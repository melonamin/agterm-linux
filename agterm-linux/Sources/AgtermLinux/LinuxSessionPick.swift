import CGtk
import Foundation
import Observation
import agtermCore

@MainActor
extension AppController {
    /// The shared receipt book can move or settle a pick without a GTK action (presenter loss,
    /// timeout, or a queued offer). Observe its slot so every transition also updates the modal.
    func observeControlPick() {
        withObservationTracking {
            _ = pickController.pending
        } onChange: { [weak self] in
            MainActorHop.enqueue {
                MainTimer.schedule(after: 0) { [weak self] in
                    guard let self, gWindows[windowID] === self else { return }
                    dismissControlPick(retainResultThroughRegistry: true, refocus: false)
                    if let pick = pickController.pending { showControlPick(pick) }
                    syncAskSurfaces()
                    observeControlPick()
                }
            }
        }
    }

    func openPick(_ pick: PendingPick, session target: String, window: String?, follow: Bool) -> ControlResponse {
        let response: ControlResponse
        switch resolveSessionResponse(target) {
        case .failure(let refusal): return refusal
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            switch store.presentPickRemotely(pick, in: session, window: windowID, follow: follow) {
            case true?: response = ControlResponse(ok: true, result: ControlResult(id: pick.id))
            case false?: return err("pick already pending")
            case nil:
                if let error = SessionPickBook.shared.openLocal(pick, session: id, window: windowID, controller: pickController) {
                    return err(error)
                }
                closePalette()
                if follow { gtk_window_present(WIN(windowPointer)) }
                response = ControlResponse(ok: true, result: ControlResult(id: pick.id))
            }
        }
        return timedInteraction(response, deadline: pick.deadline) { [weak self] in _ = self?.cancelPick(pick.id, window: nil) }
    }

    func showReplicaPick(_ pick: PresentationPick, forSession id: UUID) -> Bool {
        guard store.session(withID: id)?.remotePresentation != nil,
              originHoldsWork(id) || !pickController.modalPending else { return false }
        let accepted = SessionPickBook.shared.openReplica(pick, session: id, window: windowID, controller: pickController) { [weak self] in
            self?.remoteClients[id]?.answer($0)
        }
        if accepted {
            closePalette()
            if pick.follow == true { gtk_window_present(WIN(windowPointer)) }
        }
        return accepted
    }
}
