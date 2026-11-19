import Foundation
import Observation
import agtermCore

@MainActor
extension ControlServer {
    func reconcileOpenWork(forSession id: UUID) {
        guard let controller = gWindows.values.first(where: { $0.store.session(withID: id) != nil }) else { return }
        let local = OpenWorkLocal(modal: { _ in (controller.pickController, controller.windowID) }, showsGuiAsk: { session in
            controller.store.selectedSessionID == session.id && !controller.dashboard.isOpen
                && controller.terminalZoom.target == nil
                && (session.askPaneIdentity == nil || session.askTargetPane.map(session.rendersPane) == true)
        })
        if controller.store.reconcileOpenWork(forSession: id, local: local).offered {
            scheduleOverlayJobExpiry(after: OverlayJobs.launchWindow)
            schedulePageClaimExpiry(after: AppStore.pageClaimWindow)
        }
        controller.reconcile(focusActive: false)
        trackOpenWorkPlaces()
    }

    func trackOpenWorkPlaces() {
        openWorkTracking &+= 1
        let generation = openWorkTracking
        withObservationTracking {
            for id in presentationHub.subscribedSessions {
                guard let controller = gWindows.values.first(where: { $0.store.session(withID: id) != nil }),
                      let session = controller.store.session(withID: id) else { continue }
                for pane in [session.paneIdentity, session.splitPaneIdentity].compactMap({ $0 }) {
                    _ = ZmxLeadBook.shared.role(pane: pane)
                }
                _ = controller.pickController.modalPending
                _ = controller.store.selectedSessionID
                _ = controller.dashboard.isOpen
                _ = controller.terminalZoom.target
                _ = session.askPending
                _ = (session.overlayActive, session.hudActive)
                for pane in OverlayPane.allCases { _ = (session.paneOverlay(pane), session.rendersPane(pane)) }
            }
        } onChange: { [weak self] in
            MainActorHop.enqueue {
                guard let self else { return }
                for id in self.presentationHub.subscribedSessions { self.presentationHub.scheduleOpenWork(id) }
                if self.openWorkTracking == generation { self.trackOpenWorkPlaces() }
            }
        }
    }
}

/// Builds fresh pane attachments from the origin binding, preserving the stable local pane identity.
@MainActor
final class LinuxRemoteAttachLines: RemoteAttachLines {
    func paneAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID) -> String {
        line(origin, daemon: daemon, local: local, role: .right)
    }

    func scratchAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID) -> String {
        line(origin, daemon: daemon, local: local, role: .left)
    }

    private func line(_ origin: RemoteBinding.Origin, daemon: String, local: UUID, role: ZmxPaneRole) -> String {
        let lead = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(lead, pane: local)
        return (try? RemoteSession.attachPaneCommand(host: origin.host, endpoint: origin.endpoint, daemon: daemon,
                                                    session: origin.sessionName, pane: role, lead: lead))
            ?? RemoteSession.endedCommand(host: origin.host)
    }
}
