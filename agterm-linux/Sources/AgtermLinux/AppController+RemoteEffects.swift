import Foundation
import agtermCore

@MainActor
extension AppController {
    func remoteEffects(for id: UUID) -> RemotePresentationEffects {
        RemotePresentationEffects(
            status: { [weak self] status in
                self?.store.applyRemoteStatus(status, forSession: id)
                self?.reconcile(focusActive: false)
            },
            snapshotStatus: { [weak self] status in
                self?.store.applyRemoteSnapshotStatus(status, forSession: id)
                self?.reconcile(focusActive: false)
            },
            hud: { [weak self] hud in self?.showRemoteHud(hud, forSession: id) },
            notify: { [weak self] notify in
                self?.showRemoteNotification(notify, forSession: id)
            },
            connection: { [weak self] connection in
                self?.store.setRemoteConnection(connection, forSession: id)
                self?.syncSidebar()
                self?.updateTitle()
            },
            context: { [weak self] context in
                self?.store.applyRemoteContext(context, forSession: id)
                self?.reconcile(focusActive: false)
            },
            mode: { [weak self] mode in
                self?.store.setRemoteMode(mode, forSession: id)
                self?.syncSidebar()
            },
            askRequest: { [weak self] ask in self?.showReplicaAsk(ask, forSession: id) ?? false },
            askDismiss: { [weak self] ref in
                self?.store.dismissReplicaAsk(ref, forSession: id)
                self?.reconcile(focusActive: false)
            },
            overlayRequest: { [weak self] overlay in
                self?.showReplicaOverlay(overlay, forSession: id) ?? false
            },
            overlayClose: { [weak self] change in
                self?.store.closeReplicaOverlay(change.job, forSession: id)
                self?.reconcile(focusActive: false)
            },
            overlayResize: { [weak self] change in
                self?.store.resizeReplicaOverlay(change, forSession: id)
                self?.reconcile(focusActive: false)
            },
            layout: { [weak self] layout in self?.applyRemoteLayout(layout, forSession: id) },
            warn: { reason in
                LinuxStructuredLogger(category: "RemotePresentation")
                    .notice("presentation stream for \(id): \(reason)")
            })
    }

    func showRemoteNotification(_ notify: PresentationNotify, forSession id: UUID) {
        guard store.session(withID: id) != nil else { return }
        let title = store.recordNotificationEvent(forSession: id, title: notify.title,
                                                  body: notify.body, origin: .mirrored) ?? notify.title
        _ = store.recordTerminalNotification(TerminalNotificationRecord(
            sessionID: id, windowID: windowID, pane: .main, title: title, body: notify.body,
            firingIsFocused: false, appActive: false))
        syncSidebar()
        NotificationManager.send(title: title, body: notify.body,
                                 target: TerminalNotification.identity(windowID: windowID,
                                                                       sessionID: id, pane: .main))
    }

    func showRemoteHud(_ hud: PresentationHud?, forSession id: UUID) {
        guard let session = store.session(withID: id), session.remotePresentation != nil else { return }
        guard let hud, hud.remaining != 0 else {
            if store.closeBridgedHud(forSession: id) { reconcile(focusActive: false) }
            return
        }
        let spec = HudSpec(message: hud.spec.message, detail: hud.spec.detail, spinner: hud.spec.spinner,
                           backgroundColor: hud.spec.backgroundColor, textColor: hud.spec.textColor,
                           sizePercent: hud.spec.sizePercent, position: hud.spec.position,
                           hideAfter: hud.remaining, markdown: hud.spec.markdown, fontSize: hud.spec.fontSize)
        let pane = store.localPane(hud.pane, in: session).flatMap { session.rendersPane($0) ? $0 : nil }
        let placement = ControlHudPlacement(pane: pane)
        let bridged = session.hudActive && session.remotePresentation?.hudBridged == true
        guard bridged || !session.hudActive else { return }
        let response = bridged
            ? updateHud(id.uuidString, window: nil, spec: spec, placement: placement)
            : openHud(id.uuidString, window: nil, spec: spec, placement: placement)
        if response.ok { store.markHudBridged(forSession: id) }
    }

    func applyRemoteLayout(_ layout: PresentationLayout, forSession id: UUID) {
        let before = store.session(withID: id)?.paneIdentity
        let removed = store.applyRemoteLayout(layout, forSession: id)
        if let session = store.session(withID: id), before != session.paneIdentity,
           let primary = session.surface as? GhosttySurface,
           let split = session.splitSurface as? GhosttySurface {
            syncSwappedPaneAdapters(id, primary: primary, split: split)
        }
        for local in removed { closeRemovedRemotePane(local, forSession: id) }
        reconcile(focusActive: false)
    }

    func closeRemovedRemotePane(_ local: UUID, forSession id: UUID) {
        guard store.canCloseRemovedRemotePane(local, forSession: id),
              let session = store.session(withID: id) else { return }
        let split = session.splitPaneIdentity == local
        let surface = (split ? session.splitSurface : session.surface) as? GhosttySurface
        if split, surface == nil { store.closeSplit(id); return }
        let survivor = split ? session.surface : session.splitSurface
        guard survivor?.isRealized == true || store.remotePaneIsHeld(local, forSession: id),
              surface?.claimProcessExit() == true else { return }
        if split {
            closeSplitPane(id, alreadyFinalized: local)
        } else {
            closePrimaryPane(id, alreadyFinalized: local)
        }
    }
}
