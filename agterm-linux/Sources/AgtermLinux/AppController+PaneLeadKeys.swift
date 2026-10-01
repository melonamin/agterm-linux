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
}
