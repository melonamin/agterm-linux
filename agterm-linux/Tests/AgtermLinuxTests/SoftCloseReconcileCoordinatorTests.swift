import Foundation
import Testing
@testable import AgtermLinux

/// Records every `MainTimer`-shaped schedule so a test can fire or inspect one deterministically. The
/// coordinator takes its scheduler by injection (the `SplitRatioRestoreCoordinator` pattern), so nothing
/// here touches the process-global `MainTimer.scheduleTimer` seam — which is also why this is NOT the core
/// suite's `TimerRecorder`: that one records cancels as a list of indices because it catches every unrelated
/// debouncer in the process, while this one owns its coordinator's schedules alone and tracks them by flag.
@MainActor
private final class ScheduleRecorder {
    private(set) var delays: [TimeInterval] = []
    private(set) var cancelled: [Bool] = []
    private var fires: [@MainActor () -> Void] = []

    func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let index = delays.count
        delays.append(delay)
        cancelled.append(false)
        fires.append(fire)
        return { [weak self] in self?.cancelled[index] = true }
    }

    func fire(_ index: Int) { fires[index]() }
}

/// The trailing soft-close reconcile's ownership contract: it must be disarmable (a fire after
/// `windowWillClose` rebuilds a destroyed GTK widget tree) and it must not rebuild the sidebar on top of a
/// live inline rename or an open context menu (the rebuild commits the rename's half-typed text).
@Suite("soft-close reconcile ownership")
@MainActor
struct SoftCloseReconcileCoordinatorTests {
    /// A retry cadence distinct from the production `AppController.sidebarInteractionRetryInterval`, so the
    /// deferral tests prove the INJECTED value is what a deferred fire re-arms at.
    private static let retryInterval: TimeInterval = 0.5

    private func makeCoordinator(_ recorder: ScheduleRecorder) -> SoftCloseReconcileCoordinator {
        SoftCloseReconcileCoordinator(retryInterval: Self.retryInterval, schedule: { recorder.schedule($0, $1) })
    }

    @Test("an armed reconcile runs once at the requested delay when nothing is interacting")
    func armedReconcileRuns() {
        let recorder = ScheduleRecorder()
        let coordinator = makeCoordinator(recorder)
        var reconciles = 0

        coordinator.arm(after: 3.1, deferWhile: { false }, run: { reconciles += 1 })
        #expect(recorder.delays == [3.1])
        #expect(coordinator.isArmed)
        #expect(reconciles == 0)

        recorder.fire(0)
        #expect(reconciles == 1)
        #expect(!coordinator.isArmed)   // one-shot: nothing left for `windowWillClose` to disarm
    }

    @Test("cancel disarms the pending reconcile — the window-close teardown path")
    func cancelDisarms() {
        let recorder = ScheduleRecorder()
        let coordinator = makeCoordinator(recorder)
        var reconciles = 0

        coordinator.arm(after: 3.1, deferWhile: { false }, run: { reconciles += 1 })
        coordinator.cancel()
        #expect(recorder.cancelled == [true])
        #expect(!coordinator.isArmed)

        coordinator.cancel()            // idempotent: a second teardown must not re-cancel or crash
        #expect(recorder.delays.count == 1)
        #expect(reconciles == 0)
    }

    @Test("arming again supersedes the pending reconcile instead of orphaning it")
    func rearmSupersedes() {
        let recorder = ScheduleRecorder()
        let coordinator = makeCoordinator(recorder)
        var reconciles = 0

        coordinator.arm(after: 3.1, deferWhile: { false }, run: { reconciles += 1 })
        coordinator.arm(after: 3.1, deferWhile: { false }, run: { reconciles += 1 })
        #expect(recorder.cancelled == [true, false])

        // Only the newest entry is owned, so the window-close cancel really disarms everything left.
        coordinator.cancel()
        #expect(recorder.cancelled == [true, true])
        #expect(reconciles == 0)
    }

    @Test("a fire during a sidebar interaction defers instead of rebuilding")
    func fireDuringInteractionDefers() {
        let recorder = ScheduleRecorder()
        let coordinator = makeCoordinator(recorder)
        var interacting = true
        var reconciles = 0

        coordinator.arm(after: 3.1, deferWhile: { interacting }, run: { reconciles += 1 })
        recorder.fire(0)
        #expect(reconciles == 0)                                        // the rename survived
        #expect(recorder.delays == [3.1, Self.retryInterval])
        #expect(coordinator.isArmed)

        interacting = false
        recorder.fire(1)
        #expect(reconciles == 1)
        #expect(!coordinator.isArmed)
    }

    @Test("a deferred retry is still cancellable")
    func deferredRetryIsCancellable() {
        let recorder = ScheduleRecorder()
        let coordinator = makeCoordinator(recorder)
        var reconciles = 0

        coordinator.arm(after: 3.1, deferWhile: { true }, run: { reconciles += 1 })
        recorder.fire(0)
        recorder.fire(1)                                                // still interacting -> defers again
        #expect(recorder.delays.count == 3)

        coordinator.cancel()
        #expect(recorder.cancelled == [false, false, true])             // fired entries stay inert
        #expect(!coordinator.isArmed)
        #expect(reconciles == 0)
    }
}
