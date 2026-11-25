import Foundation
import agtermCore

extension ControlServer: CatalogStreamHost {
    @MainActor var catalogHelloDeadline: TimeInterval { 5 }
    @MainActor var catalogHubs: [CatalogHub] { originCatalogs.values.map(\.hub) }
    @MainActor var originVersions: CatalogVersions {
        CatalogVersions(server: LinuxAppMetadata.version, protocolVersion: PresentationCodec.version, catalog: CatalogCodec.version,
                        live: gRestoreLaunchDecision.active == .live && gZmxClient != nil)
    }

    @MainActor
    func catalogSubscription(for hello: CatalogHello) -> CatalogSubscription {
        switch gLibrary.originCatalogStore(window: hello.window, liveActive: originVersions.live == true) {
        case .failure(let refusal): return .refuse(reason: refusal.message(host: ProcessInfo.processInfo.hostName), final: refusal.final)
        case .success(let origin): return .serve(originCatalog(origin.id, store: origin.store).hub, originVersions)
        }
    }

    @MainActor
    func originCatalog(_ id: UUID, store: AppStore) -> OriginCatalog {
        let catalog = originCatalogs[id] ?? {
            let shape = CatalogProjection(endpoint: gZmxClient?.endpoint ?? .init(executable: "", socketDirectory: "")) { pane in
                let count = MessageBus.shared.pending(for: pane)
                return count > 0 ? count : nil
            }
            let options = OriginCatalog.Options(epoch: originEpoch, staleTimeout: 30, shape: shape, versions: originVersions,
                recent: { gLibrary.recentClosedItems(inWindow: $0).map(ControlRecentItem.init) },
                schedule: { work in MainTimer.schedule(after: 0, work) })
            let created = OriginCatalog(window: id, options: options)
            created.projection.evidence = originEvidence
            originCatalogs[id] = created
            mailRelay.start()
            return created
        }()
        if catalog.store !== store { catalog.bind(store) }
        return catalog
    }

    @MainActor
    func originWindowClosed(_ id: UUID) {
        guard let catalog = originCatalogs[id] else { return }
        catalog.bind(nil)
        for stream in catalogStreams where stream.serves(catalog.hub) { stream.refuse(reason: "the origin window is closed", final: false) }
    }

    @MainActor
    func refreshOriginEvidence(completion: @escaping @MainActor (Bool) -> Void) {
        guard let client = gZmxClient else { return completion(false) }
        DispatchQueue.global(qos: .userInitiated).async {
            let observed = client.listSessions(timeout: 2)
            runOnMain { MainActor.assumeIsolated {
                guard let observed else { return completion(false) }
                let walk = gLibrary.paneClaims()
                let inventory = ZmxInventory.join(observed: observed, claims: walk.claims, inventoryComplete: walk.complete)
                let evidence = CatalogPaneEvidence(inventory: inventory)
                self.originEvidence = evidence
                for catalog in self.originCatalogs.values where catalog.projection.evidence != evidence { catalog.projection.evidence = evidence }
                completion(true)
            } }
        }
    }

    /// Takes the descriptor after the one-shot reply; the shared stream retains all protocol checks.
    @MainActor
    func adoptLinuxCatalogStream(_ descriptor: Int32) {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: CatalogStream.limits)
        let stream = CatalogStream(owner: owner, host: self)
        catalogStreams.append(stream)
        MainTimer.schedule(after: catalogHelloDeadline) { [weak stream] in
            if stream?.subscribed == false { stream?.shutdown() }
        }
        let inbound = DispatchSemaphore(value: 64)
        owner.start(onLine: { [weak stream] line in
            inbound.wait()
            runOnMain { MainActor.assumeIsolated { stream?.receive(line) }; inbound.signal() }
        }, onClose: { [weak stream] in
            runOnMain { MainActor.assumeIsolated { stream?.closed() } }
        })
        scheduleLinuxCatalogHeartbeat()
    }

    @MainActor
    private func scheduleLinuxCatalogHeartbeat() {
        guard nativeCatalogHeartbeat == nil else { return }
        nativeCatalogHeartbeat = MainTimer.schedule(after: 10) { [weak self] in
            guard let self else { return }
            nativeCatalogHeartbeat = nil
            guard !catalogStreams.isEmpty else { return }
            refreshOriginEvidence { _ in }
            for hub in catalogHubs { hub.heartbeat() }
            scheduleLinuxCatalogHeartbeat()
        }
    }

    func handleCatalogSubscribe(_ descriptor: Int32) -> Bool {
        let box = LinuxOriginResponse(), ready = DispatchSemaphore(value: 0)
        runOnMain { MainActor.assumeIsolated {
            guard self.originVersions.live == true else {
                box.value = ControlResponse(ok: false, error: "Live sessions are required to serve a remote window")
                ready.signal(); return
            }
            self.refreshOriginEvidence { success in
                box.value = ControlResponse(ok: success, error: success ? nil : "could not list live sessions")
                ready.signal()
            }
        } }
        ready.wait()
        guard writeResponse(descriptor, box.value), box.value.ok else { return false }
        runOnMain { MainActor.assumeIsolated { self.adoptLinuxCatalogStream(descriptor); ready.signal() } }
        ready.wait()
        return true
    }

    func performOriginRequest(_ request: ControlRequest) -> ControlResponse? {
        guard request.args?.opID != nil || request.cmd == .catalogOp else { return nil }
        let box = LinuxOriginResponse(), ready = DispatchSemaphore(value: 0)
        runOnMain { MainActor.assumeIsolated {
            let finish: @MainActor (ControlResponse) -> Void = { box.value = $0; ready.signal() }
            switch gLibrary.originCatalogStore(window: request.args?.window, liveActive: self.originVersions.live == true) {
            case .failure(let refusal): finish(ControlResponse(ok: false, error: refusal.message(host: ProcessInfo.processInfo.hostName)))
            case .success(let origin):
                self.refreshOriginEvidence { _ in
                    let catalog = self.originCatalog(origin.id, store: origin.store)
                    let host = catalog.operation(in: gLibrary) { [weak self] in self?.runOriginPlain($0, window: origin.id) ?? ControlResponse(ok: false) }
                    if request.cmd == .catalogOp {
                        guard let id = request.target, CatalogReceipt.isValidOpID(id) else {
                            return finish(ControlResponse(ok: false, error: "catalog.op requires an operation id"))
                        }
                        guard (request.args?.epoch == nil) == (request.args?.rev == nil) else {
                            return finish(ControlResponse(ok: false, error: "catalog.op takes epoch and rev together"))
                        }
                        let position = request.args?.epoch.flatMap { epoch in request.args?.rev.map { CatalogPosition(epoch: epoch, rev: $0) } }
                        finish(catalog.book.lookup(id, sent: position, host: host))
                    } else if let opID = request.args?.opID {
                        catalog.book.serve(request, opID: opID, host: host, run: { [weak self] request, done in
                            guard let self else { return done(ControlResponse(ok: false)) }
                            var plain = request
                            var args = plain.args ?? ControlArgs()
                            (args.opID, args.epoch, args.rev, args.panes, args.scratch) = (nil, nil, nil, nil, nil)
                            args.window = origin.id.uuidString
                            plain.args = args
                            runLinuxOriginOperation(plain, catalog: catalog, completion: done)
                        }, completion: finish)
                    }
                }
            }
        } }
        ready.wait()
        return box.value
    }

    @MainActor
    private func runOriginPlain(_ request: ControlRequest, window: UUID) -> ControlResponse {
        guard let controller = gWindows[window] else { return ControlResponse(ok: false, error: "the window closed") }
        var plain = request
        if [.sessionNew, .sessionCompanionNew, .sessionCompanionDuplicate].contains(request.cmd) {
            var args = plain.args ?? ControlArgs()
            args.noSelect = true
            plain.args = args
        }
        return controller.store.preservingSelection { controller.handleControl(plain) }
    }

    @MainActor
    private func runLinuxOriginOperation(_ request: ControlRequest, catalog: OriginCatalog,
                                         completion: @escaping @MainActor (ControlResponse) -> Void) {
        guard let controller = gWindows[catalog.window] else { return completion(ControlResponse(ok: false, error: "the window closed")) }
        let store = controller.store
        let finish: @MainActor (ControlResponse) -> Void = { [weak self] response in
            guard let self else { return completion(response) }
            guard response.ok else { return completion(response) }
            let references = [response.result?.id, response.result?.parent, request.target].compactMap { $0 }
                + (response.result?.recentOpen?.restored ?? []) + (request.args?.targets ?? [])
            self.prepareOriginPanes(in: controller, sessions: Set(references.compactMap(UUID.init(uuidString:)))) { failure in
                if let failure { return completion(ControlResponse(ok: false, result: response.result, error: failure)) }
                self.refreshOriginEvidence { _ in completion(response) }
            }
        }
        switch request.cmd {
        case .sessionRestart: controller.restartPane(request, completion: finish)
        case .sessionUndo:
            let restored = store.preservingSelection { request.target.flatMap(UUID.init(uuidString:)).map { store.undoPendingClose($0) } == true }
            controller.reconcile(focusActive: false)
            finish(ControlResponse(ok: restored, error: restored ? nil : AppStore.closeNoLongerUndoable))
        case .recentClear:
            gLibrary.clearRecentClosedItems(inWindow: catalog.window)
            finish(ControlResponse(ok: gLibrary.recentClosedItems(inWindow: catalog.window).isEmpty))
        case .recentOpen:
            let items = gLibrary.recentClosedItems(inWindow: catalog.window)
            switch RecentClosedTarget.resolve(request.target, in: items) {
            case .failure(let error): finish(controller.err(error.message))
            case .success(let id):
                let before = Set(store.workspaces.flatMap(\.sessions).map(\.id))
                let reopened = store.preservingSelection { gLibrary.reopenRecentClosed(id, inWindow: catalog.window) }
                switch reopened {
                case .failure(let error): finish(controller.err(error.message))
                case .success(let outcome):
                    guard let item = items.first(where: { $0.id == id }) else { return finish(controller.err("could not reopen entry")) }
                    controller.reconcile(focusActive: false)
                    let restored = store.workspaces.flatMap(\.sessions).map(\.id).filter { !before.contains($0) }.map(\.uuidString)
                    finish(ControlResponse(ok: true, result: ControlResult(recentOpen: ControlRecentOpen(item: ControlRecentItem(item),
                        window: outcome.window.uuidString, complete: outcome.complete, restored: restored))))
                }
            }
        default: finish(runOriginPlain(request, window: catalog.window))
        }
    }

}

private final class LinuxOriginResponse: @unchecked Sendable {
    var value = ControlResponse(ok: false, error: "internal")
}
