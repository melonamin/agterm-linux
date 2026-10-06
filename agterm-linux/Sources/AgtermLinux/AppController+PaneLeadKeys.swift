import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    /// App-wide like macOS `PaneLead.takeoverKeyCode`: the takeover's release lands wherever the keyboard is by then.
    private static let paneLeadKeys = LinuxPaneLeadKeyPolicy()

    /// After `handleKey` declined a press on `surface`; true when it must not reach the terminal.
    func paneLeadConsumesPress(_ surface: GhosttySurface, keyval: UInt32, keycode: UInt32, state: UInt32) -> Bool {
        let decision = Self.paneLeadKeys.press(keyval: keyval, keycode: keycode, state: state,
                                               pane: UUID(uuidString: surface.paneToken))
        if decision == .takeover { takePaneLead(surface) }
        return decision != .pass
    }

    func paneLeadCoverKey(_ surface: GhosttySurface, keyval: UInt32, keycode: UInt32, state: UInt32) {
        let decision = Self.paneLeadKeys.route(keyval: keyval, keycode: keycode, state: state,
                                               pane: UUID(uuidString: surface.paneToken)) {
            handleKey(keyval: keyval, keycode: keycode, state: state, sessionID: surface.sessionID,
                      origin: surface, context: nil)
        }
        if decision == .takeover { takePaneLead(surface) }
    }

    static func paneLeadKeyReleased(_ surface: GhosttySurface, keyval: UInt32, keycode: UInt32) -> Bool {
        paneLeadKeys.release(keyval: keyval, keycode: keycode, pane: UUID(uuidString: surface.paneToken))
    }

    /// A takeover can move focus to an entry or chrome before release; the window still sees that edge.
    static func paneLeadKeyReleased(keycode: UInt32) {
        _ = paneLeadKeys.release(keycode: keycode)
    }
}

/// Auxiliary toplevels do not receive the main window's capture controller.
@MainActor
func installPaneLeadReleaseCapture(on window: OpaquePointer) {
    let keys = gtk_event_controller_key_new()
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
    connect(keys, "key-released", unsafeBitCast(onPaneLeadKeyReleased as @convention(c)
        (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> Void, to: GCallback.self))
    gtk_widget_add_controller(W(window), keys)
}

private let onPaneLeadKeyReleased: @MainActor @convention(c)
    (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> Void = { _, _, keycode, _, _ in
        MainActor.assumeIsolated {
            AppController.paneLeadKeyReleased(keycode: keycode)
            gWindows.values.first?.leaderKeyReleased(keycode)
        }
    }
