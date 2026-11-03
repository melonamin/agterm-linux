import CGtk
import Foundation
import agtermCore

@MainActor
extension LinuxHtmlOverlayPage {
    func handleNativeKey(_ event: OpaquePointer) -> Bool {
        guard let controller, let slot = store?.htmlOverlaySlot(id) else { return false }
        let keyval = gdk_key_event_get_keyval(event), keycode = gdk_key_event_get_keycode(event)
        let state = UInt32(gdk_event_get_modifier_state(event).rawValue)
        if let chord = shortcutChord(fromKeyval: keyval, keycode: keycode, state: state,
                                     context: shortcutKeyContext(event: event, keycode: keycode)),
           let shortcut = linuxFixedShortcut(for: chord) {
            switch shortcut {
            case .fontIncrease: LinuxHtmlOverlayRegistry.shared.stepZoom(FontBindingAction.increase)
            case .fontDecrease: LinuxHtmlOverlayRegistry.shared.stepZoom(FontBindingAction.decrease)
            case .fontReset: LinuxHtmlOverlayRegistry.shared.stepZoom(FontBindingAction.reset)
            default: controller.dispatchFixedShortcut(shortcut, origin: nil)
            }
            return true
        }
        return controller.handleKey(keyval: keyval, keycode: keycode, state: state, sessionID: slot.session.id,
                                    context: shortcutKeyContext(event: event, keycode: keycode))
    }
}
