import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux presenter frame routing")
@MainActor
struct LinuxPresenterFrameTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}
    }

    final class Host {
        var takeBacks: [UUID] = []
        var reconciles = 0
    }

    let session = Session(initialCwd: "/tmp")
    let store: AppStore
    let hub = PresentationHub(staleTimeout: 30)
    let jobs = OverlayJobs()
    let presenter = Sink()
    let host = Host()

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        store = AppStore(workspaces: [Workspace(name: "work", sessions: [session])], selectedSessionID: session.id,
                         persistence: PersistenceStore(directory: directory))
        store.presentationHub = hub
        store.overlayJobs = jobs
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: session.paneIdentity)
        let notice = try #require(ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):follower:1"))
        #expect(ZmxLeadBook.shared.apply(notice, pane: session.paneIdentity) == .follower)
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: presenter) {
            PresentationSnapshot(status: nil, hud: nil)
        }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
    }

    private var router: LinuxPresenterFrameRouter {
        let store = store
        let host = host
        return LinuxPresenterFrameRouter(store: store, takeBackAsk: { id in
            host.takeBacks.append(id)
            _ = store.takeBackRemoteAsk(forSession: id)
        }, reconcile: { host.reconciles += 1 })
    }

    private func presentAsk() throws -> PresentationAskRef {
        let ask = PendingAsk(id: UUID().uuidString, title: "deploy?",
                             buttons: [ControlAskButton(id: "yes", label: "Yes")], style: .terminal)
        #expect(store.presentAskRemotely(ask, in: session, paneIdentity: nil, window: UUID()) == true)
        return PresentationAskRef(id: ask.id, owner: try #require(session.askRemoteOwner))
    }

    private func openOverlay() throws -> String {
        let options = ControlSessionOverlayOpenOptions(command: "revdiff", cwd: nil, wait: false, sizePercent: nil,
                                                       backgroundColor: nil, follow: false, pane: nil)
        let context = OverlayLaunchContext(command: "revdiff", cwd: "/tmp", sessionEnvironment: [:])
        guard case .opened(let job) = store.openRemoteOverlay(session.id, options: options, context: context) else {
            throw OverlayNotOpened()
        }
        return job
    }

    private struct OverlayNotOpened: Error {}

    @Test("a rejected ask is taken back and the unclaimed overlay job keeps its slot")
    func askRejectedTakesBackOnlyTheAsk() throws {
        let job = try openOverlay()
        let ref = try presentAsk()

        router.receive(.askRejected(ref), forSession: session.id)

        #expect(host.takeBacks == [session.id])
        #expect(host.reconciles == 1)
        #expect(!session.askPresentedRemotely)
        #expect(session.askPending?.id == ref.id)
        guard case .unclaimed? = jobs.job(job)?.state else {
            Issue.record("job state \(String(describing: jobs.job(job)?.state))")
            return
        }
        #expect(session.remoteOverlays.slot(nil)?.job == job)
    }

    @Test("a rejection naming another ask changes nothing")
    func staleAskRejectedIsIgnored() throws {
        let ref = try presentAsk()

        router.receive(.askRejected(PresentationAskRef(id: ref.id, owner: ref.owner + 1)), forSession: session.id)

        #expect(host.takeBacks.isEmpty)
        #expect(host.reconciles == 0)
        #expect(session.askPresentedRemotely)
    }

    @Test("losing the presenter takes back the ask and cancels the unclaimed job")
    func presenterLostEndsBoth() throws {
        let job = try openOverlay()
        _ = try presentAsk()

        router.presenterLost(forSession: session.id)

        #expect(host.takeBacks == [session.id])
        #expect(host.reconciles == 1)
        #expect(jobs.job(job)?.state == .finished(.canceled))
    }

    @Test("a finished overlay job drops its queued helper cancel")
    func finishedJobDropsPendingCancel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = ControlServer(path: directory.appendingPathComponent("agterm.sock").path)
        defer { server.stop() }
        server.attachPresentationHub()
        let context = OverlayLaunchContext(command: "true", cwd: "/tmp", sessionEnvironment: [:])
        let job = server.overlayJobs.register(session: UUID(), pane: nil, owner: 1, context: context)
        #expect(server.overlayJobs.claim(job, cancel: { server.pendingJobCancels.insert(job) }) != nil)
        server.overlayJobs.cancel(job)
        #expect(server.pendingJobCancels == [job])

        server.overlayJobs.helperGone(job)

        #expect(server.pendingJobCancels.isEmpty)
    }
}
