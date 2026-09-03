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
    // MARK: - Ctrl-Tab switcher

    /// Cycling moves the overlay highlight ONLY; `commitSessionSwitch` selects on Ctrl release, so one
    /// cycle pushes recency exactly once and a second Ctrl-Tab toggles back.
    func quickSwitchSession(reverse: Bool = false) {
        if sessionSwitcher.isActive {
            sessionSwitcher.advance(reverse: reverse)
        } else {
            let valid = Set(store.navigableSessions.map(\.id))
            sessionSwitcher.begin(store.sessionRecency.top(SessionSwitcherModel.maxCandidates, in: valid))
        }
        if sessionSwitcher.isActive { showSwitcherOverlay() }
    }

    /// Fires after EVERY Ctrl chord (Ctrl+C too), so it must do nothing with no cycle in flight. Ending the
    /// model BEFORE selecting is load-bearing: `selectSession` grabs focus, whose blur reaches
    /// `cancelSessionSwitch`, which must find the cycle already over.
    /// GTK updates the keyboard device's modifier state only after the release signal returns. Defer one
    /// GLib turn through MainTimer, then reacquire the device instead of retaining an event-owned pointer.
    func scheduleSessionSwitchCommit(releasing keycode: UInt32) {
        MainTimer.schedule(after: 0) { [weak self] in
            self?.commitSessionSwitch(
                releasing: keycode, controlStillHeld: ModifierKeyMods.currentControlIsHeld()
            )
        }
    }

    private func commitSessionSwitch(releasing keycode: UInt32, controlStillHeld: Bool?) {
        guard heldControlKeys.released(keycode: keycode, controlStillHeld: controlStillHeld) else { return }
        guard sessionSwitcher.isActive else { return }
        let live = Set(store.workspaces.flatMap { $0.sessions.map(\.id) })
        let target = sessionSwitcher.commitTarget(liveIDs: live)
        sessionSwitcher.end()
        hideSwitcherOverlay()
        if let target { selectSession(target) }
    }

    /// End the cycle WITHOUT selecting, so a blur cannot strand a frozen candidate list for the next Ctrl
    /// release to commit.
    func cancelSessionSwitch() {
        sessionSwitcher.end()
        hideSwitcherOverlay()
    }

    private func showSwitcherOverlay() {
        hideSwitcherOverlay()
        guard let overlay = deckOverlay, let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)),
              let scroller = sessionSwitcherScroller(containing: box) else { return }
        // Focus leaving the terminal cancels the cycle, so the card must never take the keyboard.
        gtk_widget_set_focusable(W(scroller), 0)
        gtk_widget_add_css_class(W(box), "agterm-switcher")
        gtk_widget_add_css_class(W(box), "agterm-interface-panel")
        for id in sessionSwitcher.ordered {
            guard let s = store.session(withID: id), let label = op(gtk_label_new(s.displayName)) else { continue }
            gtk_widget_set_margin_start(W(label), 18); gtk_widget_set_margin_end(W(label), 18)
            gtk_label_set_xalign(label, 0)
            gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_END)
            if id == sessionSwitcher.current { gtk_widget_add_css_class(W(label), "agterm-switcher-current") }
            gtk_box_append(cast(box), W(label))
        }
        switcherBox = scroller
        gtk_overlay_add_overlay(overlay, W(scroller))
    }

    private func hideSwitcherOverlay() {
        if let overlay = deckOverlay, let box = switcherBox { gtk_overlay_remove_overlay(overlay, W(box)) }
        switcherBox = nil
    }

    func sessionSwitcherScroller(containing rows: OpaquePointer) -> OpaquePointer? {
        guard let scroller = op(gtk_scrolled_window_new()) else { return nil }
        let metrics = InterfaceMetrics(fontSize: linuxSettingsStore().load().effectiveInterfaceFontSize)
        let windowHeight = Double(max(1, gtk_widget_get_height(W(window))))
        let maxHeight = Int32(metrics.fittedPanelHeight(windowHeight: windowHeight, topFraction: 0))
        let deckWidth = Double(max(1, gtk_widget_get_width(W(deck))))
        let width = Int32(metrics.fittedPanelWidth(
            idealAtDefault: 460, windowWidth: deckWidth, terminalAreaInset: 0))
        gtk_widget_set_halign(W(scroller), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(W(scroller), GTK_ALIGN_CENTER)
        gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(scroller, maxHeight)
        gtk_scrolled_window_set_propagate_natural_height(scroller, 1)
        gtk_scrolled_window_set_min_content_width(scroller, width)
        gtk_scrolled_window_set_max_content_width(scroller, width)
        gtk_scrolled_window_set_propagate_natural_width(scroller, 1)
        gtk_scrolled_window_set_child(scroller, W(rows))
        return scroller
    }

    // MARK: - Recent/attention popovers

    func sessionPickerScroller(containing rows: OpaquePointer) -> OpaquePointer? {
        guard let scroller = op(gtk_scrolled_window_new()) else { return nil }
        let metrics = InterfaceMetrics(fontSize: linuxSettingsStore().load().effectiveInterfaceFontSize)
        let windowHeight = Double(max(1, gtk_widget_get_height(W(window))))
        let maxHeight = Int32(metrics.fittedPanelHeight(windowHeight: windowHeight, topFraction: 0.12))
        gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(scroller, maxHeight)
        gtk_scrolled_window_set_propagate_natural_height(scroller, 1)
        gtk_scrolled_window_set_child(scroller, W(rows))
        return scroller
    }

    /// Open the mouse-accessible twin of the Ctrl-Tab MRU switcher or attention palette.
    /// These are interactive-only popovers, so no control-socket command is meaningful.
    func showSessionPicker(attention: Bool, anchor: OpaquePointer?) {
        guard let anchor else { return }
        let sessions: [Session]
        if attention {
            sessions = store.attentionSessions
        } else {
            sessions = store.navigableRecentSessions(limit: SessionSwitcherModel.maxCandidates)
                .compactMap { store.session(withID: $0) }
        }
        guard !sessions.isEmpty else { return }

        // Read the capture BEFORE the dismissal consumes it (see `popupPopover`).
        let heldSearchEntry = searchEntryCaptureSurvives(sessionPickerPopover)
        dismissSessionPicker(refocus: false)
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
        gtk_widget_set_size_request(W(rows), interfacePanelWidth(320), -1)

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

        guard let scroller = sessionPickerScroller(containing: rows) else {
            dismissSessionPicker()
            return
        }
        connect(popover, "closed", unsafeBitCast(onSessionPickerClosed as @convention(c)
            (OpaquePointer?, gpointer?) -> Void, to: GCallback.self),
            Unmanaged.passUnretained(self).toOpaque())
        gtk_popover_set_child(POPOVER(popover), W(scroller))
        popupPopover(popover, keepingCapture: heldSearchEntry)
    }

    /// `refocusOnDismiss: false` only from inside `rebuildSidebar()`, whose tail repair takes over.
    func updateRecentSessionsButton(refocusOnDismiss: Bool = true) {
        guard let button = recentSessionsButton else { return }
        let hasOther = !store.navigableRecentSessions(limit: 1).isEmpty
        gtk_widget_set_sensitive(W(button), hasOther ? 1 : 0)
        gtk_widget_set_opacity(W(button), hasOther ? 1 : 0.35)
        if !hasOther, sessionPickerPopover != nil, !sessionPickerShowsAttention {
            dismissSessionPicker(refocus: refocusOnDismiss)
        }
    }

    func activateSessionPickerRow(_ context: SessionPickerRowContext) {
        let id = context.sessionID
        let attention = context.attention
        let statusPane = context.statusPane
        // Read the capture BEFORE the dismissal consumes it; unconditional, NOT through
        // `searchEntryCaptureSurvives` — see that helper's boundary note. `refocus: false` because this
        // handler re-targets focus itself below.
        let popoverHeldSearchEntry = popoverTookKeyboardFromSearchEntry
        dismissSessionPicker(refocus: false)
        selectSession(id)
        if attention {
            handleAutoFollow(id, statusPane: statusPane)
        }
        // The attention leg needs this too: `handleAutoFollow` is shared with the auto-follow timer and
        // declines to focus while a quick terminal is visible. Entry restore first.
        if !(popoverHeldSearchEntry && restoreSearchEntryFocus()) { focusActiveSurface() }
    }

    /// Programmatic dismissal; Escape and click-away arrive at `sessionPickerDidClose` instead. The state
    /// is cleared BEFORE `detachPopover(popdown: true)` pops it down.
    func dismissSessionPicker(refocus: Bool = true) {
        guard let popover = sessionPickerPopover else { return }
        clearSessionPickerState()
        detachPopover(popover, popdown: true, refocus: refocus)
    }

    /// GTK dismissed the picker itself: Escape, or a click away.
    func sessionPickerDidClose(_ popover: OpaquePointer?) {
        guard let popover, popover == sessionPickerPopover else { return }
        clearSessionPickerState()
        detachPopover(popover, popdown: false)
    }

    private func clearSessionPickerState() {
        sessionPickerPopover = nil
        sessionPickerShowsAttention = false
        sessionPickerContexts.removeAll()
        if sessionPickerSuppressesAutoFollow {
            sessionPickerSuppressesAutoFollow = false
            resumeAutoFollow()
        }
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
