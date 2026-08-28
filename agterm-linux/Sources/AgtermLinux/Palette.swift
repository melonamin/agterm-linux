// Command palette (Ctrl+Shift+P): a modal GtkSearchEntry + GtkListBox of actions,
// fuzzy-filtered via agtermCore.fuzzyScore. Each action calls a thin AppController
// method (the shared controller). Enter runs the selected match; Esc closes.
import CGtk
import agtermCore

@MainActor
extension AppController {
    private func paletteActionList() -> [LinuxPaletteItem] {
        // The fixed commands, their titles and their rebindable built-ins all come from the shared
        // PaletteCommand catalog; this file adds ONLY the Linux closure. That switch is EXHAUSTIVE, so
        // adding a catalog case fails to compile until it's wired here — the compiler is the keep-in-sync
        // check.
        // Each fixed command carries its current keybind (kitty syntax) in the row's SHORTCUT field, which
        // filterPalette renders as a separate right-aligned dim label. Searching still matches the chord
        // (LinuxPaletteRow.searchKeys keeps a composite key), so you can find by chord.
        // Omit fixed commands that would be no-ops in the current UI state (shared visibility predicates).
        let activeSession = store.selectedSessionID.flatMap { store.session(withID: $0) }
        let paletteContext = PaletteContext(canRemoveWorkspace: store.canRemoveWorkspace,
                                            hasFlaggedSessions: !store.flaggedSessions.isEmpty,
                                            sidebarShowsWorkspaceTree: store.sidebarMode == .tree,
                                            sidebarShowsFlaggedOnly: store.sidebarMode == .flagged,
                                            activeSessionFlagged: activeSession?.flagged ?? false,
                                            hasMarkedWorkspaces: !store.focusedWorkspaceIDs.isEmpty,
                                            activeWorkspaceMarked: store.isCurrentWorkspaceFocusMember,
                                            activeWorkspaceCollapsed: store.isCurrentWorkspaceCollapsed,
                                            canStepWorkspaces: store.canStepWorkspaces,
                                            activeSessionHasSplit: activeSession?.hasSplit ?? false,
                                            activeSplitAxis: activeSession?.splitAxis,
                                            hasPendingClose: store.pendingCloseSummary != nil,
                                            hasRecentClosed: !library.recentClosedItems.isEmpty,
                                            hasActiveSession: activeSession != nil,
                                            hasCurrentWorkspace: store.currentWorkspaceID != nil,
                                            terminalZoomActive: terminalZoom.target != nil,
                                            dashboardOpen: dashboard.isOpen,
                                            pickerActive: pickController.pending != nil)
        var items: [LinuxPaletteItem] = PaletteCommand.allCases.filter { $0.isVisible(in: paletteContext) }.map { cmd in
            let row = LinuxPaletteRow.action(cmd, in: paletteContext, chord: cmd.builtinAction.flatMap(resolvedChord(for:)))
            return (row: row, run: run(for: cmd))
        }
        if !library.recentClosedItems.isEmpty {
            items.append((row: LinuxPaletteRow(title: "Clear Recent Items"), run: { self.clearRecentHistory() }))
        }
        // Preferences… (the Linux Settings surface; macOS uses the Settings scene / Cmd+,).
        // These Linux-only rows have no BuiltinAction, so no chord resolves and they render title-only.
        items.append((row: LinuxPaletteRow(title: "Preferences…"), run: { self.showSettings() }))
        items.append((row: LinuxPaletteRow(title: "Manage Integrations…"), run: { self.showSettings(page: .integrations) }))
        items.append((row: LinuxPaletteRow(title: "Keyboard Shortcuts"), run: { self.showKeyboardShortcuts() }))
        items.append((row: LinuxPaletteRow(title: "About agterm"), run: { self.showAbout() }))
        // Linux has no global macOS-style Edit menu; expose the same terminal actions in the command palette.
        items.append((row: LinuxPaletteRow(title: "Copy Selection"), run: { self.activeSurface()?.performBindingAction("copy_to_clipboard") }))
        items.append((row: LinuxPaletteRow(title: "Paste"), run: { self.activeSurface()?.performBindingAction("paste_from_clipboard") }))
        items.append((row: LinuxPaletteRow(title: "Select All"), run: { self.activeSurface()?.performBindingAction("select_all") }))
        // Dynamic: explicitly reopen persisted closed windows, matching upstream's "Open Window" palette
        // rows. Other live windows remain available as Linux-only switch targets. Both paths use
        // `openWindow`, which raises an attached window or lazily loads and presents a closed one.
        for w in gLibrary.windows where w.id != windowID {
            let target = w.id
            let row = LinuxPaletteRow.window(name: w.name, isOpen: gLibrary.isOpen(target))
            items.append((row: row, run: { openWindow(target) }))
            items.append((row: LinuxPaletteRow(title: "Rename Window: \(w.name)"), run: { self.renameWindowDialog(target) }))
            if gLibrary.canRemoveWindow {
                items.append((row: LinuxPaletteRow(title: "Delete Window: \(w.name)"), run: { self.confirmDeleteWindow(target) }))
            }
        }
        // Dynamic: move the active session to any OTHER workspace.
        if let sid = store.selectedSessionID, let current = store.workspace(forSession: sid) {
            for ws in store.workspaces where ws.id != current.id {
                let target = ws.id
                items.append((row: LinuxPaletteRow(title: "Move Session to \(ws.name)"), run: { self.moveActiveSession(to: target) }))
            }
        }
        // Dynamic: custom shell commands from keymap.conf (run via the palette; built-in chord dispatch
        // is a separate item). They carry a real `custom` BADGE plus their own bound chord, matching
        // macOS — the title itself is the bare command name, never "<name>  (custom)".
        // Read the CACHED `keymap`, never a fresh disk parse: key dispatch runs off this same cache, so
        // the chord in the shortcut column is exactly the chord that fires. A fresh read would advertise
        // an edited-but-not-yet-reloaded chord as live while pressing it did nothing, because keymap.conf
        // edits deliberately apply only on Reload Keymap (README, "After editing the file, apply it with
        // File ▸ Reload Keymap"). macOS reads the same cache (`AppActions+Palette.swift`, its
        // `settingsModel?.keymap.commands` loop). See `.claude/rules/keymap.md`.
        for cmd in keymap.commands {
            items.append((row: LinuxPaletteRow.custom(cmd), run: { self.runCustomCommand(cmd) }))
        }
        // Dynamic direct targets complement the current-workspace catalog actions.
        if store.soleFocusedWorkspaceID == nil, store.workspaces.count > 1 {
            for ws in store.workspaces {
                let target = ws.id
                items.append((row: LinuxPaletteRow(title: "Focus Workspace \(ws.name)"), run: { self.focusWorkspace(target) }))
            }
        }
        return items
    }

    /// The Linux closure a palette command runs — the ONLY half this file owns. EXHAUSTIVE: adding a
    /// catalog case fails to compile until it's wired here, so the compiler keeps the palette in sync
    /// with the shared catalog. The command's rebindable built-in (what the shortcut column resolves a
    /// chord from) is deliberately NOT restated here — `PaletteCommand.builtinAction` already owns that
    /// mapping in agtermCore, and a second copy could silently drift from it.
    private func run(for cmd: PaletteCommand) -> () -> Void {
        switch cmd {
        case .newSession: return { self.newSession() }
        case .newWorkspace: return { self.newWorkspace() }
        case .openDirectory: return { self.openDirectory() }
        case .renameSession: return { self.startRenameActive() }
        case .duplicateSession: return { if let id = self.store.selectedSessionID { _ = self.duplicateSession(id) } }
        case .renameWorkspace: return { if let id = self.store.currentWorkspaceID { self.beginRename(id: id, isWorkspace: true) } }
        case .closeSession: return { if let id = self.store.selectedSessionID { self.requestCloseSession(id) } }
        case .reopenRecent: return { self.reopenRecentClosed() }
        case .undoClose: return { self.undoPendingClose() }
        case .clearStatus: return { self.clearActiveStatus() }
        case .previousSession: return { self.navigate(.previous) }
        case .nextSession: return { self.navigate(.next) }
        case .previousAttentionSession: return { self.navigate(.previousAttention) }
        case .nextAttentionSession: return { self.navigate(.nextAttention) }
        case .previousWorkspace: return { self.navigateWorkspace(.previous) }
        case .nextWorkspace: return { self.navigateWorkspace(.next) }
        case .firstSession: return { self.navigate(.first) }
        case .lastSession: return { self.navigate(.last) }
        case .showAttention: return { self.showAttentionPalette() }
        case .toggleSplit: return { self.toggleSplit(axis: .leftRight) }
        case .toggleHorizontalSplit: return { self.toggleSplit(axis: .topBottom) }
        case .closeSplit: return { self.closeActiveSplit() }
        case .toggleScratch: return { self.toggleScratch() }
        case .toggleTerminalZoom: return { self.toggleTerminalZoom() }
        case .dashboard: return { self.toggleDashboard() }
        case .toggleSidebar: return { self.toggleSidebar() }
        case .toggleFlag: return { self.toggleFlagActive() }
        case .focusWorkspace: return { self.focusActiveWorkspace() }
        case .find: return { self.toggleSearch() }
        case .quickTerminal: return { self.toggleQuick() }
        case .toggleFullscreen: return { self.toggleWindowFullscreen() }
        case .increaseFontSize: return { self.activeSurface()?.performBindingAction(FontBindingAction.increase) }
        case .decreaseFontSize: return { self.activeSurface()?.performBindingAction(FontBindingAction.decrease) }
        case .resetFontSize: return { self.activeSurface()?.performBindingAction(FontBindingAction.reset) }
        case .selectTheme: return { self.showThemePicker() }
        case .deleteWorkspace: return { if let id = self.store.currentWorkspaceID { self.store.removeWorkspace(id); self.reconcile() } }
        case .toggleFlaggedView: return { self.toggleFlaggedView() }
        case .focusLeftPane: return { self.focusPane(left: true) }
        case .focusRightPane: return { self.focusPane(left: false) }
        case .expandWorkspaces: return { self.expandWorkspaces() }
        case .collapseWorkspaces: return { self.collapseOtherWorkspaces() }
        case .editKeymap: return { self.editKeymap() }
        case .reloadKeymap: return { reloadKeymapAllWindows(reportingIn: self) }
        case .editGhosttyConfig: return { self.editGhosttyConfig() }
        case .reloadConfig: return { self.reloadConfig() }
        case .clearFlagged: return { self.clearFlagged() }
        case .clearFocus: return { self.focusWorkspace(nil) }
        case .addWorkspaceToFocus: return { self.addActiveWorkspaceToFocus() }
        case .toggleWorkspaceFilter: return { self.toggleWorkspaceFilter() }
        case .toggleWorkspaceCollapse: return { self.toggleCurrentWorkspaceCollapse() }
        }
    }

    /// Jump to a session by fuzzy name (⌃P) — the session analogue of the action palette (⌃⇧P).
    func showSessionPalette() { showPalette(sessions: true) }

    /// Jump to a session that needs attention, matching the shared `show_attention` built-in action.
    func showAttentionPalette() { showPalette(attention: true) }

    /// Sessions as palette entries (label = "name — workspace"), each selecting that session.
    /// `navigableSessions` is the ⌃P switcher's list (every workspace, sidebar order); `attentionSessions`
    /// is the attention palette's, already ranked blocked→active→completed — which `filterPalette`
    /// preserves for an empty query rather than alphabetizing.
    private func sessionRows(_ sessions: [Session]) -> [LinuxPaletteItem] {
        sessions.map { s in
            let ws = store.workspace(forSession: s.id)?.name ?? ""
            return (row: LinuxPaletteRow(title: "\(s.displayName)  —  \(ws)"), run: { self.selectSession(s.id) })
        }
    }

    func showPalette(sessions: Bool = false, attention: Bool = false) {
        if paletteWindow != nil { closePalette(); return }   // re-invoking toggles the palette closed
        guard let win = op(gtk_window_new()) else { return }
        attachControllerContext(to: win, windowID: windowID)
        paletteWindow = win
        suppressAutoFollow()
        connect(win, "destroy", unsafeBitCast(onPaletteDestroyed, to: GCallback.self),
                Unmanaged.passRetained(self).toOpaque())
        gtk_window_set_transient_for(WIN(win), WIN(windowPointer))
        gtk_window_set_modal(WIN(win), 1)
        let title = attention ? "Go to Attention" : (sessions ? "Go to Session" : "Command Palette")
        title.withCString { gtk_window_set_title(WIN(win), $0) }
        let panelSize = interfacePanelSize(width: 480, height: 360)
        gtk_window_set_default_size(WIN(win), panelSize.0, panelSize.1)

        let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        gtk_widget_add_css_class(W(box), "agterm-interface-panel")
        let entry = op(gtk_search_entry_new())
        connect(entry, "search-changed", unsafeBitCast(onPaletteSearch as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        connect(entry, "activate", unsafeBitCast(onPaletteActivate as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        gtk_box_append(cast(box), W(entry))

        let scroller = op(gtk_scrolled_window_new())
        gtk_widget_set_vexpand(W(scroller), 1)
        let lb = op(gtk_list_box_new())
        paletteList = lb
        "command-palette".withCString { gtk_widget_set_name(W(lb), $0) }   // automation id
        connect(lb, "row-activated", unsafeBitCast(onPaletteRow as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        gtk_scrolled_window_set_child(scroller, W(lb))
        gtk_box_append(cast(box), W(scroller))
        gtk_window_set_child(WIN(win), W(box))

        let kc = gtk_event_controller_key_new()
        // CAPTURE phase so Esc/arrows reach us BEFORE the focused search entry consumes them — otherwise
        // the entry's own Esc just clears the search text instead of closing the palette.
        gtk_event_controller_set_propagation_phase(kc, GTK_PHASE_CAPTURE)
        connect(kc, "key-pressed", unsafeBitCast(onPaletteKey as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self))
        gtk_widget_add_controller(W(win), kc)

        paletteAll = attention
            ? LinuxPaletteList(items: sessionRows(store.attentionSessions), preservesNaturalOrder: true)
            : LinuxPaletteList(items: sessions ? sessionRows(store.navigableSessions) : paletteActionList())
        filterPalette("")
        gtk_window_present(WIN(win))
        _ = gtk_widget_grab_focus(W(entry))
    }

    func filterPalette(_ query: String) {
        guard let lb = paletteList else { return }
        gtk_list_box_remove_all(lb)
        // Shared, host-free ordering seam (lower-is-better, best first, alpha tie-break; the attention
        // palette keeps its own blocked-first order until something is typed) — index 0 is auto-selected
        // below, so the head of this list is what Enter runs. searchKeys keeps a composite key beside the
        // title so find-by-chord still works (see LinuxPaletteRow.searchKeys).
        let ranked = paletteAll.filtered(query: query)
        // Accessible-name contract: title, badge and shortcut are SEPARATE GtkLabels, so each exposes its
        // own text as its own AT-SPI name (labels named "New Session", "custom", "ctrl+shift+t"), which is
        // what atspi_smoke.py asserts. The GtkListBoxRow's own computed name goes empty once its child is
        // a multi-label box — nothing depends on it. Do NOT re-merge these into one label to "restore" a
        // row name; set GTK_ACCESSIBLE_PROPERTY_LABEL on the row instead if a single announcement is wanted.
        //
        // runPaletteIndex maps a GtkListBoxRow's index straight into paletteItems, so the two must stay
        // one-to-one: collect only the rows that were actually built and assign paletteItems from those,
        // rather than assigning first and letting a skipped row shift every later action by one.
        var rendered: [LinuxPaletteItem] = []
        for item in ranked {
            guard let row = op(gtk_list_box_row_new()), let box = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)) else { continue }
            gtk_widget_set_margin_top(W(box), 6); gtk_widget_set_margin_bottom(W(box), 6)
            gtk_widget_set_margin_start(W(box), 10); gtk_widget_set_margin_end(W(box), 10)
            let label = op(gtk_label_new(item.row.title))
            gtk_label_set_xalign(label, 0)
            // hexpand is the Spacer equivalent: the box's spare width goes to the title, so the badge and
            // shortcut sit flush right (they take their natural width, no xalign involved).
            gtk_widget_set_hexpand(W(label), 1)
            // Long titles are repetitive with a disambiguating TAIL ("Delete Window: <name>",
            // "Move Session to <workspace>", "<session>  —  <workspace>"), so ellipsize in the MIDDLE:
            // END would truncate exactly the part that tells two rows apart, and no ellipsize at all
            // would push the shortcut column out of the 480px palette instead of truncating.
            gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_MIDDLE)
            gtk_box_append(cast(box), W(label))
            // Trailing pill (currently only "custom") between the title and the shortcut column, so a
            // keymap command reads as name + badge + its own chord instead of a mangled title. CENTER
            // valign keeps it at its natural height — a box child defaults to FILL, which would stretch
            // the CSS background over the full row height and stop it reading as a pill.
            if let badge = item.row.badge, let pill = op(gtk_label_new(badge)) {
                gtk_widget_set_valign(W(pill), GTK_ALIGN_CENTER)
                gtk_widget_add_css_class(W(pill), "agterm-palette-badge")
                gtk_box_append(cast(box), W(pill))
            }
            if let shortcut = item.row.shortcut, let chord = op(gtk_label_new(shortcut)) {
                gtk_widget_add_css_class(W(chord), "dim-label")
                gtk_box_append(cast(box), W(chord))
            }
            gtk_list_box_row_set_child(GLBR(row), W(box))
            gtk_list_box_append(lb, W(row))
            rendered.append(item)
        }
        paletteItems = rendered
        if let first = gtk_list_box_get_row_at_index(lb, 0) { gtk_list_box_select_row(lb, first) }
        if let vadj = paletteVadjustment() { gtk_adjustment_set_value(vadj, 0) }   // reset scroll to top on re-filter
    }

    func runPaletteSelected() {
        guard let lb = paletteList, let row = gtk_list_box_get_selected_row(lb) else { return }
        runPaletteIndex(Int(gtk_list_box_row_get_index(row)))
    }

    func runPaletteRow(_ row: OpaquePointer?) {
        guard let row else { return }
        runPaletteIndex(Int(gtk_list_box_row_get_index(GLBR(row))))
    }

    private func runPaletteIndex(_ idx: Int) {
        guard idx >= 0, idx < paletteItems.count else { return }
        let run = paletteItems[idx].run
        closePalette()
        run()
    }

    func closePalette() {
        guard let win = paletteWindow else { return }
        paletteWindow = nil
        paletteList = nil
        paletteItems = []
        paletteAll = LinuxPaletteList()
        resumeAutoFollow()
        gtk_window_destroy(WIN(win))
    }

    func paletteWasDestroyed() {
        guard paletteWindow != nil else { return }
        paletteWindow = nil
        paletteList = nil
        paletteItems = []
        paletteAll = LinuxPaletteList()
        resumeAutoFollow()
    }

    /// Move the highlighted palette result up/down (Up/Down arrows from the search entry), clamped at the
    /// ends. The result list stays focused on the entry so typing continues to filter.
    func paletteMove(down: Bool) {
        guard let lb = paletteList else { return }
        let idx = gtk_list_box_get_selected_row(lb).map { Int(gtk_list_box_row_get_index($0)) } ?? -1
        let newIdx = idx + (down ? 1 : -1)
        if let row = gtk_list_box_get_row_at_index(lb, Int32(newIdx)) {
            gtk_list_box_select_row(lb, row)
            scrollListBoxRowIntoView(lb, toIndex: newIdx)
        }
    }

    /// The palette scrolled-window's vertical adjustment (the list box is wrapped in a viewport).
    private func paletteVadjustment() -> UnsafeMutablePointer<GtkAdjustment>? {
        guard let lb = paletteList,
              let scroller = gtk_widget_get_ancestor(W(lb), gtk_scrolled_window_get_type()) else { return nil }
        return gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
    }

    /// Keep the keyboard-selected row visible: the search entry keeps focus, so GtkListBox won't auto-scroll
    /// to a programmatic selection — clamp the scrolled window to the (uniform-height) row's extent ourselves.
    /// Clamp a list box's scrolled window so the row at `index` is fully visible. Shared by the command
    /// palette + theme picker (both keep focus in their search entry, so GtkListBox won't auto-scroll a
    /// programmatic selection). Uses the row's ACTUAL position — uniform index×height underestimated the
    /// offset, so scrolling DOWN lagged a row behind the selection. clamp_page brings [y, y+h] into view.
    func scrollListBoxRowIntoView(_ lb: OpaquePointer, toIndex index: Int) {
        guard let scroller = gtk_widget_get_ancestor(W(lb), gtk_scrolled_window_get_type()),
              let vadj = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller)),
              let row = gtk_list_box_get_row_at_index(lb, Int32(index)) else { return }
        var origin = graphene_point_t()
        var translated = graphene_point_t()
        guard gtk_widget_compute_point(W(OpaquePointer(row)), W(lb), &origin, &translated) != 0 else { return }
        let ry = Double(translated.y)
        gtk_adjustment_clamp_page(vadj, ry, ry + max(1, Double(gtk_widget_get_height(W(OpaquePointer(row))))))
    }
}

private let onPaletteSearch: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { entry, _ in
    MainActor.assumeIsolated {
        let text = gtk_editable_get_text(entry).map { String(cString: $0) } ?? ""
        controllerForWidget(entry)?.filterPalette(text)
    }
}
private let onPaletteActivate: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { entry, _ in
    MainActor.assumeIsolated { controllerForWidget(entry)?.runPaletteSelected() }
}
private let onPaletteRow: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { list, row, _ in
    MainActor.assumeIsolated { controllerForWidget(list)?.runPaletteRow(row) }
}
private let onPaletteKey: @MainActor @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { keys, keyval, _, _, _ in
    switch keyval {
    case 0xFF1B: MainActor.assumeIsolated { controllerForEventController(keys)?.closePalette() }; return 1
    case 0xFF52: MainActor.assumeIsolated { controllerForEventController(keys)?.paletteMove(down: false) }; return 1
    case 0xFF54: MainActor.assumeIsolated { controllerForEventController(keys)?.paletteMove(down: true) }; return 1
    default: return 0
    }
}
private let onPaletteDestroyed: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeRetainedValue().paletteWasDestroyed()
    }
}
