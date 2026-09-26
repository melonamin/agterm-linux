import Foundation
import Testing
@testable import LinuxIntegrations

extension IntegrationServiceTests {
    @Test("agent-root symlink aliases share one skill replacement")
    func agentRootSkillAliases() throws {
        let fixture = try Fixture()
        let source = fixture.resources.appendingPathComponent("agent-skill")
        try fixture.write("<!-- agterm-skill -->\ncurrent", to: source.appendingPathComponent("SKILL.md"))
        let shared = fixture.root.appendingPathComponent("shared-agent-home", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(".codex"))
        for agent in [".claude", ".codex"] {
            try FileManager.default.createSymbolicLink(
                atPath: fixture.home.appendingPathComponent(agent).path,
                withDestinationPath: shared.path
            )
        }

        let service = fixture.service(path: [])
        let plan = try service.planSkill()
        #expect(plan.operations.count == 2) // one replacement plus validation of the second alias
        #expect(try service.apply(plan).succeeded)
        #expect(try String(contentsOf: shared.appendingPathComponent("skills/agterm/SKILL.md"),
                           encoding: .utf8).contains("current"))
    }

    @Test("portable launcher resolves bundled resources through its symlink")
    func portableLauncherResourceRoot() throws {
        let fixture = try Fixture()
        let archive = fixture.root.appendingPathComponent("archive", isDirectory: true)
        let executable = archive.appendingPathComponent("bin/agtermctl")
        let skill = archive.appendingPathComponent("share/agterm/agent-skill", isDirectory: true)
        try fixture.write("#!/bin/sh\n", to: executable, mode: 0o755)
        try fixture.write("<!-- agterm-skill -->\n", to: skill.appendingPathComponent("SKILL.md"))
        let launcher = fixture.home.appendingPathComponent(".local/bin/agtermctl")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: launcher.path,
                                                   withDestinationPath: executable.path)

        let environment = IntegrationEnvironment.process(
            environment: ["HOME": fixture.home.path, "PATH": launcher.deletingLastPathComponent().path],
            arguments: ["agtermctl"]
        )

        #expect(environment.executableURL == launcher)
        #expect(environment.resource(named: "agent-skill") == skill)
    }

    @Test("skill installation applies safe targets while preserving a conflicting target")
    func skillPartialConflict() throws {
        let fixture = try Fixture()
        let source = fixture.resources.appendingPathComponent("agent-skill")
        try fixture.write("<!-- agterm-skill -->\ncurrent", to: source.appendingPathComponent("SKILL.md"))
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let protected = fixture.home.appendingPathComponent(".codex/skills/agterm/SKILL.md")
        try fixture.write("user authored", to: protected)

        let service = fixture.service(path: [])
        let plan = try service.planSkill()
        #expect(plan.canApply)
        #expect(plan.conflicts.count == 1)

        let result = try service.apply(plan)
        #expect(!result.succeeded)
        #expect(result.conflicts == plan.conflicts)
        #expect(result.results.allSatisfy { $0.success })
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(
            ".claude/skills/agterm/SKILL.md").path))
        #expect(try String(contentsOf: protected, encoding: .utf8) == "user authored")
    }

    @Test("retargeting either shared skill symlink invalidates its preview")
    func retargetedSharedSkillSymlink() throws {
        let fixture = try Fixture()
        let source = fixture.resources.appendingPathComponent("agent-skill")
        try fixture.write("<!-- agterm-skill -->\ncurrent", to: source.appendingPathComponent("SKILL.md"))
        let shared = fixture.root.appendingPathComponent("shared-skill")
        let elsewhere = fixture.root.appendingPathComponent("elsewhere-skill")
        try fixture.write("<!-- agterm-skill -->\nold", to: shared.appendingPathComponent("SKILL.md"))
        try fixture.write("<!-- agterm-skill -->\nother", to: elsewhere.appendingPathComponent("SKILL.md"))
        for agent in [".claude", ".codex"] {
            let link = fixture.home.appendingPathComponent("\(agent)/skills/agterm")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: shared.path)
        }
        let service = fixture.service(path: [])
        let plan = try service.planSkill()
        let codex = fixture.home.appendingPathComponent(".codex/skills/agterm")
        try FileManager.default.removeItem(at: codex)
        try FileManager.default.createSymbolicLink(atPath: codex.path, withDestinationPath: elsewhere.path)

        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(try String(contentsOf: shared.appendingPathComponent("SKILL.md"), encoding: .utf8)
            .contains("old"))
    }
}
