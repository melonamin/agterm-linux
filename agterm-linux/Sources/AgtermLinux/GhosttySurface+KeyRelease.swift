import CGtk

private func wrap(_ data: gpointer?) -> GhosttySurface? {
    guard let data else { return nil }
    return Unmanaged<GhosttySurface>.fromOpaque(data).takeUnretainedValue()
}

/// A forwarded modifier release reaches libghostty before the Ctrl-Tab commit, which waits a GLib turn
/// (`scheduleSessionSwitchCommit`) and then moves focus.
/// Also installed on the lead cover's button, with its surface as `data`.
let surfaceKeyReleased: @MainActor @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> Void = { _, keyval, keycode, state, data in
    MainActor.assumeIsolated {
        guard let surface = wrap(data) else { return }
        if AppController.paneLeadKeyReleased(surface, keyval: keyval, keycode: keycode) {
            surface.modifierKeyReleased(keyval: keyval, keycode: keycode, state: state)
        }
    }
}
