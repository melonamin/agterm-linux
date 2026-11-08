import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func openResolvedPageOverlay(_ id: UUID, page: HtmlSource, options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        let overlay = HtmlOverlay(source: page, navigation: options.navigation,
                                  javascript: options.javascript, chromeless: options.chromeless,
                                  persistent: options.persistent, browse: options.browse,
                                  clicked: options.clicked, textLog: options.textLog)
        switch store.openRemotePage(id, overlay: overlay, options: options) {
        case .opened:
            if page.kind != .url { gControlServer.schedulePageClaimExpiry(after: AppStore.pageClaimWindow) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, pageID: overlay.id.uuidString))
        case .slotTaken: return err(options.pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen)
        case .paneMissing: return err(PaneOverlayError.paneNotVisible)
        case .unsupported: return err(OverlayHtmlError.presenter)
        case .loopback: return err(OverlayHtmlError.remoteLoopback)
        case .tooLarge: return err(OverlayHtmlError.remoteTooLarge)
        case .pointsUnsupported: return err(OverlayPointError.remote)
        case .local: break
        }
        if store.session(withID: id)?.remoteOverlays.slot(options.pane) != nil {
            return err(options.pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen)
        }
        if options.persistent, let error = LinuxBrowserStore.shared.failure() { return err("session.overlay.open: \(error)") }
        if let failure = store.openHtmlOverlay(id, pane: options.pane, overlay: overlay, sizePercent: options.sizePercent,
                                               points: options.points, backgroundColor: options.backgroundColor) {
            return err(failure.message(pane: options.pane))
        }
        _ = LinuxHtmlOverlayRegistry.shared.page(for: overlay, controller: self, backgroundColor: options.backgroundColor)
        if options.follow { selectSession(id, userInitiated: false) }
        reconcile()
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, pageID: overlay.id.uuidString))
    }

    func openProbedImage(_ id: UUID, path: String, probe: ImageProbe,
                         options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        guard store.session(withID: id)?.overlayHidden(options.pane) != true else { return err(OverlayVisibilityError.hidden) }
        let pixels = probe.natural(scale: 1)
        guard options.pane == nil, options.sizePercent == nil, options.points.isEmpty, !store.pageBelongsRemote(id, pane: options.pane) else {
            return openResolvedPageOverlay(id, page: .image(path: path), options: options.with(imagePixels: ImagePixels(width: Int(pixels.width), height: Int(pixels.height))))
        }
        if let session = store.session(withID: id) { cacheOverlayBounds(session) }
        let scale = Double(max(1, gtk_widget_get_scale_factor(W(windowPointer))))
        let points = ImagePage.points(natural: probe.natural(scale: scale), zoom: linuxSettingsStore().load().effectiveHtmlOverlayZoom,
                                      bounds: store.session(withID: id)?.hudPaneFrames.detail)
        let sized = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: ImagePage.basePercent,
                                                     backgroundColor: options.backgroundColor, follow: options.follow,
                                                     page: .image(path: path), points: points, clicked: options.clicked)
        return openResolvedPageOverlay(id, page: .image(path: path), options: sized)
    }

    func openClickedFile(_ url: URL, session id: UUID, markdown: Bool, sizePercent: Int? = nil) -> Bool {
        guard canShowFileLink(id) else { return false }
        let path = url.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = markdown ? nil : try? ImageProbe.load(path: path).get().0
            let checked = markdown ? (try? MarkdownProbe.check(path: path).get()) != nil : image != nil
            runOnMain {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard checked, self.canShowFileLink(id) else { return GhosttyApp.openTerminalURL(url.absoluteString) }
                    self.store.releaseHiddenClickedPage(id)
                    let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false,
                                                                   sizePercent: sizePercent, backgroundColor: nil,
                                                                   page: markdown ? .markdown(path: path) : .image(path: path), clicked: true)
                    let response = image.map { self.openProbedImage(id, path: path, probe: $0, options: options) }
                        ?? self.openResolvedPageOverlay(id, page: .markdown(path: path), options: options)
                    if !response.ok { GhosttyApp.openTerminalURL(url.absoluteString) }
                }
            }
        }
        return true
    }

    func openClickedPage(_ source: HtmlSource, session id: UUID, sizePercent: Int?, log: TextLog? = nil) -> Bool {
        guard canShowFileLink(id) else { return false }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checked: Bool
            switch source {
            case .text(let path, _): checked = (try? (log.map { TextProbe.checkLog(path: path, tail: $0.tail) } ?? TextProbe.check(path: path)).get()) != nil
            case .document(let path): checked = (try? DocumentProbe.load(path: path).get()) != nil
            default: checked = false
            }
            runOnMain { MainActor.assumeIsolated {
                guard let self else { return }
                let path = source.textPath ?? source.linuxDocumentPath ?? ""
                guard checked, self.canShowFileLink(id) else { return GhosttyApp.openTerminalURL(URL(fileURLWithPath: path).absoluteString) }
                self.store.releaseHiddenClickedPage(id)
                let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: sizePercent,
                                                               backgroundColor: nil, page: source, clicked: true, textLog: log)
                if !self.openResolvedPageOverlay(id, page: source, options: options).ok {
                    GhosttyApp.openTerminalURL(URL(fileURLWithPath: path).absoluteString)
                }
            } }
        }
        return true
    }

    private func canShowFileLink(_ id: UUID) -> Bool {
        guard let session = store.session(withID: id) else { return false }
        return session.content == .terminal && session.remoteHost == nil && !session.hudActive
            && (!session.overlayActive || (session.overlayHidden && session.htmlOverlay?.clicked == true)) && terminalZoom.target == nil
    }
}
