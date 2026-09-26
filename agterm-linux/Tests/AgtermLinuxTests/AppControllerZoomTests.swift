import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux terminal zoom promotion")
struct AppControllerZoomTests {
    @Test("split and right overlay zoom targets follow primary-pane promotion")
    @MainActor
    func promotionTargets() {
        let sessionID = UUID()
        #expect(AppController.zoomTargetToRehostAfterPrimaryPanePromotion(
            .session(sessionID, .split), sessionID: sessionID) == .session(sessionID, .primary))
        #expect(AppController.zoomTargetToRehostAfterPrimaryPanePromotion(
            .session(sessionID, .overlayRight), sessionID: sessionID) == .session(sessionID, .overlayLeft))
        #expect(AppController.zoomTargetToRehostAfterPrimaryPanePromotion(
            .session(sessionID, .primary), sessionID: sessionID) == .session(sessionID, .primary))
        #expect(AppController.zoomTargetToRehostAfterPrimaryPanePromotion(
            .session(sessionID, .overlayLeft), sessionID: sessionID) == .session(sessionID, .overlayLeft))
        #expect(AppController.zoomTargetToRehostAfterPrimaryPanePromotion(
            .session(sessionID, .scratch), sessionID: sessionID) == nil)
        #expect(AppController.zoomTargetToRehostAfterPrimaryPanePromotion(
            .session(UUID(), .split), sessionID: sessionID) == nil)
    }

    @Test("pane covers keep a base surface visible while terminal zoom hosts it")
    @MainActor
    func paneCoverWhileZoomed() {
        let sessionID = UUID()
        #expect(!AppController.paneBaseIsCovered(
            overlayOpen: true, zoomTarget: .session(sessionID, .primary), dashboardOpen: false,
            sessionID: sessionID, pane: .left))
        #expect(!AppController.paneBaseIsCovered(
            overlayOpen: true, zoomTarget: .session(sessionID, .split), dashboardOpen: false,
            sessionID: sessionID, pane: .right))
        #expect(AppController.paneBaseIsCovered(
            overlayOpen: true, zoomTarget: nil, dashboardOpen: false, sessionID: sessionID, pane: .left))
        #expect(!AppController.paneBaseIsCovered(
            overlayOpen: false, zoomTarget: nil, dashboardOpen: false, sessionID: sessionID, pane: .left))
        #expect(!AppController.paneBaseIsCovered(
            overlayOpen: true, zoomTarget: nil, dashboardOpen: true, sessionID: sessionID, pane: .left))
    }

    @Test("pane overlay zoom restores the wash above the reattached terminal")
    @MainActor
    func paneOverlayStackTarget() throws {
        let sessionID = UUID()
        let left = try #require(AppController.paneOverlayTarget(.session(sessionID, .overlayLeft)))
        #expect(left.0 == sessionID)
        #expect(left.1 == .left)
        let right = try #require(AppController.paneOverlayTarget(.session(sessionID, .overlayRight)))
        #expect(right.1 == .right)
        #expect(AppController.paneOverlayTarget(.session(sessionID, .primary)) == nil)
    }
}
