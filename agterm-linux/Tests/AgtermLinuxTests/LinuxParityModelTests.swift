import CGtk
import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
@Suite(.serialized)
struct LinuxParityModelTests {
    @Test func paneFocusObservationDeliversOnGLibWithoutDispatchPumping() throws {
        let originalTimer = MainTimer.scheduleTimer
        let originalHop = installGLibMainTimer()
        defer { MainTimer.scheduleTimer = originalTimer; MainActorHop.install(originalHop) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(initialCwd: "/tmp")
        var events: [ControlEventDraft] = []
        let store = AppStore(workspaces: [Workspace(name: "test", sessions: [session])],
                             persistence: PersistenceStore(directory: root), controlEventSink: { events.append($0) }, paneFinalizer: nil)
        store.setSplitVisibility(session.id, shown: true)
        session.splitFocused = false
        pump(for: 0.2)
        events.removeAll()
        session.splitFocused = true
        pump(for: 0.2)
        let focused = events.filter { $0.kind == .paneFocused }
        #expect(focused.count == 1)
        #expect(focused.first?.session == session.id.uuidString)
        #expect(focused.first?.payload.pane == "right")
    }

    @Test func collapsedCompanionRemainsVisibleInEveryFlaggedLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = Session(initialCwd: "/tmp", customName: "parent")
        let workspace = Workspace(name: "test", sessions: [parent])
        let store = AppStore(workspaces: [workspace], persistence: PersistenceStore(directory: root))
        let companion = try store.addCompanion(to: parent.id, options: CompanionOptions(name: "child", select: false)).get()
        store.setFlag(true, forSession: companion.id)
        _ = store.setSessionExpanded(parent.id, expanded: false)
        store.setSidebarMode(.flagged)
        for layout in FlaggedViewLayout.allCases {
            var settings = AppSettings()
            settings.flaggedViewLayout = layout.rawValue
            let snapshot = SidebarSnapshot.desired(from: store, settings: settings, renaming: nil,
                                                   expandedWorkspaceIDs: [workspace.id])
            let content = try #require(snapshot.rowContent[companion.id])
            #expect(content.shown)
            #expect(!content.indented)
            #expect(content.name.contains("parent"))
            #expect(content.name.contains("child"))
        }
    }

    @Test func installedIdentityReadsReplacementSidecars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("share/agterm")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("bin/agterm-linux")
        let version = metadata.appendingPathComponent("VERSION"), commit = metadata.appendingPathComponent("COMMIT")
        try "0.38.0\n".write(to: version, atomically: true, encoding: .utf8)
        #expect(LinuxAppMetadata.installedIdentity(executable: executable)?.version == "0.38.0")
        try "0.39.1\n".write(to: version, atomically: true, encoding: .utf8)
        try "new-build\n".write(to: commit, atomically: true, encoding: .utf8)
        #expect(LinuxAppMetadata.installedIdentity(executable: executable) == AppIdentity(version: "0.39.1", commit: "new-build"))
    }

    private func pump(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(1_000)
        }
    }
}
