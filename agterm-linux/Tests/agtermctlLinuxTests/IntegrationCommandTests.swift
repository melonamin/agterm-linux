import ArgumentParser
import Foundation
import Testing
@testable import agtermctlLinux

@Suite("agtermctl integration command")
struct IntegrationCommandTests {
    @Test("status accepts the control socket compatibility option")
    func statusParsing() throws {
        let command = try AgtermctlLinux.parseAsRoot([
            "integration", "status", "--json", "--socket", "/tmp/ignored.sock",
        ])
        let status = try #require(command as? Integration.Status)
        #expect(status.socket == "/tmp/ignored.sock")
    }

    @Test("install supports hooks dry-run")
    func hooksDryRunParsing() throws {
        let command = try AgtermctlLinux.parseAsRoot([
            "integration", "install", "hooks", "--dry-run", "--socket", "/tmp/ignored.sock",
        ])
        let install = try #require(command as? Integration.Install)
        #expect(install.integration == "hooks")
        #expect(install.dryRun)
        #expect(install.socket == "/tmp/ignored.sock")
    }

    @Test("install rejects unknown integration")
    func invalidIntegration() throws {
        #expect(throws: Error.self) {
            _ = try AgtermctlLinux.parseAsRoot(["integration", "install", "unknown"])
        }
    }

    @Test("status JSON is stable and independent of the control socket")
    func statusJSONProcess() throws {
        let fixture = try CLIFixture()
        let result = try fixture.run(["integration", "status", "--json"])
        #expect(result.status == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items.count == 6)
        #expect(items.compactMap { $0["kind"] as? String } == [
            "cli", "claude-hooks", "codex-hooks", "pi-hooks", "opencode-plugin", "agent-skill",
        ])
        #expect(!result.output.contains("socket"))

        let text = try fixture.run(["integration", "status"])
        #expect(text.status == 0)
        #expect(text.output.contains("Pi Extension: Unavailable"))
    }

    @Test("dry-run JSON previews without mutating HOME")
    func dryRunProcess() throws {
        let fixture = try CLIFixture()
        let result = try fixture.run(["integration", "install", "skill", "--dry-run", "--json"])
        #expect(result.status == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "skill")
        #expect(object["canApply"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".claude").path))
    }

    @Test("conflicts, invalid resources, and failed writes have distinct exits")
    func processExitStatuses() throws {
        let conflict = try CLIFixture()
        let skill = conflict.home.appendingPathComponent(".codex/skills/agterm/SKILL.md")
        try conflict.write("unrelated", to: skill)
        let conflictResult = try conflict.run([
            "integration", "install", "skill", "--dry-run", "--json",
        ])
        #expect(conflictResult.status == 2)

        let invalid = try CLIFixture(copyResources: false)
        let invalidResult = try invalid.run(["integration", "install", "skill", "--dry-run"])
        #expect(invalidResult.status == 1)

        let failed = try CLIFixture()
        let homeFile = failed.root.appendingPathComponent("home-file")
        try failed.write("not a directory", to: homeFile)
        let failedResult = try failed.run(["integration", "install", "skill"], home: homeFile)
        #expect(failedResult.status == 4)
    }

    @Test("install applies safe skill targets and reports protected targets")
    func partialConflictProcess() throws {
        let fixture = try CLIFixture()
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let protected = fixture.home.appendingPathComponent(".codex/skills/agterm/SKILL.md")
        try fixture.write("user authored", to: protected)

        let result = try fixture.run(["integration", "install", "skill", "--json"])

        #expect(result.status == 2)
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(result.output.utf8)) as? [String: Any])
        #expect((object["conflicts"] as? [String])?.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(
            ".claude/skills/agterm/SKILL.md").path))
        #expect(try String(contentsOf: protected, encoding: .utf8) == "user authored")
    }

    @Test("hooks CLI installs Pi into isolated HOME")
    func piHooksProcess() throws {
        let fixture = try CLIFixture()
        let piAgent = fixture.home.appendingPathComponent(".pi/agent", isDirectory: true)
        try FileManager.default.createDirectory(at: piAgent, withIntermediateDirectories: true)

        let result = try fixture.run(["integration", "install", "hooks", "--json"])

        #expect(result.status == 0)
        let extensionURL = piAgent.appendingPathComponent("extensions/agterm-status.ts")
        let extensionContents = try String(contentsOf: extensionURL, encoding: .utf8)
        #expect(extensionContents.contains("// agterm-pi-status-extension"))
        #expect(!FileManager.default.fileExists(atPath: extensionURL.path + ".bak"))
    }
}

private final class CLIFixture {
    struct Result {
        let status: Int32
        let output: String
        let error: String
    }

    let root: URL
    let home: URL
    let resources: URL

    init(copyResources: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                             isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if copyResources {
            let root = packageRoot.deletingLastPathComponent()
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("agterm/Resources/agent-status"),
                to: resources.appendingPathComponent("agent-status"))
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("plugins/agterm/skills/agterm"),
                to: resources.appendingPathComponent("agent-skill"))
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func run(_ arguments: [String], home selectedHome: URL? = nil) throws -> Result {
        let process = Process()
        process.executableURL = testProductsDirectory.appendingPathComponent("agtermctl-linux")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = (selectedHome ?? home).path
        environment["PATH"] = ""
        environment["AGTERM_RESOURCE_ROOT"] = resources.path
        environment["AGTERM_STATE_DIR"] = root.appendingPathComponent("state").path
        environment["AGTERM_SOCKET"] = root.appendingPathComponent("missing.sock").path
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                      error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var testProductsDirectory: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    }
}
