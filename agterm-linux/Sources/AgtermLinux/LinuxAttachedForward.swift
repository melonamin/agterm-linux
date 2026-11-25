import Foundation
import agtermCore

struct LinuxAttachedPlan: Sendable {
    let action: AttachedForward
    let origin: AttachedOrigin
    let row: UUID
    var parent: UUID?
    var index: Int?
    var promotion: CompanionPromotion?
    var attaches = false
}

private final class LinuxAttachedBox: @unchecked Sendable {
    var response: ControlResponse?
    var plan: LinuxAttachedPlan?
}

extension ControlServer {
    static let attachedCommands: Set<Command> = [
        .sessionRestart, .zmxKill, .zmxKillPane, .sessionCompanionConvert, .sessionCompanionMove, .sessionCompanionPromote,
        .sessionDuplicate, .sessionSplit, .sessionSplitClose, .sessionScratch, .sessionRestore,
    ]

    /// Resolve on GTK, run SSH on the request worker, then apply only the acknowledged local effects.
    func performAttachedRequest(_ request: ControlRequest) -> ControlResponse? {
        if request.cmd == .sessionTerminate { return terminateAttachedRequest(request) }
        guard Self.attachedCommands.contains(request.cmd) else { return nil }
        let box = LinuxAttachedBox()
        _ = companionOnMain {
            guard !ControlDispatcher.refusesArguments(request) else { return ControlResponse(ok: true) }
            guard case .controller(let controller?) = Self.route(for: request),
                  case .success(let id) = controller.resolveSessionResponse(request.target),
                  let row = controller.store.session(withID: id), let origin = AttachedOrigin(row) else { return ControlResponse(ok: true) }
            if request.cmd == .sessionCompanionPromote {
                guard let parent = row.parentID.flatMap(controller.store.session(withID:)),
                      let parentOrigin = AttachedOrigin(parent), parentOrigin.shares(origin) else { return controller.ok() }
            }
            if request.cmd == .sessionCompanionMove, let target = request.args?.parent,
               case .success(let parent) = controller.resolveSessionResponse(target), row.parentID == parent {
                return controller.ok()
            }
            if request.cmd == .zmxKill || request.cmd == .zmxKillPane,
               request.target == "active" || request.args?.window == "active" { return ControlResponse(ok: true) }
            switch controller.attachedPlan(request, row: row, origin: origin) {
            case .success(let plan): box.plan = plan
            case .failure(let refusal): box.response = controller.err(refusal.message)
            }
            return ControlResponse(ok: true)
        }
        if let response = box.response { return response }
        guard let plan = box.plan else { return nil }
        switch runAttached(plan.action, origin: plan.origin, attaching: plan.attaches) {
        case .refused(let reason), .unknown(let reason): return ControlResponse(ok: false, error: reason)
        case .done(let reply): return finishAttached(plan, reply: reply)
        }
    }

    private func runAttached(_ action: AttachedForward, origin: AttachedOrigin, attaching: Bool = false) -> AttachedOutcome {
        guard let argv = try? RemoteSession.controlCommand(host: origin.host,
            arguments: action.words + (attaching ? ["--attach-pending"] : []), operands: action.operands) else {
            return .refused("invalid host")
        }
        let result = LinuxRemoteCommand.run(argv, deadline: 30)
        if attaching, result.refusedArguments { return runAttached(action, origin: origin) }
        return action.outcome(of: result, host: origin.host)
    }

    private func finishAttached(_ plan: LinuxAttachedPlan, reply: ControlResponse) -> ControlResponse {
        switch plan.action {
        case .duplicate, .convert:
            let convert: Bool
            if case .convert = plan.action { convert = true } else { convert = false }
            guard let created = convert ? reply.result?.parent : reply.result?.id else {
                return ControlResponse(ok: false, error: "\(plan.origin.host) did it but did not name the session it created")
            }
            return attachCreatedFromOrigin(created, beside: plan, convert: convert)
        default:
            return companionOnMain {
                guard let store = gLibrary.store(forSession: plan.row), let window = gLibrary.windowID(for: store),
                      let controller = gWindows[window] else { return ControlResponse(ok: false, error: "the attached row closed") }
                if let parent = plan.parent {
                    if case .failure(let refusal) = store.moveCompanion(plan.row, under: parent, at: plan.index) {
                        return controller.err("moved on \(plan.origin.host), but not here: \(refusal.message)")
                    }
                }
                if let promotion = plan.promotion {
                    if reply.ok, store.session(withID: plan.row)?.companionsBaselined == false {
                        store.baselineCompanions([], forSession: plan.row)
                    }
                    if case .failure(let refusal) = store.promoteCompanion(plan.row, to: promotion) {
                        return controller.err("top-level on \(plan.origin.host), but not here: \(refusal.message)")
                    }
                }
                if case .scratch = plan.action, plan.index == -1 { store.selectSession(plan.row) }
                var result = reply.result ?? ControlResult()
                result.id = plan.row.uuidString
                if let receipt = result.restart, let pane = UUID(uuidString: receipt.paneID),
                   let local = store.session(withID: plan.row)?.remotePresentation?.binding.localPane(forRemote: pane) {
                    result.restart = ControlRestartReceipt(paneID: local.uuidString, oldPid: receipt.oldPid, newPid: receipt.newPid,
                                                          replayedArgv: receipt.replayedArgv)
                }
                controller.reconcile(focusActive: false)
                return ControlResponse(ok: true, result: result)
            }
        }
    }

    private func attachCreatedFromOrigin(_ created: String, beside plan: LinuxAttachedPlan, convert: Bool) -> ControlResponse {
        let deadline = Date().addingTimeInterval(20)
        repeat {
            let listing = readRemoteTree(host: plan.origin.host)
            if let tree = listing.result?.remote, tree.sessions.contains(where: { $0.id == created }) {
                return companionOnMain {
                    guard let store = gLibrary.store(forSession: plan.row), let window = gLibrary.windowID(for: store),
                          let controller = gWindows[window], let source = store.session(withID: plan.row),
                          let workspace = store.workspace(forSession: source.id) else {
                        return ControlResponse(ok: false, error: "created \(created) on \(plan.origin.host), but its local row closed")
                    }
                    let response = controller.attachRemoteSession(host: plan.origin.host, session: created, tree: tree,
                                                                 placementWorkspace: workspace.id)
                    guard response.ok, let local = response.result?.id.flatMap(UUID.init(uuidString:)) else { return response }
                    if convert {
                        store.nest(plan.row, under: local)
                    } else if let index = workspace.sessions.firstIndex(where: { $0.id == source.id }) {
                        _ = store.moveSessions([local], toWorkspace: workspace.id, at: index + 1)
                    }
                    controller.reconcile()
                    return convert ? ControlResponse(ok: true, result: ControlResult(id: plan.row.uuidString, parent: local.uuidString)) : response
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return ControlResponse(ok: false, error: "created \(created) on \(plan.origin.host), but it could not be attached; use `agtermctl zmx attach`")
    }

    private func terminateAttachedRequest(_ request: ControlRequest) -> ControlResponse? {
        // Each target resolves independently before any effect. Origins decide their own group closure.
        let box = LinuxTerminateBox()
        let checked = companionOnMain {
            guard case .controller(let controller?) = Self.route(for: request) else { return ControlResponse(ok: false, error: "no controller") }
            box.window = controller.windowID
            for target in request.args?.targets ?? [request.target ?? "active"] {
                switch controller.resolveSessionResponse(target) {
                case .failure(let response): return response
                case .success(let id):
                    guard let row = controller.store.session(withID: id) else { return controller.err("no such session") }
                    box.rows.append((id, AttachedOrigin(row)))
                }
            }
            return controller.ok()
        }
        guard checked.ok else { return checked }
        var failures: [String] = []
        var undoable = request.args?.undoable == true
        let initiated = Date()
        var handled: [AttachedOrigin] = []
        for (id, origin) in box.rows {
            if let origin {
                if handled.contains(where: { $0.shares(origin) }) { continue }
                handled.append(origin)
                let sessions = box.rows.compactMap { $0.1 }.filter { $0.shares(origin) }.map(\.session)
                switch runAttached(.terminate(sessions: sessions, undoable: request.args?.undoable == true), origin: origin) {
                case .refused(let reason), .unknown(let reason): failures.append(reason)
                case .done(let reply):
                    let ended = Set(reply.result?.closed ?? sessions)
                    _ = companionOnMain {
                        for controller in gWindows.values {
                            let ids = controller.store.workspaces.flatMap(\.sessions).filter {
                                guard let other = AttachedOrigin($0) else { return false }
                                return other.shares(origin) && ended.contains(other.session)
                            }.map(\.id)
                            box.closed += controller.store.closeExactly(Set(ids)).map(\.uuidString)
                            controller.reconcile(focusActive: false)
                        }
                        if let recent = reply.result?.recentID, sessions.count == 1 {
                            gLibrary.noteOriginRecentID(recent, host: origin.host, sessionID: sessions[0])
                        }
                        if let window = box.window, reply.result?.undoable == true, let undo = reply.result?.undoID {
                            gLibrary.noteAttachedUndo(AttachedUndo(host: origin.host, undoID: undo, sessions: Array(ended), initiated: initiated), window: window)
                            gWindows[window]?.refreshPaletteContents()
                        }
                        return ControlResponse(ok: true)
                    }
                    undoable = undoable && reply.result?.undoable == true
                }
            } else {
                let response = companionOnMain {
                    guard let window = box.window, let controller = gWindows[window] else { return ControlResponse(ok: false) }
                    return controller.closeSession(id.uuidString, window: nil, undoable: request.args?.undoable == true)
                }
                box.closed += response.result?.closed ?? []
                if !response.ok { failures.append(response.error ?? "local close failed") }
            }
        }
        return ControlResponse(ok: failures.isEmpty,
            result: ControlResult(affected: box.closed.count, undoable: request.args?.undoable == true ? undoable : nil, closed: box.closed),
            error: failures.isEmpty ? nil : failures.joined(separator: "; "))
    }
}

private final class LinuxTerminateBox: @unchecked Sendable {
    var rows: [(UUID, AttachedOrigin?)] = []
    var window: UUID?
    var closed: [String] = []
}

struct LinuxAttachedRefusal: Error { let message: String }

@MainActor
extension AppController {
    func attachedPlan(_ request: ControlRequest, row: Session, origin: AttachedOrigin) -> Result<LinuxAttachedPlan, LinuxAttachedRefusal> {
        let args = request.args
        let session = origin.session
        let action: AttachedForward
        var parent: UUID?
        var promotion: CompanionPromotion?
        switch request.cmd {
        case .sessionDuplicate: action = .duplicate(after: session, cwd: row.focusedCwd)
        case .sessionCompanionConvert: action = .convert(session: session)
        case .sessionCompanionPromote:
            guard let placement = ControlDispatcher.companionPromotion(args) else {
                return .failure(.init(message: "invalid companion placement"))
            }
            switch resolveCompanionPromotion(placement) {
            case .failure(let response): return .failure(.init(message: response.error ?? "invalid companion placement"))
            case .success(let resolved):
                if case .failure(let refusal) = store.canPromoteCompanion(row.id, to: resolved) {
                    return .failure(.init(message: refusal.message))
                }
                promotion = resolved
            }
            action = .promoteCompanion(session: session)
        case .sessionSplit: action = .split(session: session, mode: args?.mode ?? "toggle", axis: args?.axis)
        case .sessionSplitClose: action = .closeSplit(session: session)
        case .sessionScratch:
            guard row.remotePresentation?.connection == .connected, row.remotePresentation?.layout?.scratchShown != nil else {
                return .failure(.init(message: "the origin is not connected or cannot show its scratch here"))
            }
            action = .scratch(session: session, mode: args?.mode ?? "toggle", command: args?.command)
        case .sessionCompanionMove:
            guard let target = args?.parent, case .success(let id) = resolveSessionResponse(target),
                  let parentRow = store.session(withID: id), let other = AttachedOrigin(parentRow), other.shares(origin) else {
                return .failure(.init(message: CompanionMoveRefusal.otherHost.message))
            }
            if case .failure(let refusal) = store.canMoveCompanion(row.id, under: id) { return .failure(.init(message: refusal.message)) }
            parent = id
            action = .moveCompanion(session: session, parent: other.session)
        default:
            let policy: LinuxAttachedPaneToken
            switch request.cmd {
            case .sessionRestart: policy = .strict
            case .zmxKill: policy = .ignored
            case .zmxKillPane: policy = .pinned
            default: policy = .fallback
            }
            var paneArgs = args
            if request.cmd == .sessionRestore, args?.pane == nil, args?.paneID == nil { paneArgs = ControlArgs(pane: "left") }
            let pane: (role: ZmxPaneRole, token: String)
            switch originPane(paneArgs, row: row, origin: origin, policy: policy) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let resolved): pane = resolved
            }
            let token = pane.token
            switch request.cmd {
            case .sessionRestart:
                guard remoteClients[row.id]?.originSupports(PresentationHub.restartRespawnKind) == true else {
                    return .failure(.init(message: "the origin is not connected or cannot restart a pane from here"))
                }
                action = .restart(session: session, paneID: token, command: args?.command)
            case .zmxKill, .zmxKillPane:
                guard args?.force == true else { return .failure(.init(message: "zmx kill requires --force")) }
                let layout = row.remotePresentation?.layout
                let role: ZmxPaneRole = layout?.panes.contains(where: { $0.uuidString == token }) == true
                    ? (layout?.primary.uuidString == token ? .left : .right) : pane.role
                action = .killPane(session: session, pane: role, paneID: token)
            case .sessionRestore:
                guard !origin.headless else { return .failure(.init(message: "agterm-server keeps every pane running")) }
                let pin: ControlRestoreOverride
                switch args?.mode {
                case "set": pin = .pin(args?.command ?? "")
                case "none": pin = .pinNone
                case "clear": pin = .unpin
                default: return .failure(.init(message: "invalid restore mode"))
                }
                action = .restore(session: session, paneID: token, pin: pin)
            default: return .failure(.init(message: "unsupported attached command"))
            }
        }
        var mounted = true
        if request.cmd == .sessionRestart,
           case .success(let pane) = originPane(args, row: row, origin: origin, policy: .strict) {
            mounted = OverlayPane(rawValue: pane.role.rawValue).map(row.rendersPane) ?? false
        }
        return .success(LinuxAttachedPlan(action: action, origin: origin, row: row.id, parent: parent,
                                         index: args?.follow == true && request.cmd == .sessionScratch ? -1 : args?.index,
                                         promotion: promotion, attaches: action.attachesPane && mounted))
    }
}

private enum LinuxAttachedPaneToken { case strict, fallback, pinned, ignored }

@MainActor
private extension AppController {
    func originPane(_ args: ControlArgs?, row: Session, origin: AttachedOrigin, policy: LinuxAttachedPaneToken)
        -> Result<(role: ZmxPaneRole, token: String), LinuxAttachedRefusal> {
        let panes: [(ZmxPaneRole, UUID?)] = [(.left, row.paneIdentity), (.right, row.splitPaneIdentity)]
        let token = policy == .ignored ? nil : args?.paneID.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let byToken = token.flatMap(UUID.init(uuidString:)).flatMap { token in panes.first { $0.1 == token } }
        let byRole = args?.pane.flatMap(ZmxPaneRole.init(controlName:)).flatMap { role in panes.first { $0.0 == role } }
        if let token, byToken == nil, policy == .strict || byRole == nil {
            return .failure(.init(message: "unknown pane id: \(token)"))
        }
        if policy == .pinned, let token, let (role, identity) = byRole, let identity,
           let refusal = ZmxPaneRole.pinRefusal(token, identity: identity, pane: role) {
            return .failure(.init(message: refusal))
        }
        guard let (role, identity) = byToken ?? byRole else {
            return .failure(.init(message: "name the pane with --pane left|right or --pane-id"))
        }
        guard let identity, let token = AttachedOrigin.originPaneID(of: row, local: identity) else {
            return .failure(.init(message: "no \(role.rawValue) pane of the session on \(origin.host) is attached here"))
        }
        return .success((role, token))
    }
}
