import Foundation
import agtermCore

@MainActor
extension AppController {
    /// A remote stream follows the visible row, including soft close and undo, rather than the SSH pane.
    func syncRemotePresentations() {
        store.onOriginFrame = { [weak self] id, body in
            MainActor.assumeIsolated {
                guard let self, let client = self.remoteClients[id], client.originSupports(PresentationHub.statusClearKind),
                      self.store.session(withID: id)?.remotePresentation?.mode == .presenter || client.claimsLead else { return false }
                client.answer(body)
                return true
            }
        }
        store.onReplicaPageChanged = { [weak self] in self?.replicaPageChanged($0) }
        store.onRemoteRowPromoted = { [weak self] session in
            guard let self else { return }
            LinuxCompanionFollower.shared.promoted(session.id)
            if let binding = session.remotePresentation?.binding, Self.observesMembershipOnly(session, binding: binding),
               remoteClients[session.id]?.observer != true {
                remoteClients.removeValue(forKey: session.id)?.stop()
                MainTimer.schedule(after: 0) { [weak self] in self?.syncRemotePresentations() }
            }
        }
        syncRemotePageRows()
        LinuxAttachedRestore.checkTerminals()
        pruneRemoteRespawns()
        let sessions = store.workspaces.flatMap(\.sessions)
        let visible = Set(sessions.filter { $0.remotePresentation != nil }.map(\.id))
        LinuxRemoteCatalogs.windows[windowID]?.pool.retain(Set(visible.map { "present:\($0)" }), prefix: "present:")
        LinuxPortForward.prune(window: windowID, rows: visible)
        for id in Array(remoteClients.keys) where !visible.contains(id) {
            remoteOpeners.renew(id, ended: true)
            LinuxCompanionFollower.shared.forget(id)
            remoteClients.removeValue(forKey: id)?.stop()
        }
        for session in sessions where session.remotePresentation != nil && remoteClients[session.id] == nil {
            guard let binding = session.remotePresentation?.binding, session.remotePresentation?.originEnded != true,
                  session.content == .terminal || binding.originHeadless || Self.observesMembershipOnly(session, binding: binding) else { continue }
            startRemotePresentation(session)
        }
        if remoteClients.isEmpty && RemoteReconnectBook.shared.isEmpty {
            remoteTickCancel?()
            remoteTickCancel = nil
        } else {
            scheduleRemoteTick()
        }
    }

    func stopRemotePresentations() {
        LinuxPortForward.prune(window: windowID, rows: [])
        replicaPageFlushCancel?()
        replicaPageFlushCancel = nil
        let pages = Array(replicaPages.values)
        replicaPages.removeAll()
        for page in pages { page.channel?.onClose = nil; page.channel?.close() }
        remoteTickCancel?()
        remoteTickCancel = nil
        for (id, client) in remoteClients {
            remoteOpeners.renew(id, ended: true)
            LinuxCompanionFollower.shared.forget(id)
            client.stop()
        }
        remoteClients.removeAll()
    }

    private func startRemotePresentation(_ session: Session) {
        guard let host = session.remoteHost, let binding = session.remotePresentation?.binding else { return }
        remoteOpeners.renew(session.id)
        let catalog = LinuxRemoteCatalogs.windows[windowID]
        let user = "present:\(session.id)"
        let path = catalog?.pool.lease(user)
        guard let argv = try? RemoteSession.presentCommand(host: host, session: binding.remoteSessionID, controlPath: path) else {
            LinuxStructuredLogger(category: "RemotePresentation")
                .notice("no presentation stream for \(session.id): invalid origin session id")
            return
        }
        let transport: any RemotePresentationTransport
        if let catalog, let path {
            transport = LinuxPooledTransport(pool: catalog.pool, user: user, path: path, inner: remoteTransport)
        } else { transport = remoteTransport }
        let observer = Self.observesMembershipOnly(session, binding: binding)
        let client = RemotePresentationClient(argv: argv, presentationVersion: observer ? PresentationCodec.version : binding.presentationVersion,
                                              transport: transport,
                                              effects: observer ? membershipEffects(for: session.id) : remoteEffects(for: session.id),
                                              observer: observer)
        remoteClients[session.id] = client
        client.start()
    }

    func scheduleRemoteTick() {
        guard remoteTickCancel == nil else { return }
        remoteTickCancel = MainTimer.schedule(after: 1) { [weak self] in
            guard let self else { return }
            self.remoteTickCancel = nil
            for client in self.remoteClients.values { client.tick() }
            self.tickReconnects()
            self.pruneRemoteRespawns()
            self.remoteOpeners.tick()
            LinuxCompanionFollower.shared.tick()
            if !self.remoteClients.isEmpty || !RemoteReconnectBook.shared.isEmpty { self.scheduleRemoteTick() }
        }
    }

    static func observesMembershipOnly(_ session: Session, binding: RemoteBinding) -> Bool {
        session.content == .page && session.parentID == nil && !binding.originHeadless && !binding.catalogOwned
    }

    private func membershipEffects(for id: UUID) -> RemotePresentationEffects {
        RemotePresentationEffects(status: { _ in }, snapshotStatus: { _ in }, hud: { _ in }, notify: { _ in },
            connection: { LinuxCompanionFollower.shared.disconnected($0, row: id) },
            companions: { LinuxCompanionFollower.shared.receive($0, row: id) },
            ended: { LinuxCompanionFollower.shared.forget(id) },
            warn: { LinuxStructuredLogger(category: "FollowCompanions").notice($0) })
    }
}
