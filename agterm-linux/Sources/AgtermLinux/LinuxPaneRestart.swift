import Foundation
import agtermCore

@MainActor
extension AppController {
    func restartPane(_ request: ControlRequest, completion: @escaping @MainActor (ControlResponse) -> Void) {
        func refuse(_ message: String) { completion(err(message)) }
        guard let command = request.args?.command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return refuse("session.restart requires a command")
        }
        guard !command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return refuse("command must not contain control characters") }
        guard command.utf8.count <= ControlSessionRestartOptions.maxCommandBytes else {
            return refuse("command too long (max \(ControlSessionRestartOptions.maxCommandBytes) bytes)")
        }
        let requestedPane: StatusPane?
        if let raw = request.args?.pane {
            guard let pane = StatusPane(rawValue: raw) else { return refuse("invalid pane: \(raw) (left, right, scratch)") }
            requestedPane = pane
        } else { requestedPane = nil }
        guard requestedPane != .scratch else { return refuse("session.restart does not address the scratch pane") }
        let token = request.args?.paneID.flatMap { $0.isEmpty ? nil : $0 }
        guard requestedPane != nil || token != nil else { return refuse("session.restart requires --pane-id or --pane") }
        let id: UUID
        switch resolveSessionResponse(request.target) {
        case .failure(let response): return completion(response)
        case .success(let resolved): id = resolved
        }
        guard let session = store.session(withID: id) else { return refuse("session not realized") }
        guard session.remoteHost == nil else { return refuse("session.restart needs a local pane") }
        if let token, session.paneRole(forToken: token) == nil { return refuse("unknown pane id: \(token)") }
        let pane: StatusPane
        switch session.paneAddress(token: token, pane: requestedPane) {
        case .unknownToken(let token): return refuse("unknown pane id: \(token)")
        case .pane(.scratch), .pane(nil): return refuse("session.restart does not address the scratch pane")
        case .pane(let role?): pane = role
        }
        guard pane != .right || session.hasSplit else { return refuse("session has no split pane") }
        guard let surface = (pane == .right ? session.splitSurface : session.surface) as? GhosttySurface,
              let identity = UUID(uuidString: surface.paneToken) else { return refuse("session not realized") }
        guard surface.backedByZmx, let client = gZmxClient else {
            return refuse("session.restart needs Live sessions mode; this pane has no live shell to replace")
        }
        LinuxPaneRestart(controller: self, session: session, surface: surface, identity: identity,
                         client: client, command: command, completion: completion).begin()
    }
}

/// Waits live on worker threads; every model/surface transition comes back through GLib.
@MainActor
private final class LinuxPaneRestart {
    private static var pending: Set<UUID> = []
    let controller: AppController
    let session: Session
    var surface: GhosttySurface
    let identity: UUID
    let client: LinuxZmxClient
    let command: String
    let completion: @MainActor (ControlResponse) -> Void
    let lead = ZmxLeadAttachment(claim: false)
    var config: ZmxSupport.Configuration?
    var daemon: String { ZmxSupport.daemonName(for: identity) }

    init(controller: AppController, session: Session, surface: GhosttySurface, identity: UUID,
         client: LinuxZmxClient, command: String, completion: @escaping @MainActor (ControlResponse) -> Void) {
        self.controller = controller
        self.session = session
        self.surface = surface
        self.identity = identity
        self.client = client
        self.command = command
        self.completion = completion
    }

    func begin() {
        guard Self.pending.insert(identity).inserted else {
            return completion(controller.err("this pane is already restarting"))
        }
        start()
    }

    private var stillOwned: Bool {
        controller.store.session(withID: session.id) === session
            && (session.paneIdentity == identity ? session.surface : session.splitSurface) === surface
    }

    private func start() {
        guard let config = try? LinuxZmxLaunch.configuration(paneIdentity: identity, baseEnvironment: surface.env, lead: lead).get() else {
            return finish("live sessions are unavailable for this pane")
        }
        self.config = config
        let name = daemon, client = client
        Thread.detachNewThread { [self] in
            let oldPID = Self.shell(name: name, client: client, otherThan: nil, timeout: 5)
            let job = oldPID.flatMap { client.foregroundJob(ofShell: $0) }
            runOnMain { MainActor.assumeIsolated { self.killOld(pid: oldPID, job: job) } }
        }
    }

    private func killOld(pid: Int32?, job: [ProcessRecord]?) {
        guard let pid else { return finish("the pane's shell is not running") }
        guard stillOwned else { return finish("the pane changed before the restart; nothing was started") }
        guard let job else { return finish("the process table cannot be read; nothing was changed") }
        switch client.killConfirmed(name: daemon) {
        case .killed: break
        case .staleSocket: return finish("the daemon did not confirm the kill; nothing was started")
        case .failed(let reason): return finish("could not end the pane's shell: \(reason); nothing was started")
        }
        _ = surface.claimProcessExit()
        ZmxLeadBook.shared.forget(pane: identity)
        let client = client
        Thread.detachNewThread { [self] in
            let ended = Self.waitForJob(job, client: client)
            runOnMain { MainActor.assumeIsolated { self.replace(oldPID: pid, ended: ended) } }
        }
    }

    private func replace(oldPID: Int32, ended: Bool) {
        guard ended, stillOwned, let config, let role = session.paneRole(forIdentity: identity) else {
            closeEnded()
            return finish("the old shell ended (pid \(oldPID)) but the program or pane could not be replaced; nothing was started")
        }
        controller.store.clearPaneOwnedState(session.id, pane: role == .right ? .right : .left)
        let launch = ZmxSupport.attachCommand(config, replaying: nil, creationCommand: command, denylist: [])
        guard let replacement = controller.replacePane(surface, command: launch, environment: config.environment, wait: false, lead: lead) else {
            closeEnded()
            return finish("the old shell ended; the pane could not be rebuilt and was closed")
        }
        surface = replacement
        guard replacement.isRealized else {
            replacement.teardown()
            closeEnded()
            return finish("the old shell ended; the new terminal could not be created and the pane was closed")
        }
        let name = daemon, client = client
        Thread.detachNewThread { [self] in
            let newPID = Self.shell(name: name, client: client, otherThan: oldPID, timeout: 10)
            runOnMain {
                MainActor.assumeIsolated {
                    guard let newPID else { return self.finish("the old shell ended (pid \(oldPID)) and no new one was observed") }
                    guard self.stillOwned else { return self.finish("the pane changed during the restart") }
                    let pane = self.session.paneIdentity == self.identity ? "left" : "right"
                    Self.pending.remove(self.identity)
                    self.completion(ControlResponse(ok: true, result: ControlResult(
                        id: self.session.id.uuidString, text: "restarted \(pane) pane: shell \(oldPID) -> \(newPID)", pane: pane,
                        restart: ControlRestartReceipt(paneID: self.identity.uuidString, oldPid: oldPID, newPid: newPID))))
                }
            }
        }
    }

    private func closeEnded() {
        if controller.store.session(withID: session.id) != nil {
            if session.surface === surface {
                controller.closePrimaryPane(session.id, alreadyFinalized: identity)
            } else if session.splitSurface === surface {
                controller.closeSplitPane(session.id, alreadyFinalized: identity)
            }
        } else { controller.store.finalizePendingClose(ofSession: session.id) }
    }

    private func finish(_ error: String) {
        Self.pending.remove(identity)
        completion(controller.err(error))
    }

    nonisolated private static func shell(name: String, client: LinuxZmxClient, otherThan: Int32?, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let pid = client.sessionLeaderPIDs(timeout: 1)?[name], pid != otherThan { return pid }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    nonisolated private static func waitForJob(_ job: [ProcessRecord], client: LinuxZmxClient) -> Bool {
        for (grace, kills) in [(1.0, true), (0.5, false)] {
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline {
                if !client.isRunning(job) { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if kills { client.forceEnd(job) }
        }
        return !client.isRunning(job)
    }
}
