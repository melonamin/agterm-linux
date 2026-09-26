import Foundation
import agtermCore

@MainActor
final class LinuxOverlayJobStream {
    let job: String
    private let owner: LinuxControlStreamOwner
    private weak var server: ControlServer?

    init(job: String, owner: LinuxControlStreamOwner, server: ControlServer) {
        self.job = job
        self.owner = owner
        self.server = server
    }

    func send(_ frame: OverlayJobFrame) {
        guard let line = try? frame.line(), owner.send(line) else { owner.shutdown(); return }
    }

    func receive(_ line: Data) {
        guard let jobs = server?.overlayJobs,
              let frame = try? JSONDecoder().decode(OverlayJobFrame.self, from: line) else {
            owner.shutdown()
            return
        }
        switch frame {
        case .started: jobs.started(job)
        case .exited(let code): jobs.finish(job, .exited(code))
        case .canceled: jobs.finish(job, .canceled)
        case .launchFailed: jobs.finish(job, .launchFailed)
        case .context, .cancel: owner.shutdown()
        }
    }

    func shutdown() { owner.shutdown() }

    func closed() {
        server?.overlayJobs.helperGone(job)
        if server?.overlayJobStreams[job] === self { server?.overlayJobStreams[job] = nil }
    }
}

extension ControlServer {
    func claimOverlayJobOnMain(_ target: String?) -> ControlResponse {
        let sem = DispatchSemaphore(value: 0)
        let box = OverlayClaimBox()
        runOnMain {
            MainActor.assumeIsolated {
                box.value = self.claimOverlayJob(target)
                sem.signal()
            }
        }
        sem.wait()
        return box.value
    }

    func adoptOverlayJobOnMain(_ descriptor: Int32, job: String) {
        let sem = DispatchSemaphore(value: 0)
        runOnMain {
            MainActor.assumeIsolated {
                self.adoptOverlayJobStream(descriptor: descriptor, job: job)
                sem.signal()
            }
        }
        sem.wait()
    }

    func abandonOverlayJobOnMain(_ job: String) {
        runOnMain { MainActor.assumeIsolated { self.overlayJobs.helperGone(job) } }
    }

    @MainActor
    private func claimOverlayJob(_ target: String?) -> ControlResponse {
        guard let target, UUID(uuidString: target) != nil else {
            return ControlResponse(ok: false, error: target == nil
                ? "session.overlay.job.run requires a job id" : "invalid job id")
        }
        guard overlayJobs.claim(target, cancel: { [weak self] in self?.cancelJobHelper(target) }) != nil else {
            return ControlResponse(ok: false, error: "job not claimable")
        }
        scheduleOverlayJobExpiry(after: OverlayJobs.startWindow)
        return ControlResponse(ok: true, result: ControlResult(id: target))
    }

    @MainActor
    private func adoptOverlayJobStream(descriptor: Int32, job: String) {
        let owner = LinuxControlStreamOwner(descriptor: descriptor)
        let stream = LinuxOverlayJobStream(job: job, owner: owner, server: self)
        overlayJobStreams[job] = stream
        let inbound = DispatchSemaphore(value: 16)
        owner.start(onLine: { [weak stream] line in
            inbound.wait()
            runOnMain {
                MainActor.assumeIsolated { stream?.receive(line) }
                inbound.signal()
            }
        }, onClose: { [weak stream] in
            runOnMain { MainActor.assumeIsolated { stream?.closed() } }
        })
        guard let claimed = overlayJobs.job(job), case .claimed = claimed.state else {
            stream.shutdown()
            return
        }
        stream.send(.context(claimed.context))
        if pendingJobCancels.remove(job) != nil { stream.send(.cancel) }
    }

    @MainActor
    private func cancelJobHelper(_ job: String) {
        guard let stream = overlayJobStreams[job] else {
            pendingJobCancels.insert(job)
            return
        }
        stream.send(.cancel)
    }

    @MainActor
    func openRemoteOverlay(in store: AppStore, sessionID: UUID,
                           options: ControlSessionOverlayOpenOptions) -> ControlResponse? {
        guard let session = store.session(withID: sessionID) else { return nil }
        let context = OverlayLaunchContext(
            command: options.command,
            cwd: OverlayLaunchContext.cwd(explicit: options.cwd, session: session, homeDirectory: NSHomeDirectory()),
            sessionEnvironment: SurfaceEnvironment.session(
                sessionID: sessionID, windowID: gLibrary.windowID(for: store),
                workspaceID: store.workspace(forSession: sessionID)?.id,
                socketPath: resolvedSocketPath, programVersion: LinuxAppMetadata.version))
        switch store.openRemoteOverlay(sessionID, options: options, context: context) {
        case .notPresented: return nil
        case .slotTaken:
            return ControlResponse(ok: false, error: options.pane == nil
                ? "overlay already open" : PaneOverlayError.alreadyOpen)
        case .paneMissing: return ControlResponse(ok: false, error: PaneOverlayError.paneNotVisible)
        case .tooLarge: return ControlResponse(ok: false, error: OverlayResultError.tooLarge)
        case .opened:
            scheduleOverlayJobExpiry(after: OverlayJobs.launchWindow)
            return ControlResponse(ok: true, result: ControlResult(id: sessionID.uuidString))
        }
    }

    @MainActor
    private func scheduleOverlayJobExpiry(after seconds: TimeInterval) {
        MainTimer.schedule(after: seconds + 0.1) { [weak self] in self?.overlayJobs.expire() }
    }

    @MainActor
    func shutdownOverlayJobs() {
        for stream in overlayJobStreams.values { stream.shutdown() }
        overlayJobStreams.removeAll()
    }
}

private final class OverlayClaimBox: @unchecked Sendable {
    var value = ControlResponse(ok: false, error: "internal")
}
