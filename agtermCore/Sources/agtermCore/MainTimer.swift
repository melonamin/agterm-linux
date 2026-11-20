import Foundation

/// The host's main-actor timer seam — the ONE place deferred main-actor work is scheduled from, so a
/// host whose main loop drains something other than the dispatch main queue can swap in its own timer
/// once at startup instead of every call site growing a platform branch.
///
/// The default schedules on the dispatch main queue, which the AppKit run loop drains on macOS. A host
/// whose main loop never drains that queue MUST install its own timer before scheduling anything: the
/// GTK port's GLib loop is one — under `g_application_run` neither libdispatch's main queue nor the
/// Swift Concurrency main-actor executor is drained, so the default would silently never fire (this
/// was the Linux theme-preview live-navigation bug, and it also muted every debounced save and the
/// soft-close grace finalizer).
///
/// Foundation-only — host-free. `@MainActor` so scheduled work runs on the main actor like its callers.
@MainActor
public enum MainTimer {
    /// The injection point: schedules `fire` on the main actor after `delay` and returns a closure that
    /// cancels the pending fire (a no-op once it has fired). Hosts replace this once at startup; tests
    /// swap it to drive time deterministically. Call sites use `schedule(after:_:)` instead.
    public static var scheduleTimer: @MainActor (TimeInterval, @escaping @MainActor () -> Void)
        -> (@MainActor () -> Void) = { delay, fire in
            let item = DispatchWorkItem { fire() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        }

    /// Schedules `fire` after `delay`, returning the cancel closure. The labeled wrapper over
    /// `scheduleTimer`: a stored closure has no argument labels and its result can't be
    /// `@discardableResult`, so fire-and-forget callers go through this.
    @discardableResult
    public static func schedule(after delay: TimeInterval,
                                _ fire: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        scheduleTimer(delay, fire)
    }
}
