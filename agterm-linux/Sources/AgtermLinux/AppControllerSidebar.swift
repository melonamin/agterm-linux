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
        syncSidebar()
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

    /// One pass through the effective-selection predicate, so the CSS paint and the published accessible
    /// state always describe the same model selection (the choke-point contract — see
    /// `setSidebarSelectionStyle`). An incremental sync re-publishes just the rows GTK re-rooted; the
    /// forced rebuild re-publishes every live row.
    func syncSidebarSelectionStyles(ids: Set<UUID>? = nil) {
        let selection = store.sidebarSelectionIDs
        for id in ids ?? Set(sidebarRuntime.rows.keys) {
            guard let widgets = sidebarRuntime.rows[id] else { continue }
            setSidebarSelectionStyle(widgets.row, selected: LinuxSidebarPolicy.sessionIsInEffectiveSelection(
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
        // `syncSidebar(force: true)`, which measures the floor off labels rebuilt under the new CSS.
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
    /// A FORCED sync destroys and re-creates every row, so an async one must not land here — it would tear
    /// down the in-progress rename entry (whose disposal fires a focus-out that commits its half-typed
    /// text) and dismiss the open menu, from a timer the user never asked for. Both deferred jobs that can
    /// force — the sidebar-metadata refresh and the trailing soft-close reconcile — gate on this ONE
    /// predicate so they cannot drift apart. An incremental sync destroys nothing and is not gated.
    var sidebarInteractionInProgress: Bool {
        renaming != nil || contextMenuIsOpen || sidebarHoldsKeyboardFocus
    }

    /// Whether the window's focus widget is a LIVE sidebar widget — one a forced rebuild would destroy.
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

    func updateWorkspaceFilterButton() {
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

    /// Builds one whole section — header, list box and (flagged) hint — into a transparent wrapper that is
    /// the section's ONLY `sidebarBox` child, so a later reorder is one `gtk_box_reorder_child_after` and
    /// detaches nothing. A collapsed section keeps its rows and hides the list box.
    /// `includingRows: false` builds the section EMPTY — the planner emits an `insertRow` for every row
    /// of a section it inserts, so building them here too would double them.
    func makeSection(_ section: SidebarSnapshot.Section, selection: Set<UUID>,
                     includingRows: Bool = true) -> SectionWidgets? {
        // Spacing 2 is `sidebarBox`'s own, which the header, list box and hint sat under before the
        // wrapper took them out of it.
        guard let wrapper = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)) else { return nil }
        var header: OpaquePointer?
        var disc: OpaquePointer?
        var icon: OpaquePointer?
        var nameWidget: OpaquePointer?
        var add: OpaquePointer?
        if case .workspace(let wsID) = section.key, let content = section.header,
           let row = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)) {
            header = row
            "workspace-row".withCString { gtk_widget_set_name(W(row), $0) }
            gtk_widget_set_margin_top(W(row), 8)
            gtk_widget_set_margin_start(W(row), 4)
            if let button = op(gtk_button_new_from_icon_name(Self.disclosureIconName(expanded: section.expanded))) {
                disc = button
                gtk_button_set_has_frame(BUTTON(button), 0)
                gtk_widget_set_focus_on_click(W(button), 0)
                gtk_widget_add_css_class(W(button), "flat")
                workspaceDiscButtons[button] = wsID
                connect(button, "clicked", unsafeBitCast(onWorkspaceDisclosure as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), RAW(button))
                gtk_box_append(cast(row), W(button))
            }
            icon = op(gtk_image_new_from_icon_name("agterm-grid-symbolic"))
            applyWorkspaceFocusMembership(icon, member: content.focusMember)
            gtk_box_append(cast(row), W(icon))
            if let name = makeNameWidget(id: wsID, text: content.name, isWorkspace: true) {
                nameWidget = name
                gtk_widget_add_css_class(W(name), "heading")
                gtk_box_append(cast(row), W(name))
            }
            if let button = op(gtk_button_new_from_icon_name("list-add-symbolic")) {
                add = button
                gtk_button_set_has_frame(BUTTON(button), 0)
                gtk_widget_set_focus_on_click(W(button), 0)
                gtk_widget_add_css_class(W(button), "flat")
                gtk_widget_add_css_class(W(button), "workspace-add-session")
                Self.applyAddSessionTooltip(button, workspace: content.name)
                gtk_widget_set_visible(W(button), content.addVisible ? 1 : 0)
                workspaceDiscButtons[button] = wsID
                connect(button, "clicked", unsafeBitCast(onWorkspaceAddSession as @convention(c)
                    (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
                gtk_box_append(cast(row), W(button))
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
            gtk_box_append(cast(wrapper), W(row))
        } else if let label = op(gtk_label_new("Flagged")) {
            header = label
            gtk_label_set_xalign(label, 0)
            gtk_widget_add_css_class(W(label), "heading")
            gtk_widget_set_margin_top(W(label), 8)
            gtk_widget_set_margin_start(W(label), 8)
            gtk_box_append(cast(wrapper), W(label))
        }

        guard let header, let listBox = op(gtk_list_box_new()) else { return nil }
        gtk_widget_add_css_class(W(listBox), "navigation-sidebar")
        if case .workspace = section.key { gtk_widget_set_margin_start(W(listBox), 14) }
        // Selection mode NONE: the custom shift/ctrl logic owns selection (painted through the
        // `agterm-selected` class), which lets the session-row click gesture run WITHOUT claiming
        // the sequence — see agterm-linux/docs/sidebar.md (no claiming click gesture).
        gtk_list_box_set_selection_mode(listBox, GTK_SELECTION_NONE)
        gtk_widget_set_visible(W(listBox), section.expanded ? 1 : 0)
        for id in includingRows ? section.rows : [] {
            guard let content = section.content[id], let row = makeRow(id, content: content) else { continue }
            gtk_list_box_append(listBox, W(row))
            // Publish for EVERY fresh row, not only the selected ones (an untouched row would
            // otherwise carry an UNDEFINED accessible SELECTED state until the first sync).
            setSidebarSelectionStyle(row, selected: selection.contains(id))
        }
        gtk_box_append(cast(wrapper), W(listBox))
        let widgets = SectionWidgets(wrapper: wrapper, header: header, listBox: listBox, disc: disc,
                                     icon: icon, name: nameWidget, add: add, hint: makeSectionHint(section, in: wrapper))
        widgets.applied = section.header
        sidebarRuntime.sections[section.key] = widgets
        return widgets
    }

    static func disclosureIconName(expanded: Bool) -> String {
        expanded ? "pan-down-symbolic" : "pan-end-symbolic"
    }

    static func applyAddSessionTooltip(_ button: OpaquePointer, workspace: String) {
        "New Session in \(workspace)".withCString { gtk_widget_set_tooltip_text(W(button), $0) }
    }

    func applyWorkspaceFocusMembership(_ icon: OpaquePointer?, member: Bool) {
        guard let icon else { return }
        if member {
            gtk_widget_add_css_class(W(icon), "accent")
            "In workspace focus set".withCString { gtk_widget_set_tooltip_text(W(icon), $0) }
        } else {
            gtk_widget_remove_css_class(W(icon), "accent")
            gtk_widget_set_tooltip_text(W(icon), nil)
        }
    }

    /// The flagged-empty hint, built only for the flagged section and hidden when it has rows.
    private func makeSectionHint(_ section: SidebarSnapshot.Section,
                                 in wrapper: OpaquePointer) -> OpaquePointer? {
        guard section.key == .flagged,
              let hint = op(gtk_label_new("No flagged sessions.\nRight-click a session → Flag.")) else { return nil }
        gtk_label_set_justify(hint, GTK_JUSTIFY_CENTER)
        // Fixed instructional text wraps rather than ellipsizes: wrapping drops the minimum
        // width from the longest line to the longest word, which is all the sidebar needs.
        gtk_label_set_wrap(hint, 1)
        gtk_widget_set_margin_top(W(hint), 24)
        gtk_widget_add_css_class(W(hint), "dim-label")
        gtk_widget_set_visible(W(hint), section.showsHint ? 1 : 0)
        gtk_box_append(cast(wrapper), W(hint))
        return hint
    }

    /// The name widget of a session row: a breadcrumb label in flagged view, the shared
    /// `makeNameWidget` otherwise — the one place `renameEntry` is set and the double-click rename
    /// gesture is attached, so an inline rename takes that branch in both views.
    func makeSessionNameWidget(_ id: UUID, content: SidebarSnapshot.RowContent) -> OpaquePointer? {
        // Guard on the FULL condition, not the weaker `flaggedView`: renaming in flagged view takes the
        // makeNameWidget branch, and a GtkLabel setter on the GtkEntry it returns raises a GTK critical.
        let breadcrumb = store.sidebarMode == .flagged && !content.renaming
        guard let widget = breadcrumb
            ? op(gtk_label_new(content.name))
            : makeNameWidget(id: id, text: content.name, isWorkspace: false) else { return nil }
        gtk_widget_set_hexpand(W(widget), 1)
        gtk_widget_set_margin_top(W(widget), 4)
        gtk_widget_set_margin_bottom(W(widget), 4)
        gtk_widget_set_margin_start(W(widget), 4)
        if breadcrumb {
            gtk_label_set_xalign(widget, 0)
            // END even though the breadcrumb ends in the workspace: the flagged view is already
            // workspace-scoped, so the tail is what can be given up first.
            gtk_label_set_ellipsize(widget, PANGO_ELLIPSIZE_END)
            content.name.withCString { gtk_widget_set_tooltip_text(W(widget), $0) }
        }
        return widget
    }

    func makeRow(_ id: UUID, content: SidebarSnapshot.RowContent) -> OpaquePointer? {
        guard let row = op(gtk_list_box_row_new()), let box = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)),
              let lead = op(gtk_image_new_from_icon_name("utilities-terminal-symbolic")),
              let name = makeSessionNameWidget(id, content: content),
              let glyph = op(gtk_label_new(nil)), let star = op(gtk_image_new_from_icon_name("starred-symbolic")),
              let badge = op(gtk_label_new(nil)) else { return nil }
        "session-row".withCString { gtk_widget_set_name(W(row), $0) }
        gtk_widget_add_css_class(W(box), "agterm-session-row-content")
        gtk_widget_set_margin_start(W(lead), 6)
        gtk_box_append(cast(box), W(lead))
        gtk_box_append(cast(box), W(name))
        Self.applyStatusGlyph(content.glyph, blink: content.blink,
                              phase: sidebarRuntime.blinkPhase.phase, to: glyph)
        gtk_box_append(cast(box), W(glyph))
        gtk_widget_set_visible(W(star), content.star ? 1 : 0)
        gtk_box_append(cast(box), W(star))
        Self.applyRowBadge(content.badge, to: badge)
        gtk_box_append(cast(box), W(badge))
        let widgets = SessionRowWidgets(row: row, box: box, lead: lead, name: name,
                                        glyph: glyph, star: star, badge: badge)
        widgets.applied = content
        sidebarRuntime.rows[id] = widgets
        rowSession[row] = id
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
        if store.sidebarMode != .flagged {
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
    /// row) and ONE a11y path (`GTK_ACCESSIBLE_STATE_SELECTED` on the row accessible, via
    /// `publishRowAccessibleSelected`). Every selection paint, initial or incremental, routes
    /// through here, so the visual highlight and the published accessible state cannot drift apart.
    /// See agterm-linux/docs/sidebar.md (selection contract).
    func setSidebarSelectionStyle(_ row: OpaquePointer, selected: Bool) {
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

    /// `refocusOnDismiss: false` only from the sidebar sync, whose tail repair takes over.
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
        // The dragged block breaks the planner's LIS ties: without the hint an equally minimal plan
        // may move the rows the block passed over instead of the rows the user dragged.
        reconcile(preferMoving: Set(ids))
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
        // `AppStore.selectSession` clears the visited row's unseen badge and its auto-reset indicator,
        // so the row owes a content sync — without it a blinking auto-reset glyph survives the click
        // and keeps the blink timer armed for the rest of the session.
        syncSidebar()
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
        syncSidebar(preferMoving: [source])
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
        reconcile(preferMoving: Set(ids))
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
