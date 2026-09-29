import Foundation

/// The in-progress status glyph's pulse, as a two-state opacity toggle instead of a CSS keyframe: GTK's
/// style root keeps a tick callback alive while any animation runs, so one mapped blinking glyph forced a
/// whole-toplevel frame every vblank.
enum LinuxBlinkPolicy {
    /// Half of the pulse period: the phase flips on every tick, so the glyph completes a cycle in 1.2 s.
    static let halfPeriod: TimeInterval = 0.6
    static let dimOpacity = 0.25
    /// No stylesheet rule backs this class: it is the pulse's only carrier, read back off the widget by
    /// the timer. Writer and both readers name it from here so neither can drift.
    static let markerClass = "agterm-blink"

    /// Only labels carrying the marker are written, so a non-blinking glyph needs no phase.
    static func opacity(phase: Bool) -> Double {
        phase ? dimOpacity : 1
    }

    /// An idle indicator renders no glyph at all, so it never blinks however the indicator asks.
    static func shouldMark(presentation: LinuxStatusGlyphPresentation?, blink: Bool) -> Bool {
        presentation != nil && blink
    }

    /// An unmapped glyph cannot be seen, so a timer running for one is pure main-thread wakeups. An empty
    /// collection — every tracked map cleared by a window close — is the disarm case.
    static func anyVisiblyBlinking(_ glyphs: [(marked: Bool, mapped: Bool)]) -> Bool {
        glyphs.contains { $0.marked && $0.mapped }
    }

    /// The whole arming decision. The pulse is decorative, so a desktop reduced-motion request disarms the
    /// timer outright rather than freezing it mid-phase — see `LinuxReduceMotionPolicy`.
    static func timerShouldRun(
        glyphs: [(marked: Bool, mapped: Bool)], prefersReducedMotion: Bool
    ) -> Bool {
        anyVisiblyBlinking(glyphs) && !prefersReducedMotion
    }
}
