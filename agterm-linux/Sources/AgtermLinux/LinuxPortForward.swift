import Foundation
import Glibc
import agtermCore

/// One SSH listener per remote loopback service, released with the window or the last attached row.
@MainActor
final class LinuxPortForward {
    struct Key: Hashable { let window: UUID; let host: String; let address: String; let port: Int }
    static var records: [Key: LinuxPortForward] = [:]
    let port: Int
    private var process: LinuxChildProcess?
    private var stopped = false
    private var ready = false
    private var waiters: [@MainActor (Int?) -> Void] = []
    private var rows = Set<UUID>()

    private init(port: Int) { self.port = port }

    static func localPort(_ page: ForwardedPage, host: String, window: UUID) -> Int? {
        records[Key(window: window, host: host, address: page.host, port: page.port)]?.port ?? freePort(host: page.host)
    }

    static func open(_ page: ForwardedPage, host: String, window: UUID, row: UUID,
                     localPort: Int? = nil,
                     completion: @escaping @MainActor (Int?) -> Void) {
        let key = Key(window: window, host: host, address: page.host, port: page.port)
        if let running = records[key] {
            running.rows.insert(row)
            if running.ready { completion(running.port) } else { running.waiters.append(completion) }
            return
        }
        guard let port = localPort ?? freePort(host: page.host), let argv = try? RemoteSession.forwardCommand(host: host, spec: page.spec(localPort: port)) else {
            return completion(nil)
        }
        let forward = LinuxPortForward(port: port)
        records[key] = forward
        forward.rows = [row]
        forward.waiters = [completion]
        let descriptor = Glibc.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return forward.finish(key, success: false) }
        defer { Glibc.close(descriptor) }
        do {
            forward.process = try LinuxChildProcess(argv: argv, environment: gdkEnvironment.restoringChildEnvironment(ProcessInfo.processInfo.environment),
                input: descriptor, output: descriptor, errors: descriptor, onExit: { [weak forward] _ in
                    runOnMain { MainActor.assumeIsolated { forward?.finish(key, success: false) } }
                })
        } catch { return forward.finish(key, success: false) }
        DispatchQueue.global(qos: .userInitiated).async { [weak forward] in
            let deadline = Date().addingTimeInterval(15)
            var ready = false
            repeat {
                if accepts(host: page.host, port: port) { ready = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
            let success = ready
            runOnMain { MainActor.assumeIsolated { forward?.finish(key, success: success) } }
        }
    }

    static func prune(window: UUID, rows: Set<UUID>) {
        for (key, record) in records where key.window == window {
            record.rows.formIntersection(rows)
            if record.rows.isEmpty { record.stop(); records[key] = nil }
        }
    }

    private func finish(_ key: Key, success: Bool) {
        guard !stopped, !ready || !success else { return }
        let callbacks = waiters
        waiters = []
        ready = success
        if !success { stop(); Self.records[key] = nil }
        for callback in callbacks { callback(success ? port : nil) }
    }

    private func stop() {
        stopped = true
        process?.terminate()
        process = nil
        let callbacks = waiters
        waiters = []
        for callback in callbacks { callback(nil) }
    }

    nonisolated private static func freePort(host: String) -> Int? {
        let family = host == "::1" ? AF_INET6 : AF_INET
        let descriptor = socket(family, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
        guard descriptor >= 0 else { return nil }
        defer { Glibc.close(descriptor) }
        guard loopback(host, port: 0, { bind(descriptor, $0, $1) == 0 }) else { return nil }
        var address = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        guard withUnsafeMutablePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) == 0 }
        }) else { return nil }
        let port = withUnsafePointer(to: &address) { pointer in
            family == AF_INET6 ? pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port }
                : pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port }
        }
        return Int(UInt16(bigEndian: port))
    }

    nonisolated private static func accepts(host: String, port: Int) -> Bool {
        let descriptor = socket(host == "::1" ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
        guard descriptor >= 0 else { return false }
        defer { Glibc.close(descriptor) }
        return loopback(host, port: port) { connect(descriptor, $0, $1) == 0 }
    }

    nonisolated private static func loopback(_ host: String, port: Int, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> Bool) -> Bool {
        if host == "::1" {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(port).bigEndian
            address.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { operation($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { operation($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}
