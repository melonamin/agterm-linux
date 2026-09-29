import Foundation
import Testing
import agtermCore
@testable import LinuxIntegrations

@Suite("Linux integration service")
struct IntegrationServiceTests {
    @Test("portable CLI launcher is planned and installed safely")
    func cliLauncher() throws {
        let fixture = try Fixture()
        let tool = fixture.bin.appendingPathComponent("agtermctl-linux")
        try fixture.write("#!/bin/sh\n", to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let service = fixture.service(path: [])
        #expect(service.status()[.commandLineTool]?.state == .notInstalled)
        let plan = try service.planCommandLineTool()
        #expect(plan.canApply)
        #expect(try service.apply(plan).succeeded)
        let launcher = fixture.home.appendingPathComponent(".local/bin/agtermctl")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: launcher.path) == tool.path)
        #expect(service.status()[.commandLineTool]?.state == .installed)
        #expect(try service.planCommandLineTool().canApply == false)
    }

    @Test("portable CLI launcher repairs a missing ownership record")
    func cliLauncherOwnershipRepair() throws {
        let fixture = try Fixture()
        let tool = fixture.bin.appendingPathComponent("agtermctl-linux")
        let launcher = fixture.home.appendingPathComponent(".local/bin/agtermctl")
        try fixture.write("#!/bin/sh\n", to: tool, mode: 0o755)
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: launcher.path, withDestinationPath: tool.path)

        let service = fixture.service(path: [])
        #expect(service.status()[.commandLineTool]?.state == .updateAvailable)
        let plan = try service.planCommandLineTool()
        #expect(plan.canApply)
        #expect(try service.apply(plan).succeeded)
        #expect(service.launcherOwnershipMatches(launcher: launcher, target: tool))
        #expect(try service.planCommandLineTool().canApply == false)
    }

    @Test("portable CLI launcher missing ownership remains repairable on PATH")
    func cliLauncherOwnershipRepairOnPath() throws {
        let fixture = try Fixture()
        let tool = fixture.bin.appendingPathComponent("agtermctl-linux")
        let launcherDirectory = fixture.home.appendingPathComponent(".local/bin")
        let launcher = launcherDirectory.appendingPathComponent("agtermctl")
        try fixture.write("#!/bin/sh\n", to: tool, mode: 0o755)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: launcher.path, withDestinationPath: tool.path)

        let service = fixture.service(path: [launcherDirectory])
        #expect(service.status()[.commandLineTool]?.state == .updateAvailable)
        #expect(try service.planCommandLineTool().canApply)
    }

    @Test("failed ownership record write does not leave an unowned launcher")
    func cliLauncherRecordFailure() throws {
        let fixture = try Fixture()
        let tool = fixture.bin.appendingPathComponent("agtermctl-linux")
        let launcher = fixture.home.appendingPathComponent(".local/bin/agtermctl")
        let share = fixture.home.appendingPathComponent(".local/share")
        try fixture.write("#!/bin/sh\n", to: tool, mode: 0o755)
        try fixture.write("not a directory", to: share)

        let service = fixture.service(path: [])
        let failed = try service.apply(service.planCommandLineTool())
        #expect(!failed.succeeded)
        #expect(!FileManager.default.fileExists(atPath: launcher.path))

        try FileManager.default.removeItem(at: share)
        #expect(try service.apply(service.planCommandLineTool()).succeeded)
        #expect(service.launcherOwnershipMatches(launcher: launcher, target: tool))
    }

    @Test("personal installer CLI beside the app is recognized")
    func personalInstallerCLI() throws {
        let fixture = try Fixture()
        let app = fixture.bin.appendingPathComponent("agterm-linux")
        let tool = fixture.bin.appendingPathComponent("agtermctl")
        try fixture.write("#!/bin/sh\n", to: app, mode: 0o755)
        try fixture.write("#!/bin/sh\n", to: tool, mode: 0o755)

        let status = fixture.service(path: [fixture.bin]).status()[.commandLineTool]
        #expect(status?.state == .installed)
        #expect(status?.path == tool.path)
        #expect(status?.detail == "Installed with this agterm build.")
    }

    @Test("in-place personal installer CLI is never replaced by a self-link")
    func inPlacePersonalInstallerCLI() throws {
        let fixture = try Fixture()
        let userBin = fixture.home.appendingPathComponent(".local/bin", isDirectory: true)
        let app = userBin.appendingPathComponent("agterm-linux")
        let launcher = userBin.appendingPathComponent("agtermctl")
        try fixture.write("#!/bin/sh\n# direct personal install\n", to: launcher, mode: 0o755)
        try fixture.write("#!/bin/sh\n", to: app, mode: 0o755)
        let service = IntegrationService(environment: IntegrationEnvironment(
            homeDirectory: fixture.home,
            executableURL: app,
            pathDirectories: [userBin],
            resourceRoot: fixture.resources
        ))

        let status = service.status()[.commandLineTool]
        #expect(status?.state == .installed)
        #expect(status?.detail.contains("personal installer") == true)
        #expect(try service.planCommandLineTool().operations.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: launcher.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(try String(contentsOf: launcher, encoding: .utf8).contains("direct personal install"))

        let withoutPath = IntegrationService(environment: IntegrationEnvironment(
            homeDirectory: fixture.home,
            executableURL: app,
            pathDirectories: [],
            resourceRoot: fixture.resources
        )).status()[.commandLineTool]
        #expect(withoutPath?.state == .installed)
        #expect(withoutPath?.path == launcher.path)
        #expect(withoutPath?.detail.contains("not on PATH") == true)
    }

    @Test("dangling absolute portable launcher remains repairable")
    func danglingOwnedLauncher() throws {
        let fixture = try Fixture()
        let current = fixture.bin.appendingPathComponent("agtermctl-linux")
        try fixture.write("#!/bin/sh\n", to: current, mode: 0o755)
        let launcher = fixture.home.appendingPathComponent(".local/bin/agtermctl")
        let moved = fixture.root.appendingPathComponent("moved/bin/agtermctl-linux")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: launcher.path,
            withDestinationPath: moved.path
        )

        let service = fixture.service(path: [])
        try fixture.write(service.launcherOwnershipContents(launcher: launcher, target: moved),
                          to: service.environment.launcherOwnershipFile)
        #expect(service.ownedLauncher(launcher))
        #expect(service.status()[.commandLineTool]?.state == .updateAvailable)
        #expect(try service.apply(service.planCommandLineTool()).succeeded)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: launcher.path) == current.path)
    }

    @Test("unknown broken CLI symlinks are protected")
    func brokenCLILauncher() throws {
        let fixture = try Fixture()
        let tool = fixture.bin.appendingPathComponent("agtermctl-linux")
        try fixture.write("#!/bin/sh\n", to: tool, mode: 0o755)
        let launcher = fixture.home.appendingPathComponent(".local/bin/agtermctl")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: launcher.path,
                                                   withDestinationPath: "../old/agtermctl-linux")

        let service = fixture.service(path: [])
        #expect(service.status()[.commandLineTool]?.state == .conflict)
        #expect(!service.ownedLauncher(launcher))
        #expect(try service.planCommandLineTool().canApply == false)
    }

    @Test("unrelated absolute dangling CLI symlinks are protected")
    func unrelatedAbsoluteDanglingLauncher() throws {
        let fixture = try Fixture()
        let tool = fixture.bin.appendingPathComponent("agtermctl-linux")
        try fixture.write("#!/bin/sh\n", to: tool, mode: 0o755)
        let launcher = fixture.home.appendingPathComponent(".local/bin/agtermctl")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: launcher.path,
            withDestinationPath: "/opt/other-project/agtermctl"
        )

        let service = fixture.service(path: [])
        #expect(!service.ownedLauncher(launcher))
        #expect(service.status()[.commandLineTool]?.state == .conflict)
        #expect(try service.planCommandLineTool().canApply == false)
    }

    @Test("an unrelated agterm-named launcher on PATH remains protected")
    func stalePATHLauncher() throws {
        let fixture = try Fixture()
        let current = fixture.bin.appendingPathComponent("agtermctl-linux")
        let old = fixture.root.appendingPathComponent("old/agtermctl-linux")
        try fixture.write("#!/bin/sh\n", to: current, mode: 0o755)
        try fixture.write("#!/bin/sh\n", to: old, mode: 0o755)
        let userBin = fixture.home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: userBin.appendingPathComponent("agtermctl").path,
            withDestinationPath: old.path
        )

        let service = fixture.service(path: [userBin])
        #expect(service.status()[.commandLineTool]?.state == .conflict)
        #expect(try service.planCommandLineTool().canApply == false)
    }

    @Test("an earlier portable launcher remains updatable")
    func previousPortableLauncher() throws {
        let fixture = try Fixture()
        let current = fixture.bin.appendingPathComponent("agtermctl-linux")
        let previousBin = fixture.root.appendingPathComponent("previous/bin", isDirectory: true)
        let previous = previousBin.appendingPathComponent("agtermctl-linux")
        try fixture.write("#!/bin/sh\n", to: current, mode: 0o755)
        try fixture.write("#!/bin/sh\n", to: previous, mode: 0o755)
        try fixture.write("#!/bin/sh\n", to: previousBin.appendingPathComponent("AgtermLinux"), mode: 0o755)
        let launcher = fixture.home.appendingPathComponent(".local/bin/agtermctl")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: launcher.path,
                                                   withDestinationPath: previous.path)

        let service = fixture.service(path: [launcher.deletingLastPathComponent()])
        #expect(service.status()[.commandLineTool]?.state == .updateAvailable)
        #expect(try service.apply(service.planCommandLineTool()).succeeded)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: launcher.path) == current.path)
    }

    @Test("known package tools are detected even when PATH omits them")
    func packageCLI() throws {
        let fixture = try Fixture()
        let tool = fixture.root.appendingPathComponent("package/bin/agtermctl")
        try fixture.write("#!/bin/sh\n", to: tool, mode: 0o755)
        try fixture.write("9.4.1\n", to: fixture.root.appendingPathComponent("package/share/agterm/VERSION"))

        let status = fixture.service(path: [], knownTools: [tool]).status()[.commandLineTool]
        #expect(status?.state == .installed)
        #expect(status?.path == tool.path)
        #expect(status?.version == "9.4.1")
        #expect(status?.detail.contains("package manager") == true)
    }

    @Test("unrelated CLI launcher is a conflict")
    func cliConflict() throws {
        let fixture = try Fixture()
        let tool = fixture.bin.appendingPathComponent("agtermctl-linux")
        try fixture.write("tool", to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try fixture.write("mine", to: fixture.home.appendingPathComponent(".local/bin/agtermctl"))

        let service = fixture.service(path: [])
        #expect(service.status()[.commandLineTool]?.state == .conflict)
        #expect(try service.planCommandLineTool().canApply == false)
    }

    @Test("skill installation protects unrelated content")
    func skillProtection() throws {
        let fixture = try Fixture()
        let source = fixture.resources.appendingPathComponent("agent-skill")
        try fixture.write("<!-- agterm-skill -->\ncurrent", to: source.appendingPathComponent("SKILL.md"))
        let destination = fixture.home.appendingPathComponent(".codex/skills/agterm")
        try fixture.write("user authored", to: destination.appendingPathComponent("SKILL.md"))

        let service = fixture.service(path: [])
        #expect(service.status()[.agentSkill]?.state == .conflict)
        #expect(try service.planSkill().conflicts.count == 1)

        try FileManager.default.removeItem(at: destination)
        let plan = try service.planSkill()
        #expect(try service.apply(plan).succeeded)
        #expect(service.status()[.agentSkill]?.state == .installed)
    }

    @Test("managed skills update idempotently without replacing a directory symlink")
    func skillUpdateThroughSymlink() throws {
        let fixture = try Fixture()
        let source = fixture.resources.appendingPathComponent("agent-skill")
        try fixture.write("<!-- agterm-skill -->\ncurrent", to: source.appendingPathComponent("SKILL.md"))
        let target = fixture.root.appendingPathComponent("managed-skill")
        try fixture.write("<!-- agterm-skill -->\nold", to: target.appendingPathComponent("SKILL.md"))
        let link = fixture.home.appendingPathComponent(".codex/skills/agterm")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        let service = fixture.service(path: [])
        #expect(service.status()[.agentSkill]?.state == .updateAvailable)
        #expect(try service.apply(service.planSkill()).succeeded)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(service.status()[.agentSkill]?.state == .installed)
        #expect(try service.planSkill().canApply == false)
    }

    @Test("shared Claude and Codex skill symlinks produce one replacement")
    func sharedSkillDestination() throws {
        let fixture = try Fixture()
        let source = fixture.resources.appendingPathComponent("agent-skill")
        try fixture.write("<!-- agterm-skill -->\ncurrent", to: source.appendingPathComponent("SKILL.md"))
        let shared = fixture.root.appendingPathComponent("shared-skill")
        try fixture.write("<!-- agterm-skill -->\nold", to: shared.appendingPathComponent("SKILL.md"))
        for agent in [".claude", ".codex"] {
            let link = fixture.home.appendingPathComponent("\(agent)/skills/agterm")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: shared.path)
        }

        let service = fixture.service(path: [])
        let plan = try service.planSkill()
        #expect(plan.steps.contains { $0.action == "Share" })
        #expect(try service.apply(plan).succeeded)
        #expect(service.status()[.agentSkill]?.state == .installed)
    }

    @Test("retargeting a skill directory symlink invalidates its preview")
    func retargetedSkillSymlink() throws {
        let fixture = try Fixture()
        let source = fixture.resources.appendingPathComponent("agent-skill")
        try fixture.write("<!-- agterm-skill -->\ncurrent", to: source.appendingPathComponent("SKILL.md"))
        let first = fixture.root.appendingPathComponent("skill-first")
        let second = fixture.root.appendingPathComponent("skill-second")
        try fixture.write("<!-- agterm-skill -->\nold", to: first.appendingPathComponent("SKILL.md"))
        try fixture.write("<!-- agterm-skill -->\nold", to: second.appendingPathComponent("SKILL.md"))
        let link = fixture.home.appendingPathComponent(".codex/skills/agterm")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: first.path)
        let service = fixture.service(path: [])
        let plan = try service.planSkill()

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: second.path)
        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
    }

    @Test("malformed Claude settings are preserved while safe hook targets install")
    func malformedClaudeSettings() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        try fixture.write("not json", to: fixture.home.appendingPathComponent(".claude/settings.json"))
        let service = fixture.service(path: [])
        let plan = try service.planHooks()
        #expect(plan.canApply)
        #expect(plan.conflicts.contains { $0.contains("invalid JSON") })
        let result = try service.apply(plan)
        #expect(!result.succeeded)
        #expect(result.results.allSatisfy { $0.success })
        #expect(try String(contentsOf: fixture.home.appendingPathComponent(
            ".claude/settings.json"), encoding: .utf8) == "not json")
    }

    @Test("hooks install is safe, backed up, and idempotent")
    func hooksInstall() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let settings = fixture.home.appendingPathComponent(".claude/settings.json")
        try fixture.write("{\"permissions\":{}}", to: settings)
        let service = fixture.service(path: [])
        let plan = try service.planHooks()
        #expect(plan.canApply)
        #expect(try service.apply(plan).succeeded)
        #expect(FileManager.default.fileExists(atPath: settings.path + ".bak"))
        #expect(service.status()[.claudeHooks]?.state == .installed)
        let second = try service.planHooks()
        #expect(second.canApply == false)
        #expect(service.status()[.claudeHooks]?.state == .installed)
    }

    @Test("missing shell startup integration makes installed hooks repairable")
    func missingShellStartupIntegration() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let service = fixture.service(path: [])
        #expect(try service.apply(service.planHooks()).succeeded)
        #expect(service.status()[.claudeHooks]?.state == .installed)

        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(".zshrc"))
        #expect(service.status()[.claudeHooks]?.state == .partial)
        #expect(service.status()[.codexHooks]?.state == .partial)
        #expect(try service.planHooks().canApply)
    }

    @Test("partial managed hook assets are repairable")
    func partialHooks() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let source = fixture.resources.appendingPathComponent("agent-status/agterm-agent-status.sh")
        let destination = fixture.home.appendingPathComponent(".config/agterm/agent-status/agterm-agent-status.sh")
        try fixture.write(String(contentsOf: source, encoding: .utf8), to: destination, mode: 0o755)

        let service = fixture.service(path: [])
        #expect(service.status()[.claudeHooks]?.state == .partial)
        let plan = try service.planHooks()
        #expect(plan.canApply)
        #expect(plan.steps.contains { $0.path.contains("agent-status") })
    }

    @Test("retired agterm-managed hook scripts do not block upgrades")
    func retiredManagedHookScript() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let destination = fixture.home.appendingPathComponent(".config/agterm/agent-status")
        try fixture.write(
            "#!/bin/sh\n# agterm-agent-status — retired Codex notify chain\n",
            to: destination.appendingPathComponent("codex-notify.sh"), mode: 0o755
        )

        let service = fixture.service(path: [])
        let plan = try service.planHooks()
        #expect(plan.canApply)
        #expect(try service.apply(plan).succeeded)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("codex-notify.sh").path))
        #expect(service.status()[.claudeHooks]?.state == .installed)
    }

    @Test("shell startup aliases resolving to one file produce one safe write")
    func sharedShellStartupFile() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let shared = fixture.root.appendingPathComponent("shared-shell-rc")
        try fixture.write("# shared startup\n", to: shared)
        for name in [".zshrc", ".bashrc"] {
            try FileManager.default.createSymbolicLink(
                atPath: fixture.home.appendingPathComponent(name).path,
                withDestinationPath: shared.path
            )
        }

        let service = fixture.service(path: [])
        let plan = try service.planHooks()
        #expect(plan.steps.contains { $0.action == "Share" && $0.path.hasSuffix(".bashrc") })
        #expect(try service.apply(plan).succeeded)
        let contents = try String(contentsOf: shared, encoding: .utf8)
        #expect(contents.components(separatedBy: AgentHooksInstall.rcMarkerBegin).count == 2)
    }

    @Test("retargeting a shared shell startup symlink invalidates its preview")
    func retargetedSharedShellStartupFile() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let shared = fixture.root.appendingPathComponent("shared-shell-rc")
        let elsewhere = fixture.root.appendingPathComponent("elsewhere-shell-rc")
        try fixture.write("# shared startup\n", to: shared)
        try fixture.write("# elsewhere\n", to: elsewhere)
        for name in [".zshrc", ".bashrc"] {
            try FileManager.default.createSymbolicLink(
                atPath: fixture.home.appendingPathComponent(name).path,
                withDestinationPath: shared.path
            )
        }
        let service = fixture.service(path: [])
        let plan = try service.planHooks()
        let bash = fixture.home.appendingPathComponent(".bashrc")
        try FileManager.default.removeItem(at: bash)
        try FileManager.default.createSymbolicLink(atPath: bash.path, withDestinationPath: elsewhere.path)

        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(try String(contentsOf: shared, encoding: .utf8) == "# shared startup\n")
    }

    @Test("mixed-syntax shell aliases leave their shared startup file untouched")
    func mixedSyntaxShellAliases() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let shared = fixture.root.appendingPathComponent("shared-shell-rc")
        try fixture.write("# shared startup\n", to: shared)
        for relative in [".zshrc", ".bashrc", ".config/fish/config.fish"] {
            let link = fixture.home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: shared.path)
        }
        let service = fixture.service(path: [])
        let plan = try service.planHooks()

        #expect(plan.conflicts.contains { $0.contains("different syntax") })
        #expect(!plan.steps.contains { $0.path.hasSuffix(".zshrc") || $0.path.hasSuffix(".bashrc")
            || $0.path.hasSuffix("config.fish") })
        _ = try service.apply(plan)
        #expect(try String(contentsOf: shared, encoding: .utf8) == "# shared startup\n")
    }

    @Test("incomplete shell markers are conflicts rather than installed integrations")
    func incompleteShellMarker() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let zsh = fixture.home.appendingPathComponent(".zshrc")
        try fixture.write("\(AgentHooksInstall.rcMarkerBegin)\n", to: zsh)
        let service = fixture.service(path: [])

        #expect(service.status()[.claudeHooks]?.state == .conflict)
        let plan = try service.planHooks()
        #expect(plan.conflicts.contains { $0.contains("incomplete agterm-managed block") })
        #expect(try String(contentsOf: zsh, encoding: .utf8) == "\(AgentHooksInstall.rcMarkerBegin)\n")
    }

    @Test("unrelated hook-directory content is never replaced")
    func hooksDirectoryConflict() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        try fixture.write("user hook", to: fixture.home
            .appendingPathComponent(".config/agterm/agent-status/custom.sh"))

        let service = fixture.service(path: [])
        #expect(service.status()[.claudeHooks]?.state == .conflict)
        let plan = try service.planHooks()
        #expect(plan.conflicts.contains { $0.contains("not an agterm-managed") })
        #expect(!plan.canApply)
        #expect(plan.steps.isEmpty)
        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(
            ".claude/settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(
            ".codex/config.toml").path))
    }

    @Test("hook config symlinks and restrictive modes survive merge")
    func hookSymlinkAndMode() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let real = fixture.root.appendingPathComponent("claude-settings.json")
        try fixture.write("{\"permissions\":{}}", to: real, mode: 0o600)
        let link = fixture.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        let service = fixture.service(path: [])
        let plan = try service.planHooks()
        #expect(plan.steps.contains { $0.action == "Backup" && $0.path == real.path + ".bak" })
        #expect(try service.apply(plan).succeeded)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        let mode = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(FileManager.default.fileExists(atPath: real.path + ".bak"))
    }

    @Test("a backup changed after preview is never overwritten")
    func hookBackupStalePlan() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let settings = fixture.home.appendingPathComponent(".claude/settings.json")
        let backup = URL(fileURLWithPath: AgentHooksInstall.backupPath(for: settings.path))
        try fixture.write("{\"permissions\":{}}", to: settings)
        try fixture.write("older backup", to: backup)

        let service = fixture.service(path: [])
        let plan = try service.planHooks()
        try fixture.write("newer backup", to: backup)

        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
        #expect(try String(contentsOf: backup, encoding: .utf8) == "newer backup")
    }

    @Test("custom Codex hooks block automatic installation")
    func codexCustomHooks() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        try fixture.write("[[hooks.Stop]]\n", to: fixture.home.appendingPathComponent(".codex/config.toml"))

        let service = fixture.service(path: [])
        #expect(service.status()[.codexHooks]?.state == .conflict)
        #expect(try service.planHooks().conflicts.contains { $0.contains("custom Codex hooks") })
    }

    @Test("foreign Codex marker blocks are conflicts rather than installed integrations")
    func foreignCodexMarker() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let config = fixture.home.appendingPathComponent(".codex/config.toml")
        let contents = """
        \(AgentHooksInstall.rcMarkerBegin)
        model = "gpt-5"
        \(AgentHooksInstall.rcMarkerEnd)
        """
        try fixture.write(contents, to: config)
        let service = fixture.service(path: [])

        #expect(service.status()[.codexHooks]?.state == .conflict)
        let plan = try service.planHooks()
        #expect(plan.conflicts.contains { $0.contains("unrecognized agterm marker") })
        #expect(try String(contentsOf: config, encoding: .utf8) == contents)
    }

    @Test("an absent Codex installation is unavailable instead of permanently partial")
    func absentCodexHooks() throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(".codex"))
        try fixture.makeHookResources()
        let service = fixture.service(path: [])
        #expect(service.status()[.codexHooks]?.state == .unavailable)
    }

    @Test("a changed destination invalidates a preview")
    func stalePlan() throws {
        let fixture = try Fixture()
        let tool = fixture.bin.appendingPathComponent("agtermctl-linux")
        try fixture.write("tool", to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let service = fixture.service(path: [])
        let plan = try service.planCommandLineTool()
        try fixture.write("race", to: fixture.home.appendingPathComponent(".local/bin/agtermctl"))
        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
    }

    @Test("a changed bundled source invalidates a preview")
    func staleSource() throws {
        let fixture = try Fixture()
        let source = fixture.resources.appendingPathComponent("agent-skill")
        try fixture.write("<!-- agterm-skill -->\nfirst", to: source.appendingPathComponent("SKILL.md"))
        let service = fixture.service(path: [])
        let plan = try service.planSkill()
        try fixture.write("<!-- agterm-skill -->\nsecond", to: source.appendingPathComponent("SKILL.md"))
        #expect(throws: IntegrationServiceError.self) { try service.apply(plan) }
    }

    @Test("partial apply results identify failures and skipped operations")
    func structuredPartialFailure() throws {
        let fixture = try Fixture()
        let first = fixture.root.appendingPathComponent("first.txt")
        let blockingFile = fixture.root.appendingPathComponent("not-a-directory")
        try fixture.write("block", to: blockingFile)
        let second = blockingFile.appendingPathComponent("second.txt")
        let third = fixture.root.appendingPathComponent("third.txt")
        let missing = FileFingerprint(value: "missing")
        let plan = IntegrationPlan(
            kind: .hooks,
            steps: [],
            operations: [
                .writeText(path: first.path, target: first.path, contents: "first", backup: false,
                           expectedPath: missing, expectedTarget: missing, expectedBackup: nil),
                .writeText(path: second.path, target: second.path, contents: "second", backup: false,
                           expectedPath: missing, expectedTarget: missing, expectedBackup: nil),
                .writeText(path: third.path, target: third.path, contents: "third", backup: false,
                           expectedPath: missing, expectedTarget: missing, expectedBackup: nil),
            ]
        )

        let result = try fixture.service(path: []).apply(plan)
        #expect(result.results.count == 3)
        #expect(result.results[0].success)
        #expect(!result.results[1].success)
        #expect(result.results[2].message.contains("skipped"))
        #expect(!FileManager.default.fileExists(atPath: third.path))
    }

    @Test("failed directory rollback preserves the prior installation as a recovery backup")
    func failedDirectoryRollbackPreservesBackup() throws {
        struct MoveFailure: Error {}

        let fixture = try Fixture()
        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        let destination = fixture.root.appendingPathComponent("destination", isDirectory: true)
        try fixture.write("new", to: source.appendingPathComponent("value"))
        try fixture.write("old", to: destination.appendingPathComponent("value"))
        let operation = IntegrationOperation.replaceDirectory(
            source: source.path,
            destination: destination.path,
            displayPath: destination.path,
            expectedSource: IntegrationFilesystem.fingerprint(source),
            expectedDestination: IntegrationFilesystem.fingerprint(destination),
            expectedDisplayPath: IntegrationFilesystem.fingerprint(destination),
            bakedCLI: nil
        )
        var moveCount = 0

        #expect(throws: IntegrationServiceError.self) {
            try IntegrationFilesystem.apply(operation, moveItem: { from, to in
                moveCount += 1
                if moveCount >= 2 { throw MoveFailure() }
                try FileManager.default.moveItem(at: from, to: to)
            })
        }

        let recovery = try FileManager.default.contentsOfDirectory(
            at: fixture.root, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".destination.agterm-old-") }
        let recoveryURL = try #require(recovery)
        #expect(try String(contentsOf: recoveryURL.appendingPathComponent("value"), encoding: .utf8) == "old")
    }

    @Test("a missing write path cannot become a symlink after preview")
    func writePathSymlinkRace() throws {
        let fixture = try Fixture()
        let display = fixture.root.appendingPathComponent("settings.json")
        let target = fixture.root.appendingPathComponent("elsewhere/settings.json")
        let missing = FileFingerprint(value: "missing")
        let plan = IntegrationPlan(
            kind: .hooks,
            steps: [],
            operations: [
                .writeText(path: display.path, target: display.path, contents: "managed",
                           backup: false, expectedPath: missing, expectedTarget: missing,
                           expectedBackup: nil),
            ]
        )
        try FileManager.default.createSymbolicLink(atPath: display.path,
                                                   withDestinationPath: target.path)

        #expect(throws: IntegrationServiceError.self) { try fixture.service(path: []).apply(plan) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("a dangling write symlink cannot be retargeted after preview")
    func danglingWriteSymlinkRace() throws {
        let fixture = try Fixture()
        let display = fixture.root.appendingPathComponent("settings.json")
        let first = fixture.root.appendingPathComponent("first/settings.json")
        let second = fixture.root.appendingPathComponent("second/settings.json")
        try FileManager.default.createSymbolicLink(atPath: display.path,
                                                   withDestinationPath: first.path)
        let plan = IntegrationPlan(
            kind: .hooks,
            steps: [],
            operations: [
                .writeText(
                    path: display.path,
                    target: first.path,
                    contents: "managed",
                    backup: false,
                    expectedPath: IntegrationFilesystem.fingerprint(display),
                    expectedTarget: IntegrationFilesystem.fingerprint(first),
                    expectedBackup: nil
                ),
            ]
        )
        try FileManager.default.removeItem(at: display)
        try FileManager.default.createSymbolicLink(atPath: display.path,
                                                   withDestinationPath: second.path)

        #expect(throws: IntegrationServiceError.self) { try fixture.service(path: []).apply(plan) }
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test("process environments honor injected HOME, PATH, resources, and version")
    func environmentInjection() throws {
        let fixture = try Fixture()
        let executable = fixture.bin.appendingPathComponent("relative-tool")
        try fixture.write("#!/bin/sh\n", to: executable, mode: 0o755)
        let environment = IntegrationEnvironment.process(
            environment: [
                "HOME": fixture.home.path,
                "PATH": fixture.bin.path,
                "AGTERM_RESOURCE_ROOT": fixture.resources.path,
                "AGTERM_VERSION": "1.2.3",
            ],
            arguments: ["relative-tool"]
        )
        #expect(environment.homeDirectory == fixture.home)
        #expect(environment.pathDirectories == [fixture.bin])
        #expect(environment.executableURL == executable)
        #expect(environment.resourceRoot == fixture.resources)
        #expect(environment.versionOverride == "1.2.3")
    }

    @Test("Flatpak process environments do not offer a host launcher")
    func flatpakEnvironment() throws {
        let fixture = try Fixture()
        let environment = IntegrationEnvironment.process(
            environment: [
                "HOME": fixture.home.path,
                "PATH": fixture.bin.path,
                "FLATPAK_ID": "io.github.melonamin.agterm",
            ],
            arguments: [fixture.bin.appendingPathComponent("agterm-linux").path]
        )
        #expect(!environment.portableLauncherAllowed)
        #expect(IntegrationService(environment: environment).status()[.commandLineTool]?.state == .unavailable)
    }

    @Test("AppImage environments do not offer a launcher into a temporary mount")
    func appImageLauncherUnavailable() throws {
        let fixture = try Fixture()
        let tool = fixture.bin.appendingPathComponent("agtermctl-linux")
        try fixture.write("#!/bin/sh\n", to: tool, mode: 0o755)
        let environment = IntegrationEnvironment(
            homeDirectory: fixture.home,
            executableURL: fixture.bin.appendingPathComponent("agterm-linux"),
            pathDirectories: [],
            resourceRoot: fixture.resources,
            portableLauncherAllowed: false
        )
        let service = IntegrationService(environment: environment)
        #expect(service.status()[.commandLineTool]?.state == .unavailable)
        #expect(throws: IntegrationServiceError.self) { try service.planCommandLineTool() }
    }

    @Test("AppImage environments recognize an existing persistent CLI on PATH")
    func appImageRecognizesPersistentPATHCLI() throws {
        let fixture = try Fixture()
        let bundled = fixture.bin.appendingPathComponent("agtermctl")
        let stableBin = fixture.root.appendingPathComponent("stable/bin", isDirectory: true)
        let stable = stableBin.appendingPathComponent("agtermctl")
        try fixture.write("#!/bin/sh\n", to: bundled, mode: 0o755)
        try fixture.write("#!/bin/sh\n", to: stable, mode: 0o755)
        let environment = IntegrationEnvironment(
            homeDirectory: fixture.home,
            executableURL: fixture.bin.appendingPathComponent("agterm-linux"),
            pathDirectories: [fixture.bin, stableBin],
            resourceRoot: fixture.resources,
            portableLauncherAllowed: false
        )

        let status = IntegrationService(environment: environment).status()[.commandLineTool]
        #expect(status?.state == .installed)
        #expect(status?.path == stable.path)
        #expect(status?.detail.contains("Available on PATH") == true)
    }

    @Test("AppImage environments recognize an existing agterm-owned launcher")
    func appImageRecognizesOwnedLauncher() throws {
        let fixture = try Fixture()
        let bundled = fixture.bin.appendingPathComponent("agtermctl-linux")
        let stableBin = fixture.root.appendingPathComponent("stable/bin", isDirectory: true)
        let stable = stableBin.appendingPathComponent("agtermctl-linux")
        let launcher = fixture.home.appendingPathComponent(".local/bin/agtermctl")
        try fixture.write("#!/bin/sh\n", to: bundled, mode: 0o755)
        try fixture.write("#!/bin/sh\n", to: stable, mode: 0o755)
        try fixture.write("#!/bin/sh\n", to: stableBin.appendingPathComponent("AgtermLinux"), mode: 0o755)
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: launcher.path,
                                                   withDestinationPath: stable.path)
        let environment = IntegrationEnvironment(
            homeDirectory: fixture.home,
            executableURL: fixture.bin.appendingPathComponent("agterm-linux"),
            pathDirectories: [launcher.deletingLastPathComponent()],
            resourceRoot: fixture.resources,
            portableLauncherAllowed: false
        )

        let status = IntegrationService(environment: environment).status()[.commandLineTool]
        #expect(status?.state == .installed)
        #expect(status?.path == launcher.path)
        #expect(status?.detail.contains("owned launcher") == true)
    }

    @Test("AppImage hook installs require a persistent CLI")
    func appImageHooksRequirePersistentCLI() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let tool = fixture.bin.appendingPathComponent("agtermctl-linux")
        try fixture.write("#!/bin/sh\n", to: tool, mode: 0o755)
        let environment = IntegrationEnvironment(
            homeDirectory: fixture.home,
            executableURL: fixture.bin.appendingPathComponent("agterm-linux"),
            pathDirectories: [],
            resourceRoot: fixture.resources,
            portableLauncherAllowed: false
        )
        let service = IntegrationService(environment: environment)
        #expect(throws: IntegrationServiceError.self) { try service.planHooks() }
        #expect(service.status()[.codexHooks]?.state == .unavailable)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(
            ".config/agterm/agent-status").path))
    }

    @Test("AppImage hook installs bake an existing persistent CLI")
    func appImageHooksUsePersistentCLI() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let temporaryTool = fixture.bin.appendingPathComponent("agtermctl")
        let stableBin = fixture.root.appendingPathComponent("stable/bin", isDirectory: true)
        let stableTool = stableBin.appendingPathComponent("agtermctl")
        try fixture.write("#!/bin/sh\n", to: temporaryTool, mode: 0o755)
        try fixture.write("#!/bin/sh\n", to: stableTool, mode: 0o755)
        let environment = IntegrationEnvironment(
            homeDirectory: fixture.home,
            executableURL: fixture.bin.appendingPathComponent("agterm-linux"),
            pathDirectories: [fixture.bin, stableBin],
            resourceRoot: fixture.resources,
            portableLauncherAllowed: false
        )
        let service = IntegrationService(environment: environment)
        let plan = try service.planHooks()
        #expect(try service.apply(plan).succeeded)
        let wrapper = try String(
            contentsOf: fixture.home.appendingPathComponent(
                ".config/agterm/agent-status/agterm-agent-status.sh"),
            encoding: .utf8
        )
        #expect(wrapper.contains(stableTool.path))
        #expect(!wrapper.contains(temporaryTool.path))
        #expect(service.status()[.codexHooks]?.state == .installed)
    }
}

final class Fixture {
    let root: URL
    let home: URL
    let bin: URL
    let resources: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        home = root.appendingPathComponent("home", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func service(path: [URL], knownTools: [URL] = []) -> IntegrationService {
        IntegrationService(environment: IntegrationEnvironment(
            homeDirectory: home,
            executableURL: bin.appendingPathComponent("agterm-linux"),
            pathDirectories: path,
            resourceRoot: resources,
            knownCommandLineTools: knownTools
        ))
    }

    func write(_ text: String, to url: URL, mode: Int? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }

    func makeHookResources() throws {
        try write("#!/bin/sh\n", to: bin.appendingPathComponent("agtermctl-linux"), mode: 0o755)
        let root = resources.appendingPathComponent("agent-status")
        try write("#!/bin/sh\n# agterm wrapper\n", to: root.appendingPathComponent("agterm-agent-status.sh"),
                  mode: 0o755)
        try write("#!/bin/sh\n# agterm codex wrapper\n", to: root.appendingPathComponent("agterm-codex-status.sh"),
                  mode: 0o755)
        try write("# agterm shell", to: root.appendingPathComponent("shell/integration.sh"))
        try write("# agterm fish", to: root.appendingPathComponent("shell/integration.fish"))
        try write(
            "// agterm-pi-status-extension\nexport default () => {}\n",
            to: root.appendingPathComponent("pi/agterm-status.ts")
        )
        try write(
            "\(AgentHooksInstall.opencodePluginMarker)\nexport const AgtermStatusPlugin = async () => ({})\n",
            to: root.appendingPathComponent("opencode/agterm-status.js")
        )
    }
}
