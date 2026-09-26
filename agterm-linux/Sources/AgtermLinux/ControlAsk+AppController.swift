import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func openAsk(_ ask: PendingAsk, target: String?, window: String?,
                 placement: ControlAskPlacement, follow: Bool) -> ControlResponse {
        if ask.style == .terminal {
            return openTerminalAsk(ask, target: target, placement: placement, follow: follow)
        }
        let anchor: AskAnchor?
        if let target {
            switch resolveSessionResponse(target) {
            case .failure(let response): return response
            case .success(let id):
                guard let session = store.session(withID: id) else { return err("no such session") }
                if let remote = presentAskRemotely(ask, in: session, placement: placement) { return remote }
                guard store.selectedSessionID == id, terminalZoom.target == nil,
                      !dashboard.isOpen else { return err("session not visible") }
                switch resolveControlPanePlacement(placement.pane, paneID: placement.paneID, in: session,
                                                   requireVisible: true, invalidPaneError: "ask pane must be left or right") {
                case .resolved(let identity, let pane):
                    anchor = AskAnchor(sessionID: id, pane: pane, paneIdentity: identity)
                case .rejected(let response): return response
                }
            }
        } else {
            anchor = nil
        }
        let pending = PendingAsk(id: ask.id, title: ask.title, message: ask.message,
                                 buttons: ask.buttons, defaultID: ask.defaultID,
                                 destructiveID: ask.destructiveID, style: ask.style,
                                 align: ask.align, width: ask.width, anchor: anchor)
        guard guiAskWindow == nil else { return err("ask already pending") }
        guard pickController.openAsk(pending) else {
            return err(pickController.pendingAsk == nil ? "pick already pending" : "ask already pending")
        }
        AskRegistry.shared.register(id: ask.id, owner: .window(windowID))
        if follow { gtk_window_present(WIN(windowPointer)) }
        guard showGUIAsk(pending) else {
            pickController.cancelAsk()
            return err("no ask surface")
        }
        return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: anchor?.pane?.rawValue))
    }

    private func openTerminalAsk(_ ask: PendingAsk, target: String?,
                                 placement: ControlAskPlacement, follow: Bool) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            if let remote = presentAskRemotely(ask, in: session, placement: placement) { return remote }
            let identity: UUID?
            let pane: OverlayPane?
            switch resolveControlPanePlacement(placement.pane, paneID: placement.paneID, in: session,
                                               requireVisible: true, invalidPaneError: "ask pane must be left or right") {
            case .resolved(let resolvedIdentity, let resolvedPane):
                identity = resolvedIdentity
                pane = resolvedPane
            case .rejected(let response): return response
            }
            guard session.openAsk(ask, paneIdentity: identity) else { return err("ask already pending") }
            AskRegistry.shared.register(id: ask.id, owner: .session(id, window: windowID))
            syncAskSurfaces()
            if follow { gtk_window_present(WIN(windowPointer)) }
            return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: pane?.rawValue))
        }
    }

    private func presentAskRemotely(_ ask: PendingAsk, in session: Session,
                                    placement: ControlAskPlacement) -> ControlResponse? {
        guard store.presentationHub?.hasPresenter(session: session.id) == true else { return nil }
        switch resolveControlPanePlacement(placement.pane, paneID: placement.paneID, in: session,
                                           requireVisible: false, invalidPaneError: "ask pane must be left or right") {
        case .resolved(let identity, let pane):
            guard let opened = store.presentAskRemotely(ask, in: session, paneIdentity: identity,
                                                       window: windowID) else { return nil }
            guard opened else { return err("ask already pending") }
            return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: pane?.rawValue))
        case .rejected(let response): return response
        }
    }

    func askResult(_ target: String, window: String?) -> ControlResponse {
        guard let retained = AskRegistry.shared.result(for: target),
              askResultWindowMatches(retained.windowID, window: window) else {
            return err("unknown ask: \(target)")
        }
        return ControlResponse(ok: true, result: ControlResult(ask: retained.result))
    }

    func cancelAsk(_ target: String, window: String?) -> ControlResponse {
        guard let retained = AskRegistry.shared.result(for: target),
              askResultWindowMatches(retained.windowID, window: window) else {
            return err("unknown ask: \(target)")
        }
        guard retained.result.result == .pending else { return ControlResponse(ok: true) }
        switch AskRegistry.shared.owner(for: target) {
        case .window(let id):
            let controller = gWindows[id]
            controller?.pickController.cancelAsk()
            controller?.dismissGUIAsk()
        case .session(let sessionID, let id):
            let controller = gWindows[id]
            controller?.store.session(withID: sessionID)?.cancelAsk(id: target)
            controller?.syncAskSurfaces()
        case nil: return err("unknown ask: \(target)")
        }
        return ControlResponse(ok: true)
    }

    private func askResultWindowMatches(_ id: UUID, window: String?) -> Bool {
        guard let window else { return true }
        if case .resolved(let resolved) = library.resolveWindow(window) { return resolved == id }
        return false
    }
}
