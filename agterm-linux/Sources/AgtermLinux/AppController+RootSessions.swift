import Foundation
import agtermCore

@MainActor
extension AppController {
    func newRootSession() {
        guard let root = store.rootWorkspace else { return }
        newSession(in: root.id)
    }

    func resolveNamedWorkspaceResponse(_ target: String?) -> ResolveResponse<UUID> {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return .failure(response)
        case .success(let id):
            if let refusal = store.rootRefusal(id) { return .failure(refusal) }
            return .success(id)
        }
    }
}
