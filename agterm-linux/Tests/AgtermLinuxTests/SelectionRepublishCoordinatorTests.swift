import Foundation
import Testing
@testable import AgtermLinux

/// Records every schedule so a test can fire or inspect one deterministically; the coordinator takes
/// its scheduler by injection, so nothing here touches the process-global `MainTimer` seam.
@MainActor
private final class ScheduleRecorder {
    private(set) var cancelled: [Bool] = []
    private var fires: [@MainActor () -> Void] = []

    func schedule(_ fire: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let index = cancelled.count
        cancelled.append(false)
        fires.append(fire)
        return { [weak self] in self?.cancelled[index] = true }
    }

    func fire(_ index: Int) { fires[index]() }
}

/// The post-rebuild re-publish's ownership contract: a fire after `windowWillClose` would run
/// `syncSidebarSelectionStyles` against destroyed GTK rows, so the disarm and the rearm must hold.
@Suite("selection re-publish ownership")
@MainActor
struct SelectionRepublishCoordinatorTests {
    @Test("an armed re-publish runs once and leaves nothing to disarm")
    func armedRepublishRuns() {
        let recorder = ScheduleRecorder()
        let coordinator = SelectionRepublishCoordinator(schedule: { recorder.schedule($0) })
        var republishes = 0

        coordinator.arm { republishes += 1 }
        #expect(coordinator.isArmed)
        #expect(republishes == 0)

        recorder.fire(0)
        #expect(republishes == 1)
        #expect(!coordinator.isArmed)
    }

    @Test("cancel disarms the pending re-publish — the window-close teardown path")
    func cancelDisarms() {
        let recorder = ScheduleRecorder()
        let coordinator = SelectionRepublishCoordinator(schedule: { recorder.schedule($0) })
        var republishes = 0

        coordinator.arm { republishes += 1 }
        coordinator.cancel()
        #expect(recorder.cancelled == [true])
        #expect(!coordinator.isArmed)

        coordinator.cancel()            // idempotent: a second teardown must not re-cancel or crash
        #expect(recorder.cancelled.count == 1)
        #expect(republishes == 0)
    }

    @Test("every rebuild's arm supersedes the pending re-publish instead of orphaning it")
    func rearmSupersedes() {
        let recorder = ScheduleRecorder()
        let coordinator = SelectionRepublishCoordinator(schedule: { recorder.schedule($0) })
        var republishes = 0

        coordinator.arm { republishes += 1 }
        coordinator.arm { republishes += 1 }
        #expect(recorder.cancelled == [true, false])

        // Only the newest entry is owned, so the window-close cancel really disarms everything left.
        coordinator.cancel()
        #expect(recorder.cancelled == [true, true])
        #expect(republishes == 0)
    }
}
