import Foundation
import Testing
@testable import agtermCore

/// A store backed by a throwaway temp directory so mutation-time saves never
/// touch the real Application Support path. PersistenceStore creates the
/// directory lazily on first write.
@MainActor func makeStore() -> AppStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
    return AppStore(persistence: PersistenceStore(directory: dir))
}

@MainActor func makeHeadlessSession(split: Bool) -> (store: AppStore, session: Session) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
    let store = AppStore(persistence: PersistenceStore(directory: dir), paneFinalizer: nil, headless: true)
    let workspace = store.addWorkspace(name: "server")
    let session = store.addSession(toWorkspace: workspace.id, cwd: "/srv")!
    session.daemonBackedPanes = [session.paneIdentity]
    if split {
        session.hasSplit = true
        session.splitPaneIdentity = UUID()
        session.daemonBackedPanes.insert(session.splitPaneIdentity!)
    }
    return (store, session)
}

/// The same throwaway store, plus the Open Recent store it records closes into and the persistence it
/// writes through, for the paths that read back what a close or a restore persisted.
@MainActor func makeStoreWithRecentClosed() -> (AppStore, RecentClosedStore, PersistenceStore) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
    let recentClosed = RecentClosedStore(directory: dir)
    let persistence = PersistenceStore(directory: dir)
    return (AppStore(persistence: persistence, recentClosedStore: recentClosed), recentClosed, persistence)
}

@MainActor func addPageRow(to store: AppStore, workspace: UUID, overlay: HtmlOverlay, cwd: String = "/page",
                           backgroundColor: String? = nil) throws -> Session {
    let page = try #require(store.addSession(toWorkspace: workspace, cwd: cwd, content: .page))
    #expect(store.openHtmlOverlay(page.id, pane: nil, overlay: overlay, sizePercent: nil, backgroundColor: backgroundColor) == nil)
    return page
}

/// Records every `MainTimer` schedule made while it is installed, so a test can fire ONE of them. The seam
/// is process-global, so a recorder also catches the store's unrelated debouncers (the 0.3 s save, the
/// 0.1 s tree events) — a single pending slot would be clobbered by those, hence the ordered list and
/// selection by delay. Install it through `withFakeMainTimer`, never by hand.
@MainActor
final class TimerRecorder {
    private(set) var entries: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
    private(set) var cancelled: [Int] = []

    /// Every recorded delay, in schedule order.
    var delays: [TimeInterval] { entries.map(\.delay) }

    /// The FIRST entry armed with `delay`. Tests pick unmistakable delays so the lookup can never pick up
    /// an unrelated debouncer.
    func index(ofDelay delay: TimeInterval) -> Int? { entries.firstIndex { $0.delay == delay } }

    /// The MOST RECENT entry armed with `delay` — what a test wants after a reschedule armed a second one.
    func lastIndex(ofDelay delay: TimeInterval) -> Int? { entries.lastIndex { $0.delay == delay } }

    /// Fires a LIVE entry. Cancelling does not poison the recorded closure, so without this check a test
    /// that matched an already-cancelled entry would still "pass" — hiding exactly the over-cancel
    /// regression it exists to catch. A test that deliberately wants the late-fire case calls
    /// `fireEvenIfCancelled`.
    func fire(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!cancelled.contains(index), "timer entry \(index) was cancelled before this fire",
                sourceLocation: sourceLocation)
        entries[index].fire()
    }

    /// Fires an entry the host armed and something already cancelled — the "a late host fire must be
    /// inert" case.
    func fireEvenIfCancelled(_ index: Int) { entries[index].fire() }

    fileprivate func record(delay: TimeInterval, fire: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        entries.append((delay, fire))
        let index = entries.count - 1
        return { [weak self] in self?.cancelled.append(index) }
    }
}

/// Runs `body` with `MainTimer.scheduleTimer` swapped for a recording fake, restored on the way out.
///
/// `body` is SYNCHRONOUS by type, and that is the point: the seam is a process-global static and
/// swift-testing runs tests in parallel, so an `await` between install and restore would let a concurrent
/// test's timer land on this fake and starve. A non-async closure makes that unrepresentable rather than a
/// convention reviewers have to enforce.
@MainActor func withFakeMainTimer<R>(_ body: (TimerRecorder) throws -> R) rethrows -> R {
    let recorder = TimerRecorder()
    let original = MainTimer.scheduleTimer
    defer { MainTimer.scheduleTimer = original }
    MainTimer.scheduleTimer = { delay, fire in recorder.record(delay: delay, fire: fire) }
    return try body(recorder)
}

@MainActor struct CompanionGroup {
    let store: AppStore
    let work: Workspace
    let personal: Workspace
    let parent: Session
    let first: Session
    let second: Session
    let after: Session

    init() throws {
        store = makeStore()
        work = store.addWorkspace(name: "work")
        personal = store.addWorkspace(name: "personal")
        guard let parent = store.addSession(toWorkspace: work.id, cwd: "/parent"),
              let after = store.addSession(toWorkspace: work.id, cwd: "/after") else { throw CompanionGroupFailure.setup }
        self.parent = parent
        self.after = after
        first = try store.addCompanion(to: parent.id, options: CompanionOptions(cwd: "/first")).get()
        second = try store.addCompanion(to: parent.id, options: CompanionOptions(cwd: "/second")).get()
    }

    var order: [UUID] { store.workspaces[0].sessions.map(\.id) }
}

enum CompanionGroupFailure: Error {
    case setup
}

@MainActor
final class RecordingAttachLines: RemoteAttachLines {
    var panes: [(daemon: String, local: UUID)] = []
    var scratches: [String] = []
    var scratchLocals: [UUID] = []

    func paneAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID) -> String {
        panes.append((daemon, local))
        return "attach-pane \(daemon)"
    }

    func scratchAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID) -> String {
        scratches.append(daemon)
        scratchLocals.append(local)
        return "attach-scratch \(daemon)"
    }
}

final class SpySurface: PaneRoleMutableSurface {
    var teardownCount = 0
    var onTeardown: (() -> Void)?
    var promotedCount = 0
    var assignedRoles: [SwappablePaneRole] = []
    var paneToken: String
    var backedByZmx: Bool
    /// Defaults to a live terminal, the state a surface parked in a session slot reaches a beat later; the
    /// stranded-slot cases set it false.
    var isRealized = true
    init(paneToken: String = "", backedByZmx: Bool = false) {
        self.paneToken = paneToken
        self.backedByZmx = backedByZmx
    }
    func teardown() {
        teardownCount += 1
        onTeardown?()
    }
    func promoteToPrimaryPane() { promotedCount += 1 }
    func setPaneRole(_ role: SwappablePaneRole) { assignedRoles.append(role) }
}

let attachedEndpoint = ControlZmxEndpoint(executable: "/bin/zmx", socketDirectory: "/tmp/zmx")

@MainActor func addAttachedRow(to store: AppStore, workspace: UUID, host: String = "box", origin: String = "o1",
                               page: Bool = false, split: Bool = false, catalogOwned: Bool = false) throws -> Session {
    let row = try #require(store.addSession(toWorkspace: workspace, cwd: "/a", remoteHost: host, remoteSessionID: origin,
                                            content: page ? .page : .terminal))
    var daemons: [UUID: String] = page ? [:] : [row.paneIdentity: ZmxSupport.daemonName(for: UUID())]
    if split {
        let splitPane = UUID()
        row.hasSplit = true
        row.splitPaneIdentity = splitPane
        daemons[splitPane] = ZmxSupport.daemonName(for: UUID())
    }
    store.bindRemote(RemoteBinding(remoteSessionID: origin, daemonsByLocalPane: daemons, presentationVersion: 1,
                                   origin: RemoteBinding.Origin(host: host, endpoint: attachedEndpoint, sessionName: origin),
                                   catalogOwned: catalogOwned),
                     forSession: row.id)
    return row
}
