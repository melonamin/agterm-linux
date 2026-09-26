import Testing
@testable import AgtermLinux

@Suite("Linux structured journal records")
struct LinuxStructuredLoggerTests {
    @Test("a notice record carries the journal filter fields")
    func noticeRecordCarriesJournalFields() {
        #expect(
            LinuxStructuredLogger.noticeRecord(
                category: "ControlServer",
                message: "control socket at /run/user/1000/agterm/agterm.sock"
            ) == LinuxStructuredLogger.Record(
                message: "control socket at /run/user/1000/agterm/agterm.sock",
                priority: "5",
                domain: "ControlServer",
                identifier: "agterm"
            )
        )
    }

    @Test("control diagnostic text survives verbatim", arguments: FailureTextFixtures.all)
    func messagesSurviveVerbatim(message: String) {
        let record = LinuxStructuredLogger.noticeRecord(category: "ControlServer", message: message)
        #expect(record.message == message)
        #expect(record.priority == "5")
        #expect(record.domain == "ControlServer")
        #expect(record.identifier == "agterm")
    }
}

private enum FailureTextFixtures {
    static let all: [String] = [
        "control socket at /run/user/1000/agterm/agterm.sock",
        "control socket path too long (\(tooLongPath.utf8.count) bytes): \(tooLongPath)",
        "control socket() failed: Operation not permitted",
        "control bind(/run/user/1000/agterm/agterm.sock) failed: Address already in use",
        "control chmod(/run/user/1000/agterm/agterm.sock, 0600) failed: Permission denied",
        "control listen() failed: Protocol not supported",
        "control lock open(/run/user/1000/agterm/agterm.sock.lock) failed: Too many open files",
        "control socket /run/user/1000/agterm/agterm.sock is already served by another instance — not binding",
        "control socket at /tmp/agterm-Fräy—сокет/сеанс‑1.sock",
        "control socket at /tmp/ag\u{301}term/agterm.sock",
    ]

    private static let tooLongPath = "/run/user/1000/agterm/" + String(repeating: "сеанс/", count: 24) + "agterm.sock"
}
