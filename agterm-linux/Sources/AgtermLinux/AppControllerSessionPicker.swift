import CGtk
import Foundation
import agtermCore

@MainActor
final class SessionPickerRowContext {
    unowned let controller: AppController
    let windowID: UUID
    let sessionID: UUID
    let attention: Bool

    init(controller: AppController, windowID: UUID, sessionID: UUID, attention: Bool) {
        self.controller = controller
        self.windowID = windowID
        self.sessionID = sessionID
        self.attention = attention
    }
}

@MainActor
final class SwitcherRevealTickContext {
    weak var controller: AppController?
    var ticks = 0

    init(controller: AppController) { self.controller = controller }
}

@MainActor
extension AppController {
    // MARK: - Ctrl-Tab switcher

    /// Cycling moves the overlay highlight ONLY; `commitSessionSwitch` selects on Ctrl release, so one
    /// cycle pushes recency exactly once and a second Ctrl-Tab toggles back.
    func quickSwitchSession(reverse: Bool = false) {
        guard sessionSwitchAllowed else { cancelSessionSwitch(); return }
        if sessionSwitcher.isActive {
            sessionSwitcher.advance(reverse: reverse)
            if switcherScroller == nil { showSwitcherOverlay() } else { markSwitcherSelection() }
        } else {
            let valid = Set(store.navigableSessions.map(\.id))
            sessionSwitcher.begin(store.sessionRecency.top(SessionSwitcherModel.maxCandidates, in: valid))
            if sessionSwitcher.isActive { showSwitcherOverlay() }
        }
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
        // A zoom, pick or dialog that arrived mid-hold commits nothing, as macOS resets on `flagsChanged`.
        guard sessionSwitchAllowed else { cancelSessionSwitch(); return }
        let live = Set(store.workspaces.flatMap { $0.sessions.map(\.id) })
        let target = sessionSwitcher.commitTarget(liveIDs: live)
        sessionSwitcher.end()
        hideSwitcherOverlay()
        if let target { selectSession(target) }
    }

    private var sessionSwitchAllowed: Bool {
        // Every `AdwDialog` presents inside this window, so one visible dialog covers them all.
        SessionSwitcherPolicy.canSwitch(
            zoomed: terminalZoom.target != nil, dashboardOpen: dashboard.isOpen,
            modalPending: pickController.modalPending,
            dialogVisible: adw_application_window_get_visible_dialog(cast(window)) != nil,
            popoverOpen: contextMenuIsOpen || sessionPickerIsOpen
        )
    }

    /// End the cycle and remove the card without selecting.
    func cancelSessionSwitch() {
        sessionSwitcher.end()
        hideSwitcherOverlay()
    }

    private func showSwitcherOverlay() {
        hideSwitcherOverlay()
        guard let overlay = deckOverlay, let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)),
              let scroller = sessionSwitcherScroller(containing: box, placement: switcherPlacement(overlay)),
              let dim = sessionSwitcherDim() else { return }
        // Focus leaving the terminal cancels the cycle, so the card must never take the keyboard.
        gtk_widget_set_focusable(W(scroller), 0)
        for id in sessionSwitcher.ordered {
            guard let session = store.session(withID: id),
                  let row = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 1)),
                  let titleLine = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)),
                  let title = op(gtk_label_new(session.displayName)) else { continue }
            if session.remoteHost != nil, let cloud = op(gtk_image_new_from_icon_name("weather-overcast-symbolic")) {
                gtk_widget_set_tooltip_text(W(cloud), "Remote")
                gtk_box_append(cast(titleLine), W(cloud))
            }
            gtk_label_set_xalign(title, 0)
            gtk_label_set_ellipsize(title, PANGO_ELLIPSIZE_END)
            gtk_box_append(cast(titleLine), W(title))
            gtk_box_append(cast(row), W(titleLine))
            let workspace = store.workspace(forSession: id)?.name ?? ""
            let detail = workspace.isEmpty ? session.switcherDetail : "\(workspace) · \(session.switcherDetail)"
            if let subtitle = op(gtk_label_new(detail)) {
                gtk_label_set_xalign(subtitle, 0)
                gtk_label_set_ellipsize(subtitle, PANGO_ELLIPSIZE_END)
                gtk_widget_add_css_class(W(subtitle), "dim-label")
                gtk_box_append(cast(row), W(subtitle))
            }
            gtk_widget_add_css_class(W(row), "agterm-switcher-row")
            gtk_box_append(cast(box), W(row))
            switcherRows[id] = row
        }
        switcherScroller = scroller
        gtk_box_append(cast(dim), W(scroller))
        gtk_overlay_add_overlay(overlay, W(dim))
        markSwitcherSelection()
    }

    private func markSwitcherSelection() {
        for (id, row) in switcherRows {
            if id == sessionSwitcher.current {
                gtk_widget_add_css_class(W(row), "agterm-switcher-current")
            } else {
                gtk_widget_remove_css_class(W(row), "agterm-switcher-current")
            }
        }
        revealSwitcherSelection()
    }

    /// Scrolls without focusing: the card must never take the keyboard (see `showSwitcherOverlay`).
    private func revealSwitcherSelection() {
        guard tryRevealSwitcherSelection(ticksElapsed: 0) == .wait, switcherRevealTick == 0,
              let scroller = switcherScroller else { return }
        let context = SwitcherRevealTickContext(controller: self)
        switcherRevealTick = gtk_widget_add_tick_callback(
            W(scroller), switcherRevealTickCallback, Unmanaged.passRetained(context).toOpaque(),
            releaseSwitcherRevealTick)
    }

    /// A pending tick reads the live highlight, so an advance while it waits needs no second one.
    fileprivate func retrySwitcherReveal(_ context: SwitcherRevealTickContext) -> gboolean {
        context.ticks += 1
        guard tryRevealSwitcherSelection(ticksElapsed: context.ticks) == .wait else {
            switcherRevealTick = 0
            return 0
        }
        return 1
    }

    private func tryRevealSwitcherSelection(ticksElapsed: Int) -> SessionSwitcherReveal.Step {
        guard let scroller = switcherScroller, let id = sessionSwitcher.current, let row = switcherRows[id],
              let rowWidget = W(row) else { return .giveUp }
        let step = SessionSwitcherReveal.step(rowMapped: gtk_widget_get_mapped(rowWidget) != 0,
                                              rowHeight: Double(gtk_widget_get_height(rowWidget)),
                                              ticksElapsed: ticksElapsed)
        guard step == .reveal else { return step }
        return revealVertically(rowWidget, in: scroller) ? .reveal : .giveUp
    }

    private func hideSwitcherOverlay() {
        if let scroller = switcherScroller, switcherRevealTick != 0 {
            gtk_widget_remove_tick_callback(W(scroller), switcherRevealTick)
        }
        switcherRevealTick = 0
        switcherRows.removeAll()
        if let overlay = deckOverlay, let scroller = switcherScroller, let dim = gtk_widget_get_parent(W(scroller)) {
            gtk_overlay_remove_overlay(overlay, dim)
        }
        switcherScroller = nil
    }

    private func switcherPlacement(_ overlay: OpaquePointer) -> SessionSwitcherPlacement {
        var origin = graphene_point_t(), terminalStart = graphene_point_t()
        if let paned = splitView, let content = gtk_paned_get_end_child(paned),
           gtk_widget_compute_point(content, W(overlay), &origin, &terminalStart) == 0 {
            terminalStart.x = 0
        }
        return SessionSwitcherPlacement(
            metrics: InterfaceMetrics(fontSize: linuxSettingsStore().load().effectiveInterfaceFontSize),
            windowWidth: Double(max(1, gtk_widget_get_width(W(overlay)))),
            windowHeight: Double(max(1, gtk_widget_get_height(W(overlay)))),
            sidebarVisible: store.sidebarVisible, sidebarWidth: Double(terminalStart.x))
    }

    private func sessionSwitcherScroller(containing rows: OpaquePointer,
                                         placement: SessionSwitcherPlacement) -> OpaquePointer? {
        guard let scroller = op(gtk_scrolled_window_new()) else { return nil }
        // Chrome on this fixed frame rather than the scrolled rows keeps both rounded ends in view;
        // GtkViewport clips the rows to the padding.
        gtk_widget_add_css_class(W(scroller), "agterm-switcher")
        gtk_widget_add_css_class(W(scroller), "agterm-interface-panel")
        let width = Int32(placement.contentWidth)
        gtk_widget_set_halign(W(scroller), GTK_ALIGN_START)
        gtk_widget_set_valign(W(scroller), GTK_ALIGN_START)
        gtk_widget_set_margin_start(W(scroller), Int32(placement.left.rounded()))
        gtk_widget_set_margin_top(W(scroller), Int32(placement.marginTop.rounded()))
        // EXTERNAL, not NEVER: GTK ignores the content-width bounds under NEVER and sizes the card to its
        // widest row, so a long cwd pushes it off center and up to the window edge.
        gtk_scrolled_window_set_policy(scroller, GTK_POLICY_EXTERNAL, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(scroller, Int32(placement.contentMaxHeight))
        gtk_scrolled_window_set_propagate_natural_height(scroller, 1)
        gtk_scrolled_window_set_min_content_width(scroller, width)
        gtk_scrolled_window_set_max_content_width(scroller, width)
        gtk_scrolled_window_set_child(scroller, W(rows))
        return scroller
    }

    /// The window-wide backdrop the card sits in, so removing it takes both. A GENERIC-role box would carry
    /// no accessible name, so it is built as a named GROUP for the AT-SPI teardown checks.
    private func sessionSwitcherDim() -> OpaquePointer? {
        var role = GValue()
        g_value_init(&role, gtk_accessible_role_get_type())
        g_value_set_enum(&role, gint(GTK_ACCESSIBLE_ROLE_GROUP.rawValue))
        defer { g_value_unset(&role) }
        let built = "accessible-role".withCString { name -> UnsafeMutablePointer<GObject>? in
            var names: [UnsafePointer<CChar>?] = [name]
            return g_object_new_with_properties(gtk_box_get_type(), 1, &names, &role)
        }
        guard let built else { return nil }
        let dim = OpaquePointer(built)
        gtk_widget_add_css_class(W(dim), "agterm-switcher-dim")
        gtk_widget_set_can_target(W(dim), 0)
        gtk_widget_set_focusable(W(dim), 0)
        var property = GTK_ACCESSIBLE_PROPERTY_LABEL
        var label = GValue()
        gtk_accessible_property_init_value(property, &label)
        g_value_set_string(&label, "Session switcher")
        gtk_accessible_update_property_value(dim, 1, &property, &label)
        g_value_unset(&label)
        return dim
    }

    // MARK: - Recent/attention popovers

    func sessionPickerScroller(containing rows: OpaquePointer) -> OpaquePointer? {
        guard let scroller = op(gtk_scrolled_window_new()) else { return nil }
        let metrics = InterfaceMetrics(fontSize: linuxSettingsStore().load().effectiveInterfaceFontSize)
        let windowHeight = Double(max(1, gtk_widget_get_height(W(window))))
        let maxHeight = Int32(metrics.fittedPanelHeight(
            windowHeight: windowHeight, topFraction: SessionSwitcherPlacement.topInsetFraction))
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
        let entries: [(windowID: UUID, session: Session, subtitle: String)]
        if attention {
            entries = library.attentionAcrossWindows.map {
                ($0.window.id, $0.session, library.attentionSubtitle($0))
            }
        } else {
            entries = store.navigableRecentSessions(limit: SessionSwitcherModel.maxCandidates)
                .compactMap { id -> (UUID, Session, String)? in
                    guard let session = store.session(withID: id) else { return nil }
                    let workspace = store.workspace(forSession: id)?.name ?? ""
                    let subtitle = workspace.isEmpty ? session.switcherDetail
                        : "\(workspace) · \(session.switcherDetail)"
                    return (windowID, session, subtitle)
                }
        }
        guard !entries.isEmpty else { return }

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

        // One read for the whole popover — `SettingsStore.load()` is an uncached file read — and only
        // the attention palette renders glyphs at all.
        let glyphSettings = attention ? linuxSettingsStore().load() : nil
        for entry in entries {
            let session = entry.session
            guard let button = op(gtk_button_new()), let row = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)),
                  let labels = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 1)) else { continue }
            gtk_button_set_has_frame(BUTTON(button), 0)
            gtk_widget_set_halign(W(button), GTK_ALIGN_FILL)
            gtk_widget_set_hexpand(W(button), 1)
            (attention ? "attention-session-row" : "recent-session-row").withCString {
                gtk_widget_set_name(W(button), $0)
            }

            if let glyphSettings, let icon = Self.makeStatusGlyphLabel(
                session.agentIndicator, settings: glyphSettings,
                phase: sidebarRuntime.blinkPhase.phase
            ) {
                sidebarRuntime.pickerGlyphs[session.id] = icon
                gtk_box_append(cast(row), W(icon))
            }

            let titleLine = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4))
            if session.remoteHost != nil, let cloud = op(gtk_image_new_from_icon_name("weather-overcast-symbolic")) {
                gtk_widget_set_tooltip_text(W(cloud), "Remote")
                gtk_box_append(cast(titleLine), W(cloud))
            }
            let title = op(gtk_label_new(session.displayName))
            gtk_label_set_xalign(title, 0)
            gtk_widget_add_css_class(W(title), "heading")
            gtk_box_append(cast(titleLine), W(title))
            gtk_box_append(cast(labels), W(titleLine))
            let subtitle = op(gtk_label_new(entry.subtitle))
            gtk_label_set_xalign(subtitle, 0)
            gtk_widget_add_css_class(W(subtitle), "dim-label")
            gtk_box_append(cast(labels), W(subtitle))
            gtk_widget_set_hexpand(W(labels), 1)
            gtk_box_append(cast(row), W(labels))
            gtk_button_set_child(BUTTON(button), W(row))

            let context = SessionPickerRowContext(controller: self, windowID: entry.windowID, sessionID: session.id,
                                                  attention: attention)
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
        resyncBlinkPhase()
    }

    /// The open attention popover's glyphs are refreshed in place by the sidebar sync, so a status the
    /// model takes while it is up shows there too instead of waiting for the popover to be rebuilt.
    func updateSessionPickerStatusIcons(settings: AppSettings) {
        for (id, icon) in sidebarRuntime.pickerGlyphs {
            let indicator = library.store(forSession: id)?.session(withID: id)?.agentIndicator ?? AgentIndicator()
            Self.applyStatusGlyph(indicator, settings: settings,
                                  phase: sidebarRuntime.blinkPhase.phase, to: icon)
        }
    }

    /// `refocusOnDismiss: false` only from inside the sidebar sync, whose tail repair takes over.
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
        // Resolve the live status after dismissal; a row can go idle or change pane while the picker is open.
        let targetWindow = context.windowID
        // Read the capture BEFORE the dismissal consumes it; unconditional, NOT through
        // `searchEntryCaptureSurvives` — see that helper's boundary note. `refocus: false` because this
        // handler re-targets focus itself below.
        let popoverHeldSearchEntry = popoverTookKeyboardFromSearchEntry
        dismissSessionPicker(refocus: false)
        if attention {
            if targetWindow != windowID {
                MainTimer.schedule(after: 0) { [weak self] in
                    self?.selectAttention(windowID: targetWindow, sessionID: id)
                }
                return
            }
            selectAttention(windowID: targetWindow, sessionID: id)
        } else {
            selectSession(id)
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

    /// `contextMenuIsOpen`'s twin: visibility, not the bare handle.
    var sessionPickerIsOpen: Bool {
        guard let popover = sessionPickerPopover else { return false }
        return gtk_widget_get_visible(W(popover)) != 0
    }

    private func clearSessionPickerState() {
        // Before anything pops the popover down: its glyph labels die with it, and the blink timer must
        // stop tracking them while they are still valid to read.
        sidebarRuntime.pickerGlyphs.removeAll()
        resyncBlinkPhase()
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

// GTK's imported tick typealiases take no actor annotation, so the retained context crosses as an address
// (see `sidebarScrollRetryTick`).
private let switcherRevealTickCallback: GtkTickCallback = { _, _, data in
    guard let data else { return 0 }
    let address = Int(bitPattern: data)
    return MainActor.assumeIsolated {
        guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return gboolean(0) }
        let context = Unmanaged<SwitcherRevealTickContext>.fromOpaque(raw).takeUnretainedValue()
        return context.controller?.retrySwitcherReveal(context) ?? 0
    }
}

private let releaseSwitcherRevealTick: GDestroyNotify = { data in
    guard let data else { return }
    let address = Int(bitPattern: data)
    MainActor.assumeIsolated {
        guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<SwitcherRevealTickContext>.fromOpaque(raw).release()
    }
}
