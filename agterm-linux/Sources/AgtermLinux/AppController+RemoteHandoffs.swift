import Foundation
import agtermCore

@MainActor
extension AppController {
    func takeBackRemoteAsk(forSession id: UUID) {
        guard let ask = store.takeBackRemoteAsk(forSession: id) else { return }
        guard let session = store.session(withID: id),
              store.selectedSessionID == id, !dashboard.isOpen, terminalZoom.target == nil,
              guiAskWindow == nil, !pickController.modalPending,
              session.askPaneIdentity == nil || session.askTargetPane.map(session.rendersPane) == true else {
            store.failHandback(forSession: id)
            return
        }
        let local = PendingAsk(id: ask.id, title: ask.title, message: ask.message,
                               buttons: ask.buttons, defaultID: ask.defaultID,
                               destructiveID: ask.destructiveID, style: ask.style,
                               align: ask.align, width: ask.width,
                               anchor: AskAnchor(sessionID: id, pane: session.askTargetPane,
                                                 paneIdentity: session.askPaneIdentity))
        guard pickController.openAsk(local) else {
            store.failHandback(forSession: id)
            return
        }
        guard showGUIAsk(local) else {
            store.failHandback(forSession: id)
            pickController.cancelAsk()
            return
        }
        session.releaseAsk()
        AskRegistry.shared.reassign(id: ask.id, to: .window(windowID))
        reconcile(focusActive: false)
    }

    func showReplicaAsk(_ ask: PresentationAsk, forSession id: UUID) -> Bool {
        guard let session = store.session(withID: id) else { return false }
        if ask.style == .gui {
            guard store.selectedSessionID == id, !dashboard.isOpen, terminalZoom.target == nil,
                  guiAskWindow == nil, !pickController.modalPending else { return false }
            if let pane = store.localPane(ask.pane, in: session), !session.rendersPane(pane) {
                return false
            }
        }
        let accepted = store.presentReplicaAsk(ask, forSession: id) { [weak self] body in
            self?.remoteClients[id]?.answer(body)
        }
        if accepted, ask.style == .gui, let pending = session.askPending {
            replicaGUIAskSessionID = id
            guard showGUIAsk(pending) else {
                replicaGUIAskSessionID = nil
                store.dismissReplicaAsk(PresentationAskRef(id: ask.id, owner: ask.owner), forSession: id)
                return false
            }
        }
        if accepted { reconcile(focusActive: false) }
        return accepted
    }

    func showReplicaOverlay(_ overlay: PresentationOverlay, forSession id: UUID) -> Bool {
        guard let session = store.session(withID: id), let host = session.remoteHost,
              let argv = try? RemoteSession.runJobCommand(host: host, job: overlay.job) else { return false }
        let command = CommandRestore.shellQuotedLine(argv)
        let accepted = store.presentReplicaOverlay(overlay, command: command, forSession: id) { [weak self] job in
            self?.remoteClients[id]?.answer(.overlayClosed(PresentationOverlayChange(job: job)))
        }
        if accepted { reconcile(focusActive: false) }
        return accepted
    }
}
