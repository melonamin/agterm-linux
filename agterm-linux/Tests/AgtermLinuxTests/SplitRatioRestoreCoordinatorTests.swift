import Testing
import Foundation
@testable import AgtermLinux

@Suite("split ratio restore ownership")
struct SplitRatioRestoreCoordinatorTests {
    @Test("superseding and cancelling restores remove the owned source")
    @MainActor
    func cancellation() {
        var removed: [UInt32] = []
        let coordinator = SplitRatioRestoreCoordinator { _, callbackID in removed.append(callbackID) }
        let windowID = UUID()
        let sessionID = UUID()
        let paned = OpaquePointer(bitPattern: 0x100)!

        let first = coordinator.begin(windowID: windowID, sessionID: sessionID, paned: paned)
        coordinator.setCallback(41, paned: paned, sessionID: sessionID, generation: first)
        let second = coordinator.begin(windowID: windowID, sessionID: sessionID, paned: paned)
        #expect(removed == [41])
        #expect(second != first)
        #expect(coordinator.isSuppressed(sessionID))

        coordinator.setCallback(42, paned: paned, sessionID: sessionID, generation: second)
        coordinator.cancelAll()
        #expect(removed == [41, 42])
        #expect(!coordinator.isSuppressed(sessionID))
    }

    @Test("a hidden restore can wait for mapping without owning a frame callback")
    @MainActor
    func waitsForMapping() {
        var removed: [UInt32] = []
        let coordinator = SplitRatioRestoreCoordinator { _, callbackID in removed.append(callbackID) }
        let windowID = UUID()
        let sessionID = UUID()
        let paned = OpaquePointer(bitPattern: 0x180)!
        let generation = coordinator.begin(windowID: windowID, sessionID: sessionID, paned: paned)

        #expect(coordinator.pending[sessionID]?.callbackID == 0)
        coordinator.setCallback(41, paned: paned, sessionID: sessionID, generation: generation)
        coordinator.clearCallback(41, sessionID: sessionID, generation: generation)
        #expect(coordinator.pending[sessionID]?.callbackID == 0)
        #expect(coordinator.isSuppressed(sessionID))
        #expect(removed.isEmpty)

        coordinator.setCallback(42, paned: paned, sessionID: sessionID, generation: generation)
        coordinator.cancel(sessionID: sessionID)
        #expect(removed == [42])
    }

    @Test("stale generations cannot clear or adopt a newer restore")
    @MainActor
    func staleGeneration() {
        var removed: [UInt32] = []
        let coordinator = SplitRatioRestoreCoordinator { _, callbackID in removed.append(callbackID) }
        let windowID = UUID()
        let sessionID = UUID()
        let paned = OpaquePointer(bitPattern: 0x200)!
        let generation = coordinator.begin(windowID: windowID, sessionID: sessionID, paned: paned)

        coordinator.setCallback(9, paned: paned, sessionID: sessionID, generation: generation &- 1)
        coordinator.complete(sessionID: sessionID, generation: generation &- 1)
        #expect(removed == [9])
        #expect(coordinator.matches(
            windowID: windowID, sessionID: sessionID, paned: paned, generation: generation))
    }
}
