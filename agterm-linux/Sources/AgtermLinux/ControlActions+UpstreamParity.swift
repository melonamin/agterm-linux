import Foundation
import agtermCore

/// Linux host actions added by upstream protocol releases.
/// Kept beside the main adapter so that already-large compatibility surface stays within the lint limit.
@MainActor
extension AppController {
    func applySessionWatermark(_ id: UUID) {
        surfaces[id]?.applyWatermarkFromSession()
        splitSurfaces[id]?.applyWatermarkFromSession()
        scratchSurfaces[id]?.applyWatermarkFromSession()
    }

    func readEvents(_ options: ControlEventReadOptions) -> ControlResponse {
        library.readEvents(options)
    }

    func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            store.setWorkspaceExpanded(id, expanded: expanded)
            rebuildSidebarKeepingKeyboard()
            syncSidebarSelection()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func setSessionRestore(_ target: String?, window: String?,
                           update: ControlSessionRestoreUpdate) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id): return applySessionRestore(id: id, update: update)
        }
    }

    private func applySessionRestore(id: UUID, update: ControlSessionRestoreUpdate) -> ControlResponse {
        guard let session = store.session(withID: id) else {
            return ControlResponse(ok: false, error: "no such session")
        }
        let pane: StatusPane
        if let token = update.paneID, !token.isEmpty {
            guard let resolved = session.paneRole(forToken: token) ?? update.pane else {
                return ControlResponse(ok: false, error: "unknown pane id: \(token)")
            }
            pane = resolved
        } else {
            pane = update.pane ?? .left
        }
        guard pane != .scratch else {
            return ControlResponse(ok: false, error: "the scratch terminal is never restored")
        }
        guard pane != .right || session.hasSplit else {
            return ControlResponse(ok: false, error: "session has no split")
        }

        let value: String?
        switch update.pin {
        case .pin(let command): value = command
        case .pinNone: value = ""
        case .unpin: value = nil
        }
        guard store.setRestoreCommand(value, pane: pane, forSession: id) else {
            return ControlResponse(
                ok: false,
                error: "failed to save the restore override, the previous value is still in effect"
            )
        }
        var result = ControlResult(id: id.uuidString)
        if case .pin = update.pin, linuxSettingsStore().load().restoreRunningCommand != true {
            result.text = "saved, but \"Restore running commands on restart\" is off, so the override will not run"
        }
        return ControlResponse(ok: true, result: result)
    }
}
