import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite @MainActor
struct LinuxRootSessionsTests {
    @Test func rootSessionsPrecedeWorkspacesWithoutAHeaderOrCollapse() throws {
        let store = AppStore()
        let named = store.addWorkspace(name: "Project")
        store.ensureRoot()
        let root = try #require(store.rootWorkspace)
        let session = try #require(store.addSession(toWorkspace: root.id, cwd: "/"))
        let snapshot = SidebarSnapshot.desired(from: store, settings: AppSettings(), renaming: nil,
                                               expandedWorkspaceIDs: [])
        let first = try #require(snapshot.sections.first)
        #expect(first.key == .workspace(root.id))
        #expect(first.rows == [session.id])
        #expect(first.header == nil)
        #expect(first.expanded)
        #expect(snapshot.sections.last?.key == .workspace(named.id))
    }

    @Test func anEmptyRootHasNoSidebarSection() {
        let store = AppStore()
        let named = store.addWorkspace(name: "Project")
        store.ensureRoot()
        let snapshot = SidebarSnapshot.desired(from: store, settings: AppSettings(), renaming: nil,
                                               expandedWorkspaceIDs: [])
        #expect(snapshot.sections.map(\.key) == [.workspace(named.id)])
    }

    @Test func flaggedRootSessionsKeepTheirHeaderlessTopPosition() throws {
        let store = AppStore()
        let named = store.addWorkspace(name: "Project")
        let other = try #require(store.addSession(toWorkspace: named.id, cwd: "/"))
        store.ensureRoot()
        let root = try #require(store.rootWorkspace)
        let session = try #require(store.addSession(toWorkspace: root.id, cwd: "/"))
        store.setFlag(true, forSessions: [session.id, other.id])
        store.setSidebarMode(.flagged)
        var settings = AppSettings()
        settings.flaggedViewLayout = FlaggedViewLayout.tree.rawValue
        let snapshot = SidebarSnapshot.desired(from: store, settings: settings, renaming: nil,
                                               expandedWorkspaceIDs: [])
        #expect(snapshot.sections.first?.key == .workspace(root.id))
        #expect(snapshot.sections.first?.header == nil)
        #expect(snapshot.sections.first?.rows == [session.id])
        #expect(snapshot.sections.first?.expanded == true)
    }
}
