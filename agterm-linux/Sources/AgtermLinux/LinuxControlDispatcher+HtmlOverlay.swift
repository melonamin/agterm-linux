import Foundation
import agtermCore

@MainActor
extension LinuxControlDispatcher {
    func dispatchHtmlOverlayCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionOverlayOpen:
            if request.args?.chromeless == true {
                guard request.args?.html != nil else { return ControlResponse(ok: false, error: OverlayHtmlError.chromelessRequiresFile) }
                if request.args?.navigation == true { return ControlResponse(ok: false, error: OverlayHtmlError.chromelessWithNavigation) }
            }
            if request.args?.persistent == true, request.args?.url == nil {
                return ControlResponse(ok: false, error: OverlayHtmlError.persistentRequiresURL)
            }
            let command = request.args?.command ?? ""
            let page: HtmlSource?
            switch (request.args?.html, request.args?.url) {
            case (nil, nil):
                if request.args?.navigation == true {
                    return ControlResponse(ok: false, error: OverlayHtmlError.navigationWithoutPage)
                }
                if request.args?.javascript == true {
                    return ControlResponse(ok: false, error: OverlayHtmlError.javascriptWithoutPage)
                }
                guard !command.isEmpty else {
                    return ControlResponse(ok: false, error: "session.overlay.open requires a command")
                }
                page = nil
            case (.some, .some):
                return ControlResponse(ok: false, error: OverlayHtmlError.htmlAndURL)
            case (.some(let html), nil):
                if !command.isEmpty { return ControlResponse(ok: false, error: OverlayHtmlError.commandAndHtml) }
                if request.args?.wait == true { return ControlResponse(ok: false, error: OverlayHtmlError.waitWithHtml) }
                if let error = HtmlOverlay.grantError(file: html, grantRoot: request.args?.cwd) {
                    return ControlResponse(ok: false, error: "session.overlay.open: \(error)")
                }
                page = .file(path: html, grantRoot: request.args?.cwd)
            case (nil, .some(let text)):
                if !command.isEmpty { return ControlResponse(ok: false, error: OverlayHtmlError.commandAndURL) }
                if request.args?.wait == true { return ControlResponse(ok: false, error: OverlayHtmlError.waitWithURL) }
                if request.args?.cwd != nil { return ControlResponse(ok: false, error: OverlayHtmlError.cwdWithURL) }
                guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      let host = url.host, !host.isEmpty else {
                    return ControlResponse(ok: false, error: OverlayHtmlError.invalidURL)
                }
                page = .url(url)
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            let pane: OverlayPane?
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let parsed): pane = parsed
            }
            if pane != nil, request.args?.sizePercent != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict)
            }
            if let percent = request.args?.sizePercent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.open: --size-percent must be 1...100")
            }
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: page == nil ? request.args?.cwd : nil,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color,
                                                follow: request.args?.follow ?? false,
                                                pane: pane,
                                                page: page,
                                                navigation: request.args?.navigation ?? false,
                                                javascript: request.args?.javascript ?? false,
                                                chromeless: request.args?.chromeless ?? false,
                                                persistent: request.args?.persistent ?? false
                                              ))
        case .sessionOverlayReload:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.reloadSessionOverlay(request.target, window: request.args?.window,
                                                    pane: pane, current: request.args?.current ?? false)
            }
        case .sessionOverlayNavigate:
            guard let step = request.args?.to.flatMap(HtmlNavigation.init(rawValue:)) else {
                return ControlResponse(ok: false, error: OverlayHtmlError.navigation)
            }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.navigateSessionOverlay(request.target, window: request.args?.window,
                                                      pane: pane, navigation: step)
            }
        default:
            preconditionFailure("unexpected HTML overlay command: \(request.cmd.rawValue)")
        }
    }
}
