import Foundation
import agtermCore

enum LinuxTextActionParse {
    case action(OverlayPane?, TextPageAction)
    case refused(ControlResponse)
}

@MainActor
extension LinuxControlDispatcher {
    func parseTextAction(_ request: ControlRequest) -> LinuxTextActionParse {
        let pane: OverlayPane?
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return .refused(response)
        case .pane(let value): pane = value
        }
        func reject(_ message: String) -> LinuxTextActionParse { .refused(ControlResponse(ok: false, error: message)) }
        switch request.cmd {
        case .sessionOverlayFollow, .sessionOverlayWrap, .sessionOverlayExpand:
            let name = request.cmd == .sessionOverlayFollow ? "follow" : request.cmd == .sessionOverlayWrap ? "wrap" : "expand"
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return reject("invalid overlay \(name) mode: \(request.args?.mode ?? "toggle")")
            }
            return .action(pane, name == "follow" ? .follow(mode) : name == "wrap" ? .wrap(mode) : .expand(mode))
        case .sessionOverlayFiles:
            guard let file = request.args?.to, !file.isEmpty else { return reject("session.overlay.files requires to, a file number or path") }
            return .action(pane, .files(file))
        case .sessionOverlayChanges:
            guard let direction = request.args?.to else { return reject("session.overlay.changes requires to next or prev") }
            guard ["next", "prev"].contains(direction) else { return reject("invalid overlay changes direction: \(direction)") }
            return .action(pane, .changes(forward: direction == "next"))
        default:
            switch (request.args?.text, request.args?.to) {
            case (nil, nil): return reject(OverlayHtmlError.searchRequest)
            case (.some, .some): return reject(OverlayHtmlError.searchTextWithStep)
            case (let text?, nil):
                guard !text.isEmpty else { return reject("session.overlay.search: text must not be empty") }
                return .action(pane, .search(.query(text)))
            case (nil, let to?):
                switch to {
                case "next": return .action(pane, .search(.next))
                case "prev": return .action(pane, .search(.previous))
                case "close": return .action(pane, .search(.close))
                default: return reject("invalid overlay search direction: \(to)")
                }
            }
        }
    }
}

@MainActor
extension AppController {
    func runTextAction(_ action: TextPageAction, session: String?, pane: OverlayPane?) -> ControlResponse {
        switch action {
        case .follow(let mode): setSessionOverlayFollow(session, window: nil, pane: pane, mode: mode)
        case .wrap(let mode): toggleTextLayout(session, pane: pane, mode: mode, expand: false)
        case .expand(let mode): toggleTextLayout(session, pane: pane, mode: mode, expand: true)
        case .search(let request): searchTextPage(session, pane: pane, request: request)
        case .changes(let forward): stepTextChanges(session, pane: pane, forward: forward)
        case .files(let file): goTextFile(session, pane: pane, to: file)
        }
    }
}

extension ControlServer {
    func performRemoteTextRequest(_ request: ControlRequest) -> ControlResponse? {
        guard [.sessionOverlayFollow, .sessionOverlayWrap, .sessionOverlayExpand, .sessionOverlaySearch,
               .sessionOverlayChanges, .sessionOverlayFiles].contains(request.cmd) else { return nil }
        let box = LinuxRemoteTextResponse(), done = DispatchSemaphore(value: 0)
        runOnMain {
            MainActor.assumeIsolated {
                guard case .controller(let controller?) = Self.route(for: request) else { done.signal(); return }
                switch controller.resolveSessionResponse(request.target) {
                case .failure(let response): box.value = response; done.signal()
                case .success(let id):
                    switch LinuxControlDispatcher(actions: controller).parseTextAction(request) {
                    case .refused(let response): box.value = response; done.signal()
                    case .action(let pane, let action):
                        controller.store.remoteTextAction(id, pane: pane, action) { outcome in
                            box.value = outcome.response(session: id)
                            done.signal()
                        }
                    }
                }
            }
        }
        done.wait()
        return box.value
    }
}

private final class LinuxRemoteTextResponse: @unchecked Sendable {
    var value: ControlResponse?
}
