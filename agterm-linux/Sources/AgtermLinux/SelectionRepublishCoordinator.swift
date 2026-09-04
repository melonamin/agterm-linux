import Foundation
import agtermCore

/// Owns the post-rebuild accessible-selection re-publish (`AppController.rebuildSidebar` tail): ONE
/// cancellable next-turn `MainTimer` job, re-armed by every rebuild. A coordinator for the same
/// reason as `SoftCloseReconcileCoordinator`: the fire touches the freshly-built GTK rows, so
/// `windowWillClose` must be able to disarm it (`.claude/rules/main-loop.md`) — the controller can
/// outlive its widget tree whenever a dialog still retains it, and `[weak self]` alone cannot tell
/// a live controller from one whose rows GTK already destroyed.
@MainActor
final class SelectionRepublishCoordinator {
    private var cancelPending: (@MainActor () -> Void)?
    private let schedule: @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    init(schedule: @escaping @MainActor (@escaping @MainActor () -> Void)
        -> (@MainActor () -> Void) = { MainTimer.schedule(after: 0, $0) }) {
        self.schedule = schedule
    }

    /// Whether a re-publish is still pending.
    var isArmed: Bool { cancelPending != nil }

    /// Arm the re-publish for the next main-loop turn, superseding any pending one.
    func arm(run: @escaping @MainActor () -> Void) {
        cancel()
        cancelPending = schedule { [weak self] in
            self?.cancelPending = nil
            run()
        }
    }

    /// Disarm the pending re-publish. Idempotent, and inert once the job has already fired.
    func cancel() {
        cancelPending?()
        cancelPending = nil
    }
}
