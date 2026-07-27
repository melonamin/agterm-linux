import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    static var sidebarFontProvider: OpaquePointer?

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
        for listBox in workspaceListBoxes { gtk_list_box_unselect_all(listBox) }
        for row in rowSession.keys { setSidebarSelectionStyle(row, selected: false) }
        let selected = store.sidebarSelectionIDs.isEmpty ? store.selectedSessionID.map { [$0] } ?? []
            : store.sidebarSelectionIDs
        for id in selected {
            guard let row = rowSession.first(where: { $0.value == id })?.key,
                  let parent = gtk_widget_get_parent(W(row)) else { continue }
            gtk_list_box_select_row(OpaquePointer(parent), GLBR(row))
            // Libadwaita's navigation-sidebar rules can suppress GtkListBoxRow's :selected paint.
            // Mirror the model selection into an explicit class so the themed highlight stays visible.
            setSidebarSelectionStyle(row, selected: true)
        }
        if let active = store.selectedSessionID,
           let row = rowSession.first(where: { $0.value == active })?.key {
            scrollRowIntoView(row)
        }
    }

    func applySidebarFontSize() {
        guard let display = gdk_display_get_default() else { return }
        let settings = linuxSettingsStore().load()
        let size = AppSettings.clampSidebarFontSize(settings.sidebarFontSize ?? AppSettings.defaultSidebarFontSize)
        let css = ".agterm-sidebar label { font-size: \(size)pt; }"
        if Self.sidebarFontProvider == nil {
            let provider = OpaquePointer(gtk_css_provider_new())
            Self.sidebarFontProvider = provider
            gtk_style_context_add_provider_for_display(display, provider, 651)
        }
        if let provider = Self.sidebarFontProvider {
            css.withCString { gtk_css_provider_load_from_string(cast(provider), $0) }
        }
    }

    /// Whether a sidebar row interaction is live: an inline rename, or an open context menu.
    ///
    /// `rebuildSidebar()` destroys and re-creates every row, so an ASYNC rebuild must not land here — it
    /// would tear down the in-progress rename entry (whose disposal fires a focus-out that commits its
    /// half-typed text) and dismiss the open menu, from a timer the user never asked for. Both deferred
    /// rebuilds — the sidebar-metadata refresh and the trailing soft-close reconcile — gate on this ONE
    /// predicate so they cannot drift apart. A SYNCHRONOUS rebuild is a direct consequence of a user action
    /// and is deliberately not gated.
    var sidebarInteractionInProgress: Bool { renaming != nil || contextMenuIsOpen }

    /// How long a deferred rebuild waits before re-checking `sidebarInteractionInProgress`. It belongs to the
    /// GATE rather than to either job: the metadata refresh and the soft-close reconcile are unrelated jobs
    /// that happen to defer on the same predicate, so neither owning the other's retry cadence.
    static let sidebarInteractionRetryInterval: TimeInterval = 0.25

    func rebuildSidebar() {
        let settings = linuxSettingsStore().load()
        // GtkPopover is parented to the row's GtkListBox while its context menu is open. Detach it
        // before destroying that list box: GtkListBox disposal otherwise treats the popover as a row,
        // repeatedly fails to remove it, and starves the GTK main loop.
        dismissContextMenu()
        updateAttentionButton(settings: settings)
        updateDashboardStatusIndicators()
        while let child = gtk_widget_get_first_child(W(sidebarBox)) {
            gtk_box_remove(cast(sidebarBox), child)
        }
        rowSession.removeAll()
        nameLabels.removeAll()
        workspaceDiscButtons.removeAll()
        workspaceListBoxes.removeAll()

        if store.sidebarMode == .flagged {
            appendSection("Flagged", store.flaggedSessions, settings: settings)
            if store.flaggedSessions.isEmpty {
                if let hint = op(gtk_label_new("No flagged sessions.\nRight-click a session → Flag.")) {
                    gtk_label_set_justify(hint, GTK_JUSTIFY_CENTER)
                    gtk_widget_set_margin_top(W(hint), 24)
                    gtk_widget_add_css_class(W(hint), "dim-label")
                    gtk_box_append(cast(sidebarBox), W(hint))
                }
            }
        } else {
            if let fid = store.focusedWorkspaceID, let ws = store.workspaces.first(where: { $0.id == fid }),
               let pill = op(gtk_button_new()) {
                "✕  \(ws.name)".withCString { gtk_button_set_label(cast(pill), $0) }
                gtk_widget_add_css_class(W(pill), "agterm-focus-pill")
                gtk_widget_set_margin_top(W(pill), 4)
                gtk_widget_set_margin_start(W(pill), 8)
                gtk_widget_set_margin_end(W(pill), 8)
                connect(pill, "clicked", unsafeBitCast(onClearFocusPill as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
                gtk_box_append(cast(sidebarBox), W(pill))
            }
            for ws in store.visibleWorkspaces {
                appendSection(ws.name, ws.sessions, workspace: ws.id, settings: settings)
            }
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
                gtk_widget_add_css_class(W(disc), "flat")
                workspaceDiscButtons[disc] = wsID
                connect(disc, "clicked", unsafeBitCast(onWorkspaceDisclosure as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), RAW(disc))
                gtk_box_append(cast(row), W(disc))
            }
            gtk_box_append(cast(row), W(op(gtk_image_new_from_icon_name("agterm-grid-symbolic"))))
            if let name = makeNameWidget(id: wsID, text: title, isWorkspace: true) {
                gtk_widget_add_css_class(W(name), "heading")
                gtk_box_append(cast(row), W(name))
            }
            if !settings.isInterfaceElementHidden(.workspaceAddSession),
               let add = op(gtk_button_new_from_icon_name("list-add-symbolic")) {
                gtk_button_set_has_frame(BUTTON(add), 0)
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
        gtk_list_box_set_selection_mode(lb, GTK_SELECTION_MULTIPLE)
        let rightClick = gtk_gesture_click_new()
        gtk_gesture_single_set_button(rightClick, 3)
        connect(rightClick, "pressed", unsafeBitCast(onRowRightClick as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), RAW(lb))
        gtk_widget_add_controller(W(lb), rightClick)
        workspaceListBoxes.append(lb)

        for s in sessions {
            guard let row = makeRow(s) else { continue }
            gtk_list_box_append(lb, W(row))
            rowSession[row] = s.id
            if store.sidebarSelectionIDs.contains(s.id) ||
                (store.sidebarSelectionIDs.isEmpty && s.id == store.selectedSessionID) {
                gtk_list_box_select_row(lb, GLBR(row))
                setSidebarSelectionStyle(row, selected: true)
            }
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
        let label = flaggedView && renaming?.id != s.id
            ? op(gtk_label_new(LinuxSidebarPolicy.flaggedRowLabel(for: s, in: store)))
            : makeNameWidget(id: s.id, text: s.displayName, isWorkspace: false)
        gtk_widget_set_hexpand(W(label), 1)
        gtk_widget_set_margin_top(W(label), 4)
        gtk_widget_set_margin_bottom(W(label), 4)
        gtk_widget_set_margin_start(W(label), 4)
        if flaggedView { gtk_label_set_xalign(label, 0) }
        gtk_box_append(cast(box), W(label))
        if let icon = Self.statusIcon(s.agentIndicator.status), let glyph = op(gtk_image_new_from_icon_name(icon)) {
            if let cls = Self.statusColorClass(s.agentIndicator.status) { gtk_widget_add_css_class(W(glyph), cls) }
            if s.agentIndicator.blink { gtk_widget_add_css_class(W(glyph), "agterm-blink") }
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
        gtk_widget_set_margin_end(W(box), 6)
        gtk_list_box_row_set_child(GLBR(row), W(box))
        let selectClick = gtk_gesture_click_new()
        gtk_gesture_single_set_button(selectClick, 1)
        gtk_event_controller_set_propagation_phase(selectClick, GTK_PHASE_CAPTURE)
        connect(selectClick, "pressed", unsafeBitCast(onSessionRowClick, to: GCallback.self), RAW(row))
        gtk_widget_add_controller(W(row), selectClick)
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

    private func setSidebarSelectionStyle(_ row: OpaquePointer, selected: Bool) {
        let update: (OpaquePointer?) -> Void = { widget in
            if selected {
                gtk_widget_add_css_class(W(widget), "agterm-selected")
            } else {
                gtk_widget_remove_css_class(W(widget), "agterm-selected")
            }
        }
        update(row)
        update(gtk_list_box_row_get_child(GLBR(row)).map { OpaquePointer($0) })
    }

    static func statusIcon(_ s: AgentStatus) -> String? {
        switch s {
        case .idle: return nil
        case .active: return "content-loading-symbolic"
        case .completed: return "emblem-ok-symbolic"
        case .blocked: return "dialog-warning-symbolic"
        }
    }

    static func statusColorClass(_ s: AgentStatus) -> String? {
        switch s {
        case .idle: return nil
        case .active: return "agterm-status-active"
        case .completed: return "agterm-status-completed"
        case .blocked: return "agterm-status-blocked"
        }
    }

    func updateAttentionButton(settings: AppSettings? = nil) {
        updateRecentSessionsButton()
        guard let button = attentionButton else { return }
        let enabled = (settings ?? linuxSettingsStore().load()).attentionButtonEnabled ?? false
        gtk_widget_set_visible(W(button), enabled ? 1 : 0)
        let sessions = store.attentionSessions
        gtk_widget_set_sensitive(W(button), sessions.isEmpty ? 0 : 1)
        let hasBlocked = sessions.contains { $0.agentIndicator.status == .blocked }
        gtk_button_set_icon_name(BUTTON(button), hasBlocked ? "dialog-warning-symbolic" : "emblem-important-symbolic")
        if !enabled || sessions.isEmpty, sessionPickerPopover != nil, sessionPickerShowsAttention {
            dismissSessionPicker()
        }
    }

    func session(forRow row: OpaquePointer?) -> UUID? {
        guard let row else { return nil }
        return rowSession[row]
    }

    func handleSessionDrop(source: UUID, onto target: UUID) {
        guard let tgt = store.sessionLocation(ofSession: target) else { return }
        let dropTarget = SidebarDrop.SessionDropTarget.sessionRow(workspace: tgt.workspace, sessionIndex: tgt.index, sessionCount: tgt.count)
        let ids = store.sidebarSelectionIDs.contains(source) ? store.sidebarSelectionIDs : [source]
        let sources = ids.compactMap { id -> SidebarDrop.SessionSource? in
            guard let location = store.sessionLocation(ofSession: id) else { return nil }
            return SidebarDrop.SessionSource(workspace: location.workspace, index: location.index)
        }
        guard let resolution = SidebarDrop.resolveSessions(sources: sources, target: dropTarget,
                                                           childIndex: SidebarDrop.onItemIndex) else { return }
        store.moveSessions(ids, toWorkspace: resolution.workspace, at: resolution.destination)
        reconcile()
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

    func handleWorkspaceDrop(source: UUID, onto target: UUID) {
        guard source != target,
              let s = store.workspaces.firstIndex(where: { $0.id == source }),
              let t = store.workspaces.firstIndex(where: { $0.id == target }),
              let res = SidebarDrop.resolveWorkspace(sourceIndex: s, count: store.workspaces.count, childIndex: t) else { return }
        store.moveWorkspace(source, at: res.destination)
        rebuildSidebar()
    }

    func handleSessionToWorkspace(session: UUID, workspace: UUID) {
        guard store.session(withID: session) != nil else { return }
        store.moveSession(session, toWorkspace: workspace)
        reconcile()
    }

    func handleDirectoryDrop(_ paths: [String], onto widget: OpaquePointer) -> Bool {
        let rowWorkspaceID = workspaceForHeader(widget)
            ?? session(forRow: widget).flatMap { store.workspace(forSession: $0)?.id }
        let workspaceID = SidebarDrop.resolveDirectoryWorkspace(sidebarMode: store.sidebarMode,
            rowWorkspaceID: rowWorkspaceID, focusedWorkspaceID: store.focusedWorkspaceID,
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
