import CGtk
import agtermCore

@MainActor
extension AppController {
    /// Re-derive the sidebar's width floor by MEASURING `sidebarBox` — the widest sidebar site by
    /// construction — and push it onto the paned start child, which is where it is stored and read back
    /// from. Called at the END of every `rebuildSidebar`, so the number matches the widgets that exist.
    /// Deliberately NOT tracked: `gtk-theme-name`, so a live theme switch that moved the row padding
    /// leaves the floor stale until the next rebuild.
    /// The full contract is the width-floor section of `agterm-linux/docs/sidebar.md`.
    func refreshSidebarWidthFloor() {
        guard let paned = splitView, let sidebar = gtk_paned_get_start_child(paned) else { return }
        var minimum: Int32 = 0
        gtk_widget_measure(W(sidebarBox), GTK_ORIENTATION_HORIZONTAL, -1, &minimum, nil, nil, nil)
        // `AppStore.sidebarWidthDefault` as the clamp's minimum is what PINS the floor to the default
        // width; see `LinuxSidebarPolicy.clampSidebarWidth`. Both terms come from `Int32`, so the
        // clamped answer is integral and the `Int32()` below is exact.
        let floor = LinuxSidebarPolicy.clampSidebarWidth(
            Double(minimum) + Self.sidebarScrollbarOverhead(),
            minimum: AppStore.sidebarWidthDefault)
        gtk_widget_set_size_request(sidebar, Int32(floor), -1)
        applySidebarWidth(paned)
    }

    /// The width the sidebar scroller's vertical scrollbar takes OUT of the viewport, which the
    /// `sidebarBox` measure cannot see: the bar is laid out BESIDE the content, between that box and the
    /// paned start child the floor is pushed onto. Zero unless GTK's
    /// `gtk-overlay-scrolling && GTK_OVERLAY_SCROLLING != "0"` is false — both terms, since the settings
    /// property alone misses the env-var case. It is unconditional, measured off a THROWAWAY scrolled
    /// window, and cached; `agterm-linux/docs/sidebar.md` records why each of those three.
    private static var cachedScrollbarOverhead: Double?

    /// Drop the cached reservation above, from `App.swift`'s `gtk-overlay-scrolling` observer: that
    /// property is LIVE (GNOME's `org.gnome.desktop.interface overlay-scrolling`, an XSETTINGS manager,
    /// or `gtk-4.0/settings.ini`), and the same observer's `rebuildSidebar` then re-measures through it.
    static func invalidateSidebarScrollbarOverhead() { cachedScrollbarOverhead = nil }

    private static func sidebarScrollbarOverhead() -> Double {
        if let cached = cachedScrollbarOverhead { return cached }
        let overhead = measureSidebarScrollbarOverhead()
        cachedScrollbarOverhead = overhead
        return overhead
    }

    private static func measureSidebarScrollbarOverhead() -> Double {
        // Seeded TRUE, GTK's own default, so a property read that failed leaves the floor where it is
        // rather than silently widening every sidebar.
        var overlay = true
        if let settings = gtk_settings_get_default() {
            var value = GValue()
            _ = g_value_init(&value, GType(20))   // G_TYPE_BOOLEAN
            g_value_set_boolean(&value, 1)
            "gtk-overlay-scrolling".withCString { g_object_get_property(GOBJ(settings), $0, &value) }
            overlay = g_value_get_boolean(&value) != 0
            g_value_unset(&value)
        }
        if overlay, g_getenv("GTK_OVERLAY_SCROLLING").map({ String(cString: $0) }) != "0" { return 0 }
        guard let probe = OpaquePointer(gtk_scrolled_window_new()) else { return 0 }
        _ = g_object_ref_sink(RAW(probe))
        defer { g_object_unref(RAW(probe)) }
        guard let bar = gtk_scrolled_window_get_vscrollbar(probe) else { return 0 }
        var minimum: Int32 = 0
        gtk_widget_measure(bar, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, nil, nil, nil)
        return Double(max(0, minimum))
    }

    /// The sidebar's EFFECTIVE minimum: the measured minimum of the paned START CHILD, which is what GTK
    /// clamps the divider up to — the content floor folded together with the `AdwHeaderBar` and the
    /// footer bottom bar. Never cached: the header's window-control minimum does not exist until the
    /// window is ROOTED, so the same measure from `AppController.init` sees only the bare size request.
    ///
    /// IMPORTANT: nil means both callers do NOTHING — never substitute a plausible default, or
    /// `captureSidebarWidth` reads every position as a drag and writes it over the user's request.
    private func sidebarEffectiveMinimum(_ paned: OpaquePointer) -> Double? {
        guard let child = gtk_paned_get_start_child(paned) else { return nil }
        var minimum: Int32 = 0
        gtk_widget_measure(child, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, nil, nil, nil)
        return Double(minimum)
    }

    /// GtkPaned's own `max-position` — the widest divider position the CURRENT window width leaves. A
    /// paned reports `G_MAXINT` here until its first allocation, i.e. already unbounded, and
    /// `laidOutSidebarWidth` reads a non-positive value as unbounded too, so a failed read means no cap.
    private func sidebarLayoutMaximum(_ paned: OpaquePointer) -> Double {
        var value = GValue()
        // The `GType` is spelled as its fundamental-type id because the `G_TYPE_*` names are GObject
        // macros Swift cannot import.
        _ = g_value_init(&value, GType(24))   // G_TYPE_INT
        "max-position".withCString { g_object_get_property(GOBJ(paned), $0, &value) }
        let maximum = g_value_get_int(&value)
        g_value_unset(&value)
        return Double(maximum)
    }

    /// Lay the divider out at the user's requested width as the current floor and window width allow.
    /// Pure layout: it never writes `store.sidebarWidth`. The `max-position` cap inside
    /// `laidOutSidebarWidth` is LOAD-BEARING — this also runs from inside GtkPaned's own `size_allocate`,
    /// where an over-wide `gtk_paned_set_position` is never re-clamped.
    ///
    /// IMPORTANT: the minimum must be `sidebarEffectiveMinimum`, the SAME one `captureSidebarWidth` passes
    /// to `persistedSidebarWidth`, never the content floor; see `LinuxSidebarPolicy.laidOutSidebarWidth`.
    func applySidebarWidth(_ paned: OpaquePointer) {
        guard store.sidebarVisible, let minimum = sidebarEffectiveMinimum(paned) else { return }
        let position = LinuxSidebarPolicy.laidOutSidebarWidth(
            requested: store.sidebarWidth, minimum: minimum,
            layoutMaximum: sidebarLayoutMaximum(paned))
        gtk_paned_set_position(paned, Int32(position.rounded()))
    }

    /// Build the desktop split as a real GtkPaned so the divider spans the complete window and owns
    /// a native horizontal-resize gesture. The shared store already persists the per-window width.
    func buildSidebarSplit(sidebar: OpaquePointer?, content: OpaquePointer?) -> OpaquePointer {
        guard let sidebar, let content,
              let paned = OpaquePointer(gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)) else {
            fatalError("failed to construct sidebar split")
        }
        splitView = paned
        gtk_widget_add_css_class(W(paned), "agterm-sidebar-split")
        gtk_widget_add_css_class(W(sidebar), "agterm-sidebar-column")
        gtk_paned_set_start_child(paned, W(sidebar))
        gtk_paned_set_end_child(paned, W(content))
        gtk_paned_set_resize_start_child(paned, 0)
        gtk_paned_set_shrink_start_child(paned, 0)
        gtk_paned_set_resize_end_child(paned, 1)
        gtk_paned_set_shrink_end_child(paned, 1)
        gtk_widget_set_visible(W(sidebar), store.sidebarVisible ? 1 : 0)
        // `controllerForWidget`, never unretained signal data: GTK emits paned notifications while a
        // closing window unmaps, after `windowWillClose` dropped the controller from `gWindows`.
        connect(paned, "notify::position", unsafeBitCast(onSidebarPanedPosition, to: GCallback.self))
        // The widening leg: GTK fires no `notify::position` when the window gets wider again, so without
        // this the divider stays at the narrow window's cap. See `agterm-linux/docs/sidebar.md`.
        connect(paned, "notify::max-position",
                unsafeBitCast(onSidebarPanedMaxPosition, to: GCallback.self))
        // Seeds the initial position too, so a legacy record clamped only to the shared 160 lays out at
        // the floor from the very first frame.
        refreshSidebarWidthFloor()
        return paned
    }

    func applySidebarVisibility() {
        guard let paned = splitView, let sidebar = gtk_paned_get_start_child(paned) else { return }
        gtk_widget_set_visible(sidebar, store.sidebarVisible ? 1 : 0)
        applySidebarWidth(paned)
    }

    /// Persist a divider position the USER dragged to. A position the LAYOUT produced — GTK clamping
    /// the divider up to the start child's minimum, or down to the window's `max-position` — is
    /// deliberately dropped; see `LinuxSidebarPolicy.persistedSidebarWidth`.
    func captureSidebarWidth(_ paned: OpaquePointer?) {
        guard let paned, store.sidebarVisible,
              let minimum = sidebarEffectiveMinimum(paned) else { return }
        let proposed = Double(gtk_paned_get_position(paned))
        guard let width = LinuxSidebarPolicy.persistedSidebarWidth(
            observed: proposed, requested: store.sidebarWidth, minimum: minimum,
            layoutMaximum: sidebarLayoutMaximum(paned)) else { return }
        if width != proposed {
            gtk_paned_set_position(paned, Int32(width.rounded()))
            return
        }
        // Idempotence: `persistedSidebarWidth` answers "is this a drag?", not "is this a change?", and it
        // can hand back the number already stored. Writing it again would re-arm the 0.4s save debouncer
        // on every allocation.
        guard abs(store.sidebarWidth - width) >= 1 else { return }
        store.sidebarWidth = width
        layoutSaveDebouncer.schedule(after: 0.4) { [weak self] in self?.store.save() }
    }
}

private let onSidebarPanedPosition: @MainActor @convention(c) (
    OpaquePointer?, OpaquePointer?, gpointer?
) -> Void = { paned, _, _ in
    MainActor.assumeIsolated { controllerForWidget(paned)?.captureSidebarWidth(paned) }
}

private let onSidebarPanedMaxPosition: @MainActor @convention(c) (
    OpaquePointer?, OpaquePointer?, gpointer?
) -> Void = { paned, _, _ in
    guard let paned else { return }
    MainActor.assumeIsolated { controllerForWidget(paned)?.applySidebarWidth(paned) }
}
