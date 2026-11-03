import Testing
@testable import AgtermLinux

@Suite("Linux Reduce Motion policy")
struct LinuxReduceMotionPolicyTests {
    @Test("the dedicated GTK preference disables the status pulse")
    func interfacePreferenceDisablesPulse() {
        #expect(LinuxReduceMotionPolicy.prefersReducedMotion(
            interfaceReducedMotion: true, animationsEnabled: true))
    }

    @Test("the legacy GTK animation switch remains the fallback")
    func disabledAnimationsDisablePulse() {
        #expect(LinuxReduceMotionPolicy.prefersReducedMotion(
            interfaceReducedMotion: nil, animationsEnabled: false))
        #expect(LinuxReduceMotionPolicy.prefersReducedMotion(
            interfaceReducedMotion: false, animationsEnabled: false))
    }

    @Test("normal desktop preferences retain the requested pulse")
    func normalPreferencesRetainPulse() {
        #expect(!LinuxReduceMotionPolicy.prefersReducedMotion(
            interfaceReducedMotion: nil, animationsEnabled: true))
        #expect(!LinuxReduceMotionPolicy.prefersReducedMotion(
            interfaceReducedMotion: false, animationsEnabled: true))
    }

    @Test("the preference disarms the blink timer rather than a stylesheet")
    func reducedMotionDisarmsTheBlinkTimer() {
        let visible = [(marked: true, mapped: true)]

        #expect(LinuxBlinkPolicy.timerShouldRun(glyphs: visible, prefersReducedMotion: false))
        #expect(!LinuxBlinkPolicy.timerShouldRun(glyphs: visible, prefersReducedMotion: true))
    }
}
