import Foundation
import Testing
@testable import LinuxIntegrations

@Suite("Linux integration stale-plan safety")
struct IntegrationServiceRaceTests {
    @Test("a dangling user skill symlink is reported and preserved")
    func danglingSkillSymlink() throws {
        let fixture = try Fixture()
        let source = fixture.resources.appendingPathComponent("agent-skill/SKILL.md")
        let link = fixture.home.appendingPathComponent(".codex/skills/agterm")
        let missing = fixture.root.appendingPathComponent("shared/missing-skill")
        try fixture.write("<!-- agterm-skill -->\ncurrent", to: source)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: missing.path)
        let service = fixture.service(path: [])

        #expect(service.status()[.agentSkill]?.state == .conflict)
        let plan = try service.planSkill()
        #expect(!plan.canApply)
        #expect(plan.conflicts.contains { $0.contains("dangling user-owned symlink") })
        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
    }

    @Test("a current skill target changing invalidates a multi-target preview")
    func staleCurrentSkillTarget() throws {
        let fixture = try Fixture()
        let source = fixture.resources.appendingPathComponent("agent-skill")
        let current = fixture.home.appendingPathComponent(".claude/skills/agterm")
        let pending = fixture.home.appendingPathComponent(".codex/skills/agterm")
        try fixture.write("<!-- agterm-skill -->\ncurrent", to: source.appendingPathComponent("SKILL.md"))
        try fixture.write("<!-- agterm-skill -->\ncurrent", to: current.appendingPathComponent("SKILL.md"))
        let service = fixture.service(path: [])
        let plan = try service.planSkill()
        #expect(plan.canApply)

        try fixture.write("<!-- agterm-skill -->\nchanged", to: current.appendingPathComponent("SKILL.md"))
        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(!FileManager.default.fileExists(atPath: pending.path))
    }

    @Test("a changed durable CLI invalidates a hook repair preview")
    func staleHookCLI() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let service = fixture.service(path: [])
        #expect(try service.apply(service.planHooks()).succeeded)
        let zsh = fixture.home.appendingPathComponent(".zshrc")
        try FileManager.default.removeItem(at: zsh)
        let plan = try service.planHooks()

        try fixture.write(
            "#!/bin/sh\n# replaced\n", to: fixture.bin.appendingPathComponent("agtermctl-linux"), mode: 0o755)
        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(!FileManager.default.fileExists(atPath: zsh.path))
    }

    @Test("changed bundled hook assets invalidate a configuration-only preview")
    func staleCurrentHookAssets() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let service = fixture.service(path: [])
        #expect(try service.apply(service.planHooks()).succeeded)
        let zsh = fixture.home.appendingPathComponent(".zshrc")
        try FileManager.default.removeItem(at: zsh)
        let plan = try service.planHooks()

        try fixture.write(
            "#!/bin/sh\n# changed agterm wrapper\n",
            to: fixture.resources.appendingPathComponent("agent-status/agterm-agent-status.sh"),
            mode: 0o755
        )
        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(!FileManager.default.fileExists(atPath: zsh.path))
    }
}
