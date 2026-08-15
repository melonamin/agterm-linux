import Foundation

/// Coalesces rapid repeated calls into a single deferred action: `schedule(after:_:)` cancels any pending
/// work and reschedules, so only the latest runs once the quiet window elapses; `flush()` runs it
/// synchronously (for a commit/quit path that must capture the latest state now); `cancel()` drops it.
///
/// `@MainActor` so the work runs on the main actor like its callers (AppStore saves, SettingsModel theme
/// preview). Foundation-only — host-free.
@MainActor
public final class Debouncer {
    /// Cancels the pending deferred fire; nil when nothing is scheduled. Deferral goes through
    /// `MainTimer`, the host timer seam — see its note for why a host may have to replace it.
    private var cancelTimer: (@MainActor () -> Void)?
    private var action: (@MainActor () -> Void)?

    public init() {}

    /// Cancels any pending action and schedules `action` to run after `delay`. Only the
    /// most recently scheduled action survives, so a burst of calls collapses to one run.
    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        cancelTimer?()
        self.action = action
        cancelTimer = MainTimer.schedule(after: delay) { [weak self] in self?.fire() }
    }

    /// Runs the pending action immediately (if any) and clears it. A no-op when nothing
    /// is pending. The deferred timer is cancelled so the action can't run twice.
    public func flush() {
        cancelTimer?()
        fire()
    }

    /// Drops the pending action without running it.
    public func cancel() {
        cancelTimer?()
        cancelTimer = nil
        action = nil
    }

    /// Runs and clears the pending action. Clearing first makes a re-entrant call a no-op.
    private func fire() {
        guard let action else { return }
        cancelTimer = nil
        self.action = nil
        action()
    }
}
