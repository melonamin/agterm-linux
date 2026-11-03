import Foundation
import CGtk
import agtermCore

let pageLogger = LinuxStructuredLogger(category: "PageServe")

/// LinuxPageServeAdmission counts one kind of request a page channel has taken in and not finished. It never
/// blocks: a request past the limit is refused, so the reader keeps reading cancels and EOF behind it.
final class LinuxPageServeAdmission: Sendable {
    private let limit: Int
    private let taken = LinuxPageLock(0)

    init(limit: Int) { self.limit = limit }

    /// tryAcquire takes a slot, false when all are taken.
    func tryAcquire() -> Bool {
        taken.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func release() {
        taken.withLock { $0 -= 1 }
    }
}

/// LinuxPageServeStream is the channel a presenter's helper opened for one page this Mac handed over. It serves the
/// page's files from inside its grant and runs the page's bridge requests here, as a local page's would run.
/// The helper's connection closing, or sending what a helper never sends, ends the page; the presenter
/// subscription is not touched.
@MainActor
final class LinuxPageServeStream {
    private struct Transfers {
        var active: Set<Int> = []
        var cancelled: Set<Int> = []
    }

    let page: UUID
    /// companion is set for one attachment of a page companion, whose channel ends nothing but itself.
    let companion: CompanionPageServing?
    let resourceSlots = LinuxPageServeAdmission(limit: ControlServer.pageServeResourceLimit)
    let bridgeSlots = LinuxPageServeAdmission(limit: ControlServer.pageServeBridgeLimit)
    private let source: HtmlSource
    private let owner: LinuxControlStreamOwner
    private weak var server: ControlServer?
    // bridge calls have their own slots and queue, so they wait behind at most the chunks already queued for
    // the writer, never behind a whole file
    private let files = DispatchQueue(label: "com.umputun.agterm.pageserve.files")
    private let replies = DispatchQueue(label: "com.umputun.agterm.pageserve.replies")
    private let transfers = LinuxPageLock(Transfers())
    private var ending = false

    init(page: UUID, source: HtmlSource, owner: LinuxControlStreamOwner, server: ControlServer,
         companion: CompanionPageServing? = nil) {
        self.page = page
        self.companion = companion
        self.source = source
        self.owner = owner
        self.server = server
    }

    /// take handles one line on the reader thread: a cancel applies at once, a request takes a slot of its
    /// kind and runs on the main actor or is refused at once by id, and anything else ends the page. Nothing
    /// here waits, so cancels and EOF behind a request are always read.
    nonisolated func take(_ line: Data) {
        guard let frame = try? PageServeCodec.decode(line) else { return failOnMain("a malformed frame") }
        switch frame {
        case .cancel(let id):
            transfers.withLock { if $0.active.contains(id) { $0.cancelled.insert(id) } }
        case .resource(let id, _):
            guard resourceSlots.tryAcquire() else { return refuse(id) }
            transfers.withLock { _ = $0.active.insert(id) }
            runOnMain { MainActor.assumeIsolated { self.receive(frame) } }
        case .bridge(let id, _):
            guard bridgeSlots.tryAcquire() else { return refuse(id) }
            runOnMain { MainActor.assumeIsolated { self.receive(frame) } }
        case .head, .chunk, .end, .failure, .reply:
            failOnMain("a frame only this Mac sends")
        }
    }

    /// receive runs one admitted request; its slot is released once its last frame is queued for the writer.
    func receive(_ frame: PageServeFrame) {
        switch frame {
        case .resource(let id, let path): serve(id: id, path: path)
        case .bridge(let id, let request): relay(id: id, request: request)
        case .cancel, .head, .chunk, .end, .failure, .reply: break
        }
    }

    /// shutdown closes the channel without ending the page, which the caller already did or is doing.
    func shutdown() {
        ending = true
        owner.shutdown()
    }

    // a peer past the limit while the writer queue is full is not reading what it asked for, so the page ends
    // rather than the reader waiting or the refusals queueing without bound
    private nonisolated func refuse(_ id: Int) {
        guard let line = try? PageServeCodec.encode(.failure(id: id, error: PageServeFrame.busy)), owner.send(line) else {
            return failOnMain("more requests than it reads answers to")
        }
    }

    func closed() {
        if let companion {
            server?.companionPageStreams[companion.claim] = nil
            return
        }
        if server?.pageServeStreams[page] === self { server?.pageServeStreams[page] = nil }
        guard !ending else { return }
        server?.endRemotePage(page)
    }

    private nonisolated func failOnMain(_ reason: String) {
        runOnMain { MainActor.assumeIsolated { self.fail(reason) } }
    }

    private func fail(_ reason: String) {
        guard !ending else { return }
        pageLogger.notice("ending a page whose channel sent \(reason)")
        ending = true
        if companion == nil { server?.endRemotePage(page) }
        shutdown()
    }

    private func serve(id: Int, path: String) {
        let owner = owner, source = source, transfers = transfers, slots = resourceSlots
        files.async {
            Self.transfer(id: id, path: path, source: source, owner: owner, transfers: transfers)
            transfers.withLock {
                $0.active.remove(id)
                $0.cancelled.remove(id)
            }
            slots.release()
        }
    }

    // every admitted transfer ends in exactly one terminal frame, a cancelled one too, so the viewer frees its
    // request slot only when this side has
    nonisolated private static func transfer(id: Int, path: String, source: HtmlSource, owner: LinuxControlStreamOwner,
                                             transfers: LinuxPageLock<Transfers>) {
        let cancelled = { transfers.withLock { $0.cancelled.contains(id) } }
        let stop = { _ = sendWaiting(.failure(id: id, error: PageServeFrame.cancelled), owner) }
        guard !cancelled() else { return stop() }
        guard let file = RemotePageResources.resolve(path, source: source) else {
            _ = sendWaiting(.failure(id: id, error: "file is outside the page's folder"), owner)
            return
        }
        guard let handle = FileHandle(forReadingAtPath: file) else {
            _ = sendWaiting(.failure(id: id, error: "file cannot be read"), owner)
            return
        }
        defer { try? handle.close() }
        guard sendWaiting(.head(id: id, mimeType: mimeType(file)), owner) else { return }
        while !cancelled() {
            let data: Data?
            do {
                data = try handle.read(upToCount: PageServeCodec.maxChunkBytes)
            } catch {
                _ = sendWaiting(.failure(id: id, error: "file cannot be read"), owner)
                return
            }
            guard let data, !data.isEmpty else {
                _ = sendWaiting(.end(id: id), owner)
                return
            }
            guard sendWaiting(.chunk(id: id, data: data), owner) else { return }
        }
        stop()
    }

    private func relay(id: Int, request: String) {
        guard let server, let place = companion.map(server.companionPagePlace) ?? server.remotePagePlace(page) else {
            return reply(.failure(id: id, error: "page closed"))
        }
        if companion != nil, case .url = source { return reply(.failure(id: id, error: "a URL page has no bridge")) }
        let origin = HtmlBridgePage(window: place.window?.uuidString, session: place.session, pane: place.pane)
        let built: ControlRequest
        switch HtmlBridge.request(from: Data(request.utf8), page: origin) {
        case .failure(let refusal): return reply(.failure(id: id, error: refusal.message))
        case .success(let request): built = request
        }
        let owner = owner, slots = bridgeSlots
        replies.async {
            let response = server.performRequest(built)
            let frame = (try? JSONEncoder().encode(response)).map {
                PageServeFrame.reply(id: id, response: String(decoding: $0, as: UTF8.self))
            } ?? .failure(id: id, error: "reply could not be encoded")
            _ = Self.sendWaiting(frame, owner)
            slots.release()
        }
    }

    private func reply(_ frame: PageServeFrame) {
        let owner = owner, slots = bridgeSlots
        replies.async { _ = Self.sendWaiting(frame, owner); slots.release() }
    }

    nonisolated private static func sendWaiting(_ frame: PageServeFrame, _ owner: LinuxControlStreamOwner) -> Bool {
        do {
            return owner.sendWaiting(try PageServeCodec.encode(frame))
        } catch {
            // a reply too large for one line goes back as a failure, so the page learns why and the channel stays
            guard let line = try? PageServeCodec.encode(.failure(id: frame.id, error: "answer too large for the channel"))
            else { return false }
            return owner.sendWaiting(line)
        }
    }

    nonisolated private static func mimeType(_ path: String) -> String {
        var uncertain: gboolean = 0
        guard let type = g_content_type_guess(path, nil, 0, &uncertain) else { return "application/octet-stream" }
        defer { g_free(type) }
        guard let mime = g_content_type_get_mime_type(type) else { return "application/octet-stream" }
        defer { g_free(mime) }
        return String(cString: mime)
    }
}

/// Reference ownership lets the reader, transfer worker, and main adapter share cancellation state.
final class LinuxPageLock<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }
}
