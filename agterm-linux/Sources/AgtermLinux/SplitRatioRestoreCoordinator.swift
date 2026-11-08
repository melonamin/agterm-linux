import CGtk
import Foundation

@MainActor
final class SplitRatioRestoreCoordinator {
    struct Pending: Equatable {
        let windowID: UUID
        let sessionID: UUID
        let paned: OpaquePointer
        let generation: UInt64
        var callbackID: guint
    }

    private(set) var pending: [UUID: Pending] = [:]
    private var nextGeneration: UInt64 = 0
    private let removeCallback: (OpaquePointer, guint) -> Void

    init(removeCallback: @escaping (OpaquePointer, guint) -> Void = {
        gtk_widget_remove_tick_callback(W($0), $1)
    }) {
        self.removeCallback = removeCallback
    }

    func begin(windowID: UUID, sessionID: UUID, paned: OpaquePointer) -> UInt64 {
        cancel(sessionID: sessionID)
        nextGeneration &+= 1
        pending[sessionID] = Pending(
            windowID: windowID, sessionID: sessionID, paned: paned,
            generation: nextGeneration, callbackID: 0)
        return nextGeneration
    }

    func setCallback(_ callbackID: guint, paned: OpaquePointer, sessionID: UUID, generation: UInt64) {
        guard var value = pending[sessionID], value.generation == generation, value.paned == paned else {
            removeCallback(paned, callbackID)
            return
        }
        value.callbackID = callbackID
        pending[sessionID] = value
    }

    func matches(windowID: UUID, sessionID: UUID, paned: OpaquePointer, generation: UInt64) -> Bool {
        pending[sessionID] == Pending(
            windowID: windowID, sessionID: sessionID, paned: paned,
            generation: generation, callbackID: pending[sessionID]?.callbackID ?? 0)
    }

    func clearCallback(_ callbackID: guint, sessionID: UUID, generation: UInt64) {
        guard pending[sessionID]?.generation == generation,
              pending[sessionID]?.callbackID == callbackID else { return }
        pending[sessionID]?.callbackID = 0
    }

    func complete(sessionID: UUID, generation: UInt64) {
        guard pending[sessionID]?.generation == generation else { return }
        pending[sessionID] = nil
    }

    func cancel(sessionID: UUID) {
        guard let value = pending.removeValue(forKey: sessionID) else { return }
        if value.callbackID != 0 { removeCallback(value.paned, value.callbackID) }
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
    var callbackID: guint = 0
    var ticks = 0

    init(controller: AppController, sessionID: UUID, paned: OpaquePointer, generation: UInt64) {
        self.controller = controller
        windowID = controller.windowID
        self.sessionID = sessionID
        self.paned = paned
        self.generation = generation
    }
}
