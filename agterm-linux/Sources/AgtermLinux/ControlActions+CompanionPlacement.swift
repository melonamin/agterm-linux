import Foundation
import agtermCore

@MainActor
extension AppController {
    func convertToCompanion(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            switch store.convertToCompanion(id) {
            case .failure(let failure): return err(failure.message)
            case .success(let parent):
                reconcile()
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, parent: parent.id.uuidString))
            }
        }
    }

    func moveLinuxCompanion(_ target: String?, parent: String, index: Int?) -> ControlResponse {
        let id: UUID
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let value): id = value
        }
        switch resolveSessionResponse(parent) {
        case .failure(let response): return response
        case .success(let parentID):
            switch store.moveCompanion(id, under: parentID, at: index) {
            case .failure(let failure): return err(failure.message)
            case .success:
                reconcile(focusActive: false)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, parent: parentID.uuidString))
            }
        }
    }

    func createLinuxPageSession(_ target: String?, options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let source = options.page else { return err(OverlayHtmlError.pageSessionNeedsPage) }
            if options.persistent, let failure = LinuxBrowserStore.shared.failure() { return err(failure) }
            let overlay = HtmlOverlay(source: source, navigation: options.navigation, javascript: options.javascript,
                                      chromeless: options.chromeless, persistent: options.persistent, browse: options.browse)
            switch store.addPageSession(after: id, overlay: overlay, select: options.follow, backgroundColor: options.backgroundColor) {
            case .failure: return err("could not create page session")
            case .success(let row):
                _ = LinuxHtmlOverlayRegistry.shared.page(for: overlay, controller: self, backgroundColor: options.backgroundColor)
                reconcile(focusActive: options.follow)
                return ControlResponse(ok: true, result: ControlResult(id: row.id.uuidString, pageID: overlay.id.uuidString))
            }
        }
    }

    func moveCompanion(_ target: String?, parent: String, index: Int?, window: String?) async -> ControlResponse {
        moveLinuxCompanion(target, parent: parent, index: index)
    }

    func createPageSession(_ target: String?, window: String?, options: ControlSessionOverlayOpenOptions) async -> ControlResponse {
        createLinuxPageSession(target, options: options)
    }
}
