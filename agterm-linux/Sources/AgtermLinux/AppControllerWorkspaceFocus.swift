import Foundation
import agtermCore

@MainActor
extension AppController {
    /// Focus the sidebar on a single workspace, or clear the marked set (nil).
    func focusWorkspace(_ workspaceID: UUID?) {
        if let workspaceID {
            store.applyFocusMode(.on, to: workspaceID)
        } else {
            store.clearFocus()
        }
        syncSidebar()
    }

    /// Replace-toggle the focus set with the active workspace.
    func focusActiveWorkspace() {
        guard let current = store.currentWorkspaceID else { return }
        store.toggleFocusedWorkspace(current)
        syncSidebar()
    }

    func addActiveWorkspaceToFocus() {
        guard let current = store.currentWorkspaceID else { return }
        store.setFocusMembership(current, member: true)
        syncSidebar()
    }

    func toggleWorkspaceFilter() {
        store.applyWorkspaceFilter(.toggle)
        syncSidebar()
    }
}
