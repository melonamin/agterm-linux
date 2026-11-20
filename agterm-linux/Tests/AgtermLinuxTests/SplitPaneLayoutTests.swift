import Testing
@testable import AgtermLinux

@Suite("Linux split-pane layout")
struct SplitPaneLayoutTests {
    @Test("both panes stay hosted through every visibility state")
    func stableSlots() {
        let cases = [
            (isSplit: true, splitFocused: false, primaryVisible: true, splitVisible: true),
            (isSplit: true, splitFocused: true, primaryVisible: true, splitVisible: true),
            (isSplit: false, splitFocused: false, primaryVisible: true, splitVisible: false),
            (isSplit: false, splitFocused: true, primaryVisible: false, splitVisible: true),
        ]

        for item in cases {
            let layout = SplitPaneLayout(isSplit: item.isSplit, splitFocused: item.splitFocused)

            #expect(layout.primaryVisible == item.primaryVisible)
            #expect(layout.splitVisible == item.splitVisible)
        }
    }

    @Test("inactive-pane opacity is shared by its base and overlay")
    @MainActor
    func paneOpacity() {
        let left = AppController.paneSurfaceOpacities(
            isSplit: true, splitFocused: true, dimmed: 0.55, backdropActive: false)
        #expect(left.left == 0.55)
        #expect(left.right == 1)

        let right = AppController.paneSurfaceOpacities(
            isSplit: true, splitFocused: false, dimmed: 0.55, backdropActive: false)
        #expect(right.left == 1)
        #expect(right.right == 0.55)

        let single = AppController.paneSurfaceOpacities(
            isSplit: false, splitFocused: true, dimmed: 0.55, backdropActive: false)
        #expect(single.left == 1)
        #expect(single.right == 1)

        let backdrop = AppController.paneSurfaceOpacities(
            isSplit: true, splitFocused: true, dimmed: 0.55, backdropActive: true)
        #expect(backdrop.left == 1)
        #expect(backdrop.right == 1)
        #expect(AppController.paneOverlayWashOpacity(
            isSplit: true, splitFocused: true, pane: .left,
            scaledMuteOpacity: 0.45, backdropActive: false) == 0.45)
        #expect(AppController.paneOverlayWashOpacity(
            isSplit: true, splitFocused: true, pane: .left,
            scaledMuteOpacity: AppController.scaledMuteOpacity(0.45, renderedWindowOpacity: 0.6),
            backdropActive: false) == 0.27)
        #expect(AppController.paneOverlayWashOpacity(
            isSplit: true, splitFocused: true, pane: .left,
            scaledMuteOpacity: 0.45, backdropActive: true) == 0)
        #expect(AppController.paneOverlayWashColor(
            fixedBackground: "#123456", themeBackground: "#abcdef") == "#123456")
        #expect(AppController.paneOverlayWashColor(
            fixedBackground: nil, themeBackground: "#abcdef") == "#abcdef")
    }

    @Test("hidden split does not retain a live divider hit target")
    @MainActor
    func hiddenDivider() {
        #expect(AppController.splitDividerHit(x: 500, dividerPosition: 500, splitVisible: true))
        #expect(!AppController.splitDividerHit(x: 500, dividerPosition: 500, splitVisible: false))
        #expect(!AppController.splitDividerHit(x: 489, dividerPosition: 500, splitVisible: true))
    }
}
