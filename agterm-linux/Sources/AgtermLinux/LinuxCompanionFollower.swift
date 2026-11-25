import Foundation
import agtermCore

/// Membership work is shared across windows because an explicit creation must hold every viewer of its host.
@MainActor
final class LinuxCompanionFollower {
    static let shared = LinuxCompanionFollower()

    struct Host: Hashable, Sendable {
        let host: String
        let executable: String
        let directory: String

        init(_ host: String, endpoint: ControlZmxEndpoint) {
            self.host = host
            executable = endpoint.executable
            directory = endpoint.socketDirectory
        }

        var endpoint: ControlZmxEndpoint { ControlZmxEndpoint(executable: executable, socketDirectory: directory) }
    }

    private struct Row {
        var list: PresentationCompanions
        var generation: Int
        var pass: Int?
        var parked: Set<String> = []
        var retries: [String: (failures: Int, due: Date)] = [:]
    }

    private struct Attempt: Sendable {
        let row: UUID
        let child: String
        let parent: String
        let host: Host
        let generation: Int
        let pass: Int
    }

    private enum Outcome: Sendable { case handled, parked, retry, dropped }
    private struct Target {
        let store: AppStore
        let controller: AppController
        let parent: String
        let host: Host
    }
    /// Written on GTK, then read after companionOnMain's semaphore has completed.
    private final class ResultBox: @unchecked Sendable { var outcome: Outcome = .dropped }

    private var rows: [UUID: Row] = [:]
    private var holds: [Host: Int] = [:]
    private var counter = 0

    func receive(_ list: PresentationCompanions?, row id: UUID) {
        guard let list else { forget(id); return }
        counter += 1
        let old = rows[id]
        let members = Set(list.members.map(\.id.uuidString))
        rows[id] = Row(list: list, generation: counter, pass: old?.pass,
                       parked: (old?.parked ?? []).intersection(members), retries: old?.retries ?? [:])
        drain(id)
    }

    func forget(_ id: UUID) {
        rows[id] = nil
        gLibrary.store(forSession: id)?.setFollowsCompanions(false, forSession: id)
    }

    func disconnected(_ connection: RemotePresentationConnection, row id: UUID) {
        if connection != .connected { forget(id) }
    }

    func promoted(_ id: UUID) { drain(id) }

    func hold(_ host: Host) { holds[host, default: 0] += 1 }

    func release(_ host: Host) {
        if let count = holds[host] { holds[host] = count > 1 ? count - 1 : nil }
        if holds[host] == nil {
            for id in Array(rows.keys) { drain(id) }
        }
    }

    func markHandled(_ child: String, on host: Host) {
        for id in Array(rows.keys) {
            guard let current = target(id), current.host == host else { continue }
            gLibrary.markOriginCompanionsHandled([child], parent: current.parent, host: host.host, endpoint: host.endpoint)
        }
    }

    func tick() {
        let now = Date()
        for (id, row) in rows where row.retries.values.contains(where: { $0.due <= now }) { drain(id) }
    }

    private func target(_ id: UUID) -> Target? {
        guard let store = gLibrary.store(forSession: id), let row = store.session(withID: id), row.parentID == nil,
              let host = row.remoteHost, let binding = row.remotePresentation?.binding, !binding.catalogOwned,
              let origin = binding.origin, let window = gLibrary.windowID(for: store), let controller = gWindows[window],
              controller.remoteClients[id]?.originSupports(PresentationHub.companionsKind) == true else { return nil }
        return Target(store: store, controller: controller,
                      parent: UUID(uuidString: binding.remoteSessionID)?.uuidString ?? binding.remoteSessionID,
                      host: Host(host, endpoint: origin.endpoint))
    }

    private func drain(_ id: UUID) {
        let resolved = target(id)
        gLibrary.store(forSession: id)?.setFollowsCompanions(rows[id] != nil && resolved != nil, forSession: id)
        guard let row = rows[id], let resolved else { return }
        let store = resolved.store, parent = resolved.parent, host = resolved.host
        guard store.session(withID: id)?.companionsBaselined == true else {
            store.baselineCompanions(row.list.members.map(\.id.uuidString), forSession: id)
            return
        }
        guard row.pass == nil, holds[host] == nil else { return }
        let shown = gLibrary.shownOriginSessions(host: host.host, endpoint: host.endpoint)
        let follow = store.companionsToFollow(row.list, forSession: id, shown: shown)
        if !follow.markOnly.isEmpty {
            gLibrary.markOriginCompanionsHandled(follow.markOnly, parent: parent, host: host.host, endpoint: host.endpoint)
        }
        let wanted = Set(follow.attach.map(\.id.uuidString))
        rows[id]?.retries = row.retries.filter { wanted.contains($0.key) }
        guard let member = follow.attach.first(where: {
            !row.parked.contains($0.id.uuidString) && (row.retries[$0.id.uuidString].map { $0.due <= Date() } ?? true)
        }) else { return }
        counter += 1
        let attempt = Attempt(row: id, child: member.id.uuidString, parent: parent, host: host,
                              generation: row.generation, pass: counter)
        rows[id]?.pass = attempt.pass
        let page = member.kind == .page
        let server = gControlServer
        DispatchQueue.global().async {
            let outcome = page ? Self.attachPage(attempt, server: server) : Self.attachTerminal(attempt, server: server)
            runOnMain { MainActor.assumeIsolated { Self.shared.settle(outcome, attempt) } }
        }
    }

    private func current(_ attempt: Attempt) -> (AppStore, AppController)? {
        guard rows[attempt.row]?.generation == attempt.generation,
              rows[attempt.row]?.list.members.contains(where: { $0.id.uuidString == attempt.child }) == true,
              let current = target(attempt.row), current.parent == attempt.parent, current.host == attempt.host,
              holds[current.host] == nil, current.store.session(withID: attempt.row)?.followedCompanions.contains(attempt.child) == false,
              !gLibrary.shownOriginSessions(host: current.host.host, endpoint: current.host.endpoint).contains(attempt.child) else { return nil }
        return (current.store, current.controller)
    }

    private func settle(_ outcome: Outcome, _ attempt: Attempt) {
        if case .handled = outcome {
            gLibrary.markOriginCompanionsHandled([attempt.child], parent: attempt.parent,
                                                host: attempt.host.host, endpoint: attempt.host.endpoint)
        }
        guard rows[attempt.row]?.pass == attempt.pass else { return }
        rows[attempt.row]?.pass = nil
        if rows[attempt.row]?.generation == attempt.generation {
            switch outcome {
            case .handled, .dropped: rows[attempt.row]?.retries[attempt.child] = nil
            case .parked:
                rows[attempt.row]?.retries[attempt.child] = nil
                rows[attempt.row]?.parked.insert(attempt.child)
            case .retry:
                let failures = (rows[attempt.row]?.retries[attempt.child]?.failures ?? 0) + 1
                rows[attempt.row]?.retries[attempt.child] = (failures, Date().addingTimeInterval(RemoteRetryBackoff.delay(afterFailures: failures)))
            }
        }
        drain(attempt.row)
    }

    nonisolated private static func attachTerminal(_ attempt: Attempt, server: ControlServer) -> Outcome {
        let response = server.readRemoteTree(host: attempt.host.host)
        guard response.ok, let tree = response.result?.remote else { return .retry }
        guard tree.endpoint == attempt.host.endpoint,
              let remote = tree.sessions.first(where: { $0.id.caseInsensitiveCompare(attempt.child) == .orderedSame }),
              remote.parent?.caseInsensitiveCompare(attempt.parent) == .orderedSame else { return .parked }
        let box = ResultBox()
        _ = server.companionOnMain {
            guard let (_, controller) = shared.current(attempt) else { return ControlResponse(ok: true) }
            let attached = controller.attachRemoteSession(host: attempt.host.host, session: remote.id, tree: tree,
                                                         parent: attempt.row, select: false, claimLead: false)
            box.outcome = .handled
            if !attached.ok {
                LinuxStructuredLogger(category: "FollowCompanions").notice(attached.error ?? "companion attachment refused")
            }
            return attached
        }
        return box.outcome
    }

    nonisolated private static func attachPage(_ attempt: Attempt, server: ControlServer) -> Outcome {
        guard let argv = try? RemoteSession.controlCommand(host: attempt.host.host,
            arguments: ["session", "overlay", "page-attach", "--target", attempt.child]) else { return .handled }
        let result = LinuxRemoteCommand.run(argv, deadline: 30)
        if result.refusedArguments { return .handled }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else { return .retry }
        guard reply.ok, let page = reply.result?.companionPage else {
            if reply.refusesUnknown(.sessionCompanionPageAttach) { return .handled }
            return [PageAttachmentBook.loopbackRefusal, PageAttachmentBook.contentRefusal].contains(reply.error ?? "") ? .handled : .parked
        }
        guard reply.result?.parent?.caseInsensitiveCompare(attempt.parent) == .orderedSame else { return .parked }
        let box = ResultBox()
        _ = server.companionOnMain {
            guard let (store, controller) = shared.current(attempt) else { return ControlResponse(ok: true) }
            if case .url(let text) = page.source, HtmlSource.isLoopback(text) { box.outcome = .handled; return controller.ok() }
            if page.persistent, let failure = LinuxBrowserStore.shared.failure() {
                box.outcome = failure == BrowserClearError.clearing ? .retry : .handled
                return controller.err(failure)
            }
            let attached = controller.attachRemotePage(page, originSession: attempt.child, host: attempt.host.host,
                                                      parent: attempt.row, select: false)
            box.outcome = .handled
            if attached.ok, let id = attached.result?.id.flatMap(UUID.init(uuidString:)),
               let pageID = attached.result?.pageID.flatMap(UUID.init(uuidString:)),
               controller.replicaPages[pageID]?.channel?.isClosed != false {
                store.discardSession(id)
                controller.reconcile(focusActive: false)
                box.outcome = .retry
            }
            return attached
        }
        return box.outcome
    }
}
