import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
@Suite("Linux launch seed latch")
struct LinuxLaunchSeedLatchTests {
    private func latchedPolicy(launchedAs launched: RestoreMode, thenConfigured configured: RestoreMode,
                               liveUnavailableReason: String? = nil) throws -> (seed: Bool, exit: LinuxExitCapturePolicy.Action) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-seed-latch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        var settings = store.load()
        settings.restoreMode = launched
        try store.save(settings)
        let decision = store.load().effectiveRestoreMode.launchDecision(liveUnavailableReason: liveUnavailableReason)
        settings.restoreMode = configured
        try store.save(settings)
        let seed = LinuxLaunchSeedPolicy(launch: decision, denylist: [], runningNames: nil)
        let window = UUID()
        let exit = LinuxExitCapturePolicy { store.load().effectiveRestoreMode }
            .windowClosing(window, isTerminating: true, openIDs: [window])
        return (seed.restoreEnabled, exit)
    }

    @Test("a Re-run launch keeps replaying after the configured mode switches to Fresh")
    func rerunLaunchSwitchedToFresh() throws {
        let result = try latchedPolicy(launchedAs: .rerun, thenConfigured: .none)
        #expect(result.seed)
        #expect(result.exit == .clear)
    }

    @Test("a Fresh launch does not replay after the configured mode switches to Re-run")
    func freshLaunchSwitchedToRerun() throws {
        let result = try latchedPolicy(launchedAs: .none, thenConfigured: .rerun)
        #expect(!result.seed)
        #expect(result.exit == .capture(preserveUnconsumedPending: true))
    }

    @Test("Live launches never enable ordinary replay, active or fallen back", arguments: [nil, "unsupported shell"])
    func liveLaunchDoesNotReplay(reason: String?) throws {
        #expect(try !latchedPolicy(launchedAs: .live, thenConfigured: .rerun, liveUnavailableReason: reason).seed)
    }

    @Test("restore.set names the launch mode, not the configured one, for set and none")
    func restorePinNoticeReadsLaunchMode() {
        for pin in [ControlRestoreOverride.pin("make watch"), .pinNone] {
            #expect(AppController.restorePinNotice(pin, launchMode: .live)
                == "saved for rerun mode; active restore mode is live")
            #expect(AppController.restorePinNotice(pin, launchMode: .none)
                == "saved for rerun mode; active restore mode is none")
            #expect(AppController.restorePinNotice(pin, launchMode: .rerun) == nil)
        }
        #expect(AppController.restorePinNotice(.unpin, launchMode: .live) == nil)
    }
}
