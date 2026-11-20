import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func remoteLinkLost(_ notice: RemoteLinkNotice, surface: GhosttySurface) {
        guard let pane = UUID(uuidString: surface.paneToken),
              notice.nonce == ZmxLeadBook.shared.states[pane]?.attachment.nonce,
              let session = store.session(withID: surface.sessionID), let host = session.remoteHost,
              session.surface === surface || session.splitSurface === surface else { return }
        let cover = ZmxLeadBook.shared.role(pane: pane) != nil || ZmxLeadBook.shared.reattaching(pane: pane)
        ZmxLeadBook.shared.forget(pane: pane)
        store.remotePaneHeld(pane, forSession: session.id)
        remoteHeldExits.paneHeld(surface, forSession: session.id)
        RemoteReconnectBook.shared.wait(pane: pane, session: session.id, host: host, cover: cover, now: Date())
        surface.syncLeadCover()
        surface.refreshReconnectNote()
        store.leadRoleChanged()
        scheduleRemoteTick()
    }

    func retryRemoteLinksNow() {
        RemoteReconnectBook.shared.retryAllNow(now: Date())
        for client in remoteClients.values { client.retryNow(); client.tick() }
        tickReconnects()
    }

    func retryRemotePane(_ surface: GhosttySurface, keycode: UInt32) -> Bool {
        guard let pane = UUID(uuidString: surface.paneToken), RemoteReconnectBook.shared.waiting(pane: pane) else { return false }
        LinuxLeaderState.shared.consumed.insert(keycode)
        RemoteReconnectBook.shared.retryNow(pane: pane, now: Date())
        tickReconnects()
        return true
    }

    func tickReconnects() {
        let book = RemoteReconnectBook.shared
        for pane in book.entries.keys {
            guard let entry = book.entries[pane],
                  let session = store.session(withID: entry.session) ?? store.pendingCloseSession(withID: entry.session) else { continue }
            let surface = session.paneIdentity == pane ? session.surface : session.splitPaneIdentity == pane ? session.splitSurface : nil
            (surface as? GhosttySurface)?.refreshReconnectNote()
        }
        for pane in book.due(now: Date()) {
            guard let entry = book.entries[pane],
                  let owner = gWindows.values.first(where: { $0.store.session(withID: entry.session) != nil || $0.store.pendingCloseSession(withID: entry.session) != nil }),
                  let session = owner.store.session(withID: entry.session) ?? owner.store.pendingCloseSession(withID: entry.session),
                  session.paneRole(forIdentity: pane) != nil,
                  let argv = try? RemoteSession.probeCommand(host: entry.host) else {
                book.cancel(pane: pane)
                continue
            }
            let expected = (session.paneIdentity == pane ? session.surface : session.splitSurface) as? GhosttySurface
            Thread.detachNewThread { [weak owner] in
                let result = LinuxRemoteCommand.run(argv, deadline: 10)
                runOnMain {
                    MainActor.assumeIsolated {
                        guard let self = owner,
                              let held = self.store.session(withID: entry.session) ?? self.store.pendingCloseSession(withID: entry.session),
                              (held.paneIdentity == pane ? held.surface : held.splitSurface) === expected,
                              let entry = book.finished(pane: pane, ok: result.status == 0,
                                                                  stderr: result.stderr, now: Date()) else { return }
                        guard let session = self.store.session(withID: entry.session),
                              let surface = (session.paneIdentity == pane ? session.surface : session.splitSurface) as? GhosttySurface,
                              self.reattachPane(surface, claim: false, cover: entry.cover) else {
                            book.wait(pane: pane, session: entry.session, host: entry.host, cover: entry.cover, now: Date())
                            return
                        }
                        self.store.remotePaneResumed(pane, forSession: entry.session)
                    }
                }
            }
        }
    }
}

@MainActor
extension GhosttySurface {
    func refreshReconnectNote() {
        let entry = UUID(uuidString: paneToken).flatMap { RemoteReconnectBook.shared.entries[$0] }
        if let entry {
            if reconnectNote == nil {
                let label = OpaquePointer(gtk_label_new(nil))
                gtk_widget_add_css_class(W(label), "view")
                gtk_widget_set_halign(W(label), GTK_ALIGN_FILL)
                gtk_widget_set_valign(W(label), GTK_ALIGN_END)
                gtk_label_set_wrap(label, 1)
                gtk_overlay_add_overlay(rootWidget, W(label))
                reconnectNote = label
            }
            let readback = RemoteReconnectBook.shared.readback(pane: UUID(uuidString: paneToken))
            let text = "Reconnecting to \(entry.host) · \(readback?.failures ?? 0) failed probe(s)"
                + (readback?.reason.map { " · \($0)" } ?? "") + " · Press a key to retry"
            text.withCString { gtk_label_set_text(reconnectNote, $0) }
        } else if let reconnectNote {
            gtk_overlay_remove_overlay(rootWidget, W(reconnectNote))
            self.reconnectNote = nil
        }
    }
}
