import Testing
@testable import AgtermLinux

@Suite("Ghostty reload action policy")
struct GhosttyReloadPolicyTests {
    @Test("a soft reload adds no surface config update to host appearance reconciliation")
    func softReloadIsHandledWithoutAnotherUpdate() {
        var hostReloads = 0

        let disposition = GhosttyReloadPolicy.handle(isSoft: true) { hostReloads += 1 }

        #expect(disposition == .ignoreSoftReload)
        #expect(hostReloads == 0)
    }

    @Test("an app-scoped hard reload rebuilds the config once from the host")
    func hardReloadUsesHostConfig() {
        var hostReloads = 0

        let disposition = GhosttyReloadPolicy.handle(isSoft: false) { hostReloads += 1 }

        #expect(disposition == .reloadHostConfig)
        #expect(hostReloads == 1)
    }
}
