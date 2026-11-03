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

    @Test("a zoom hides the sibling pane of the pane it targets and leaves session covers alone")
    @MainActor
    func zoomedPaneVisibility() throws {
        let primary = try #require(AppController.zoomedPaneVisibility(.primary))
        #expect(primary.primary && !primary.split)
        let overlayLeft = try #require(AppController.zoomedPaneVisibility(.overlayLeft))
        #expect(overlayLeft.primary && !overlayLeft.split)
        let split = try #require(AppController.zoomedPaneVisibility(.split))
        #expect(!split.primary && split.split)
        let overlayRight = try #require(AppController.zoomedPaneVisibility(.overlayRight))
        #expect(!overlayRight.primary && overlayRight.split)
        #expect(AppController.zoomedPaneVisibility(.scratch) == nil)
        #expect(AppController.zoomedPaneVisibility(.overlay) == nil)
    }

    @Test("a zoom shows the stack page that holds its surface, never moving the surface")
    @MainActor
    func zoomedStackPage() {
        for slot in [TerminalZoomSurface.primary, .split, .overlayLeft, .overlayRight] {
            #expect(AppController.zoomedStackPage(slot, floatingOverlay: false) == "main")
        }
        #expect(AppController.zoomedStackPage(.scratch, floatingOverlay: false) == "scratch")
        #expect(AppController.zoomedStackPage(.overlay, floatingOverlay: false) == "overlay")
        #expect(AppController.zoomedStackPage(.overlay, floatingOverlay: true) == nil)
    }

    @Test("floating overlays yield to pane zoom and return on exit or overlay zoom")
    @MainActor
    func floatingOverlayVisibility() {
        let sessionID = UUID()
        func visible(_ target: TerminalZoomTarget?) -> Bool {
            AppController.floatingOverlayVisible(
                sessionID: sessionID, activeID: sessionID, overlayActive: true, zoomTarget: target)
        }
        #expect(visible(nil))
        #expect(!visible(.session(sessionID, .primary)))
        #expect(!visible(.session(sessionID, .split)))
        #expect(!visible(.session(sessionID, .scratch)))
        #expect(!visible(.session(sessionID, .overlayLeft)))
        #expect(!visible(.quick))
        #expect(visible(.session(sessionID, .overlay)))
        #expect(!AppController.floatingOverlayVisible(
            sessionID: sessionID, activeID: UUID(), overlayActive: true, zoomTarget: nil))
        #expect(!AppController.floatingOverlayVisible(
            sessionID: sessionID, activeID: sessionID, overlayActive: false, zoomTarget: nil))
    }
}
