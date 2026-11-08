import Foundation
import agtermCore

private final class LinuxPageClaimBox: @unchecked Sendable {
    var response = ControlResponse(ok: false, error: "page not claimable")
}

@MainActor
extension ControlServer {
    nonisolated func handlePageServe(_ descriptor: Int32, request: ControlRequest) -> Bool {
        guard let token = request.target, !token.isEmpty else {
            _ = writeResponse(descriptor, ControlResponse(ok: false, error: "page-serve requires a token"))
            return false
        }
        let box = LinuxPageClaimBox(), ready = DispatchSemaphore(value: 0)
        runOnMain {
            MainActor.assumeIsolated { box.response = self.claimPageServe(token); ready.signal() }
        }
        ready.wait()
        let written = writeResponse(descriptor, box.response)
        guard box.response.ok, let page = box.response.result?.id.flatMap(UUID.init(uuidString:)) else { return false }
        runOnMain {
            MainActor.assumeIsolated {
                if written { self.adoptPageServeStream(descriptor: descriptor, page: page) } else { self.pageClaimUnanswered(page) }
                ready.signal()
            }
        }
        ready.wait()
        return written
    }

    func shutdownPageStreams() {
        for stream in pageServeStreams.values { stream.shutdown() }
        for stream in companionPageStreams.values { stream.shutdown() }
        pendingPageClaims.removeAll()
        pendingCompanionClaims.removeAll()
        companionPageTokens.removeAll()
    }
    static let pageServeResourceLimit = 8
    static let pageServeBridgeLimit = 8

    var openPageStores: [AppStore] { gLibrary.openIDs().compactMap { gLibrary.store(for: $0) } }

    /// claimPageServe answers `session.overlay.page.serve`: an ok answer is the token's one admitted claim, and the connection
    /// is then adopted as that page's channel.
    func claimPageServe(_ token: String) -> ControlResponse {
        if let companion = claimCompanionPage(token) { return companion }
        for store in openPageStores {
            guard let claim = store.claimRemotePage(token: token) else { continue }
            pendingPageClaims[claim.overlay.id] = claim.overlay.source
            return ControlResponse(ok: true, result: ControlResult(id: claim.overlay.id.uuidString))
        }
        return ControlResponse(ok: false, error: "page not claimable")
    }

    /// adoptPageServeStream takes over the connection of a page whose claim was just answered ok.
    func adoptPageServeStream(descriptor: Int32, page: UUID) {
        if let serving = pendingCompanionClaims.removeValue(forKey: page) {
            return adoptCompanionPageStream(descriptor: descriptor, serving: serving)
        }
        let owner = LinuxControlStreamOwner(descriptor: descriptor, maxPending: 8)
        // a page that ended between its claim and this adoption gets no channel
        guard let source = pendingPageClaims.removeValue(forKey: page), remotePagePlace(page) != nil else {
            owner.start(onLine: { _ in }, onClose: {})
            owner.shutdown()
            return
        }
        let stream = LinuxPageServeStream(page: page, source: source, owner: owner, server: self)
        pageServeStreams[page] = stream
        owner.start(
            onLine: { [weak stream] line in stream?.take(Data(line)) },
            onClose: { [weak stream] in
                runOnMain { MainActor.assumeIsolated { stream?.closed() } }
            }
        )
    }

    /// pageClaimUnanswered ends a page whose claim reply never reached the helper, which leaves nobody to load it.
    func pageClaimUnanswered(_ page: UUID) {
        // a page companion's attachment that never connected leaves the page and its other viewers alone
        if pendingCompanionClaims.removeValue(forKey: page) != nil { return }
        pendingPageClaims[page] = nil
        endRemotePage(page)
    }

    /// endRemotePage ends page `page` wherever its reservation sits, which also tells the presenter.
    func endRemotePage(_ page: UUID) {
        for store in openPageStores {
            for session in store.workspaces.flatMap(\.sessions) {
                guard let slot = session.remoteOverlays.slot(job: page.uuidString) else { continue }
                store.closeRemoteOverlay(session.id, pane: slot.pane)
                return
            }
        }
    }

    /// remotePagePlace finds where page `page` is reserved now, nil once it ended or its presenter changed: a swap
    /// moves the slot, and a new presenter generation means the page belongs to a stream that is gone.
    func remotePagePlace(_ page: UUID) -> (session: UUID, pane: OverlayPane?, window: UUID?)? {
        for store in openPageStores {
            for session in store.workspaces.flatMap(\.sessions) {
                guard let slot = session.remoteOverlays.slot(job: page.uuidString), slot.page != nil,
                      presentationHub.presenterGeneration(session: session.id) == slot.owner,
                      presentationHub.hasPresenter(session: session.id) else { continue }
                return (session.id, slot.pane, gLibrary.windowID(for: store))
            }
        }
        return nil
    }

    /// receiveRemotePageFrame hands what a presenter reported about a page to its store, logging why a page was
    /// refused, since the open was already answered ok and the reason surfaces nowhere else.
    func receiveRemotePageFrame(_ body: PresentationFrame.Body, in store: AppStore, forSession sessionID: UUID) {
        if case .pageRejected(let change) = body {
            pageLogger.notice("presenter refused page \(change.page): \(change.reason ?? "no reason")")
        }
        store.receiveRemotePageFrame(body, forSession: sessionID)
    }

    /// schedulePageClaimExpiry ends every file page whose channel was not claimed in time, once `seconds` passed.
    func schedulePageClaimExpiry(after seconds: TimeInterval) {
        MainTimer.schedule(after: seconds + 0.1) { [weak self] in
            guard let self else { return }
            for store in openPageStores { store.expireRemotePageClaims() }
        }
    }
}
