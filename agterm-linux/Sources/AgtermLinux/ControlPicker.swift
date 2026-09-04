import CGtk
import Foundation
import agtermCore

struct LinuxControlPickRow {
    let item: ControlPickItem?
    let originalIndex: Int?
    let customQuery: String?
}

@MainActor
extension AppController {
    func openPick(_ pick: PendingPick, window: String?, follow: Bool) -> ControlResponse {
        guard pickController.open(pick) else {
            return ControlResponse(ok: false, error: "pick already pending")
        }
        if follow { gtk_window_present(WIN(windowPointer)) }
        closePalette()
        showControlPick(pick)
        return ControlResponse(ok: true, result: ControlResult(id: pick.id))
    }

    func pickResult(_ target: String, window: String?) -> ControlResponse {
        if window == nil {
            if let live = PickRegistry.shared.livePick(for: target),
               let result = live.controller.result(for: target) {
                return ControlResponse(ok: true, result: ControlResult(pick: result))
            }
            if let retained = PickRegistry.shared.retainedResult(for: target) {
                return ControlResponse(ok: true, result: ControlResult(pick: retained.result))
            }
            return ControlResponse(ok: false, error: "unknown pick: \(target)")
        }
        if let retained = PickRegistry.shared.retainedResult(for: target) {
            guard retained.windowID == windowID else {
                return ControlResponse(ok: false, error: "unknown pick: \(target)")
            }
            return ControlResponse(ok: true, result: ControlResult(pick: retained.result))
        }
        guard let result = pickController.result(for: target) else {
            return ControlResponse(ok: false, error: "unknown pick: \(target)")
        }
        return ControlResponse(ok: true, result: ControlResult(pick: result))
    }

    func cancelPick(_ target: String, window: String?) -> ControlResponse {
        if window == nil {
            if let live = PickRegistry.shared.livePick(for: target) {
                if live.controller.pending?.id == target {
                    gWindows[live.windowID]?.cancelControlPick()
                }
                return ControlResponse(ok: true)
            }
            if PickRegistry.shared.retainedResult(for: target) != nil {
                return ControlResponse(ok: true)
            }
            return ControlResponse(ok: false, error: "unknown pick: \(target)")
        }
        if let retained = PickRegistry.shared.retainedResult(for: target) {
            return retained.windowID == windowID
                ? ControlResponse(ok: true)
                : ControlResponse(ok: false, error: "unknown pick: \(target)")
        }
        guard pickController.result(for: target) != nil else {
            return ControlResponse(ok: false, error: "unknown pick: \(target)")
        }
        if pickController.pending?.id == target { cancelControlPick() }
        return ControlResponse(ok: true)
    }

    private func showControlPick(_ pick: PendingPick) {
        guard let win = op(gtk_window_new()) else {
            pickController.cancel()
            return
        }
        controlPickWindow = win
        suppressAutoFollow()
        controlPickSuppressesAutoFollow = true
        attachControllerContext(to: win, windowID: windowID)
        connect(win, "destroy", unsafeBitCast(
            onControlPickDestroyed as @convention(c) (OpaquePointer?, gpointer?) -> Void,
            to: GCallback.self
        ), Unmanaged.passRetained(self).toOpaque())
        connect(win, "close-request", unsafeBitCast(
            onControlPickCloseRequest as @convention(c) (OpaquePointer?, gpointer?) -> gboolean,
            to: GCallback.self
        ))
        gtk_window_set_transient_for(WIN(win), WIN(windowPointer))
        gtk_window_set_modal(WIN(win), 1)
        "Select".withCString { gtk_window_set_title(WIN(win), $0) }
        let panelSize = interfacePanelSize(width: 520, height: 380)
        gtk_window_set_default_size(WIN(win), panelSize.0, panelSize.1)

        let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        gtk_widget_add_css_class(W(box), "agterm-interface-panel")
        let entry = op(gtk_search_entry_new())
        controlPickEntry = entry
        (pick.prompt ?? "Select…").withCString {
            gtk_entry_set_placeholder_text(UnsafeMutablePointer<GtkEntry>(entry), $0)
        }
        connect(entry, "search-changed", unsafeBitCast(
            onControlPickSearch as @convention(c) (OpaquePointer?, gpointer?) -> Void,
            to: GCallback.self
        ))
        connect(entry, "activate", unsafeBitCast(
            onControlPickActivate as @convention(c) (OpaquePointer?, gpointer?) -> Void,
            to: GCallback.self
        ))
        gtk_box_append(cast(box), W(entry))

        let scroller = op(gtk_scrolled_window_new())
        gtk_widget_set_vexpand(W(scroller), 1)
        let list = op(gtk_list_box_new())
        controlPickList = list
        "control-picker".withCString { gtk_widget_set_name(W(list), $0) }
        connect(list, "row-activated", unsafeBitCast(
            onControlPickRow as @convention(c)
                (OpaquePointer?, OpaquePointer?, gpointer?) -> Void,
            to: GCallback.self
        ))
        gtk_scrolled_window_set_child(scroller, W(list))
        gtk_box_append(cast(box), W(scroller))
        gtk_window_set_child(WIN(win), W(box))

        let keys = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        connect(keys, "key-pressed", unsafeBitCast(
            onControlPickKey as @convention(c)
                (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean,
            to: GCallback.self
        ))
        gtk_widget_add_controller(W(win), keys)

        filterControlPick("")
        gtk_window_present(WIN(win))
        _ = gtk_widget_grab_focus(W(entry))
    }

    func filterControlPick(_ query: String) {
        guard let list = controlPickList, let pending = pickController.pending else { return }
        while let child = gtk_widget_get_first_child(W(list)) {
            gtk_list_box_remove(list, child)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexed = pending.items.enumerated().map { (index: $0.offset, item: $0.element) }
        let filtered = fuzzyRank(query: trimmed, items: indexed) { value in
            value.item.subtitle.map { [value.item.label, $0] } ?? [value.item.label]
        }
        controlPickRows = filtered.map {
            LinuxControlPickRow(item: $0.item, originalIndex: $0.index, customQuery: nil)
        }
        if let label = pickCustomRowLabel(
            query: trimmed,
            filteredCount: filtered.count,
            allowCustom: pending.allowCustom
        ) {
            controlPickRows = [
                LinuxControlPickRow(item: nil, originalIndex: nil, customQuery: trimmed)
            ]
            appendControlPickRow(label: label, subtitle: nil, to: list)
        } else {
            for value in filtered {
                appendControlPickRow(label: value.item.label, subtitle: value.item.subtitle, to: list)
            }
        }
        if let first = gtk_list_box_get_row_at_index(list, 0) {
            gtk_list_box_select_row(list, first)
        }
    }

    private func appendControlPickRow(label: String, subtitle: String?, to list: OpaquePointer) {
        guard let row = op(gtk_list_box_row_new()),
              let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 1)),
              let title = op(gtk_label_new(label)) else { return }
        gtk_label_set_xalign(title, 0)
        gtk_label_set_ellipsize(title, PANGO_ELLIPSIZE_MIDDLE)
        gtk_box_append(cast(box), W(title))
        if let subtitle, let detail = op(gtk_label_new(subtitle)) {
            gtk_label_set_xalign(detail, 0)
            gtk_label_set_ellipsize(detail, PANGO_ELLIPSIZE_MIDDLE)
            gtk_widget_add_css_class(W(detail), "dim-label")
            gtk_box_append(cast(box), W(detail))
        }
        gtk_widget_set_margin_start(W(box), 12)
        gtk_widget_set_margin_end(W(box), 12)
        gtk_widget_set_margin_top(W(box), 6)
        gtk_widget_set_margin_bottom(W(box), 6)
        gtk_list_box_row_set_child(GLBR(row), W(box))
        gtk_list_box_append(list, W(row))
    }

    func runControlPickSelected() {
        guard let list = controlPickList,
              let row = gtk_list_box_get_selected_row(list) else { return }
        runControlPick(index: Int(gtk_list_box_row_get_index(row)))
    }

    func runControlPickRow(_ row: OpaquePointer?) {
        guard let row else { return }
        runControlPick(index: Int(gtk_list_box_row_get_index(GLBR(row))))
    }

    private func runControlPick(index: Int) {
        guard controlPickRows.indices.contains(index) else { return }
        let row = controlPickRows[index]
        if let query = row.customQuery {
            resolveControlPick(ControlPickResult(result: .custom, query: query))
        } else if let item = row.item, let originalIndex = row.originalIndex {
            resolveControlPick(ControlPickResult(
                result: .picked,
                id: item.id,
                label: item.label,
                index: originalIndex
            ))
        }
    }

    func moveControlPick(down: Bool) {
        guard let list = controlPickList else { return }
        let index = gtk_list_box_get_selected_row(list)
            .map { Int(gtk_list_box_row_get_index($0)) } ?? -1
        let next = index + (down ? 1 : -1)
        if let row = gtk_list_box_get_row_at_index(list, Int32(next)) {
            gtk_list_box_select_row(list, row)
            scrollListBoxRowIntoView(list, toIndex: next)
        }
    }

    func cancelControlPick() {
        guard pickController.pending != nil else { return }
        pickController.cancel()
        dismissControlPick(retainResultThroughRegistry: false)
    }

    private func resolveControlPick(_ result: ControlPickResult) {
        pickController.resolve(result)
        dismissControlPick(retainResultThroughRegistry: false)
    }

    /// `refocus: false` is for `windowWillClose` only, where the deferred grab below would run against a
    /// finalized window.
    func dismissControlPick(retainResultThroughRegistry: Bool, refocus: Bool = true) {
        if !retainResultThroughRegistry, pickController.pending != nil {
            pickController.cancel()
        }
        guard let win = controlPickWindow else {
            finishControlPickDismissal(refocus: refocus)
            return
        }
        controlPickWindow = nil
        controlPickList = nil
        controlPickEntry = nil
        controlPickRows = []
        finishControlPickDismissal(refocus: refocus)
        gtk_window_destroy(WIN(win))
    }

    func controlPickWasDestroyed() {
        guard controlPickWindow != nil else { return }
        controlPickWindow = nil
        controlPickList = nil
        controlPickEntry = nil
        controlPickRows = []
        if pickController.pending != nil { pickController.cancel() }
        finishControlPickDismissal(refocus: true)
    }

    /// The deferred one-shot re-checks controller identity because it can fire after `windowWillClose`
    /// finalized the window, and tests the search entry at FIRE time, not at dismissal time.
    private func finishControlPickDismissal(refocus: Bool) {
        if controlPickSuppressesAutoFollow {
            controlPickSuppressesAutoFollow = false
            resumeAutoFollow()
        }
        guard refocus, gtk_window_is_active(WIN(windowPointer)) != 0 else { return }
        MainTimer.schedule(after: 0) { [weak self] in
            guard let self, gWindows[self.windowID] === self,
                  !self.searchEntryHoldsKeyboard() else { return }
            self.focusActiveSurface()
        }
    }
}

private let onControlPickSearch: @MainActor @convention(c)
    (OpaquePointer?, gpointer?) -> Void = { entry, _ in
        MainActor.assumeIsolated {
            let query = gtk_editable_get_text(entry).map { String(cString: $0) } ?? ""
            controllerForWidget(entry)?.filterControlPick(query)
        }
    }

private let onControlPickActivate: @MainActor @convention(c)
    (OpaquePointer?, gpointer?) -> Void = { entry, _ in
        MainActor.assumeIsolated { controllerForWidget(entry)?.runControlPickSelected() }
    }

private let onControlPickRow: @MainActor @convention(c)
    (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { list, row, _ in
        MainActor.assumeIsolated { controllerForWidget(list)?.runControlPickRow(row) }
    }

private let onControlPickKey: @MainActor @convention(c)
    (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { keys, keyval, _, _, _ in
        switch keyval {
        case 0xFF1B:
            MainActor.assumeIsolated { controllerForEventController(keys)?.cancelControlPick() }
            return 1
        case 0xFF52:
            MainActor.assumeIsolated { controllerForEventController(keys)?.moveControlPick(down: false) }
            return 1
        case 0xFF54:
            MainActor.assumeIsolated { controllerForEventController(keys)?.moveControlPick(down: true) }
            return 1
        default:
            return 0
        }
    }

private let onControlPickCloseRequest: @MainActor @convention(c)
    (OpaquePointer?, gpointer?) -> gboolean = { window, _ in
        MainActor.assumeIsolated { controllerForWidget(window)?.cancelControlPick() }
        return 1
    }

private let onControlPickDestroyed: @MainActor @convention(c)
    (OpaquePointer?, gpointer?) -> Void = { _, data in
        guard let data else { return }
        MainActor.assumeIsolated {
            Unmanaged<AppController>.fromOpaque(data).takeRetainedValue().controlPickWasDestroyed()
        }
    }
