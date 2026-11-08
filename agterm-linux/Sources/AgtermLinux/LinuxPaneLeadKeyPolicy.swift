import Foundation
import agtermCore

/// Keys on a covered pane after the keymap declined them (macOS `PaneLead.consumes`). GTK4 carries no
/// repeat flag, so the takeover keycode is held until its release: the press lands on the surface that
/// `reattachPane` tears down, its repeats and release on the replacement.
@MainActor
final class LinuxPaneLeadKeyPolicy {
    enum Press: Equatable {
        case keymap
        case pass
        case consume
        case takeover
    }

    private let book: ZmxLeadBook
    private(set) var takeoverKeycode: UInt32?

    init(book: ZmxLeadBook = .shared) {
        self.book = book
    }

    /// The cover button's order; the surface runs `handleKey` itself and then calls `press`.
    func route(keyval: UInt32, keycode: UInt32, state: UInt32, pane: UUID?, keymap: () -> Bool) -> Press {
        if keymap() { return .keymap }
        return press(keyval: keyval, keycode: keycode, state: state, pane: pane)
    }

    func press(keyval: UInt32, keycode: UInt32, state: UInt32, pane: UUID?) -> Press {
        if keycode == takeoverKeycode { return .consume }
        guard book.covered(pane: pane) else { return .pass }
        if state & ModifierKeyMods.superBit != 0 || ModifierKeyMods.modifierBit(forKeyval: keyval) != nil {
            return .consume
        }
        guard takeoverKeycode == nil, !book.reattaching(pane: pane) else { return .consume }
        takeoverKeycode = keycode
        return .takeover
    }

    /// True when a modifier release reaches libghostty: only on an uncovered pane, since a covered one
    /// consumed its press (macOS `flagsChanged` returns on `leadCovered`).
    func release(keyval: UInt32, keycode: UInt32, pane: UUID?) -> Bool {
        guard ModifierKeyMods.modifierBit(forKeyval: keyval) != nil else {
            _ = release(keycode: keycode)
            return false
        }
        return !book.covered(pane: pane)
    }

    /// True when the release belongs to the takeover and must not reach the terminal.
    func release(keycode: UInt32) -> Bool {
        guard keycode == takeoverKeycode else { return false }
        takeoverKeycode = nil
        return true
    }

    /// The cover button holds the keyboard over a covered surface, so either one losing it to a
    /// reattach must hand it to the replacement.
    static func replacementTakesFocus(surfaceFocused: Bool, coverFocused: Bool) -> Bool {
        surfaceFocused || coverFocused
    }
}
