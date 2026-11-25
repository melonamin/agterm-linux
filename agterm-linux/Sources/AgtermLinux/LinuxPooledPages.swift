import Foundation
import agtermCore

@MainActor
extension AppController {
    func startRemotePageChannel(_ channel: LinuxPageChannel, local: UUID, host: String, token: String, fallback: [String]) {
        guard let catalog = LinuxRemoteCatalogs.windows[windowID] else { return channel.start(fallback) }
        let user = "page:\(token)", path = catalog.pool.lease("page:\(token)")
        replicaPages[local]?.pool = catalog.pool
        replicaPages[local]?.poolUser = user
        guard let command = try? RemoteSession.pageServeCommand(host: host, token: token, controlPath: path) else { return channel.close() }
        LinuxSshPoolRoot.prepare(catalog.pool, path: path) { [weak self] ready in
            guard let self, replicaPages[local]?.channel === channel else { return }
            if ready { channel.start(command) } else { channel.close() }
        }
    }
}
