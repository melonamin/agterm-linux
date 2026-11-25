import Foundation
import agtermCore

@MainActor
extension AppController {
    func toggleTextLayout(_ target: String?, pane: OverlayPane?, mode: ControlToggleMode, expand: Bool) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if expand {
                switch store.setTextExpand(id, pane: pane, mode: mode) {
                case .failure(let failure): return err(failure.message)
                case .success(let value):
                    reconcile(focusActive: false)
                    return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: value ? "expanded" : "collapsed"))
                }
            }
            switch store.setTextWrap(id, pane: pane, mode: mode) {
            case .failure(let failure): return err(failure.message)
            case .success(let value):
                reconcile(focusActive: false)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: value ? "wrapped" : "unwrapped"))
            }
        }
    }

    func goTextFile(_ target: String?, pane: OverlayPane?, to file: String) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            let page: HtmlOverlay
            switch store.textChangesPage(id, pane: pane) {
            case .failure(let failure): return err(failure.message)
            case .success(let value): page = value
            }
            guard let bridge = LinuxHtmlOverlayRegistry.shared.existing(page.id)?.textPage,
                  let report = bridge.goFile(file), let current = report["current"] as? Int,
                  let count = report["count"] as? Int, let path = report["path"] as? String else {
                return err(TextChangesFailure.noFile(file).message)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: "\(current) of \(count): \(path)"))
        }
    }

    func setSessionOverlayWrap(_ target: String?, window: String?, pane: OverlayPane?, mode: ControlToggleMode) async -> ControlResponse {
        toggleTextLayout(target, pane: pane, mode: mode, expand: false)
    }

    func setSessionOverlayExpand(_ target: String?, window: String?, pane: OverlayPane?, mode: ControlToggleMode) async -> ControlResponse {
        toggleTextLayout(target, pane: pane, mode: mode, expand: true)
    }

    func goSessionOverlayFiles(_ target: String?, window: String?, pane: OverlayPane?, to: String) async -> ControlResponse {
        goTextFile(target, pane: pane, to: to)
    }
}
