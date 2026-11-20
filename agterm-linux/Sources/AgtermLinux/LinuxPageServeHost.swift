import CGtk
import Foundation
import agtermCore

extension ControlServer: PageServeHost {
    @MainActor
    func claimRemotePage(token: String) -> (page: UUID, served: PageServeClaim)? {
        for store in openPageStores {
            guard let claim = store.claimRemotePage(token: token) else { continue }
            return (claim.overlay.id, PageServeClaim(source: claim.overlay.source, links: claim.overlay.markdownLinks,
                                                     log: claim.overlay.textLog))
        }
        return nil
    }

    @MainActor
    func dispatchPageBridge(_ request: ControlRequest) async -> ControlResponse? {
        await withCheckedContinuation { continuation in
            dispatchPageBridge(request) { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    func dispatchPageBridge(_ request: ControlRequest, completion: @escaping @MainActor (ControlResponse?) -> Void) {
        DispatchQueue.global().async {
            let response = self.performRequest(request)
            runOnMain { MainActor.assumeIsolated { completion(response) } }
        }
    }

    nonisolated static func pageMimeType(_ path: String) -> String {
        var uncertain: gboolean = 0
        guard let type = g_content_type_guess(path, nil, 0, &uncertain) else { return "application/octet-stream" }
        defer { g_free(type) }
        guard let mime = g_content_type_get_mime_type(type) else { return "application/octet-stream" }
        defer { g_free(mime) }
        return String(cString: mime)
    }

    @MainActor func reofferLostPage(_ page: UUID) -> Bool { openPageStores.contains { $0.remotePageLost(page) } }
    @MainActor func isCurrentPageClaim(_ page: UUID, token: String) -> Bool {
        openPageStores.lazy.compactMap { $0.remotePageClaimToken(page) }.first == token
    }
    @MainActor func isPageCandidateClaim(_ page: UUID, token: String) -> Bool {
        openPageStores.contains { $0.pageCandidateClaimed(page, token: token) }
    }
    @MainActor func commitPageCandidate(_ page: UUID, token: String) -> PageMove? {
        for store in openPageStores {
            if let move = store.commitPageCandidate(page, token: token) { return move }
        }
        return nil
    }
    @MainActor func finishPageMove(_ move: PageMove) { openPageStores.forEach { $0.finishPageMove(move) } }
    @MainActor func pageCandidateFailed(_ page: UUID, token: String) -> Bool {
        openPageStores.contains { $0.failPageCandidate(page, token: token) }
    }

    @MainActor func claimPageAttachment(_ token: String) -> ControlResponse? { claimCompanionPage(token) }
    @MainActor func adoptPageAttachment(descriptor: Int32, claim: UUID) -> Bool {
        guard let serving = pendingCompanionClaims.removeValue(forKey: claim) else { return false }
        adoptCompanionPageStream(descriptor: descriptor, serving: serving)
        return true
    }
    @MainActor func dropPageAttachmentClaim(_ claim: UUID) -> Bool { pendingCompanionClaims.removeValue(forKey: claim) != nil }
    @MainActor func pageAttachmentPlace(_ attachment: PageServeStream.Attachment, page: UUID) -> (session: UUID, pane: OverlayPane?, window: UUID?)? {
        companionPagePlace(CompanionPageServing(claim: attachment.claim, session: attachment.session, page: page))
    }
    @MainActor func pageAttachmentClosed(_ attachment: PageServeStream.Attachment) { companionPageStreams[attachment.claim] = nil }
}
