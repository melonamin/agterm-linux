import CGtk
import CWebKit
import Foundation
import agtermCore

/// Web views are owned by page id, so a pane swap or GTK remount does not reload the document.
@MainActor
final class LinuxHtmlOverlayRegistry {
    static let shared = LinuxHtmlOverlayRegistry()
    private static let fileScheme = "agterm-file"
    private var pages: [UUID: LinuxHtmlOverlayPage] = [:]
    private var installed = false

    func install() {
        HtmlOverlayReleases.shared.onRelease = { [weak self] id in self?.release(id) }
        guard !installed, let context = webkit_web_context_get_default() else { return }
        installed = true
        Self.fileScheme.withCString {
            webkit_web_context_register_uri_scheme(context, $0, onHtmlSchemeRequest, nil, nil)
            webkit_security_manager_register_uri_scheme_as_local(webkit_web_context_get_security_manager(context), $0)
        }
    }

    func page(for overlay: HtmlOverlay, controller: AppController, backgroundColor: String?) -> LinuxHtmlOverlayPage {
        if let page = pages[overlay.id] {
            page.apply(overlay)
            return page
        }
        let page = LinuxHtmlOverlayPage(overlay: overlay, controller: controller,
                                        backgroundColor: backgroundColor, theme: theme(backgroundColor: backgroundColor))
        pages[overlay.id] = page
        page.start()
        return page
    }

    var persistentPageCount: Int { pages.values.filter { $0.overlay.persistent }.count }

    func ownsKeyboard(in controller: AppController) -> Bool {
        guard let focus = gtk_root_get_focus(controller.windowPointer) else { return false }
        return pages.values.contains {
            $0.controller === controller && (focus == W($0.webView) || gtk_widget_is_ancestor(focus, W($0.webView)) != 0)
        }
    }

    func stepZoom(_ action: String) {
        let settingsStore = linuxSettingsStore()
        var settings = settingsStore.load()
        guard let zoom = HtmlZoom.applying(fontAction: action, to: settings.effectiveHtmlOverlayZoom) else { return }
        settings.htmlOverlayZoom = zoom == 1 ? nil : zoom
        try? settingsStore.save(settings)
        for page in pages.values { page.applyZoom() }
    }

    func existing(_ id: UUID) -> LinuxHtmlOverlayPage? { pages[id] }

    func release(_ id: UUID) {
        pages.removeValue(forKey: id)?.close()
    }

    func releasePages(in store: AppStore) {
        for session in store.workspaces.flatMap(\.sessions) {
            if let page = session.htmlOverlay { release(page.id) }
            for pane in OverlayPane.allCases {
                if let page = session.paneOverlay(pane)?.html { release(page.id) }
            }
        }
    }

    func refreshThemes() {
        for page in pages.values { page.applyTheme(theme(backgroundColor: page.backgroundColor)) }
    }

    func refreshVisibility(in store: AppStore, selected: UUID?, covered: Bool) {
        for (id, page) in pages {
            guard let slot = store.htmlOverlaySlot(id) else {
                page.setOnScreen(false)
                continue
            }
            let hiddenByFullOverlay = slot.pane != nil && slot.session.fullOverlayActive
            page.setOnScreen(!covered && !hiddenByFullOverlay && slot.session.id == selected)
        }
    }

    func reload(sessionID: UUID, pane: OverlayPane?, current: Bool, store: AppStore) -> HtmlOverlayCommandFailure? {
        if let failure = store.reloadHtmlOverlay(sessionID, pane: pane, target: current ? .current : .original) {
            return failure
        }
        let session = store.session(withID: sessionID)
        if let overlay = pane.map({ session?.paneOverlay($0)?.html }) ?? session?.htmlOverlay {
            pages[overlay.id]?.apply(overlay)
        }
        return nil
    }

    func navigate(sessionID: UUID, pane: OverlayPane?, step: HtmlNavigation, store: AppStore) -> String? {
        let session = store.session(withID: sessionID)
        guard let overlay = pane.map({ session?.paneOverlay($0)?.html }) ?? session?.htmlOverlay else {
            return store.htmlOverlayCommandFailure(sessionID, pane: pane)?.message ?? OverlayHtmlError.noOverlay
        }
        guard let page = pages[overlay.id] else { return OverlayHtmlError.notRealized }
        return page.navigate(step)
    }

    private func theme(backgroundColor: String?) -> HtmlOverlayTheme {
        let background = backgroundColor ?? GhosttyApp.shared.currentThemeBackgroundHex ?? "#282c34"
        let foreground = GhosttyApp.shared.currentThemeForegroundHex ?? "#ffffff"
        let hex = background.dropFirst()
        let rgb = UInt32(hex, radix: 16) ?? 0x282c34
        let dark = ThemeBrightness.isDark(red: Double((rgb >> 16) & 255) / 255,
                                          green: Double((rgb >> 8) & 255) / 255,
                                          blue: Double(rgb & 255) / 255)
        return HtmlOverlayTheme(background: background, foreground: foreground, dark: dark,
                                palette: GhosttyApp.shared.currentThemePalette)
    }

    func fileURI(for path: String, id: UUID, grantRoot: String) -> String? {
        let root = URL(fileURLWithPath: grantRoot).standardizedFileURL.resolvingSymlinksInPath()
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let components = file.pathComponents
        guard components.starts(with: root.pathComponents), components.count > root.pathComponents.count else { return nil }
        let relative = components.dropFirst(root.pathComponents.count).joined(separator: "/")
        var uri = URLComponents()
        uri.scheme = Self.fileScheme
        uri.host = id.uuidString.lowercased()
        uri.path = "/" + relative
        return uri.url?.absoluteString
    }

    func serve(_ request: OpaquePointer?) {
        guard let request, let pointer = webkit_uri_scheme_request_get_uri(request),
              let uri = URLComponents(string: String(cString: pointer)),
              let host = uri.host, let id = UUID(uuidString: host), let page = pages[id],
              let resource = page.resource(for: uri.path) else {
            if let request { agterm_uri_scheme_deny(request) }
            return
        }
        resource.path.withCString { path in
            resource.mime.withCString { mime in agterm_uri_scheme_finish_file(request, path, mime) }
        }
    }
}

private let onHtmlSchemeRequest: @MainActor @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { request, _ in
    LinuxHtmlOverlayRegistry.shared.serve(request)
}
