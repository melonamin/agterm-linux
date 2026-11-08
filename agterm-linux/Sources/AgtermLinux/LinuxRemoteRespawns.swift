import Foundation
import Glibc
import agtermCore

@MainActor
extension AppController {
    func respawnPrimaryAdapters(_ id: UUID, prior: [String: Int32]?) {
        let identity = store.session(withID: id)?.paneIdentity
        removeSession(id)
        reconcile(focusActive: false)
        guard let identity, surfaces[id]?.backedByZmx == true else { return }
        let daemon = ZmxSupport.daemonName(for: identity)
        gControlServer.ownerRespawned(session: id, daemon: daemon, prior: prior?[daemon])
    }

    func applyRemoteRespawns(_ respawns: PresentationRespawns, seed: Bool, forSession id: UUID) {
        guard let session = store.session(withID: id), let binding = session.remotePresentation?.binding else { return }
        for (pane, daemon) in binding.daemonsByPane {
            guard seed || respawns.generations[daemon] != nil else { continue }
            let mark = RemoteRespawnBook.Mark(epoch: respawns.epoch, generation: respawns.generations[daemon] ?? 0)
            if RemoteRespawnBook.shared.observe(mark, pane: pane, session: id, seed: seed) { reattachRespawned(pane, in: session) }
        }
        scheduleRemoteTick()
    }

    func remotePaneRespawnHeld(_ surface: GhosttySurface) {
        guard let session = store.session(withID: surface.sessionID), session.remotePresentation != nil,
              let pane = UUID(uuidString: surface.paneToken),
              session.surface === surface || session.splitSurface === surface else { return }
        if RemoteRespawnBook.shared.held(pane: pane, session: session.id) { reattachRespawned(pane, in: session) }
    }

    func pruneRemoteRespawns() {
        RemoteRespawnBook.shared.prune { pane, session in
            guard let holder = gLibrary.store(holdingSession: session),
                  let row = holder.session(withID: session) ?? holder.pendingCloseSession(withID: session) else { return false }
            return row.paneIdentity == pane || row.splitPaneIdentity == pane
        }
    }

    private func reattachRespawned(_ pane: UUID, in session: Session) {
        let surface = session.paneIdentity == pane ? session.surface : session.splitPaneIdentity == pane ? session.splitSurface : nil
        guard let surface = surface as? GhosttySurface else { return }
        _ = reattachPane(surface, claim: true)
    }
}

@MainActor
extension ControlServer {
    func snapshotWithRespawns(_ id: UUID) -> PresentationSnapshot {
        var snapshot = gLibrary.store(forSession: id)?.presentationSnapshot(forSession: id) ?? PresentationSnapshot(status: nil, hud: nil)
        snapshot.respawns = PresentationRespawns(epoch: originEpoch, generations: respawnGenerations[id] ?? [:])
        return snapshot
    }

    func ownerRespawned(session: UUID, daemon: String, prior: Int32?) {
        guard let client = gZmxClient else { return }
        Thread.detachNewThread { [weak self] in
            let deadline = Date().addingTimeInterval(10)
            repeat {
                if let pid = client.sessionLeaderPIDs(timeout: 1)?[daemon], pid != prior, kill(pid, 0) == 0 {
                    runOnMain {
                        MainActor.assumeIsolated {
                            guard let self, gLibrary.store(forSession: session) != nil else { return }
                            var counts = self.respawnGenerations[session] ?? [:]
                            let generation = (counts[daemon] ?? 0) + 1
                            counts[daemon] = generation
                            self.respawnGenerations[session] = counts
                            self.presentationHub.publish(.respawn(PresentationRespawns(epoch: self.originEpoch,
                                generations: [daemon: generation])), session: session)
                        }
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
        }
    }
}
