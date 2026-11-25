import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func undoAttachedFromGUI(_ undo: AttachedUndo) {
        let server = gControlServer, window = windowID
        DispatchQueue.global().async {
            let response = server.undoAttached(undo, window: window)
            runOnMain { MainActor.assumeIsolated {
                if !response.ok { NotificationManager.send(title: "Undo close on origin", body: response.error ?? "the origin refused undo") }
            } }
        }
    }
    func sendRemoteHistory(_ command: Command, target: String? = nil) {
        remoteAttachRequest(ControlRequest(cmd: command, target: target, args: ControlArgs(window: windowID.uuidString))) { response in
            if !response.ok { NotificationManager.send(title: "Remote history", body: response.error ?? "the remote action failed") }
        }
    }

    /// All remote GUI mutations use the same request parser and receipt path as socket callers.
    @discardableResult
    func sendRemoteGUI(_ request: ControlRequest) -> Bool {
        if ControlServer.attachedCommands.contains(request.cmd) || request.cmd == .sessionTerminate,
           case .success(let id) = resolveSessionResponse(request.target),
           let row = store.session(withID: id), AttachedOrigin(row) != nil {
            var scoped = request
            var args = scoped.args ?? ControlArgs()
            args.window = windowID.uuidString
            scoped.args = args
            remoteAttachRequest(scoped) { response in
                if !response.ok { NotificationManager.send(title: "Remote action", body: response.error ?? "the remote action failed") }
            }
            return true
        }
        guard let catalog = LinuxRemoteCatalogs.windows[windowID], RemoteOperation.structuralCommands.contains(request.cmd),
              !RemoteOperation.runsLocally(request, in: store) else { return false }
        catalog.perform(request) { [weak self] response in
            guard let self, !response.ok else { return }
            NotificationManager.send(title: "Remote action", body: response.error ?? "the remote action failed")
            self.reconcile(focusActive: false)
        }
        return true
    }

    func chooseRemoteHost(prompt: String, completion: @escaping @MainActor (String) -> Void) {
        let entries = linuxRemotes(configDirectory: configDirectory())
        guard let first = entries.first else { return }
        if entries.count == 1 { return completion(first.destination) }
        let pick = PendingPick(id: UUID().uuidString,
                              items: entries.map { ControlPickItem(id: $0.destination, label: $0.label) }, prompt: prompt)
        guard openPick(pick, window: nil, follow: true).ok else { return }
        controlPickCompletion = { answer in
            if answer.result == .picked, let host = answer.id { completion(host) }
        }
    }

    func showRemoteWindow() {
        chooseRemoteHost(prompt: "Open remote window on which machine?") { [weak self] host in
            self?.chooseOriginWindow(on: host) { [weak self] window in
                var args = ControlArgs(host: host)
                args.originWindow = window
                self?.remoteAttachRequest(ControlRequest(cmd: .windowRemoteOpen, args: args)) { response in
                    if !response.ok { NotificationManager.send(title: "Open Remote Window", body: response.error ?? "could not open window") }
                }
            }
        }
    }

    func showNewRemoteSession() {
        chooseRemoteHost(prompt: "Start a session on which machine?") { [weak self] host in
            guard let self else { return }
            chooseOriginWindow(on: host) { [weak self] origin in
                guard let self else { return }
                var args = ControlArgs(host: host, window: windowID.uuidString)
                args.originWindow = origin
                let request = ControlRequest(cmd: .sessionRemoteNew, args: args)
                remoteAttachRequest(request) { response in
                    if !response.ok { NotificationManager.send(title: "New Remote Session", body: response.error ?? "could not create session") }
                }
            }
        }
    }

    private func chooseOriginWindow(on host: String, completion: @escaping @MainActor (String?) -> Void) {
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: ["version"]) else { return }
        LinuxRemoteCatalog.run(argv) { [weak self] result in
            guard let self else { return }
            let version = (try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)))?.result
            if version?.headless == true { return completion(nil) }
            guard let argv = try? RemoteSession.controlCommand(host: host, arguments: ["window", "list"]) else { return }
            LinuxRemoteCatalog.run(argv) { [weak self] result in
                guard let self else { return }
                let windows = (try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)))?.result?.windows ?? []
                let offered = RemoteOriginWindow.offered(windows)
                guard offered.count > 1 else { return completion(offered.first?.id) }
                let pick = PendingPick(id: UUID().uuidString, items: offered.map { ControlPickItem(id: $0.id, label: $0.name) },
                                       prompt: "Which window on \(host)?")
                guard openPick(pick, window: nil, follow: true).ok else { return }
                controlPickCompletion = { answer in if answer.result == .picked { completion(answer.id) } }
            }
        }
    }

    func showDetachedRemoteSessions() {
        guard let catalog = LinuxRemoteCatalogs.windows[windowID] else { return }
        let items = catalog.mirror.detachedItems
        guard !items.isEmpty else { return }
        let pick = PendingPick(id: UUID().uuidString,
                              items: items.map { ControlPickItem(id: $0.id.uuidString, label: $0.name) }, prompt: "Detached Sessions")
        guard openPick(pick, window: nil, follow: true).ok else { return }
        controlPickCompletion = { answer in
            guard answer.result == .picked, let id = answer.id.flatMap(UUID.init(uuidString:)),
                  let item = items.first(where: { $0.id == id }) else { return }
            let error = item.kind == .workspace ? catalog.mirror.reattach(workspace: id) : catalog.mirror.reattach(session: id)
            if let error { NotificationManager.send(title: "Reattach", body: error) }
        }
    }

    func convertActiveCompanion() {
        let request = ControlRequest(cmd: .sessionCompanionConvert, target: store.selectedSessionID?.uuidString)
        if sendRemoteGUI(request) { return }
        let response = convertToCompanion(request.target, window: nil)
        if !response.ok { NotificationManager.send(title: "Convert to Companion", body: response.error ?? "could not convert session") }
    }

    func forwardRemoteLink(_ path: String, session id: UUID, pane: UUID?, surface: GhosttySurface? = nil) {
        let client = remoteClients[id]
        let click = RemoteLinkClick(raw: path, session: id, pane: pane, mode: linuxSettingsStore().load().effectiveLinkOpenMode)
        let hidden = terminalZoom.target != nil || store.session(withID: id)?.hudActive == true
        let snapshots = surface != nil && client?.originSupports(PresentationHub.linkSnapshotKind) == true
        switch store.linkClickRequest(click, originSupportsClick: client?.originSupports(PresentationHub.linkClickKind) == true,
                                     hidden: hidden && !snapshots, originTakesLeads: client?.claimsLead == true) {
        case .success(var frame):
            if snapshots, let surface, let booked = remoteOpeners.record(path, session: id, surface: surface, rules: keymap.openers) {
                frame.click = booked
                frame.openers = remoteOpeners.book.selectors(for: booked)
                frame.snapshotOnly = hidden ? true : nil
            } else if hidden {
                return
            }
            client?.answer(.linkClick(frame))
        case .failure(let reason):
            let host = store.session(withID: id)?.remoteHost ?? "origin"
            NotificationManager.send(title: "Open remote file", body: reason.message(host: host))
        }
    }
}
