import CGtk
import Foundation
import agtermCore

/// Per-row and per-header updaters: the in-place half of the incremental sidebar. Every write is guarded
/// by the widget set's last-applied cache (`SidebarRuntime.swift`).
@MainActor
extension AppController {
    static func applyRowBadge(_ text: String?, to badge: OpaquePointer) {
        guard let text else {
            gtk_widget_set_visible(W(badge), 0)
            gtk_label_set_text(badge, "")
            return
        }
        "<span background=\"#cc3333\" foreground=\"white\"> \(text) </span>".withCString {
            gtk_label_set_markup(badge, $0)
        }
        gtk_widget_set_visible(W(badge), 1)
    }

    func updateSessionRow(_ id: UUID, content: SidebarSnapshot.RowContent) {
        guard let widgets = sidebarRuntime.rows[id] else { return }
        let previous = widgets.applied
        guard previous != content else { return }
        var applied = content
        let slot = NameSlot(current: widgets.name, box: widgets.box, after: widgets.lead)
        let named = applyNameWidget(slot,
                                    previous: previous.map { (name: $0.name, renaming: $0.renaming) },
                                    content: (content.name, content.renaming)) { [weak self] in
            self?.makeSessionNameWidget(id, content: content)
        }
        widgets.name = named.widget
        applied.name = named.name
        applied.renaming = named.renaming
        // A breadcrumb label's tooltip is its full text; only the in-place write leaves it stale.
        if !named.renaming, previous?.renaming == named.renaming, store.sidebarMode == .flagged,
           previous?.name != named.name {
            named.name.withCString { gtk_widget_set_tooltip_text(W(named.widget), $0) }
        }
        if previous?.glyph != content.glyph || previous?.blink != content.blink {
            Self.applyStatusGlyph(content.glyph, blink: content.blink,
                                  phase: sidebarRuntime.blinkPhase.phase, to: widgets.glyph)
        }
        if previous?.star != content.star { gtk_widget_set_visible(W(widgets.star), content.star ? 1 : 0) }
        if previous?.badge != content.badge { Self.applyRowBadge(content.badge, to: widgets.badge) }
        widgets.applied = applied
    }

    func updateWorkspaceHeader(_ key: SidebarSnapshot.Section.Key,
                               content: SidebarSnapshot.HeaderContent) {
        guard case .workspace(let workspaceID) = key, let widgets = sidebarRuntime.sections[key],
              let name = widgets.name, let icon = widgets.icon else { return }
        let previous = widgets.applied
        guard previous != content else { return }
        var applied = content
        let slot = NameSlot(current: name, box: widgets.header, after: icon)
        let named = applyNameWidget(slot,
                                    previous: previous.map { (name: $0.name, renaming: $0.renaming) },
                                    content: (content.name, content.renaming)) { [weak self] in
            guard let widget = self?.makeNameWidget(id: workspaceID, text: content.name,
                                                    isWorkspace: true) else { return nil }
            gtk_widget_add_css_class(W(widget), "heading")
            return widget
        }
        widgets.name = named.widget
        applied.name = named.name
        applied.renaming = named.renaming
        if previous?.focusMember != content.focusMember {
            applyWorkspaceFocusMembership(icon, member: content.focusMember)
        }
        if let add = widgets.add {
            if previous?.addVisible != content.addVisible {
                gtk_widget_set_visible(W(add), content.addVisible ? 1 : 0)
            }
            if previous?.name != content.name {
                Self.applyAddSessionTooltip(add, workspace: content.name)
            }
        }
        if previous?.expanded != content.expanded, let disc = widgets.disc {
            gtk_button_set_icon_name(BUTTON(disc), Self.disclosureIconName(expanded: content.expanded))
        }
        widgets.applied = applied
    }

    /// The name half of a row or a header: a plain text write, or the label ↔ rename-entry swap that is
    /// the only per-row structural edit. The swap runs solely when the `renaming` flag flipped, and goes
    /// through `make` in BOTH directions because `makeNameWidget` is the one place `renameEntry` is set
    /// and the double-click gesture attached. Returns the widget now on screen with the name and flag it
    /// actually shows: when GTK refuses to build the replacement the outgoing widget stays, keeping its
    /// `nameLabels` registration and so still renameable, and recording what IT shows is what makes a
    /// later content change re-attempt the swap.
    private func applyNameWidget(_ slot: NameSlot,
                                 previous: (name: String, renaming: Bool)?,
                                 content: (name: String, renaming: Bool),
                                 make: () -> OpaquePointer?)
        -> (widget: OpaquePointer, name: String, renaming: Bool) {
        guard previous?.renaming != content.renaming else {
            if previous?.name != content.name, !content.renaming {
                content.name.withCString { gtk_label_set_text(slot.current, $0) }
            }
            return (slot.current, content.name, content.renaming)
        }
        guard let replacement = make() else {
            return (slot.current, previous?.name ?? content.name,
                    previous?.renaming ?? content.renaming)
        }
        nameLabels[slot.current] = nil
        gtk_box_remove(cast(slot.box), W(slot.current))
        gtk_box_insert_child_after(cast(slot.box), W(replacement), W(slot.after))
        return (replacement, content.name, content.renaming)
    }
}

/// Where a name widget lives: the label or entry on screen, the box holding it, and the sibling a swap
/// re-inserts the replacement after.
private struct NameSlot {
    let current: OpaquePointer
    let box: OpaquePointer
    let after: OpaquePointer
}

/// What one apply pass did that its tail must react to: rows GTK re-rooted (an insert and a move both
/// reset the published SELECTED state), whether a widget was detached at all, and whether that took a
/// popover down with it.
private struct SidebarSyncOutcome {
    var rerootedRows: Set<UUID> = []
    var detached = false
    var dismissedPopover = false
    /// Rows and sections GTK refused to build; they are kept out of the applied snapshot so the next
    /// pass retries them.
    var unbuiltRows: Set<UUID> = []
    var unbuiltSections: Set<SidebarSnapshot.Section.Key> = []

    mutating func noteDetach(dismissedPopover: Bool) {
        detached = true
        self.dismissedPopover = self.dismissedPopover || dismissedPopover
    }
}

@MainActor
extension AppController {
    /// The sidebar's single entry point: build what should be rendered, diff it against what IS, and
    /// apply only the difference. `force` skips the diff for the one case a diff cannot express — every
    /// label must be re-measured under new CSS after a font or DPI change.
    func syncSidebar(force: Bool = false, preferMoving: Set<UUID> = []) {
        guard sidebarRuntime.syncGate.enter() else { return }
        defer { sidebarRuntime.syncGate.exit() }
        runSidebarSyncPass(force: force, preferMoving: preferMoving)
        // Drain what re-entered, unforced — both forced callers are top-level.
        while sidebarRuntime.syncGate.takePending() {
            runSidebarSyncPass(force: false, preferMoving: [])
        }
    }

    private func runSidebarSyncPass(force: Bool, preferMoving: Set<UUID>) {
        let settings = linuxSettingsStore().load()
        guard !force else { return rebuildSidebar(settings: settings) }
        let desired = SidebarSnapshot.desired(from: store, settings: settings, renaming: renaming)
        let ops = SidebarSnapshotDiff.plan(from: sidebarRuntime.current, to: desired,
                                           preferMoving: preferMoving)
        if ops.first == .rebuildAll { return rebuildSidebar(settings: settings) }
        // Read BEFORE any dismissal: `detachPopover` consumes the capture even under `refocus: false`.
        let heldSearchEntry = popoverTookKeyboardFromSearchEntry
        var outcome = SidebarSyncOutcome()
        applyLayoutOps(ops, desired: desired, outcome: &outcome)
        // A part GTK refused to build is left out of the applied snapshot, so the next pass plans its
        // insert again instead of recording a widget that is not there.
        sidebarRuntime.current = desired.without(rows: outcome.unbuiltRows,
                                                 sections: outcome.unbuiltSections)
        finishSidebarSync(settings: settings, outcome: outcome, heldSearchEntry: heldSearchEntry)
    }

    /// The forced path, private to the sync engine: every row destroyed and rebuilt. Reached only when
    /// the planner cannot express the change — a mode switch, or a font/DPI change that must re-measure
    /// every label under new CSS.
    private func rebuildSidebar(settings: AppSettings) {
        // Read BEFORE the dismissal: `detachPopover` consumes the capture even under `refocus: false`.
        let heldSearchEntry = popoverTookKeyboardFromSearchEntry
        // GtkPopover is parented to the row's GtkListBox while its context menu is open. Detach it
        // before destroying that list box: GtkListBox disposal otherwise treats the popover as a row,
        // repeatedly fails to remove it, and starves the GTK main loop. `refocus: false` — a grab fires
        // `surfaceDidFocus`, which RE-ENTERS the sync — so the keyboard repair runs in the shared tail.
        var outcome = SidebarSyncOutcome()
        outcome.noteDetach(dismissedPopover: contextMenuPopover != nil)
        dismissContextMenu(refocus: false)
        // Maps drop BEFORE the widgets they key, so nothing can resolve a disposed row mid-teardown.
        rowSession.removeAll()
        nameLabels.removeAll()
        workspaceDiscButtons.removeAll()
        sidebarRuntime.rows.removeAll()
        sidebarRuntime.sections.removeAll()
        sidebarRuntime.selectionRepublishScope.addAll()   // every row is about to be re-rooted
        while let child = gtk_widget_get_first_child(W(sidebarBox)) {
            gtk_box_remove(cast(sidebarBox), child)
        }

        let desired = SidebarSnapshot.desired(from: store, settings: settings, renaming: renaming)
        for section in desired.sections {
            guard let widgets = makeSection(section, selection: desired.selection) else { continue }
            gtk_box_append(cast(sidebarBox), W(widgets.wrapper))
        }
        // A part GTK refused to build is left out of the applied snapshot, so the next pass plans it
        // again — the same contract the incremental path holds, read back off the maps this rebuild
        // just repopulated.
        sidebarRuntime.current = desired.without(
            rows: Set(desired.sections.flatMap(\.rows)).subtracting(sidebarRuntime.rows.keys),
            sections: Set(desired.sections.map(\.key)).subtracting(sidebarRuntime.sections.keys))
        finishSidebarSync(settings: settings, outcome: outcome, heldSearchEntry: heldSearchEntry)
    }

    /// Ops run in emitted order against the live tree: every index is anchor-relative to the list as it
    /// stands at that moment, and a move is "remove it from where it is, then insert at that index".
    /// `SidebarSnapshotDiffTests`' simulator pins the same rule.
    private func applyLayoutOps(_ ops: [SidebarSnapshotDiff.LayoutOp], desired: SidebarSnapshot,
                                outcome: inout SidebarSyncOutcome) {
        var order = sidebarRuntime.current.sections.map(\.key)
        let sections = desired.sectionsByKey
        let rowContent = desired.rowContent
        for op in ops {
            switch op {
            case .rebuildAll:
                preconditionFailure("a rebuild is taken by the pass itself, never applied as an op")
            case .removeRow(let id):
                removeSidebarRow(id, outcome: &outcome)
            case .insertRow(let id, let key, let index):
                guard let content = rowContent[id],
                      insertSidebarRow(id, content: content, into: key, at: index,
                                       selected: desired.selection.contains(id)) else {
                    outcome.unbuiltRows.insert(id)
                    continue
                }
                outcome.rerootedRows.insert(id)
            case .moveRow(let id, let key, let index):
                guard moveSidebarRow(id, into: key, at: index, outcome: &outcome) else { continue }
                outcome.rerootedRows.insert(id)
            case .removeSection(let key):
                removeSidebarSection(key, outcome: &outcome)
                order.removeAll { $0 == key }
            case .insertSection(let key, let index):
                guard let section = sections[key],
                      insertSidebarSection(section, after: wrapper(in: order, before: index),
                                           selection: desired.selection) else {
                    outcome.unbuiltSections.insert(key)
                    continue
                }
                order.insert(key, at: index)
            case .moveSection(let key, let index):
                order.removeAll { $0 == key }
                if let widgets = sidebarRuntime.sections[key] {
                    gtk_box_reorder_child_after(cast(sidebarBox), W(widgets.wrapper),
                                                W(wrapper(in: order, before: index)))
                }
                order.insert(key, at: index)
            case .setExpanded(let key, let expanded):
                guard let widgets = sidebarRuntime.sections[key] else { continue }
                // Collapsing detaches nothing, but it still unroots a popover parented inside the list
                // box and strands a rename entry hosted there.
                if !expanded { outcome.noteDetach(dismissedPopover: detachGuard(widgets.listBox)) }
                gtk_widget_set_visible(W(widgets.listBox), expanded ? 1 : 0)
            case .setHint(let key, let shows):
                guard let hint = sidebarRuntime.sections[key]?.hint else { continue }
                gtk_widget_set_visible(W(hint), shows ? 1 : 0)
            case .updateHeader(let key):
                guard let content = sections[key]?.header else { continue }
                updateWorkspaceHeader(key, content: content)
            case .updateRow(let id):
                guard let content = rowContent[id] else { continue }
                updateSessionRow(id, content: content)
            case .updateSelection(let ids):
                for id in ids {
                    guard let widgets = sidebarRuntime.rows[id] else { continue }
                    setSidebarSelectionStyle(widgets.row, selected: desired.selection.contains(id))
                }
            }
        }
    }

    /// The `sidebarBox` child a section landing at `index` goes after — nil for the first slot, which
    /// both `gtk_box_insert_child_after` and `gtk_box_reorder_child_after` read as "prepend".
    private func wrapper(in order: [SidebarSnapshot.Section.Key], before index: Int) -> OpaquePointer? {
        guard index > 0, order.indices.contains(index - 1) else { return nil }
        return sidebarRuntime.sections[order[index - 1]]?.wrapper
    }

    private func removeSidebarRow(_ id: UUID, outcome: inout SidebarSyncOutcome) {
        guard let widgets = sidebarRuntime.rows[id] else { return }
        outcome.noteDetach(dismissedPopover: detachGuard(widgets.row))
        forgetSidebarRow(id, widgets: widgets)
        guard let listBox = gtk_widget_get_parent(W(widgets.row)) else { return }
        gtk_list_box_remove(OpaquePointer(listBox), W(widgets.row))
    }

    private func insertSidebarRow(_ id: UUID, content: SidebarSnapshot.RowContent,
                                  into key: SidebarSnapshot.Section.Key, at index: Int,
                                  selected: Bool) -> Bool {
        guard let section = sidebarRuntime.sections[key],
              let row = makeRow(id, content: content) else { return false }
        gtk_list_box_insert(section.listBox, W(row), Int32(index))
        setSidebarSelectionStyle(row, selected: selected)
        return true
    }

    /// A row move IS a reparent — the list box holds the sole reference to a sunk row — so the remove
    /// would drop the last one before the insert could take it.
    private func moveSidebarRow(_ id: UUID, into key: SidebarSnapshot.Section.Key, at index: Int,
                                outcome: inout SidebarSyncOutcome) -> Bool {
        guard let widgets = sidebarRuntime.rows[id],
              let section = sidebarRuntime.sections[key] else { return false }
        outcome.noteDetach(dismissedPopover: detachGuard(widgets.row))
        _ = g_object_ref(RAW(widgets.row))
        defer { g_object_unref(RAW(widgets.row)) }
        if let listBox = gtk_widget_get_parent(W(widgets.row)) {
            gtk_list_box_remove(OpaquePointer(listBox), W(widgets.row))
        }
        gtk_list_box_insert(section.listBox, W(widgets.row), Int32(index))
        return true
    }

    private func insertSidebarSection(_ section: SidebarSnapshot.Section, after previous: OpaquePointer?,
                                      selection: Set<UUID>) -> Bool {
        guard let widgets = makeSection(section, selection: selection,
                                        includingRows: false) else { return false }
        gtk_box_insert_child_after(cast(sidebarBox), W(widgets.wrapper), W(previous))
        return true
    }

    /// A removed section takes its rows' widgets with it; the planner rebuilds any survivor elsewhere as
    /// an insert, so every map entry the subtree owns drops here.
    private func removeSidebarSection(_ key: SidebarSnapshot.Section.Key,
                                      outcome: inout SidebarSyncOutcome) {
        guard let widgets = sidebarRuntime.sections[key] else { return }
        outcome.noteDetach(dismissedPopover: detachGuard(widgets.wrapper))
        for id in sidebarRuntime.current.sections.first(where: { $0.key == key })?.rows ?? [] {
            guard let row = sidebarRuntime.rows[id] else { continue }
            forgetSidebarRow(id, widgets: row)
        }
        for widget in [widgets.disc, widgets.add, widgets.header].compactMap({ $0 }) {
            workspaceDiscButtons[widget] = nil
        }
        if let name = widgets.name { nameLabels[name] = nil }
        sidebarRuntime.sections[key] = nil
        gtk_box_remove(cast(sidebarBox), W(widgets.wrapper))
    }

    private func forgetSidebarRow(_ id: UUID, widgets: SessionRowWidgets) {
        rowSession[widgets.row] = nil
        nameLabels[widgets.name] = nil
        sidebarRuntime.rows[id] = nil
    }

    /// What a widget about to be removed, moved or hidden must give up first: a popover parented to it or
    /// to a descendant would be left unrooted (the documented close-hang shape), and a rename entry it
    /// hosts must commit while still valid — no focus-out will fire for it, since the header row is
    /// non-focusable and its buttons take no focus on click. Returns whether a popover went down.
    private func detachGuard(_ widget: OpaquePointer) -> Bool {
        if let entry = renameEntry,
           entry == widget || gtk_widget_is_ancestor(W(entry), W(widget)) != 0 {
            commitInlineRename(RAW(entry))
        }
        guard let popover = contextMenuPopover, let parent = gtk_widget_get_parent(W(popover)),
              OpaquePointer(parent) == widget
                || gtk_widget_is_ancestor(parent, W(widget)) != 0 else { return false }
        dismissContextMenu(refocus: false)
        return true
    }

    /// The tail BOTH passes end in — everything outside the incremental apply and outside the forced
    /// rebuild's own teardown and build loop — written once, so neither can drop a call or reorder one.
    private func finishSidebarSync(settings: AppSettings, outcome: SidebarSyncOutcome,
                                   heldSearchEntry: Bool) {
        updateWorkspaceFilterButton()
        updateDashboardStatusIndicators(settings: settings)
        updateSessionPickerStatusIcons(settings: settings)
        let hadSessionPicker = sessionPickerPopover != nil
        // `refocusOnDismiss: false` for the rebuild's reason: the grab would re-enter this sync.
        updateAttentionButton(settings: settings, refocusOnDismiss: false)
        let dismissedSessionPicker = hadSessionPicker && sessionPickerPopover == nil
        refreshSidebarWidthFloor()
        // A rebuild destroyed every glyph label the timer tracked; re-derive from the fresh ones.
        resyncBlinkPhase()
        sidebarRuntime.selectionRepublishScope.add(outcome.rerootedRows)
        if !sidebarRuntime.selectionRepublishScope.isEmpty { armSelectionRepublish() }
        guard outcome.detached || dismissedSessionPicker else { return }
        // The search entry is restored only when a popover actually went down — that dismissal skipped
        // its own grab. An ordinary detach (a row move) took no keyboard to give back.
        let restored = (outcome.dismissedPopover || dismissedSessionPicker)
            && heldSearchEntry && restoreSearchEntryFocus()
        if !restored { refocusIfStranded() }
    }

    /// GtkListBoxRow resets the published SELECTED state whenever GTK roots it, which an insert, a move
    /// and a rebuild all do (the list intentionally stays in GTK_SELECTION_NONE, so nothing re-derives
    /// it). Re-publish on the next main-loop turn, after every row is rooted; later selection changes
    /// update synchronously. Arming supersedes a pending job, hence the scope living on the runtime.
    /// Disarmed in `windowWillClose` — a pending job must not touch a destroyed widget tree
    /// (`.claude/rules/main-loop.md`).
    private func armSelectionRepublish() {
        selectionRepublish.arm { [weak self] in
            guard let self else { return }
            syncSidebarSelectionStyles(ids: sidebarRuntime.selectionRepublishScope.take())
        }
    }

    /// Arm the shared pulse only while a tracked glyph carries the blink marker AND is on screen, and
    /// only while the desktop asks for no reduced motion — the timer is otherwise pure main-thread
    /// wakeups, and the pulse is decorative.
    func resyncBlinkPhase() {
        // The entry is nil while this window is still CONSTRUCTING (`openWindow` records the controller
        // only after `init` has presented and reconciled) and again after `windowWillClose`, which
        // empties the glyph maps first — so accepting nil rejects a REPLACED controller without making
        // the first map and the first sync dead.
        let live = gWindows[windowID]
        guard live == nil || live === self else { return }
        let shouldRun = LinuxBlinkPolicy.timerShouldRun(
            glyphs: blinkTrackedGlyphs().map {
                (marked: gtk_widget_has_css_class(W($0), LinuxBlinkPolicy.markerClass) != 0,
                 mapped: gtk_widget_get_mapped(W($0)) != 0)
            },
            prefersReducedMotion: linuxPrefersReducedMotion(gtk_settings_get_default()))
        sidebarRuntime.blinkPhase.resync(shouldRun: shouldRun) { [weak self] phase in
            self?.applyBlinkPhase(phase)
        }
    }

    private func blinkTrackedGlyphs() -> [OpaquePointer] {
        sidebarRuntime.rows.values.map(\.glyph)
            + Array(dashboardRuntime.statusIcons.values)
            + Array(sidebarRuntime.pickerGlyphs.values)
    }

    /// The window is leaving the screen. Stop outright rather than re-deriving: descendants still report
    /// themselves mapped while `unmap` is emitting, so a resync here would keep the timer armed.
    func stopBlinkPhaseForUnmap() {
        guard gWindows[windowID] === self else { return }
        sidebarRuntime.blinkPhase.cancel()
        applyBlinkPhase(false)
    }

    /// Marked labels only, mapped or not: a hidden blinking row must keep step while another visible
    /// glyph holds the timer, or expanding its workspace would show it out of phase until the next tick.
    private func applyBlinkPhase(_ phase: Bool) {
        let opacity = LinuxBlinkPolicy.opacity(phase: phase)
        let marker = LinuxBlinkPolicy.markerClass
        for label in blinkTrackedGlyphs() where gtk_widget_has_css_class(W(label), marker) != 0 {
            gtk_widget_set_opacity(W(label), opacity)
        }
    }
}
