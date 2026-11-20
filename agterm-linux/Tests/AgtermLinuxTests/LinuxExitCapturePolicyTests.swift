import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
@Suite("Linux exit capture policy")
struct LinuxExitCapturePolicyTests {
    private let capture = LinuxExitCapturePolicy.Action.capture(preserveUnconsumedPending: true)

    private func stateDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-exit-capture-\(UUID().uuidString)", isDirectory: true)
    }

    private func setMode(_ mode: RestoreMode, in store: SettingsStore) throws {
        var settings = store.load()
        settings.restoreMode = mode
        try store.save(settings)
    }

    @Test("configured rerun and live capture at exit, none clears", arguments: [
        (RestoreMode.rerun, true), (.live, true), (.none, false),
    ])
    func configuredModeDecides(mode: RestoreMode, captures: Bool) {
        let window = UUID()
        let policy = LinuxExitCapturePolicy { mode }
        let expected: LinuxExitCapturePolicy.Action = captures ? capture : .clear
        #expect(policy.windowClosing(window, isTerminating: false, openIDs: [window]) == expected)
    }

    @Test("a mode switched on after a Fresh launch captures at quit")
    func freshLaunchSwitchedToLiveCaptures() throws {
        let directory = stateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try setMode(.none, in: store)
        let policy = LinuxExitCapturePolicy { store.load().effectiveRestoreMode }
        try setMode(.live, in: store)
        let window = UUID()
        #expect(policy.quitting(registeredWindows: [window]).map(\.1) == [capture])
    }

    @Test("a mode switched off after a Live launch clears at quit")
    func liveLaunchSwitchedToFreshClears() throws {
        let directory = stateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try setMode(.live, in: store)
        let policy = LinuxExitCapturePolicy { store.load().effectiveRestoreMode }
        try setMode(.none, in: store)
        let window = UUID()
        #expect(policy.windowClosing(window, isTerminating: true, openIDs: [window]) == .clear)
    }

    @Test("a terminating close captures even with other windows open")
    func terminatingCloseCaptures() {
        let window = UUID()
        let policy = LinuxExitCapturePolicy { .rerun }
        #expect(policy.windowClosing(window, isTerminating: true, openIDs: [window, UUID()]) == capture)
    }

    @Test("closing the last open window captures")
    func lastWindowCloseCaptures() {
        let window = UUID()
        let policy = LinuxExitCapturePolicy { .live }
        #expect(policy.windowClosing(window, isTerminating: false, openIDs: [window]) == capture)
    }

    @Test("a non-last close clears in every mode", arguments: RestoreMode.allCases)
    func nonLastCloseClears(mode: RestoreMode) {
        let window = UUID()
        let policy = LinuxExitCapturePolicy { mode }
        #expect(policy.windowClosing(window, isTerminating: false, openIDs: [UUID(), window]) == .clear)
    }

    @Test("the quit flush acts only on still-registered windows")
    func quitFlushScopedToRegisteredWindows() {
        let closed = UUID(), open = UUID()
        let policy = LinuxExitCapturePolicy { .live }
        #expect(policy.windowClosing(closed, isTerminating: true, openIDs: [closed, open]) == capture)
        let flushed = policy.quitting(registeredWindows: [open])
        #expect(flushed.map(\.0) == [open])
        #expect(flushed.map(\.1) == [capture])
    }

    @Test("no window is captured twice in one exit")
    func windowCapturedOnce() {
        let window = UUID()
        let policy = LinuxExitCapturePolicy { .rerun }
        #expect(policy.windowClosing(window, isTerminating: true, openIDs: [window]) == capture)
        #expect(policy.quitting(registeredWindows: [window]).map(\.1) == [.skip])
        #expect(policy.windowClosing(window, isTerminating: true, openIDs: [window]) == .skip)

        let flushedFirst = UUID()
        #expect(policy.quitting(registeredWindows: [flushedFirst]).map(\.1) == [capture])
        #expect(policy.windowClosing(flushedFirst, isTerminating: true, openIDs: [flushedFirst])
            == .skip)
    }

    @Test("a window reopened after its exit edge captures again")
    func reopenedWindowCapturesAgain() {
        let window = UUID()
        let policy = LinuxExitCapturePolicy { .live }
        #expect(policy.windowClosing(window, isTerminating: false, openIDs: [window]) == capture)
        policy.windowOpened(window)
        #expect(policy.quitting(registeredWindows: [window]).map(\.1) == [capture])
    }
}
