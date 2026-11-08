import CGtk
import Foundation
import agtermCore

/// Held keys outlive a surface and a window switch. GTK does not carry an autorepeat bit.
@MainActor
final class LinuxLeaderState {
    static let shared = LinuxLeaderState()
    var engine = CustomCommandEngine(commands: [])
    var timeout: guint = 0
    var consumed: Set<UInt32> = []
    var heldTail: UInt32?

    func consume(_ keycode: UInt32, repeating: Bool) {
        consumed.insert(keycode)
        heldTail = repeating ? keycode : nil
    }
}

@MainActor
extension AppController {
    func leaderKeyReleased(_ keycode: UInt32) {
        let state = LinuxLeaderState.shared
        state.consumed.remove(keycode)
        guard state.heldTail == keycode else { return }
        state.heldTail = nil
        syncLeaderDeadline()
    }

    func leaderFocusLeft() {
        // A builtin can move focus to another terminal/window while its repeat tail is held.
        // Wait until GTK has completed that transition before deciding to cancel the monitor.
        MainTimer.schedule(after: 0) { [weak self] in
            guard let self else { return }
            let active = gWindows.values.first { gtk_window_is_active(WIN($0.windowPointer)) != 0 }
            if active == nil { LinuxLeaderState.shared.consumed.removeAll() }
            guard let active, let focus = gtk_root_get_focus(active.windowPointer),
                  (Array(active.surfaces.values) + Array(active.splitSurfaces.values) + Array(active.scratchSurfaces.values)).contains(where: { W($0.glArea) == focus }) else {
                self.abandonLeader()
                return
            }
            if !self.customCommandEngine.isRepeating { self.abandonLeader() }
        }
    }
}
