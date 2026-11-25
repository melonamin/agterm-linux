import CGtk
import Foundation
import agtermCore

@MainActor
enum LinuxSessionLinkHandoff {
    private static var request = 0

    /// The last link wins. A cold launch can still be loading attached rows and presenting restored windows.
    static func queue(_ session: UUID) {
        request += 1
        let generation = request
        let deadline = Date().addingTimeInterval(10)
        MainTimer.schedule(after: 0) { drain(session, generation: generation, deadline: deadline) }
    }

    private static func drain(_ session: UUID, generation: Int, deadline: Date) {
        guard request == generation, Date() < deadline else { return }
        let owners = gLibrary.openIDs().filter { gLibrary.store(for: $0)?.session(withID: session) != nil }
        guard owners.count < 2 else { return }
        if let window = owners.first, let controller = gWindows[window] {
            guard controller.terminalZoom.target == nil, !controller.dashboard.isOpen,
                  controller.pickController.pending == nil else { return }
            gLibrary.frontmostWindowID = window
            controller.store.selectSession(session)
            controller.reconcile()
            gtk_window_unminimize(WIN(controller.windowPointer))
            gtk_window_present(WIN(controller.windowPointer))
            return
        }
        MainTimer.schedule(after: 0.1) { drain(session, generation: generation, deadline: deadline) }
    }
}
