import Foundation
import Testing
@testable import AgtermLinux

/// Records every armed source so a test can tick or inspect one deterministically; the coordinator takes
/// its timer by injection, so nothing here reaches GLib.
@MainActor
private final class TimerRecorder {
    private(set) var intervals: [TimeInterval] = []
    private(set) var cancelled: [Bool] = []
    private var ticks: [@MainActor () -> Bool] = []

    func start(
        _ interval: TimeInterval, _ tick: @escaping @MainActor () -> Bool
    ) -> (@MainActor () -> Void) {
        let index = intervals.count
        intervals.append(interval)
        cancelled.append(false)
        ticks.append(tick)
        return { [weak self] in self?.cancelled[index] = true }
    }

    /// Whether the GLib source survives the tick, which is what the real trampoline returns.
    @discardableResult
    func tick(_ index: Int) -> Bool { ticks[index]() }
}

private final class RetainToken {}

@Suite("blink phase coordinator")
@MainActor
struct BlinkPhaseCoordinatorTests {
    @Test("a resync that should run arms one source at the half period and applies nothing")
    func armsOnce() {
        let recorder = TimerRecorder()
        let coordinator = BlinkPhaseCoordinator(start: { recorder.start($0, $1) })
        var applied: [Bool] = []

        coordinator.resync(shouldRun: true) { applied.append($0) }
        #expect(coordinator.isArmed)
        #expect(!coordinator.phase)
        #expect(recorder.intervals == [LinuxBlinkPolicy.halfPeriod])
        #expect(applied.isEmpty)
    }

    @Test("a resync while armed neither adds a source nor applies a phase")
    func resyncWhileArmedIsInert() {
        let recorder = TimerRecorder()
        let coordinator = BlinkPhaseCoordinator(start: { recorder.start($0, $1) })
        var applied: [Bool] = []

        coordinator.resync(shouldRun: true) { applied.append($0) }
        coordinator.resync(shouldRun: true) { applied.append($0) }
        #expect(recorder.intervals.count == 1)
        #expect(recorder.cancelled == [false])
        #expect(applied.isEmpty)
    }

    @Test("each tick flips the phase and applies it")
    func tickFlipsPhase() {
        let recorder = TimerRecorder()
        let coordinator = BlinkPhaseCoordinator(start: { recorder.start($0, $1) })
        var applied: [Bool] = []

        coordinator.resync(shouldRun: true) { applied.append($0) }
        recorder.tick(0)
        #expect(coordinator.phase)
        recorder.tick(0)
        #expect(!coordinator.phase)
        #expect(applied == [true, false])
    }

    @Test("a resync that should not run cancels and restores full opacity")
    func resyncFalseCancels() {
        let recorder = TimerRecorder()
        let coordinator = BlinkPhaseCoordinator(start: { recorder.start($0, $1) })
        var applied: [Bool] = []

        coordinator.resync(shouldRun: true) { applied.append($0) }
        recorder.tick(0)
        applied.removeAll()

        coordinator.resync(shouldRun: false) { applied.append($0) }
        #expect(recorder.cancelled == [true])
        #expect(!coordinator.isArmed)
        #expect(!coordinator.phase)
        #expect(applied == [false])
    }

    @Test("a resync that should not run while unarmed touches nothing")
    func resyncFalseWhileUnarmedIsANoOp() {
        let recorder = TimerRecorder()
        let coordinator = BlinkPhaseCoordinator(start: { recorder.start($0, $1) })
        var applied: [Bool] = []

        coordinator.resync(shouldRun: false) { applied.append($0) }
        #expect(recorder.intervals.isEmpty)
        #expect(applied.isEmpty)
    }

    @Test("cancel is idempotent and a late tick is inert — the window-close teardown path")
    func cancelIsIdempotentAndSwallowsLateTicks() {
        let recorder = TimerRecorder()
        let coordinator = BlinkPhaseCoordinator(start: { recorder.start($0, $1) })
        var applied: [Bool] = []

        coordinator.resync(shouldRun: true) { applied.append($0) }
        coordinator.cancel()
        coordinator.cancel()
        #expect(recorder.cancelled == [true])

        recorder.tick(0)
        #expect(!coordinator.phase)
        #expect(applied.isEmpty)
    }

    @Test("a resync while armed rebinds the apply closure, so the tick reaches the current widget maps")
    func resyncWhileArmedRebindsApply() {
        let recorder = TimerRecorder()
        let coordinator = BlinkPhaseCoordinator(start: { recorder.start($0, $1) })
        var first: [Bool] = []
        var second: [Bool] = []

        coordinator.resync(shouldRun: true) { first.append($0) }
        coordinator.resync(shouldRun: true) { second.append($0) }
        recorder.tick(0)
        #expect(first.isEmpty)
        #expect(second == [true])
    }

    @Test("an orphaned source removes itself on its first fire instead of waking the loop forever")
    func deallocatedCoordinatorStopsItsSource() {
        let recorder = TimerRecorder()
        var coordinator: BlinkPhaseCoordinator? = BlinkPhaseCoordinator(start: { recorder.start($0, $1) })
        coordinator?.resync(shouldRun: true) { _ in }
        coordinator = nil

        #expect(!recorder.tick(0))
    }

    @Test("cancel drops the apply closure instead of retaining the widget maps it captures")
    func cancelReleasesTheApplyClosure() {
        let recorder = TimerRecorder()
        let coordinator = BlinkPhaseCoordinator(start: { recorder.start($0, $1) })
        var token: RetainToken? = RetainToken()
        weak var observed = token

        coordinator.resync(shouldRun: true) { [token] _ in _ = token }
        token = nil
        #expect(observed != nil)

        coordinator.cancel()
        #expect(observed == nil)
    }
}
