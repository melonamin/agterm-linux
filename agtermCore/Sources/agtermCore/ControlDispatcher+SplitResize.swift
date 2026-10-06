import Foundation

@MainActor
extension ControlDispatcher {
    func dispatchSessionResize(_ request: ControlRequest) -> ControlResponse {
        switch (request.args?.ratio, request.args?.ratioDelta, request.args?.pane) {
        case (nil, nil, _):
            return ControlResponse(ok: false, error: "session.resize requires --split-ratio, --grow-left, or --grow-right")
        case (.some, .some, _):
            return ControlResponse(ok: false, error: "session.resize: --split-ratio is mutually exclusive with --grow-left/--grow-right")
        case (.some, nil, .some):
            return ControlResponse(ok: false, error: "session.resize: --split-ratio does not accept a pane selector")
        case (.some(let ratio), nil, nil):
            return actions.resizeSplit(request.target, window: request.args?.window, resize: .ratio(ratio))
        case (nil, .some(let delta), nil):
            return actions.resizeSplit(request.target, window: request.args?.window, resize: .delta(delta))
        case (nil, .some(let delta), .some(let pane)):
            guard let target = ControlSplitResizeTarget.parse(pane) else {
                return ControlResponse(
                    ok: false,
                    error: "invalid resize pane: \(pane) (primary|split|left|right|top|bottom)"
                )
            }
            return actions.resizeSplit(
                request.target,
                window: request.args?.window,
                resize: .paneDelta(target, delta)
            )
        }
    }
}
