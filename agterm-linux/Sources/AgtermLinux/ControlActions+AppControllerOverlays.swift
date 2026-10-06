import Foundation
import agtermCore

@MainActor
extension AppController {
    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let page = options.page {
                if store.session(withID: id)?.remoteOverlays.slot(options.pane) != nil {
                    return err(options.pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen)
                }
                if options.persistent, let error = LinuxBrowserStore.shared.failure() {
                    return err("session.overlay.open: \(error)")
                }
                let overlay = HtmlOverlay(source: page, navigation: options.navigation,
                                          javascript: options.javascript, chromeless: options.chromeless, persistent: options.persistent)
                if let failure = store.openHtmlOverlay(id, pane: options.pane, overlay: overlay,
                                                       sizePercent: options.sizePercent,
                                                       backgroundColor: options.backgroundColor) {
                    return err(failure.message(pane: options.pane))
                }
                _ = LinuxHtmlOverlayRegistry.shared.page(for: overlay, controller: self, backgroundColor: options.backgroundColor)
                if options.follow { selectSession(id, userInitiated: false) }
                reconcile()
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, pageID: overlay.id.uuidString))
            }
            if let remote = gControlServer.openRemoteOverlay(in: store, sessionID: id, options: options) {
                return remote
            }
            if let pane = options.pane {
                switch store.openPaneOverlay(id, pane: pane, command: options.command, cwd: options.cwd,
                                             wait: options.wait, backgroundColor: options.backgroundColor) {
                case nil:
                    if options.follow { selectSession(id, userInitiated: false) }
                    reconcile()
                    return ok(id)
                case .unknownSession: return err("no such session")
                case .alreadyOpen: return err(PaneOverlayError.alreadyOpen)
                case .paneNotVisible: return err(PaneOverlayError.paneNotVisible)
                }
            }
            guard store.openOverlay(id, command: options.command, cwd: options.cwd, wait: options.wait,
                                    sizePercent: options.sizePercent,
                                    backgroundColor: options.backgroundColor) else {
                return err("overlay already open")
            }
            if options.follow { selectSession(id, userInitiated: false) }
            reconcile()
            return ok(id)
        }
    }

    func reloadSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, current: Bool) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let failure = LinuxHtmlOverlayRegistry.shared.reload(sessionID: id, pane: pane,
                                                                    current: current, store: store) {
                return err(failure.message)
            }
            return ok(id)
        }
    }

    func navigateSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?,
                                navigation: HtmlNavigation) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let failure = LinuxHtmlOverlayRegistry.shared.navigate(sessionID: id, pane: pane,
                                                                      step: navigation, store: store) {
                return err(failure)
            }
            return ok(id)
        }
    }

    func closeSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            let hud = pane == nil && store.session(withID: id)?.hudActive == true
            let closed = store.closeRemoteOverlay(id, pane: pane)
                || (pane.map { store.closePaneOverlay(id, pane: $0) } ?? store.closeOverlay(id))
            guard closed else { return err("no overlay") }
            reconcile(focusActive: !hud)
            return ok(id)
        }
    }

    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            if let resized = store.resizeRemoteOverlay(id, sizePercent: sizePercent) {
                return resized ? ok(id) : err(OverlayResultError.viewerGone)
            }
            let hud = session.hudActive
            if hud, sizePercent == nil { return err(OverlayHudError.fullResize) }
            let previousSize = session.overlaySizePercent
            guard store.resizeOverlay(id, sizePercent: sizePercent) else { return err("no overlay") }
            if hud, !writeHudBody(session, pane: hudPaneMetrics(for: session)) {
                store.resizeOverlay(id, sizePercent: previousSize)
                return err(OverlayHudError.writeFailed)
            }
            reconcile(focusActive: !hud)
            return ok(id)
        }
    }

    func sessionOverlayResult(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            if session.htmlCovers(pane) { return err(OverlayHtmlError.noResult) }
            if let pane {
                if let slot = session.remoteOverlays.slot(pane), !slot.ended {
                    return err(OverlayResultError.stillRunning)
                }
                if session.paneOverlay(pane) != nil { return err(OverlayResultError.stillRunning) }
                if session.paneOverlayExitCode(pane) == nil, let failure = session.remoteOverlays.failure(pane) {
                    return err(OverlayResultError.ended(failure))
                }
                guard let code = session.paneOverlayExitCode(pane) else { return err(OverlayResultError.noResult) }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
            }
            if session.hudActive { return err(OverlayHudError.noResult) }
            if let slot = session.remoteOverlays.slot(nil), !slot.ended {
                return err(OverlayResultError.stillRunning)
            }
            if session.overlayActive { return err(OverlayResultError.stillRunning) }
            if session.overlayExitCode == nil, let failure = session.remoteOverlays.failure(nil) {
                return err(OverlayResultError.ended(failure))
            }
            guard let code = session.overlayExitCode else { return err(OverlayResultError.noResult) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
        }
    }

    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse {
        if let watermark = options.watermark, watermark.kind == .image {
            guard let path = watermark.imagePath, WatermarkRenderer.isSupportedImage(path) else {
                return err("unsupported image (PNG or JPEG only): \(watermark.imagePath ?? "")")
            }
            guard FileManager.default.fileExists(atPath: path) else { return err("no such image file: \(path)") }
        }
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            if options.pane == .right, !session.hasSplit { return err("session has no split pane") }
            if options.pane == .scratch, session.scratchSurface == nil {
                return err("session has no scratch terminal")
            }
            guard store.setBackgroundWatermark(options.watermark, forSession: id, pane: options.pane) else {
                return ok(id)
            }
            applySessionWatermark(id, pane: options.pane)
            return ok(id)
        }
    }
}
