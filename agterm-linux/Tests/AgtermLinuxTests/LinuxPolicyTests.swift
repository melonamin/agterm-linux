import CGtk
import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux-owned policy and adapters")
struct LinuxPolicyTests {
    @Test("resource resolution requires complete sibling resources and preserves precedence")
    func resourceResolution() {
        let complete = [
            "/complete/ghostty/shell-integration", "/complete/terminfo/x/xterm-ghostty",
            "/later/ghostty/shell-integration", "/later/terminfo/x/xterm-ghostty"
        ]
        let resolver = GhosttyResourceResolver(
            candidates: ["relative", "/shell-only/ghostty", "/terminfo-only/ghostty",
                         "/complete/ghostty", "/later/ghostty"],
            fileExists: { complete.contains($0) || $0 == "/shell-only/ghostty/shell-integration"
                || $0 == "/terminfo-only/terminfo/x/xterm-ghostty" }
        )
        #expect(resolver.resolve() == "/complete/ghostty")
        #expect(resolver.terminalName == "xterm-ghostty")

        let incomplete = GhosttyResourceResolver(
            candidates: ["", "relative", "/shell-only/ghostty", "/terminfo-only/ghostty"],
            fileExists: { $0 == "/shell-only/ghostty/shell-integration"
                || $0 == "/terminfo-only/terminfo/x/xterm-ghostty" }
        )
        #expect(incomplete.resolve() == nil)
        #expect(incomplete.terminalName == "xterm-256color")
        #expect(GhosttyResourceResolver.terminalName(resolvedResources: "/share/ghostty") == "xterm-ghostty")
    }

    @Test("URI lists become POSIX path payloads")
    func pasteURIList() {
        let payload = "# copied files\nfile:///tmp/one%20two\nfile:///tmp/three\n"
        #expect(PasteDecoder.posixPaths(fromURIList: payload) == "/tmp/one two /tmp/three")
        #expect(ShellEscape.dropPayload("") == nil)
        #expect(ShellEscape.dropPayload("plain") == "plain")
    }

    @Test("Linux proc cmdline decoding is NUL-delimited")
    func procCmdline() {
        #expect(CommandRestore.parseProcCmdline(Data()) == nil)
        #expect(CommandRestore.parseProcCmdline(Data("zsh\0-c\0echo hi\0".utf8)) == ["zsh", "-c", "echo hi"])
    }

    @Test("Linux starter files remain comment-only or denylist-only")
    func starterFiles() {
        #expect(ConfigPaths.starterGhosttyConfig().contains("agterm-scoped ghostty config"))
        #expect(ConfigPaths.starterRestoreDenylist().contains("tmux\nscreen\nzellij"))
        #expect(GhosttyDefaults.baseConfLines.contains("cursor-click-to-move = false"))
        #expect("  value\n".linuxTrimmedOrNil == "value")
        #expect(" \n".linuxTrimmedOrNil == nil)
    }

    @Test("Linux bundled libghostty defaults mirror upstream macOS adapted to Linux conventions")
    func bundledLibghosttyDefaults() {
        let defaults = GhosttyDefaults.baseConfLines
        #expect(defaults.contains("cursor-style = block"))
        #expect(defaults.contains("cursor-click-to-move = false"))
        #expect(defaults.contains("window-padding-x = 8"))
        #expect(defaults.contains("window-padding-y = 6"))
        #expect(defaults.contains("shell-integration-features = no-cursor,no-title"))
        #expect(defaults.contains("keybind = performable:ctrl+shift+key_c=copy_to_clipboard"))
        #expect(defaults.contains("keybind = performable:ctrl+shift+key_v=paste_from_clipboard"))
        #expect(defaults.contains("keybind = performable:ctrl+shift+key_a=select_all"))
        #expect(!defaults.contains("ctrl+shift+c="))
        #expect(!defaults.contains("ctrl+shift+v="))
        #expect(!defaults.contains("ctrl+shift+a="))
    }

    @Test("bundled libghostty defaults parse clean and bind physical C/V/A on any layout")
    func bundledDefaultsParserCoverage() throws {
        // libghostty's config API allocates through process-global state that is undefined
        // until ghostty_init; the app calls it in GhosttyApp.init, tests must call it themselves.
        _ = ghostty_init(0, nil)
        let fm = FileManager.default

        func writeConf(_ contents: String) throws -> String {
            let url = fm.temporaryDirectory
                .appendingPathComponent("agterm-bundled-\(UUID().uuidString).conf")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }

        func buildConfig(layers: [String]) throws -> ghostty_config_t {
            let cfg = try #require(ghostty_config_new())
            for layer in layers {
                let path = try writeConf(layer)
                path.withCString { ghostty_config_load_file(cfg, $0) }
            }
            ghostty_config_finalize(cfg)
            return cfg
        }

        // A Ctrl+Shift key event for a physical XKB keycode, carrying the glyph a Russian
        // ЙЦУКЕН layout produces on that key — the exact event shape a non-Latin layout
        // hands the terminal (the produced character must not affect physical-key binds).
        func ctrlShiftKey(keycode: UInt32, unshifted: UInt32) -> ghostty_input_key_s {
            var event = ghostty_input_key_s()
            event.action = GHOSTTY_ACTION_PRESS
            event.keycode = keycode
            event.mods = ghosttyMods((1 << 0) | (1 << 2)) // GDK_SHIFT | GDK_CONTROL
            event.consumed_mods = GHOSTTY_MODS_NONE
            event.unshifted_codepoint = unshifted
            event.text = nil
            event.composing = false
            return event
        }

        // The baseline isolates the bundled layer's contribution: libghostty's own defaults
        // may add environment diagnostics, so the bundled lines must add ZERO on top of it.
        let baseline = try buildConfig(layers: [""])
        defer { ghostty_config_free(baseline) }
        let baselineDiagnostics = ghostty_config_diagnostics_count(baseline)

        let bundled = try buildConfig(layers: [GhosttyDefaults.baseConfLines])
        defer { ghostty_config_free(bundled) }
        #expect(ghostty_config_diagnostics_count(bundled) == baselineDiagnostics)

        let physicalC = ctrlShiftKey(keycode: 54, unshifted: 0x0441) // с
        let physicalV = ctrlShiftKey(keycode: 55, unshifted: 0x043C) // м
        let physicalA = ctrlShiftKey(keycode: 38, unshifted: 0x0444) // ф
        #expect(ghostty_config_key_is_binding(bundled, physicalC))
        #expect(ghostty_config_key_is_binding(bundled, physicalV))
        #expect(ghostty_config_key_is_binding(bundled, physicalA))

        // A later scoped layer (the agterm-scoped ghostty.conf) can unbind ONE physical
        // default without touching the others: C freed, V/A still bound, no new diagnostics.
        let scoped = try buildConfig(layers: [
            GhosttyDefaults.baseConfLines,
            "keybind = ctrl+shift+key_c=unbind\n",
        ])
        defer { ghostty_config_free(scoped) }
        #expect(ghostty_config_diagnostics_count(scoped) == baselineDiagnostics)
        #expect(!ghostty_config_key_is_binding(scoped, physicalC))
        #expect(ghostty_config_key_is_binding(scoped, physicalV))
        #expect(ghostty_config_key_is_binding(scoped, physicalA))
    }

    @Test("session switcher starts from the previous MRU entry and wraps")
    func sessionSwitcher() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var switcher = SessionSwitcherModel()
        #expect(switcher.begin([first]) == nil)
        #expect(switcher.begin([first, second, third]) == second)
        #expect(switcher.advance(reverse: true) == first)
        #expect(switcher.advance(reverse: true) == third)
        #expect(switcher.advance() == first)
        switcher.end()
        #expect(!switcher.isActive)
    }

    @Test("delete prompts use native Linux wording")
    func deletePrompts() {
        #expect(DeletePrompt.workspaceMessage(name: "work", sessions: 1).contains("1 session"))
        #expect(DeletePrompt.workspaceMessage(name: "work", sessions: 2).contains("2 sessions"))
        #expect(DeletePrompt.windowMessage(name: "work").contains("all its workspaces and sessions"))
    }

    @Test("session reports and pane focus mutate the owning shared model")
    @MainActor
    func sessionAdapters() {
        let session = Session(initialCwd: "/start")
        session.hasSplit = true
        let store = AppStore(workspaces: [Workspace(name: "work", sessions: [session])])

        #expect(store.recordPwd("/main", forSession: session.id, isSplit: false))
        #expect(store.recordPwd("/split", forSession: session.id, isSplit: true))
        #expect(store.recordTitle("main", forSession: session.id, isSplit: false))
        #expect(store.recordTitle("split", forSession: session.id, isSplit: true))
        #expect(!store.recordPwd("/main", forSession: session.id, isSplit: false))
        #expect(!store.recordTitle("split", forSession: session.id, isSplit: true))
        store.setPaneFocus(true, forSession: session.id)

        #expect(session.currentCwd == "/main")
        #expect(session.splitCwd == "/split")
        #expect(session.oscTitle == "main")
        #expect(session.splitTitle == "split")
        #expect(session.splitFocused)
        #expect(LinuxSidebarPolicy.flaggedRowLabel(for: session, in: store) == "main  —  work")
    }

    @Test("sidebar CSS derives row height from the shared font-size clamp")
    func sidebarCSS() {
        let standard = LinuxSidebarPolicy.sidebarCSS(fontSize: 13)
        #expect(standard.contains(".agterm-sidebar label { font-size: 13.0pt; }"))
        // The full selector, closing brace included, pins the exact libadwaita rule being lowered.
        #expect(standard.contains(".agterm-sidebar .navigation-sidebar > row { min-height: 28px; }"))
        // Only the row rule may be emitted: Adwaita's inner-box rule is AdwSidebar-scoped and never
        // matches this port's widget tree, so an override there would be inert CSS.
        #expect(!standard.contains("> row > box"))
        // nil means "unset", which resolves to the same shared default as an explicit 13pt.
        #expect(LinuxSidebarPolicy.sidebarCSS(fontSize: nil) == standard)

        let dense = LinuxSidebarPolicy.sidebarCSS(fontSize: 9)
        #expect(dense.contains("font-size: 9.0pt;"))
        #expect(dense.contains("> row { min-height: 24px; }"))

        let large = LinuxSidebarPolicy.sidebarCSS(fontSize: 20)
        #expect(large.contains("font-size: 20.0pt;"))
        #expect(large.contains("> row { min-height: 35px; }"))

        // A hand-edited fractional size keeps its exact point value while the row height rounds.
        let fractional = LinuxSidebarPolicy.sidebarCSS(fontSize: 13.6)
        #expect(fractional.contains("font-size: 13.6pt;"))
        #expect(fractional.contains("> row { min-height: 29px; }"))

        // Out-of-range values clamp to the shared bounds rather than emitting a degenerate row.
        #expect(LinuxSidebarPolicy.sidebarCSS(fontSize: 40) == large)
        #expect(LinuxSidebarPolicy.sidebarCSS(fontSize: 2) == dense)
    }

    @Test("the clamp pins the derived sidebar floor inside the shared width range")
    @MainActor
    func clampSidebarWidth() {
        // `refreshSidebarWidthFloor`'s call: the measured content minimum, pinned at the shared default.
        func floor(_ measured: Double) -> Double {
            LinuxSidebarPolicy.clampSidebarWidth(measured, minimum: AppStore.sidebarWidthDefault)
        }
        // Content the pin already holds keeps the pin, so a fresh window's 220px stays reachable.
        for measured in [0.0, 181, AppStore.sidebarWidthDefault] {
            #expect(floor(measured) == AppStore.sidebarWidthDefault)
        }
        // …and follows the measurement once the chrome no longer fits inside it.
        #expect(floor(229) == 229)
        #expect(floor(255) == 255)
        // The cap is a CAP, not a fall back to the pin; a floor above the max could never settle.
        #expect(floor(900) == AppStore.sidebarWidthMax)
        // The other caller's shape: an observed drag clamped against the start child's own minimum.
        #expect(LinuxSidebarPolicy.clampSidebarWidth(160, minimum: 310) == 310)
        #expect(LinuxSidebarPolicy.clampSidebarWidth(900, minimum: 310) == AppStore.sidebarWidthMax)
    }

    @Test("a floor-driven divider move is not persisted, so the requested width survives it")
    @MainActor
    func persistedSidebarWidth() {
        // `minimum` is the EFFECTIVE minimum measured off the paned start child, not the content floor;
        // the default maximum is the `G_MAXINT` a paned reports before its first allocation.
        func persisted(observed: Double, requested: Double, minimum: Double,
                       layoutMaximum: Double = Double(Int32.max)) -> Double? {
            LinuxSidebarPolicy.persistedSidebarWidth(observed: observed, requested: requested,
                                                     minimum: minimum, layoutMaximum: layoutMaximum)
        }
        // A minimum that rose past the saved width clamps the divider up; persisting that overwrites
        // the request for good, since nothing pulls the divider back when the minimum drops again.
        #expect(persisted(observed: 250, requested: 220, minimum: 250) == nil)
        #expect(persisted(observed: 220, requested: 160, minimum: 220) == nil)
        // The same for the header's window controls raising the start child above the content floor.
        #expect(persisted(observed: 235, requested: 220, minimum: 235) == nil)

        // A real drag is anything the layout did not produce — wider, or down onto the floor itself.
        #expect(persisted(observed: 300, requested: 220, minimum: 220) == 300)
        #expect(persisted(observed: 220, requested: 300, minimum: 220) == 220)
        #expect(persisted(observed: 250, requested: 300, minimum: 250) == 250)
        // A drag past the shared maximum records the maximum, which the caller also lays out at.
        #expect(persisted(observed: 900, requested: 300, minimum: 220) == AppStore.sidebarWidthMax)
        // Sub-pixel jitter around the standing request is not a drag.
        #expect(persisted(observed: 220.4, requested: 220, minimum: 220) == nil)

        // The `max-position` leg: a narrowed window's cap is not a drag; a drag below it still is, and
        // a maximum above the standing request never masks one.
        #expect(persisted(observed: 349, requested: 400, minimum: 220, layoutMaximum: 349) == nil)
        #expect(persisted(observed: 300, requested: 400, minimum: 220, layoutMaximum: 349) == 300)
        #expect(persisted(observed: 349, requested: 400, minimum: 220, layoutMaximum: 900) == 349)

        // A minimum above the shared maximum is a LAYOUT constraint: no request there is honourable, so
        // every position would read as a drag and the write-back would destroy the request.
        #expect(persisted(observed: 700, requested: 220, minimum: 700) == nil)
        // The boundary itself stays live — these two pin the guard as `<=`; only the second survives `<`.
        #expect(persisted(observed: 300, requested: 220,
                          minimum: AppStore.sidebarWidthMax) == AppStore.sidebarWidthMax)
        #expect(persisted(observed: AppStore.sidebarWidthMax, requested: 220,
                          minimum: AppStore.sidebarWidthMax) == nil)
    }

    @Test("the divider is laid out at the request the floor and the window width both allow")
    @MainActor
    func laidOutSidebarWidth() {
        func laidOut(requested: Double, minimum: Double, layoutMaximum: Double) -> Double {
            LinuxSidebarPolicy.laidOutSidebarWidth(requested: requested, minimum: minimum,
                                                   layoutMaximum: layoutMaximum)
        }
        // A wide enough window: the request stands, raised by the minimum and capped by the shared max.
        #expect(laidOut(requested: 400, minimum: 220, layoutMaximum: 899) == 400)
        #expect(laidOut(requested: 160, minimum: 220, layoutMaximum: 899) == 220)
        #expect(laidOut(requested: 900, minimum: 220, layoutMaximum: 899)
            == AppStore.sidebarWidthMax)
        // Narrowed past the request, the window wins — the LOAD-BEARING leg, without which the
        // `notify::max-position` handler re-asserts an over-wide position and the sidebar overhangs.
        #expect(laidOut(requested: 400, minimum: 220, layoutMaximum: 349) == 349)
        // All three readings of "no window cap yet"; `.infinity` must never reach `set_position`.
        for unbounded in [Double(Int32.max), 0, -1] {
            #expect(laidOut(requested: 400, minimum: 220, layoutMaximum: unbounded) == 400)
        }
    }

    @Test("notification delivery delegates policy and identity to shared core")
    @MainActor
    func notificationDelivery() {
        let session = Session(initialCwd: "/tmp")
        let store = AppStore(workspaces: [Workspace(name: "work", sessions: [session])])
        let windowID = UUID()
        let delivery = store.recordTerminalNotification(TerminalNotificationRecord(
            sessionID: session.id,
            windowID: windowID,
            pane: .split,
            title: "done",
            body: "ready",
            firingIsFocused: false,
            appActive: true
        ))

        #expect(session.unseenCount == 1)
        #expect(delivery?.identity == TerminalNotification.identity(
            windowID: windowID,
            sessionID: session.id,
            pane: .split
        ))
    }

    @Test("focused OSC suppression precedes unseen mutation while explicit control delivery bypasses it")
    @MainActor
    func notificationSuppressionOrdering() {
        let session = Session(initialCwd: "/tmp")
        let store = AppStore(workspaces: [Workspace(name: "work", sessions: [session])])
        let windowID = UUID()

        let suppressed = store.recordTerminalNotification(TerminalNotificationRecord(
            sessionID: session.id, windowID: windowID, pane: .main,
            title: "focused", body: "ignored", firingIsFocused: true, appActive: true))
        #expect(suppressed == nil)
        #expect(session.unseenCount == 0)

        let inactive = store.recordTerminalNotification(TerminalNotificationRecord(
            sessionID: session.id, windowID: windowID, pane: .main,
            title: "inactive", body: "delivered", firingIsFocused: true, appActive: false))
        #expect(inactive != nil)
        #expect(session.unseenCount == 1)

        let explicitControl = store.recordTerminalNotification(TerminalNotificationRecord(
            sessionID: session.id, windowID: windowID, pane: .main,
            title: "control", body: "requested", firingIsFocused: false, appActive: true))
        #expect(explicitControl != nil)
        #expect(session.unseenCount == 2)
    }

    @Test("Linux surface roles map every terminal kind deliberately")
    func surfaceNotificationRoles() {
        #expect(LinuxSurfaceRole.main.notificationPane == .main)
        #expect(LinuxSurfaceRole.split.notificationPane == .split)
        #expect(LinuxSurfaceRole.overlay.notificationPane == .overlay)
        #expect(LinuxSurfaceRole.scratch.notificationPane == .overlay)
        #expect(LinuxSurfaceRole.quick.notificationPane == nil)
        #expect(LinuxSurfaceRole.overlay.notificationPane(liveOverlayPane: .left) == .main)
        #expect(LinuxSurfaceRole.overlay.notificationPane(liveOverlayPane: .right) == .split)
        #expect(LinuxSurfaceRole.overlay.notificationPane(liveOverlayPane: nil) == .overlay)
        #expect(LinuxSurfaceRole.scratch.statusPane == .scratch)
    }

    @Test("HUD presentation is passive while program overlays remain interactive")
    @MainActor
    func floatingOverlayInputPolicy() {
        #expect(!AppController.floatingOverlayTargetable(isHud: true))
        #expect(AppController.floatingOverlayTargetable(isHud: false))
        #expect(!AppController.floatingOverlayFocusable(isHud: true))
        #expect(AppController.floatingOverlayFocusable(isHud: false))
        #expect(AppController.floatingFrameOpacity(quickVisible: true, dimmed: 0.55) == 0.55)
        #expect(AppController.floatingFrameOpacity(quickVisible: false, dimmed: 0.55) == 1)
    }

    @Test("HUD geometry refreshes once per positive deck allocation")
    @MainActor
    func hudGeometryRefreshPolicy() {
        #expect(!AppController.hudGeometryNeedsRefresh(previous: nil, width: 0, height: 400))
        #expect(AppController.hudGeometryNeedsRefresh(previous: nil, width: 640, height: 400))
        #expect(!AppController.hudGeometryNeedsRefresh(previous: (640, 400), width: 640, height: 400))
        #expect(AppController.hudGeometryNeedsRefresh(previous: (640, 400), width: 600, height: 400))
    }

    @Test("HUD layout uses the stable session font before settings or defaults")
    @MainActor
    func hudFontPolicy() {
        #expect(AppController.hudFontSize(sessionFontSize: 17, settingsFontSize: 15) == 17)
        #expect(AppController.hudFontSize(sessionFontSize: nil, settingsFontSize: 15) == 15)
        #expect(AppController.hudFontSize(sessionFontSize: nil, settingsFontSize: nil)
                == DashboardLayout.ghosttyDefaultFontSize)
    }

    @Test("deferred workspace row clicks re-read the current setting")
    @MainActor
    func workspaceRowTogglePolicy() {
        #expect(AppController.workspaceRowToggleEnabled(nil))
        #expect(AppController.workspaceRowToggleEnabled(true))
        #expect(!AppController.workspaceRowToggleEnabled(false))
    }

    @Test("pane identities coalesce independently and stale reveal panes fall back safely")
    func notificationIdentityAndReveal() {
        let windowID = UUID()
        let sessionID = UUID()
        let main = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: .main)
        let split = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: .split)
        let overlay = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: .overlay)
        #expect(Set([main, split, overlay]).count == 3)
        #expect(NotificationManager.notificationID(main) != NotificationManager.notificationID(split))
        #expect(LinuxNotificationRevealFocus.resolve(
            pane: .split, sessionExists: true, hasSplit: true, coverActive: false) == .split)
        #expect(LinuxNotificationRevealFocus.resolve(
            pane: .split, sessionExists: true, hasSplit: false, coverActive: false) == .primary)
        #expect(LinuxNotificationRevealFocus.resolve(
            pane: .overlay, sessionExists: true, hasSplit: false, coverActive: true) == .overlay)
        #expect(LinuxNotificationRevealFocus.resolve(
            pane: .overlay, sessionExists: true, hasSplit: false, coverActive: false) == .primary)
        #expect(LinuxNotificationRevealFocus.resolve(
            pane: .main, sessionExists: false, hasSplit: false, coverActive: false) == nil)
    }
}
