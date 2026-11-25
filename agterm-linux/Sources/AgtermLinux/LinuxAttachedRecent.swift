import Foundation
import agtermCore

private final class LinuxAttachedRecentBox: @unchecked Sendable {
    var item: RemoteRecentClosedItem?
    var refusal: ControlResponse?
    var window: String?
}

extension ControlServer {
    func performAttachedRecent(_ request: ControlRequest) -> ControlResponse? {
        guard request.cmd == .recentOpen else { return nil }
        let box = LinuxAttachedRecentBox()
        _ = companionOnMain {
            guard !gLibrary.remoteRecentClosedItems.isEmpty else { return ControlResponse(ok: true) }
            if request.args?.window != nil,
               case .controller(let controller) = Self.route(for: request),
               let controller, gLibrary.windows.first(where: { $0.id == controller.windowID })?.isRemote == true {
                return ControlResponse(ok: true)
            }
            switch RecentClosedTarget.resolve(request.target, in: gLibrary.recentClosedItems, remote: gLibrary.remoteRecentClosedItems) {
            case .failure(let refusal): box.refusal = ControlResponse(ok: false, error: refusal.message)
            case .success(.local): break
            case .success(.remote(let id)): box.item = gLibrary.remoteRecentClosedItems.first { $0.id == id }
            }
            if box.item != nil {
                switch Self.route(for: request) {
                case .failure(let error): box.refusal = ControlResponse(ok: false, error: error)
                case .controller(let controller):
                    if let controller {
                        if gLibrary.windows.first(where: { $0.id == controller.windowID })?.isRemote == true {
                            box.refusal = ControlResponse(ok: false, error: "recent.open is not available in a remote window")
                        } else {
                            box.window = controller.windowID.uuidString
                        }
                    } else { box.refusal = ControlResponse(ok: false, error: "no controller") }
                }
            }
            return ControlResponse(ok: true)
        }
        if let response = box.refusal { return response }
        guard let item = box.item else { return nil }
        let current = readRemoteTree(host: item.host)
        guard let tree = current.result?.remote else { return current }
        var sessions = [item.originSessionID]
        if !tree.sessions.contains(where: { $0.id == item.originSessionID }) {
            var entry = item.originRecentID
            if entry == nil {
                let list = linuxOriginCommand(item.host, words: ["recent", "list"])
                guard list.ok else { return list }
                entry = list.result?.recent?.first { $0.host == nil && $0.sessionIDs.contains(item.originSessionID) }?.id
            }
            guard let entry else { return ControlResponse(ok: false, error: "the session on \(item.host) is gone and its origin keeps no record") }
            let reopened = linuxOriginCommand(item.host, words: ["recent", "open"], operands: [entry])
            guard reopened.ok, let open = reopened.result?.recentOpen else { return reopened }
            sessions = open.item.sessionIDs
        }
        return reattachRecent(sessions, item: item, window: box.window)
    }

    func undoAttached(_ undo: AttachedUndo, window: UUID) -> ControlResponse {
        let undone = linuxOriginCommand(undo.host, words: ["session", "undo", "--target", undo.undoID])
        guard undone.ok else { return undone }
        let box = LinuxAttachedRecentBox()
        for session in undo.sessions {
            _ = companionOnMain {
                box.item = gLibrary.remoteRecentClosedItems.first { $0.host == undo.host && $0.originSessionID == session }
                return ControlResponse(ok: true)
            }
            if let item = box.item {
                let reply = reattachRecent([session], item: item, window: window.uuidString)
                if !reply.ok { return reply }
            }
        }
        return undone
    }

    private func reattachRecent(_ sessions: [String], item: RemoteRecentClosedItem, window: String?) -> ControlResponse {
        let deadline = Date().addingTimeInterval(20)
        repeat {
            let listing = readRemoteTree(host: item.host)
            guard let tree = listing.result?.remote else { return listing }
            guard sessions.allSatisfy({ id in tree.sessions.contains { $0.id == id } }) else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            var order = sessions
            if let parent = tree.sessions.first(where: { $0.id == item.originSessionID && $0.content == "page" })?.parent,
               !order.contains(parent) { order.insert(parent, at: 0) }
            var shown: UUID?
            for session in order {
                let found = companionOnMain {
                    let row = gWindows.values.flatMap { $0.store.workspaces.flatMap(\.sessions) }.first {
                        $0.remoteHost == item.host && $0.remoteSessionID == session
                    }
                    return ControlResponse(ok: row != nil, result: ControlResult(id: row?.id.uuidString))
                }
                let attached = found.ok ? found : attachRemoteOnMain(host: item.host, session: session, tree: tree, window: window)
                guard attached.ok else { return attached }
                if session == item.originSessionID { shown = attached.result?.id.flatMap(UUID.init(uuidString:)) }
            }
            guard let shown else { return ControlResponse(ok: false, error: "the origin session did not attach") }
            return companionOnMain {
                guard let store = gLibrary.store(forSession: shown), let destination = gLibrary.windowID(for: store) else {
                    return ControlResponse(ok: false, error: "the attached row closed")
                }
                if store.session(withID: shown)?.parentID == nil, store.workspaces.contains(where: { $0.id == item.placement.workspaceID }) {
                    store.moveSession(shown, toWorkspace: item.placement.workspaceID, at: item.placement.sessionIndex)
                }
                gLibrary.removeRemoteRecentClosed(item.id)
                gWindows[destination]?.reconcile()
                return ControlResponse(ok: true, result: ControlResult(id: shown.uuidString, recentOpen: ControlRecentOpen(
                    item: ControlRecentItem(item), window: destination.uuidString, complete: true)))
            }
        } while Date() < deadline
        return ControlResponse(ok: false, error: "\(item.host) reopened \(item.name) but has not listed it as attachable; Reopen tries again")
    }

    private func linuxOriginCommand(_ host: String, words: [String], operands: [String] = []) -> ControlResponse {
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: words, operands: operands) else {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = LinuxRemoteCommand.run(argv, deadline: 30)
        return (try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)))
            ?? ControlResponse(ok: false, error: "\(host) gave no answer; whether the command ran is unknown")
    }
}
