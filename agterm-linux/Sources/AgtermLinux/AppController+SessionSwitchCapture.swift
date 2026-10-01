import CGtk
import Foundation

/// The GTK analogue of macOS's app-wide switcher monitor (`agterm-linux/docs/menu-actions.md`).
@MainActor
func installSessionSwitchCapture(on window: OpaquePointer?) {
    let keys = gtk_event_controller_key_new()
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
    connect(keys, "key-pressed", unsafeBitCast(onSessionSwitchKeyPressed as @convention(c)
        (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self))
    connect(keys, "key-released", unsafeBitCast(onSessionSwitchKeyReleased as @convention(c)
        (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> Void, to: GCallback.self))
    gtk_widget_add_controller(W(window), keys)
}

@MainActor
extension AppController {
    /// Ctrl-Tab is consumed even when the gate refuses a cycle, so no widget below turns it into a focus move.
    fileprivate func sessionSwitchKeyPressed(keyval: UInt32, keycode: UInt32, state: UInt32) -> Bool {
        heldControlKeys.pressed(keyval: keyval, keycode: keycode, state: state)
        guard let key = SessionSwitchKey.classify(
            keyval: keyval, state: state, cycleActive: sessionSwitcher.isActive) else { return false }
        // The surface never sees this press, so its activity note and leader reset happen here instead.
        noteUserActivity()
        abandonLeader()
        switch key {
        case .cycle(let reverse):
            quickSwitchSession(reverse: reverse)
        case .cancel:
            cancelSessionSwitch()
        }
        return true
    }
}

private let onSessionSwitchKeyPressed: @MainActor @convention(c)
    (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { controller, keyval, keycode, state, _ in
        MainActor.assumeIsolated {
            controllerForEventController(controller)?
                .sessionSwitchKeyPressed(keyval: keyval, keycode: keycode, state: state) == true ? 1 : 0
        }
}

private let onSessionSwitchKeyReleased: @MainActor @convention(c)
    (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> Void = { controller, keyval, keycode, _, _ in
        guard ModifierKeyMods.modifierBit(forKeyval: keyval) == ModifierKeyMods.controlBit else { return }
        MainActor.assumeIsolated {
            controllerForEventController(controller)?.scheduleSessionSwitchCommit(releasing: keycode)
        }
}
