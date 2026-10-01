import Foundation
import agtermCore

struct SessionSwitcherModel: Equatable, Sendable {
    /// Cap on cycle rows, shared with the recent-sessions popover (macOS `SessionSwitcher.maxCandidates`).
    static let maxCandidates = 10

    private var candidates: [UUID] = []
    private var index = 0

    var isActive: Bool { !candidates.isEmpty }
    var current: UUID? { candidates.indices.contains(index) ? candidates[index] : nil }
    var ordered: [UUID] { candidates }

    mutating func begin(_ mru: [UUID]) {
        guard mru.count >= 2 else {
            candidates = []
            index = 0
            return
        }
        candidates = mru
        index = 1
    }

    mutating func advance(reverse: Bool = false) {
        guard !candidates.isEmpty else { return }
        let delta = reverse ? -1 : 1
        index = ((index + delta) % candidates.count + candidates.count) % candidates.count
    }

    /// No walk to the next live candidate — one closed mid-hold commits nothing, matching macOS. The
    /// liveness test is not redundant with `AppStore.selectSession`'s own: Linux `selectSession` grabs
    /// focus and rewrites the title and sidebar BEFORE the store ignores a dead id.
    func commitTarget(liveIDs: Set<UUID>) -> UUID? {
        guard let current, liveIDs.contains(current) else { return nil }
        return current
    }

    mutating func end() {
        candidates = []
        index = 0
    }
}

/// macOS `canSwitch` (`uiActionsEnabled`).
enum SessionSwitcherPolicy {
    /// Each of these owns the keyboard, so a cycle neither begins nor commits under one.
    static func canSwitch(zoomed: Bool, dashboardOpen: Bool, modalPending: Bool, dialogVisible: Bool,
                          popoverOpen: Bool) -> Bool {
        !(zoomed || dashboardOpen || modalPending || dialogVisible || popoverOpen)
    }
}

/// The reserved Ctrl-Tab chord, or Esc during a cycle, taken before any widget sees it
/// (`agterm-linux/docs/menu-actions.md`).
enum SessionSwitchKey: Equatable {
    case cycle(reverse: Bool)
    case cancel

    static func classify(keyval: UInt32, state: UInt32, cycleActive: Bool) -> SessionSwitchKey? {
        if keyval == 0xFF1B { return cycleActive ? .cancel : nil }
        guard let chord = namedShortcutChord(fromKeyval: keyval, mods: shortcutModifiers(state)),
              chord.key == "tab", isReservedMonitorChord(chord) else { return nil }
        return .cycle(reverse: chord.mods.contains(.shift))
    }
}

/// The Ctrl keys observed down, retained as a fallback when GTK cannot report the live keyboard-device
/// state. The device state is authoritative on release because the set cannot contain Ctrl keys that were
/// already held when the window gained focus. A press arriving with Ctrl clear resyncs the fallback,
/// so a key up lost to a blur or grab cannot strand a phantom forever.
struct HeldControlKeys: Equatable, Sendable {
    private var down: Set<UInt32> = []

    mutating func pressed(keyval: UInt32, keycode: UInt32, state: UInt32) {
        if state & ModifierKeyMods.controlBit == 0 { down.removeAll() }
        guard ModifierKeyMods.modifierBit(forKeyval: keyval) == ModifierKeyMods.controlBit else { return }
        down.insert(keycode)
    }

    mutating func released(keycode: UInt32, controlStillHeld: Bool?) -> Bool {
        down.remove(keycode)
        if let controlStillHeld {
            if !controlStillHeld { down.removeAll() }
            return !controlStillHeld
        }
        return down.isEmpty
    }
}

/// Whether the card's highlighted row can be scrolled to yet. A card added mid-frame publishes its rows
/// before their first allocation, so the reveal waits a few frames for a height, then gives up.
enum SessionSwitcherReveal {
    enum Step: Equatable { case reveal, wait, giveUp }

    static func step(rowMapped: Bool, rowHeight: Double, ticksElapsed: Int) -> Step {
        if rowMapped, rowHeight > 0 { return .reveal }
        return ticksElapsed < LinuxSidebarPolicy.scrollRetryTicks ? .wait : .giveUp
    }
}

/// macOS `SessionSwitcherOverlay` geometry in overlay coordinates: centered over the terminal area where it
/// fits, and 12% down the window. `left` folds in `panelOffset`'s clamp, which keeps the card inside the
/// window.
struct SessionSwitcherPlacement: Equatable, Sendable {
    static let idealWidthAtDefault: Double = 460
    static let topInsetFraction: Double = 0.12
    static let cardPadding = 10
    static let cardBorder = 1
    static let cardCSS = """
        .agterm-switcher { background-color: @popover_bg_color; color: @popover_fg_color; padding: \(cardPadding)px;
            border-radius: 10px; border: \(cardBorder)px solid alpha(@popover_fg_color, 0.12); }
        """

    let width: Double
    let maxHeight: Double
    let left: Double
    let marginTop: Double

    /// `sidebarWidth` is where the terminal area starts, divider included.
    init(metrics: InterfaceMetrics, windowWidth: Double, windowHeight: Double, sidebarVisible: Bool,
         sidebarWidth: Double) {
        let inset = sidebarVisible ? max(0, sidebarWidth) : 0
        width = metrics.fittedPanelWidth(
            idealAtDefault: Self.idealWidthAtDefault, windowWidth: windowWidth, terminalAreaInset: inset)
        left = (windowWidth - width) / 2
            + metrics.panelOffset(width: width, windowWidth: windowWidth, terminalAreaInset: inset)
        marginTop = windowHeight * Self.topInsetFraction
        maxHeight = metrics.fittedPanelHeight(windowHeight: windowHeight, topFraction: Self.topInsetFraction)
    }

    /// The scroller's content bounds: GTK adds its CSS padding and border outside `max-content-*`, so these
    /// give them back to keep the whole card within `width` by `maxHeight`.
    var contentWidth: Double { width - Self.chrome }
    var contentMaxHeight: Double { maxHeight - Self.chrome }
    private static var chrome: Double { Double(2 * (cardPadding + cardBorder)) }
}
