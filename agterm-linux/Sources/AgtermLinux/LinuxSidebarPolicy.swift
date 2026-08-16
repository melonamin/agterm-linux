import Foundation
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

    /// Converts a drop's `y` coordinate WITHIN the target row into the insertion slot the shared
    /// `SidebarDrop` resolvers expect (mirroring macOS's workspace midpoint convention): the row's top
    /// half inserts BEFORE the target (`targetIndex`), the bottom half AFTER it (`targetIndex + 1`),
    /// with the exact midpoint counting as the bottom half.
    /// The GTK glue (reading the widget height, the drop `y`) stays in the controller; only the
    /// arithmetic lives here so it is table-testable.
    static func dropInsertionSlot(targetIndex: Int, y: Double, height: Double) -> Int {
        guard height > 0, y < height / 2 else { return targetIndex + 1 }
        return targetIndex
    }

    /// The full-array `childIndex` for a workspace drop aimed at the row at `targetVisibleIndex`
    /// among the RENDERED rows: the y-midpoint slot read in visible-row space, mapped onto the
    /// full array by `SidebarDrop.workspaceInsertIndex`. `handleWorkspaceDrop` and the policy
    /// tables both call this, so the shipped composition is exactly what the tables prove.
    static func workspaceDropChildIndex(targetVisibleIndex: Int, visibleIndices: [Int],
                                        y: Double, height: Double) -> Int {
        SidebarDrop.workspaceInsertIndex(
            visibleIndices: visibleIndices,
            slot: dropInsertionSlot(targetIndex: targetVisibleIndex, y: y, height: height))
    }

    /// Whether `id` is inside the CURRENT effective sidebar selection: the transient multi-selection
    /// when present, else the sole active session (an empty `selection` means no multi-select is in
    /// flight, so the active session is the whole selection).
    static func sessionIsInEffectiveSelection(_ id: UUID, selection: [UUID], activeID: UUID?) -> Bool {
        selection.isEmpty ? activeID == id : selection.contains(id)
    }

    /// The session block a drag carries: the whole transient multi-selection when the pressed row is
    /// inside it, else just that row. The Linux drag payload is the single pressed row's UUID
    /// (`onRowDragPrepare`), so EVERY session drop path — session row and workspace header alike —
    /// must apply this expansion, mirroring the macOS pasteboard writer's selected-block payload.
    static func draggedSessionBlock(source: UUID, selection: [UUID]) -> [UUID] {
        selection.contains(source) ? selection : [source]
    }

    /// The press/release timing state for session-row left clicks, host-free so full press-then-release
    /// SEQUENCES are table-testable (not just each phase in isolation).
    ///
    /// A plain press on an UNSELECTED row applies immediately (selection on mouse-down, as before);
    /// shift/ctrl presses also act on press. The ONE deliberate timing change: a plain press on a row
    /// ALREADY inside the current selection changes NOTHING at press time — the collapse-to-one runs on
    /// `released`, so a drag of a multi-selected block keeps its block (past the drag threshold the
    /// `GtkDragSource` claims the sequence, the click gesture is cancelled, `released` never fires, and
    /// the drop handler still reads the full selection; the NEXT press resets the pending state, so a
    /// cancelled release cannot leak into a later click).
    ///
    /// The press DECISION is remembered rather than re-derived at release time: `release` ignores live
    /// modifier state entirely, so a modifier key lifted (or pressed) between press and release can
    /// neither collapse a multi-selection the press itself just built nor swallow a deferred collapse.
    struct SessionClickTracker {
        private var pendingCollapseID: UUID?

        /// Returns `true` when the press should run the full selection logic NOW; `false` means the
        /// press deferred the collapse of `id` to the matching release.
        mutating func press(_ id: UUID, modified: Bool, alreadyInSelection: Bool) -> Bool {
            pendingCollapseID = nil
            guard !modified, alreadyInSelection else { return true }
            pendingCollapseID = id
            return false
        }

        /// Returns `true` when the release should collapse the selection to `id` — only when the
        /// matching press deferred on the SAME row, regardless of release-time modifiers.
        mutating func release(_ id: UUID) -> Bool {
            guard pendingCollapseID == id else { return false }
            pendingCollapseID = nil
            return true
        }
    }

    /// Row hover paint: sidebar rows are PASSIVE (non-activatable, `makeRow`), which strips GTK's
    /// `.activatable` class — the class libadwaita's `.navigation-sidebar > row.activatable:hover`
    /// rule keys on — so hover paint is restored here keyed on bare `:hover` (a pointer state,
    /// independent of activatable). Matches libadwaita's sidebar hover alpha. Under a terminal
    /// theme the display-wide provider at priority 650 (`applyWindowThemeColors`) still paints
    /// sidebar rows transparent, exactly as it did before rows went passive.
    /// Installed by `installAppCSS` (`App.swift`); the selector is string-pinned in `LinuxPolicyTests`.
    static let sidebarHoverCSS =
        ".agterm-sidebar .navigation-sidebar > row:hover { background-color: alpha(currentColor, 0.07); }"
}
