import Foundation
import agtermCore

/// Owns the trailing deck reconcile a soft close arms (`AppController.reconcileSoftClose`): ONE
/// cancellable, re-armable `MainTimer` job that drops the deck pages of sessions whose grace expired
/// without an undo.
///
/// It is a coordinator rather than a bare fire-and-forget `MainTimer.schedule` because that job carries two
/// hazards now that main-actor timers really fire on Linux:
///
/// - **It must be disarmable.** The job outlives its window whenever something still retains the controller
///   (an open Settings dialog, the command palette, or the theme picker all `passRetained` it), and
///   `windowWillClose` runs synchronously inside the close-request handler — GTK destroys the widget tree
///   right after. A later fire would rebuild an already-destroyed sidebar and deck, so `cancel()` in
///   `windowWillClose` is what keeps `[weak self]` from being the only defense.
/// - **It must not land on top of a sidebar interaction.** The reconcile rebuilds the sidebar, which
///   destroys an in-progress inline rename entry (whose disposal fires a focus-out that commits the
///   half-typed text) and dismisses an open context menu — from a timer the user never asked for. So a fire
///   that lands mid-interaction re-arms at a slower cadence instead of running, exactly like the
///   sidebar-metadata refresh; whichever action ends the interaction reconciles anyway, and the retry is
///   then a cheap no-op.
///
/// Arming again supersedes the pending job. Every caller passes the same grace, so the newest arm always
/// fires no earlier than the one it replaces and therefore covers it.
@MainActor
final class SoftCloseReconcileCoordinator {
    private var cancelPending: (@MainActor () -> Void)?
    /// How long a fire that landed mid-interaction waits before re-checking. Injected rather than owned: the
    /// cadence belongs to whatever `deferWhile` gates on (for the deck reconcile, the sidebar interaction —
    /// `AppController.sidebarInteractionRetryInterval`), not to this coordinator.
    private let retryInterval: TimeInterval
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    init(retryInterval: TimeInterval,
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void)
        -> (@MainActor () -> Void) = { MainTimer.schedule(after: $0, $1) }) {
        self.retryInterval = retryInterval
        self.schedule = schedule
    }

    /// Whether a reconcile is still outstanding — armed, or deferred behind a sidebar interaction.
    var isArmed: Bool { cancelPending != nil }

    /// Arm the trailing reconcile, superseding any pending one. `deferWhile` is re-evaluated at fire time,
    /// not at arm time, so an interaction that starts during the grace still defers the rebuild.
    func arm(after delay: TimeInterval,
             deferWhile: @escaping @MainActor () -> Bool,
             run: @escaping @MainActor () -> Void) {
        cancel()
        cancelPending = schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelPending = nil
            guard !deferWhile() else {
                self.arm(after: self.retryInterval, deferWhile: deferWhile, run: run)
                return
            }
            run()
        }
    }

    /// Disarm the pending reconcile. Idempotent, and inert once the job has already fired.
    func cancel() {
        cancelPending?()
        cancelPending = nil
    }
}
