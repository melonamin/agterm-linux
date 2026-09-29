import Foundation
import agtermCore

@MainActor
extension AppController {
    /// A remote stream follows the visible row, including soft close and undo, rather than the SSH pane.
    func syncRemotePresentations() {
        let sessions = store.workspaces.flatMap(\.sessions)
        let visible = Set(sessions.filter { $0.remotePresentation != nil }.map(\.id))
        for id in Array(remoteClients.keys) where !visible.contains(id) {
            remoteClients.removeValue(forKey: id)?.stop()
        }
        for session in sessions where session.remotePresentation != nil && remoteClients[session.id] == nil {
            startRemotePresentation(session)
        }
        if remoteClients.isEmpty {
            remoteTickCancel?()
            remoteTickCancel = nil
        } else {
            scheduleRemoteTick()
        }
    }

    func stopRemotePresentations() {
        remoteTickCancel?()
        remoteTickCancel = nil
        for client in remoteClients.values { client.stop() }
        remoteClients.removeAll()
    }

    private func startRemotePresentation(_ session: Session) {
        guard let host = session.remoteHost, let binding = session.remotePresentation?.binding else { return }
        guard let argv = try? RemoteSession.presentCommand(host: host, session: binding.remoteSessionID) else {
            LinuxStructuredLogger(category: "RemotePresentation")
                .notice("no presentation stream for \(session.id): invalid origin session id")
            return
        }
        let client = RemotePresentationClient(argv: argv, presentationVersion: binding.presentationVersion,
                                              transport: remoteTransport, effects: remoteEffects(for: session.id))
        remoteClients[session.id] = client
        client.start()
    }

    private func scheduleRemoteTick() {
        guard remoteTickCancel == nil else { return }
        remoteTickCancel = MainTimer.schedule(after: 1) { [weak self] in
            guard let self else { return }
            self.remoteTickCancel = nil
            for client in self.remoteClients.values { client.tick() }
            if !self.remoteClients.isEmpty { self.scheduleRemoteTick() }
        }
    }
}
