// Top-level multi-window state: the shared WindowLibrary (one AppStore per window),
// the live windowID -> AppController registry, the AdwApplication handle (to build new
// windows), and the single control socket. AppController is per-window; `gController`
// (declared in AppController.swift) tracks the frontmost one for global/control routing.
import CGtk
import Foundation
import agtermCore

@MainActor var gLibrary: WindowLibrary!
@MainActor var gWindows: [UUID: AppController] = [:]
@MainActor var gApp: OpaquePointer?
@MainActor let gControlServer = ControlServer()

private struct LinuxSavedWindowSize: Codable {
    let width: Double
    let height: Double
}

@MainActor
private enum LinuxWindowGeometryStore {
    static var url: URL { linuxStateDirectory().appendingPathComponent("window-sizes.json") }

    static func size(for id: UUID) -> WindowGeometry.Size? {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: LinuxSavedWindowSize].self, from: data),
              let value = saved[id.uuidString] else { return nil }
        let requested = WindowGeometry.Size(width: value.width, height: value.height)
        guard let maximum = connectedDisplayMaximumSize() else { return requested }
        return WindowGeometry.clampSize(requested,
                                        min: WindowGeometry.Size(width: 480, height: 320),
                                        max: maximum)
    }

    static func save(_ size: WindowGeometry.Size, for id: UUID) {
        var saved: [String: LinuxSavedWindowSize] = [:]
        if let data = try? Data(contentsOf: url) {
            saved = (try? JSONDecoder().decode([String: LinuxSavedWindowSize].self, from: data)) ?? [:]
        }
        saved[id.uuidString] = LinuxSavedWindowSize(width: size.width, height: size.height)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
    }

    private static func connectedDisplayMaximumSize() -> WindowGeometry.Size? {
        guard let display = gdk_display_get_default(), let monitors = gdk_display_get_monitors(display),
              g_list_model_get_n_items(monitors) > 0,
              let item = g_list_model_get_item(monitors, 0) else { return nil }
        defer { g_object_unref(item) }
        var rect = GdkRectangle()
        gdk_monitor_get_geometry(OpaquePointer(item), &rect)
        return WindowGeometry.Size(width: Double(rect.width), height: Double(rect.height))
    }
}

extension WindowLibrary {
    func geometry(forWindow id: UUID) -> WindowGeometry.Size? { LinuxWindowGeometryStore.size(for: id) }
    func setGeometry(_ size: WindowGeometry.Size, forWindow id: UUID) { LinuxWindowGeometryStore.save(size, for: id) }
}

/// Route an OSC notification from the exact GTK surface that fired it. Suppression happens before the
/// unseen bump, so a pane the user is actively viewing gets neither a banner nor a badge.
@MainActor func routeTerminalNotification(
    origin: LinuxTerminalNotificationOrigin, title: String, body: String
) {
    guard let controller = gWindows[origin.windowID],
          controller.store.session(withID: origin.sessionID) != nil else {
        NotificationManager.send(title: title, body: body)
        return
    }
    let delivery = controller.store.recordTerminalNotification(TerminalNotificationRecord(
        sessionID: origin.sessionID, windowID: origin.windowID, pane: origin.pane,
        title: title, body: body, firingIsFocused: origin.firingIsFocused,
        appActive: origin.appActive))
    guard let delivery else { return }
    controller.refreshSidebar()
    if NotificationManager.bannersEnabled {
        NotificationManager.send(title: delivery.title, body: delivery.body, target: delivery.identity)
    }
}

/// Seed the comment-only starter config files on first launch (never overwriting an existing file), now
/// that each is wired to be effective: `ghostty.conf` (the scoped layer GhosttyApp.buildConfig loads),
/// `keymap.conf` (keymap dispatch), and `restore-denylist.conf` (tmux/screen/zellij, read by the
/// restore-running-command feature). Resolves the config directory once for all three.
@MainActor func ensureStarterFiles() {
    let env = ProcessInfo.processInfo.environment
    let dir = ConfigPaths.configDirectory(setting: linuxSettingsStore().load().configDirectory,
                                           stateDir: env["AGTERM_STATE_DIR"],
                                           home: FileManager.default.homeDirectoryForCurrentUser)
    func ensure(_ path: URL, _ content: @autoclosure () -> String) {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? content().write(to: path, atomically: true, encoding: .utf8)
    }
    ensure(ConfigPaths.ghosttyConfigPath(configDirectory: dir), ConfigPaths.starterGhosttyConfig())
    ensure(ConfigPaths.keymapPath(configDirectory: dir), ConfigPaths.starterKeymapConf())
    ensure(ConfigPaths.restoreDenylistPath(configDirectory: dir), ConfigPaths.starterRestoreDenylist())
}

/// Capture foreground commands (when restore is on), then flush every open window's snapshot + index.
@MainActor func flushOnQuit() {
    guard let library = gLibrary else { return }
    for controller in gWindows.values { controller.commitBackgroundOpacity() }
    if linuxSettingsStore().load().restoreRunningCommand ?? false {
        for ctl in gWindows.values { ctl.captureForegroundCommands() }
    }
    // capture each open window's on-screen size so it restores at the same size on reopen.
    for (id, ctl) in gWindows {
        let w = gtk_widget_get_width(W(ctl.windowPointer))
        let h = gtk_widget_get_height(W(ctl.windowPointer))
        if w > 0, h > 0 { library.setGeometry(WindowGeometry.Size(width: Double(w), height: Double(h)), forWindow: id) }
    }
    // Close out any soft-close grace still running: the quit path does not go through `windowWillClose`,
    // so without this the held records would be dropped with the process — leaking their watermark PNGs and
    // recency entries — and the snapshot below would be written while a finalizer was still pending.
    library.finalizeAllPendingCloses()
    library.saveAllOpen()
    library.saveIndex()
}

/// Open the window for `id` (raise it if already open).
@MainActor func openWindow(_ id: UUID) {
    if let existing = gWindows[id] {
        gtk_window_present(WIN(existing.windowPointer))
        return
    }
    _ = gLibrary.loadStore(for: id)
    gWindows[id] = AppController(app: gApp, windowID: id, library: gLibrary)
}
