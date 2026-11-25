import Foundation
import agtermCore

@MainActor
extension AppController {
    /// Resolve after discovery and payload validation, so failed attaches cannot leave an empty workspace.
    func attachWorkspace(_ target: ControlAttachWorkspace?) -> ResolveResponse<UUID> {
        switch target {
        case nil:
            guard let id = store.currentWorkspaceID else { return .failure(err("no window to attach into")) }
            return .success(id)
        case .id(let raw): return resolveWorkspaceResponse(raw)
        case .name(let name, let create):
            if let found = store.workspace(named: name) { return .success(found.id) }
            guard create else { return .failure(err("no workspace named \"\(name)\" (pass --create-workspace to add it)")) }
            guard let workspace = store.ensureWorkspace(named: name) else { return .failure(err("the workspace to attach into could not be created")) }
            return .success(workspace.id)
        }
    }
}
