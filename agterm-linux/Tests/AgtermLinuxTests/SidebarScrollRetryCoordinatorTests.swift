import Testing
@testable import AgtermLinux

@Suite("sidebar scroll retry ownership")
struct SidebarScrollRetryCoordinatorTests {
    @Test("a superseding request removes the previous row's callback through that row")
    @MainActor
    func supersedeRemovesThroughTheOwningRow() {
        var removed: [(Int, UInt32)] = []
        let coordinator = SidebarScrollRetryCoordinator { removed.append((Int(bitPattern: $0), $1)) }
        let first = OpaquePointer(bitPattern: 0x100)!
        let second = OpaquePointer(bitPattern: 0x200)!

        let older = coordinator.request(row: first, attempt: { true })!
        coordinator.setCallback(7, row: first, generation: older)
        let newer = coordinator.request(row: second, attempt: { true })!
        #expect(removed.map(\.0) == [0x100])
        #expect(removed.map(\.1) == [7])
        #expect(newer != older)
        #expect(coordinator.matches(row: second, generation: newer))
        #expect(!coordinator.matches(row: first, generation: older))

        coordinator.setCallback(8, row: second, generation: newer)
        coordinator.cancelAll()
        #expect(removed.map(\.0) == [0x100, 0x200])
        #expect(removed.map(\.1) == [7, 8])
        #expect(coordinator.pending == nil)
    }

    @Test("a request whose attempt resolves still supersedes the row waiting before it")
    @MainActor
    func resolvedRequestSupersedesTheWaitingRow() {
        var removed: [(Int, UInt32)] = []
        let coordinator = SidebarScrollRetryCoordinator { removed.append((Int(bitPattern: $0), $1)) }
        let waiting = OpaquePointer(bitPattern: 0x700)!
        let resolved = OpaquePointer(bitPattern: 0x800)!

        let generation = coordinator.request(row: waiting, attempt: { true })!
        coordinator.setCallback(9, row: waiting, generation: generation)

        #expect(coordinator.request(row: resolved, attempt: { false }) == nil)
        #expect(removed.map(\.0) == [0x700])
        #expect(removed.map(\.1) == [9])
        #expect(coordinator.pending == nil)
        #expect(!coordinator.matches(row: waiting, generation: generation))
    }

    @Test("a stale request neither adopts a callback nor clears the live one")
    @MainActor
    func staleGenerationIsRejected() {
        var removed: [UInt32] = []
        let coordinator = SidebarScrollRetryCoordinator { removed.append($1) }
        let row = OpaquePointer(bitPattern: 0x300)!
        let other = OpaquePointer(bitPattern: 0x400)!
        let generation = coordinator.request(row: row, attempt: { true })!

        coordinator.setCallback(3, row: row, generation: generation &- 1)
        coordinator.setCallback(4, row: other, generation: generation)
        coordinator.complete(generation: generation &- 1)
        #expect(removed == [3, 4])
        #expect(coordinator.matches(row: row, generation: generation))
        // A rejected adopt must not leave a foreign id on the live request for `cancelAll` to remove.
        #expect(coordinator.pending?.callbackID == 0)
        coordinator.cancelAll()
        #expect(removed == [3, 4])
        #expect(coordinator.pending == nil)
    }

    @Test("completing removes nothing — the tick and the destroy notify own that themselves")
    @MainActor
    func completeDoesNotRemoveTheCallback() {
        var removed: [UInt32] = []
        let coordinator = SidebarScrollRetryCoordinator { removed.append($1) }
        let row = OpaquePointer(bitPattern: 0x500)!
        let generation = coordinator.request(row: row, attempt: { true })!
        coordinator.setCallback(11, row: row, generation: generation)

        coordinator.complete(generation: generation)
        #expect(removed.isEmpty)
        coordinator.cancelAll()
        #expect(removed.isEmpty)
    }

    @Test("a request whose attach never returned an id cancels without removing anything")
    @MainActor
    func cancellingBeforeAnAttachRemovesNothing() {
        var removed: [UInt32] = []
        let coordinator = SidebarScrollRetryCoordinator { removed.append($1) }
        _ = coordinator.request(row: OpaquePointer(bitPattern: 0x600)!, attempt: { true })

        coordinator.cancelAll()
        #expect(removed.isEmpty)
        #expect(coordinator.pending == nil)
    }
}
