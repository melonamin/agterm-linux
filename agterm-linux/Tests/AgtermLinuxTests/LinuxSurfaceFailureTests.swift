import Testing
@testable import AgtermLinux

@Suite("Linux surface failure diagnostics")
struct LinuxSurfaceFailureTests {
    @Test("failure injection is gated, role-specific, and distinguishes GL from creation")
    func failureInjection() {
        let active = [
            "AGTERM_ATSPI_SCENARIO": "surface-failures",
            LinuxSurfaceFailureInjection.environmentKey: "creation:quick",
        ]
        #expect(LinuxSurfaceFailureInjection.failure(for: .quick, environment: active) == .creation)
        #expect(LinuxSurfaceFailureInjection.failure(for: .main, environment: active) == nil)
        #expect(LinuxSurfaceFailureInjection.failure(
            for: .quick,
            environment: [LinuxSurfaceFailureInjection.environmentKey: "creation:quick"]
        ) == nil)

        let glContext = [
            "AGTERM_ATSPI_SCENARIO": "surface-failures",
            LinuxSurfaceFailureInjection.environmentKey: "gl-context:split",
        ]
        #expect(LinuxSurfaceFailureInjection.failure(for: .split, environment: glContext) == .glContext)
        #expect(LinuxSurfaceFailureInjection.failure(for: .quick, environment: glContext) == nil)
    }

    @Test("only a proven GL context failure is display-wide")
    func presentationScope() {
        let glContext = LinuxSurfaceFailurePresentation.resolve(.glContext, role: .main)
        #expect(glContext.scope == .displayWide)
        #expect(glContext.message.contains("No GL context"))

        let quick = LinuxSurfaceFailurePresentation.resolve(.creation, role: .quick)
        let scratch = LinuxSurfaceFailurePresentation.resolve(.creation, role: .scratch)
        #expect(quick.scope == .surfaceLocal)
        #expect(quick.message.hasPrefix("Quick terminal failed to start."))
        #expect(scratch.scope == .surfaceLocal)
        #expect(scratch.message.hasPrefix("Scratch terminal failed to start."))
        #expect(quick.message != scratch.message)
        #expect(!quick.message.contains("OpenGL older"))
    }
}
