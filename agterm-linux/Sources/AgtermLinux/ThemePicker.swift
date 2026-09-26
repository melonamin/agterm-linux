// Theme picker (live preview): a modal GtkSearchEntry + GtkListBox of bundled ghostty
// themes. Arrow keys / typing move the selection, which previews the theme live (no
// persist); Enter commits + persists, Esc reverts to the theme in effect on open.
import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    private static let defaultThemeLabel = "default ghostty"

    func showThemePicker() {
        if themeWindow != nil { return }
        themeCommitted = currentTheme
        guard let win = op(gtk_window_new()) else { return }
        attachControllerContext(to: win, windowID: windowID)
        themeWindow = win
        noteUserActivity()
        suppressAutoFollow()
        connect(win, "destroy", unsafeBitCast(onThemeDestroyed, to: GCallback.self),
                Unmanaged.passRetained(self).toOpaque())
        gtk_window_set_transient_for(WIN(win), WIN(windowPointer))
        gtk_window_set_modal(WIN(win), 1)
        "Select Theme".withCString { gtk_window_set_title(WIN(win), $0) }
        gtk_window_set_default_size(WIN(win), 480, 440)

        let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        let entry = op(gtk_search_entry_new())
        connect(entry, "search-changed", unsafeBitCast(onThemeSearch as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        connect(entry, "activate", unsafeBitCast(onThemeActivateEnter as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))   // Enter commits
        let kc = gtk_event_controller_key_new()
        // CAPTURE phase so Esc/Enter/arrows reach us before the search entry consumes them (its own Esc
        // clears the text instead of cancelling the picker).
        gtk_event_controller_set_propagation_phase(kc, GTK_PHASE_CAPTURE)
        connect(kc, "key-pressed", unsafeBitCast(onThemeKey as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self))
        gtk_widget_add_controller(W(entry), kc)
        gtk_box_append(cast(box), W(entry))

        let scroller = op(gtk_scrolled_window_new())
        gtk_widget_set_vexpand(W(scroller), 1)
        let lb = op(gtk_list_box_new())
        themeList = lb
        connect(lb, "row-selected", unsafeBitCast(onThemeSelected as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        connect(lb, "row-activated", unsafeBitCast(onThemeActivated as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        gtk_scrolled_window_set_child(scroller, W(lb))
        gtk_box_append(cast(box), W(scroller))
        gtk_window_set_child(WIN(win), W(box))

        filterThemes("")
        gtk_window_present(WIN(win))
        _ = gtk_widget_grab_focus(W(entry))
    }

    func filterThemes(_ query: String) {
        guard let lb = themeList else { return }
        gtk_list_box_remove_all(lb)
        let all = [Self.defaultThemeLabel] + Self.bundledThemes()
        if query.isEmpty {
            themeItems = all
        } else {
            // shared ranking seam (lower-is-better, best first, alpha tie-break) — index 0 is
            // auto-selected below, so the best match is what Enter commits (was an inverted
            // descending sort that surfaced the WORST match first).
            themeItems = fuzzyRank(query: query, items: all, keys: { [$0] })
        }
        let selected = themeCommitted ?? Self.defaultThemeLabel
        for item in themeItems {
            guard let row = op(gtk_list_box_row_new()) else { continue }
            let label = op(gtk_label_new(item))
            gtk_label_set_xalign(label, 0)
            gtk_widget_set_margin_top(W(label), 6); gtk_widget_set_margin_bottom(W(label), 6)
            gtk_widget_set_margin_start(W(label), 10)
            gtk_list_box_row_set_child(GLBR(row), W(label))
            gtk_list_box_append(lb, W(row))
            if item == selected { gtk_list_box_select_row(lb, GLBR(row)) }
        }
        if gtk_list_box_get_selected_row(lb) == nil, let first = gtk_list_box_get_row_at_index(lb, 0) {
            gtk_list_box_select_row(lb, first)
        }
    }

    /// Map a list label to a theme name (the "default ghostty" row means nil).
    private func themeName(_ item: String) -> String? { item == Self.defaultThemeLabel ? nil : item }

    func themePreviewSelected(_ row: OpaquePointer?) {
        guard let row else { return }
        let idx = Int(gtk_list_box_row_get_index(GLBR(row)))
        guard idx >= 0, idx < themeItems.count else { return }
        // debounce the live preview so rapid arrow nav collapses to one config rebuild (macOS parity).
        let name = themeName(themeItems[idx])
        themePreviewDebouncer.schedule(after: Self.themePreviewDebounceInterval) { [weak self] in
            self?.previewTheme(name)
        }
    }

    func moveThemeSelection(_ delta: Int) {
        guard let lb = themeList else { return }
        let cur = gtk_list_box_get_selected_row(lb).map { Int(gtk_list_box_row_get_index($0)) } ?? 0
        let next = max(0, min(themeItems.count - 1, cur + delta))
        if let row = gtk_list_box_get_row_at_index(lb, Int32(next)) {
            gtk_list_box_select_row(lb, row)
            scrollListBoxRowIntoView(lb, toIndex: next)
        }
    }

    func commitTheme() {
        if let lb = themeList, let row = gtk_list_box_get_selected_row(lb) {
            let idx = Int(gtk_list_box_row_get_index(row))
            if idx >= 0, idx < themeItems.count {
                applyTheme(themeName(themeItems[idx]))
                closeThemePicker()
                return
            }
        }
        // Nothing selected to commit — a query matching no theme leaves the list EMPTY, so Enter lands here
        // with the LAST previewed theme still on every live surface. Closing would clear the preview
        // override without reverting, stranding an unpersisted theme that the next chrome re-resolve
        // repaints from the persisted one — the exact drift the override exists to prevent. Revert instead.
        cancelTheme()
    }

    func cancelTheme() {
        // Guard FIRST, before `previewTheme` sets the process-global override: `closeThemePicker` is what
        // clears it, and that is a no-op with no picker up, so a cancel reached after teardown would pin
        // every window to a stale, unpersisted theme for the rest of the process. Three callers reach this:
        // Esc in `onThemeKey`, `commitTheme`'s empty-list fallthrough (where the `row-activated` and
        // entry-`activate` signals land too, since both go through `commitTheme`), and `windowWillClose` —
        // so the invariant belongs here rather than in each caller.
        guard themeWindow != nil else { return }
        themePreviewDebouncer.cancel()   // drop a pending nav preview so it can't override the revert
        previewTheme(themeCommitted)     // revert the live preview immediately (no persist)
        closeThemePicker()
    }

    func closeThemePicker() {
        guard let win = themeWindow else { return }
        teardownThemePicker()
        gtk_window_destroy(WIN(win))
    }

    /// Handles the window-manager close path, which is a cancellation rather than a commit.
    func themePickerWasDestroyed() {
        guard themeWindow != nil else { return }
        previewTheme(themeCommitted)   // revert the live preview; the window is already going away
        teardownThemePicker()
    }

    /// The state every picker exit shares — ONE place, so preview state added later cannot be cleared on
    /// only one of the two paths (a leaked `themePreviewSettings` would shadow the persisted theme for the
    /// rest of the process).
    private func teardownThemePicker() {
        themePreviewDebouncer.cancel()   // any close path (incl. commit) cancels a pending preview
        Self.themePreviewSettings = nil  // later config_change re-resolves read the persisted theme again
        themeWindow = nil
        themeList = nil
        themeItems = []
        resumeAutoFollow()
    }
}

private let onThemeDestroyed: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeRetainedValue().themePickerWasDestroyed()
    }
}

private let onThemeSearch: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { entry, _ in
    MainActor.assumeIsolated {
        let text = gtk_editable_get_text(entry).map { String(cString: $0) } ?? ""
        controllerForWidget(entry)?.filterThemes(text)
    }
}
private let onThemeSelected: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { list, row, _ in
    MainActor.assumeIsolated { controllerForWidget(list)?.themePreviewSelected(row) }
}
private let onThemeActivated: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { list, _, _ in
    MainActor.assumeIsolated { controllerForWidget(list)?.commitTheme() }
}
private let onThemeActivateEnter: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { entry, _ in
    MainActor.assumeIsolated { controllerForWidget(entry)?.commitTheme() }
}
private let onThemeKey: @MainActor @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { keys, keyval, _, _, _ in
    let controller = MainActor.assumeIsolated { controllerForEventController(keys) }
    switch keyval {
    case 0xFF1B: MainActor.assumeIsolated { controller?.cancelTheme() }; return 1
    case 0xFF0D, 0xFF8D: MainActor.assumeIsolated { controller?.commitTheme() }; return 1
    case 0xFF52: MainActor.assumeIsolated { controller?.moveThemeSelection(-1) }; return 1
    case 0xFF54: MainActor.assumeIsolated { controller?.moveThemeSelection(1) }; return 1
    default: return 0
    }
}
