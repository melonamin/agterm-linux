import Foundation
import agtermCore

private final class PresentationResponseBox: @unchecked Sendable {
    var value = ControlResponse(ok: false, error: "internal")
}

@MainActor
final class LinuxPresentationStream: PresentationSink {
    let session: UUID
    private let owner: LinuxControlStreamOwner
    private weak var server: ControlServer?
    private var subscriber: PresentationHub.SubscriberID?

    init(session: UUID, owner: LinuxControlStreamOwner, server: ControlServer) {
        self.session = session
        self.owner = owner
        self.server = server
    }

    var subscribed: Bool { subscriber != nil }

    func offer(_ frame: PresentationFrame) -> Bool {
        guard let line = try? PresentationCodec.encode(frame) else { return false }
        return owner.send(line)
    }

    func close(_: PresentationHub.CloseReason) { owner.shutdown() }
    func shutdown() { owner.shutdown() }

    func receive(_ line: Data) {
        guard let server, let frame = try? PresentationCodec.decode(line) else {
            owner.shutdown()
            return
        }
        if let subscriber {
            server.presentationHub.receive(frame, from: subscriber)
            return
        }
        guard case .hello(let hello) = frame.body,
              server.presentationSourceExists(session) else {
            owner.shutdown()
            return
        }
        subscriber = try? server.presentationHub.subscribe(session: session, hello: hello, sink: self) {
            gLibrary.store(forSession: self.session)?.presentationSnapshot(forSession: self.session)
                ?? PresentationSnapshot(status: nil, hud: nil)
        }
        if subscriber == nil { owner.shutdown() }
    }

    func closed() {
        if let subscriber { server?.presentationHub.unsubscribe(subscriber) }
        subscriber = nil
        server?.presentationStreams.removeAll { $0 === self }
    }
}

extension ControlServer {
    func openPresentationOnMain(_ target: String?) -> ControlResponse {
        let sem = DispatchSemaphore(value: 0)
        let box = PresentationResponseBox()
        runOnMain {
            MainActor.assumeIsolated {
                box.value = self.openPresentation(target)
                sem.signal()
            }
        }
        sem.wait()
        return box.value
    }

    func adoptPresentationOnMain(_ descriptor: Int32, session: UUID) {
        let sem = DispatchSemaphore(value: 0)
        runOnMain {
            MainActor.assumeIsolated {
                self.adoptPresentationStream(descriptor: descriptor, session: session)
                sem.signal()
            }
        }
        sem.wait()
    }

    @MainActor
    private func openPresentation(_ target: String?) -> ControlResponse {
        guard let target, !target.isEmpty else {
            return ControlResponse(ok: false, error: "zmx.present requires a session")
        }
        guard !target.unicodeScalars.contains(where: {
            $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7f
        }) else {
            return ControlResponse(ok: false, error: "invalid session")
        }
        let candidates = gWindows.values.flatMap { $0.store.workspaces.flatMap { $0.sessions.map(\.id) } }
        let id: UUID
        switch ControlResolve.resolve(target, candidates: candidates, active: nil) {
        case .resolved(let found): id = found
        case .ambiguous(let hits):
            return ControlResponse(ok: false,
                                   error: ControlResolve.ambiguousMessage(noun: "session", target: target, hits: hits))
        case .notFound:
            return ControlResponse(ok: false, error: ControlResolve.notFoundMessage(noun: "session", target: target))
        }
        guard let session = gLibrary.store(forSession: id)?.session(withID: id) else {
            return ControlResponse(ok: false, error: "no such session")
        }
        guard session.allPanesBackedByZmx else {
            return ControlResponse(ok: false,
                                   error: "session is not live-backed, so nothing can be attached to it")
        }
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
    }

    @MainActor
    private func adoptPresentationStream(descriptor: Int32, session: UUID) {
        let owner = LinuxControlStreamOwner(descriptor: descriptor)
        let stream = LinuxPresentationStream(session: session, owner: owner, server: self)
        presentationStreams.append(stream)
        attachPresentationHub()
        schedulePresentationHeartbeat()
        MainTimer.schedule(after: 5) { [weak stream] in
            if stream?.subscribed == false { stream?.shutdown() }
        }
        let inbound = DispatchSemaphore(value: 64)
        owner.start(onLine: { [weak stream] line in
            inbound.wait()
            runOnMain {
                MainActor.assumeIsolated { stream?.receive(line) }
                inbound.signal()
            }
        }, onClose: { [weak stream] in
            runOnMain { MainActor.assumeIsolated { stream?.closed() } }
        })
    }

    @MainActor
    func attachPresentationHub() {
        presentationHub.onPresenterLost = { [weak self] id in self?.presenterLost(forSession: id) }
        presentationHub.onPresenterFrame = { [weak self] id, body in self?.receivePresenterFrame(body, forSession: id) }
        overlayJobs.onFinished = { job in
            gLibrary?.store(forSession: job.session)?.finishRemoteOverlay(job)
        }
        for controller in gWindows.values {
            controller.store.presentationHub = presentationHub
            controller.store.overlayJobs = overlayJobs
        }
        for stream in presentationStreams where !presentationSourceExists(stream.session) { stream.shutdown() }
    }

    @MainActor
    func presentationSourceExists(_ id: UUID) -> Bool {
        gLibrary?.store(forSession: id)?.session(withID: id) != nil
    }

    @MainActor
    func shutdownPresentationStreams() {
        presentationHeartbeatCancel?()
        presentationHeartbeatCancel = nil
        for stream in presentationStreams { stream.shutdown() }
    }

    @MainActor
    private func schedulePresentationHeartbeat() {
        guard presentationHeartbeatCancel == nil else { return }
        presentationHeartbeatCancel = MainTimer.schedule(after: 10) { [weak self] in
            guard let self else { return }
            self.presentationHeartbeatCancel = nil
            guard !self.presentationStreams.isEmpty else { return }
            for stream in self.presentationStreams where !self.presentationSourceExists(stream.session) {
                stream.shutdown()
            }
            self.presentationHub.heartbeat()
            self.schedulePresentationHeartbeat()
        }
    }

    @MainActor
    private func presenterLost(forSession id: UUID) {
        guard let controller = gWindows.values.first(where: { $0.store.session(withID: id) != nil }) else { return }
        let store = controller.store
        controller.takeBackRemoteAsk(forSession: id)
        store.remoteOverlayPresenterLost(forSession: id)
        controller.reconcile(focusActive: false)
    }

    @MainActor
    private func receivePresenterFrame(_ body: PresentationFrame.Body, forSession id: UUID) {
        guard let store = gLibrary?.store(forSession: id) else { return }
        switch body {
        case .askResolve(let answer): _ = store.resolveRemoteAsk(answer, forSession: id)
        case .askRejected(let ref) where store.isPresentingRemotely(ref, forSession: id):
            presenterLost(forSession: id)
        case .overlayRejected(let change): store.rejectRemoteOverlay(change.job, forSession: id)
        case .overlayClosed(let change): store.remoteOverlaySurfaceClosed(change.job, forSession: id)
        default: break
        }
    }
}
