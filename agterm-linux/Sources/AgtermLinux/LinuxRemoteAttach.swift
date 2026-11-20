import Foundation
import agtermCore

@MainActor
func linuxRemotes(configDirectory: URL) -> [RemoteEntry] {
    let url = ConfigPaths.remotesPath(configDirectory: configDirectory)
    LinuxRemotesObserver.shared.watch(url)
    let entries = (try? RemotesFile.load(at: url))?.remotes.entries ?? []
    return entries
}

@MainActor
extension AppController {
    func showRemoteAttach() {
        guard !pickController.modalPending, terminalZoom.target == nil, !dashboard.isOpen else { return }
        let entries = linuxRemotes(configDirectory: configDirectory())
        guard let first = entries.first else { return }
        if entries.count == 1 { return listRemoteSessions(first.destination) }
        let pick = PendingPick(id: UUID().uuidString, items: entries.map {
            ControlPickItem(id: $0.destination, label: $0.label, subtitle: $0.label == $0.destination ? nil : $0.destination)
        }, prompt: "Attach from which machine?")
        if openPick(pick, window: nil, follow: true).ok {
            controlPickCompletion = { [weak self] result in
                guard result.result == .picked, let host = result.id else { return }
                self?.listRemoteSessions(host)
            }
        }
    }

    func beginRemoteCompanionFromGUI(_ id: UUID, duplicate: Bool) {
        let progress = LinuxRemoteAttachProgress(controller: self)
        progress.show("creating and attaching a companion…", spinner: true)
        let request = ControlRequest(cmd: duplicate ? .sessionCompanionDuplicate : .sessionCompanionNew,
                                     target: id.uuidString, args: ControlArgs(window: windowID.uuidString))
        remoteAttachRequest(request) { response in
            if response.ok { progress.close() } else { progress.show(response.error ?? "could not create companion") }
        }
    }

    private func listRemoteSessions(_ host: String) {
        let progress = LinuxRemoteAttachProgress(controller: self)
        progress.show("listing sessions on \(host)…", spinner: true)
        remoteAttachRequest(ControlRequest(cmd: .zmxTree, args: ControlArgs(host: host))) { [weak self] response in
            guard let self else { return }
            guard response.ok, let sessions = response.result?.remote?.sessions.filter({ $0.content == nil }) else {
                progress.show("\(host): \(response.error ?? "no answer")")
                return
            }
            guard !sessions.isEmpty, sessions.count <= ControlPickItem.maxItems else {
                progress.show(sessions.isEmpty ? "nothing to attach on \(host)" : "\(host) offers too many sessions")
                return
            }
            progress.close()
            let names = Dictionary(sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let items = sessions.map { Self.remotePickItem($0, parentName: $0.parent.flatMap { names[$0] }) }
            let pick = PendingPick(id: UUID().uuidString, items: items, prompt: "Attach from \(host)")
            guard self.openPick(pick, window: nil, follow: true).ok else { return }
            self.controlPickCompletion = { [weak self] result in
                guard let self, result.result == .picked, let id = result.id else { return }
                progress.show("attaching \(result.label ?? id)…", spinner: true)
                let command: Command = sessions.first(where: { $0.id == id })?.parent == nil ? .zmxAttachGroup : .zmxAttach
                self.remoteAttachRequest(ControlRequest(cmd: command, target: id,
                                                       args: ControlArgs(host: host, window: self.windowID.uuidString))) { response in
                    if response.ok {
                        progress.close()
                    } else {
                        if let parent = response.result?.id { progress.move(to: parent) }
                        progress.show(response.error ?? "attach failed")
                    }
                }
            }
        }
    }

    func remoteAttachRequest(_ request: ControlRequest, completion: @escaping @MainActor (ControlResponse) -> Void) {
        let server = gControlServer
        DispatchQueue.global().async { [weak self] in
            let response = server.performRequest(request)
            runOnMain {
                MainActor.assumeIsolated {
                    guard let self, gWindows[self.windowID] === self else { return }
                    completion(response)
                }
            }
        }
    }

    static func remotePickItem(_ session: ControlRemoteSession, parentName: String? = nil) -> ControlPickItem {
        let programs = session.panes.compactMap { $0.foreground?.first.map { ($0 as NSString).lastPathComponent } }
        let subtitle = ["\(session.windowName)/\(session.workspaceName)", session.context ?? "", session.cwd,
                        programs.joined(separator: " | ")].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        return ControlPickItem(id: session.id, label: parentName.map { "\($0) › \(session.name)" } ?? session.name, subtitle: subtitle,
                               status: session.status, statusColor: session.statusColor, statusShape: session.statusShape)
    }
}

@MainActor
final class LinuxRemoteAttachProgress {
    weak var controller: AppController?
    var sessionID: UUID?
    var generation: Int?

    init(controller: AppController) {
        self.controller = controller
        sessionID = controller.store.selectedSessionID
    }

    func show(_ text: String, spinner: Bool = false) {
        guard let controller else { return }
        let message = CommandFailure.message(name: "Attach Remote", reason: text)
        if let sessionID, controller.openHud(sessionID.uuidString, window: nil,
                                            spec: HudSpec(message: message, spinner: spinner ? .bar : nil,
                                                          hideAfter: spinner ? 30 : 5)).ok {
            generation = controller.store.session(withID: sessionID)?.overlaySlotGeneration
        } else if !spinner { NotificationManager.send(title: "Attach Remote", body: message) }
    }

    func close() {
        guard let controller, let sessionID, let generation,
              controller.store.session(withID: sessionID)?.overlaySlotGeneration == generation else { return }
        _ = controller.closeHud(sessionID.uuidString, window: nil)
        self.generation = nil
    }

    func move(to value: String) {
        guard let id = UUID(uuidString: value), controller?.store.session(withID: id) != nil else { return }
        close()
        sessionID = id
        generation = nil
    }
}
