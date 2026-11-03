import CGtk

/// Owns the frame-aligned retry that scrolls a just-revealed sidebar row into view once GTK has
/// allocated it. At most one is pending per window; the widget-scoped callback id and the supersede
/// rule are in `agterm-linux/docs/main-loop.md`.
@MainActor
final class SidebarScrollRetryCoordinator {
    struct Pending: Equatable {
        let row: OpaquePointer
        let generation: UInt64
        var callbackID: guint
    }

    private(set) var pending: Pending?
    private var nextGeneration: UInt64 = 0
    private let removeCallback: (OpaquePointer, guint) -> Void

    init(removeCallback: @escaping (OpaquePointer, guint) -> Void = {
        gtk_widget_remove_tick_callback(W($0), $1)
    }) {
        self.removeCallback = removeCallback
    }

    /// Claims the pending slot for `row`, then runs `attempt` and returns the generation a tick must
    /// carry — nil when the attempt resolved and nothing is left waiting. The claim happens BEFORE the
    /// attempt because a request that resolves immediately must still supersede an earlier row's tick,
    /// which would otherwise fire a frame later and scroll back to that row.
    func request(row: OpaquePointer, attempt: () -> Bool) -> UInt64? {
        let generation = begin(row: row)
        guard attempt() else {
            complete(generation: generation)
            return nil
        }
        return generation
    }

    private func begin(row: OpaquePointer) -> UInt64 {
        cancelAll()
        nextGeneration &+= 1
        pending = Pending(row: row, generation: nextGeneration, callbackID: 0)
        return nextGeneration
    }

    /// Adopts the id the attach returned. A superseded request removes it right back: the caller had to
    /// attach before it could be told the request is stale.
    func setCallback(_ callbackID: guint, row: OpaquePointer, generation: UInt64) {
        guard var value = pending, value.generation == generation, value.row == row else {
            removeCallback(row, callbackID)
            return
        }
        value.callbackID = callbackID
        pending = value
    }

    func matches(row: OpaquePointer, generation: UInt64) -> Bool {
        pending?.row == row && pending?.generation == generation
    }

    /// Drops a finished request WITHOUT removing its callback — the tick returns `G_SOURCE_REMOVE`
    /// itself, and the destroy notify uses this too when GTK disposes the row first.
    func complete(generation: UInt64) {
        guard pending?.generation == generation else { return }
        pending = nil
    }

    /// External cancellation. Clears before removing, so the destroy notify the removal fires finds
    /// nothing left to match.
    func cancelAll() {
        guard let value = pending else { return }
        pending = nil
        if value.callbackID != 0 { removeCallback(value.row, value.callbackID) }
    }
}

/// What one attached tick carries across the C boundary. `ticks` counts the frames this request has
/// waited, which is what bounds the retry.
@MainActor
final class SidebarScrollRetryContext {
    weak var controller: AppController?
    let row: OpaquePointer
    let generation: UInt64
    var ticks = 0

    init(controller: AppController, row: OpaquePointer, generation: UInt64) {
        self.controller = controller
        self.row = row
        self.generation = generation
    }
}
