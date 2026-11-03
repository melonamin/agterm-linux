import Foundation
import agtermCore

extension ControlServer {
    func attachRemotePageRow(_ remote: ControlRemoteSession, tree: ControlRemoteTree, host: String,
                             window: String?) -> ControlResponse {
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
        if case .url(let text) = page.source, HtmlSource.isLoopback(text) {
            return err("a page on \(host)'s loopback cannot be shown on this machine")
        }
        if page.persistent, let failure = LinuxBrowserStore.shared.failure() { return err(failure) }
        guard let command = try? RemoteSession.pageServeCommand(host: host, token: page.token) else { return err("invalid host") }
        let row: Session
        switch store.addReplicaPageCompanion(to: parent, page: page, select: select) {
        case .failure(let refusal): return err(refusal.message)
        case .success(let created): row = created
        }
        store.bindRemote(RemoteBinding(remoteSessionID: originSession, daemonsByLocalPane: [:], presentationVersion: nil),
                         forSession: row.id)
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
        channel.start(command)
        reconcile(focusActive: select)
        return ControlResponse(ok: true, result: ControlResult(id: row.id.uuidString, pageID: local.uuidString,
                                                               parent: parent.uuidString))
    }
}
