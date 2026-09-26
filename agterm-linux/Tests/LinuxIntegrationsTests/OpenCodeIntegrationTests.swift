import Foundation
import Testing
import agtermCore
@testable import LinuxIntegrations

@Suite("OpenCode Linux integration")
struct OpenCodeIntegrationTests {
    @Test("plugin installs, updates, and is idempotent")
    func pluginInstall() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent(".config/opencode"),
            withIntermediateDirectories: true
        )
        let service = fixture.service(path: [])
        #expect(service.status()[.opencodePlugin]?.state == .notInstalled)
        #expect(try service.apply(service.planHooks()).succeeded)
        #expect(service.status()[.opencodePlugin]?.state == .installed)

        let plugin = fixture.home.appendingPathComponent(
            ".config/opencode/plugins/agterm-status.js")
        try fixture.write(
            "\(AgentHooksInstall.opencodePluginMarker)\nold\n", to: plugin)
        #expect(service.status()[.opencodePlugin]?.state == .updateAvailable)
        #expect(try service.apply(service.planHooks()).succeeded)
        #expect(service.status()[.opencodePlugin]?.state == .installed)
        #expect(!(try service.planHooks()).steps.contains { $0.path == plugin.path })
    }

    @Test("user-owned plugin is preserved")
    func userOwnedPlugin() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let plugin = fixture.home.appendingPathComponent(
            ".config/opencode/plugins/agterm-status.js")
        try fixture.write("export const Mine = async () => ({})\n", to: plugin)
        let service = fixture.service(path: [])
        #expect(service.status()[.opencodePlugin]?.state == .conflict)
        let plan = try service.planHooks()
        #expect(plan.conflicts.contains { $0.contains("user-owned") && $0.contains("opencode") })
        _ = try service.apply(plan)
        #expect(try String(contentsOf: plugin, encoding: .utf8)
            == "export const Mine = async () => ({})\n")
    }
}
