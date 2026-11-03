import Foundation
import agtermCore

@MainActor
extension AppController {
    func closeSession(_ target: String?, window: String?, undoable: Bool) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id): return closeResolvedSessions([id], undoable: undoable)
        }
    }

    func closeSessions(_ targets: [String], window: String?, undoable: Bool) -> ControlResponse {
        var ids: [UUID] = []
        for target in targets {
            switch resolveSessionResponse(target) {
            case .failure(let response): return response
            case .success(let id): if !ids.contains(id) { ids.append(id) }
            }
        }
        guard !ids.isEmpty else { return err("session.close requires at least one --target") }
        return closeResolvedSessions(ids, undoable: undoable)
    }

    private func closeResolvedSessions(_ ids: [UUID], undoable: Bool) -> ControlResponse {
        let named = Set(ids)
        let roots = ids.filter { store.session(withID: $0)?.parentID.map(named.contains) != true }
        let closing = roots.flatMap { [$0] + store.companions(of: $0).map(\.id) }
        let soft = (ids.count > 1 || undoable) && (linuxSettingsStore().load().closeGraceUndoEnabled ?? true)
        if soft {
            let closed = ids.count == 1 ? store.softCloseSession(ids[0]) : store.softCloseSessions(ids)
            guard closed else { return err("could not close session") }
            reconcileSoftClose()
        } else {
            for id in roots { store.closeSession(id) }
            reconcile(focusActive: false)
        }
        return ControlResponse(ok: true, result: ControlResult(
            id: ids.count == 1 ? ids[0].uuidString : nil,
            affected: ids.count > 1 || closing.count > 1 ? closing.count : nil,
            undoable: undoable ? soft : nil, closed: closing.map(\.uuidString)))
    }
}
