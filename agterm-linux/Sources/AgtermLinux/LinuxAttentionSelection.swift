import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    /// The caller has already dismissed its picker. Resolve the live owner again after that GTK turn.
    func selectAttention(windowID targetWindow: UUID, sessionID: UUID) {
        guard let controller = gWindows[targetWindow],
              let session = controller.store.session(withID: sessionID),
              session.agentIndicator.status != .idle else { return }
        let pane = session.agentIndicator.statusPane
        if targetWindow != windowID {
            gtk_window_present(WIN(controller.windowPointer))
            library.frontmostWindowID = targetWindow
        }
        controller.selectSession(sessionID)
        handleAutoFollow(sessionID, statusPane: pane)
    }
}
