import Foundation
import Testing
import agtermCore
@testable import LinuxIntegrations

@Suite("Linux Pi integration")
struct PiIntegrationTests {
    @Test("Pi is unavailable until its agent directory exists")
    func absentPi() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()

        let status = fixture.service(path: []).status()[.piHooks]

        #expect(status?.state == .unavailable)
        #expect(status?.detail.contains("No ~/.pi/agent") == true)
    }

    @Test("Pi installs idempotently without a backup and becomes current")
    func installAndReinstall() throws {
        let fixture = try piFixture()
        let service = fixture.service(path: [])
        let destination = piDestination(fixture)
        #expect(service.status()[.piHooks]?.state == .notInstalled)

        let first = try service.apply(service.planHooks())

        #expect(first.succeeded)
        #expect(service.status()[.piHooks]?.state == .installed)
        #expect(service.status()[.piHooks]?.detail.contains("current") == true)
        #expect(try String(contentsOf: destination, encoding: .utf8)
            .contains(AgentHooksInstall.piExtensionMarker))
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".bak"))
        let reinstall = try service.planHooks()
        #expect(!reinstall.canApply)
    }

    @Test("a managed older Pi extension reports and applies an update")
    func updateManagedExtension() throws {
        let fixture = try piFixture()
        let service = fixture.service(path: [])
        #expect(try service.apply(service.planHooks()).succeeded)
        let destination = piDestination(fixture)
        try fixture.write(
            "\(AgentHooksInstall.piExtensionMarker)\n// old managed extension\n",
            to: destination
        )

        #expect(service.status()[.piHooks]?.state == .updateAvailable)
        let result = try service.apply(service.planHooks())

        #expect(result.succeeded)
        #expect(service.status()[.piHooks]?.state == .installed)
        #expect(try String(contentsOf: destination, encoding: .utf8).contains("export default"))
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".bak"))
    }

    @Test("a user-owned Pi extension is preserved while safe hooks install")
    func userOwnedConflict() throws {
        let fixture = try piFixture()
        let destination = piDestination(fixture)
        try fixture.write("// my extension\n", to: destination)
        let service = fixture.service(path: [])

        #expect(service.status()[.piHooks]?.state == .conflict)
        let plan = try service.planHooks()
        #expect(plan.canApply)
        #expect(plan.conflicts.contains { $0.contains("user-owned") })
        let result = try service.apply(plan)
        let allSafeOperationsSucceeded = result.results.allSatisfy { $0.success }

        #expect(!result.succeeded)
        #expect(allSafeOperationsSucceeded)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "// my extension\n")
        #expect(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(".claude/settings.json").path))
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".zshrc").path))
    }

    @Test("an unreadable Pi extension is reported and left untouched")
    func unreadableExtension() throws {
        let fixture = try piFixture()
        let destination = piDestination(fixture)
        try fixture.write("\(AgentHooksInstall.piExtensionMarker)\n", to: destination)
        try Data([0xC3, 0x28]).write(to: destination)
        let service = fixture.service(path: [])

        let status = service.status()[.piHooks]
        #expect(status?.state == .conflict)
        #expect(status?.detail.contains("could not be read") == true)
        let plan = try service.planHooks()
        #expect(plan.conflicts.contains { $0.contains("could not be read") })
    }

    @Test("source mutation after preflight rejects the whole stale plan")
    func sourceMutation() throws {
        let fixture = try piFixture()
        let service = fixture.service(path: [])
        let plan = try service.planHooks()
        let source = piSource(fixture)
        try fixture.write(
            "\(AgentHooksInstall.piExtensionMarker)\n// changed after preview\n",
            to: source
        )

        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(!FileManager.default.fileExists(atPath: piDestination(fixture).path))
    }

    @Test("destination mutation after preflight is preserved and rejects the stale plan")
    func destinationMutation() throws {
        let fixture = try piFixture()
        let service = fixture.service(path: [])
        let plan = try service.planHooks()
        let destination = piDestination(fixture)
        try fixture.write("// appeared after preview\n", to: destination)

        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "// appeared after preview\n")
    }

    @Test("retargeting a managed Pi symlink after preflight cannot redirect the write")
    func symlinkRetarget() throws {
        let fixture = try piFixture()
        let destination = piDestination(fixture)
        let first = fixture.root.appendingPathComponent("shared/first.ts")
        let second = fixture.root.appendingPathComponent("shared/second.ts")
        let old = "\(AgentHooksInstall.piExtensionMarker)\n// old\n"
        try fixture.write(old, to: first)
        try fixture.write(old, to: second)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: destination.path, withDestinationPath: first.path)
        let service = fixture.service(path: [])
        let plan = try service.planHooks()

        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(
            atPath: destination.path, withDestinationPath: second.path)

        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(try String(contentsOf: second, encoding: .utf8) == old)
    }

    @Test("a Pi write failure is reported after independently safe hook work")
    func writeFailureIsolation() throws {
        let fixture = try piFixture()
        let service = fixture.service(path: [])
        let plan = try service.planHooks()
        try fixture.write("blocks the extensions directory", to: fixture.home.appendingPathComponent(
            ".pi/agent/extensions"))

        let result = try service.apply(plan)

        let piResult = result.results.last { $0.path == piDestination(fixture).path }
        #expect(piResult?.success == false)
        #expect(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(".claude/settings.json").path))
        #expect(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(".codex/config.toml").path))
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".zshrc").path))
    }

    @Test("an interrupted Pi replacement rolls the prior managed file back")
    func replacementRollback() throws {
        struct MoveFailure: Error {}

        let fixture = try piFixture()
        let source = piSource(fixture)
        let destination = piDestination(fixture)
        let old = "\(AgentHooksInstall.piExtensionMarker)\n// prior\n"
        try fixture.write(old, to: destination)
        let operation = IntegrationOperation.copyFile(
            source: source.path,
            path: destination.path,
            target: destination.path,
            expectedSource: IntegrationFilesystem.fingerprint(source),
            expectedPath: IntegrationFilesystem.fingerprint(destination),
            expectedTarget: IntegrationFilesystem.fingerprint(destination)
        )
        var moveCount = 0

        #expect(throws: MoveFailure.self) {
            try IntegrationFilesystem.apply(operation, moveItem: { from, to in
                moveCount += 1
                if moveCount == 2 { throw MoveFailure() }
                try FileManager.default.moveItem(at: from, to: to)
            })
        }

        #expect(try String(contentsOf: destination, encoding: .utf8) == old)
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".bak"))
    }
}

private func piFixture() throws -> Fixture {
    let fixture = try Fixture()
    try fixture.makeHookResources()
    try FileManager.default.createDirectory(
        at: fixture.home.appendingPathComponent(".pi/agent"), withIntermediateDirectories: true)
    return fixture
}

private func piSource(_ fixture: Fixture) -> URL {
    fixture.resources.appendingPathComponent(
        "agent-status/\(AgentHooksInstall.piExtensionRelativePath)")
}

private func piDestination(_ fixture: Fixture) -> URL {
    URL(fileURLWithPath: AgentHooksInstall.piExtensionPath(home: fixture.home.path))
}
