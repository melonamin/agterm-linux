import Foundation

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

/// The Ctrl keys observed down, retained as a fallback when GTK cannot report the live keyboard-device
/// state. The device state is authoritative on release because the set cannot contain Ctrl keys that were
/// already held when this controller gained focus. A press arriving with Ctrl clear resyncs the fallback,
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
