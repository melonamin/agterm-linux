import Foundation
import agtermCore

@MainActor
extension AppController {
    func setSessionTint(_ target: String?, window: String?, update: ControlTintUpdate) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            store.setTint(update.resolved(over: session.tint), forSession: id)
            syncSidebar()
            return ok(id)
        }
    }

    func setWorkspaceTint(_ target: String?, window: String?, update: ControlTintUpdate) -> ControlResponse {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            let current = store.workspaces.first { $0.id == id }?.tint
            store.setTint(update.resolved(over: current), forWorkspace: id)
            syncSidebar()
            return ok(id)
        }
    }

    func moveFlaggedSession(_ target: String?, window: String?, anchor: String,
                            placement: FlaggedOrderPlacement) -> ControlResponse {
        let id: UUID
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let resolved): id = resolved
        }
        switch resolveSessionResponse(anchor) {
        case .failure(let response): return response
        case .success(let other):
            guard id != other else { return err("a session cannot be its own anchor") }
            guard store.session(withID: id)?.flagged == true,
                  store.session(withID: other)?.flagged == true else { return err("session.flag move needs a flagged session and a flagged anchor") }
            store.moveFlagged([id], to: placement, of: other)
            syncSidebar(preferMoving: [id])
            return ok(id)
        }
    }

    func setWorkspaceFlag(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            store.applyWorkspaceFlag(mode, to: id)
            reconcile(focusActive: false)
            return ok(id)
        }
    }
}
