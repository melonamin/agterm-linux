import CGtk

/// Synthesizes the post-event modifier state for modifier-ONLY key events.
///
/// GDK (like X11) reports the modifier state PRIOR to the event: a bare Ctrl press arrives with the
/// control bit still clear in `state`, and the release with it still set. libghostty recomputes link
/// hover and the mouse cursor shape on modifier transitions (`Surface.zig` modsChanged →
/// mouseRefreshLinks), so forwarding the raw prior-state value defers those recomputes to the next
/// mouse-motion event — the user-visible "hold Ctrl and jiggle the mouse" quirk on Linux. Upstream
/// macOS avoids it because AppKit's `flagsChanged` carries the post-change `modifierFlags`
/// (umputun/agterm `GhosttySurfaceView+Input.swift`). This seam reproduces the same contract in GDK
/// state space: press adds the key's own bit, release clears it. Both operations are idempotent, so
/// a backend that already reports the new state (Wayland) is unaffected.
enum ModifierKeyMods {
    // GDK modifier bits (GDK state space; mirrors the private GDK_* constants in GtkInterop.swift).
    static let shiftBit: UInt32 = 1 << 0
    static let controlBit: UInt32 = 1 << 2
    static let altBit: UInt32 = 1 << 3
    static let superBit: UInt32 = 1 << 26

    /// The GDK modifier bit owned by a modifier keyval, or nil when `keyval` is not a bare modifier
    /// (letters, arrows, function keys). Lock keys (Caps_Lock 0xFFE5, Shift_Lock 0xFFE6) toggle
    /// state asynchronously from the physical press and are deliberately left untouched, matching
    /// upstream macOS's pass-through of the lock keys.
    static func modifierBit(forKeyval keyval: UInt32) -> UInt32? {
        switch keyval {
        case 0xFFE1, 0xFFE2: return shiftBit // Shift_L / Shift_R
        case 0xFFE3, 0xFFE4: return controlBit // Control_L / Control_R
        case 0xFFE7, 0xFFE8, 0xFFE9, 0xFFEA: return altBit // Meta_L/R, Alt_L/R (both map to MOD1)
        case 0xFFEB, 0xFFEC, 0xFFED, 0xFFEE: return superBit // Super_L/R, Hyper_L/R
        default: return nil
        }
    }

    /// `state` adjusted for a modifier-only key event: press sets the key's own bit, release clears
    /// it. Non-modifier keys pass through unchanged.
    static func adjustedState(forKeyval keyval: UInt32, state: UInt32, pressing: Bool) -> UInt32 {
        guard let bit = modifierBit(forKeyval: keyval) else { return state }
        return pressing ? state | bit : state & ~bit
    }

    /// The default seat's live Ctrl state after GTK finishes dispatching a key release. Unlike the key
    /// event's own prior-state mask, this sees a second physical Ctrl that was already held when the
    /// controller gained focus. Reacquire and consume every borrowed GTK pointer synchronously; only the
    /// copied Bool escapes.
    static func currentControlIsHeld() -> Bool? {
        guard let display = gdk_display_get_default(),
              let seat = gdk_display_get_default_seat(display),
              let device = gdk_seat_get_keyboard(seat) else {
            return nil
        }
        return gdk_device_get_modifier_state(device).rawValue & controlBit != 0
    }
}
