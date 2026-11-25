import Foundation
import Testing
import agtermCore
@testable import LinuxIntegrations

@Suite("Linux OpenCode major selection")
struct OpenCodeV2IntegrationTests {
    @Test("login-shell PATH and exported v2 directory drive the installer")
    func loginEnvironment() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let base = fixture.root.appendingPathComponent("opencode-login")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try fixture.write("#!/bin/sh\nprintf '2.1.0\\n'\n", to: fixture.bin.appendingPathComponent("opencode"), mode: 0o755)
        try fixture.write("export PATH=\(CommandRestore.shellQuotedLine([fixture.bin.path])):$PATH\n"
                          + "export OPENCODE_CONFIG_DIR=\(CommandRestore.shellQuotedLine([base.path]))\n",
                          to: fixture.home.appendingPathComponent(".zshrc"))
        let service = IntegrationService(environment: IntegrationEnvironment(
            homeDirectory: fixture.home, executableURL: fixture.bin.appendingPathComponent("agterm-linux"),
            pathDirectories: [], resourceRoot: fixture.resources,
            probeEnvironment: ["HOME": fixture.home.path, "SHELL": "/bin/zsh"]))
        #expect(service.detectedOpenCodeVersion() == .v2)
        #expect(service.openCodeConfigurationDirectory?.path == base.path)
        let marker = AgentHooksInstall.OpenCode.marker(version: .v2)
        try fixture.write("\(marker)\nnew\n", to: fixture.resources.appendingPathComponent("agent-status/opencode/agterm-v2/tui.js"))
        #expect(try service.apply(service.planHooks()).succeeded)
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("plugins/agterm-v2/tui.js").path))
    }

    @Test("an explicitly empty v2 override never falls back to another directory")
    func emptyOverride() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        try fixture.write("user-owned", to: fixture.home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js"))
        let service = IntegrationService(environment: IntegrationEnvironment(
            homeDirectory: fixture.home, executableURL: fixture.bin.appendingPathComponent("agterm-linux"),
            pathDirectories: [], resourceRoot: fixture.resources, openCodeConfigDirectory: ""), openCodeVersion: .v2)
        #expect(service.openCodeConfigurationDirectory == nil)
        #expect(service.status()[.opencodePlugin]?.state == .unavailable)
        #expect(!service.needsOpenCodeVersionChoice)
        let unknown = IntegrationService(environment: service.environment)
        #expect(unknown.needsOpenCodeVersionChoice)
        #expect(!(try service.planHooks()).steps.contains { $0.path.contains("opencode") })
    }

    @Test("real version probe selects v2 and installs its entrypoint idempotently")
    func detectedV2() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let marker = AgentHooksInstall.OpenCode.marker(version: .v2)
        try fixture.write("\(marker)\nexport default () => {}\n",
                          to: fixture.resources.appendingPathComponent("agent-status/opencode/agterm-v2/tui.js"))
        try fixture.write("#!/bin/sh\nprintf '2.1.0\\n'\n", to: fixture.bin.appendingPathComponent("opencode"), mode: 0o755)
        let base = fixture.home.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let service = fixture.service(path: [fixture.bin])
        #expect(service.detectedOpenCodeVersion() == .v2)
        #expect(try service.apply(service.planHooks()).succeeded)
        #expect(service.status()[.opencodePlugin]?.state == .installed)
        #expect(try String(contentsOf: base.appendingPathComponent("plugins/agterm-v2/tui.js"), encoding: .utf8).contains(marker))
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("plugins/agterm-status.js").path))
        #expect(!(try service.planHooks()).steps.contains { $0.path.hasSuffix("agterm-v2/tui.js") })
    }

    @Test("unknown major skips without replacing user plugins; existing managed v2 can update offline")
    func unknownAndOffline() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let path = fixture.home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js")
        try fixture.write("// my plugin\n", to: path)
        let service = fixture.service(path: [])
        #expect(service.detectedOpenCodeVersion() == nil)
        let plan = try service.planHooks()
        #expect(plan.warnings.contains { $0.contains("major version is unknown") })
        _ = try service.apply(plan)
        #expect(try String(contentsOf: path, encoding: .utf8) == "// my plugin\n")
        let marker = AgentHooksInstall.OpenCode.marker(version: .v2)
        try fixture.write("\(marker)\nold\n", to: path)
        try fixture.write("\(marker)\nnew\n", to: fixture.resources.appendingPathComponent("agent-status/opencode/agterm-v2/tui.js"))
        #expect(service.detectedOpenCodeVersion() == .v2)
        #expect(try service.apply(service.planHooks()).succeeded)
        #expect(try String(contentsOf: path, encoding: .utf8) == "\(marker)\nnew\n")
    }
}
