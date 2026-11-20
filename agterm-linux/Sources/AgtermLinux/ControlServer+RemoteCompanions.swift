import Foundation
import agtermCore

struct LinuxRemoteCompanionPlan: Sendable {
    let request: LinuxRemoteCompanionRequest
    let host: String
    let origin: String
    let parent: UUID
    let parentOrigin: String
    let select: Bool
}

final class LinuxRemoteCompanionBox: @unchecked Sendable {
    var response = ControlResponse(ok: false, error: "no controller")
    var plan: LinuxRemoteCompanionPlan?
}

extension ControlServer {
    /// Creation runs once. Polling readiness may retry; a failed attach always names the created origin row.
    func createRemoteCompanion(_ plan: LinuxRemoteCompanionPlan) -> ControlResponse {
        let current = readRemoteTree(host: plan.host)
        guard current.ok, let tree = current.result?.remote else { return current }
        guard tree.sessions.contains(where: { $0.id == plan.parentOrigin }) else {
            return ControlResponse(ok: false, error: "the session on \(plan.host) is not attachable now; nothing was created")
        }
        guard let argv = try? RemoteSession.controlCommand(host: plan.host, arguments: plan.request.arguments(originSession: plan.origin)) else {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = LinuxRemoteCommand.run(argv, deadline: 30)
        if result.refusedArguments { return companionUnsupported(plan.host) }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return ControlResponse(ok: false, error: "\(plan.host) gave no answer\(detail.isEmpty ? "" : " (\(detail))"); "
                + "whether the companion was created there is unknown")
        }
        guard reply.ok else {
            if reply.refusesUnknown(plan.request.command) { return companionUnsupported(plan.host) }
            return reply
        }
        guard let created = reply.result?.id, UUID(uuidString: created) != nil else {
            return ControlResponse(ok: false, error: "\(plan.host) created a companion but did not name it")
        }
        func failed(_ reason: String) -> ControlResponse {
            ControlResponse(ok: false, error: "created companion \(created) on \(plan.host) but could not attach it: \(reason); "
                + "`agtermctl zmx attach \(plan.host) \(created)` attaches it")
        }
        guard result.status == 0 else { return failed("the connection failed") }
        if case .page = plan.request {
            let response = attachRemotePage(created, host: plan.host, parent: plan.parent, select: plan.select)
            return response.ok ? response : failed(response.error ?? "attach failed")
        }
        let deadline = Date().addingTimeInterval(20)
        var reason = "it did not become attachable"
        repeat {
            let listing = readRemoteTree(host: plan.host)
            if let tree = listing.result?.remote, tree.sessions.contains(where: { $0.id == created }) {
                let response = companionOnMain {
                    guard let store = gLibrary.store(forSession: plan.parent),
                          let parent = store.session(withID: plan.parent), parent.remoteHost == plan.host,
                          parent.remotePresentation?.binding.remoteSessionID == plan.parentOrigin,
                          let window = gLibrary.windowID(for: store), let controller = gWindows[window] else {
                        return ControlResponse(ok: false, error: "its parent row here was closed or changed")
                    }
                    return controller.attachRemoteSession(host: plan.host, session: created, tree: tree,
                                                          parent: plan.parent, select: plan.select, tint: plan.request.tint)
                }
                return response.ok ? response : failed(response.error ?? "attach failed")
            }
            reason = listing.error ?? reason
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return failed(reason)
    }

    func attachRemotePage(_ origin: String, host: String, parent: UUID, select: Bool) -> ControlResponse {
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: ["session", "overlay", "page-attach", "--target", origin]) else {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = LinuxRemoteCommand.run(argv, deadline: 30)
        guard !result.refusedArguments else { return companionUnsupported(host) }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            return ControlResponse(ok: false, error: "\(host) gave no answer")
        }
        guard result.status == 0, reply.ok, let page = reply.result?.companionPage else {
            if reply.refusesUnknown(.sessionCompanionPageAttach) { return companionUnsupported(host) }
            return ControlResponse(ok: false, error: reply.error ?? "\(host) did not hand the page over")
        }
        return companionOnMain {
            guard let store = gLibrary.store(forSession: parent), let row = store.session(withID: parent), row.remoteHost == host,
                  let window = gLibrary.windowID(for: store), let controller = gWindows[window] else {
                return ControlResponse(ok: false, error: "its parent row here was closed")
            }
            return controller.attachRemotePage(page, originSession: origin, host: host, parent: parent, select: select)
        }
    }

    func companionOnMain(_ operation: @escaping @MainActor @Sendable () -> ControlResponse) -> ControlResponse {
        let box = LinuxRemoteCompanionBox(), ready = DispatchSemaphore(value: 0)
        runOnMain { MainActor.assumeIsolated { box.response = operation(); ready.signal() } }
        ready.wait()
        return box.response
    }

    private func companionUnsupported(_ host: String) -> ControlResponse {
        ControlResponse(ok: false, error: "the agterm on \(host) is too old for companions")
    }
}
