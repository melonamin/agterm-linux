import CGtk
import CWebKit
import Foundation
import agtermCore

/// One live WebKit view and its GTK chrome. The model owns the slot; the registry owns this view.
@MainActor
final class LinuxHtmlOverlayPage {
    private static let transferGuard = """
        (() => {
          const blocked = data => {
            if (!data) return false;
            const hasURI = () => {
              for (const type of data.types) {
                if (type === 'text/uri-list' || type === 'x-special/gnome-copied-files' ||
                    type === 'application/vnd.portal.filetransfer') return true;
              }
              return false;
            };
            // On X11, WebKit can populate DataTransfer.types on its first read.
            return hasURI() || hasURI() || data.files.length > 0;
          };
          for (const name of ['paste', 'drop', 'dragover']) {
            window.addEventListener(name, event => {
              const transfer = event.clipboardData || event.dataTransfer;
              if (!blocked(transfer)) return;
              event.preventDefault();
              event.stopImmediatePropagation();
              if (event.dataTransfer) event.dataTransfer.dropEffect = 'none';
            }, true);
          }
        })();
        """

    struct Resource {
        let path: String
        let mime: String
    }

    let id: UUID
    let root: OpaquePointer
    let webView: OpaquePointer
    let backgroundColor: String?
    private weak var controller: AppController?
    private weak var store: AppStore?
    private var overlay: HtmlOverlay
    private var theme: HtmlOverlayTheme
    private var appliedRevision: Int
    private var loadFailed = false
    private var pendingExternalURL: URL?
    private var pendingDialog: OpaquePointer?
    private var promptSilenced = false
    private var onScreen = false
    private let manager: OpaquePointer
    private var inputController: OpaquePointer?
    private let title: OpaquePointer
    private let errorLabel: OpaquePointer
    private var buttons: [String: OpaquePointer] = [:]
    private let bridgeToken = UUID().uuidString

    init(overlay: HtmlOverlay, controller: AppController, backgroundColor: String?, theme: HtmlOverlayTheme) {
        id = overlay.id
        self.overlay = overlay
        self.controller = controller
        store = controller.store
        self.backgroundColor = backgroundColor
        self.theme = theme
        appliedRevision = overlay.reloadRevision
        manager = webkit_user_content_manager_new()
        let settings = webkit_settings_new()
        // Run the trusted transfer guard while keeping page-authored scripts opt-in.
        webkit_settings_set_enable_javascript(settings, 1)
        webkit_settings_set_enable_javascript_markup(settings, overlay.javascript ? 1 : 0)
        webkit_settings_set_allow_file_access_from_file_urls(settings, 0)
        webkit_settings_set_allow_universal_access_from_file_urls(settings, 0)
        webkit_settings_set_javascript_can_open_windows_automatically(settings, 0)
        webView = op(agterm_web_view_new_ephemeral(manager, settings))!
        g_object_unref(RAW(settings))
        root = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        g_object_ref_sink(RAW(root))
        title = OpaquePointer(gtk_label_new(nil))
        errorLabel = OpaquePointer(gtk_label_new(nil))
        Self.transferGuard.withCString { source in
            let script = "agterm-transfer-guard".withCString { world in
                webkit_user_script_new_for_world(source, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
                                                 WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, world, nil, nil)
            }
            webkit_user_content_manager_add_script(manager, script)
            webkit_user_script_unref(script)
        }
        if case .file = overlay.source { installBridge() }
        buildUI()
        connectSignals()
        applyTheme(theme)
    }

    func start() { loadOriginal() }

    func close() {
        let data = Unmanaged.passUnretained(self).toOpaque()
        let dialog = pendingDialog
        pendingDialog = nil
        pendingExternalURL = nil
        if let dialog {
            agterm_disconnect_signals(RAW(dialog), data)
            adw_dialog_close(cast(dialog))
        }
        agterm_disconnect_signals(RAW(webView), data)
        agterm_disconnect_signals(RAW(manager), data)
        if case .file = overlay.source {
            for world in bridgeWorlds { webkit_user_content_manager_unregister_script_message_handler(manager, LinuxHtmlOverlayBridge.handlerName, world) }
        }
        if let inputController { agterm_disconnect_signals(RAW(inputController), data) }
        for button in buttons.values { agterm_disconnect_signals(RAW(button), data) }
        webkit_web_view_stop_loading(cast(webView))
        controller?.moveHtmlRoot(root, into: nil)
        g_object_unref(RAW(manager))
        g_object_unref(RAW(root))
    }

    func setOnScreen(_ visible: Bool) {
        onScreen = visible
        guard !visible, let dialog = pendingDialog else { return }
        pendingDialog = nil
        pendingExternalURL = nil
        adw_dialog_close(cast(dialog))
    }

    func apply(_ newer: HtmlOverlay) {
        overlay = newer
        refreshToolbar()
        guard newer.reloadRevision != appliedRevision else { return }
        appliedRevision = newer.reloadRevision
        if newer.reloadTarget == .current, webkit_web_view_get_uri(cast(webView)) != nil {
            webkit_web_view_reload(cast(webView))
        } else {
            loadOriginal()
        }
    }

    func applyTheme(_ newer: HtmlOverlayTheme) {
        guard theme != newer || webkit_web_view_get_uri(cast(webView)) == nil else { return }
        theme = newer
        webkit_user_content_manager_remove_all_style_sheets(manager)
        let themed: Bool = if case .file = overlay.source { true } else { false }
        let look = themed ? "color-scheme: \(newer.dark ? "dark" : "light"); color: \(newer.foreground); " : ""
        let palette = newer.palette.enumerated().compactMap { index, color in
            color.isEmpty ? nil : "--agterm-color-\(index): \(color); "
        }.joined()
        let css = ":where(html) { \(look)--agterm-background: \(newer.background); "
            + "--agterm-foreground: \(newer.foreground); \(palette)}"
        css.withCString { source in
            let sheet = webkit_user_style_sheet_new(source, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                                                     WEBKIT_USER_STYLE_LEVEL_AUTHOR, nil, nil)
            webkit_user_content_manager_add_style_sheet(manager, sheet)
            webkit_user_style_sheet_unref(sheet)
        }
        if themed {
            let rgb = UInt32(newer.background.dropFirst(), radix: 16) ?? 0x282c34
            var color = GdkRGBA(red: Float((rgb >> 16) & 255) / 255, green: Float((rgb >> 8) & 255) / 255,
                                blue: Float(rgb & 255) / 255, alpha: 1)
            webkit_web_view_set_background_color(cast(webView), &color)
            if webkit_web_view_get_uri(cast(webView)) != nil { webkit_web_view_reload(cast(webView)) }
        }
    }

    func navigate(_ step: HtmlNavigation) -> String? {
        switch step {
        case .back:
            guard webkit_web_view_can_go_back(cast(webView)) != 0 else { return OverlayHtmlError.noHistory(.back) }
            webkit_web_view_go_back(cast(webView))
        case .forward:
            guard webkit_web_view_can_go_forward(cast(webView)) != 0 else { return OverlayHtmlError.noHistory(.forward) }
            webkit_web_view_go_forward(cast(webView))
        case .browser:
            guard launchDefaultHandler(forURI: browserURL.absoluteString) else { return OverlayHtmlError.noBrowser }
        case .finder:
            guard case .file = overlay.source else { return OverlayHtmlError.finderRequiresFile }
            launchDefaultHandler(forURI: pageURL.deletingLastPathComponent().absoluteString)
        }
        return nil
    }

    func resource(for uriPath: String) -> Resource? {
        guard case .file(_, let grantRoot?) = overlay.source else { return nil }
        let root = URL(fileURLWithPath: grantRoot).standardizedFileURL.resolvingSymlinksInPath()
        let path = root.appendingPathComponent(String(uriPath.drop(while: { $0 == "/" })))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard path.pathComponents.starts(with: root.pathComponents),
              path.pathComponents.count > root.pathComponents.count else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: path.path) else { return nil }
        let mime: String = switch path.pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "js", "mjs": "text/javascript"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
        return Resource(path: path.path, mime: mime)
    }

    private var pageURL: URL {
        if case .file(let path, let grantRoot) = overlay.source {
            guard let grantRoot, let current = webkit_web_view_get_uri(cast(webView)),
                  let uri = URLComponents(string: String(cString: current)), uri.scheme == "agterm-file" else {
                return URL(fileURLWithPath: path)
            }
            return URL(fileURLWithPath: grantRoot).appendingPathComponent(String(uri.path.dropFirst()))
        }
        if let current = webkit_web_view_get_uri(cast(webView)), let url = URL(string: String(cString: current)),
           url.scheme == "http" || url.scheme == "https" { return url }
        if case .url(let url) = overlay.source { return url }
        return URL(fileURLWithPath: "/")
    }

    private var browserURL: URL {
        if case .file(let path, _) = overlay.source { return URL(fileURLWithPath: path) }
        return pageURL
    }

    private func loadOriginal() {
        loadFailed = false
        store?.setHtmlLoadState(id, state: .loading, error: nil)
        switch overlay.source {
        case .url(let url):
            url.absoluteString.withCString { webkit_web_view_load_uri(cast(webView), $0) }
        case .file(let path, let grantRoot?):
            guard let uri = LinuxHtmlOverlayRegistry.shared.fileURI(for: path, id: id, grantRoot: grantRoot) else {
                fail("html file is outside cwd")
                return
            }
            uri.withCString { webkit_web_view_load_uri(cast(webView), $0) }
        case .file(let path, nil):
            guard let html = try? String(contentsOfFile: path, encoding: .utf8) else {
                fail("could not read html file: \(path)")
                return
            }
            html.withCString { webkit_web_view_load_html(cast(webView), $0, nil) }
        }
    }

    // the page world (nil) only on a --js page, where `agterm.request` lives
    private var bridgeWorlds: [String?] { overlay.javascript ? [LinuxHtmlOverlayBridge.world, nil] : [LinuxHtmlOverlayBridge.world] }

    // installed once: theme changes replace only style sheets, so the scripts and handlers stay
    private func installBridge() {
        addScript(LinuxHtmlOverlayBridge.adapterScript(token: bridgeToken), world: LinuxHtmlOverlayBridge.world,
                  at: WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END)
        if overlay.javascript {
            addScript(LinuxHtmlOverlayBridge.helperScript(token: bridgeToken), world: nil,
                      at: WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START)
        }
        connect(manager, "script-message-with-reply-received::\(LinuxHtmlOverlayBridge.handlerName)",
                unsafeBitCast(onHtmlBridgeMessage as @convention(c)
                    (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, gpointer?) -> gboolean,
                    to: GCallback.self), Unmanaged.passUnretained(self).toOpaque())
        for world in bridgeWorlds {
            _ = webkit_user_content_manager_register_script_message_handler_with_reply(
                manager, LinuxHtmlOverlayBridge.handlerName, world)
        }
    }

    private func addScript(_ source: String, world: String?, at time: WebKitUserScriptInjectionTime) {
        let script = source.withCString { source in
            if let world {
                return world.withCString { webkit_user_script_new_for_world(source, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, time, $0, nil, nil) }
            }
            return webkit_user_script_new(source, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, time, nil, nil)
        }
        webkit_user_content_manager_add_script(manager, script)
        webkit_user_script_unref(script)
    }

    func bridgeMessage(_ value: UnsafeMutableRawPointer?, reply: UnsafeMutableRawPointer?) -> gboolean {
        guard let reply else { return 0 }
        let message = value.flatMap { agterm_script_message_json($0) }.map { json in
            defer { g_free(json) }
            return String(cString: json)
        }
        let answer = LinuxScriptReply(reply)
        LinuxHtmlOverlayBridge.handle(message, token: bridgeToken, origin: bridgeOrigin,
                                      dispatch: LinuxHtmlOverlayRegistry.shared.dispatch) { json, error in
            answer.send(json, error: error)
        }
        return 1
    }

    // resolved per message, so a page acts from where it sits now
    private var bridgeOrigin: HtmlBridgePage? {
        guard let store, let slot = store.htmlOverlaySlot(id) else { return nil }
        let window = gWindows.first { $0.value.store === store }?.key.uuidString
        return HtmlBridgePage(window: window, session: slot.session.id, pane: slot.pane)
    }

    func fail(_ message: String) {
        loadFailed = true
        store?.setHtmlLoadState(id, state: .failed, error: message)
        message.withCString { gtk_label_set_text(errorLabel, $0) }
        gtk_widget_set_visible(W(errorLabel), 1)
    }

    func reportPage() {
        guard webkit_web_view_get_uri(cast(webView)) != nil else { return }
        let page = pageURL
        let title = webkit_web_view_get_title(cast(webView)).map(String.init(cString:))
        store?.setHtmlPage(id, HtmlPageInfo(page: page.isFileURL ? page.path : page.absoluteString,
                                            title: title?.isEmpty == true ? nil : title,
                                            canGoBack: webkit_web_view_can_go_back(cast(webView)) != 0,
                                            canGoForward: webkit_web_view_can_go_forward(cast(webView)) != 0))
        refreshToolbar()
    }

    private func refreshToolbar() {
        if let slot = store?.htmlOverlaySlot(id) {
            if let current = slot.pane.flatMap({ slot.session.paneOverlay($0)?.html }) ?? slot.session.htmlOverlay {
                overlay = current
            }
        }
        overlay.identity.withCString { gtk_label_set_text(title, $0) }
        for (name, button) in buttons {
            let isNavigation = ["back", "forward", "reload", "browser", "finder", "copy"].contains(name)
            let isFile: Bool = if case .file = overlay.source { true } else { false }
            let visible = !isNavigation || (overlay.navigation && (name != "finder" || isFile)
                                           && (name != "copy" || !isFile))
            gtk_widget_set_visible(W(button), visible ? 1 : 0)
        }
        let current = store?.htmlOverlaySlot(id).flatMap { slot in
            slot.pane.map { slot.session.paneOverlay($0)?.html } ?? slot.session.htmlOverlay
        }?.current
        if let button = buttons["back"] { gtk_widget_set_sensitive(W(button), current?.canGoBack == true ? 1 : 0) }
        if let button = buttons["forward"] { gtk_widget_set_sensitive(W(button), current?.canGoForward == true ? 1 : 0) }
    }

    private func buildUI() {
        guard let strip = OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)) else { return }
        gtk_widget_add_css_class(W(strip), "toolbar")
        gtk_widget_set_size_request(W(strip), -1, 30)
        for (name, icon, tooltip) in [
            ("back", "go-previous-symbolic", "Back"), ("forward", "go-next-symbolic", "Forward"),
            ("reload", "view-refresh-symbolic", "Reload"),
        ] { addButton(name, icon: icon, tooltip: tooltip, to: strip) }
        gtk_label_set_ellipsize(title, PANGO_ELLIPSIZE_MIDDLE)
        gtk_widget_set_hexpand(W(title), 1)
        gtk_box_append(cast(strip), W(title))
        for (name, icon, tooltip) in [
            ("browser", "web-browser-symbolic", "Open in Browser"),
            ("finder", "folder-open-symbolic", "Show in Files"),
            ("copy", "edit-copy-symbolic", "Copy Link"),
            ("close", "window-close-symbolic", "Close"),
        ] { addButton(name, icon: icon, tooltip: tooltip, to: strip) }
        gtk_box_append(cast(root), W(strip))
        guard let content = OpaquePointer(gtk_overlay_new()) else { return }
        gtk_widget_set_hexpand(W(content), 1)
        gtk_widget_set_vexpand(W(content), 1)
        gtk_widget_set_hexpand(W(webView), 1)
        gtk_widget_set_vexpand(W(webView), 1)
        gtk_overlay_set_child(content, W(webView))
        gtk_widget_set_halign(W(errorLabel), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(W(errorLabel), GTK_ALIGN_CENTER)
        gtk_label_set_wrap(errorLabel, 1)
        gtk_widget_add_css_class(W(errorLabel), "error")
        gtk_widget_set_visible(W(errorLabel), 0)
        gtk_overlay_add_overlay(content, W(errorLabel))
        gtk_box_append(cast(root), W(content))
        gtk_widget_set_hexpand(W(root), 1)
        gtk_widget_set_vexpand(W(root), 1)
        refreshToolbar()
    }

    private func addButton(_ name: String, icon: String, tooltip: String, to strip: OpaquePointer) {
        let button = OpaquePointer(icon.withCString { gtk_button_new_from_icon_name($0) })
        tooltip.withCString { gtk_widget_set_tooltip_text(W(button), $0) }
        gtk_widget_add_css_class(W(button), "flat")
        buttons[name] = button
        connect(button, "clicked", unsafeBitCast(onHtmlToolbarClick as @convention(c)
            (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), Unmanaged.passUnretained(self).toOpaque())
        gtk_box_append(cast(strip), W(button))
    }

    func toolbarClick(_ sender: OpaquePointer?) {
        guard let name = buttons.first(where: { $0.value == sender })?.key else { return }
        switch name {
        case "back": _ = navigate(.back)
        case "forward": _ = navigate(.forward)
        case "reload":
            if let store, let slot = store.htmlOverlaySlot(id) {
                _ = LinuxHtmlOverlayRegistry.shared.reload(sessionID: slot.session.id, pane: slot.pane,
                                                             current: true, store: store)
            }
        case "browser": _ = navigate(.browser)
        case "finder": _ = navigate(.finder)
        case "copy":
            if let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display) {
                browserURL.absoluteString.withCString { gdk_clipboard_set_text(clipboard, $0) }
            }
        case "close":
            if store?.closeHtmlOverlay(id) == true { controller?.reconcile() }
        default: break
        }
    }

    private func connectSignals() {
        let data = Unmanaged.passUnretained(self).toOpaque()
        let input = gtk_event_controller_legacy_new()
        inputController = OpaquePointer(UnsafeMutableRawPointer(input))
        gtk_event_controller_set_propagation_phase(input, GTK_PHASE_CAPTURE)
        connect(input.map { OpaquePointer(UnsafeMutableRawPointer($0)) }, "event",
                unsafeBitCast(onHtmlUserEvent as @convention(c)
                    (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self), data)
        gtk_widget_add_controller(W(webView), input)
        connect(webView, "load-changed", unsafeBitCast(onHtmlLoadChanged as @convention(c)
            (OpaquePointer?, Int32, gpointer?) -> Void, to: GCallback.self), data)
        connect(webView, "load-failed", unsafeBitCast(onHtmlLoadFailed as @convention(c)
            (OpaquePointer?, Int32, UnsafePointer<CChar>?, UnsafeMutablePointer<GError>?, gpointer?) -> gboolean,
            to: GCallback.self), data)
        connect(webView, "decide-policy", unsafeBitCast(onHtmlDecidePolicy as @convention(c)
            (OpaquePointer?, OpaquePointer?, Int32, gpointer?) -> gboolean, to: GCallback.self), data)
        for signal in ["notify::uri", "notify::title", "notify::can-go-back", "notify::can-go-forward"] {
            connect(webView, signal, unsafeBitCast(onHtmlProperty as @convention(c)
                (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self), data)
        }
        connect(webView, "permission-request", unsafeBitCast(onHtmlPermission as @convention(c)
            (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self), data)
        connect(webView, "run-file-chooser", unsafeBitCast(onHtmlFileChooser as @convention(c)
            (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self), data)
        connect(webView, "script-dialog", unsafeBitCast(onHtmlScriptDialog as @convention(c)
            (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self), data)
        connect(webView, "web-process-terminated", unsafeBitCast(onHtmlProcessTerminated as @convention(c)
            (OpaquePointer?, Int32, gpointer?) -> Void, to: GCallback.self), data)
        connect(webView, "context-menu", unsafeBitCast(onHtmlContextMenu as @convention(c)
            (OpaquePointer?, OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self), data)
    }

    func loadChanged(_ event: Int32) {
        switch event {
        case 0:
            loadFailed = false
            gtk_widget_set_visible(W(errorLabel), 0)
            store?.setHtmlLoadState(id, state: .loading, error: nil)
        case 3:
            if !loadFailed { store?.setHtmlLoadState(id, state: .loaded, error: nil) }
            reportPage()
        default: break
        }
    }

    func loadFailedWith(_ error: UnsafeMutablePointer<GError>?) {
        guard !loadFailed else { return }
        let message = error.map { String(cString: $0.pointee.message) } ?? "page load failed"
        fail(message)
    }

    func decide(_ decision: OpaquePointer?, type: Int32) -> gboolean {
        guard let decision else { return 0 }
        guard type == 0 || type == 1 else { return 0 }
        let action = webkit_navigation_policy_decision_get_navigation_action(decision)
        guard let request = webkit_navigation_action_get_request(action),
              let pointer = webkit_uri_request_get_uri(request), let rawURL = URL(string: String(cString: pointer)) else {
            webkit_policy_decision_ignore(cast(decision))
            return 1
        }
        let target: HtmlNavigationTarget = type == 1 ? .newWindow
            : webkit_navigation_action_get_frame_name(action) == nil ? .mainFrame : .subframe
        let clicked = webkit_navigation_action_get_navigation_type(action).rawValue == 0
        let url: URL
        if rawURL.scheme == "agterm-file", case .file(_, let grantRoot?) = overlay.source,
           rawURL.host?.lowercased() == id.uuidString.lowercased() {
            url = URL(fileURLWithPath: grantRoot).appendingPathComponent(String(rawURL.path.dropFirst()))
        } else {
            url = rawURL
        }
        let verdict = HtmlNavigationPolicy.decide(
            HtmlNavigationAction(url: url, target: target, userActivated: clicked), overlay: overlay)
        if verdict == .allow {
            webkit_policy_decision_use(cast(decision))
        } else {
            webkit_policy_decision_ignore(cast(decision))
            if verdict == .openExternal { askToOpen(url) }
            if target == .mainFrame, !clicked, !loadFailed { fail("navigation blocked: \(url.absoluteString)") }
        }
        return 1
    }

    private func askToOpen(_ url: URL) {
        guard onScreen, pendingDialog == nil, !promptSilenced, let controller else { return }
        let heading = "Open \(HtmlSource.origin(of: url) ?? url.absoluteString) in your browser?"
        let dialog = OpaquePointer(heading.withCString { h in
            url.absoluteString.withCString { b in adw_alert_dialog_new(h, b) }
        })
        "cancel".withCString { key in "Cancel".withCString { label in
            adw_alert_dialog_add_response(cast(dialog), key, label)
        } }
        "open".withCString { key in "Open".withCString { label in
            adw_alert_dialog_add_response(cast(dialog), key, label)
        } }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        pendingExternalURL = url
        pendingDialog = dialog
        connect(dialog, "response", unsafeBitCast(onHtmlExternalResponse as @convention(c)
            (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self),
                Unmanaged.passUnretained(self).toOpaque())
        adw_dialog_present(cast(dialog), W(controller.windowPointer))
    }

    func externalResponse(_ answer: UnsafePointer<CChar>?) {
        guard pendingDialog != nil else { return }
        let url = pendingExternalURL
        pendingExternalURL = nil
        pendingDialog = nil
        if answer.map(String.init(cString:)) == "open", let url {
            launchDefaultHandler(forURI: url.absoluteString)
        } else {
            promptSilenced = true
        }
    }

    private func hasFileTransfer(_ formats: OpaquePointer?) -> Bool {
        guard let formats else { return false }
        if gdk_content_formats_contain_gtype(formats, gdk_file_list_get_type()) != 0 { return true }
        return ["text/uri-list", "x-special/gnome-copied-files", "application/vnd.portal.filetransfer"]
            .contains { mime in
                mime.withCString { gdk_content_formats_contain_mime_type(formats, $0) != 0 }
            }
    }

    private var clipboardHasFileTransfer: Bool {
        guard let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display) else {
            return false
        }
        return hasFileTransfer(gdk_clipboard_get_formats(clipboard))
    }

    func blockFileContextMenu() -> gboolean { clipboardHasFileTransfer ? 1 : 0 }

    func userEvent(_ event: OpaquePointer?) -> gboolean {
        guard let event else { return 0 }
        let type = gdk_event_get_event_type(event)
        if type == GDK_DRAG_ENTER || type == GDK_DRAG_MOTION || type == GDK_DROP_START,
           let drop = gdk_dnd_event_get_drop(event), hasFileTransfer(gdk_drop_get_formats(drop)) {
            if type == GDK_DROP_START { gdk_drop_finish(drop, GdkDragAction(rawValue: 0)) }
            return 1
        }
        if type == GDK_KEY_PRESS {
            let key = gdk_keyval_to_lower(gdk_key_event_get_keyval(event))
            let modifiers = UInt32(gdk_event_get_modifier_state(event).rawValue)
            let paste = (key == UInt32(GDK_KEY_v) && modifiers & UInt32(GDK_CONTROL_MASK.rawValue) != 0)
                || (key == UInt32(GDK_KEY_Insert) && modifiers & UInt32(GDK_SHIFT_MASK.rawValue) != 0)
            if paste && clipboardHasFileTransfer { return 1 }
        }
        if type == GDK_BUTTON_PRESS || type == GDK_KEY_PRESS {
            promptSilenced = false
            store?.noteUserActivity()
        }
        return 0
    }
}

@MainActor private func htmlPage(_ data: gpointer?) -> LinuxHtmlOverlayPage? {
    guard let data else { return nil }
    return Unmanaged<LinuxHtmlOverlayPage>.fromOpaque(data).takeUnretainedValue()
}

private let onHtmlToolbarClick: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { sender, data in
    htmlPage(data)?.toolbarClick(sender)
}
private let onHtmlLoadChanged: @MainActor @convention(c) (OpaquePointer?, Int32, gpointer?) -> Void = { _, event, data in
    htmlPage(data)?.loadChanged(event)
}
private let onHtmlLoadFailed: @MainActor @convention(c)
    (OpaquePointer?, Int32, UnsafePointer<CChar>?, UnsafeMutablePointer<GError>?, gpointer?) -> gboolean =
    { _, _, _, error, data in htmlPage(data)?.loadFailedWith(error); return 1 }
private let onHtmlProperty: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, _, data in
    htmlPage(data)?.reportPage()
}
private let onHtmlDecidePolicy: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, Int32, gpointer?) -> gboolean =
    { _, decision, type, data in htmlPage(data)?.decide(decision, type: type) ?? 0 }
private let onHtmlPermission: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean =
    { _, request, _ in webkit_permission_request_deny(request); return 1 }
private let onHtmlFileChooser: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean =
    { _, request, _ in webkit_file_chooser_request_cancel(request); return 1 }
private let onHtmlScriptDialog: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean =
    { _, dialog, _ in webkit_script_dialog_close(dialog); return 1 }
private let onHtmlProcessTerminated: @MainActor @convention(c) (OpaquePointer?, Int32, gpointer?) -> Void = { _, _, data in
    htmlPage(data)?.fail("web content process terminated")
}
private let onHtmlBridgeMessage: @MainActor @convention(c)
    (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, gpointer?) -> gboolean =
    { _, value, reply, data in htmlPage(data)?.bridgeMessage(value, reply: reply) ?? 0 }
private let onHtmlExternalResponse: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void =
    { _, answer, data in htmlPage(data)?.externalResponse(answer) }
private let onHtmlUserEvent: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean =
    { _, event, data in htmlPage(data)?.userEvent(event) ?? 0 }
private let onHtmlContextMenu: @MainActor @convention(c)
    (OpaquePointer?, OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean =
    { _, _, _, data in htmlPage(data)?.blockFileContextMenu() ?? 0 }
