import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Ctrl-Tab session switcher")
struct SessionSwitcherTests {
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

    @Test("the switcher runs only when nothing modal owns the keyboard")
    func canSwitch() {
        func allowed(zoomed: Bool = false, dashboardOpen: Bool = false, modalPending: Bool = false,
                     dialogVisible: Bool = false, popoverOpen: Bool = false) -> Bool {
            SessionSwitcherPolicy.canSwitch(zoomed: zoomed, dashboardOpen: dashboardOpen, modalPending: modalPending,
                                            dialogVisible: dialogVisible, popoverOpen: popoverOpen)
        }
        #expect(allowed())
        #expect(!allowed(zoomed: true))
        #expect(!allowed(dashboardOpen: true))
        #expect(!allowed(modalPending: true))
        #expect(!allowed(dialogVisible: true))
        #expect(!allowed(popoverOpen: true))
    }

    @Test("the card takes its colors from the theme, not a fixed dark fill")
    func cardUsesThemeTokens() throws {
        let switcherRules = appCSS.split(separator: "\n").filter { $0.contains(".agterm-switcher") }
        let card = try #require(switcherRules.first { $0.contains(".agterm-switcher {") })
        #expect(!switcherRules.contains { $0.contains("#1e2228") })
        #expect(card.contains("@popover_bg_color"))
        #expect(card.contains("@popover_fg_color"))
        #expect(!switcherRules.contains { $0.contains("opacity") || $0.contains("font-weight") })
    }

    @Test("the selected row follows the terminal theme's selection colors")
    func selectedRowUsesSelectionColors() {
        let css = ThemeColorResolver.windowThemeCSS(
            background: "#111111", foreground: "#222222", selectionBackground: "#333333",
            selectionForeground: "#444444", sidebarBackground: "#555555")
        #expect(css.contains(
            "\n.agterm-switcher-row.agterm-switcher-current { background-color: #333333; color: #444444; }"))
    }

    @Test("the highlighted row is revealed once allocated, after a bounded wait for its height")
    func revealStep() {
        #expect(SessionSwitcherReveal.step(rowMapped: true, rowHeight: 30, ticksElapsed: 0) == .reveal)
        #expect(SessionSwitcherReveal.step(rowMapped: true, rowHeight: 0, ticksElapsed: 0) == .wait)
        #expect(SessionSwitcherReveal.step(rowMapped: false, rowHeight: 30, ticksElapsed: 1) == .wait)
        #expect(SessionSwitcherReveal.step(rowMapped: true, rowHeight: 0,
                                           ticksElapsed: LinuxSidebarPolicy.scrollRetryTicks) == .giveUp)
    }

    private static let metrics = InterfaceMetrics(fontSize: AppSettings.defaultInterfaceFontSize)

    private static func placement(width: Double = 1200, height: Double = 800, sidebarVisible: Bool = true,
                                  sidebarWidth: Double = 240) -> SessionSwitcherPlacement {
        SessionSwitcherPlacement(metrics: metrics, windowWidth: width, windowHeight: height,
                                 sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth)
    }

    @Test("the card centers over the terminal area, or the whole window with no visible sidebar")
    func placementCentersOverTerminalArea() {
        let beside = Self.placement()
        #expect(beside.width == 460)
        #expect(beside.left + beside.width / 2 == (240 + 1200) / 2)
        let hidden = Self.placement(sidebarVisible: false)
        #expect(hidden.left + hidden.width / 2 == 600)
    }

    @Test("a sidebar wider than the terminal area cannot push the card out of the window")
    func placementStaysInsideWindow() {
        let crowded = Self.placement(width: 800, sidebarWidth: 560)
        #expect(crowded.width == InterfaceMetrics.minimumPanelWidth)
        #expect(crowded.left >= 0)
        #expect(crowded.left + crowded.width <= 800)
    }

    @Test("the card starts 12% down the window and may run no further than the fitted panel height")
    func placementVertical() {
        let placement = Self.placement()
        #expect(placement.marginTop == 800 * 0.12)
        #expect(placement.maxHeight == Self.metrics.fittedPanelHeight(windowHeight: 800, topFraction: 0.12))
    }

    @Test("the scroller's content bounds give back the card's padding and border, so the whole card fits")
    func placementReservesCardChrome() {
        let placement = Self.placement()
        #expect(SessionSwitcherPlacement.cardCSS.contains("padding: 10px;"))
        #expect(SessionSwitcherPlacement.cardCSS.contains("border: 1px solid"))
        #expect(appCSS.contains(SessionSwitcherPlacement.cardCSS))
        #expect(placement.width - placement.contentWidth == 22)
        #expect(placement.maxHeight - placement.contentMaxHeight == 22)
    }

    @Test("any Ctrl+Tab variant cycles, with Shift reversing, whatever else is held")
    func captureCyclesOnCtrlTab() {
        let control = ModifierKeyMods.controlBit, shift = ModifierKeyMods.shiftBit
        #expect(SessionSwitchKey.classify(keyval: 0xFF09, state: control, cycleActive: false) == .cycle(reverse: false))
        #expect(SessionSwitchKey.classify(keyval: 0xFF89, state: control, cycleActive: true) == .cycle(reverse: false))
        #expect(SessionSwitchKey.classify(keyval: 0xFE20, state: control | shift, cycleActive: true)
            == .cycle(reverse: true))
        #expect(SessionSwitchKey.classify(keyval: 0xFF09, state: control | ModifierKeyMods.altBit, cycleActive: false)
            == .cycle(reverse: false))
    }

    @Test("Tab without Ctrl and other Ctrl chords pass through")
    func capturePassesOtherKeys() {
        #expect(SessionSwitchKey.classify(keyval: 0xFF09, state: 0, cycleActive: true) == nil)
        #expect(SessionSwitchKey.classify(keyval: 0xFE20, state: ModifierKeyMods.shiftBit, cycleActive: true) == nil)
        #expect(SessionSwitchKey.classify(keyval: 0x63, state: ModifierKeyMods.controlBit, cycleActive: true) == nil)
    }

    @Test("Esc cancels a live cycle and otherwise reaches the focused widget")
    func captureEscapeOnlyDuringCycle() {
        #expect(SessionSwitchKey.classify(keyval: 0xFF1B, state: ModifierKeyMods.controlBit, cycleActive: true) == .cancel)
        #expect(SessionSwitchKey.classify(keyval: 0xFF1B, state: 0, cycleActive: false) == nil)
    }

    @Test("the dim behind the card is macOS's 20% black")
    func dimColor() {
        #expect(appCSS.contains(".agterm-switcher-dim { background-color: alpha(#000000, 0.2); }"))
    }
}
