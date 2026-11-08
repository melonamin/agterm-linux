import CGtk
import Foundation
import agtermCore

struct LinuxReplicaPageRecord {
    let session: UUID
    let origin: UUID
    let channel: LinuxPageChannel?
    var appliedSeq = 0
}

@MainActor
extension AppController {
    func showReplicaPage(_ page: PresentationPage, forSession id: UUID) -> String? {
        guard let session = store.session(withID: id) else { return "no such session" }
        var page = page
        var command: [String]?
        if case .url = page.source {
            if page.persistent, let failure = LinuxBrowserStore.shared.failure() { return failure }
        } else {
            guard let host = session.remoteHost,
                  let argv = try? RemoteSession.pageServeCommand(host: host, token: page.token) else {
                return "the origin cannot be reached for this page"
            }
            command = argv
        }
        if case .image(_, let width, let height) = page.source, page.pane == nil, page.sizePercent == nil, page.points.isEmpty {
            cacheOverlayBounds(session)
            let scale = Double(max(1, gtk_widget_get_scale_factor(W(windowPointer))))
            let natural = ImagePage.natural(pixelWidth: width, pixelHeight: height, orientation: 1, scale: scale)
            let points = ImagePage.points(natural: natural, zoom: linuxSettingsStore().load().effectiveHtmlOverlayZoom,
                                          bounds: session.hudPaneFrames.detail)
            (page.sizePercent, page.width, page.height) = (ImagePage.basePercent, points.width, points.height)
        }
        if let reason = store.presentReplicaPage(page, forSession: id) { return reason }
        guard let slot = store.replicaPage(page.page, forSession: id), let origin = slot.page.replicaOf else { return "page not shown" }
        let channel = command.map { _ in LinuxPageChannel() }
        let local = slot.page.id
        replicaPages[local] = LinuxReplicaPageRecord(session: id, origin: origin, channel: channel)
        _ = LinuxHtmlOverlayRegistry.shared.page(for: slot.page, controller: self, backgroundColor: page.backgroundColor)
        if let channel, let command {
            channel.onClose = { [weak self] in
                guard let self else { return }
                _ = self.store.closeHtmlOverlay(local)
                self.reconcile(focusActive: false)
            }
            channel.start(command)
        }
        reconcile(focusActive: page.follow)
        return nil
    }

    func replicaPageReleased(_ local: UUID, origin: UUID) {
        guard let record = replicaPages.removeValue(forKey: local) else { return }
        remoteClients[record.session]?.answer(.pageClosed(PresentationPageChange(page: origin.uuidString)))
        record.channel?.onClose = nil
        record.channel?.close()
    }

    func applyReplicaPageCommand(_ command: PresentationPageCommand, forSession id: UUID) {
        guard let slot = store.replicaPage(command.page, forSession: id) else { return }
        let registry = LinuxHtmlOverlayRegistry.shared
        switch command.action {
        case .hide, .show: store.setReplicaPageHidden(command.page, forSession: id, hidden: command.action == .hide)
        case .reloadOriginal: _ = registry.reload(sessionID: id, pane: slot.pane, current: false, store: store)
        case .reloadCurrent: _ = registry.reload(sessionID: id, pane: slot.pane, current: true, store: store)
        case .back: _ = registry.navigate(sessionID: id, pane: slot.pane, step: .back, store: store)
        case .forward: _ = registry.navigate(sessionID: id, pane: slot.pane, step: .forward, store: store)
        case .browser: _ = registry.navigate(sessionID: id, pane: slot.pane, step: .browser, store: store)
        case .resize:
            store.resizeReplicaPage(command.page, forSession: id, sizePercent: command.sizePercent, points: command.points)
        }
        if var record = replicaPages[slot.page.id] {
            record.appliedSeq = max(record.appliedSeq, command.seq)
            replicaPages[slot.page.id] = record
        }
        reconcile(focusActive: false)
        replicaPageChanged(slot.page.id)
    }

    func replicaPageChanged(_ local: UUID) {
        guard replicaPages[local] != nil, replicaPageFlushCancel == nil else { return }
        replicaPageFlushCancel = MainTimer.schedule(after: 0) { [weak self] in
            guard let self, gWindows[self.windowID] === self else { return }
            self.replicaPageFlushCancel = nil
            for (local, record) in self.replicaPages {
                guard let state = self.store.replicaPageState(local, appliedSeq: record.appliedSeq) else { continue }
                self.remoteClients[record.session]?.answer(.pageState(state))
            }
        }
    }
}
