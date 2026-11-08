import Testing
import agtermCore
@testable import LinuxIntegrations

@Suite("Linux integration managed markers")
struct IntegrationManagedMarkersTests {
    private let scriptDir = "/home/test/.config/agterm/agent-status"

    @Test("complete shell block is installed")
    func completeShellBlock() {
        let installed = AgentHooksInstall.appendShellRC(existing: "", scriptDir: scriptDir)
        #expect(IntegrationManagedMarkers.shellRCState(
            existing: installed.contents,
            scriptDir: scriptDir
        ) == .installed)
    }

    @Test("incomplete shell marker is malformed")
    func incompleteShellMarker() {
        #expect(IntegrationManagedMarkers.shellRCState(
            existing: "\(AgentHooksInstall.rcMarkerBegin)\n",
            scriptDir: scriptDir
        ) == .malformed)
    }

    @Test("Codex wrapper must be inside the managed block")
    func codexWrapperOutsideMarkers() {
        let expectedWrapper = AgentHooksInstall.shellQuote(
            scriptDir + "/" + AgentHooksInstall.codexWrapperName)
        let existing = """
        note = \(expectedWrapper)
        \(AgentHooksInstall.rcMarkerBegin)
        model = "gpt-5"
        \(AgentHooksInstall.rcMarkerEnd)
        """

        #expect(AgentHooksInstall.mergeCodexConfig(
            existing: existing,
            scriptDir: scriptDir
        ) == .unchanged)
        #expect(!IntegrationManagedMarkers.codexBlockIsCurrent(
            existing: existing,
            scriptDir: scriptDir
        ))
    }
}
