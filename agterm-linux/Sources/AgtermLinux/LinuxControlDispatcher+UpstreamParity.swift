import agtermCore
import Foundation

@MainActor
extension LinuxControlDispatcher {
    func dispatchZmxCommand(_ request: ControlRequest) -> ControlResponse? {
        switch request.cmd {
        case .restoreMode:
            guard let raw = request.args?.mode else { return actions.readRestoreMode() }
            guard let mode = RestoreMode(rawValue: raw) else {
                return ControlResponse(ok: false, error: "invalid restore mode: \(raw)")
            }
            return actions.setRestoreMode(mode)
        case .zmxList:
            return actions.listZmxDaemons()
        case .zmxPrune:
            return actions.pruneZmxDaemons()
        case .zmxKill:
            guard let target = request.target, !target.isEmpty else {
                return ControlResponse(ok: false, error: "zmx.kill requires an explicit --target")
            }
            guard let rawPane = request.args?.pane,
                  let pane = ZmxPaneRole(controlName: rawPane) else {
                return ControlResponse(ok: false, error: "zmx.kill requires --pane left|right")
            }
            guard request.args?.force == true else {
                return ControlResponse(ok: false, error: "zmx.kill requires --force")
            }
            return actions.killZmxDaemon(target: target, window: request.args?.window, pane: pane)
        case .zmxTree:
            return request.args?.host?.linuxTrimmedOrNil == nil ? actions.localAttachableSessions() : nil
        case .zmxAttach:
            return nil
        default:
            preconditionFailure("unexpected zmx command: \(request.cmd.rawValue)")
        }
    }

    func dispatchSessionContext(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let context: String?
        switch args?.mode ?? "" {
        case "set":
            guard let text = args?.text else {
                return ControlResponse(ok: false, error: "session.context set requires text")
            }
            switch Session.validateContext(text) {
            case .valid(let value): context = value
            case .invalid(let message): return ControlResponse(ok: false, error: message)
            }
        case "clear":
            guard args?.text == nil else {
                return ControlResponse(ok: false, error: "session.context clear takes no text")
            }
            context = nil
        default:
            let rawMode = args?.mode ?? ""
            return ControlResponse(ok: false,
                                   error: "invalid context mode: \(rawMode) (set|clear)")
        }
        return actions.setSessionContext(request.target, window: args?.window, context: context)
    }
}
