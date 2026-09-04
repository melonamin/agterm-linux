// The Linux control socket: a unix-domain socket that decodes one ControlRequest
// per connection and dispatches it onto the shared AppController/AppStore, writing
// one ControlResponse back. Mirrors the macOS ControlServer, but hops to the GTK
// main thread via g_idle (runOnMain) + a semaphore instead of DispatchQueue.main.
// The wire protocol (ControlProtocol) is shared from agtermCore; the Linux agtermctl wrapper lives in
// agterm-linux so Glibc socket code stays inside the Linux boundary.
import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

final class ControlServer: @unchecked Sendable {
    let path: String
    private var listenFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var refused = false
    private static let maxLine = 1 << 20
    private static let readTimeoutMS: Int32 = 5_000
    static let unavailableSuffix = ".unavailable"

    private let logger = LinuxStructuredLogger(category: "ControlServer")
    private let setSocketPermissions: (String, Int32) -> Int32

    /// The socket path once actually bound (nil before bind / after a bind failure), so a spawned
    /// shell's `AGTERM_SOCKET` only advertises a socket that exists. Mirrors macOS `boundSocketPath`.
    var boundSocketPath: String? { listenFD >= 0 ? path : nil }
    var resolvedSocketPath: String { refused ? path + Self.unavailableSuffix : path }

    init(
        path: String? = nil,
        setSocketPermissions: ((String, Int32) -> Int32)? = nil
    ) {
        self.path = path ?? Self.defaultSocketPath()
        self.setSocketPermissions = setSocketPermissions ?? { path, _ in
            path.withCString { chmod($0, 0o600) }
        }
        _ = acquireOwnership()
    }

    static func defaultSocketPath() -> String {
        ControlResolve.socketPath(stateDir: ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"],
                                  appSupport: PersistenceStore.defaultDirectory.path)
    }

    func start() {
        guard listenFD < 0 else { return }
        signal(SIGPIPE, SIG_IGN)
        guard path.utf8.count < 104 else {
            logger.notice("control socket path too long (\(path.utf8.count) bytes): \(path)")
            return
        }
        guard lockFD >= 0 || acquireOwnership() else { return }
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            logger.notice("control socket() failed: \(reason)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buf in
                bytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
            }
        }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            logger.notice("control bind(\(path)) failed: \(reason)")
            close(fd)
            return
        }
        // Secure the pathname before listen makes connections queueable. A permissive process umask can
        // otherwise leave a short cross-user connection window, and a failed chmod must never be ignored.
        guard setSocketPermissions(path, fd) == 0 else {
            let errorNumber = errno
            let reason = String(cString: strerror(errorNumber))
            logger.notice("control chmod(\(path), 0600) failed: \(reason)")
            close(fd)
            unlink(path)
            return
        }
        guard listen(fd, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            logger.notice("control listen() failed: \(reason)")
            close(fd)
            unlink(path)
            return
        }
        listenFD = fd
        Thread.detachNewThread { [self] in acceptLoop(fd) }
        logger.notice("control socket at \(path)")
    }

    func stop() {
        defer { releaseOwnership() }
        guard listenFD >= 0 else { return }
        close(listenFD)
        listenFD = -1
        unlink(path)
    }

    private func acquireOwnership() -> Bool {
        let lockPath = path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            logger.notice("control lock open(\(lockPath)) failed: \(reason)")
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            refused = true
            logger.notice("control socket \(path) is already served by another instance — not binding")
            return false
        }
        lockFD = fd
        refused = false
        return true
    }

    private func releaseOwnership() {
        guard lockFD >= 0 else { return }
        close(lockFD)
        lockFD = -1
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 {
                // a closed listener (stop()) makes accept fail — exit; EINTR (signal) / ECONNABORTED
                // are transient, so keep serving instead of dying. Mirrors the macOS accept loop.
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            Thread.detachNewThread { [self] in
                handle(conn)
                close(conn)
            }
        }
    }

    private func handle(_ conn: Int32) {
        guard let line = readLine(conn) else { return }
        let response: ControlResponse
        if let req = try? JSONDecoder().decode(ControlRequest.self, from: line) {
            response = Self.isRemoteZmxRequest(req) ? dispatchRemoteZmx(req) : dispatchOnMain(req)
        } else {
            response = ControlResponse(ok: false, error: "could not decode request")
        }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        writeAll(conn, data)
    }

    private static func isRemoteZmxRequest(_ request: ControlRequest) -> Bool {
        request.cmd == .zmxAttach
            || (request.cmd == .zmxTree
                && request.args?.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    /// SSH waits on a per-connection worker, never GTK's main thread and never the listener thread.
    private func dispatchRemoteZmx(_ request: ControlRequest) -> ControlResponse {
        guard let host = request.args?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return ControlResponse(ok: false, error: request.cmd == .zmxAttach
                ? "zmx.attach requires a host" : "invalid host")
        }
        let tree = readRemoteTree(host: host)
        guard request.cmd == .zmxAttach else { return tree }
        guard let remoteID = request.target?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isPlainRemoteToken(remoteID) else {
            return ControlResponse(ok: false, error: request.target == nil
                ? "zmx.attach requires a remote session" : "invalid remote session")
        }
        guard tree.ok, let remote = tree.result?.remote else { return tree }
        return attachRemoteOnMain(host: host, session: remoteID, tree: remote)
    }

    private func readRemoteTree(host: String) -> ControlResponse {
        let argv: [String]
        do {
            argv = try RemoteSession.treeCommand(host: host)
        } catch {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = LinuxRemoteCommand.run(argv, deadline: LinuxRemoteCommand.treeDeadline)
        guard result.status == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = RemoteTreeMerger.remoteError(stdout: result.stdout) ?? (stderr.isEmpty ? nil : stderr)
            return ControlResponse(ok: false, error: detail ?? "the remote command failed on \(host)")
        }
        do {
            let decoded = try RemoteTreeMerger.decode(stdout: result.stdout)
            let stamped = ControlRemoteTree(host: host, endpoint: decoded.endpoint, sessions: decoded.sessions)
            return ControlResponse(ok: true, result: ControlResult(remote: stamped))
        } catch let error as RemoteTreeMerger.MergeError {
            return ControlResponse(ok: false, error: error.message)
        } catch {
            return ControlResponse(ok: false, error: "the remote answer could not be read")
        }
    }

    private func attachRemoteOnMain(host: String, session: String,
                                    tree: ControlRemoteTree) -> ControlResponse {
        let sem = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        runOnMain {
            MainActor.assumeIsolated {
                box.value = gController?.attachRemoteSession(host: host, session: session, tree: tree)
                    ?? ControlResponse(ok: false, error: "no window to attach into")
                sem.signal()
            }
        }
        sem.wait()
        return box.value
    }

    private static func isPlainRemoteToken(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains {
            $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7f
        }
    }

    /// Run the dispatch on the GTK main thread and block until it returns.
    private func dispatchOnMain(_ req: ControlRequest) -> ControlResponse {
        let sem = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        runOnMain {
            MainActor.assumeIsolated {
                box.value = Self.route(for: req).response(for: req)
                sem.signal()
            }
        }
        sem.wait()
        return box.value
    }

    private enum ControllerRoute {
        case controller(AppController?)
        case failure(String)

        @MainActor func response(for req: ControlRequest) -> ControlResponse {
            switch self {
            case .controller(let controller):
                return controller?.handleControl(req) ?? ControlResponse(ok: false, error: "no controller")
            case .failure(let error):
                return ControlResponse(ok: false, error: error)
            }
        }
    }

    @MainActor private static func route(for req: ControlRequest) -> ControllerRoute {
        if let window = req.args?.window, !window.isEmpty {
            guard let library = gLibrary else {
                return .failure("window not open")
            }
            let id: UUID
            switch library.resolveWindow(window) {
            case .resolved(let resolved):
                id = resolved
            case .ambiguous(let hits):
                return .failure(ControlResolve.ambiguousMessage(noun: "window", target: window, hits: hits))
            case .notFound:
                return .failure(ControlResolve.notFoundMessage(noun: "window", target: window))
            }
            guard let controller = gWindows[id] else {
                return .failure("window not open")
            }
            return .controller(controller)
        }
        switch req.cmd {
        case .sessionClose, .sessionDuplicate, .sessionSelect, .sessionGo, .sessionRename, .sessionReveal,
             .sessionMove, .sessionType,
             .sessionStatus, .sessionRestore, .sessionFlag, .sessionContext, .sessionSeen,
             .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionScratch, .sessionFocus,
             .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch,
             .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayResult,
             .sessionOverlayCopy, .sessionOverlayText,
             .sessionHudOpen, .sessionHudUpdate, .sessionHudClose,
             .sessionBackground, .sessionResize, .sessionText, .notify,
             .fontInc, .fontDec, .fontReset:
            return routeOwningSession(req.target) ?? .controller(gController)
        case .workspaceRename, .workspaceDelete, .workspaceSelect, .workspaceMove, .workspaceFocus,
             .workspaceCollapse, .workspaceExpand:
            return routeOwningWorkspace(req.target) ?? .controller(gController)
        case .sessionNew:
            return routeOwningWorkspace(req.args?.workspace) ?? .controller(gController)
        case .surfaceZoom, .surfaceCursor:
            return routeOwningSurface(req.target) ?? .controller(gController)
        case .tree, .eventsRead, .workspaceNew, .workspaceGo, .quick, .quickType, .quickText, .dashboard,
             .sidebar, .sidebarMode, .sidebarExpand, .sidebarCollapse, .workspaceFilter,
             .windowNew, .windowList, .windowSelect, .windowClose, .windowRename, .windowDelete,
             .windowResize, .windowMove, .windowZoom, .windowFullscreen, .windowMinimize,
             .keymapReload, .keymapList, .configReload, .themeSet, .themeList,
             .pickOpen, .pickResult, .pickCancel, .sidebarWidth,
             .restoreClear, .restoreCapture, .restoreMode, .recentClear, .version,
             .zmxList, .zmxPrune, .zmxKill, .zmxTree, .zmxAttach, .debugAppearance:
            return .controller(gController)
        }
    }

    @MainActor private static func explicitTarget(_ target: String?) -> String? {
        guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty, target != "active" else { return nil }
        return target
    }

    @MainActor private static func routeOwningSession(_ target: String?) -> ControllerRoute? {
        guard let target = explicitTarget(target) else { return nil }
        let controllers = gWindows.values
        let candidates = controllers.flatMap { $0.store.workspaces.flatMap { $0.sessions.map(\.id) } }
        switch ControlResolve.resolve(target, candidates: candidates, active: nil) {
        case .resolved(let id):
            return .controller(controllers.first { $0.store.session(withID: id) != nil })
        case .ambiguous(let hits):
            return .failure(ControlResolve.ambiguousMessage(noun: "session", target: target, hits: hits))
        case .notFound:
            return .failure(ControlResolve.notFoundMessage(noun: "session", target: target))
        }
    }

    @MainActor private static func routeOwningSurface(_ target: String?) -> ControllerRoute? {
        guard let target = explicitTarget(target), target != "quick",
              let surfaceID = TerminalSurfaceID(rawValue: target) else { return nil }
        return routeOwningSession(surfaceID.sessionID.uuidString)
    }

    @MainActor private static func routeOwningWorkspace(_ target: String?) -> ControllerRoute? {
        guard let target = explicitTarget(target) else { return nil }
        let controllers = gWindows.values
        let candidates = controllers.flatMap { $0.store.workspaces.map(\.id) }
        switch ControlResolve.resolve(target, candidates: candidates, active: nil) {
        case .resolved(let id):
            return .controller(controllers.first { $0.store.workspaces.contains { $0.id == id } })
        case .ambiguous(let hits):
            return .failure(ControlResolve.ambiguousMessage(noun: "workspace", target: target, hits: hits))
        case .notFound:
            return .failure(ControlResolve.notFoundMessage(noun: "workspace", target: target))
        }
    }

    private func readLine(_ conn: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            var pfd = pollfd(fd: conn, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Self.readTimeoutMS)
            if ready == 0 { return nil }
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard (pfd.revents & Int16(POLLIN)) != 0 else { return nil }
            let n = read(conn, &byte, 1)
            if n == 0 { return buffer.isEmpty ? nil : buffer }
            if n < 0 { return nil }
            if byte == 0x0A { return buffer }
            buffer.append(byte)
            if buffer.count > Self.maxLine { return nil }
        }
    }

    private func writeAll(_ conn: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = write(conn, base + offset, data.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}

private final class ResponseBox: @unchecked Sendable {
    var value = ControlResponse(ok: false, error: "internal")
}
