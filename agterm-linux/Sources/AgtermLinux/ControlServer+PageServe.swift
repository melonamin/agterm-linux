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
                if written { self.adoptPageServeStream(descriptor: descriptor, page: page, token: token) } else { self.pageClaimUnanswered(page, token: token) }
                ready.signal()
            }
        }
        ready.wait()
        return written
    }

    func shutdownPageStreams() {
        snapshotBook.shutdown()
        for stream in pageServeStreams.values { stream.shutdown() }
        for stream in companionPageStreams.values { stream.shutdown() }
        pendingPageClaims.removeAll()
        pendingCompanionClaims.removeAll()
        companionPageTokens.removeAll()
    }
    static let pageServeResourceLimit = 8
    static let pageServeBridgeLimit = 8

    var openPageStores: [AppStore] { gLibrary.openIDs().compactMap { gLibrary.store(for: $0) } }

    func claimPageServe(_ token: String) -> ControlResponse { claimPageStream(token) }

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
                      let owner = slot.owner, presentationHub.isConnected(owner: owner) else { continue }
                return (session.id, slot.pane, gLibrary.windowID(for: store))
            }
        }
        return nil
    }

    /// receiveRemotePageFrame hands what a presenter reported about a page to its store, logging why a page was
    /// refused, since the open was already answered ok and the reason surfaces nowhere else.
    func receiveRemotePageFrame(_ body: PresentationFrame.Body, in store: AppStore, forSession sessionID: UUID, from sender: Int) {
        if case .pageRejected(let change) = body {
            pageLogger.notice("presenter refused page \(change.page): \(change.reason ?? "no reason")")
        }
        store.receiveRemotePageFrame(body, forSession: sessionID, from: sender)
    }

    /// schedulePageClaimExpiry ends every file page whose channel was not claimed in time, once `seconds` passed.
    func schedulePageClaimExpiry(after seconds: TimeInterval) {
        MainTimer.schedule(after: seconds + 0.1) { [weak self] in
            guard let self else { return }
            for store in openPageStores { store.expireRemotePageClaims() }
        }
    }
}
