import Testing
import agtermCore
@testable import AgtermLinux

@Suite("background overlay policy")
struct LinuxBackgroundOverlayPolicyTests {
    private let sessionColor = BackgroundWatermark(kind: .color, colorHex: "#335577")

    private func overlay(latch: String?, fixed: String? = nil, session: BackgroundWatermark? = nil,
                         fontSize: Double? = nil, opacity: Double = 1) -> String {
        let watermark = LinuxBackgroundOverlayPolicy.watermark(
            oscLatch: latch, fixedBackground: fixed, sessionBackground: session)
        return LinuxBackgroundOverlayPolicy.overlayText(
            oscLatch: latch, watermark: watermark, resolvedImagePath: nil, fontSize: fontSize, windowOpacity: opacity)
    }

    private func keys(_ text: String) -> [String] {
        text.split(separator: "\n").map { String($0.split(separator: "=")[0]).trimmingCharacters(in: .whitespaces) }
    }

    @Test("a latched overlay never carries a background key")
    func latchedOverlayHasNoBackground() {
        let text = overlay(latch: "#AA0000", fixed: "#112233", session: sessionColor, fontSize: 15, opacity: 0.85)
        #expect(!keys(text).contains("background"))
    }

    @Test("a latched overlay keeps font size and window opacity")
    func latchedOverlayKeepsFontAndOpacity() {
        #expect(overlay(latch: "#AA0000", fontSize: 15, opacity: 0.85)
            == "background-opacity = 0.85\nfont-size = 15\n")
    }

    @Test("the latch wins over a session and a fixed color")
    func latchWinsOverSessionColor() {
        #expect(LinuxBackgroundOverlayPolicy.watermark(
            oscLatch: "#AA0000", fixedBackground: "#112233", sessionBackground: sessionColor) == nil)
        #expect(overlay(latch: "#AA0000", session: sessionColor) == overlay(latch: "#AA0000"))
    }

    @Test("a fixed color wins over the session watermark")
    func fixedColorWinsOverSession() {
        #expect(LinuxBackgroundOverlayPolicy.watermark(
            oscLatch: nil, fixedBackground: "#112233", sessionBackground: sessionColor)
            == BackgroundWatermark(kind: .color, colorHex: "#112233"))
    }

    @Test("without a latch a session color emits background")
    func sessionColorEmitsBackground() {
        #expect(overlay(latch: nil, session: sessionColor, opacity: 0.85)
            == "background = #335577\nbackground-opacity = 0.85\n")
    }

    @Test("a forced reapply with no latch and no watermark emits a bare overlay")
    func forcedBareOverlay() {
        #expect(LinuxBackgroundOverlayPolicy.shouldReapply(
            force: true, oscLatch: nil, watermark: nil, hasFontOverride: false))
        #expect(overlay(latch: nil).isEmpty)
        #expect(overlay(latch: nil, fontSize: 13) == "font-size = 13\n")
    }

    @Test("a set latch alone is a reason to reapply")
    func latchCountsInReapplyGuard() {
        #expect(LinuxBackgroundOverlayPolicy.shouldReapply(
            force: false, oscLatch: "#AA0000", watermark: nil, hasFontOverride: false))
        #expect(!LinuxBackgroundOverlayPolicy.shouldReapply(
            force: false, oscLatch: nil, watermark: nil, hasFontOverride: false))
        #expect(LinuxBackgroundOverlayPolicy.shouldReapply(
            force: false, oscLatch: nil, watermark: nil, hasFontOverride: true))
    }

    @Test("window opacity is clamped", arguments: [
        (-0.5, "0"), (1.5, "1"), (Double.nan, "1"), (Double.infinity, "1"), (0, "0"), (1, "1"),
    ])
    func opacityIsClamped(input: Double, expected: String) {
        #expect(overlay(latch: "#AA0000", opacity: input) == "background-opacity = \(expected)\n")
        #expect(overlay(latch: nil, session: sessionColor, opacity: input)
            == "background = #335577\nbackground-opacity = \(expected)\n")
    }
}
