import Testing
import Foundation
@testable import AgtermLinux

@Suite("split ratio restore ownership")
struct SplitRatioRestoreCoordinatorTests {
    @Test("superseding and cancelling restores remove the owned source")
    @MainActor
    func cancellation() {
        var removed: [UInt32] = []
        let coordinator = SplitRatioRestoreCoordinator { removed.append($0) }
        let windowID = UUID()
        let sessionID = UUID()
        let paned = OpaquePointer(bitPattern: 0x100)!

        let first = coordinator.begin(windowID: windowID, sessionID: sessionID, paned: paned)
        coordinator.setSource(41, sessionID: sessionID, generation: first)
        let second = coordinator.begin(windowID: windowID, sessionID: sessionID, paned: paned)
        #expect(removed == [41])
        #expect(second != first)
        #expect(coordinator.isSuppressed(sessionID))

        coordinator.setSource(42, sessionID: sessionID, generation: second)
        coordinator.cancelAll()
        #expect(removed == [41, 42])
        #expect(!coordinator.isSuppressed(sessionID))
    }

    @Test("stale generations cannot clear or adopt a newer restore")
    @MainActor
    func staleGeneration() {
        var removed: [UInt32] = []
        let coordinator = SplitRatioRestoreCoordinator { removed.append($0) }
        let windowID = UUID()
        let sessionID = UUID()
        let paned = OpaquePointer(bitPattern: 0x200)!
        let generation = coordinator.begin(windowID: windowID, sessionID: sessionID, paned: paned)

        coordinator.setSource(9, sessionID: sessionID, generation: generation &- 1)
        coordinator.complete(sessionID: sessionID, generation: generation &- 1)
        #expect(removed == [9])
        #expect(coordinator.matches(
            windowID: windowID, sessionID: sessionID, paned: paned, generation: generation))
    }
}
