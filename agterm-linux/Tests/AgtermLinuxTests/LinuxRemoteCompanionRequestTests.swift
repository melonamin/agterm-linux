import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Remote companion arguments")
struct LinuxRemoteCompanionRequestTests {
    @Test("empty values remain separate arguments and dash values stay joined")
    func emptyAndDashValues() {
        let request = LinuxRemoteCompanionRequest.terminal(CompanionOptions(
            cwd: "", command: "--program argument", name: "--child", wait: true))
        #expect(request.arguments(originSession: "origin") == [
            "session", "new", "--parent", "origin", "--no-select", "--cwd", "",
            "--command=--program argument", "--wait", "--name=--child",
        ])
    }

    @Test("absent values inherit the origin defaults")
    func absentValues() {
        #expect(LinuxRemoteCompanionRequest.terminal(CompanionOptions()).arguments(originSession: "origin") == [
            "session", "new", "--parent", "origin", "--no-select",
        ])
    }
}
