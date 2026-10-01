import Foundation
import agtermCore

@MainActor
extension AppController {
    var remoteHeldExits: LinuxRemoteHeldExitRouter {
        LinuxRemoteHeldExitRouter(store: store,
                                  closeRemovedPane: { [weak self] local, id in self?.closeRemovedRemotePane(local, forSession: id) },
                                  reconcile: { [weak self] focusActive in self?.reconcile(focusActive: focusActive) })
    }
}

/// Routes a replica surface held on its exit prompt to the store. Only the surface still in its slot counts:
/// a hook that outlived its slot must not mark whatever replaced it.
@MainActor
struct LinuxRemoteHeldExitRouter {
    let store: AppStore
    let closeRemovedPane: (_ local: UUID, _ session: UUID) -> Void
    let reconcile: (_ focusActive: Bool) -> Void

    func paneHeld(_ surface: any TerminalSurface, forSession id: UUID) {
        guard let session = store.session(withID: id), session.remotePresentation != nil else { return }
        let local: UUID
        if session.surface === surface {
            local = session.paneIdentity
        } else if session.splitSurface === surface, let split = session.splitPaneIdentity {
            local = split
        } else {
            return
        }
        store.remotePaneHeld(local, forSession: id)
        // a removal frame that arrived first could not close a replica still running its ssh
        closeRemovedPane(local, id)
        reconcile(false)
    }

    func overlayHeld(_ surface: any TerminalSurface, forSession id: UUID) {
        guard let session = store.session(withID: id) else { return }
        let pane: OverlayPane?
        let replica: OverlayReplica?
        if session.overlaySurface === surface {
            pane = nil
            replica = session.overlayReplica
        } else if let role = session.paneOverlayRole(of: surface) {
            pane = role
            replica = session.paneOverlay(role)?.replica
        } else {
            return
        }
        guard replica != nil else { return }
        store.replicaOverlayHeld(forSession: id, pane: pane)
        reconcile(false)
    }
}
