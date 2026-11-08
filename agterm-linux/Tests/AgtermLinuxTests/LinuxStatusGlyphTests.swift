import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux agent-status glyph presentation")
struct LinuxStatusGlyphTests {
    @Test("idle has no presentation")
    func idleIsHidden() {
        #expect(LinuxStatusGlyphPresentation(
            indicator: AgentIndicator(), settings: AppSettings()) == nil)
    }

    @Test("per-call shape and color override settings")
    func perCallOverridesSettings() throws {
        var settings = AppSettings()
        settings.activeStatusShape = StatusShape.square.rawValue
        settings.activeStatusColorHex = "#112233"
        let presentation = try #require(LinuxStatusGlyphPresentation(
            indicator: AgentIndicator(
                status: .active, color: "#ABCDEF", shape: .star
            ),
            settings: settings
        ))
        #expect(presentation.glyph == "★")
        #expect(presentation.colorHex == "#ABCDEF")
        #expect(presentation.tooltip == "Agent status: Active")
    }

    @Test("settings shape is used before the circle default")
    func settingsShapeAndDefault() throws {
        var settings = AppSettings()
        settings.blockedStatusShape = StatusShape.triangle.rawValue
        let configured = try #require(LinuxStatusGlyphPresentation(
            indicator: AgentIndicator(status: .blocked), settings: settings))
        let fallback = try #require(LinuxStatusGlyphPresentation(
            indicator: AgentIndicator(status: .completed), settings: AppSettings()))
        #expect(configured.glyph == "▲")
        #expect(fallback.glyph == "●")
    }
}
