import Foundation
import agtermCore

extension ControlServer {
    func attachRemotePageRow(_ remote: ControlRemoteSession, tree: ControlRemoteTree, host: String,
                             window: String?, workspace: ControlAttachWorkspace? = nil) -> ControlResponse {
        if remote.parent == nil {
            guard let argv = try? RemoteSession.controlCommand(host: host,
                arguments: ["session", "overlay", "page-attach", "--target", remote.id]) else { return ControlResponse(ok: false, error: "invalid host") }
            let result = LinuxRemoteCommand.run(argv, deadline: 30)
            guard let response = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
                return ControlResponse(ok: false, error: "\(host) did not answer")
            }
            guard response.ok, let page = response.result?.companionPage else { return response }
            return companionOnMain {
                let id: UUID?
                if let window {
                    guard case .resolved(let resolved) = gLibrary.resolveWindow(window) else { return ControlResponse(ok: false, error: "window not open") }
                    id = resolved
                } else { id = gLibrary.activeWindowID }
                guard let id, let controller = gWindows[id] else {
                    return ControlResponse(ok: false, error: "no local workspace to attach into")
                }
                let destination: UUID
                switch controller.attachWorkspace(workspace) {
                case .failure(let response): return response
                case .success(let id): destination = id
                }
                let binding = RemoteBinding(remoteSessionID: remote.id, daemonsByLocalPane: [:], presentationVersion: tree.presentation,
                    origin: RemoteBinding.Origin(host: host, endpoint: tree.endpoint, sessionName: remote.name), originHeadless: tree.headless == true)
                return controller.placeRemotePage(page, host: host, originSession: remote.id, placement: .root(destination), select: true,
                                                  binding: binding, name: remote.name)
            }
        }
        let resolved = companionOnMain {
            let stores: [AppStore]
            if let window {
                guard case .resolved(let id) = gLibrary.resolveWindow(window), gWindows[id] != nil,
                      let store = gLibrary.store(for: id) else { return ControlResponse(ok: false, error: "window not open") }
                stores = [store]
            } else {
                stores = gLibrary.openIDs().compactMap { gLibrary.store(for: $0) }
            }
            let sessions = stores.flatMap { $0.workspaces.flatMap(\.sessions) }
            let rows = sessions.filter { row in
                guard row.parentID == nil, row.remoteHost == host,
                      let binding = row.remotePresentation?.binding else { return false }
                return binding.remoteSessionID == remote.parent && binding.origin?.endpoint == tree.endpoint
            }
            guard rows.count == 1, let parent = rows.first else {
                return ControlResponse(ok: false, error: rows.isEmpty
                    ? "attach the page's parent session from \(host) first" : "more than one row here shows the page's parent")
            }
            return ControlResponse(ok: true, result: ControlResult(id: parent.id.uuidString))
        }
        guard resolved.ok, let parent = resolved.result?.id.flatMap(UUID.init(uuidString:)) else { return resolved }
        return attachRemotePage(remote.id, host: host, parent: parent, select: true)
    }
}

@MainActor
extension AppController {
    func attachRemotePage(_ page: PresentationPage, originSession: String, host: String,
                          parent: UUID, select: Bool) -> ControlResponse {
        let parentBinding = store.session(withID: parent)?.remotePresentation?.binding
        let binding = RemoteBinding(remoteSessionID: originSession, daemonsByLocalPane: [:],
            presentationVersion: parentBinding?.presentationVersion, origin: parentBinding?.origin,
            originHeadless: parentBinding?.originHeadless == true)
        return placeRemotePage(page, host: host, originSession: originSession, placement: .companion(parent), select: select, binding: binding)
    }

    func placeRemotePage(_ page: PresentationPage, host: String, originSession: String,
                         placement: LinuxReplicaPlacement, select: Bool, binding: RemoteBinding? = nil, name: String? = nil) -> ControlResponse {
        if case .url(let text) = page.source, HtmlSource.isLoopback(text) {
            return err("a page on \(host)'s loopback cannot be shown on this machine")
        }
        if page.persistent, let failure = LinuxBrowserStore.shared.failure() { return err(failure) }
        guard let command = try? RemoteSession.pageServeCommand(host: host, token: page.token) else { return err("invalid host") }
        let row: Session
        let placed: Result<Session, ReplicaPageRefusal>
        switch placement {
        case .companion(let parent): placed = store.addReplicaPageCompanion(to: parent, page: page, select: select, remoteSessionID: originSession)
        case .root(let workspace): placed = store.addReplicaPageRoot(toWorkspace: workspace, host: host, name: name, page: page,
                                                                  select: select, remoteSessionID: originSession)
        case .existing(let id): placed = store.fillReplicaPage(id, page: page)
        case .catalog(let id):
            if let error = store.showCatalogPage(page, inRow: id) { return err(error) }
            guard let current = store.session(withID: id) else { return err("the page row closed") }
            placed = .success(current)
        }
        switch placed {
        case .failure(let refusal): return err(refusal.message)
        case .success(let created): row = created
        }
        if let binding { store.bindRemote(binding, forSession: row.id) }
        row.awaitsOriginCheck = false
        guard let overlay = row.htmlOverlay, let origin = overlay.replicaOf else {
            store.closeSession(row.id)
            return err("the page cannot be reached on \(host)")
        }
        let channel = LinuxPageChannel()
        replicaPages[overlay.id] = LinuxReplicaPageRecord(session: row.id, origin: origin, channel: channel)
        _ = LinuxHtmlOverlayRegistry.shared.page(for: overlay, controller: self, backgroundColor: page.backgroundColor)
        let local = overlay.id, rowID = row.id
        let server = gControlServer
        channel.onClose = {
            if case .catalog = placement {
                guard let holder = gLibrary.store(forSession: rowID), holder.session(withID: rowID)?.htmlOverlay?.id == local else { return }
                holder.showCatalogPageRefusal("the page's connection to \(host) ended, reconnecting", inRow: rowID)
                self.syncRemotePageRows()
                return
            }
            guard let command = try? RemoteSession.controlCommand(host: host,
                arguments: ["session", "overlay", "result", "--page", origin.uuidString]) else { return }
            Thread.detachNewThread {
                let result = LinuxRemoteCommand.run(command, deadline: LinuxRemoteCommand.treeDeadline)
                let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8))
                _ = server.companionOnMain {
                    HtmlPageOutcomes.shared.settle(local, like: reply?.result?.pageOutcome)
                    guard let holder = gLibrary.store(holdingSession: rowID) else { return ControlResponse(ok: true) }
                    if !holder.closeHtmlOverlay(local) { holder.finalizePendingClose(ofSession: rowID) }
                    if let window = gLibrary.windowID(for: holder) { gWindows[window]?.reconcile(focusActive: false) }
                    return ControlResponse(ok: true)
                }
            }
        }
        startRemotePageChannel(channel, local: local, host: host, token: page.token, fallback: command)
        store.setRemoteConnection(.connected, forSession: row.id)
        reconcile(focusActive: select)
        return ControlResponse(ok: true, result: ControlResult(id: row.id.uuidString, pageID: local.uuidString,
                                                               parent: row.parentID?.uuidString))
    }
}

enum LinuxReplicaPlacement: Sendable { case companion(UUID), root(UUID), existing(UUID), catalog(UUID) }
