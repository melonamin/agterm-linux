import Foundation
import Glibc
import agtermCore

@MainActor
enum LinuxSshPoolRoot {
    /// SSH's Unix socket path is short; its sockets and diagnostic files live on persistent storage.
    static let path: String = {
        let persistent = linuxStateDirectory().appendingPathComponent("ssh")
        try? FileManager.default.createDirectory(at: persistent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let alias = "/tmp/agterm-ssh-\(getuid())-\(getpid())"
        try? FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: persistent.path)
        return alias
    }()

    static func prepare(_ pool: SshConnectionPool, path: String, completion: @escaping @MainActor (Bool) -> Void) {
        pool.ready(path, launch: { argv, done in LinuxRemoteCatalog.run(argv) { done($0.status) } }, completion: completion)
    }
}

@MainActor
final class LinuxPooledTransport: RemotePresentationTransport {
    let pool: SshConnectionPool
    let user: String
    let path: String
    let inner: any RemotePresentationTransport

    init(pool: SshConnectionPool, user: String, path: String, inner: any RemotePresentationTransport) {
        self.pool = pool
        self.user = user
        self.path = path
        self.inner = inner
    }

    func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
              onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
        let deferred = DeferredLink()
        _ = pool.lease(user)
        LinuxSshPoolRoot.prepare(pool, path: path) { [inner, pool] ready in
            if ready { deferred.attach { inner.open(argv, onLine: onLine, onClose: onClose) } } else {
                deferred.fail { onClose("no connection to \(pool.host)") }
            }
        }
        return deferred
    }
}
