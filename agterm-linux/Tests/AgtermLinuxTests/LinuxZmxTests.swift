import Foundation
import Testing
@testable import AgtermLinux

@Suite("Linux zmx adapters")
struct LinuxZmxTests {
    @Test("kill output requires an exact confirmation")
    func killOutcome() {
        #expect(LinuxZmxClient.outcome(
            of: "killed session agterm-deadbeef\n", name: "agterm-deadbeef"
        ) == .killed)
        #expect(LinuxZmxClient.outcome(
            of: "cleaned up stale session agterm-deadbeef\n", name: "agterm-deadbeef"
        ) == .staleSocket)
        #expect(LinuxZmxClient.outcome(
            of: "not killed session agterm-deadbeef\n", name: "agterm-deadbeef"
        ) == .failed("not killed session agterm-deadbeef"))
    }

    @Test("proc stat parsing tolerates parentheses in the process name")
    func procStatForegroundGroup() {
        let stat = "42 (zmx (pane)) S 1 42 42 34816 777 0 0 0"
        #expect(LinuxZmxForegroundResolver.terminalForegroundGroup(stat: stat) == 777)
        #expect(LinuxZmxForegroundResolver.terminalForegroundGroup(
            stat: "42 (zmx) S 1 42 42 34816 -1 0"
        ) == nil)
        #expect(LinuxZmxForegroundResolver.terminalForegroundGroup(stat: "malformed") == nil)
    }

    @Test("the development zmx path is absolute")
    func developmentPath() {
        #expect(LinuxZmxLaunch.executablePath(environment: [:]).hasPrefix("/"))
        #expect(LinuxZmxLaunch.executablePath(environment: ["AGTERM_ZMX_PATH": "/tmp/custom-zmx"])
            == "/tmp/custom-zmx")
    }
}
