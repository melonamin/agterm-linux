// In-terminal search (Ctrl+Shift+F): a GtkSearchEntry + match count + prev/next/close,
// shown above the terminal deck. Drives libghostty via start_search / search:<q> /
// navigate_search / end_search; libghostty replies through the START/END/TOTAL/SELECTED
// actions, routed back via GhosttySurface.applySearch* -> these controller methods.
import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func buildSearchBar() {
        let bar = OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))
        gtk_widget_set_visible(W(bar), 0)
        gtk_widget_add_css_class(W(bar), "toolbar")
        gtk_widget_set_margin_top(W(bar), 4)
        gtk_widget_set_margin_bottom(W(bar), 4)
        gtk_widget_set_margin_start(W(bar), 6)
        gtk_widget_set_margin_end(W(bar), 6)

        guard let entry = op(gtk_search_entry_new()), let label = op(gtk_label_new("")) else { return }
        gtk_widget_set_hexpand(W(entry), 1)
        connect(entry, "search-changed", unsafeBitCast(onSearchChanged as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        let kc = gtk_event_controller_key_new()
        connect(kc, "key-pressed", unsafeBitCast(onSearchKey as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self))
        gtk_widget_add_controller(W(entry), kc)
        gtk_box_append(cast(bar), W(entry))

        gtk_widget_add_css_class(W(label), "dim-label")
        gtk_box_append(cast(bar), W(label))

        func iconButton(_ icon: String, _ tip: String, _ cb: @escaping @convention(c) (OpaquePointer?, gpointer?) -> Void) {
            let b = OpaquePointer(gtk_button_new_from_icon_name(icon))
            gtk_widget_set_tooltip_text(W(b), tip)
            gtk_widget_set_focus_on_click(W(b), 0)   // Prev/Next must not pull focus off the entry
            connect(b, "clicked", unsafeBitCast(cb, to: GCallback.self))
            gtk_box_append(cast(bar), W(b))
        }
        iconButton("go-up-symbolic", "Previous match (Shift+Enter)", onSearchPrev)
        iconButton("go-down-symbolic", "Next match (Enter)", onSearchNext)
        iconButton("window-close-symbolic", "Close (Esc)", onSearchClose)

        searchBar = bar
        searchEntry = entry
        searchMatchLabel = label
    }

    /// Ctrl+Shift+F: open search on the active surface, or close it if already open.
    func toggleSearch() {
        if let owner = searchSurface {
            owner.endSearch()
            return
        }
        guard let id = store.selectedSessionID, let surf = searchTargetSurface(for: id) else { return }
        searchSurface = surf
        surf.startSearch()
    }

    // MARK: - Replies from libghostty (via GhosttySurface.applySearch*)

    func searchDidStart(_ id: UUID, needle: String?) {
        if !searchSuppressesAutoFollow {
            suppressAutoFollow()
            searchSuppressesAutoFollow = true
        }
        searchSessionID = id
        searchTotal = nil
        searchSelected = nil
        updateSearchLabel()
        gtk_widget_set_visible(W(searchBar), 1)
        if let needle { needle.withCString { gtk_editable_set_text(searchEntry, $0) } }
        _ = gtk_widget_grab_focus(W(searchEntry))
    }

    func searchDidEnd(_ id: UUID) {
        guard searchSessionID == id else { return }
        let owner = searchSurface
        endSearchAutoFollowSuppression()
        searchSessionID = nil
        searchSurface = nil
        gtk_widget_set_visible(W(searchBar), 0)
        owner?.grabFocus(supersedingPopoverCapture: true)
    }

    func searchDidReportTotal(_ id: UUID, total: Int?) { searchTotal = total; updateSearchLabel() }
    func searchDidReportSelected(_ id: UUID, selected: Int?) { searchSelected = selected; updateSearchLabel() }

    func searchDisplayText() -> String {
        guard let total = searchTotal else { return "" }
        return total == 0 ? "No results" : "\(searchSelected ?? 0)/\(total)"
    }

    private func updateSearchLabel() {
        let text: String
        text = searchDisplayText()
        text.withCString { gtk_label_set_text(searchMatchLabel, $0) }
    }

    // MARK: - Driven from the entry / buttons

    /// Search owns keyboard focus outside the terminal, so keep auto-follow suppressed for its whole
    /// lifetime. User input inside the entry still refreshes the idle stamp; the pending timer can fire
    /// normally after search closes. Control-driven query changes do not pass through this method.
    func noteSearchUserActivity() { noteUserActivity() }

    func endSearchAutoFollowSuppression() {
        guard searchSuppressesAutoFollow else { return }
        searchSuppressesAutoFollow = false
        resumeAutoFollow()
    }

    /// Clear host search ownership when its terminal disappears before libghostty can send END_SEARCH.
    /// Session removal uses this before tearing down the surface so auto-follow suppression stays balanced.
    func abandonSearch(ownedBy id: UUID) {
        guard searchSessionID == id || searchSurface?.sessionID == id else { return }
        endSearchAutoFollowSuppression()
        searchSessionID = nil
        searchSurface = nil
        searchTotal = nil
        searchSelected = nil
        gtk_widget_set_visible(W(searchBar), 0)
        // Unlike `searchDidEnd` above, there is no owner left to hand the keyboard back to.
        refocusIfStranded()
    }

    /// End a live search because the ACTIVE SESSION is about to change — the bar belongs to the outgoing
    /// session's surface. No refocus: both callers hand the keyboard on themselves via `showActive()`.
    func endSearchForSelectionChange() {
        guard let owner = searchSurface else { return }
        owner.endSearch()
        endSearchAutoFollowSuppression()
        searchSessionID = nil
        searchSurface = nil
        gtk_widget_set_visible(W(searchBar), 0)
    }

    /// Whether the window's focus widget sits inside a LIVE search's entry — the one legitimate keyboard
    /// owner `focusActiveSurface()` cannot resolve, since it is chrome rather than a surface.
    func searchEntryHoldsKeyboard() -> Bool {
        guard searchSessionID != nil, let entry = searchEntry,
              gtk_widget_get_mapped(W(entry)) != 0,
              let focus = gtk_window_get_focus(WIN(window)) else { return false }
        return focus == W(entry) || gtk_widget_is_ancestor(focus, W(entry)) != 0
    }

    /// Hand the keyboard back to a live search's entry. Returns `false` whenever the grab did not land
    /// (search ended, bar unmapped, GTK refused) — the caller MUST then run its own fallback repair.
    func restoreSearchEntryFocus() -> Bool {
        guard searchSessionID != nil, let entry = searchEntry,
              gtk_widget_get_mapped(W(entry)) != 0 else { return false }
        return gtk_widget_grab_focus(W(entry)) != 0
    }

    func searchQueryChanged(_ text: String) { searchSurface?.sendSearchQuery(text) }
    func searchNavigate(_ direction: SearchDirection) { searchSurface?.navigateSearch(direction) }
    func searchClose() { searchSurface?.endSearch() }
}

private let onSearchChanged: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { entry, _ in
    MainActor.assumeIsolated {
        let text = gtk_editable_get_text(entry).map { String(cString: $0) } ?? ""
        controllerForWidget(entry)?.searchQueryChanged(text)
    }
}
private let onSearchKey: @MainActor @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { keys, keyval, _, state, _ in
    let shift = (state & (1 << 0)) != 0
    let controller = MainActor.assumeIsolated { controllerForEventController(keys) }
    MainActor.assumeIsolated { controller?.noteSearchUserActivity() }
    switch keyval {
    case 0xFF1B: MainActor.assumeIsolated { controller?.searchClose() }; return 1
    case 0xFF0D, 0xFF8D: MainActor.assumeIsolated { controller?.searchNavigate(shift ? .previous : .next) }; return 1
    default: return 0
    }
}
private let onSearchPrev: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        controllerForWidget(button)?.noteSearchUserActivity()
        controllerForWidget(button)?.searchNavigate(.previous)
    }
}
private let onSearchNext: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        controllerForWidget(button)?.noteSearchUserActivity()
        controllerForWidget(button)?.searchNavigate(.next)
    }
}
private let onSearchClose: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        controllerForWidget(button)?.noteSearchUserActivity()
        controllerForWidget(button)?.searchClose()
    }
}
