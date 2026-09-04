// GLib-backed implementation of agtermCore's MainTimer seam: one one-shot `g_timeout_add_full` source per
// schedule, on the loop GTK actually runs. The shared default schedules on the dispatch main queue, which
// `g_application_run` never drains, so installing this at startup is what makes every deferral in the
// process fire at all — see `agterm-linux/docs/main-loop.md`.
import CGtk
import Foundation
import agtermCore

@MainActor
func installGLibMainTimer() {
    MainTimer.scheduleTimer = { delay, fire in
        let timer = GLibMainTimerSource(delay: delay, fire: fire)
        return { timer.cancel() }
    }
}

/// One pending fire: a one-shot g_timeout source retaining this object as its user data, released
/// by the source's destroy notify on fire AND on cancel (`g_source_remove` also triggers it).
///
/// State is `private` (nothing outside the type touches it); the two entry points are `fileprivate` because
/// their callers are the file-scope C callback and installer closures below, which sit OUTSIDE the type and
/// so cannot reach a `private` member.
@MainActor
private final class GLibMainTimerSource {
    private var sourceID: guint = 0
    private let fire: @MainActor () -> Void

    init(delay: TimeInterval, fire: @escaping @MainActor () -> Void) {
        self.fire = fire
        // Clamped, never a bare `guint(...)`: `MainTimer.schedule` is public API taking any `TimeInterval`,
        // and converting a negative, non-finite, or >49-day (`guint.max` ms) delay would TRAP and take the
        // app down. A non-finite delay parks the timer instead of crashing; a negative one fires next turn.
        let ms = (delay * 1000).rounded()
        let interval = ms.isFinite ? guint(min(max(0, ms), Double(guint.max))) : guint.max
        sourceID = g_timeout_add_full(G_PRIORITY_DEFAULT, interval, onGLibMainTimerTimeout,
                                      Unmanaged.passRetained(self).toOpaque(), releaseGLibMainTimerSource)
    }

    fileprivate func fired() {
        sourceID = 0
        fire()
    }

    fileprivate func cancel() {
        guard sourceID != 0 else { return }   // already fired — nothing to remove
        _ = g_source_remove(sourceID)
        sourceID = 0
    }
}

private let onGLibMainTimerTimeout: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    let timer = Unmanaged<GLibMainTimerSource>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { timer.fired() }
    return 0   // one-shot; the destroy notify balances the init retain
}

private let releaseGLibMainTimerSource: @MainActor @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<GLibMainTimerSource>.fromOpaque(data).release()
}
