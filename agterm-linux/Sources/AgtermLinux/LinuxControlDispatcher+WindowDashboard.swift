import Foundation
import agtermCore

@MainActor
extension LinuxControlDispatcher {
    func dispatchWindowCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .windowGo:
            guard let direction = request.args?.to.flatMap(WorkspaceNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "window.go requires --to next|prev")
            }
            return actions.windowGo(direction: direction)
        case .windowRename:
            guard let name = request.args?.name?.linuxTrimmedOrNil else {
                return ControlResponse(ok: false, error: "window.rename requires a name")
            }
            return actions.windowRename(request.target, name: name)
        case .windowResize:
            guard let width = request.args?.width, let height = request.args?.height,
                  width > 0, height > 0 else {
                return ControlResponse(ok: false, error: "window.resize requires positive width and height")
            }
            return actions.windowResize(request.target, width: width, height: height)
        case .windowMove:
            guard let x = request.args?.x, let y = request.args?.y else {
                return ControlResponse(ok: false, error: "window.move requires x and y")
            }
            return actions.windowMove(request.target, x: x, y: y, display: request.args?.display)
        case .windowZoom:
            return actions.windowZoom(request.target)
        case .windowFullscreen:
            return actions.windowFullscreen(request.target)
        case .windowMinimize:
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false,
                                       error: "invalid minimize mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.windowMinimizeSync(request.target, mode: mode)
        default:
            preconditionFailure("unexpected window command: \(request.cmd.rawValue)")
        }
    }

    func dispatchDashboard(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let targets = args?.targets ?? []
        let fontSize = args?.fontSize
        let autoSize = args?.autoSize ?? false
        let mru = args?.mru ?? false
        if args?.close == true {
            guard targets.isEmpty, !mru, fontSize == nil, !autoSize else {
                return ControlResponse(ok: false,
                                       error: "dashboard --close takes no ids, --mru, or font options")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: true,
                                        fontMode: .untouched, mru: false)
        }
        if fontSize != nil, autoSize {
            return ControlResponse(ok: false,
                                   error: "dashboard: --font-size is mutually exclusive with --auto-size")
        }
        if let fontSize, !fontSize.isFinite || fontSize <= 0 {
            return ControlResponse(ok: false, error: "dashboard --font-size must be a positive number")
        }
        let mode: DashboardFontMode = autoSize ? .auto : (fontSize.map(DashboardFontMode.fixed) ?? .untouched)
        if mru {
            guard targets.isEmpty else {
                return ControlResponse(ok: false,
                                       error: "dashboard --mru cannot be combined with explicit session ids")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: false,
                                        fontMode: mode, mru: true)
        }
        guard !targets.isEmpty else {
            return ControlResponse(ok: false, error: "dashboard requires at least one session id")
        }
        if let malformed = targets.first(where: { DashboardTarget(rawValue: $0) == nil }) {
            return ControlResponse(
                ok: false,
                error: "dashboard: invalid session id '\(malformed)' — use <id>, <id>:left, or <id>:right")
        }
        return actions.setDashboard(targets: targets, window: args?.window, close: false,
                                    fontMode: mode, mru: false)
    }
}
