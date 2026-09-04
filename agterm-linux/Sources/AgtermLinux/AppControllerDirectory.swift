import CGtk
import Foundation

@MainActor
extension AppController {
    /// Open a folder picker and retain its originating workspace while the async chooser is visible.
    func openDirectory() {
        guard let workspaceID = store.currentWorkspaceID else { return }
        noteUserActivity()
        suppressAutoFollow()
        let dialog = gtk_file_dialog_new()
        "Open Directory".withCString { gtk_file_dialog_set_title(dialog, $0) }
        let context = DirectoryChooserContext(controller: self, workspaceID: workspaceID)
        gtk_file_dialog_select_folder(
            dialog, WIN(window), nil, onDirectoryChosen,
            Unmanaged.passRetained(context).toOpaque())
    }

    /// Create and select a session in the captured chooser workspace.
    func createSessionInDirectory(_ cwd: String, workspaceID: UUID? = nil) {
        guard let workspaceID = workspaceID ?? store.currentWorkspaceID,
              let session = store.addSession(toWorkspace: workspaceID, cwd: cwd) else { return }
        reconcile()
        selectSession(session.id)
    }
}
