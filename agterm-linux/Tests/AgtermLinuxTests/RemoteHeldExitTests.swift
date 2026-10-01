import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Remote held exits")
@MainActor
struct RemoteHeldExitTests {
    final class HeldSurface: TerminalSurface {
        var isRealized = true
        var paneToken: String { "" }
        func teardown() {}
        func promoteToPrimaryPane() {}
    }

    final class Host {
        var closed: [(local: UUID, held: Bool, closable: Bool)] = []
        var reconciles: [Bool] = []
    }

    static let remoteLeft = UUID()
    static let remoteRight = UUID()

    let store: AppStore
    let session: Session
    let host = Host()
    let primary = HeldSurface()
    let split = HeldSurface()

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let workspace = Workspace(name: "work", sessions: [])
        store = AppStore(workspaces: [workspace], selectedSessionID: nil,
                         persistence: PersistenceStore(directory: directory))
        session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", remoteHost: "buildbox"))
    }

    private func bind(split hasSplit: Bool = true) throws {
        session.surface = primary
        var daemons = [session.paneIdentity: ZmxSupport.daemonName(for: Self.remoteLeft)]
        if hasSplit {
            store.toggleSplit(session.id)
            session.splitSurface = split
            daemons[try #require(session.splitPaneIdentity)] = ZmxSupport.daemonName(for: Self.remoteRight)
        }
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: daemons, presentationVersion: 1),
                         forSession: session.id)
    }

    private var router: LinuxRemoteHeldExitRouter {
        let store = store
        let host = host
        return LinuxRemoteHeldExitRouter(store: store, closeRemovedPane: { local, id in
            host.closed.append((local, store.remotePaneIsHeld(local, forSession: id),
                                store.canCloseRemovedRemotePane(local, forSession: id)))
        }, reconcile: { host.reconciles.append($0) })
    }

    private func showOverlay(pane: PresentationPane?) -> HeldSurface {
        let overlay = PresentationOverlay(job: "j1", pane: pane, sizePercent: nil, backgroundColor: nil,
                                          follow: false, wait: true)
        #expect(store.presentReplicaOverlay(overlay, command: "job", forSession: session.id) { _ in })
        let surface = HeldSurface()
        if pane == nil {
            session.overlaySurface = surface
        } else {
            session.setPaneOverlaySurface(surface, pane: .right)
        }
        return surface
    }

    @Test("a held replica pane is recorded held, offered for removal, then redrawn without focus")
    func heldReplicaPane() throws {
        try bind()

        router.paneHeld(split, forSession: session.id)

        let local = try #require(session.splitPaneIdentity)
        #expect(store.remotePaneIsHeld(local, forSession: session.id))
        #expect(host.closed.map(\.local) == [local])
        #expect(host.closed.first?.held == true)
        #expect(host.reconciles == [false])
    }

    @Test("a removal that arrived before the exit is closable once the exit is held")
    func removalBeforeHeldExitCompletes() throws {
        try bind(split: false)
        let removal = PresentationLayout(panes: [Self.remoteRight], primary: Self.remoteRight, shown: false)
        #expect(store.applyRemoteLayout(removal, forSession: session.id) == [session.paneIdentity])
        #expect(!store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))

        router.paneHeld(primary, forSession: session.id)

        #expect(host.closed.count == 1)
        #expect(host.closed.first?.local == session.paneIdentity)
        #expect(host.closed.first?.held == true)
        #expect(host.closed.first?.closable == true)
        #expect(host.reconciles == [false])
    }

    @Test("a held session-wide replica overlay marks its job ended")
    func heldSessionOverlay() throws {
        try bind()
        store.setRemoteConnection(.connected, forSession: session.id)
        let surface = showOverlay(pane: nil)

        router.overlayHeld(surface, forSession: session.id)

        #expect(session.overlayReplica?.ended == true)
        #expect(session.overlayActive)
        #expect(host.reconciles == [false])
    }

    @Test("a held pane replica overlay marks the job in its current slot ended")
    func heldPaneOverlay() throws {
        try bind()
        store.setRemoteConnection(.connected, forSession: session.id)
        let surface = showOverlay(pane: .identity(Self.remoteRight))

        router.overlayHeld(surface, forSession: session.id)

        #expect(session.paneOverlay(.right)?.replica?.ended == true)
        #expect(host.reconciles == [false])
    }

    @Test("an orphaned replica overlay closes on its held exit")
    func heldOrphanedOverlayCloses() throws {
        try bind()
        store.setRemoteConnection(.connected, forSession: session.id)
        let surface = showOverlay(pane: nil)
        store.setRemoteConnection(.failed("exit 255"), forSession: session.id)

        router.overlayHeld(surface, forSession: session.id)

        #expect(!session.overlayActive)
        #expect(host.reconciles == [false])
    }

    @Test("held exits redraw without focusing, so an inline rename keeps its entry", arguments: [0, 1, 2])
    func heldExitsNeverRequestFocus(kind: Int) throws {
        try bind()
        store.setRemoteConnection(.connected, forSession: session.id)
        switch kind {
        case 0: router.paneHeld(primary, forSession: session.id)
        case 1: router.overlayHeld(showOverlay(pane: nil), forSession: session.id)
        default: router.overlayHeld(showOverlay(pane: .identity(Self.remoteRight)), forSession: session.id)
        }

        #expect(host.reconciles == [false])
    }

    @Test("a surface outside the remote model makes no store call")
    func nonReplicaSurfacesAreIgnored() throws {
        store.toggleSplit(session.id)
        session.surface = primary
        session.splitSurface = split
        _ = store.openOverlay(session.id, command: "htop", wait: true)
        let overlay = HeldSurface()
        session.overlaySurface = overlay

        router.paneHeld(split, forSession: session.id)
        router.overlayHeld(overlay, forSession: session.id)

        #expect(host.closed.isEmpty)
        #expect(host.reconciles.isEmpty)
        #expect(session.overlayActive)
    }

    @Test("a stale overlay hook whose surface left its slot makes no store call", arguments: [false, true])
    func staleOverlayHook(paneSlot: Bool) throws {
        try bind()
        store.setRemoteConnection(.connected, forSession: session.id)
        let stale = showOverlay(pane: paneSlot ? .identity(Self.remoteRight) : nil)
        if paneSlot {
            session.setPaneOverlaySurface(HeldSurface(), pane: .right)
        } else {
            session.overlaySurface = HeldSurface()
        }

        router.overlayHeld(stale, forSession: session.id)

        let replica = paneSlot ? session.paneOverlay(.right)?.replica : session.overlayReplica
        #expect(replica?.ended == false)
        #expect(host.reconciles.isEmpty)
    }

    @Test("a pane no longer in its session's slots makes no store call")
    func stalePaneHook() throws {
        try bind()

        router.paneHeld(HeldSurface(), forSession: session.id)

        #expect(host.closed.isEmpty)
        #expect(host.reconciles.isEmpty)
    }
}
