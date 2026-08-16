import agtermCore

enum LinuxSidebarPolicy {
    /// The CSS that scales the sidebar rows to the configured sidebar font size (nil = the shared
    /// default): the row text size, plus a `min-height` derived from the shared
    /// `AppSettings.sidebarRowHeight` that lowers libadwaita's `navigation-sidebar` row pin.
    /// That height is a FLOOR, not a cap — taller content still grows the row.
    static func sidebarCSS(fontSize: Double?) -> String {
        let size = AppSettings.clampSidebarFontSize(fontSize ?? AppSettings.defaultSidebarFontSize)
        let rowHeight = Int(AppSettings.sidebarRowHeight(fontSize: size))
        return """
            .agterm-sidebar label { font-size: \(size)pt; }
            .agterm-sidebar .navigation-sidebar > row { min-height: \(rowHeight)px; }
            """
    }

    @MainActor
    static func flaggedRowLabel(for session: Session, in store: AppStore) -> String {
        if let workspace = store.workspace(forSession: session.id) {
            return "\(session.displayName)  —  \(workspace.name)"
        }
        return session.displayName
    }

    /// Clamp a proposed sidebar width into `[minimum, AppStore.sidebarWidthMax]`. The `min` leg is an
    /// invariant the two functions below depend on: a position above the shared maximum is one GTK cannot
    /// honour, so `gtk_paned_set_position` ↔ `notify::position` would feed back instead of settling.
    /// `AppController.refreshSidebarWidthFloor` passes `AppStore.sidebarWidthDefault`, which is what PINS
    /// the derived floor to the default width; see `agterm-linux/docs/sidebar.md`.
    @MainActor
    static func clampSidebarWidth(_ proposed: Double, minimum: Double) -> Double {
        min(AppStore.sidebarWidthMax, max(minimum, proposed))
    }

    /// What the LAYOUT makes of a standing request: the request through the sidebar's minimum, then
    /// capped by what the current WINDOW width leaves. `AppController.applySidebarWidth` lays the divider
    /// out at this number and `persistedSidebarWidth` calls an observed position a drag precisely when it
    /// is NOT this number, so `layoutMaximum` reads `G_MAXINT` and any non-positive value alike as
    /// unbounded rather than collapsing the sidebar.
    ///
    /// IMPORTANT: both callers must pass the same ARGUMENTS, not merely call the same function. `minimum`
    /// is `AppController.sidebarEffectiveMinimum`, never the content floor — feeding them different
    /// minimums manufactures a phantom drag on every allocation.
    @MainActor
    static func laidOutSidebarWidth(requested: Double, minimum: Double, layoutMaximum: Double) -> Double {
        min(clampSidebarWidth(requested, minimum: minimum), layoutMaximum > 0 ? layoutMaximum : .infinity)
    }

    /// The width to PERSIST for an observed divider position, or `nil` when the LAYOUT produced that
    /// position rather than the user dragging to it. `requested` is the user's standing REQUEST, never
    /// the layout's answer to it; anything within a pixel of `laidOutSidebarWidth` is the layout's own
    /// answer, anything else is a drag and is persisted clamped. Both bounds must be the ones that
    /// function takes — see it for what `minimum` has to be.
    ///
    /// IMPORTANT: an effective minimum above `AppStore.sidebarWidthMax` persists NOTHING — the layout can
    /// honour no request there, so every position would read as a drag and the write-back would destroy
    /// the request permanently. The guard is `<=`, not `<`: AT the maximum the layout still has an answer.
    @MainActor
    static func persistedSidebarWidth(observed: Double, requested: Double, minimum: Double,
                                      layoutMaximum: Double) -> Double? {
        guard minimum <= AppStore.sidebarWidthMax else { return nil }
        let laidOut = laidOutSidebarWidth(requested: requested, minimum: minimum,
                                          layoutMaximum: layoutMaximum)
        guard abs(observed - laidOut) >= 1 else { return nil }
        return clampSidebarWidth(observed, minimum: minimum)
    }
}
