import Foundation
import Testing
@testable import AgtermLinux

/// GDK (like X11) reports the modifier state PRIOR to a key event: a bare Ctrl press arrives with
/// the control bit still clear in `state`, and the release with it still set. libghostty recomputes
/// link hover and the mouse cursor shape on modifier transitions (`Surface.zig` modsChanged →
/// mouseRefreshLinks), so forwarding the raw prior-state value defers those recomputes to the next
/// mouse-motion event — the user-visible "hold Ctrl and jiggle the mouse" quirk on Linux. Upstream
/// macOS avoids it because AppKit's `flagsChanged` carries the post-change `modifierFlags`
/// (umputun/agterm `GhosttySurfaceView+Input.swift`). `ModifierKeyMods.adjustedState` reproduces
/// that contract in GDK state space: press adds the key's own bit, release clears it.
@Suite("Modifier-only key state synthesis (X11 prior-state quirk)")
struct ModifierKeyModsTests {
    @Test("ctrl press sets the control bit even though the raw state lacks it")
    func ctrlPressSetsBit() {
        let out = ModifierKeyMods.adjustedState(forKeyval: 0xFFE3, state: 0, pressing: true) // Control_L
        #expect(out & ModifierKeyMods.controlBit != 0)
    }

    @Test("shift press sets the shift bit, preserving already-held modifiers")
    func shiftPressPreservesOthers() {
        let out = ModifierKeyMods.adjustedState(
            forKeyval: 0xFFE1, // Shift_L
            state: ModifierKeyMods.controlBit,
            pressing: true
        )
        #expect(out & ModifierKeyMods.shiftBit != 0)
        #expect(out & ModifierKeyMods.controlBit != 0)
    }

    @Test("ctrl release clears only the control bit (raw release state still has it set)")
    func ctrlReleaseClearsBit() {
        let out = ModifierKeyMods.adjustedState(
            forKeyval: 0xFFE4, // Control_R
            state: ModifierKeyMods.shiftBit | ModifierKeyMods.controlBit,
            pressing: false
        )
        #expect(out & ModifierKeyMods.controlBit == 0)
        #expect(out & ModifierKeyMods.shiftBit != 0)
    }

    @Test("press is idempotent when the backend already reports the new state (Wayland-style)")
    func pressIdempotent() {
        let out = ModifierKeyMods.adjustedState(
            forKeyval: 0xFFE3,
            state: ModifierKeyMods.controlBit,
            pressing: true
        )
        #expect(out == ModifierKeyMods.controlBit)
    }

    @Test("alt/meta and super/hyper keyvals map to their GDK bits")
    func altAndSuperMap() {
        for kv: UInt32 in [0xFFE7, 0xFFE8, 0xFFE9, 0xFFEA] { // Meta_L/R, Alt_L/R
            #expect(ModifierKeyMods.modifierBit(forKeyval: kv) == ModifierKeyMods.altBit)
        }
        for kv: UInt32 in [0xFFEB, 0xFFEC, 0xFFED, 0xFFEE] { // Super_L/R, Hyper_L/R
            #expect(ModifierKeyMods.modifierBit(forKeyval: kv) == ModifierKeyMods.superBit)
        }
    }

    @Test("non-modifier keys pass the state through unchanged in both directions")
    func nonModifiersPassThrough() {
        for kv: UInt32 in [0x61, 0xFF1B, 0xFF51, 0xFFE5] { // 'a', Escape, Left arrow, Caps_Lock
            #expect(ModifierKeyMods.modifierBit(forKeyval: kv) == nil)
            #expect(ModifierKeyMods.adjustedState(forKeyval: kv, state: 0x42, pressing: true) == 0x42)
            #expect(ModifierKeyMods.adjustedState(forKeyval: kv, state: 0x42, pressing: false) == 0x42)
        }
    }
}
