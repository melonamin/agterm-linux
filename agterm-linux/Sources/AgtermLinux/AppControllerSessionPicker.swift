import CGtk
import Foundation
import agtermCore

@MainActor
final class SessionPickerRowContext {
    unowned let controller: AppController
    let sessionID: UUID
    let attention: Bool
    let statusPane: StatusPane?

    init(controller: AppController, sessionID: UUID, attention: Bool, statusPane: StatusPane?) {
        self.controller = controller
        self.sessionID = sessionID
        self.attention = attention
        self.statusPane = statusPane
    }
}

@MainActor
extension AppController {
    /// Open the mouse-accessible twin of the Ctrl-Tab MRU switcher or attention palette.
    /// These are interactive-only popovers, so no control-socket command is meaningful.
    func showSessionPicker(attention: Bool, anchor: OpaquePointer?) {
        guard let anchor else { return }
        let sessions: [Session]
        if attention {
            sessions = store.attentionSessions
        } else {
            sessions = store.recentSessions(limit: 11)
                .filter { $0 != store.selectedSessionID }
                .prefix(10)
                .compactMap { store.session(withID: $0) }
        }
        guard !sessions.isEmpty else { return }

        dismissSessionPicker()
        guard let popover = op(gtk_popover_new()), let rows = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)) else {
            return
        }
        sessionPickerPopover = popover
        sessionPickerShowsAttention = attention
        sessionPickerSuppressesAutoFollow = true
        suppressAutoFollow()
        gtk_widget_set_parent(W(popover), W(anchor))
        gtk_popover_set_position(POPOVER(popover), GTK_POS_BOTTOM)
        gtk_widget_add_css_class(W(rows), "agterm-session-picker")
        gtk_widget_add_css_class(W(rows), "agterm-interface-panel")
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(W(rows), 6)
        }
        let metrics = InterfaceMetrics(fontSize: linuxSettingsStore().load().effectiveInterfaceFontSize)
        gtk_widget_set_size_request(W(rows), Int32(metrics.scaled(320)), -1)

        for session in sessions {
            guard let button = op(gtk_button_new()), let row = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)),
                  let labels = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 1)) else { continue }
            gtk_button_set_has_frame(BUTTON(button), 0)
            gtk_widget_set_halign(W(button), GTK_ALIGN_FILL)
            gtk_widget_set_hexpand(W(button), 1)
            (attention ? "attention-session-row" : "recent-session-row").withCString {
                gtk_widget_set_name(W(button), $0)
            }

            if attention, let icon = Self.makeStatusGlyph(
                session.agentIndicator, settings: linuxSettingsStore().load()
            ) {
                gtk_box_append(cast(row), W(icon))
            }

            let title = op(gtk_label_new(session.displayName))
            gtk_label_set_xalign(title, 0)
            gtk_widget_add_css_class(W(title), "heading")
            gtk_box_append(cast(labels), W(title))
            let workspace = store.workspace(forSession: session.id)?.name ?? ""
            let detail = workspace.isEmpty ? session.subtitleDetail : "\(workspace) · \(session.subtitleDetail)"
            let subtitle = op(gtk_label_new(detail))
            gtk_label_set_xalign(subtitle, 0)
            gtk_widget_add_css_class(W(subtitle), "dim-label")
            gtk_box_append(cast(labels), W(subtitle))
            gtk_widget_set_hexpand(W(labels), 1)
            gtk_box_append(cast(row), W(labels))
            gtk_button_set_child(BUTTON(button), W(row))

            let context = SessionPickerRowContext(
                controller: self,
                sessionID: session.id,
                attention: attention,
                statusPane: session.agentIndicator.statusPane
            )
            sessionPickerContexts.append(context)
            connect(button, "clicked", unsafeBitCast(onSessionPickerRow as @convention(c)
                (OpaquePointer?, gpointer?) -> Void, to: GCallback.self),
                Unmanaged.passUnretained(context).toOpaque())
            gtk_box_append(cast(rows), W(button))
        }

        connect(popover, "closed", unsafeBitCast(onSessionPickerClosed as @convention(c)
            (OpaquePointer?, gpointer?) -> Void, to: GCallback.self),
            Unmanaged.passUnretained(self).toOpaque())
        gtk_popover_set_child(POPOVER(popover), W(rows))
        gtk_popover_popup(POPOVER(popover))
    }

    func updateRecentSessionsButton() {
        guard let button = recentSessionsButton else { return }
        let hasOther = store.recentSessions(limit: 2).contains { $0 != store.selectedSessionID }
        gtk_widget_set_sensitive(W(button), hasOther ? 1 : 0)
        gtk_widget_set_opacity(W(button), hasOther ? 1 : 0.35)
        if !hasOther, sessionPickerPopover != nil, !sessionPickerShowsAttention { dismissSessionPicker() }
    }

    func activateSessionPickerRow(_ context: SessionPickerRowContext) {
        let id = context.sessionID
        let attention = context.attention
        let statusPane = context.statusPane
        dismissSessionPicker()
        selectSession(id)
        if attention {
            handleAutoFollow(id, statusPane: statusPane)
        } else {
            focusedSurface(for: id)?.grabFocus()
        }
    }

    func dismissSessionPicker() {
        guard let popover = sessionPickerPopover else { return }
        sessionPickerPopover = nil
        sessionPickerShowsAttention = false
        sessionPickerContexts.removeAll()
        if sessionPickerSuppressesAutoFollow {
            sessionPickerSuppressesAutoFollow = false
            resumeAutoFollow()
        }
        gtk_popover_popdown(POPOVER(popover))
        gtk_widget_unparent(W(popover))
    }

    func sessionPickerDidClose(_ popover: OpaquePointer?) {
        guard popover == sessionPickerPopover else { return }
        sessionPickerPopover = nil
        sessionPickerShowsAttention = false
        sessionPickerContexts.removeAll()
        if sessionPickerSuppressesAutoFollow {
            sessionPickerSuppressesAutoFollow = false
            resumeAutoFollow()
        }
        gtk_widget_unparent(W(popover))
    }
}

private let onSessionPickerRow: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<SessionPickerRowContext>.fromOpaque(data).takeUnretainedValue()
        context.controller.activateSessionPickerRow(context)
    }
}

private let onSessionPickerClosed: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { popover, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().sessionPickerDidClose(popover)
    }
}
