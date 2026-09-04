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

    @Test("Linux session home honors an isolated launch environment")
    func defaultSessionHome() {
        #expect(ConfigPaths.defaultNewSessionCwd(environment: ["HOME": "/tmp/agterm-home"])
            == "/tmp/agterm-home")
        #expect(ConfigPaths.defaultNewSessionCwd(environment: ["HOME": ""])
            == FileManager.default.homeDirectoryForCurrentUser.path)
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
        switcher.begin([first])
        #expect(!switcher.isActive)
        switcher.begin([first, second, third])
        #expect(switcher.current == second)
        switcher.advance(reverse: true)
        #expect(switcher.current == first)
        switcher.advance(reverse: true)
        #expect(switcher.current == third)
        switcher.advance()
        #expect(switcher.current == first)
        switcher.end()
        #expect(!switcher.isActive)
    }

    @Test("Ctrl release commits the highlighted candidate, or nothing")
    func sessionSwitcherCommitTarget() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let live: Set<UUID> = [first, second, third]
        var switcher = SessionSwitcherModel()
        #expect(switcher.commitTarget(liveIDs: live) == nil)
        switcher.begin([first])
        #expect(switcher.commitTarget(liveIDs: live) == nil)

        switcher.begin([first, second, third])
        #expect(switcher.commitTarget(liveIDs: live) == second)
        switcher.advance()
        #expect(switcher.commitTarget(liveIDs: live) == third)
        #expect(switcher.commitTarget(liveIDs: live.subtracting([third])) == nil)
        switcher.advance(reverse: true)
        #expect(switcher.commitTarget(liveIDs: live) == second)

        switcher.end()
        switcher.end()
        #expect(!switcher.isActive)
        #expect(switcher.commitTarget(liveIDs: live) == nil)
    }

    @Test("the commit waits for the last held Ctrl key")
    func heldControlKeys() {
        let left: UInt32 = 37
        let right: UInt32 = 105
        let tab: UInt32 = 23
        let control = ModifierKeyMods.controlBit
        var held = HeldControlKeys()

        held.pressed(keyval: 0xFFE3, keycode: left, state: 0)
        held.pressed(keyval: 0xFFE4, keycode: right, state: control)
        held.pressed(keyval: 0xFF09, keycode: tab, state: control)
        var commits = held.released(keycode: right, controlStillHeld: true)
        #expect(!commits)
        commits = held.released(keycode: left, controlStillHeld: false)
        #expect(commits)

        // A key up lost to a blur strands `left`; the next press without Ctrl resyncs it away.
        held.pressed(keyval: 0xFFE3, keycode: left, state: 0)
        held.pressed(keyval: 0xFF09, keycode: tab, state: 0)
        held.pressed(keyval: 0xFFE4, keycode: right, state: 0)
        commits = held.released(keycode: right, controlStillHeld: false)
        #expect(commits)

        // Both Ctrl keys predate this controller's focus, so its fallback set never saw either press.
        // GTK's live device state must still keep the first release from committing.
        var preHeld = HeldControlKeys()
        preHeld.pressed(keyval: 0xFF09, keycode: tab, state: control)
        commits = preHeld.released(keycode: left, controlStillHeld: true)
        #expect(!commits)
        commits = preHeld.released(keycode: right, controlStillHeld: false)
        #expect(commits)
    }

    @Test("the switcher cycles at most ten candidates")
    func sessionSwitcherCandidateCap() {
        let ids = (0..<12).map { _ in UUID() }
        var recency = RecencyStack<UUID>()
        for id in ids { recency.push(id) }
        var switcher = SessionSwitcherModel()
        switcher.begin(recency.top(SessionSwitcherModel.maxCandidates, in: Set(ids)))
        #expect(switcher.ordered.count == 10)
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

    @Test("redundant local shell titles preserve cwd-derived session names")
    func redundantLocalTitles() {
        #expect(LinuxSessionTitlePolicy.recordableTitle(
            "/home/sasha", cwd: "/home/sasha", home: "/tmp/test-home", loginShell: "bash") == "")
        #expect(LinuxSessionTitlePolicy.recordableTitle(
            "/h/sasha", cwd: "/home/sasha", home: "/tmp/test-home", loginShell: "fish") == "")
        #expect(LinuxSessionTitlePolicy.recordableTitle(
            "~", cwd: "/home/sasha", home: "/home/sasha", loginShell: "fish") == "")
        #expect(LinuxSessionTitlePolicy.recordableTitle(
            "~/D/github.com", cwd: "/home/sasha/Developer/github.com",
            home: "/home/sasha", loginShell: "fish") == "")
        #expect(LinuxSessionTitlePolicy.recordableTitle(
            "~/.c/fish", cwd: "/home/sasha/.config/fish",
            home: "/home/sasha", loginShell: "fish") == "")
        #expect(LinuxSessionTitlePolicy.recordableTitle(
            "[server] ~", cwd: "/home/sasha", home: "/home/sasha", loginShell: "fish") == "[server] ~")
        #expect(LinuxSessionTitlePolicy.recordableTitle(
            "vim README.md", cwd: "/home/sasha", home: "/home/sasha", loginShell: "fish") == "vim README.md")
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

@Suite("Sidebar drop insertion slots")
struct SidebarDropSlotTests {
    @Test("y-midpoint maps to an insertion slot: top half before, bottom half (midpoint inclusive) after")
    func dropInsertionSlot() {
        #expect(LinuxSidebarPolicy.dropInsertionSlot(targetIndex: 3, y: 0, height: 30) == 3)
        #expect(LinuxSidebarPolicy.dropInsertionSlot(targetIndex: 3, y: 14.9, height: 30) == 3)
        #expect(LinuxSidebarPolicy.dropInsertionSlot(targetIndex: 3, y: 15, height: 30) == 4)
        #expect(LinuxSidebarPolicy.dropInsertionSlot(targetIndex: 3, y: 29.9, height: 30) == 4)
        #expect(LinuxSidebarPolicy.dropInsertionSlot(targetIndex: 0, y: 20, height: 30) == 1)
        // Out-of-range y (GTK can report a drop just outside the row): each side resolves to
        // its nearest half.
        #expect(LinuxSidebarPolicy.dropInsertionSlot(targetIndex: 3, y: -5, height: 30) == 3)
        #expect(LinuxSidebarPolicy.dropInsertionSlot(targetIndex: 3, y: 35, height: 30) == 4)
    }

    // A selection id can close mid-drag: `handleSessionDrop` still hands `moveSessions` the full id list.
    @Test("moveSessions ignores a stale id and moves the survivors (agtermCore assumption)")
    @MainActor
    func staleSelectionIDTolerance() {
        let first = Session(initialCwd: "/tmp")
        let second = Session(initialCwd: "/tmp")
        let home = Workspace(name: "home", sessions: [first, second])
        let target = Workspace(name: "target", sessions: [])
        let store = AppStore(workspaces: [home, target])
        let moved = store.moveSessions([first.id, UUID()], toWorkspace: target.id, at: 0)
        #expect(moved == 1)
        #expect(store.workspaces[0].sessions.map(\.id) == [second.id])
        #expect(store.workspaces[1].sessions.map(\.id) == [first.id])
    }

    /// Feeds a synthesized drop through `handleWorkspaceDrop`'s OWN composition —
    /// `LinuxSidebarPolicy.workspaceDropChildIndex` (the function the controller calls), then the
    /// UNCHANGED `SidebarDrop.resolveWorkspace` — and returns the post-removal destination
    /// (nil = no-op). `target` is the aimed-at row's position among the RENDERED rows;
    /// `visibleIndices` their full-array indices (default: every workspace rendered, where the
    /// mapping is the identity).
    private func workspaceDestination(source: Int, target: Int, count: Int,
                                      bottomHalf: Bool, height: Double = 30,
                                      visibleIndices: [Int]? = nil) -> Int? {
        let childIndex = LinuxSidebarPolicy.workspaceDropChildIndex(
            targetVisibleIndex: target, visibleIndices: visibleIndices ?? Array(0..<count),
            y: bottomHalf ? height * 0.75 : height * 0.25, height: height)
        return SidebarDrop.resolveWorkspace(sourceIndex: source, count: count,
                                            childIndex: childIndex)?.destination
    }

    @Test("two-workspace reorder: every half of every row resolves to the macOS destinations")
    func twoWorkspaceTable() {
        // [A, B]: drag A onto B's bottom half -> slot 2 -> destination 1 -> [B, A].
        // This is the reported repro ("drag A to last" was silently dropped by the raw-index bug).
        #expect(workspaceDestination(source: 0, target: 1, count: 2, bottomHalf: true) == 1)
        // A onto B's top half -> slot 1 -> insert-before-B is where A already is -> no-op.
        #expect(workspaceDestination(source: 0, target: 1, count: 2, bottomHalf: false) == nil)
        // B onto A's top half -> slot 0 -> [B, A] (the direction that already worked).
        #expect(workspaceDestination(source: 1, target: 0, count: 2, bottomHalf: false) == 0)
        // B onto A's bottom half -> slot 1 -> no-op.
        #expect(workspaceDestination(source: 1, target: 0, count: 2, bottomHalf: true) == nil)
    }

    @Test("three-workspace reorder pins the old off-by-one and both halves of a far target")
    func threeWorkspaceTable() {
        // [A, B, C]: A onto C's bottom half -> slot 3 -> destination 2 (the old raw-index bug landed at 1).
        #expect(workspaceDestination(source: 0, target: 2, count: 3, bottomHalf: true) == 2)
        // A onto C's top half -> slot 2 -> destination 1.
        #expect(workspaceDestination(source: 0, target: 2, count: 3, bottomHalf: false) == 1)
        // C onto A's bottom half -> slot 1 -> destination 1.
        #expect(workspaceDestination(source: 2, target: 0, count: 3, bottomHalf: true) == 1)
        // C onto A's top half -> slot 0 -> destination 0.
        #expect(workspaceDestination(source: 2, target: 0, count: 3, bottomHalf: false) == 0)
        // A dropped onto its own bottom half -> slot 1 -> no-op.
        #expect(workspaceDestination(source: 0, target: 0, count: 3, bottomHalf: true) == nil)
    }

    @Test("focus-filtered workspace drops land adjacent to the visible target, never across hidden rows")
    func filteredWorkspaceTable() {
        // [A, B, C, D] with only {B(1), D(3)} rendered by the focus filter. `target` is the row's
        // VISIBLE position (B = 0, D = 1); `visibleIndices` maps it back to the full array.
        let visible = [1, 3]
        // B onto D's top half: in visible space that is the slot just after B — where B already sits,
        // so a NO-OP. The raw full-array slot (3) would have moved B past the HIDDEN C ([A, C, B, D]),
        // a reorder invisible at drop time and impossible to aim at.
        #expect(workspaceDestination(source: 1, target: 1, count: 4,
                                     bottomHalf: false, visibleIndices: visible) == nil)
        // B onto D's bottom half -> full-array insert 4 -> destination 3 -> [A, C, D, B].
        #expect(workspaceDestination(source: 1, target: 1, count: 4,
                                     bottomHalf: true, visibleIndices: visible) == 3)
        // D onto B's top half -> insert 1, immediately before B: the hidden A stays first -> [A, D, B, C].
        #expect(workspaceDestination(source: 3, target: 0, count: 4,
                                     bottomHalf: false, visibleIndices: visible) == 1)
        // D onto B's bottom half -> insert 2, immediately after B and before the hidden C -> [A, B, D, C].
        #expect(workspaceDestination(source: 3, target: 0, count: 4,
                                     bottomHalf: true, visibleIndices: visible) == 2)
    }

    /// Feeds a synthesized session drop through the slot helper into the UNCHANGED
    /// `SidebarDrop.resolveSessions`.
    private func sessionResolution(sources: [SidebarDrop.SessionSource],
                                   targetWorkspace: UUID, targetIndex: Int, targetCount: Int,
                                   bottomHalf: Bool, height: Double = 30) -> SidebarDrop.SessionResolution? {
        let slot = LinuxSidebarPolicy.dropInsertionSlot(
            targetIndex: targetIndex, y: bottomHalf ? height * 0.75 : height * 0.25, height: height)
        return SidebarDrop.resolveSessions(
            sources: sources,
            target: .sessionRow(workspace: targetWorkspace, sessionIndex: targetIndex, sessionCount: targetCount),
            childIndex: slot)
    }

    @Test("same-workspace session drops reach the first slot, append at the end, and no-op on own position")
    func sameWorkspaceSessionTable() {
        let ws = UUID()
        // [s0, s1, s2]: drag s2 onto s0's top half -> slot 0 -> destination 0 (the previously
        // unreachable FIRST slot; the old onItemIndex redirect forced sessionIndex + 1).
        let toFirst = sessionResolution(sources: [.init(workspace: ws, index: 2)],
                                        targetWorkspace: ws, targetIndex: 0, targetCount: 3, bottomHalf: false)
        #expect(toFirst?.workspace == ws)
        #expect(toFirst?.destination == 0)
        // s0 onto s2's bottom half -> slot 3 -> post-removal destination 2 (append).
        let toLast = sessionResolution(sources: [.init(workspace: ws, index: 0)],
                                       targetWorkspace: ws, targetIndex: 2, targetCount: 3, bottomHalf: true)
        #expect(toLast?.destination == 2)
        // Drop on the dragged row's OWN halves: both resolve back to its current slot -> no-op.
        #expect(sessionResolution(sources: [.init(workspace: ws, index: 1)],
                                  targetWorkspace: ws, targetIndex: 1, targetCount: 3, bottomHalf: false) == nil)
        #expect(sessionResolution(sources: [.init(workspace: ws, index: 1)],
                                  targetWorkspace: ws, targetIndex: 1, targetCount: 3, bottomHalf: true) == nil)
    }

    @Test("cross-workspace session drops land before or after the aimed-at row")
    func crossWorkspaceSessionTable() {
        let source = UUID()
        let target = UUID()
        let top = sessionResolution(sources: [.init(workspace: source, index: 0)],
                                    targetWorkspace: target, targetIndex: 1, targetCount: 2, bottomHalf: false)
        #expect(top?.workspace == target)
        #expect(top?.destination == 1)
        let bottom = sessionResolution(sources: [.init(workspace: source, index: 0)],
                                       targetWorkspace: target, targetIndex: 1, targetCount: 2, bottomHalf: true)
        #expect(bottom?.workspace == target)
        #expect(bottom?.destination == 2)
    }

    @Test("multi-selection blocks keep their order and a block containing the target stays a no-op")
    func multiSelectionBlockTable() {
        let ws = UUID()
        // [s0, s1, s2]: drag the [s0, s1] block onto s2's bottom half -> slot 3 -> post-removal
        // destination 1; the caller inserts `sources` in order, so the block order is preserved.
        let block = sessionResolution(sources: [.init(workspace: ws, index: 0), .init(workspace: ws, index: 1)],
                                      targetWorkspace: ws, targetIndex: 2, targetCount: 3, bottomHalf: true)
        #expect(block?.destination == 1)
        // A block dropped onto a row INSIDE itself is a no-op on either half.
        let selfSources: [SidebarDrop.SessionSource] = [.init(workspace: ws, index: 1), .init(workspace: ws, index: 2)]
        #expect(sessionResolution(sources: selfSources,
                                  targetWorkspace: ws, targetIndex: 1, targetCount: 3, bottomHalf: false) == nil)
        #expect(sessionResolution(sources: selfSources,
                                  targetWorkspace: ws, targetIndex: 2, targetCount: 3, bottomHalf: true) == nil)
        // A cross-workspace block lands as one insertion at the slot.
        let other = UUID()
        let mixed = sessionResolution(sources: [.init(workspace: other, index: 0), .init(workspace: ws, index: 0)],
                                      targetWorkspace: ws, targetIndex: 1, targetCount: 2, bottomHalf: true)
        #expect(mixed?.workspace == ws)
        #expect(mixed?.destination == 1)
    }

    @Test("a drag carries the whole selected block only when the pressed row is inside it")
    func draggedSessionBlockTable() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        // Pressed row inside the selection: the block moves, preserving its (visual) order.
        #expect(LinuxSidebarPolicy.draggedSessionBlock(source: b, selection: [a, b, c]) == [a, b, c])
        // Pressed row outside the selection, or no multi-select in flight: only the pressed row.
        #expect(LinuxSidebarPolicy.draggedSessionBlock(source: b, selection: [a, c]) == [b])
        #expect(LinuxSidebarPolicy.draggedSessionBlock(source: b, selection: []) == [b])
    }

    /// The header-drop composition `handleSessionToWorkspace` ships: the expanded block through
    /// `resolveSessions` with a `.workspaceRow` target and the `onItemIndex` append slot.
    private func headerResolution(sources: [SidebarDrop.SessionSource], targetWorkspace: UUID,
                                  targetCount: Int) -> SidebarDrop.SessionResolution? {
        SidebarDrop.resolveSessions(
            sources: sources,
            target: .workspaceRow(id: targetWorkspace, sessionCount: targetCount),
            childIndex: SidebarDrop.onItemIndex)
    }

    @Test("header drops append the whole block and no-op when it already tails the target")
    func headerBlockAppendTable() {
        let src = UUID()
        let dest = UUID()
        // A cross-workspace [s0, s1] block appends after the target's existing session.
        let block = headerResolution(sources: [.init(workspace: src, index: 0), .init(workspace: src, index: 1)],
                                     targetWorkspace: dest, targetCount: 1)
        #expect(block?.workspace == dest)
        #expect(block?.destination == 1)
        // A block already at its own workspace's tail dropped on that header is a no-op.
        #expect(headerResolution(sources: [.init(workspace: src, index: 1), .init(workspace: src, index: 2)],
                                 targetWorkspace: src, targetCount: 3) == nil)
        // Not at the tail: the same-workspace block re-appends at the post-removal end.
        let reappend = headerResolution(sources: [.init(workspace: src, index: 0), .init(workspace: src, index: 1)],
                                        targetWorkspace: src, targetCount: 3)
        #expect(reappend?.destination == 1)
    }
}

@Suite("Sidebar session-click timing")
struct SidebarSessionClickTests {
    // `#expect` cannot call a mutating member inside its macro expansion, so tracker calls land in a `let`.
    @Test("press applies immediately except a plain press inside the current selection, which defers")
    func pressTable() {
        var tracker = LinuxSidebarPolicy.SessionClickTracker()
        let row = UUID()
        let plainOutside = tracker.press(row, modified: false, alreadyInSelection: false)
        #expect(plainOutside)
        // The deferred collapse-to-one runs on release, so a block drag keeps its block.
        let plainInside = tracker.press(row, modified: false, alreadyInSelection: true)
        #expect(!plainInside)
        let modifiedOutside = tracker.press(row, modified: true, alreadyInSelection: false)
        #expect(modifiedOutside)
        let modifiedInside = tracker.press(row, modified: true, alreadyInSelection: true)
        #expect(modifiedInside)
    }

    @Test("release collapses only after a press that deferred on the same row")
    func deferredPressThenRelease() {
        var tracker = LinuxSidebarPolicy.SessionClickTracker()
        let row = UUID()
        let applied = tracker.press(row, modified: false, alreadyInSelection: true)
        #expect(!applied)
        let collapses = tracker.release(row)
        #expect(collapses)
        // The pending state is CONSUMED: a second release (stale event) changes nothing.
        let replay = tracker.release(row)
        #expect(!replay)
    }

    @Test("a modifier press applies on press and its release never collapses, whatever the release-time modifiers")
    func modifierLiftedBeforeButtonUp() {
        var tracker = LinuxSidebarPolicy.SessionClickTracker()
        let row = UUID()
        // alreadyInSelection: true — the clicked row IS in the selection the shift press just built.
        let shiftApplied = tracker.press(row, modified: true, alreadyInSelection: true)
        #expect(shiftApplied)
        let shiftReleaseCollapses = tracker.release(row)
        #expect(!shiftReleaseCollapses)
        // Same for a plain press on an unselected row: applying on press leaves nothing to defer.
        let plainApplied = tracker.press(row, modified: false, alreadyInSelection: false)
        #expect(plainApplied)
        let plainReleaseCollapses = tracker.release(row)
        #expect(!plainReleaseCollapses)
    }

    @Test("a new press resets a pending collapse a cancelled release left behind")
    func dragCancelThenNextClick() {
        var tracker = LinuxSidebarPolicy.SessionClickTracker()
        let dragged = UUID()
        let other = UUID()
        // A drag past the threshold cancels `released`, so the deferred collapse survives the drag...
        let deferred = tracker.press(dragged, modified: false, alreadyInSelection: true)
        #expect(!deferred)
        // ...but the NEXT press resets it, so a later release cannot replay the stale collapse.
        let nextApplied = tracker.press(other, modified: false, alreadyInSelection: false)
        #expect(nextApplied)
        let staleCollapse = tracker.release(dragged)
        #expect(!staleCollapse)
        // And a release on a DIFFERENT row than the pending one never collapses.
        let deferredAgain = tracker.press(dragged, modified: false, alreadyInSelection: true)
        #expect(!deferredAgain)
        let wrongRowCollapse = tracker.release(other)
        #expect(!wrongRowCollapse)
    }

    @Test("CSS and accessibility selection follow single, range, and collapse transitions")
    func effectiveSelectionTransitions() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let ids = [a, b, c]
        func selected(_ selection: [UUID], activeID: UUID?) -> [UUID] {
            ids.filter {
                LinuxSidebarPolicy.sessionIsInEffectiveSelection(
                    $0, selection: selection, activeID: activeID)
            }
        }
        // Empty transient selection: the active session alone counts as in-selection.
        #expect(selected([], activeID: c) == [c])
        #expect(selected([], activeID: nil).isEmpty)
        // Range selection publishes every member, then a plain-click release collapses to one.
        #expect(selected([a, b, c], activeID: c) == [a, b, c])
        #expect(selected([b], activeID: b) == [b])
        // Once transient selection exists it is authoritative even if the active id differs.
        #expect(selected([a, b], activeID: c) == [a, b])
    }

    // The release collapse re-runs `selectSession(id, sidebarSelection: [id])`; this pins that re-run as inert.
    @Test("selectSession on an already-sole selection is idempotent (agtermCore assumption)")
    @MainActor
    func collapseIdempotence() {
        let session = Session(initialCwd: "/tmp")
        let store = AppStore(workspaces: [Workspace(name: "work", sessions: [session])])
        store.selectSession(session.id, sidebarSelection: [session.id])
        store.selectSession(session.id, sidebarSelection: [session.id])
        #expect(store.selectedSessionID == session.id)
        #expect(store.sidebarSelectionIDs == [session.id])
    }
}

@Suite("Sidebar hover CSS")
struct SidebarHoverCSSTests {
    @Test("the sidebar hover rule keys on bare :hover, never .activatable")
    func hoverCSS() {
        // Passive rows (non-activatable, makeRow) lose the `.activatable` class libadwaita's own
        // hover rule keys on, so the replacement rule must key on bare `:hover` — a selector
        // containing `.activatable` would never match a sidebar row again.
        let css = LinuxSidebarPolicy.sidebarHoverCSS
        #expect(css.contains(".agterm-sidebar .navigation-sidebar > row:hover"))
        #expect(css.contains("background-color: alpha(currentColor, 0.07)"))
        #expect(!css.contains(".activatable"))
    }

    @Test("the installed app CSS carries the sidebar hover rule")
    func appCSSInstallsHoverRule() {
        // The hover constant only takes effect once `installAppCSS` interpolates it into the
        // installed stylesheet — pin the composed string, not just the constant.
        #expect(appCSS(prefersReducedMotion: false).contains(LinuxSidebarPolicy.sidebarHoverCSS))
    }
}
