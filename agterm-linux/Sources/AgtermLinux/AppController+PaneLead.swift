import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func reportPaneLead(_ notice: ZmxLeadNotice, from surface: GhosttySurface) {
        guard let session = store.session(withID: surface.sessionID),
              session.surface === surface || session.splitSurface === surface,
              let pane = UUID(uuidString: surface.paneToken),
              let role = ZmxLeadBook.shared.apply(notice, pane: pane) else { return }
        guard !RemoteReconnectBook.shared.waiting(pane: pane) else { return }
        surface.syncLeadCover()
        store.leadRoleChanged()
        if role == .unowned { reattachPane(surface, claim: false) }
    }

    func takePaneLead(_ surface: GhosttySurface) {
        guard let identity = UUID(uuidString: surface.paneToken),
              ZmxLeadBook.shared.covered(pane: identity),
              !ZmxLeadBook.shared.reattaching(pane: identity) else { return }
        reattachPane(surface, claim: true)
    }

    func sessionLead(_ target: String?, window: String?, pane: StatusPane?) -> ControlResponse {
        guard pane != .scratch else { return err("the scratch terminal has no lead") }
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("session not realized") }
            if pane == .right, !session.hasSplit { return err("session has no split pane") }
            let surface = pane == .right ? splitSurfaces[id] : surfaces[id]
            guard let surface, let identity = UUID(uuidString: surface.paneToken) else {
                return err("session not realized")
            }
            guard ZmxLeadBook.shared.role(pane: identity) != nil
                    || ZmxLeadBook.shared.covered(pane: identity) else {
                return err("pane has no lead to take")
            }
            if ZmxLeadBook.shared.covered(pane: identity) { takePaneLead(surface) }
            return ok(id)
        }
    }

    @discardableResult
    func reattachPane(_ old: GhosttySurface, claim: Bool, cover: Bool = true) -> Bool {
        guard let session = store.session(withID: old.sessionID),
              let identity = UUID(uuidString: old.paneToken) else { return false }
        let role: StatusPane
        let host: OpaquePointer?
        if session.surface === old {
            role = .left
            host = primaryPaneHosts[session.id]
        } else if session.splitSurface === old {
            role = .right
            host = splitPaneHosts[session.id]
        } else { return false }
        guard let host else { return false }
        let lead = ZmxLeadAttachment(claim: claim)
        let command: String
        let environment: [String: String]
        let wait: Bool
        if old.backedByZmx {
            guard let config = try? LinuxZmxLaunch.configuration(
                paneIdentity: identity, baseEnvironment: old.env, lead: lead).get() else { return false }
            let gone = "printf '%s\\n' 'agterm: session is gone'; exit 1"
            command = CommandRestore.shellQuotedLine(config.attachArguments + ["/bin/sh", "-c", gone])
            environment = config.environment
            wait = false
        } else {
            guard let origin = session.remotePresentation?.binding.origin,
                  let daemon = session.remotePresentation?.binding.daemon(forLocalPane: identity),
                  let remote = try? RemoteSession.attachPaneCommand(
                    host: origin.host, endpoint: origin.endpoint, daemon: daemon,
                    session: origin.sessionName, pane: role == .right ? .right : .left, lead: lead)
            else { return false }
            command = remote
            environment = old.env.merging([ZmxLeadAttachment.nonceVariable: lead.nonce]) { _, new in new }
            wait = true
        }
        return replacePane(old, command: command, environment: environment, wait: wait, lead: lead, cover: cover) != nil
    }

    func replacePane(_ old: GhosttySurface, command: String, environment: [String: String],
                     wait: Bool, lead: ZmxLeadAttachment, cover: Bool = true) -> GhosttySurface? {
        guard let session = store.session(withID: old.sessionID), let identity = UUID(uuidString: old.paneToken) else { return nil }
        let role: StatusPane = session.splitSurface === old ? .right : .left
        guard (role == .right ? session.splitSurface : session.surface) === old,
              let host = role == .right ? splitPaneHosts[session.id] : primaryPaneHosts[session.id] else { return nil }
        let coverFocused = old.leadCover.flatMap { gtk_widget_get_first_child(W($0)) }.map { gtk_widget_has_focus($0) != 0 }
        let focused = LinuxPaneLeadKeyPolicy.replacementTakesFocus(
            surfaceFocused: gtk_widget_has_focus(W(old.glArea)) != 0, coverFocused: coverFocused ?? false)
        let replacement = GhosttySurface(sessionID: session.id, cwd: old.cwd, command: command,
                                         env: environment, controller: self, waitAfterCommand: wait,
                                         role: role == .right ? .split : .main, fontSize: session.fontSize,
                                         backedByZmx: old.backedByZmx)
        installPaneExitHandler(replacement, sessionID: session.id)
        if cover { ZmxLeadBook.shared.begin(lead, pane: identity, reattaching: true) }
        replacement.syncLeadCover()
        _ = old.claimProcessExit()
        if searchSurface === old { abandonSearch(ownedBy: session.id) }
        if role == .right {
            session.splitSurface = replacement
            splitSurfaces[session.id] = replacement
        } else {
            session.surface = replacement
            surfaces[session.id] = replacement
        }
        if let title = GhosttyApp.shared.staticTitle { replacement.applyTitle(title) }
        // Keep the old libghostty allocation alive until the fresh surface exists, so a queued child
        // exit cannot be delivered to a reused address.
        g_object_ref(RAW(old.rootWidget))
        gtk_overlay_set_child(host, W(replacement.rootWidget))
        replacement.realizeWidgetIfNeeded()
        old.preservesReconnectOnTeardown = true
        old.teardown()
        g_object_unref(RAW(old.rootWidget))
        if focused { replacement.grabFocus() }
        store.leadRoleChanged()
        return replacement
    }
}

@MainActor
extension GhosttySurface {
    func syncLeadCover() {
        let covered = ZmxLeadBook.shared.covered(pane: UUID(uuidString: paneToken))
        if covered, leadCover == nil {
            let cover = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
            let button = OpaquePointer(gtk_button_new_with_label("Pane in use elsewhere · Take lead"))
            gtk_widget_add_css_class(W(cover), "view")
            gtk_widget_set_hexpand(W(cover), 1)
            gtk_widget_set_vexpand(W(cover), 1)
            gtk_widget_set_halign(W(button), GTK_ALIGN_CENTER)
            gtk_widget_set_valign(W(button), GTK_ALIGN_CENTER)
            gtk_box_append(cast(cover), W(button))
            connect(button, "clicked", unsafeBitCast(onPaneLeadClicked as @convention(c)
                (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), Unmanaged.passUnretained(self).toOpaque())
            let key = gtk_event_controller_key_new()
            connect(key, "key-pressed", unsafeBitCast(onPaneLeadKey as @convention(c)
                (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self),
                Unmanaged.passUnretained(self).toOpaque())
            connect(key, "key-released", unsafeBitCast(surfaceKeyReleased as @convention(c)
                (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> Void, to: GCallback.self),
                Unmanaged.passUnretained(self).toOpaque())
            gtk_widget_add_controller(W(button), key)
            gtk_overlay_add_overlay(rootWidget, W(cover))
            leadCover = cover
        }
        if let leadCover {
            let focused = gtk_widget_has_focus(W(glArea)) != 0
            gtk_widget_set_visible(W(leadCover), covered ? 1 : 0)
            if covered, focused, let button = gtk_widget_get_first_child(W(leadCover)) {
                _ = gtk_widget_grab_focus(button)
            }
        }
        gtk_widget_set_can_target(W(glArea), covered ? 0 : 1)
    }
}

private let onPaneLeadClicked: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        guard let data else { return }
        let surface = Unmanaged<GhosttySurface>.fromOpaque(data).takeUnretainedValue()
        surface.controller?.takePaneLead(surface)
    }
}

private let onPaneLeadKey: @MainActor @convention(c)
    (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { _, keyval, keycode, state, data in
    MainActor.assumeIsolated {
        guard let data else { return 1 }
        let surface = Unmanaged<GhosttySurface>.fromOpaque(data).takeUnretainedValue()
        surface.controller?.paneLeadCoverKey(surface, keyval: keyval, keycode: keycode, state: state)
        return 1
    }
}
