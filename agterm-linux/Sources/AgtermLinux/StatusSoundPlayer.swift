import CGtk
import agtermCore

/// Linux status sounds use the desktop bell. The shared CLI/help documents macOS sound names too; Linux
/// accepts those names and maps them to the bell so `--sound Glass` never prevents the status update.
@MainActor
final class StatusSoundPlayer {
    static let shared = StatusSoundPlayer()

    private var throttle = SoundThrottle(window: .milliseconds(200))

    func statusSoundError(for name: String) -> String? {
        nil
    }

    func play(_ name: String) {
        guard statusSoundError(for: name) == nil else { return }
        guard throttle.allow(name, at: ContinuousClock().now) else { return }
        if let display = gdk_display_get_default() {
            gdk_display_beep(display)
        } else if let widget = W(gController?.windowPointer) {
            gtk_widget_error_bell(widget)
        }
    }
}
