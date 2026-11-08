import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("blink policy")
struct LinuxBlinkPolicyTests {
    @Test("the dim phase fades the glyph and the other restores it to full opacity")
    func opacityPerPhase() {
        #expect(LinuxBlinkPolicy.opacity(phase: true) == LinuxBlinkPolicy.dimOpacity)
        #expect(LinuxBlinkPolicy.opacity(phase: false) == 1)
        #expect(LinuxBlinkPolicy.dimOpacity < 1)
    }

    @Test("the marker names the class the writer adds and both readers look for")
    func markerClassIsPinned() {
        #expect(LinuxBlinkPolicy.markerClass == "agterm-blink")
    }

    @Test("only a glyph that renders something can be marked as blinking")
    func markingNeedsAPresentation() {
        let active = LinuxStatusGlyphPresentation(indicator: AgentIndicator(status: .active),
                                                  settings: AppSettings())
        #expect(active != nil)
        #expect(LinuxBlinkPolicy.shouldMark(presentation: active, blink: true))
        #expect(!LinuxBlinkPolicy.shouldMark(presentation: active, blink: false))
        #expect(!LinuxBlinkPolicy.shouldMark(presentation: nil, blink: true))
    }

    @Test("the timer runs only for a glyph that is both marked and mapped")
    func visiblyBlinking() {
        #expect(!LinuxBlinkPolicy.anyVisiblyBlinking([]))
        #expect(!LinuxBlinkPolicy.anyVisiblyBlinking([(marked: true, mapped: false),
                                                      (marked: false, mapped: true)]))
        #expect(LinuxBlinkPolicy.anyVisiblyBlinking([(marked: false, mapped: true),
                                                     (marked: true, mapped: true)]))
    }
}
