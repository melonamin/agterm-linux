import Foundation
import Glibc
import agtermCore

enum LinuxPageChannelError: Error, Sendable {
    case closed
    case refused(String)
}

/// The scheme adapter opens the completed spool before releasing it; its stream keeps the unlinked inode.
final class LinuxPageResource: Sendable {
    let path: String
    let mime: String
    init(path: String, mime: String) { self.path = path; self.mime = mime }
    deinit { _ = Glibc.unlink(path) }
}

/// Callback delivery follows GLib rather than Swift's main-actor executor.
@MainActor
final class LinuxPageChannel {
    typealias FetchReply = @MainActor (Result<LinuxPageResource, LinuxPageChannelError>) -> Void
    typealias BridgeReply = @MainActor (Result<String, LinuxPageChannelError>) -> Void
    private struct Fetch {
        let path: String
        var reply: FetchReply?
    }

    private var owner: LinuxControlStreamOwner?
    private var process: LinuxChildProcess?
    private var resources: [Int: Fetch] = [:]
    private var queued: [(Int, Fetch)] = []
    private var bridges: [Int: BridgeReply] = [:]
    private var queuedBridges: [(Int, String, BridgeReply)] = []
    private var nextID = 0
    private var closed = false
    private let expected = LinuxPageLock(Set<Int>())
    private let expectedBridges = LinuxPageLock(Set<Int>())
    var onClose: (() -> Void)?

    func start(_ argv: [String]) {
        guard owner == nil, !closed else { return }
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair) == 0 else { return close() }
        _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
        let errors = Pipe()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { LinuxStructuredLogger(category: "RemotePage").notice(String(decoding: data, as: UTF8.self)) }
        }
        do {
            process = try LinuxChildProcess(argv: argv,
                environment: gdkEnvironment.restoringChildEnvironment(ProcessInfo.processInfo.environment),
                input: pair[1], output: pair[1], errors: errors.fileHandleForWriting.fileDescriptor)
        } catch {
            _ = Glibc.close(pair[0]); _ = Glibc.close(pair[1])
            errors.fileHandleForReading.readabilityHandler = nil
            return close()
        }
        _ = Glibc.close(pair[1])
        try? errors.fileHandleForWriting.close()
        let connection = LinuxControlStreamOwner(descriptor: pair[0], maxPending: 32)
        owner = connection
        let spooler = LinuxPageSpooler(expected: expected, expectedBridges: expectedBridges) { [weak self] event in
            runOnMain { MainActor.assumeIsolated { self?.receive(event) } }
        }
        connection.start(onLine: { line in
            if !spooler.receive(line) { connection.shutdown() }
        }, onClose: { [weak self] in
            spooler.close()
            runOnMain { MainActor.assumeIsolated { self?.close() } }
        })
        drain()
    }

    func fetch(_ path: String, reply: @escaping FetchReply) {
        guard !closed else { return reply(.failure(.closed)) }
        nextID += 1
        queued.append((nextID, Fetch(path: path, reply: reply)))
        drain()
    }

    func bridge(_ request: String, reply: @escaping BridgeReply) {
        guard !closed else { return reply(.failure(.closed)) }
        nextID += 1
        queuedBridges.append((nextID, request, reply))
        drain()
    }

    /// Keep the occupied slot until the origin sends a terminal frame for each cancelled transfer.
    func cancelResources() {
        let waiting = queued
        queued.removeAll()
        for (_, fetch) in waiting { fetch.reply?(.failure(.closed)) }
        for id in Array(resources.keys) {
            let reply = resources[id]?.reply
            resources[id]?.reply = nil
            reply?(.failure(.closed))
            send(.cancel(id: id))
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        owner?.shutdown()
        owner = nil
        process?.terminate()
        process = nil
        let pendingResources = Array(resources.values) + queued.map(\.1)
        let pendingBridges = Array(bridges.values) + queuedBridges.map(\.2)
        resources.removeAll(); queued.removeAll(); bridges.removeAll(); queuedBridges.removeAll()
        for fetch in pendingResources { fetch.reply?(.failure(.closed)) }
        for reply in pendingBridges { reply(.failure(.closed)) }
        let finished = onClose
        onClose = nil
        finished?()
    }

    private func drain() {
        guard owner != nil, !closed else { return }
        while resources.count < ControlServer.pageServeResourceLimit, !queued.isEmpty {
            let (id, fetch) = queued.removeFirst()
            resources[id] = fetch
            expected.withLock { _ = $0.insert(id) }
            send(.resource(id: id, path: fetch.path))
        }
        while bridges.count < ControlServer.pageServeBridgeLimit, !queuedBridges.isEmpty {
            let (id, request, reply) = queuedBridges.removeFirst()
            bridges[id] = reply
            expectedBridges.withLock { _ = $0.insert(id) }
            send(.bridge(id: id, request: request))
        }
    }

    private func send(_ frame: PageServeFrame) {
        guard let data = try? PageServeCodec.encode(frame), owner?.send(data) == true else { return close() }
    }

    private func receive(_ event: LinuxPageSpooler.Event) {
        guard !closed else { return }
        switch event {
        case .resource(let id, let resource):
            expected.withLock { _ = $0.remove(id) }
            resources.removeValue(forKey: id)?.reply?(.success(resource))
        case .failure(let id, let error):
            expected.withLock { _ = $0.remove(id) }
            resources.removeValue(forKey: id)?.reply?(.failure(.refused(error)))
            bridges.removeValue(forKey: id)?(.failure(.refused(error)))
        case .bridge(let id, let response): bridges.removeValue(forKey: id)?(.success(response))
        }
        drain()
    }
}

/// Used only by one connection's reader thread, which also performs its cleanup after EOF.
/// Chunks go straight to private files: neither queued GTK callbacks nor memory grow with resource size.
private final class LinuxPageSpooler: @unchecked Sendable {
    enum Event: Sendable {
        case resource(Int, LinuxPageResource)
        case failure(Int, String)
        case bridge(Int, String)
    }
    struct Spool {
        let handle: FileHandle
        let resource: LinuxPageResource
    }
    private var spools: [Int: Spool] = [:]
    private let expected: LinuxPageLock<Set<Int>>
    private let expectedBridges: LinuxPageLock<Set<Int>>
    private let deliver: @Sendable (Event) -> Void

    init(expected: LinuxPageLock<Set<Int>>, expectedBridges: LinuxPageLock<Set<Int>>, deliver: @escaping @Sendable (Event) -> Void) {
        self.expected = expected
        self.expectedBridges = expectedBridges
        self.deliver = deliver
    }

    func receive(_ line: Data) -> Bool {
        guard let frame = try? PageServeCodec.decode(line) else { return false }
        switch frame {
        case .head(let id, let mime):
            guard expected.withLock({ $0.contains(id) }), spools[id] == nil else { return false }
            var template = Array((NSTemporaryDirectory() + "/agterm-page-XXXXXX").utf8CString)
            let fd = mkstemp(&template)
            guard fd >= 0 else { return false }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let resource = LinuxPageResource(path: path, mime: mime)
            spools[id] = Spool(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), resource: resource)
        case .chunk(let id, let data):
            guard let spool = spools[id] else { return false }
            do { try spool.handle.write(contentsOf: data) } catch { return false }
        case .end(let id):
            guard let spool = spools.removeValue(forKey: id) else { return false }
            try? spool.handle.close()
            expected.withLock { _ = $0.remove(id) }
            deliver(.resource(id, spool.resource))
        case .failure(let id, let error):
            if let spool = spools.removeValue(forKey: id) { try? spool.handle.close() }
            let resource = expected.withLock { $0.remove(id) != nil }
            let bridge = expectedBridges.withLock { $0.remove(id) != nil }
            if resource || bridge { deliver(.failure(id, error)) }
        case .reply(let id, let response):
            if expectedBridges.withLock({ $0.remove(id) != nil }) { deliver(.bridge(id, response)) }
        case .resource, .bridge, .cancel: return false
        }
        return true
    }

    func close() {
        for spool in spools.values { try? spool.handle.close() }
        spools.removeAll()
    }
}
