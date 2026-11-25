import Foundation
import agtermCore

/// Clicks belong to one presentation generation and retain their click-time rules.
/// GTK callbacks retire each click once, including disconnects racing a completed transfer.
@MainActor
final class LinuxRemoteOpeners {
    private final class Click {
        weak var surface: GhosttySurface?
        var channel: LinuxPageChannel?
        init(_ surface: GhosttySurface) { self.surface = surface }
    }

    let book = PendingOpenerClicks()
    private var connections: [UUID: UUID] = [:]
    private var clicks: [UUID: Click] = [:]
    private let staging = OpenerStaging()

    func renew(_ session: UUID, ended: Bool = false) {
        if let connection = connections.removeValue(forKey: session) {
            for entry in book.teardown(connection: connection) {
                remove(entry.click)
            }
        }
        if !ended { connections[session] = UUID() }
    }

    func record(_ raw: String, session: UUID, surface: GhosttySurface, rules: [FileOpener]) -> UUID? {
        prune()
        guard let connection = connections[session],
              let click = book.record(raw: raw, connection: connection, session: session, rules: rules) else { return nil }
        clicks[click] = Click(surface)
        return click
    }

    func finish(_ click: UUID) {
        book.retire(click)
        remove(click)
    }

    func tick() {
        book.expire()
        for entry in book.overdue() {
            guard clicks[entry.click]?.channel != nil else { continue }
            fail(entry.click, session: entry.session)
        }
        prune()
    }

    func receive(_ snapshot: PresentationLinkSnapshot, session: UUID, controller: AppController) {
        guard let connection = connections[session],
              let (_, rule) = book.accept(snapshot, connection: connection, session: session) else { return }
        let click = snapshot.click
        guard let host = controller.store.session(withID: session)?.remoteHost,
              let argv = try? RemoteSession.pageServeCommand(host: host, token: snapshot.token) else {
            return fail(click, session: session)
        }
        let channel = LinuxPageChannel()
        clicks[click]?.channel = channel
        channel.start(argv)
        channel.fetch(snapshot.name, maxBytes: snapshot.size) { [weak self, weak controller] result in
            guard let self, let controller, self.clicks[click]?.channel === channel else { return }
            guard case .success(let resource) = result else { return self.fail(click, session: session) }
            self.clicks[click]?.channel = nil
            channel.close()
            let staging = self.staging
            DispatchQueue.global(qos: .userInitiated).async {
                let staged = Result { () throws -> String in
                    let data = try BoundedFile.read(path: resource.path, maxBytes: snapshot.size).get()
                    return try staging.stage(name: snapshot.name, data: data, size: snapshot.size)
                }
                runOnMain { MainActor.assumeIsolated {
                    guard case .success(let path) = staged else { return self.fail(click, session: session) }
                    let surface = self.clicks[click]?.surface
                    guard self.book.retire(click) != nil, let surface else {
                        self.remove(click)
                        return staging.remove(path)
                    }
                    self.remove(click)
                    if !controller.runFileOpener(rule, path: path, surface: surface, host: host) { staging.remove(path) }
                } }
            }
        }
    }

    private func fail(_ click: UUID, session: UUID) {
        guard book.retire(click) != nil else { return }
        let host = clicks[click]?.surface?.controller?.store.session(withID: session)?.remoteHost ?? "origin"
        remove(click)
        NotificationManager.send(title: "Open remote file", body: RemoteLinkRefusal.snapshotFailed.message(host: host))
    }

    private func remove(_ click: UUID) {
        let channel = clicks.removeValue(forKey: click)?.channel
        channel?.close()
    }

    private func prune() {
        for click in Array(clicks.keys) where !book.contains(click) { remove(click) }
    }
}
