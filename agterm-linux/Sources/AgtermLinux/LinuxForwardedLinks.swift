import Foundation
import agtermCore

@MainActor
extension AppController {
    func receiveForwardedLink(_ click: PresentationLinkClick, session id: UUID, sender: Int) {
        let hub = gControlServer.presentationHub
        let refuse: @MainActor (RemoteLinkRefusal) -> Void = {
            hub.send(.linkRefused(PresentationLinkRefusal(reason: $0, click: click.click)), toOwner: sender)
        }
        guard let target = store.forwardedClickPane(id, pane: click.pane) else { return refuse(.paneNotAttached) }
        let origin = LinkPolicy.ClickOrigin.pane(id)
        let candidates = LinkPolicy.locations(for: click.raw, origin: origin, cwd: target.cwd)
        let selectors = hub.snapshotSelectors(click, from: sender)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let route = LinkPolicy.resolvedRoute(for: click.raw, candidates: candidates, mode: click.mode, origin: origin,
                                                exists: { FileManager.default.fileExists(atPath: $0) })
            let source: HtmlSource?
            let percent: Int?
            switch route {
            case .image(let url, _): (source, percent) = (.image(path: url.path), nil)
            case .markdown(let url, _, let size): (source, percent) = (.markdown(path: url.path), size)
            case .text(let text): (source, percent) = (.text(path: text.url.path, line: text.line), text.sizePercent)
            case .document(let url, _, let size): (source, percent) = (.document(path: url.path), size)
            default: (source, percent) = (nil, nil)
            }
            let exists = route.localFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let snapshot = exists ? SnapshotCandidate.find(route, selectors: selectors) : nil
            runOnMain { MainActor.assumeIsolated {
                guard let self, hub.isConnected(owner: sender) else { return }
                if let snapshot, let clickID = click.click, self.store.session(withID: id) != nil {
                    return hub.offerSnapshot(snapshot, click: clickID, book: gControlServer.snapshotBook, to: sender)
                }
                if click.snapshotOnly == true { return refuse(.hidden) }
                guard let source else { return refuse(.notAPage) }
                guard exists else { return refuse(.notFound) }
                let links = source.markdownPath.flatMap { MarkdownPage.linkGrant(for: $0) }
                let log: TextLog?
                if case .text(let text) = route, text.opensAsLog, self.supportsTextLog(id, pane: nil, forwardedTo: sender) {
                    log = TextLog(tail: TextPage.defaultTail, follow: true)
                } else { log = nil }
                let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: percent,
                    backgroundColor: nil, page: source, navigation: links != nil, clicked: true,
                    textLog: log, forwardedTo: sender, markdownLinks: links)
                if !self.openSessionOverlay(id.uuidString, window: nil, options: options).ok { refuse(.notOpened) }
            } }
        }
    }
}
