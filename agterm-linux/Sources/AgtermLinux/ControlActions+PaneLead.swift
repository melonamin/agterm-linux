import Foundation
import agtermCore

private enum LinuxLeadPaneSource {
    case surface
    case daemon(String, LinuxZmxClient)
    case refused(String)
}

@MainActor
extension AppController {
    private func leadPaneSource(_ surface: GhosttySurface, viewport: Bool = false) -> LinuxLeadPaneSource {
        let pane = UUID(uuidString: surface.paneToken)
        let covered = ZmxLeadBook.shared.covered(pane: pane)
        guard covered || ZmxLeadBook.shared.role(pane: pane) != nil else { return .surface }
        guard surface.backedByZmx, let pane, let client = gZmxClient else {
            return covered
                ? .refused("pane is in use on its origin host; take the lead to drive it from here")
                : .surface
        }
        return !covered && viewport ? .surface : .daemon(ZmxSupport.daemonName(for: pane), client)
    }

    func coveredPaneRefusal(_ surface: GhosttySurface) -> ControlResponse? {
        guard ZmxLeadBook.shared.covered(pane: UUID(uuidString: surface.paneToken)) else { return nil }
        return err("pane is covered while another host leads it; take the lead first (session lead)")
    }

    func leadText(_ surface: GhosttySurface, session: UUID, all: Bool, lines: Int?) -> ControlResponse? {
        switch leadPaneSource(surface, viewport: !all && lines == nil) {
        case .surface: return nil
        case .refused(let reason): return err(reason)
        case .daemon(let name, let client):
            guard let screen = client.screen(name: name, all: all || lines != nil) else {
                return err("failed to read surface buffer")
            }
            return ControlResponse(ok: true, result: ControlResult(
                id: session.uuidString, text: lines.map(screen.lastLines) ?? screen.text))
        }
    }

    func leadCursor(_ surface: GhosttySurface, controlID: String) -> ControlResponse? {
        switch leadPaneSource(surface) {
        case .surface: return nil
        case .refused(let reason): return err(reason)
        case .daemon(let name, let client):
            guard let screen = client.screen(name: name, all: false) else {
                return err("failed to read cursor position")
            }
            return ControlResponse(ok: true, result: ControlResult(
                id: controlID, cursor: ControlCursor(column: screen.cursorColumn)))
        }
    }

    func leadType(_ text: String, surface: GhosttySurface, session: UUID) -> ControlResponse? {
        switch leadPaneSource(surface) {
        case .surface: return nil
        case .refused(let reason): return err(reason)
        case .daemon(let name, let client):
            let bytes = KeystrokeSegments.ptyBytes(text)
            guard bytes.isEmpty || client.type(name: name, bytes: bytes) else {
                return err("the pane's zmx daemon did not accept the input")
            }
            if !text.isEmpty, let role = store.session(withID: session)?.paneRole(forToken: surface.paneToken) {
                clearAttentionStatus(session, pane: role, keystroke: InterruptKeystroke.classify(text: text))
            }
            return ok(session)
        }
    }
}
