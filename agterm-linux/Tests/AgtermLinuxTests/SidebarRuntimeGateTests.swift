import Foundation
import Testing
@testable import AgtermLinux

@Suite("sidebar sync gate")
struct SidebarSyncGateTests {
    @Test("a nested call records itself and the owner drains it")
    func nestedCallIsDrained() {
        var gate = SidebarSyncGate()
        let owned = gate.enter()
        let nested = gate.enter()
        let drained = gate.takePending()
        let nothingLeft = gate.takePending()
        gate.exit()
        let ownedAgain = gate.enter()
        #expect(owned)
        #expect(!nested)
        #expect(drained)
        #expect(!nothingLeft)
        #expect(ownedAgain)
    }

    @Test("a pass that keeps re-entering is drained a bounded number of times")
    func drainIsBounded() {
        var gate = SidebarSyncGate()
        _ = gate.enter()
        _ = gate.enter()
        var passes = 0
        while gate.takePending() {
            passes += 1
            _ = gate.enter()
        }
        #expect(passes == SidebarSyncGate.maxDrainPasses)
    }

    @Test("a dropped request leaves no flag for the next unrelated sync to act on")
    func aDroppedRequestIsNotCarriedOver() {
        var gate = SidebarSyncGate()
        _ = gate.enter()
        _ = gate.enter()
        gate.exit()
        let owned = gate.enter()
        let pending = gate.takePending()
        #expect(owned)
        #expect(!pending)
    }
}

@Suite("sidebar metadata refresh gate")
struct SidebarMetadataRefreshGateTests {
    @Test("an unforced burst refreshes in place, ungated by an interaction")
    func unforcedRefreshesInPlace() {
        var gate = SidebarMetadataRefreshGate()
        gate.request(forced: false)
        let decision = gate.take(interacting: true)
        #expect(decision == .inPlace)
    }

    @Test("forced wins across a coalesced burst in either order")
    func forcedWinsAcrossABurst() {
        for order in [[true, false], [false, true]] {
            var gate = SidebarMetadataRefreshGate()
            for forced in order { gate.request(forced: forced) }
            let decision = gate.take(interacting: false)
            #expect(decision == .rebuild)
        }
    }

    @Test("a forced refresh waits behind an interaction and stays forced for its retry")
    func forcedRetriesWhileInteracting() {
        var gate = SidebarMetadataRefreshGate()
        gate.request(forced: true)
        let deferred = gate.take(interacting: true)
        let ran = gate.take(interacting: false)
        let consumed = gate.take(interacting: false)
        #expect(deferred == .retry)
        #expect(ran == .rebuild)
        #expect(consumed == .inPlace)
    }
}

@Suite("selection republish scope")
struct SelectionRepublishScopeTests {
    @Test("id scopes merge instead of superseding each other")
    func idsAccumulate() {
        var scope = SelectionRepublishScope()
        let first = UUID(), second = UUID()
        scope.add([first])
        scope.add([second])
        #expect(scope.take() == [first, second])
        #expect(scope.take() == [])
    }

    @Test("emptiness is what the sync tail arms on")
    func emptinessDrivesTheArm() {
        var scope = SelectionRepublishScope()
        #expect(scope.isEmpty)
        scope.add([])
        #expect(scope.isEmpty)
        scope.add([UUID()])
        #expect(!scope.isEmpty)
        _ = scope.take()
        #expect(scope.isEmpty)
        scope.addAll()
        #expect(!scope.isEmpty)
    }

    @Test("a rebuild's whole-sidebar scope survives a later id-scoped sync")
    func allWinsOverIds() {
        var scope = SelectionRepublishScope()
        scope.addAll()
        scope.add([UUID()])
        #expect(scope.take() == nil)
        #expect(scope.take() == [])
    }
}
