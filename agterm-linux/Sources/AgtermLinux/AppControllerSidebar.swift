import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    static var sidebarFontProvider: OpaquePointer?
    static var interfaceFontProvider: OpaquePointer?

    func scheduleWorkspaceToggle(_ data: gpointer?) {
        guard Self.workspaceRowToggleEnabled(linuxSettingsStore().load().workspaceRowClickExpands),
              let data, let workspaceID = workspaceDiscButtons[OpaquePointer(data)] else { return }
        cancelPendingWorkspaceToggle()
        pendingWorkspaceToggle = workspaceID
        cancelPendingWorkspaceToggleTimer = MainTimer.schedule(after: 0.3) { [weak self] in
            self?.firePendingWorkspaceToggle()
        }
    }

    func cancelPendingWorkspaceToggle() {
        cancelPendingWorkspaceToggleTimer?()
        cancelPendingWorkspaceToggleTimer = nil
        pendingWorkspaceToggle = nil
    }

    func firePendingWorkspaceToggle() {
        cancelPendingWorkspaceToggleTimer = nil
        guard let workspaceID = pendingWorkspaceToggle else { return }
        pendingWorkspaceToggle = nil
        guard Self.workspaceRowToggleEnabled(linuxSettingsStore().load().workspaceRowClickExpands) else { return }
        let isExpanded = store.workspaces.first(where: { $0.id == workspaceID })?.isExpanded ?? true
        store.setWorkspaceExpanded(workspaceID, expanded: !isExpanded)
        rebuildSidebarKeepingKeyboard()
    }

    static func workspaceRowToggleEnabled(_ setting: Bool?) -> Bool { setting ?? true }

    func newSession(in workspaceID: UUID) {
        noteUserActivity()
        guard store.addSession(toWorkspace: workspaceID, cwd: newSessionCwd()) != nil else { return }
        reconcile()
    }

    func installSidebarDirectoryDropTarget() {
        let drop = gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY)
        connect(drop, "drop", unsafeBitCast(onSidebarDirectoryDrop as @convention(c)
            (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean,
            to: GCallback.self))
        gtk_widget_add_controller(W(sidebarBox), drop)
    }

    func syncSidebarSelection() {
        syncSidebarSelectionStyles()
        if let active = store.selectedSessionID,
           let row = rowSession.first(where: { $0.value == active })?.key {
            scrollRowIntoView(row)
        }
    }

    func updateSessionName(_ id: UUID) {
        guard renaming?.id != id,
              let session = store.session(withID: id),
              let widget = sessionNameWidgets[id] else { return }
        let text = store.sidebarMode == .flagged
            ? LinuxSidebarPolicy.flaggedRowLabel(for: session, in: store)
            : session.displayName
        text.withCString { gtk_label_set_text(widget, $0) }
    }

    /// One pass over every live row through the effective-selection predicate, so the CSS paint and
    /// the published accessible state always describe the same model selection (the choke-point
    /// contract — see `setSidebarSelectionStyle`).
    func syncSidebarSelectionStyles() {
        let selection = store.sidebarSelectionIDs
        for (row, id) in rowSession {
            setSidebarSelectionStyle(row, selected: LinuxSidebarPolicy.sessionIsInEffectiveSelection(
                id, selection: selection, activeID: store.selectedSessionID))
        }
    }

    func applySidebarFontSize() {
        guard let display = gdk_display_get_default() else { return }
        let settings = linuxSettingsStore().load()
        let css = LinuxSidebarPolicy.sidebarCSS(fontSize: settings.sidebarFontSize)
        if Self.sidebarFontProvider == nil {
            let provider = OpaquePointer(gtk_css_provider_new())
            Self.sidebarFontProvider = provider
            gtk_style_context_add_provider_for_display(display, provider, 651)
        }
        if let provider = Self.sidebarFontProvider {
            css.withCString { gtk_css_provider_load_from_string(cast(provider), $0) }
        }
        // The width floor is NOT refreshed here: GTK revalidates a CSS node only on the next frame, so a
        // measure taken now would still report the OLD font size. Every caller follows this with
        // `rebuildSidebar`, which measures the floor off labels rebuilt under the new CSS.
    }

    func applyInterfaceFontSize() {
        guard let display = gdk_display_get_default() else { return }
        let metrics = InterfaceMetrics(fontSize: linuxSettingsStore().load().effectiveInterfaceFontSize)
        let css = """
        .agterm-interface-panel, .agterm-interface-panel entry, .agterm-interface-panel label {
            font-size: \(metrics.base)pt;
        }
        .agterm-interface-panel .dim-label, .agterm-interface-panel .agterm-palette-badge {
            font-size: \(metrics.secondary)pt;
        }
        """
        if Self.interfaceFontProvider == nil {
            let provider = OpaquePointer(gtk_css_provider_new())
            Self.interfaceFontProvider = provider
            gtk_style_context_add_provider_for_display(display, provider, 651)
        }
        if let provider = Self.interfaceFontProvider {
            css.withCString { gtk_css_provider_load_from_string(cast(provider), $0) }
        }
    }

    func interfacePanelWidth(_ width: Double) -> Int32 {
        let metrics = InterfaceMetrics(fontSize: linuxSettingsStore().load().effectiveInterfaceFontSize)
        let windowWidth = Double(max(1, gtk_widget_get_width(W(window))))
        let sidebarInset = store.sidebarVisible ? Double(max(0, gtk_widget_get_width(W(sidebarBox)))) : 0
        let fittedWidth = metrics.fittedPanelWidth(
            idealAtDefault: width, windowWidth: windowWidth, terminalAreaInset: sidebarInset)
        return Int32(fittedWidth)
    }

    func interfacePanelSize(width: Double, height: Double) -> (Int32, Int32) {
        let metrics = InterfaceMetrics(fontSize: linuxSettingsStore().load().effectiveInterfaceFontSize)
        let windowHeight = Double(max(1, gtk_widget_get_height(W(window))))
        let fittedHeight = min(metrics.scaled(height), metrics.fittedPanelHeight(
            windowHeight: windowHeight, topFraction: 0))
        return (interfacePanelWidth(width), Int32(fittedHeight))
    }

    /// Whether a sidebar interaction is live: an inline rename, an open context menu, or parked keyboard.
    ///
    /// `rebuildSidebar()` destroys and re-creates every row, so an ASYNC rebuild must not land here — it
    /// would tear down the in-progress rename entry (whose disposal fires a focus-out that commits its
    /// half-typed text) and dismiss the open menu, from a timer the user never asked for. Both deferred
    /// rebuilds — the sidebar-metadata refresh and the trailing soft-close reconcile — gate on this ONE
    /// predicate so they cannot drift apart. A SYNCHRONOUS rebuild is a direct consequence of a user action
    /// and is deliberately not gated.
    var sidebarInteractionInProgress: Bool {
        renaming != nil || contextMenuIsOpen || sidebarHoldsKeyboardFocus
    }

    /// Whether the window's focus widget is a LIVE sidebar widget — one `rebuildSidebar()` would destroy.
    /// The `mapped` test keeps the gate self-clearing: focus inside a HIDDEN sidebar or a minimized window
    /// would otherwise stall the refresh forever.
    var sidebarHoldsKeyboardFocus: Bool {
        guard let focus = gtk_window_get_focus(WIN(window)),
              gtk_widget_is_ancestor(focus, W(sidebarBox)) != 0 else { return false }
        return gtk_widget_get_mapped(focus) != 0
    }

    /// How long a deferred rebuild waits before re-checking `sidebarInteractionInProgress`. It belongs to the
    /// GATE rather than to either job: the metadata refresh and the soft-close reconcile are unrelated jobs
    /// that happen to defer on the same predicate, so neither owning the other's retry cadence.
    static let sidebarInteractionRetryInterval: TimeInterval = 0.25

    /// For a handler that can be driven BY KEYBOARD from a sidebar widget the rebuild then destroys.
    /// Safe from a deferred caller too: `refocusIfStranded()` is steal-proof by its own guard.
    func rebuildSidebarKeepingKeyboard() {
        rebuildSidebar()
        refocusIfStranded()
    }

    func rebuildSidebar() {
        let settings = linuxSettingsStore().load()
        // GtkPopover is parented to the row's GtkListBox while its context menu is open. Detach it
        // before destroying that list box: GtkListBox disposal otherwise treats the popover as a row,
        // repeatedly fails to remove it, and starves the GTK main loop. Both dismissals below take
        // `refocus: false` — a grab fires `surfaceDidFocus`, which RE-ENTERS this function — so the
        // keyboard repair runs at the TAIL instead, and the capture is read BEFORE them: `detachPopover`
        // consumes it even under `refocus: false`.
        let popoverHeldSearchEntry = popoverTookKeyboardFromSearchEntry
        let dismissedContextMenu = contextMenuPopover != nil
        dismissContextMenu(refocus: false)
        // `updateAttentionButton` may dismiss an open session picker one statement later.
        let hadSessionPicker = sessionPickerPopover != nil
        updateAttentionButton(settings: settings, refocusOnDismiss: false)
        let dismissedSessionPicker = hadSessionPicker && sessionPickerPopover == nil
        updateDashboardStatusIndicators()
        while let child = gtk_widget_get_first_child(W(sidebarBox)) {
            gtk_box_remove(cast(sidebarBox), child)
        }
        rowSession.removeAll()
        nameLabels.removeAll()
        sessionNameWidgets.removeAll()
        workspaceDiscButtons.removeAll()
        updateWorkspaceFilterButton()

        if store.sidebarMode == .flagged {
            appendSection("Flagged", store.flaggedSessions, settings: settings)
            if store.flaggedSessions.isEmpty {
                if let hint = op(gtk_label_new("No flagged sessions.\nRight-click a session → Flag.")) {
                    gtk_label_set_justify(hint, GTK_JUSTIFY_CENTER)
                    // Fixed instructional text wraps rather than ellipsizes: wrapping drops the minimum
                    // width from the longest line to the longest word, which is all the sidebar needs.
                    gtk_label_set_wrap(hint, 1)
                    gtk_widget_set_margin_top(W(hint), 24)
                    gtk_widget_add_css_class(W(hint), "dim-label")
                    gtk_box_append(cast(sidebarBox), W(hint))
                }
            }
        } else {
            for ws in store.visibleWorkspaces {
                appendSection(ws.name, ws.sessions, workspace: ws.id, settings: settings)
            }
        }
        refreshSidebarWidthFloor()
        // GtkListBoxRow resets the published SELECTED state while GTK roots the rebuilt hierarchy
        // (the list intentionally stays in GTK_SELECTION_NONE, so nothing re-derives it). Re-publish
        // from the current model on the next main-loop turn, after every row is rooted; later
        // selection changes update synchronously. Disarmed in `windowWillClose` — a pending job
        // must not touch a destroyed widget tree (`.claude/rules/main-loop.md`).
        selectionRepublish.arm { [weak self] in self?.syncSidebarSelectionStyles() }
        // Only when a dismissal above actually took a popover down, since it skipped its own grab. The
        // `refocusIfStranded()` leg can re-enter this function through `surfaceDidFocus` — bounded, as it
        // is the last statement and the rebuild above is complete.
        if dismissedContextMenu || dismissedSessionPicker {
            if !(popoverHeldSearchEntry && restoreSearchEntryFocus()) { refocusIfStranded() }
        }
    }

    private func updateWorkspaceFilterButton() {
        guard let button = footerFocusFilterButton else { return }
        let hasMembers = !store.focusedWorkspaceIDs.isEmpty
        gtk_widget_set_sensitive(W(button), hasMembers ? 1 : 0)
        let tooltip = store.focusEnabled
            ? "Show All Workspaces"
            : "Show Only Focused Workspaces"
        tooltip.withCString { gtk_widget_set_tooltip_text(W(button), $0) }
        if store.focusEnabled {
            gtk_widget_add_css_class(W(button), "accent")
        } else {
            gtk_widget_remove_css_class(W(button), "accent")
        }
    }

    private func appendSection(_ title: String, _ sessions: [Session], workspace: UUID? = nil,
                               settings: AppSettings) {
        if let wsID = workspace, let row = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)) {
            "workspace-row".withCString { gtk_widget_set_name(W(row), $0) }
            gtk_widget_set_margin_top(W(row), 8)
            gtk_widget_set_margin_start(W(row), 4)
            let collapsed = !(store.workspaces.first(where: { $0.id == wsID })?.isExpanded ?? true)
            if let disc = op(gtk_button_new_from_icon_name(collapsed ? "pan-end-symbolic" : "pan-down-symbolic")) {
                gtk_button_set_has_frame(BUTTON(disc), 0)
                gtk_widget_set_focus_on_click(W(disc), 0)
                gtk_widget_add_css_class(W(disc), "flat")
                workspaceDiscButtons[disc] = wsID
                connect(disc, "clicked", unsafeBitCast(onWorkspaceDisclosure as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), RAW(disc))
                gtk_box_append(cast(row), W(disc))
            }
            let workspaceIcon = op(gtk_image_new_from_icon_name("agterm-grid-symbolic"))
            if store.focusedWorkspaceIDs.contains(wsID) {
                gtk_widget_add_css_class(W(workspaceIcon), "accent")
                "In workspace focus set".withCString { gtk_widget_set_tooltip_text(W(workspaceIcon), $0) }
            }
            gtk_box_append(cast(row), W(workspaceIcon))
            if let name = makeNameWidget(id: wsID, text: title, isWorkspace: true) {
                gtk_widget_add_css_class(W(name), "heading")
                gtk_box_append(cast(row), W(name))
            }
            if !settings.isInterfaceElementHidden(.workspaceAddSession),
               let add = op(gtk_button_new_from_icon_name("list-add-symbolic")) {
                gtk_button_set_has_frame(BUTTON(add), 0)
                gtk_widget_set_focus_on_click(W(add), 0)
                gtk_widget_add_css_class(W(add), "flat")
                gtk_widget_add_css_class(W(add), "workspace-add-session")
                "New Session in \(title)".withCString { gtk_widget_set_tooltip_text(W(add), $0) }
                workspaceDiscButtons[add] = wsID
                connect(add, "clicked", unsafeBitCast(onWorkspaceAddSession as @convention(c)
                    (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
                gtk_box_append(cast(row), W(add))
            }
            workspaceDiscButtons[row] = wsID
            let wsLeftClick = gtk_gesture_click_new()
            gtk_gesture_single_set_button(wsLeftClick, 1)
            connect(wsLeftClick, "released", unsafeBitCast(onWorkspaceRowClick as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), RAW(row))
            gtk_widget_add_controller(W(row), wsLeftClick)
            let wsRightClick = gtk_gesture_click_new()
            gtk_gesture_single_set_button(wsRightClick, 3)
            connect(wsRightClick, "pressed", unsafeBitCast(onWorkspaceRightClick as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), RAW(row))
            gtk_widget_add_controller(W(row), wsRightClick)
            let wdrag = gtk_drag_source_new()
            gtk_drag_source_set_actions(wdrag, GDK_ACTION_MOVE)
            connect(wdrag, "prepare", unsafeBitCast(onHeaderDragPrepare as @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer?, to: GCallback.self))
            gtk_widget_add_controller(W(row), wdrag)
            let wdrop = gtk_drop_target_new(GType(64), GDK_ACTION_MOVE)
            connect(wdrop, "drop", unsafeBitCast(onHeaderDrop as @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean, to: GCallback.self))
            gtk_widget_add_controller(W(row), wdrop)
            let directoryDrop = gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY)
            connect(directoryDrop, "drop", unsafeBitCast(onSidebarDirectoryDrop as @convention(c)
                (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean,
                to: GCallback.self))
            gtk_widget_add_controller(W(row), directoryDrop)
            gtk_box_append(cast(sidebarBox), W(row))
        } else if let header = op(gtk_label_new(title)) {
            gtk_label_set_xalign(header, 0)
            gtk_widget_add_css_class(W(header), "heading")
            gtk_widget_set_margin_top(W(header), 8)
            gtk_widget_set_margin_start(W(header), 8)
            gtk_box_append(cast(sidebarBox), W(header))
        }

        if let wsID = workspace, !(store.workspaces.first(where: { $0.id == wsID })?.isExpanded ?? true) { return }

        guard let lb = op(gtk_list_box_new()) else { return }
        gtk_widget_add_css_class(W(lb), "navigation-sidebar")
        if workspace != nil { gtk_widget_set_margin_start(W(lb), 14) }
        // Selection mode NONE: the custom shift/ctrl logic owns selection (painted through the
        // `agterm-selected` class), which lets the session-row click gesture run WITHOUT claiming
        // the sequence — see agterm-linux/docs/sidebar.md (no claiming click gesture).
        gtk_list_box_set_selection_mode(lb, GTK_SELECTION_NONE)

        for s in sessions {
            guard let row = makeRow(s) else { continue }
            gtk_list_box_append(lb, W(row))
            rowSession[row] = s.id
            // Publish for EVERY fresh row, not only the selected ones (an untouched row would
            // otherwise carry an UNDEFINED accessible SELECTED state until the first sync),
            // through the same effective-selection predicate the sync pass uses.
            setSidebarSelectionStyle(row, selected: LinuxSidebarPolicy.sessionIsInEffectiveSelection(
                s.id, selection: store.sidebarSelectionIDs, activeID: store.selectedSessionID))
        }
        gtk_box_append(cast(sidebarBox), W(lb))
    }

    private func makeRow(_ s: Session) -> OpaquePointer? {
        guard let row = op(gtk_list_box_row_new()), let box = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)) else { return nil }
        "session-row".withCString { gtk_widget_set_name(W(row), $0) }
        gtk_widget_add_css_class(W(box), "agterm-session-row-content")
        if let lead = op(gtk_image_new_from_icon_name("utilities-terminal-symbolic")) {
            gtk_widget_set_margin_start(W(lead), 6)
            gtk_box_append(cast(box), W(lead))
        }
        let flaggedView = store.sidebarMode == .flagged
        // The flagged row normally includes its workspace breadcrumb, but inline rename must edit only
        // the session's bare display name. Reuse the normal name widget for the active rename so the
        // entry is created and seeded without the breadcrumb.
        let breadcrumb = flaggedView && renaming?.id != s.id
        let label = breadcrumb
            ? op(gtk_label_new(LinuxSidebarPolicy.flaggedRowLabel(for: s, in: store)))
            : makeNameWidget(id: s.id, text: s.displayName, isWorkspace: false)
        sessionNameWidgets[s.id] = label
        gtk_widget_set_hexpand(W(label), 1)
        gtk_widget_set_margin_top(W(label), 4)
        gtk_widget_set_margin_bottom(W(label), 4)
        gtk_widget_set_margin_start(W(label), 4)
        // Guard on `breadcrumb`, not the weaker `flaggedView`: renaming in flagged view takes the
        // makeNameWidget branch, and a GtkLabel setter on the GtkEntry it returns raises a GTK critical.
        if breadcrumb {
            gtk_label_set_xalign(label, 0)
            // END even though the breadcrumb ends in the workspace: the flagged view is already
            // workspace-scoped, so the tail is what can be given up first.
            gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_END)
            LinuxSidebarPolicy.flaggedRowLabel(for: s, in: store).withCString {
                gtk_widget_set_tooltip_text(W(label), $0)
            }
        }
        gtk_box_append(cast(box), W(label))
        if let glyph = Self.makeStatusGlyph(
            s.agentIndicator, settings: linuxSettingsStore().load()
        ) {
            gtk_box_append(cast(box), W(glyph))
        }
        if s.flagged, !flaggedView {
            gtk_box_append(cast(box), W(op(gtk_image_new_from_icon_name("starred-symbolic"))))
        }
        if s.unseenCount > 0, badgeEnabled, let badge = op(gtk_label_new(nil)) {
            let text = s.unseenCount > 99 ? "99+" : "\(s.unseenCount)"
            "<span background=\"#cc3333\" foreground=\"white\"> \(text) </span>".withCString { gtk_label_set_markup(badge, $0) }
            gtk_box_append(cast(box), W(badge))
        }
        // Keep the trailing inset inside the content box as CSS `padding-right` (installAppCSS),
        // rather than shrinking the row that paints the rounded selection background. This mirrors
        // the leading icon's margin_start on the left.
        gtk_list_box_row_set_child(GLBR(row), W(box))
        // Rows are PASSIVE: under GTK_SELECTION_NONE the list box's built-in click gesture would
        // still move keyboard focus to a selectable/activatable row on release — after showActive()
        // already gave the terminal focus on press — sending subsequent typing into the sidebar.
        // Non-selectable + non-activatable makes the box's click handling skip the row, and
        // focusable=FALSE is ALSO required: GtkListBoxRow is focusable by default, so the
        // toplevel's click-to-focus would still move keyboard focus onto the row (verified by the
        // sidebar-click-rename AT-SPI scenario's typing leg, which lands in the sidebar without it).
        gtk_list_box_row_set_selectable(GLBR(row), 0)
        gtk_list_box_row_set_activatable(GLBR(row), 0)
        gtk_widget_set_focusable(W(row), 0)
        let selectClick = gtk_gesture_click_new()
        gtk_gesture_single_set_button(selectClick, 1)
        gtk_event_controller_set_propagation_phase(selectClick, GTK_PHASE_CAPTURE)
        connect(selectClick, "pressed", unsafeBitCast(onSessionRowPress, to: GCallback.self), RAW(row))
        connect(selectClick, "released", unsafeBitCast(onSessionRowRelease, to: GCallback.self), RAW(row))
        gtk_widget_add_controller(W(row), selectClick)
        let rightClick = gtk_gesture_click_new()
        gtk_gesture_single_set_button(rightClick, 3)
        gtk_event_controller_set_propagation_phase(rightClick, GTK_PHASE_CAPTURE)
        connect(rightClick, "pressed", unsafeBitCast(onSessionRowContextClick, to: GCallback.self), RAW(row))
        gtk_widget_add_controller(W(row), rightClick)
        if !flaggedView {
            let drag = gtk_drag_source_new()
            gtk_drag_source_set_actions(drag, GDK_ACTION_MOVE)
            connect(drag, "prepare", unsafeBitCast(onRowDragPrepare as @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer?, to: GCallback.self))
            gtk_widget_add_controller(W(row), drag)
            let drop = gtk_drop_target_new(GType(64), GDK_ACTION_MOVE)
            connect(drop, "drop", unsafeBitCast(onRowDrop as @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean, to: GCallback.self))
            gtk_widget_add_controller(W(row), drop)
            let directoryDrop = gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY)
            connect(directoryDrop, "drop", unsafeBitCast(onSidebarDirectoryDrop as @convention(c)
                (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean,
                to: GCallback.self))
            gtk_widget_add_controller(W(row), directoryDrop)
        }
        return row
    }

    /// The sidebar selection choke point: ONE paint path (the `agterm-selected` CSS class on the
    /// row) and ONE a11y path (`GTK_ACCESSIBLE_STATE_SELECTED` on the row
    /// accessible, via `publishRowAccessibleSelected`). Every selection change routes through here
    /// — `syncSidebarSelectionStyles`' single predicate pass and the initial paint in
    /// `appendSection`'s build loop — so the visual highlight and the published accessible state
    /// cannot drift apart.
    /// See agterm-linux/docs/sidebar.md (selection contract).
    private func setSidebarSelectionStyle(_ row: OpaquePointer, selected: Bool) {
        if selected {
            gtk_widget_add_css_class(W(row), "agterm-selected")
        } else {
            gtk_widget_remove_css_class(W(row), "agterm-selected")
        }
        publishRowAccessibleSelected(row, selected: selected)
    }

    /// Publish `GTK_ACCESSIBLE_STATE_SELECTED` on the ROW accessible — the a11y half of the
    /// selection contract (see `setSidebarSelectionStyle` for the contract itself). The state goes
    /// and CSS class both go on the row; its child is presentation only. Verified over AT-SPI on
    /// GTK 4.22: the row's `STATE_SELECTED` follows this
    /// call (present on the selected row, absent after deselection).
    private func publishRowAccessibleSelected(_ row: OpaquePointer, selected: Bool) {
        var state = GTK_ACCESSIBLE_STATE_SELECTED
        var value = GValue()
        // `gtk_accessible_state_init_value` types the GValue for the state: SELECTED is
        // boolean-or-undefined, which GTK's language-binding API represents as G_TYPE_INT
        // (false/true/undefined), not G_TYPE_BOOLEAN — a boolean GValue trips a
        // GLib-GObject-CRITICAL and the update is silently dropped (observed on GTK 4.22).
        gtk_accessible_state_init_value(state, &value)
        g_value_set_int(&value, selected ? 1 : 0)
        // The row passes as-is: GTK_ACCESSIBLE() is a C macro, and GtkAccessible's instance
        // struct is never defined (G_DECLARE_INTERFACE), so `GtkAccessible *` imports as the
        // same bare OpaquePointer every widget is stored as.
        gtk_accessible_update_state_value(row, 1, &state, &value)
        g_value_unset(&value)
    }

    /// `refocusOnDismiss: false` only from `rebuildSidebar()`, whose tail repair takes over.
    func updateAttentionButton(settings: AppSettings? = nil, refocusOnDismiss: Bool = true) {
        updateRecentSessionsButton(refocusOnDismiss: refocusOnDismiss)
        guard let button = attentionButton else { return }
        let enabled = (settings ?? linuxSettingsStore().load()).attentionButtonEnabled ?? false
        gtk_widget_set_visible(W(button), enabled ? 1 : 0)
        let sessions = store.attentionSessions
        gtk_widget_set_sensitive(W(button), sessions.isEmpty ? 0 : 1)
        let hasBlocked = sessions.contains { $0.agentIndicator.status == .blocked }
        gtk_button_set_icon_name(BUTTON(button), hasBlocked ? "dialog-warning-symbolic" : "emblem-important-symbolic")
        if !enabled || sessions.isEmpty, sessionPickerPopover != nil, sessionPickerShowsAttention {
            dismissSessionPicker(refocus: refocusOnDismiss)
        }
    }

    func session(forRow row: OpaquePointer?) -> UUID? {
        guard let row else { return nil }
        return rowSession[row]
    }

    /// `SidebarDrop.resolveSessions` expects an INSERTION SLOT: the old `SidebarDrop.onItemIndex`
    /// redirected every drop to `sessionIndex + 1` ("insert after target"), which made the FIRST slot
    /// unreachable. The slot comes from the drop's `y` against the target row's midpoint
    /// (`LinuxSidebarPolicy.dropInsertionSlot`): top half inserts before the target, bottom half after.
    func handleSessionDrop(source: UUID, onto target: UUID, y: Double, targetHeight: Double) {
        guard let tgt = store.sessionLocation(ofSession: target) else { return }
        let dropTarget = SidebarDrop.SessionDropTarget.sessionRow(workspace: tgt.workspace, sessionIndex: tgt.index, sessionCount: tgt.count)
        let slot = LinuxSidebarPolicy.dropInsertionSlot(targetIndex: tgt.index, y: y, height: targetHeight)
        let ids = LinuxSidebarPolicy.draggedSessionBlock(source: source, selection: store.sidebarSelectionIDs)
        let sources = ids.compactMap { id -> SidebarDrop.SessionSource? in
            guard let location = store.sessionLocation(ofSession: id) else { return nil }
            return SidebarDrop.SessionSource(workspace: location.workspace, index: location.index)
        }
        guard let resolution = SidebarDrop.resolveSessions(sources: sources, target: dropTarget,
                                                           childIndex: slot) else { return }
        store.moveSessions(ids, toWorkspace: resolution.workspace, at: resolution.destination)
        reconcile()
    }

    private func sessionClickIsModified(_ modifiers: UInt32) -> Bool {
        modifiers & (UInt32(GDK_SHIFT_MASK.rawValue) | UInt32(GDK_CONTROL_MASK.rawValue)) != 0
    }

    /// The press half of a session-row click: apply immediately unless the tracker defers
    /// (a plain press inside the current selection collapses on release instead, so a block drag
    /// keeps its block — see `LinuxSidebarPolicy.SessionClickTracker`).
    /// A press on the row being INLINE-RENAMED is ignored entirely: it is a caret/selection click
    /// inside the rename entry, and running the selection logic would `grab_focus` the terminal,
    /// firing the entry's focus-leave commit mid-edit.
    func handleSessionRowPress(_ id: UUID, modifiers: UInt32) {
        guard renaming?.id != id else { return }
        // A press is user activity even when the tracker DEFERS the selection change: a deferred
        // press is how every block drag starts, and once the drag claims the sequence the release
        // (the other activity-noting path) never fires — so without this the idle auto-follow
        // timer keeps running through the hold/drag and its fire would replace
        // `sidebarSelectionIDs` before `handleSessionDrop` reads the block.
        noteUserActivity()
        let applyNow = sessionClickTracker.press(
            id,
            modified: sessionClickIsModified(modifiers),
            alreadyInSelection: LinuxSidebarPolicy.sessionIsInEffectiveSelection(
                id, selection: store.sidebarSelectionIDs, activeID: store.selectedSessionID))
        guard applyNow else { return }
        handleSessionRowClick(id, modifiers: modifiers)
    }

    /// The release half: collapse to just the clicked row, but ONLY when the matching press
    /// deferred — the tracker remembers the press decision, so release-time modifier state is
    /// irrelevant (a shift/ctrl key lifted before the button cannot collapse the multi-selection
    /// that same click just built). Never fires for a completed drag — past the drag threshold the
    /// `GtkDragSource` claims the sequence and the click gesture is cancelled before `released`.
    func handleSessionRowRelease(_ id: UUID) {
        guard renaming?.id != id else { return }
        guard sessionClickTracker.release(id) else { return }
        handleSessionRowClick(id, modifiers: 0)
    }

    func handleSessionRowClick(_ id: UUID, modifiers: UInt32) {
        let visible = store.navigableSessions.map(\.id)
        let current = store.sidebarSelectionIDs
        let shift = modifiers & UInt32(GDK_SHIFT_MASK.rawValue) != 0
        let control = modifiers & UInt32(GDK_CONTROL_MASK.rawValue) != 0
        var selected: [UUID]
        if shift, let anchor = sidebarSelectionAnchor ?? store.selectedSessionID,
           let start = visible.firstIndex(of: anchor), let end = visible.firstIndex(of: id) {
            let range = start <= end ? start ... end : end ... start
            selected = Array(visible[range])
        } else if control {
            let set = Set(current)
            selected = set.contains(id) ? current.filter { $0 != id } : visible.filter { set.contains($0) || $0 == id }
            if selected.isEmpty { selected = [id] }
            sidebarSelectionAnchor = id
        } else {
            selected = [id]
            sidebarSelectionAnchor = id
        }
        let active = selected.contains(id) ? id : (store.selectedSessionID.flatMap { selected.contains($0) ? $0 : nil }
            ?? selected.last ?? id)
        noteUserActivity()
        store.selectSession(active, sidebarSelection: selected)
        showActive()
        syncSidebarSelection()
        updateTitle()
    }

    func workspaceForHeader(_ header: OpaquePointer?) -> UUID? { header.flatMap { workspaceDiscButtons[$0] } }

    /// `SidebarDrop.resolveWorkspace` expects an INSERTION SLOT, not the target row's raw index —
    /// feeding it the raw index made "drag onto the row below" a no-op and every downward drop land
    /// one short. The slot comes from the drop's `y` against the target header's midpoint
    /// (`LinuxSidebarPolicy.dropInsertionSlot`): top half inserts before the target, bottom half after.
    /// The slot is read in VISIBLE-row space — the sidebar renders `store.visibleWorkspaces`, under the
    /// focus filter a possibly NON-CONTIGUOUS subset of `store.workspaces` — and mapped onto the full
    /// array by `SidebarDrop.workspaceInsertIndex`, the same mapping the macOS coordinator applies
    /// (`resolveWorkspaceMove`). Feeding the target's full-array index directly would jump the dragged
    /// workspace across the hidden workspaces between rendered rows (visible `[B, D]` of `[A, B, C, D]`:
    /// B on D's top half must be a no-op, not a hop over the hidden C).
    func handleWorkspaceDrop(source: UUID, onto target: UUID, y: Double, targetHeight: Double) {
        guard source != target,
              let s = store.workspaces.firstIndex(where: { $0.id == source }) else { return }
        let visible = store.visibleWorkspaces
        guard let targetVisibleIndex = visible.firstIndex(where: { $0.id == target }) else { return }
        let visibleIndices = visible.compactMap { workspace in
            store.workspaces.firstIndex(where: { $0.id == workspace.id })
        }
        let childIndex = LinuxSidebarPolicy.workspaceDropChildIndex(
            targetVisibleIndex: targetVisibleIndex, visibleIndices: visibleIndices,
            y: y, height: targetHeight)
        guard let res = SidebarDrop.resolveWorkspace(sourceIndex: s, count: store.workspaces.count,
                                                     childIndex: childIndex) else { return }
        store.moveWorkspace(source, at: res.destination)
        rebuildSidebar()
    }

    /// A session dropped on a workspace HEADER appends — and carries its whole selected block through
    /// the same expansion as `handleSessionDrop` (macOS header drops move the full dragged block too).
    func handleSessionToWorkspace(session: UUID, workspace: UUID) {
        guard store.session(withID: session) != nil,
              let target = store.workspaces.first(where: { $0.id == workspace }) else { return }
        let ids = LinuxSidebarPolicy.draggedSessionBlock(source: session, selection: store.sidebarSelectionIDs)
        let sources = ids.compactMap { id -> SidebarDrop.SessionSource? in
            guard let location = store.sessionLocation(ofSession: id) else { return nil }
            return SidebarDrop.SessionSource(workspace: location.workspace, index: location.index)
        }
        guard let resolution = SidebarDrop.resolveSessions(
            sources: sources,
            target: .workspaceRow(id: workspace, sessionCount: target.sessions.count),
            childIndex: SidebarDrop.onItemIndex) else { return }
        store.moveSessions(ids, toWorkspace: resolution.workspace, at: resolution.destination)
        reconcile()
    }

    func handleDirectoryDrop(_ paths: [String], onto widget: OpaquePointer) -> Bool {
        let rowWorkspaceID = workspaceForHeader(widget)
            ?? session(forRow: widget).flatMap { store.workspace(forSession: $0)?.id }
        let workspaceID = SidebarDrop.resolveDirectoryWorkspace(sidebarMode: store.sidebarMode,
            rowWorkspaceID: rowWorkspaceID, fallbackWorkspaceID: store.soleFocusedWorkspaceID,
            currentWorkspaceID: store.currentWorkspaceID)
        guard let workspaceID else { return false }
        let directories = paths.filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard directories.count <= SidebarDrop.maximumDirectoryImportCount else {
            showToast("Drop at most \(SidebarDrop.maximumDirectoryImportCount) directories at once")
            return false
        }
        var created: [UUID] = []
        for path in directories {
            guard let session = store.addSession(toWorkspace: workspaceID, cwd: path) else { continue }
            created.append(session.id)
        }
        guard let selected = created.last else { return false }
        reconcile()
        selectSession(selected)
        return true
    }
}
