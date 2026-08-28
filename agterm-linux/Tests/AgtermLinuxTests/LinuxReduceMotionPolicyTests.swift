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

    @Test("composed app CSS gates only the decorative pulse")
    func appCSSGatesPulse() {
        let reduced = appCSS(prefersReducedMotion: true)
        let normal = appCSS(prefersReducedMotion: false)

        #expect(reduced.contains(".agterm-blink { animation: none; }"))
        #expect(!reduced.contains("animation: agterm-blink-pulse 1.2s"))
        #expect(normal.contains("animation: agterm-blink-pulse 1.2s"))
        #expect(normal.contains("@keyframes agterm-blink-pulse"))
    }
}
