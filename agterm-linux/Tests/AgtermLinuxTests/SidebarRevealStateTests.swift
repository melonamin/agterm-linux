import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("sidebar reveal state")
struct SidebarRevealStateTests {
    @Test("a newly selected session reveals its owner once")
    func revealInsertsOwnerAndAdvancesGate() {
        var reveal = SidebarRevealState()
        let session = UUID()
        let workspace = UUID()
        reveal.revealIfSelectionChanged(selected: session, owner: workspace)
        #expect(reveal.transientlyExpandedWorkspaceIDs == [workspace])
        #expect(reveal.lastRevealedSelection == session)

        reveal.clearTransient(workspace)
        reveal.revealIfSelectionChanged(selected: session, owner: workspace)
        #expect(reveal.transientlyExpandedWorkspaceIDs.isEmpty)
    }

    @Test("a nil selection clears the gate so the same session reveals again")
    func nilSelectionClearsGate() {
        var reveal = SidebarRevealState()
        let session = UUID()
        let workspace = UUID()
        reveal.revealIfSelectionChanged(selected: session, owner: workspace)
        reveal.clearTransient(workspace)
        reveal.revealIfSelectionChanged(selected: nil, owner: nil)
        #expect(reveal.lastRevealedSelection == nil)

        reveal.revealIfSelectionChanged(selected: session, owner: workspace)
        #expect(reveal.transientlyExpandedWorkspaceIDs == [workspace])
    }

    @Test("an owner-less selection leaves the gate alone")
    func ownerlessSelectionLeavesGate() {
        var reveal = SidebarRevealState()
        let session = UUID()
        let workspace = UUID()
        reveal.revealIfSelectionChanged(selected: session, owner: workspace)
        reveal.clearTransient(workspace)

        reveal.revealIfSelectionChanged(selected: session, owner: nil)
        #expect(reveal.lastRevealedSelection == session)
        #expect(reveal.transientlyExpandedWorkspaceIDs.isEmpty)
    }

    @Test("reveals accumulate, clear per id or wholesale, and drop workspaces the store lost")
    @MainActor
    func clearingAndPruning() {
        let open = Workspace(name: "open")
        let store = AppStore(workspaces: [open])
        var reveal = SidebarRevealState()
        let closed = UUID()
        reveal.revealIfSelectionChanged(selected: UUID(), owner: open.id)
        reveal.revealIfSelectionChanged(selected: UUID(), owner: closed)
        #expect(reveal.transientlyExpandedWorkspaceIDs == [open.id, closed])

        reveal.clearTransient(open.id)
        #expect(reveal.transientlyExpandedWorkspaceIDs == [closed])

        _ = reveal.syncedExpansion(store: store)
        #expect(reveal.transientlyExpandedWorkspaceIDs.isEmpty)

        reveal.revealIfSelectionChanged(selected: UUID(), owner: open.id)
        reveal.clearAllTransient()
        #expect(reveal.transientlyExpandedWorkspaceIDs.isEmpty)
    }

    @Test("a fold made under a still-selected session survives a flagged round trip")
    @MainActor
    func foldSurvivesAFlaggedRoundTrip() {
        let buried = Session(initialCwd: "/tmp", customName: "buried")
        let folded = Workspace(name: "folded", sessions: [buried], isExpanded: false)
        let store = AppStore(workspaces: [folded], selectedSessionID: buried.id)
        store.setFlag(true, forSession: buried.id)
        var reveal = SidebarRevealState()
        #expect(reveal.syncedExpansion(store: store) == [folded.id])

        reveal.clearTransient(folded.id)
        #expect(reveal.syncedExpansion(store: store).isEmpty)

        store.setSidebarMode(.flagged)
        #expect(reveal.syncedExpansion(store: store).isEmpty)
        store.setSidebarMode(.tree)
        #expect(reveal.syncedExpansion(store: store).isEmpty)
    }

    @Test("a listed flagged-mode selection advances the gate, so the trip back to tree reveals nothing")
    @MainActor
    func listedFlaggedSelectionAdvancesTheGate() {
        let first = Session(initialCwd: "/tmp", customName: "first")
        let second = Session(initialCwd: "/tmp", customName: "second")
        let open = Workspace(name: "open", sessions: [first])
        let folded = Workspace(name: "folded", sessions: [second], isExpanded: false)
        let store = AppStore(workspaces: [open, folded], selectedSessionID: first.id)
        store.setFlag(true, forSession: second.id)
        var reveal = SidebarRevealState()
        #expect(reveal.syncedExpansion(store: store) == [open.id])

        store.setSidebarMode(.flagged)
        store.selectSession(second.id)
        #expect(reveal.syncedExpansion(store: store) == [open.id])
        #expect(reveal.lastRevealedSelection == second.id)
        store.setSidebarMode(.tree)
        #expect(reveal.syncedExpansion(store: store) == [open.id])
    }

    @Test("an unlisted flagged-mode selection clears the gate, so the trip back to tree reveals it")
    @MainActor
    func unlistedFlaggedSelectionClearsTheGate() {
        let first = Session(initialCwd: "/tmp", customName: "first")
        let second = Session(initialCwd: "/tmp", customName: "second")
        let open = Workspace(name: "open", sessions: [first])
        let folded = Workspace(name: "folded", sessions: [second], isExpanded: false)
        let store = AppStore(workspaces: [open, folded], selectedSessionID: first.id)
        var reveal = SidebarRevealState()
        #expect(reveal.syncedExpansion(store: store) == [open.id])

        store.setSidebarMode(.flagged)
        store.selectSession(second.id)
        #expect(reveal.syncedExpansion(store: store) == [open.id])
        #expect(reveal.lastRevealedSelection == nil)
        store.setSidebarMode(.tree)
        #expect(reveal.syncedExpansion(store: store) == [open.id, folded.id])
    }

    @Test("a nil selection in flagged mode clears the gate and leaves the overlay alone")
    @MainActor
    func nilFlaggedSelectionClearsTheGateOnly() {
        let buried = Session(initialCwd: "/tmp", customName: "buried")
        let folded = Workspace(name: "folded", sessions: [buried], isExpanded: false)
        let store = AppStore(workspaces: [folded], selectedSessionID: buried.id)
        var reveal = SidebarRevealState()
        #expect(reveal.syncedExpansion(store: store) == [folded.id])

        store.setSidebarMode(.flagged)
        store.selectSession(nil)
        #expect(reveal.syncedExpansion(store: store) == [folded.id])
        #expect(reveal.lastRevealedSelection == nil)
    }

    @Test("collapsing another workspace keeps a reveal; collapsing the revealed one folds it for good")
    @MainActor
    func perWorkspaceCollapsePreservesOtherReveal() {
        let buried = Session(initialCwd: "/tmp", customName: "buried")
        let other = Workspace(name: "other", sessions: [Session(initialCwd: "/tmp")])
        let folded = Workspace(name: "folded", sessions: [buried], isExpanded: false)
        let store = AppStore(workspaces: [other, folded], selectedSessionID: buried.id)
        var reveal = SidebarRevealState()
        #expect(reveal.syncedExpansion(store: store) == [other.id, folded.id])

        // Reproduces `AppController.setWorkspaceExpanded` by hand; the setter's own routing is untested.
        reveal.clearTransient(other.id)
        store.setWorkspaceExpanded(other.id, expanded: false)
        #expect(reveal.syncedExpansion(store: store) == [folded.id])

        reveal.clearTransient(folded.id)
        store.setWorkspaceExpanded(folded.id, expanded: false)
        #expect(reveal.syncedExpansion(store: store).isEmpty)
        store.setFlag(true, forSession: buried.id)
        #expect(reveal.syncedExpansion(store: store).isEmpty)
    }

    @Test("the effective set is the persisted set widened by the overlay")
    @MainActor
    func effectiveSetUnionsPersistedAndTransient() {
        let open = Workspace(name: "open")
        let folded = Workspace(name: "folded", isExpanded: false)
        let other = Workspace(name: "other", isExpanded: false)
        let workspaces = [open, folded, other]
        var reveal = SidebarRevealState()
        #expect(reveal.effectiveExpandedIDs(workspaces: workspaces) == [open.id])

        reveal.revealIfSelectionChanged(selected: UUID(), owner: folded.id)
        #expect(reveal.effectiveExpandedIDs(workspaces: workspaces) == [open.id, folded.id])

        reveal.clearTransient(folded.id)
        #expect(reveal.effectiveExpandedIDs(workspaces: workspaces) == [open.id])
    }

    @Test("collapsing a revealed workspace folds it even though the store write is a no-op")
    @MainActor
    func clearingBeforeANoOpStoreWriteCollapses() {
        let folded = Workspace(name: "folded", isExpanded: false)
        let store = AppStore(workspaces: [folded])
        var reveal = SidebarRevealState()
        reveal.revealIfSelectionChanged(selected: UUID(), owner: folded.id)
        #expect(reveal.effectiveExpandedIDs(workspaces: store.workspaces) == [folded.id])

        let expanded = reveal.effectiveExpandedIDs(workspaces: store.workspaces).contains(folded.id)
        reveal.clearTransient(folded.id)
        store.setWorkspaceExpanded(folded.id, expanded: !expanded)
        #expect(store.workspaces[0].isExpanded == false)
        #expect(reveal.effectiveExpandedIDs(workspaces: store.workspaces).isEmpty)
    }

    /// Mirrors `AppController.toggleCurrentWorkspaceCollapse`, whose palette title reads the same property:
    /// with no sidebar on screen there are no rows to mirror, so both fall back to the persisted flag.
    @Test("with the sidebar hidden the current-workspace toggle still expands a revealed workspace")
    @MainActor
    func hiddenSidebarTogglesAgainstThePersistedFlag() {
        let buried = Session(initialCwd: "/tmp", customName: "buried")
        let folded = Workspace(name: "folded", sessions: [buried], isExpanded: false)
        let store = AppStore(workspaces: [folded], selectedSessionID: buried.id)
        var reveal = SidebarRevealState()
        store.noteSidebarExpansion(reveal.syncedExpansion(store: store))
        #expect(!store.isCurrentWorkspaceCollapsed)

        store.setSidebarVisible(false)
        #expect(store.isCurrentWorkspaceCollapsed)
        reveal.clearTransient(folded.id)
        store.setWorkspaceExpanded(folded.id, expanded: store.isCurrentWorkspaceCollapsed)
        #expect(store.workspaces[0].isExpanded)
    }

    @Test("the mirror spans every workspace, so a current workspace the focus filter hid reads its reveal")
    @MainActor
    func mirrorSpansAFilteredOutCurrentWorkspace() {
        let buried = Session(initialCwd: "/tmp", customName: "buried")
        let open = Workspace(name: "open", sessions: [Session(initialCwd: "/tmp")])
        let folded = Workspace(name: "folded", sessions: [buried], isExpanded: false)
        let store = AppStore(workspaces: [open, folded], selectedSessionID: buried.id)
        var reveal = SidebarRevealState()
        store.noteSidebarExpansion(reveal.syncedExpansion(store: store))

        store.selectSession(nil)
        store.setFocusMembership(open.id, member: true)
        store.setFocusEnabled(true)
        #expect(store.visibleWorkspaces.map(\.id) == [open.id])
        #expect(store.currentWorkspaceID == folded.id)

        store.noteSidebarExpansion(reveal.syncedExpansion(store: store))
        #expect(!store.isCurrentWorkspaceCollapsed)
    }
}
