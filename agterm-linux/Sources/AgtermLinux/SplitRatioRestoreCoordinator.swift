import CGtk
import Foundation

@MainActor
final class SplitRatioRestoreCoordinator {
    struct Pending: Equatable {
        let windowID: UUID
        let sessionID: UUID
        let paned: OpaquePointer
        let generation: UInt64
        var sourceID: guint
    }

    private(set) var pending: [UUID: Pending] = [:]
    private var nextGeneration: UInt64 = 0
    private let removeSource: (guint) -> Void

    init(removeSource: @escaping (guint) -> Void = { _ = g_source_remove($0) }) {
        self.removeSource = removeSource
    }

    func begin(windowID: UUID, sessionID: UUID, paned: OpaquePointer) -> UInt64 {
        cancel(sessionID: sessionID)
        nextGeneration &+= 1
        pending[sessionID] = Pending(
            windowID: windowID, sessionID: sessionID, paned: paned,
            generation: nextGeneration, sourceID: 0)
        return nextGeneration
    }

    func setSource(_ sourceID: guint, sessionID: UUID, generation: UInt64) {
        guard var value = pending[sessionID], value.generation == generation else {
            removeSource(sourceID)
            return
        }
        value.sourceID = sourceID
        pending[sessionID] = value
    }

    func matches(windowID: UUID, sessionID: UUID, paned: OpaquePointer, generation: UInt64) -> Bool {
        pending[sessionID] == Pending(
            windowID: windowID, sessionID: sessionID, paned: paned,
            generation: generation, sourceID: pending[sessionID]?.sourceID ?? 0)
    }

    func complete(sessionID: UUID, generation: UInt64) {
        guard pending[sessionID]?.generation == generation else { return }
        pending[sessionID] = nil
    }

    func cancel(sessionID: UUID) {
        guard let value = pending.removeValue(forKey: sessionID) else { return }
        if value.sourceID != 0 { removeSource(value.sourceID) }
    }

    func cancelAll() {
        for sessionID in Array(pending.keys) { cancel(sessionID: sessionID) }
    }

    func isSuppressed(_ sessionID: UUID) -> Bool {
        pending[sessionID] != nil
    }
}

@MainActor
final class SplitRatioRestoreTickContext {
    weak var controller: AppController?
    let windowID: UUID
    let sessionID: UUID
    let paned: OpaquePointer
    let generation: UInt64

    init(controller: AppController, sessionID: UUID, paned: OpaquePointer, generation: UInt64) {
        self.controller = controller
        windowID = controller.windowID
        self.sessionID = sessionID
        self.paned = paned
        self.generation = generation
    }
}
