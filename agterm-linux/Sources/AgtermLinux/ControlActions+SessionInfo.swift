import Foundation
import agtermCore

/// The session owns cancellation, including a callback that has already become ready when a refresh
/// supersedes it. Keeping the armed generation in this object requires no process-global timer map.
@MainActor
private final class InfoExpiry {
    var active = true
    var cancel: (@MainActor () -> Void)?

    func discard() {
        active = false
        cancel?()
        cancel = nil
    }
}

@MainActor
extension AppController {
    func setSessionInfo(_ target: String?, window: String?, info: SessionInfo?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            session.onInfoDiscarded?()
            session.onInfoDiscarded = nil
            store.setInfo(info, forSession: id)
            if let info, info.hideAfter > 0 {
                let expiry = InfoExpiry()
                expiry.cancel = MainTimer.schedule(after: info.hideAfter) { [weak library = library, weak session] in
                    guard expiry.active, let library, session != nil, let store = library.store(forSession: id) else { return }
                    store.setInfo(nil, forSession: id)
                    if let window = library.windowID(for: store) { gWindows[window]?.syncSidebar() }
                }
                session.onInfoDiscarded = { expiry.discard() }
            }
            syncSidebar()
            return ok(id)
        }
    }
}
