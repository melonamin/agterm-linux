import CGtk
import CWebKit
import Foundation
import agtermCore

@MainActor
extension LinuxHtmlOverlayPage {
    func focusTextSearch() {
        guard overlay.source.kind == .text, !closed else { return }
        webkit_web_view_evaluate_javascript(cast(webView), "agtermTextFocusSearch()", -1, "agterm-text", nil, nil, nil, nil)
    }

    func installTextRenderer() {
        guard overlay.source.kind == .text else { return }
        addBridgeScript(MarkdownAssets.shared.textScript, world: "agterm-text", atEnd: true)
        guard overlay.source.textPath != nil else { return }
        textPage = LinuxTextPage(page: self)
        _ = webkit_user_content_manager_register_script_message_handler(manager, "agtermTextPage", "agterm-text")
        connect(manager, "script-message-received::agtermTextPage", unsafeBitCast(onTextPageReport, to: GCallback.self),
                Unmanaged.passUnretained(self).toOpaque())
    }
}

private let onTextPageReport: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, value, data in
    guard let data else { return }
    Unmanaged<LinuxHtmlOverlayPage>.fromOpaque(data).takeUnretainedValue().textPage?.receive(value)
}

@MainActor
extension AppController {
    func setSessionOverlayFollow(_ target: String?, window: String?, pane: OverlayPane?, mode: ControlToggleMode) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            switch store.setTextLogFollowing(id, pane: pane, mode: mode) {
            case .failure(let failure): return err(failure.message)
            case .success(let value):
                reconcile(focusActive: false)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: value ? "following" : "paused"))
            }
        }
    }

    func searchSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, request: TextSearchRequest) async -> ControlResponse {
        searchTextPage(target, pane: pane, request: request)
    }

    func searchTextPage(_ target: String?, pane: OverlayPane?, request: TextSearchRequest) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            let page: HtmlOverlay
            switch store.textSearchPage(id, pane: pane) {
            case .failure(let failure): return err(failure.message)
            case .success(let value): page = value
            }
            let forward: Bool
            switch request {
            case .query(let text): store.setTextSearch(page.id, query: text); reconcile(focusActive: false); return ok(id)
            case .close: store.setTextSearch(page.id, query: ""); reconcile(focusActive: false); return ok(id)
            case .next: forward = true
            case .previous: forward = false
            }
            guard page.textSearch?.query.isEmpty == false else { return err(TextSearchFailure.noQuery.message) }
            guard let text = LinuxHtmlOverlayRegistry.shared.existing(page.id)?.textPage,
                  let found = text.step(forward: forward), let count = found["matches"] as? Int, let current = found["current"] as? Int else {
                return err(TextSearchFailure.notLoaded.message)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: "\(current) of \(count)"))
        }
    }

    func stepSessionOverlayChanges(_ target: String?, window: String?, pane: OverlayPane?, forward: Bool) async -> ControlResponse {
        stepTextChanges(target, pane: pane, forward: forward)
    }

    func stepTextChanges(_ target: String?, pane: OverlayPane?, forward: Bool) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            let page: HtmlOverlay
            switch store.textChangesPage(id, pane: pane) {
            case .failure(let failure): return err(failure.message)
            case .success(let value): page = value
            }
            guard let text = LinuxHtmlOverlayRegistry.shared.existing(page.id)?.textPage,
                  let found = text.step(forward: forward, changes: true), let count = found["count"] as? Int,
                  let current = found["current"] as? Int else { return err(TextChangesFailure.notLoaded.message) }
            guard count > 0 else { return err(TextChangesFailure.noChanges.message) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: "\(current) of \(count)"))
        }
    }
}

@MainActor
extension LinuxControlDispatcher {
    func dispatchTextPage(_ request: ControlRequest) -> ControlResponse {
        let pane: OverlayPane?
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return response
        case .pane(let value): pane = value
        }
        if request.cmd == .sessionOverlayChanges {
            guard let direction = request.args?.to, ["next", "prev"].contains(direction) else {
                return actions.err(request.args?.to.map { "invalid overlay changes direction: \($0)" }
                    ?? "session.overlay.changes requires to next or prev")
            }
            return actions.stepTextChanges(request.target, pane: pane, forward: direction == "next")
        }
        let search: TextSearchRequest
        switch (request.args?.text, request.args?.to) {
        case (nil, nil): return actions.err(OverlayHtmlError.searchRequest)
        case (.some, .some): return actions.err(OverlayHtmlError.searchTextWithStep)
        case (let text?, nil):
            guard !text.isEmpty else { return actions.err("session.overlay.search: text must not be empty") }
            search = .query(text)
        case (nil, let to?):
            switch to {
            case "next": search = .next
            case "prev": search = .previous
            case "close": search = .close
            default: return actions.err("invalid overlay search direction: \(to)")
            }
        }
        return actions.searchTextPage(request.target, pane: pane, request: search)
    }
}

extension HtmlSource {
    var linuxDocumentPath: String? {
        if case .document(let path) = self { return path }
        return nil
    }
}
