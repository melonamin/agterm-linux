// agterm-linux entry point: an Adwaita application whose window is built by
// AppController (workspace -> session sidebar + a stable GtkOverlay terminal deck driven
// by agtermCore's AppStore).
import CGtk
import Foundation
import agtermCore

/// Generic GObject pointer cast: some GTK/Adw types import as distinct typed
/// pointers; all are layout-compatible, so reinterpret the stored handle.
@inline(__always) func cast<T>(_ p: OpaquePointer?) -> UnsafeMutablePointer<T>? { p.map { UnsafeMutablePointer($0) } }

@main
struct AgtermApp {
    static func main() {
        // AGTERM_APP_ID overrides the GApplication id so a dev/test instance registers separately on
        // the session bus and runs ALONGSIDE a deployed one (the Linux analogue of the macOS .debug
        // bundle id) instead of forwarding its launch to the running instance.
        let appID = ProcessInfo.processInfo.environment["AGTERM_APP_ID"] ?? LinuxAppMetadata.applicationID
        // HANDLES_OPEN (1<<2): route a dir/file arg to the `open` signal (agterm-linux <dir> → a session
        // there) instead of erroring on unknown args; no-arg launches still fire `activate`.
        let app = OpaquePointer(adw_application_new(appID, GApplicationFlags(rawValue: 4)))
        connect(app, "activate", unsafeBitCast(onActivate, to: GCallback.self), nil)
        connect(app, "open", unsafeBitCast(onOpen, to: GCallback.self), nil)
        connect(app, "shutdown", unsafeBitCast(onShutdown, to: GCallback.self), nil)
        let status = g_application_run(GAPP(app), CommandLine.argc, CommandLine.unsafeArgv)
        exit(status)
    }
}

private let onActivate: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { app, _ in
    MainActor.assumeIsolated { activateApplication(app) }
}

/// The `open` signal (G_APPLICATION_HANDLES_OPEN): `agterm-linux <dir> [<dir>…]` — first launch OR a
/// second launch forwarded to the running single instance — opens a session per path in the frontmost
/// window (a file arg → its parent dir), then raises that window. Routes through the SAME setup as
/// activate, so a cold `agterm-linux <dir>` boots the app and lands in the directory.
private let onOpen: @MainActor @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?, gint, UnsafePointer<CChar>?, gpointer?) -> Void = { app, files, nFiles, _, _ in
    MainActor.assumeIsolated {
        activateApplication(app)   // ensure setup + a window (or raise the already-running instance)
        guard let files, nFiles > 0,
              let id = gLibrary.frontmostWindowID ?? gLibrary.windows.first?.id,
              let ctl = gWindows[id] else { return }
        for i in 0..<Int(nFiles) {
            guard let f = files[i], let cpath = g_file_get_path(f) else { continue }
            let path = String(cString: cpath); g_free(cpath)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            let cwd = (exists && isDir.boolValue) ? path : (path as NSString).deletingLastPathComponent
            ctl.createSessionInDirectory(cwd)
        }
        gtk_window_present(WIN(ctl.windowPointer))
    }
}

/// First-time application setup (idempotent — a second activate/open raises the frontmost instead): the
/// reveal action, the WindowLibrary, the starter config files, app CSS/icons, the control server, the
/// quit-signal handlers, the color-scheme tracker, saved windows, then appearance reconciliation.
/// Shared by `activate`+`open`.
@MainActor func activateApplication(_ app: OpaquePointer?) {
    // A second launch (or any re-activate) of the single-instance GApplication fires activate again:
    // raise the frontmost window instead of no-op'ing, so launching agterm while it runs focuses it.
    if gLibrary != nil {
        let id = gLibrary.frontmostWindowID ?? gLibrary.windows.first?.id
        if let id, let ctl = gWindows[id] { gtk_window_present(WIN(ctl.windowPointer)) }
        return
    }
    gApp = app
    // Route every deferred main-actor job (MainTimer) through g_timeout_add BEFORE any store or
    // controller exists — see `agterm-linux/docs/main-loop.md`.
    installGLibMainTimer()
    let stateDirectory = linuxStateDirectory()
    let settingsStore = linuxSettingsStore()
    let currentSettings = settingsStore.load()
    let welcomeDue = FirstRunWelcome.isDue(
        welcomeShown: currentSettings.welcomeShown,
        hasPriorState: FirstRunWelcome.hasPriorState(in: stateDirectory))
    let appearanceSide = LinuxAppearanceSide(isDark: AppController.systemIsDark)
    GhosttyApp.shared.start(appearanceSide: appearanceSide)
    // The notification click-to-reveal target: an `app.reveal` action carrying a session-id string.
    let revealAction = g_simple_action_new("reveal", g_variant_type_new("s"))
    connect(revealAction, "activate", unsafeBitCast(onRevealAction as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
    g_action_map_add_action(app, revealAction)
    gLibrary = WindowLibrary(directory: linuxStateDirectory())
    ensureStarterFiles()
    installAppCSS()
    installStatusColorCSS()
    installAppIcons()
    gControlServer.start()
    // Quit cleanly on SIGTERM/SIGINT (session logout, `kill`, Ctrl+C) so flushOnQuit captures the
    // foreground commands + snapshot — without this a signal kills the process and loses the capture
    // (the macOS path runs through applicationWillTerminate). g_application_quit emits "shutdown".
    _ = g_unix_signal_add(SIGTERM, onQuitSignal, nil)
    _ = g_unix_signal_add(SIGINT, onQuitSignal, nil)
    // Re-push the system light/dark scheme to live surfaces whenever it changes.
    connect(adw_style_manager_get_default(), "notify::dark",
            unsafeBitCast(onColorSchemeChanged, to: GCallback.self), nil)
    let ids = gLibrary.openIDs()
    let toOpen = ids.isEmpty ? [gLibrary.windows.first?.id].compactMap { $0 } : ids
    for id in toOpen { openWindow(id) }
    if let controller = gWindows.values.first {
        _ = controller.reloadConfigForAppearanceChange(appearanceSide)
    }
    if welcomeDue,
       ProcessInfo.processInfo.environment["AGTERM_ATSPI_OPEN_PREFERENCES"] == nil,
       let id = toOpen.first, let controller = gWindows[id] {
        var settings = currentSettings
        settings.welcomeShown = true
        try? settingsStore.save(settings)
        controller.showFirstRunWelcome()
    }
    #if DEBUG
    if let rawURL = ProcessInfo.processInfo.environment["AGTERM_ATSPI_OPEN_URL"], !rawURL.isEmpty {
        GhosttyApp.exerciseURLAction(rawURL)
    }
    // AT-SPI cannot focus an arbitrary Wayland client on compositors such as Hyprland. Present the
    // isolated smoke-test dialog during activation, while the initial surface is still being mapped,
    // so libadwaita exposes its pages without requiring compositor-specific pointer automation.
    if let pageName = ProcessInfo.processInfo.environment["AGTERM_ATSPI_OPEN_PREFERENCES"],
       let page = LinuxSettingsPage(rawValue: pageName),
       let id = gLibrary.frontmostWindowID ?? gLibrary.windows.first?.id {
        gWindows[id]?.showSettings(page: page)
    }
    #endif
}

func linuxStateDirectory() -> URL {
    if let path = ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return PersistenceStore.defaultDirectory
}

func linuxSettingsStore() -> SettingsStore {
    SettingsStore(directory: linuxStateDirectory())
}

/// On clean quit: capture each pane's foreground command (when restore is enabled), then flush every
/// open window's snapshot — AppStore only saves on structural mutations, so a live `cd` since the last
/// one would otherwise be lost.
private let onShutdown: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated {
        colorSchemeChangeDebouncer.cancel()
        flushOnQuit()
    }
}

/// Install the app-wide CSS once: the `.agterm-blink` keyframe animation that pulses an in-progress
/// agent-status glyph (the `AgentIndicator.blink` cue). Added at the application priority so it layers
/// over the theme without overriding user CSS.
@MainActor private func installAppCSS() {
    guard let display = gdk_display_get_default() else { return }
    let provider = gtk_css_provider_new()
    let css = """
    .agterm-blink { animation: agterm-blink-pulse 1.2s ease-in-out infinite; }
    /* one selector per keyframe: GTK 4.14's _gtk_css_keyframes_parse takes a single progress value and then
       expects the block, so a `0%, 100%` list is a parse error there - and GTK drops @keyframes silently */
    @keyframes agterm-blink-pulse { 0% { opacity: 1; } 50% { opacity: 0.25; } 100% { opacity: 1; } }
    window.agterm-translucent { background-color: transparent; }   /* terminal translucency: ghostty's alpha reaches the compositor */
    \(LinuxQuickCardPolicy.cardCSS)
    .agterm-switcher { background-color: alpha(#1e2228, 0.96); padding: 10px; border-radius: 10px; border: 1px solid alpha(#ffffff, 0.12); }
    .agterm-switcher label { padding: 3px 0; opacity: 0.6; }
    .agterm-switcher label.agterm-switcher-current { opacity: 1; font-weight: bold; }
    .agterm-gl-error { color: #ffffff; background-color: alpha(#1e2228, 0.96); padding: 24px; border-radius: 10px; border: 1px solid alpha(#e5a50a, 0.5); }
    .agterm-dashboard { background-color: @window_bg_color; }
    .agterm-modal-header { border-bottom: 1px solid alpha(@window_fg_color, 0.12); }
    .agterm-dashboard-cell { border: 2px solid alpha(@window_fg_color, 0.16); border-radius: 10px; background-color: @view_bg_color; }
    .agterm-dashboard-cell.selected { border-color: @accent_color; box-shadow: 0 0 0 2px alpha(@accent_color, 0.35); }
    .agterm-dashboard-caption { background-color: alpha(@window_bg_color, 0.9); color: @window_fg_color; padding: 4px 8px; border-radius: 8px; }
    .agterm-palette-badge { font-size: 0.8em; padding: 1px 6px; border-radius: 6px; background-color: alpha(@window_fg_color, 0.14); color: alpha(@window_fg_color, 0.7); }  /* keymap-command pill */
    .agterm-sidebar #workspace-row .workspace-add-session { opacity: 0; }
    .agterm-sidebar #workspace-row:hover .workspace-add-session { opacity: 1; }
    /* trailing inset inside the selection highlight (the row's content box paints it, so a box margin would indent the highlight itself) */
    .agterm-session-row-content { padding-right: 6px; }
    """
    css.withCString { gtk_css_provider_load_from_string(provider, $0) }
    // GTK_STYLE_PROVIDER_PRIORITY_APPLICATION = 600; the macro cast isn't available in Swift, the
    // GtkCssProvider pointer is passed straight through as the GtkStyleProvider.
    gtk_style_context_add_provider_for_display(display, OpaquePointer(provider), 600)
}

@MainActor private var gStatusColorProvider: OpaquePointer?

/// Apply the agent-status glyph colors from settings (nil = the Adwaita defaults) via a dedicated,
/// reloadable provider above the app CSS — re-callable when the Settings color pickers change them.
@MainActor func installStatusColorCSS() {
    guard let display = gdk_display_get_default() else { return }
    let s = linuxSettingsStore().load()
    let css = """
    .agterm-status-blocked { color: \(s.blockedStatusColorHex ?? "#e5a50a"); }
    .agterm-status-completed { color: \(s.completedStatusColorHex ?? "#2ec27e"); }
    .agterm-status-active { color: \(s.activeStatusColorHex ?? "#DBD9E6"); }
    """
    if gStatusColorProvider == nil {
        let p = OpaquePointer(gtk_css_provider_new())
        gStatusColorProvider = p
        gtk_style_context_add_provider_for_display(display, p, 650)   // above the app CSS (600)
    }
    if let p = gStatusColorProvider { css.withCString { gtk_css_provider_load_from_string(cast(p), $0) } }
}

/// Custom symbolic icon search paths, highest priority first. The dist tarball ships them under
/// `<bundle>/share/icons`; dev runs can point `AGTERM_ICON_RESOURCES` at `agterm-linux/Resources/icons`,
/// or fall back to the common repo-root / package-root working directories.
nonisolated private func iconResourceCandidates() -> [String] {
    let env = ProcessInfo.processInfo.environment
    var candidates: [String] = []
    if let override = env["AGTERM_ICON_RESOURCES"], !override.isEmpty { candidates.append(override) }
    if let arg0 = CommandLine.arguments.first, !arg0.isEmpty {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let raw = URL(fileURLWithPath: arg0)
        let executable = raw.path.hasPrefix("/") ? raw : cwd.appendingPathComponent(arg0)
        let bundleRoot = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(bundleRoot.appendingPathComponent("share/icons", isDirectory: true).path)
    }
    let cwd = FileManager.default.currentDirectoryPath
    candidates.append((cwd as NSString).appendingPathComponent("Resources/icons"))
    candidates.append((cwd as NSString).appendingPathComponent("agterm-linux/Resources/icons"))
    return candidates
}

/// Register the custom symbolic icons (the macOS-matching toolbar glyphs: split / scratch / quick /
/// new-workspace / new-session / flag) by adding their directory to the icon theme. Installed builds
/// can also resolve them from the user's hicolor theme (see scripts/install-linux.sh).
@MainActor private func installAppIcons() {
    guard let display = gdk_display_get_default() else { return }
    let theme = gtk_icon_theme_get_for_display(display)
    for iconsDir in iconResourceCandidates() where FileManager.default.fileExists(atPath: iconsDir) {
        iconsDir.withCString { gtk_icon_theme_add_search_path(theme, $0) }
    }
}

@MainActor private let colorSchemeChangeDebouncer = Debouncer()
private let colorSchemeChangeDebounceInterval: TimeInterval = 0.05

@MainActor private func colorSchemeReloadContext() -> AppearanceReloadContext {
    let settings = linuxSettingsStore().load()
    return AppearanceReloadContext(
        followsSystemAppearance: settings.followSystemAppearance == true,
        hasLightSlot: settings.theme != nil,
        hasDarkSlot: settings.darkTheme != nil,
        currentSide: LinuxAppearanceSide(isDark: AppController.systemIsDark)
    )
}

private let onColorSchemeChanged: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, _, _ in
    MainActor.assumeIsolated {
        colorSchemeChangeDebouncer.schedule(after: colorSchemeChangeDebounceInterval) {
            let context = colorSchemeReloadContext()
            let plan = gAppearanceReloadPolicy.plan(for: context)
            synchronizeLiveColorScheme(plan.side)
            guard plan.requiresConfigReload else { return }
            guard let controller = gWindows.values.first,
                  controller.reloadConfigForAppearanceChange(plan.side) else { return }
            for ctl in gWindows.values { ctl.rebuildSettingsForColorSchemeChange() }
        }
    }
}

/// SIGTERM/SIGINT → quit the GApplication on the main loop so its "shutdown" handler (flushOnQuit) runs.
/// Returns G_SOURCE_REMOVE (the signal source is one-shot — the app is on its way out).
private let onQuitSignal: @MainActor @convention(c) (gpointer?) -> gboolean = { _ in
    MainActor.assumeIsolated { if let app = gApp { g_application_quit(GAPP(app)) } }
    return 0
}

/// The `app.reveal` action handler: a clicked notification fires this with the pane-qualified identity
/// (`window:session:pane`) or, for older/plain notifications, just the session id.
private let onRevealAction: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, param, _ in
    guard let param, let cstr = g_variant_get_string(param, nil) else { return }
    let target = String(cString: cstr)
    MainActor.assumeIsolated {
        if let parsed = TerminalNotification.parseIdentity(target) {
            revealSession(parsed.sessionID, windowID: parsed.windowID, pane: parsed.pane)
        } else if let id = UUID(uuidString: target) {
            revealSession(id)
        }
    }
}

/// Reveal a notification target, reopening its encoded window when needed. Legacy session-only targets
/// still search open windows. Unknown windows, sessions, and vanished split/overlay panes are safe no-ops
/// or fall back to the primary pane.
@MainActor func revealSession(_ id: UUID, windowID: UUID? = nil, pane: PaneRole = .main) {
    let controller: AppController?
    if let windowID {
        guard gLibrary.windows.contains(where: { $0.id == windowID }) else { return }
        openWindow(windowID)
        controller = gWindows[windowID]
    } else {
        controller = gWindows.values.first { $0.store.session(withID: id) != nil }
    }
    guard let controller else { return }
    let session = controller.store.session(withID: id)
    guard let focus = LinuxNotificationRevealFocus.resolve(
        pane: pane, sessionExists: session != nil,
        hasSplit: session?.hasSplit ?? false,
        coverActive: (session?.overlayActive ?? false) || (session?.scratchActive ?? false)
    ), let session else { return }
    let wantSplit = focus == .split
    session.splitFocused = wantSplit
    gtk_window_present(WIN(controller.windowPointer))
    controller.selectSession(id)
    if focus == .overlay,
       let cover = session.overlayActive ? controller.overlaySurfaces[id] : controller.scratchSurfaces[id] {
        cover.grabFocus()
    } else if session.hasSplit {
        controller.focusPane(left: !wantSplit)
    } else {
        controller.surfaces[id]?.grabFocus()
    }
}

/// Reconcile the Linux auto-follow selection into GTK without raising or focusing a background
/// window. A covering scratch terminal is hidden when the blocked status belongs to a regular pane.
@MainActor func handleAutoFollow(_ id: UUID?, statusPane: StatusPane?) {
    guard let id, let windowID = gLibrary.windowID(forSession: id),
          let controller = gWindows[windowID],
          let session = controller.store.session(withID: id) else { return }
    // The selection made by AppStore stands, but terminal zoom owns the visible surface. Do not mutate
    // scratch visibility or split focus behind that layer; the selected session appears when zoom exits.
    guard controller.terminalZoom.target == nil else {
        controller.syncSidebarSelection()
        controller.updateTitle()
        controller.refreshSidebar()
        return
    }
    // Prefer the coordinator's pre-selection snapshot. An auto-reset indicator is cleared by
    // AppStore.selectSession before this host-side reconciliation runs.
    switch statusPane ?? session.agentIndicator.statusPane ?? .left {
    case .left:
        if session.scratchActive { controller.store.toggleScratch(id) }
        if session.hasSplit { controller.store.setPaneFocus(false, forSession: id) }
    case .right:
        if session.scratchActive { controller.store.toggleScratch(id) }
        if session.hasSplit { controller.store.setPaneFocus(true, forSession: id) }
    case .scratch:
        if !session.scratchActive { controller.store.toggleScratch(id) }
    }
    // Quick is a visible terminal overlay with its own first responder. Reconcile the selection beneath
    // it, but do not steal keyboard focus from the terminal the user can actually see.
    let shouldFocus = !controller.quickVisible
        && gtk_window_is_active(WIN(controller.windowPointer)) != 0
    controller.reconcile(focusActive: shouldFocus)
}
