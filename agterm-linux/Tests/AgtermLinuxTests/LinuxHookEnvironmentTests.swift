import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux hook environment")
struct LinuxHookEnvironmentTests {
    private func event() -> ControlEvent {
        ControlEvent(seq: 7, ts: 0, kind: .status, window: "window", workspace: "workspace",
                     session: "session", payload: ControlEventPayload(status: "busy", host: "box"))
    }

    @Test("hooks carry the event fields and use the custom-command PATH policy")
    func environmentPolicy() {
        let base = ["KEEP": "yes", "HOME": "/home/test", "PATH": "/custom/bin:/usr/bin"]
        let environment = LinuxHookEnvironment.make(event: event(), socket: "/tmp/agterm.sock",
                                                    baseEnvironment: base)

        #expect(environment["KEEP"] == "yes")
        #expect(environment["AGT_EVENT_KIND"] == "status")
        #expect(environment["AGT_EVENT_STATUS"] == "busy")
        #expect(environment["AGT_EVENT_HOST"] == "box")
        #expect(environment["AGT_SESSION_ID"] == "session")
        #expect(environment["AGT_WORKSPACE_ID"] == "workspace")
        #expect(environment["AGT_WINDOW_ID"] == "window")
        #expect(environment["AGT_SOCKET"] == "/tmp/agterm.sock")
        #expect(environment["PATH"] == LinuxCommandPath.widened(
            "/custom/bin:/usr/bin", bundledCLIDirectory: LinuxCommandPath.bundledCLIDirectory,
            homeDirectory: "/home/test"))
        #expect(environment["PATH"]?.contains("/home/test/.local/bin") == true)
    }

    /// Runs a real `/bin/sh -c` lookup, as the hook launcher does. The second arm is the previous shared
    /// macOS PATH, which does not include `~/.local/bin`, so it shows the check can fail.
    @Test("a hook finds a helper installed only in ~/.local/bin")
    func localBinLookup() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm hook path \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bin = (home as NSString).appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let helper = (bin as NSString).appendingPathComponent("agterm-hook-path-probe")
        try "#!/bin/sh\nexit 0\n".write(toFile: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)

        let base = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let environment = LinuxHookEnvironment.make(event: event(), socket: "/tmp/agterm.sock",
                                                    baseEnvironment: base)
        #expect(try run("agterm-hook-path-probe", environment: environment) == 0)

        var shared = environment
        shared["PATH"] = CommandPath.widened(base["PATH"], bundledCLIDirectory: nil)
        #expect(try run("agterm-hook-path-probe", environment: shared) == 127)
    }

    private func run(_ command: String, environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
