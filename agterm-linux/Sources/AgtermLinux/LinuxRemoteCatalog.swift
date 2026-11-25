import CGtk
import Foundation
import agtermCore

/// The GTK host of upstream's catalog mirror and operation receipts.
/// Blocking SSH runs on workers; all model and widget work returns through GLib.
@MainActor
final class LinuxRemoteCatalog: RemoteCatalogEffects {
    let windowID: UUID
    let host: String
    private let store: AppStore
    private let originWindow: UUID?
    private let transport = LinuxPresentationTransport()
    private var link: RemotePresentationLink?
    private var retry: (@MainActor () -> Void)?
    private var watchdog: (@MainActor () -> Void)?
    private var generation = 0
    private var attempt = 0
    private var lastFrame = Date()
    private var stopped = false
    private var lookedUp = Set<String>()
    private var redraw: (@MainActor () -> Void)?
    private var notice: OpaquePointer?
    private var leads: [UUID: ZmxLeadAttachment] = [:]
    var controller: AppController? { gWindows[windowID] }

    lazy var pool = SshConnectionPool(host: host, root: LinuxSshPoolRoot.path,
        key: "\(gControlServer.path)|\(windowID.uuidString)", automaticPreparation: false) { argv in
        await Task.detached { LinuxRemoteCommand.run(argv, deadline: 15).status }.value
    }

    lazy var mirror = RemoteCatalogMirror(host: host, store: store, effects: self,
        viewState: gLibrary.remoteViewState(for: windowID), pool: pool, originWindow: originWindow,
        claimOnOpen: gLibrary.takeOpenClaim(windowID))
    lazy var actions = RemoteCatalogActions(mirror: mirror, runner: { argv in
        let result = await Task.detached { LinuxRemoteCommand.run(argv, deadline: 8) }.value
        return (result.status, result.stdout)
    }, automaticLookups: false)

    init(windowID: UUID, source: WindowSource, store: AppStore) {
        self.windowID = windowID
        self.store = store
        host = source.host
        originWindow = source.originWindow
    }

    func start() {
        guard !stopped else { return }
        controller?.store.remoteActions = actions
        actions.onChange = { [weak self] in self?.lookupPending() }
        connect()
    }

    func stop(waitForConnections: Bool = false) {
        stopped = true
        generation += 1
        retry?(); watchdog?(); redraw?()
        retry = nil; watchdog = nil
        link?.stop(); link = nil
        actions.stop()
        for command in pool.close() {
            if waitForConnections { _ = LinuxRemoteCommand.run(command, deadline: 2) } else { Self.run(command) { _ in } }
        }
        _ = gLibrary.saveRemoteViewState(for: windowID)
    }

    func connect() {
        guard !stopped else { return }
        generation += 1
        let mine = generation
        retry?(); retry = nil
        watchdog?(); watchdog = nil
        link?.stop(); link = nil
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: ["version"]) else { return lost("invalid host") }
        runPooled(argv) { [weak self] result in
            guard let self, !stopped, mine == generation else { return }
            guard result.status == 0, let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)), reply.ok else {
                return lost("\(host) did not answer")
            }
            guard mirror.checkVersions(reply.result?.versions, mac: reply.result?.macCatalog, app: reply.result?.app),
                  let argv = try? RemoteSession.catalogCommand(host: host, controlPath: pool.lease("catalog")) else { return }
            mirror.subscribing()
            lastFrame = Date()
            let path = pool.lease("catalog")
            let pooled = LinuxPooledTransport(pool: pool, user: "catalog", path: path, inner: transport)
            link = pooled.open(argv, onLine: { [weak self] line in self?.receive(line, generation: mine) },
                                  onClose: { [weak self] reason in
                guard let self, mine == generation, !stopped else { return }
                lost(reason)
            })
            send(.hello(CatalogHello(version: CatalogCodec.version, pageRows: true, window: originWindow?.uuidString)))
            armWatchdog()
        }
    }

    private func receive(_ line: Data, generation mine: Int) {
        guard !stopped, mine == generation else { return }
        lastFrame = Date()
        guard let frame = try? CatalogCodec.decode(line) else { return lost("invalid catalog frame") }
        if case .refused(let reason, false) = frame { return lost(reason) }
        if let reply = mirror.receive(frame) { send(reply) }
        if case .snapshot = frame {
            lookedUp.removeAll()
            for row in store.workspaces.flatMap(\.sessions) { LinuxAttachedRestore.pageRefusals.remove(row.id) }
        }
        if case .commit = frame { lookedUp.removeAll() }
        lookupPending()
        if mirror.needsSnapshot { return lost("catalog revisions changed") }
        if mirror.state == .connected { attempt = 0 }
        if mirror.state.isRefused { generation += 1; link?.stop(); link = nil }
    }

    private func send(_ frame: CatalogFrame) {
        if let data = try? CatalogCodec.encode(frame) { link?.send(data) }
    }

    private func lost(_ reason: String) {
        guard !stopped, !mirror.state.isRefused else { return }
        generation += 1
        link?.stop(); link = nil
        watchdog?(); watchdog = nil
        mirror.connectionLost(reason)
        let delays: [TimeInterval] = [1, 2, 5, 10, 30]
        let delay = delays[min(attempt, delays.count - 1)]
        attempt += 1
        retry?()
        retry = MainTimer.schedule(after: delay) { [weak self] in self?.connect() }
    }

    private func armWatchdog() {
        watchdog = MainTimer.schedule(after: 10) { [weak self] in
            guard let self, !stopped else { return }
            if Date().timeIntervalSince(lastFrame) > 30 { return lost("catalog stream went silent") }
            armWatchdog()
        }
    }

    private func lookupPending() {
        for (id, words) in actions.pendingLookups where lookedUp.insert(id).inserted {
            guard let argv = try? RemoteSession.controlCommand(host: host, arguments: words) else { continue }
            runPooled(argv) { [weak self] result in self?.actions.acceptLookup(result, operation: id) }
        }
    }

    static func run(_ argv: [String], completion: @escaping @MainActor (RemoteCommandResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LinuxRemoteCommand.run(argv, deadline: 8)
            runOnMain { MainActor.assumeIsolated { completion(result) } }
        }
    }

    func runPooled(_ argv: [String], completion: @escaping @MainActor (RemoteCommandResult) -> Void) {
        let slot = pool.leaseOnce()
        LinuxSshPoolRoot.prepare(pool, path: slot.path) { [pool] ready in
            guard ready else {
                pool.release(slot.user)
                return completion(RemoteCommandResult(status: 255, stdout: "", stderr: "no connection to \(pool.host)"))
            }
            var command = argv
            command.insert(contentsOf: ["-o", "ControlPath=" + slot.path], at: 1)
            Self.run(command) { response in pool.release(slot.user); completion(response) }
        }
    }

    func perform(_ request: ControlRequest, completion: @escaping @MainActor (ControlResponse) -> Void) {
        guard let controller else { return completion(ControlResponse(ok: false, error: "window not open")) }
        switch RemoteOperation.parse(request, in: controller.store) {
        case .refused(let response): completion(response)
        case .operation(let operation, let select):
            switch actions.prepare(operation) {
            case .refused(let response): completion(response)
            case .ready(let prepared):
                actions.send(prepared, selectingCreated: select, launch: runPooled, completion: completion)
            }
        }
    }

    func attachCommand(host: String, pane: CatalogPane, claim: Bool) -> String {
        let lead = ZmxLeadAttachment(claim: claim, reclaim: ZmxLeadBook.shared.pendingReclaim(pane: pane.identity))
        leads[pane.identity] = lead
        ZmxLeadBook.shared.begin(lead, pane: pane.identity)
        let path = pool.lease("pane:\(pane.identity)")
        LinuxSshPoolRoot.prepare(pool, path: path) { _ in }
        return (try? RemoteSession.attachPaneCommand(host: host, endpoint: pane.endpoint, daemon: pane.daemon,
                                                    session: pane.daemon, pane: .left, lead: lead, controlPath: path))
            ?? RemoteSession.endedCommand(host: host)
    }

    func scratchAttachCommand(host: String, pane: CatalogPane) -> String {
        let lead = ZmxLeadAttachment(claim: false, reclaim: ZmxLeadBook.shared.pendingReclaim(pane: pane.identity))
        ZmxLeadBook.shared.begin(lead, pane: pane.identity)
        let path = pool.lease("pane:\(pane.identity)")
        LinuxSshPoolRoot.prepare(pool, path: path) { _ in }
        return (try? RemoteSession.attachPaneCommand(host: host, endpoint: pane.endpoint, daemon: pane.daemon,
                                             session: pane.daemon, pane: .scratch, lead: lead, controlPath: path)) ?? RemoteSession.endedCommand(host: host)
    }

    private func scheduleRedraw() {
        guard redraw == nil else { return }
        redraw = MainTimer.schedule(after: 0) { [weak self] in
            guard let self, !stopped else { return }
            redraw = nil
            controller?.reconcile(focusActive: false)
        }
    }

    func catalogRowAdded(_ session: Session) { scheduleRedraw() }
    func catalogRowRemoved(_ sessionID: UUID) { scheduleRedraw() }
    func catalogRowEnded(_ sessionID: UUID) { controller?.remoteClients.removeValue(forKey: sessionID)?.stop() }

    func catalogPaneNeedsAttach(_ identity: UUID, session id: UUID) {
        guard let controller, let session = controller.store.session(withID: id),
              let lead = leads[identity] else { return }
        let right = identity == session.splitPaneIdentity
        let surface = (right ? session.splitSurface : session.surface) as? GhosttySurface
        if let surface, let command = right ? session.splitInitialCommand : session.initialCommand {
            _ = controller.replacePane(surface, command: command,
                environment: surface.env.merging([ZmxLeadAttachment.nonceVariable: lead.nonce]) { _, new in new },
                wait: true, lead: lead)
        } else { controller.reconcile(focusActive: false) }
    }

    func catalogBound(_ catalogID: UUID) -> Bool {
        switch gLibrary.bindCatalog(catalogID, toWindow: windowID) {
        case .bound: return true
        case .duplicate(let other): openWindow(other); return false
        case .rebound: return true
        }
    }

    func catalogStateChanged(_ state: RemoteCatalogMirror.State) {
        guard let controller else { return }
        if notice == nil, let box = controller.contentBox {
            let label = OpaquePointer(gtk_label_new(nil))
            gtk_widget_add_css_class(W(label), "caption")
            gtk_widget_set_margin_top(W(label), 6)
            gtk_widget_set_margin_bottom(W(label), 6)
            gtk_box_prepend(cast(box), W(label))
            notice = label
        }
        if let notice {
            gtk_label_set_text(notice, state.windowNotice(host: host))
            gtk_widget_set_visible(W(notice), state == .connected ? 0 : 1)
        }
        controller.reconcile(focusActive: false)
    }

    func catalogViewStateChanged() { _ = gLibrary.saveRemoteViewState(for: windowID) }
    func catalogWorkspaceCollapsed(_ id: UUID) { controller?.store.setWorkspaceExpanded(id, expanded: false) }
    func catalogClaimLead(_ identity: UUID, session id: UUID) {
        guard let controller, let session = controller.store.session(withID: id),
              let surface = (identity == session.splitPaneIdentity ? session.splitSurface : session.surface) as? GhosttySurface else { return }
        _ = controller.reattachPane(surface, claim: true)
    }
}

@MainActor
enum LinuxRemoteCatalogs {
    static var windows: [UUID: LinuxRemoteCatalog] = [:]

    static func opened(_ id: UUID) {
        guard windows[id] == nil, let controller = gWindows[id], let source = gLibrary.windows.first(where: { $0.id == id })?.source else { return }
        let catalog = LinuxRemoteCatalog(windowID: id, source: source, store: controller.store)
        windows[id] = catalog
        catalog.start()
    }

    static func closed(_ id: UUID) { windows.removeValue(forKey: id)?.stop() }

    static func shutdown() {
        for catalog in windows.values { catalog.stop(waitForConnections: true) }
        windows.removeAll()
        try? FileManager.default.removeItem(atPath: LinuxSshPoolRoot.path)
    }
}
