import CGtk
import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

@MainActor
extension AppController {
    func swapSessionPanes(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id): return swapSessionPanes(id)
        }
    }

    func swapSessionPanes(_ id: UUID) -> ControlResponse {
        var refusal = store.swapPanes(id)
        if refusal == .slotNotRealized {
            for _ in 0..<12 {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(30_000)
                refusal = store.swapPanes(id)
                if refusal != .slotNotRealized { break }
            }
        }
        if let refusal {
            let error: String
            switch refusal {
            case .noSession: error = "session closed during swap"
            case .noSplit: error = "session has no split pane"
            case .slotNotRealized: error = "session not realized"
            case .roleNotMutable: error = "session panes do not support swapping"
            }
            return ControlResponse(ok: false, error: error)
        }
        guard let session = store.session(withID: id),
              let primary = session.surface as? GhosttySurface,
              let split = session.splitSurface as? GhosttySurface else {
            return ControlResponse(ok: false, error: "session closed during swap")
        }
        // The realized GtkGLArea widgets never move. Rebind the role-indexed maps (and their fixed host
        // widgets) to the model's newly exchanged surface slots instead.
        surfaces[id] = primary
        splitSurfaces[id] = split
        (primaryPaneHosts[id], splitPaneHosts[id]) = (splitPaneHosts[id], primaryPaneHosts[id])
        (leftOverlaySurfaces[id], rightOverlaySurfaces[id]) =
            (rightOverlaySurfaces[id], leftOverlaySurfaces[id])
        (leftOverlayWashes[id], rightOverlayWashes[id]) =
            (rightOverlayWashes[id], leftOverlayWashes[id])
        (leftOverlayWashProviders[id], rightOverlayWashProviders[id]) =
            (rightOverlayWashProviders[id], leftOverlayWashProviders[id])
        NotificationManager.withdraw(windowID: windowID, sessionID: id)
        refreshSidebar()
        updateTitle()
        sessionFocusTarget(for: id)?.grabFocus(supersedingPopoverCapture: true)
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
    }

    func swapActiveSessionPanes() {
        guard pickController.pending == nil,
              let id = store.selectedSessionID,
              store.session(withID: id)?.hasSplit == true else { return }
        _ = swapSessionPanes(id)
    }

    func closeActiveSplit() {
        guard let id = store.selectedSessionID, let session = store.session(withID: id),
              session.hasSplit, !session.fullOverlayActive else { return }
        if session.scratchActive {
            store.toggleScratch(id)
            reconcile()
            return
        }
        store.closeSplit(id)
        reconcile()
        sessionFocusTarget(for: id, wantSplit: false)?.grabFocus(supersedingPopoverCapture: true)
    }

    @discardableResult
    func navigateWorkspace(_ direction: WorkspaceNavigation, userInitiated: Bool = true) -> WorkspaceStep? {
        if userInitiated { noteUserActivity() }
        guard let step = store.navigateWorkspace(direction) else { return nil }
        reconcile()
        syncSidebarSelection()
        return step
    }

    func toggleCurrentWorkspaceCollapse() {
        guard store.sidebarMode == .tree, let id = store.currentWorkspaceID else { return }
        store.setWorkspaceExpanded(id, expanded: store.isCurrentWorkspaceCollapsed)
        rebuildSidebarKeepingKeyboard()
    }
}
