import Foundation
import agtermCore

@MainActor
extension LinuxControlDispatcher {
    func dispatchNewParityCommand(_ request: ControlRequest) -> ControlResponse? {
        switch request.cmd {
        case .keymapRun:
            guard let name = request.args?.name, !name.isEmpty else {
                return ControlResponse(ok: false, error: "keymap.run requires a command name")
            }
            return actions.runCustomCommand(name: name, target: request.target, window: request.args?.window)
        case .zmxScreen:
            guard let name = request.args?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  !name.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7f }) else {
                return ControlResponse(ok: false, error: "zmx.screen requires a daemon name")
            }
            if request.args?.all == true, request.args?.lines != nil {
                return ControlResponse(ok: false, error: "use either --all or --lines, not both")
            }
            if let lines = request.args?.lines, lines <= 0 {
                return ControlResponse(ok: false, error: "--lines must be greater than 0")
            }
            return actions.readZmxScreen(name: name, fullBuffer: request.args?.all == true,
                                         lines: request.args?.lines)
        case .sessionOverlaySubmit:
            guard let value = request.args?.value else {
                return ControlResponse(ok: false, error: OverlayHtmlError.submitValue)
            }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.submitSessionOverlay(request.target, window: request.args?.window, pane: pane, value: value)
            }
        case .sessionOverlayResult where request.args?.page != nil:
            guard let id = request.args?.page.flatMap(UUID.init(uuidString:)) else {
                return ControlResponse(ok: false, error: OverlayHtmlError.invalidPageID)
            }
            return actions.htmlPageResult(id)
        default: return nil
        }
    }
}

@MainActor
extension AppController {
    func readZmxScreen(name: String, fullBuffer: Bool, lines: Int?) -> ControlResponse {
        guard let client = gZmxClient else { return err("zmx is unavailable in this instance") }
        guard let screen = client.screen(name: name, all: fullBuffer || lines != nil) else {
            return err("could not read the zmx screen of \(name)")
        }
        return ControlResponse(ok: true, result: ControlResult(text: lines.map(screen.lastLines) ?? screen.text))
    }

    func submitSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, value: String) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let failure = store.submitHtmlOverlay(id, pane: pane, value: value) { return err(failure.message) }
            reconcile()
            return ok(id)
        }
    }

    func readSurfaceCursor(_ target: String?, window: String?, paneID: String?) -> ControlResponse {
        guard let paneID, !paneID.isEmpty else { return readSurfaceCursor(target, window: window) }
        let target = target?.trimmingCharacters(in: .whitespacesAndNewlines)
        if target == "quick" || target.flatMap(TerminalSurfaceID.init(rawValue:)) != nil {
            return err("surface.cursor: --pane-id takes a session target")
        }
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let pane = store.session(withID: id)?.paneRole(forToken: paneID) else {
                return err("unknown pane id: \(paneID)")
            }
            let kind: TerminalZoomSurface = pane == .right ? .split : (pane == .scratch ? .scratch : .primary)
            return readSurfaceCursor(TerminalSurfaceID(sessionID: id, surface: kind).rawValue, window: window)
        }
    }

    func runCustomCommand(name: String, target: String?, window: String?) -> ControlResponse {
        guard let command = keymap.commands.first(where: { $0.name == name }) else {
            return err("no custom command named \(name)")
        }
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard runCustomCommand(command, targetSession: store.session(withID: id)) else {
                return err("command failed to launch: \(name)")
            }
            return ok(id)
        }
    }
}
