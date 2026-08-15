// Owns the single `ghostty_app_t` and the libghostty runtime-config callbacks.
// Mirrors the macOS GhosttyApp/GhosttyCallbacks split, adapted to GLib/GTK:
// wakeups coalesce onto a g_idle main-thread tick; the `.render` action draws on
// the app thread (the Linux embedded apprt sets must_draw_from_app_thread).
//
// `@unchecked Sendable` like the macOS GhosttyCallbacks: the C closures fire off
// whatever thread libghostty calls from. The only mutable state (`tickScheduled`)
// is lock-guarded; `app` is set once on the main thread before any surface exists.
// Surface-touching action handling runs during a tick on the main thread, asserted
// via `MainActor.assumeIsolated`.
import CGtk
import Foundation
import agtermCore

/// The ghostty-resources candidate dirs (highest priority first): a dev env override, the per-user
/// install, then the system package. Shared by the GHOSTTY_RESOURCES_DIR resolution and the themes
/// lookup so they can't diverge (one resolver for both).
nonisolated func ghosttyResourceCandidates() -> [String] {
    let env = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var c: [String] = []
    if let dev = env["AGTERM_GHOSTTY_RESOURCES"], !dev.isEmpty { c.append(dev) }
    c.append("\(home)/.local/share/agterm/ghostty")
    c.append("/usr/share/ghostty")
    return c
}

final class GhosttyApp: @unchecked Sendable {
    static let shared = GhosttyApp()
    private(set) var app: ghostty_app_t?

    private let tickLock = NSLock()
    private var tickScheduled = false
    private var resolvedResources: String?

    /// The current theme's colors as OSC escape sequences (OSC 11/10/4/…), fed to each surface at creation
    /// because the embedded OpenGL renderer doesn't adopt the config's default colors from the config file.
    /// Set at launch from the persisted theme; refreshed by AppController.previewTheme on every theme change.
    var currentThemeOSC: String = ""
    var currentThemeBackgroundHex: String?
    @MainActor private var appliedAppearanceSide: LinuxAppearanceSide?

    @MainActor func start(appearanceSide: LinuxAppearanceSide) {
        setGhosttyResourcesEnv()   // export GHOSTTY_RESOURCES_DIR before init + buildConfig read it
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

        // Persisted settings (font/size/theme/scroll) are layered on at launch so they survive
        // relaunch. Translucency is omitted: Linux has no window-level compositing yet.
        let saved = linuxSettingsStore().load()
        let lines = AppController.ghosttyLines(for: saved, isDark: appearanceSide.isDark)
        currentThemeOSC = AppSettings.themeOSC(from: lines)
        let cfg = buildConfig(extraLines: lines)
        if let cfg {
            currentThemeBackgroundHex = GhosttyConfigTheme.colors(from: cfg).background
        }

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = true
        rt.wakeup_cb = { _ in GhosttyApp.shared.scheduleTick() }
        rt.action_cb = { _, target, action in GhosttyApp.shared.handleAction(target, action) }
        rt.read_clipboard_cb = { ud, loc, state in GhosttyApp.readClipboard(ud, loc, state) }
        rt.confirm_read_clipboard_cb = { ud, content, state, request in
            GhosttyApp.confirmReadClipboard(ud, content, state, request)
        }
        rt.write_clipboard_cb = { ud, loc, content, len, confirm in
            GhosttyApp.writeClipboard(ud, content, len, loc, confirm)
        }
        rt.close_surface_cb = { ud, _ in
            guard let retained = RetainedGhosttySurface(ud) else { return }
            runOnMain { MainActor.assumeIsolated {
                retained.surface.handleProcessExit()
                retained.release()
            } }
        }

        app = ghostty_app_new(&rt, cfg)
        // libghostty starts with a light conditional state. Re-side and re-apply the app config before
        // any surface mounts; otherwise a dark launch rebuilds each surface from config files and drops
        // host-only env vars, initial input, and command fields from its surface configuration.
        if let app, let cfg {
            ghostty_app_set_color_scheme(
                app, appearanceSide.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
            ghostty_app_update_config(app, cfg)
        }
        appliedAppearanceSide = appearanceSide
        ghostty_config_free(cfg)
    }

    func tick() { if let a = app { ghostty_app_tick(a) } }

    func updateConfig(_ config: ghostty_config_t) {
        guard let app else { return }
        ghostty_app_update_config(app, config)
    }

    @MainActor func applyColorScheme(_ side: LinuxAppearanceSide) {
        guard let app else { return }
        ghostty_app_set_color_scheme(
            app, side.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        appliedAppearanceSide = side
    }

    /// Build a ghostty config (bundled defaults + the user's ~/.config/ghostty + the given
    /// extra lines, e.g. `theme = <name>`), finalized and ready for ghostty_surface_update_config.
    /// Caller owns it and must ghostty_config_free it after applying.
    func buildConfig(extraLines: [String]) -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        if let path = Self.writeDefaultsConf() { path.withCString { ghostty_config_load_file(cfg, $0) } }
        if linuxSettingsStore().load().inheritGlobalGhosttyConfig == true {
            ghostty_config_load_default_files(cfg)
        }
        // The agterm-scoped <configDir>/ghostty.conf overrides the bundled defaults + the user's
        // global ghostty config for any key, but the UI settings (extraLines) still win since they
        // load last. Mirrors macOS's 4-layer stack. Skipped when absent.
        if let scoped = Self.scopedGhosttyConfigPath(), FileManager.default.fileExists(atPath: scoped) {
            scoped.withCString { ghostty_config_load_file(cfg, $0) }
        }
        // Distinct empty themes keep libghostty's conditional state active while the following agterm
        // lines supply one fixed palette. This updates OSC color-scheme reports without changing colors.
        let appearanceStateLines = Self.writeAppearanceStateThemes().map {
            ["theme = light:\($0.light),dark:\($0.dark)"]
        } ?? []
        let runtimeLines = appearanceStateLines + extraLines
        if let extra = Self.writeTempConf(runtimeLines) {
            extra.withCString { ghostty_config_load_file(cfg, $0) }
        }
        // Expand any `config-file = <path>` includes across the loaded layers (matches macOS ordering:
        // recursive resolution after all load_file calls, before finalize). Without this a user's
        // `config-file` directives are silently ignored on Linux.
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        return cfg
    }

    /// Build a config for one surface with a final per-session overlay (`background-image*`, solid
    /// `background`, and/or a font-size override). The returned config is owned by the caller.
    ///
    /// Resolves through the live theme-picker preview (hence `@MainActor`): the per-surface watermark
    /// reapply runs off the preview's own OSC color-change action, so a persisted-settings base would
    /// rebuild the surface with the OLD theme's palette mid-preview.
    @MainActor
    func configWithOverlay(_ overlayText: String, settings: AppSettings? = nil) -> ghostty_config_t? {
        let base = AppController.ghosttyLines(
            for: settings ?? AppController.resolvedThemeSettings(persisted: linuxSettingsStore().load()),
            isDark: appliedAppearanceSide?.isDark ?? AppController.systemIsDark)
        let overlay = overlayText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return buildConfig(extraLines: base + overlay)
    }

    /// `<configDir>/ghostty.conf` — the agterm-scoped ghostty config layer, resolved via the shared
    /// ConfigPaths (honors a custom config dir + AGTERM_STATE_DIR isolation).
    private static func scopedGhosttyConfigPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let dir = ConfigPaths.configDirectory(setting: linuxSettingsStore().load().configDirectory,
                                               stateDir: env["AGTERM_STATE_DIR"],
                                               home: FileManager.default.homeDirectoryForCurrentUser)
        return ConfigPaths.ghosttyConfigPath(configDirectory: dir).path
    }

    private static func writeTempConf(_ lines: [String]) -> String? {
        let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("agterm-ghostty-runtime.conf")
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func writeAppearanceStateThemes() -> (light: String, dark: String)? {
        let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        let light = (dir as NSString).appendingPathComponent("agterm-ghostty-empty-light-theme")
        let dark = (dir as NSString).appendingPathComponent("agterm-ghostty-empty-dark-theme")
        guard (try? "".write(toFile: light, atomically: true, encoding: .utf8)) != nil,
              (try? "".write(toFile: dark, atomically: true, encoding: .utf8)) != nil else { return nil }
        return (light, dark)
    }

    /// Coalesce libghostty wakeups (fired off the main thread, faster than the
    /// loop drains) into a single queued main-thread `ghostty_app_tick`.
    func scheduleTick() {
        tickLock.lock()
        let already = tickScheduled
        tickScheduled = true
        tickLock.unlock()
        guard !already else { return }
        g_idle_add({ _ in
            let s = GhosttyApp.shared
            s.tickLock.lock(); s.tickScheduled = false; s.tickLock.unlock()
            MainActor.assumeIsolated { s.tick() }
            return 0 // G_SOURCE_REMOVE
        }, nil)
    }

    // MARK: - Action routing (runs on the main thread, during a tick)

    private func handleAction(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        MainActor.assumeIsolated {
            switch action.tag {
            case GHOSTTY_ACTION_RENDER:
                Self.wrapper(fromTarget: target)?.queueRender()
                return true
            case GHOSTTY_ACTION_SET_TITLE:
                guard let w = Self.wrapper(fromTarget: target), let ptr = action.action.set_title.title else { return true }
                w.applyTitle(String(cString: ptr))
                return true
            case GHOSTTY_ACTION_PWD:
                guard let w = Self.wrapper(fromTarget: target), let ptr = action.action.pwd.pwd else { return true }
                w.applyPwd(String(cString: ptr))
                return true
            case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
                guard let w = Self.wrapper(fromTarget: target) else { return false }
                guard w.shouldCloseOnChildExitAction else { return false }
                guard let retained = w.surface.flatMap({ RetainedGhosttySurface(ghostty_surface_userdata($0)) }) else { return false }
                runOnMain { MainActor.assumeIsolated {
                    retained.surface.handleProcessExit()
                    retained.release()
                } }
                return true
            case GHOSTTY_ACTION_CELL_SIZE:
                // fires when the cell pixel size changes (font-size via Ctrl+/-, or a DPI change):
                // a trigger to read + persist the live font size.
                Self.wrapper(fromTarget: target)?.reportFontSize()
                return true
            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                // hide the pointer over the terminal while typing; restore it on movement.
                Self.wrapper(fromTarget: target)?.setMouseVisible(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
                return true
            case GHOSTTY_ACTION_RING_BELL:
                if let display = gdk_display_get_default() { gdk_display_beep(display) }
                return true
            case GHOSTTY_ACTION_OPEN_URL:
                let value = action.action.open_url
                if let raw = GhosttyActionDecoder.utf8String(value.url, length: value.len) {
                    Self.openTerminalURL(raw)
                }
                return true
            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                // a non-empty url means the pointer is over a hyperlink → show the hand cursor.
                // libghostty signals hover-clear with an EMPTY url (len == 0); the pointer is never NULL.
                let action_ = action.action.mouse_over_link
                Self.wrapper(fromTarget: target)?.setLinkHover(LinkHoverDecision.isActive(url: action_.url, len: action_.len))
                return true
            case GHOSTTY_ACTION_MOUSE_SHAPE:
                Self.wrapper(fromTarget: target)?.setMouseShape(action.action.mouse_shape)
                return true
            case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                let n = action.action.desktop_notification
                let title = n.title.map { String(cString: $0) } ?? ""
                let body = n.body.map { String(cString: $0) } ?? ""
                if let origin = Self.wrapper(fromTarget: target)?.terminalNotificationOrigin() {
                    routeTerminalNotification(origin: origin, title: title, body: body)
                } else {
                    NotificationManager.send(title: title, body: body)
                }
                return true
            case GHOSTTY_ACTION_START_SEARCH:
                Self.wrapper(fromTarget: target)?.applySearchStart(action.action.start_search.needle.flatMap { String(cString: $0) })
                return true
            case GHOSTTY_ACTION_END_SEARCH:
                Self.wrapper(fromTarget: target)?.applySearchEnd()
                return true
            case GHOSTTY_ACTION_SEARCH_TOTAL:
                let raw = action.action.search_total.total
                Self.wrapper(fromTarget: target)?.applySearchTotal(raw < 0 ? nil : Int(raw))
                return true
            case GHOSTTY_ACTION_SEARCH_SELECTED:
                let raw = action.action.search_selected.selected
                Self.wrapper(fromTarget: target)?.applySearchSelected(raw < 0 ? nil : Int(raw))
                return true
            case GHOSTTY_ACTION_PROGRESS_REPORT:
                // OSC 9;4 (ConEmu/agent long-task progress). nil = clear, -1 = indeterminate, 0-100 = percent.
                let r = action.action.progress_report
                let value: Int?
                if r.state == GHOSTTY_PROGRESS_STATE_REMOVE {
                    value = nil
                } else if r.state == GHOSTTY_PROGRESS_STATE_INDETERMINATE {
                    value = -1
                } else {
                    value = r.progress < 0 ? -1 : Int(r.progress)
                }
                Self.wrapper(fromTarget: target)?.applyProgress(value)
                return true
            case GHOSTTY_ACTION_RELOAD_CONFIG:
                _ = GhosttyReloadPolicy.handle(isSoft: action.action.reload_config.soft) {
                    gWindows.values.first?.reloadConfig()
                }
                return true
            case GHOSTTY_ACTION_CONFIG_CHANGE:
                // ghostty reloaded its config (e.g. an external edit it picked up) — re-tint the sidebar in
                // case the theme changed; the surface re-renders itself.
                Self.wrapper(fromTarget: target)?.applyHostConfigChange()
                return true
            case GHOSTTY_ACTION_COLOR_CHANGE:
                let change = action.action.color_change
                if change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                    Self.wrapper(fromTarget: target)?.applyOSCBackground(
                        red: change.r, green: change.g, blue: change.b)
                }
                return true
            default:
                return false
            }
        }
    }

    #if DEBUG
    /// Drive the real libghostty action boundary with a non-NUL-terminated, sentinel-suffixed URL.
    /// The isolated AT-SPI runtime uses this when compositor pointer injection cannot express link hover reliably.
    @MainActor static func exerciseURLAction(_ raw: String) {
        var bytes = raw.utf8.map { CChar(bitPattern: $0) }
        bytes.append(contentsOf: [CChar(bitPattern: 0x58), CChar(bitPattern: 0x59)])
        bytes.withUnsafeMutableBufferPointer { buffer in
            var payload = ghostty_action_u()
            payload.open_url = ghostty_action_open_url_s(
                kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT,
                url: UnsafePointer(buffer.baseAddress),
                len: UInt(raw.utf8.count)
            )
            let action = ghostty_action_s(tag: GHOSTTY_ACTION_OPEN_URL, action: payload)
            _ = shared.handleAction(ghostty_target_s(), action)
        }
    }
    #endif

    /// Apply the shared safe-link policy. Linux has no portable select-in-file-manager API, so a
    /// local file reveal opens its containing directory with the desktop's default file manager.
    private static func openTerminalURL(_ raw: String) {
        let uri: String
        switch LinkPolicy.disposition(for: raw) {
        case .open(let url):
            uri = url.absoluteString
        case .reveal(let url):
            uri = url.deletingLastPathComponent().absoluteString
        case .ignore:
            return
        }
        #if DEBUG
        if let capturePath = ProcessInfo.processInfo.environment["AGTERM_ATSPI_URL_CAPTURE"],
           !capturePath.isEmpty {
            try? uri.write(toFile: capturePath, atomically: true, encoding: .utf8)
        }
        #endif
        uri.withCString { _ = g_app_info_launch_default_for_uri($0, nil, nil) }
    }

    // MARK: - Clipboard (GTK4 reads are async)

    private static func gdkClipboard(for loc: ghostty_clipboard_e) -> OpaquePointer? {
        guard let display = gdk_display_get_default() else { return nil }
        if loc == GHOSTTY_CLIPBOARD_SELECTION {
            return gdk_display_get_primary_clipboard(display)
        }
        return gdk_display_get_clipboard(display)
    }

    private static func readClipboard(_ ud: UnsafeMutableRawPointer?, _ loc: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
        guard let retained = RetainedGhosttySurface(ud) else { return false }
        nonisolated(unsafe) let requestState = state
        runOnMain {
            MainActor.assumeIsolated {
                guard let surface = retained.surface.surface else {
                    retained.release()
                    return
                }
                guard let clipboard = gdkClipboard(for: loc) else {
                    "".withCString { ghostty_surface_complete_clipboard_request(surface, $0, requestState, false) }
                    retained.release()
                    return
                }
                let req = ClipboardRequest(surface: surface, state: requestState, retained: retained)
                gdk_clipboard_read_text_async(
                    clipboard, nil,
                    { source, result, data in
                        let req = Unmanaged<ClipboardRequest>.fromOpaque(data!).takeRetainedValue()
                        defer { req.retained.release() }
                        guard let source else {
                            "".withCString {
                                ghostty_surface_complete_clipboard_request(req.surface, $0, req.state, false)
                            }
                            return
                        }
                        let text = gdk_clipboard_read_text_finish(OpaquePointer(source), result, nil)
                        let raw = text.map { String(cString: $0) } ?? ""
                        // a file-manager copy lands as a file:// uri-list → paste the POSIX paths, like macOS.
                        let value = PasteDecoder.posixPaths(fromURIList: raw) ?? raw
                        value.withCString {
                            ghostty_surface_complete_clipboard_request(req.surface, $0, req.state, false)
                        }
                        if let text { g_free(text) }
                    },
                    Unmanaged.passRetained(req).toOpaque()
                )
            }
        }
        return true
    }

    private static func confirmReadClipboard(_ ud: UnsafeMutableRawPointer?, _ content: UnsafePointer<CChar>?,
                                             _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {
        guard let retained = RetainedGhosttySurface(ud) else { return }
        guard request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ else {
            let text = content.map { String(cString: $0) } ?? ""
            nonisolated(unsafe) let requestState = state
            runOnMain {
                MainActor.assumeIsolated {
                    defer { retained.release() }
                    guard let surface = retained.surface.surface else { return }
                    text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, requestState, true) }
                }
            }
            return
        }
        let text = content.map { String(cString: $0) } ?? ""
        nonisolated(unsafe) let requestState = state
        runOnMain {
            MainActor.assumeIsolated {
                let requester = retained.surface
                guard requester.surface != nil else {
                    retained.release()
                    return
                }
                ClipboardPromptController.shared.request(.read, requester: requester) { allowed in
                    defer { retained.release() }
                    guard let surface = requester.surface else { return }
                    let delivered = allowed ? text : ""
                    delivered.withCString { ghostty_surface_complete_clipboard_request(surface, $0, requestState, true) }
                }
            }
        }
    }

    private static func writeClipboard(_ ud: UnsafeMutableRawPointer?, _ content: UnsafePointer<ghostty_clipboard_content_s>?,
                                       _ len: Int, _ loc: ghostty_clipboard_e, _ confirm: Bool) {
        guard let content, len > 0 else { return }
        var text: String?
        for item in UnsafeBufferPointer(start: content, count: len) {
            guard let data = item.data, let mime = item.mime, String(cString: mime).hasPrefix("text/plain") else { continue }
            text = String(cString: data)
            break
        }
        guard let text else { return }
        guard confirm else { setClipboard(text, loc: loc); return }
        guard let retained = RetainedGhosttySurface(ud) else { return }
        runOnMain {
            MainActor.assumeIsolated {
                let requester = retained.surface
                guard requester.surface != nil else {
                    retained.release()
                    return
                }
                ClipboardPromptController.shared.request(.write, requester: requester) { allowed in
                    defer { retained.release() }
                    if allowed { setClipboard(text, loc: loc) }
                }
            }
        }
    }

    private static func setClipboard(_ text: String, loc: ghostty_clipboard_e) {
        guard let clipboard = gdkClipboard(for: loc) else { return }
        text.withCString { gdk_clipboard_set_text(clipboard, $0) }
    }

    // MARK: - userdata recovery

    @MainActor static func surface(from ud: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        wrapper(from: ud)?.surface
    }
    static func wrapper(from ud: UnsafeMutableRawPointer?) -> GhosttySurface? {
        guard let ud else { return nil }
        return Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
    }
    static func wrapper(fromTarget target: ghostty_target_s) -> GhosttySurface? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
    }

    /// Bundled config defaults select Ghostty's TERM only when its complete resource pair resolved.
    /// User's ~/.config/ghostty/config still wins.
    private static func writeDefaultsConf() -> String? {
        let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("agterm-ghostty-defaults.conf")
        let term = GhosttyResourceResolver.terminalName(resolvedResources: GhosttyApp.shared.resolvedResources)
        let contents = "term = \(term)\n" + GhosttyDefaults.baseConfLines
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Resolve the ghostty resources dir (shell-integration + themes, with the compiled terminfo DB as its
    /// SIBLING) and export `GHOSTTY_RESOURCES_DIR`, so libghostty derives `TERMINFO=dirname(dir)/terminfo`
    /// and injects shell-integration at shell spawn (cwd/title reporting → OSC 7/133). Mirrors the macOS
    /// GhosttyApp.resolveResources(); candidates are the dev env override, the per-user install, then the
    /// system ghostty package.
    private func setGhosttyResourcesEnv() {
        let resolver = GhosttyResourceResolver(candidates: ghosttyResourceCandidates(),
                                               fileExists: { FileManager.default.fileExists(atPath: $0) })
        let resolved = resolver.resolve()
        resolvedResources = resolved
        if let dir = resolved {
            if dir == "/usr/share/ghostty" {
                FileHandle.standardError.write(Data("agterm: using system Ghostty resources at \(dir)\n".utf8))
            }
            setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
        } else {
            unsetenv("GHOSTTY_RESOURCES_DIR")
        }
    }
}

final class ClipboardRequest: @unchecked Sendable {
    let surface: ghostty_surface_t
    let state: UnsafeMutableRawPointer?
    let retained: RetainedGhosttySurface
    init(surface: ghostty_surface_t, state: UnsafeMutableRawPointer?, retained: RetainedGhosttySurface) {
        self.surface = surface
        self.state = state
        self.retained = retained
    }
}

/// Run a closure on the GTK main thread (callbacks may fire off-main).
func runOnMain(_ body: @escaping @Sendable () -> Void) {
    let box = Unmanaged.passRetained(MainClosure(body)).toOpaque()
    g_idle_add({ data in
        let c = Unmanaged<MainClosure>.fromOpaque(data!).takeRetainedValue()
        c.body()
        return 0
    }, box)
}
final class MainClosure: @unchecked Sendable { let body: @Sendable () -> Void; init(_ b: @escaping @Sendable () -> Void) { body = b } }

final class RetainedGhosttySurface: @unchecked Sendable {
    private let retained: Unmanaged<GhosttySurface>

    init?(_ ud: UnsafeMutableRawPointer?) {
        guard let ud else { return nil }
        retained = Unmanaged<GhosttySurface>.fromOpaque(ud).retain()
    }

    @MainActor var surface: GhosttySurface { retained.takeUnretainedValue() }

    func release() {
        retained.release()
    }
}
