import CGtk
import Foundation
import agtermCore

enum LinuxLinkModifierPolicy {
    static let revealChord = GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SHIFT.rawValue

    static func reveals(_ mods: ghostty_input_mods_e, mouseCaptured: Bool) -> Bool {
        mods.rawValue == revealChord && !mouseCaptured
    }

    static func forEngine(_ mods: ghostty_input_mods_e, mouseCaptured: Bool) -> ghostty_input_mods_e {
        reveals(mods, mouseCaptured: mouseCaptured) ? GHOSTTY_MODS_CTRL : mods
    }
}

@MainActor
extension AppController {
    func linkOpenMode(_ mode: LinkOpenMode?) -> ControlResponse {
        let settingsStore = linuxSettingsStore()
        var settings = settingsStore.load()
        if let mode {
            settings.linkOpenMode = mode == .browser ? nil : mode.rawValue
            do { try settingsStore.save(settings) } catch { return err("could not save link-open mode") }
        }
        return ControlResponse(ok: true, result: ControlResult(text: settings.effectiveLinkOpenMode.rawValue))
    }
}

@MainActor
extension GhosttySurface {
    func rememberLinkModifiers(_ mods: ghostty_input_mods_e) {
        linkBrowserOverride = LinuxLinkModifierPolicy.reveals(mods, mouseCaptured: mouseCapturedForLinks)
    }

    /// Match Ghostty's Ctrl-only links while retaining the reveal chord at the host boundary.
    /// Mouse-reporting TUIs receive their original modifiers, including Shift.
    func linkInputModifiers(_ mods: ghostty_input_mods_e) -> ghostty_input_mods_e {
        guard mods.rawValue == LinuxLinkModifierPolicy.revealChord else { return mods }
        return LinuxLinkModifierPolicy.forEngine(mods, mouseCaptured: mouseCapturedForLinks)
    }

    private var mouseCapturedForLinks: Bool {
        surface.map { ghostty_surface_mouse_captured($0) } ?? true
    }

    var linkClickOrigin: LinkPolicy.ClickOrigin {
        switch role {
        case .main, .split:
            if controller?.store.session(withID: sessionID)?.remoteHost != nil { return .remotePane(sessionID) }
            return .pane(sessionID)
        case .scratch: return .scratch(sessionID)
        case .quick: return .quick
        case .overlay: return controller?.store.session(withID: sessionID)?.hudActive == true ? .hud : .programOverlay
        }
    }

    func openLink(_ raw: String) -> Bool {
        let session = controller?.store.session(withID: sessionID)
        let directory = isSplitPane ? session?.splitCwd ?? session?.effectiveCwd : session?.effectiveCwd
        let locations = LinkPolicy.locations(for: raw, origin: linkClickOrigin, cwd: directory)
        guard !locations.isEmpty else { return openResolvedLink(raw) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let location = locations.first { FileManager.default.fileExists(atPath: $0.path) }
            runOnMain { MainActor.assumeIsolated {
                guard let self else { return }
                if !self.openResolvedLink(raw, location: location) { GhosttyApp.openTerminalURL(raw) }
            } }
        }
        return true
    }

    private func openResolvedLink(_ raw: String, location: LinkPolicy.LinkLocation? = nil) -> Bool {
        guard let controller else { return false }
        let mode = linkBrowserOverride ? LinkOpenMode.browser : linuxSettingsStore().load().effectiveLinkOpenMode
        let route = location.map { LinkPolicy.route(for: $0, mode: mode, origin: linkClickOrigin) }
            ?? LinkPolicy.route(for: raw, mode: mode, origin: linkClickOrigin)
        if linkBrowserOverride, let file = route.localFile {
            GhosttyApp.openTerminalURL(file.absoluteString)
            return true
        }
        switch route {
        case .image(let url, let id):
            return controller.openClickedFile(url, session: id, markdown: false)
        case .markdown(let url, let id, let sizePercent):
            return controller.openClickedFile(url, session: id, markdown: true, sizePercent: sizePercent)
        case .text(let link):
            let log = link.opensAsLog && !controller.store.pageBelongsRemote(link.session, pane: nil)
            return controller.openClickedPage(.text(path: link.url.path, line: link.line), session: link.session,
                                              sizePercent: link.sizePercent,
                                              log: log ? TextLog(tail: TextPage.defaultTail, follow: true) : nil)
        case .document(let url, let id, let sizePercent):
            return controller.openClickedPage(.document(path: url.path), session: id, sizePercent: sizePercent)
        case .overlay(let url, let id, let sizePercent):
            guard controller.terminalZoom.target == nil, controller.store.session(withID: id)?.hudActive != true else { return false }
            controller.store.releaseHiddenClickedPage(id)
            return controller.openSessionOverlay(id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
                command: "", cwd: nil, wait: false, sizePercent: sizePercent, backgroundColor: nil, follow: false,
                pane: nil, page: .url(url), navigation: true, javascript: true, persistent: true, browse: true, clicked: true)).ok
        case .browser, .reveal, .ignore: return false
        }
    }
}
