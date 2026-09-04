# Sidebar layout contracts

How the GTK sidebar's rows and column negotiate width.
Nothing auto-loads this document — read it before editing `AppController.swift` (`makeNameWidget`),
`AppControllerSidebar.swift` (`makeRow`), `LinuxStatusGlyph.swift` (`makeStatusGlyph`),
`LinuxThemePolicy.swift` (`windowThemeCSS`), or the sidebar scenarios in
`agterm-linux/tests/atspi_smoke.py`.

## Label sizing

- The contract is that any sidebar widget which can hold arbitrary-length USER text must be able to
  report a SMALL minimum width.
  A GTK4 `GtkLabel` with neither ellipsize nor wrap reports its WHOLE text as its minimum, and GTK never
  allocates below a minimum, so the row overflows the sidebar's `GtkScrolledWindow` — the name is cut
  mid-glyph with no `…` and the status glyph, flag star, and unseen badge are pushed past the viewport.
- It breaks EVERY row, not just the long-named one: the scroller's child is a vertical `GtkBox` whose
  minimum is the max over its children and which allocates its full width to each of them.
- The GTK row already reproduces the macOS layout — the name is the only `hexpand` child and the trailing
  glyphs hug — so only the truncation half was missing.
  Never reach for an `hexpand` change here.
- The treatment depends on the KIND of text, and getting that distinction wrong is the trap:
  - **User text ELLIPSIZES.**
    `gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_END)` on `makeNameWidget`'s plain-label branch
    (`AppController.swift`, which covers session rows AND workspace headers) and on `makeRow`'s
    flagged-view breadcrumb.
    `END`, not the `MIDDLE` that the palette rows use (`Palette.swift`): a palette title disambiguates at
    its TAIL ("Move Session to <workspace>") while a session or workspace name disambiguates at its HEAD,
    and `END` matches the macOS `.byTruncatingTail` on the very same names.
  - **Fixed instructional text WRAPS.**
    The flagged-empty hint takes `gtk_label_set_wrap` and never ellipsize, because truncating an
    instruction to `No flagged sessi…` is worse than the bug.
    Wrapping drops its minimum from its longest LINE to its longest WORD, which is all the sidebar needs.
    The default `PANGO_WRAP_WORD` is right (it never cuts mid-word) and `GTK_JUSTIFY_CENTER` still reads
    correctly once wrapped.
  - **Hugging trailing glyphs get NOTHING** — status glyph, flag star, unseen badge.
    The badge in particular must NOT be ellipsized even though it is a `GtkLabel` and so pattern-matches
    the sites that do need it: its natural width is part of the sidebar's chrome budget, and
    `PANGO_ELLIPSIZE_END` would collapse a `99+` badge to a bare `…`.
    The fixed `"Flagged"` section header needs nothing either; it can never be the constraint.
    In `LinuxStatusGlyph.swift`'s `makeStatusGlyph` the ABSENCE of a sizing call is the contract.
- In `makeRow`, label-only setters must be guarded on the FULL `flaggedView && renaming?.id != s.id`
  condition that CHOSE the plain label, hoisted into the `breadcrumb` binding so the two cannot drift.
  The weaker `if flaggedView` also reaches the `GtkEntry` that `makeNameWidget` returns during a rename,
  where a `GtkLabel` setter raises `assertion 'GTK_IS_LABEL (self)' failed`.
- No `gtk_label_set_width_chars` / `gtk_editable_set_width_chars` floor, deliberately.
  The rename `GtkEntry` does not need one: its minimum is a font-size-independent ~18px, because the
  `.agterm-sidebar label` CSS matches `label` nodes while an entry is an `entry` > `text` pair — and
  `gtk_editable_set_width_chars` RAISES that minimum monotonically, manufacturing a floor it does not have.
- The regression gate is the AT-SPI scenario `sidebar-narrow-clipping` in `agterm-linux/tests/atspi_smoke.py`,
  and it checks every site TWO ways, because a label that reports its whole text as its minimum has two
  possible symptoms depending on where the sidebar column's minimum comes from.
  CONTAINMENT (`sidebar_row_parts_fit`, which runs `sidebar_fits` over each visible part) asserts on the
  row PARTS — name label, status glyph, badge — rather than the row box, whose theme-dependent trailing
  inset it skips entirely; it catches the part overflowing a column that cannot grow to hold it.
  `sidebar_fits` itself checks one arbitrary box against the column, so the flagged-empty hint — which is
  no row — goes through it directly.
  NO GROWTH (`sidebar_does_not_widen`) asserts that the column never widened past a baseline captured while
  the row was fully decorated but still short-named; it catches the other symptom, a column that grew to
  follow the un-truncated content.
  Containment stops discriminating the moment the sidebar's own minimum follows its rows — every part then
  sits inside the widened column and every containment assertion passes vacuously — which is the whole
  reason the no-growth half is there, and why neither half may be dropped as redundant.
  The scenario seeds the LARGEST sidebar font on purpose: at the default font the flagged-empty hint's
  longest LINE already fits the narrowest column, so its wrap leg would prove nothing.

## Width floor

- The sidebar has exactly ONE width constraint: the floor `refreshSidebarWidthFloor` measures and pushes
  onto the paned START CHILD, pinned at `AppStore.sidebarWidthDefault` (220), capped at
  `AppStore.sidebarWidthMax`.
  It replaced two that disagreed — a hardcoded 240px `size_request` on the scroller and
  `AppStore.sidebarWidthMin` (160) on the start child — where the wider simply won and neither followed
  the font.
- **Never add a second `size_request` anywhere in the sidebar tree.**
  A second one silently wins wherever it is larger and is invisible to everything that reasons about the
  divider.
- Width-floor code also lives in hub files this document's intro does not name — read this section
  before touching
  `AppController.swift` (the scroller), `AppControllerSurfaces.swift` (`scheduleSidebarMetadataRefresh`),
  `App.swift` (the desktop-metric observers), or `Settings.swift` (`applyToolbarMode`).
- Measure, do not model: `refreshSidebarWidthFloor` measures `sidebarBox`, the widest sidebar site by
  construction, at the end of every `rebuildSidebar`, because the minimum depends on theme padding, the
  icon set, the resolved font, and the desktop text scale.
  It does not track `gtk-theme-name`, so a live theme switch leaves the floor stale until the next
  rebuild — deliberate, since rebuilds are frequent.
  Measured on GTK 4.22.4 a decorated row runs 181-255px across fonts and text scales, so the pin holds
  for ordinary configurations; those are the numbers `LinuxPolicyTests` feeds.
- One term is invisible to that measure and is added on top: the scroller's vertical scrollbar takes
  ~15px BESIDE the content whenever it is not an overlay indicator, i.e. whenever GTK's own
  `gtk-overlay-scrolling && GTK_OVERLAY_SCROLLING != "0"` is false
  (`gtk_scrolled_window_update_use_indicators`; the settings property alone misses the env-var case).
  `sidebarScrollbarOverhead` probes a THROWAWAY `GtkScrolledWindow`, because the live bar is CSS-animated
  across the flip and still reports the slim indicator width inside the notify handler.
  The reservation is UNCONDITIONAL and cached: gating it on the live bar would jitter the floor as the
  list crosses the scroll threshold, and the measure runs before fresh rows are allocated, so it would be
  wrong exactly when it matters.
  `App.swift`'s observer invalidates the cache before scheduling the rebuild.
- The floor lives ONLY on the widget, never mirrored on `AppController`.
  GTK4 folds a width request back into `gtk_widget_measure`, so `sidebarEffectiveMinimum` reads it back;
  a `max(mirror, measured)` on top can never bind and drifts the moment one side is updated alone.
- The content floor is NOT what GTK clamps the divider to — `sidebarEffectiveMinimum` is, folding in the
  header and the footer — so `applySidebarWidth` and `captureSidebarWidth` must pass THAT to
  `laidOutSidebarWidth`/`persistedSidebarWidth`; different minimums manufacture a phantom drag on every
  allocation.
  It returns nil with no start child, and both callers then do nothing.
  Never substitute a default there: a stand-in is a fine layout guess and a catastrophic capture one,
  because every position that is not exactly the stand-in reads as a drag and overwrites the request.
- `store.sidebarWidth` holds the user's REQUEST, never the layout's answer, which is what returns the
  sidebar to the asked-for width after a floor rises and falls, or a window narrows and widens.
  Only a position that is not the layout's own answer is persisted.
- The WIDENING leg arrives on `notify::max-position`; `notify::position` does not fire when a window gets
  wider, so without it the divider sits at the narrow window's cap until some unrelated rebuild.
  `applySidebarWidth` caps itself at `max-position` because it runs inside GtkPaned's own
  `size_allocate`, where an over-wide `set_position` is never re-clamped.
  `applyToolbarMode` moves the start child's minimum but NOT the content floor, so it calls
  `applySidebarWidth`, never `refreshSidebarWidthFloor`.
- The desktop-metric observers (`gtk-xft-dpi`, `gtk-font-name`, `gtk-overlay-scrolling`) re-measure
  through `scheduleSidebarMetadataRefresh`, never a direct `rebuildSidebar()`: that path coalesces the
  notify burst, honors `sidebarInteractionInProgress` and re-arms, so a live "Large Text" toggle cannot
  destroy an open context menu or an in-flight rename.
  Never arm the shared `softCloseReconcile` for this — its `arm()` supersedes the pending soft-close job.
- The gate is the AT-SPI scenario `sidebar-width-floor`, separate from `sidebar-narrow-clipping` because
  once the floor follows the rows plain containment passes vacuously.
  Five launches, none redundant: PIN (a competing `size_request`), MEASUREMENT (the floor became a
  constant), SCROLLBAR (driven with `GTK_OVERLAY_SCROLLING=0`, the GtkSettings half needing an XSETTINGS
  manager the Xvfb session lacks), WINDOW WIDTH (the `max-position` widening, plus the on-disk assertion
  that the narrow cap was not written over the saved request), and WIRING.
  The window-width leg reads its precondition off the toplevel FRAME's extents, never off the sidebar:
  inferring a declined resize from an uncapped sidebar conflates it with the regression the leg gates,
  which then prints SKIP and passes.
  The wiring leg gates only the minimum `captureSidebarWidth` passes — the `applySidebarWidth` side
  self-corrects in one hop — and needs all three of its levers, because every other launch hides the
  header, which leaves the content floor and the effective minimum equal.
  It seeds a 160px request, raises the header minimum to ~310px and the content floor to ~404px through a
  scoped user `gtk.css`, then switches to flagged mode so the floor falls back to the pin while the header
  holds 310: the one moment the two candidates disagree, and the only moment `notify::position` fires.
  Not covered: a MID-SESSION `applyToolbarMode` toggle, reachable from Preferences but from no control
  command.

## Drag-and-drop: no claiming click gesture on a drag-source row

- A row that carries a `GtkDragSource` must NEVER have a claiming click gesture.
  `gtk_gesture_set_state(…, GTK_EVENT_SEQUENCE_CLAIMED)` at press time cancels every other gesture on
  the sequence: the row's `GtkDragSource` (which must observe press-then-motion) never starts a drag,
  and the name label's bubble-phase double-click gesture never sees a press, so session double-click
  rename dies as collateral.
  The session-row click callbacks (`onSessionRowPress`/`onSessionRowRelease` in
  `AppControllerCallbacks.swift`) therefore never claim; the workspace header row is the precedent —
  a drag source plus a non-claiming click gesture.

## Selection: mode NONE, one paint path, one published accessible state

- The claim only existed to keep `GtkListBox`'s built-in selection from fighting the custom shift/ctrl
  logic, so the sidebar list boxes run `GTK_SELECTION_NONE` (`appendSection`) instead — nothing left to
  fight, no native `gtk_list_box_select_row`/`unselect_all` calls anywhere in the SIDEBAR code
  (the Palette/ControlPicker/ThemePicker list boxes keep theirs — different widgets).
- `setSidebarSelectionStyle` (`AppControllerSidebar.swift`) is the single selection choke point and
  owns BOTH selection surfaces.
  Paint: `syncSidebarSelection` mirrors the model into the `agterm-selected` CSS class, the ONLY
  selection visual (libadwaita suppresses `:selected` under `navigation-sidebar` anyway).
  The tint rule follows the exact row-content path from
  `.agterm-sidebar row.agterm-selected` to its direct `label` and `image` children
  (`ThemeColorResolver.windowThemeCSS`, whose CSS comment owns why; string-pinned in
  `GhosttyConfigThemeTests`). Only the row carries the class and paints the rounded background;
  tagging the content box too would cover that radius with a square fill. `makeRow` must keep every
  row label and symbolic icon a DIRECT child of the content box — a wrapper drops the tint silently.
  The `image` half is what keeps the leading
  terminal icon and the flagged star visible when a theme's selection background equals its
  foreground; the status glyph and badge keep their pango markup colors.
  The sibling rules stay descendant matches and keep cascading into row popovers —
  `.agterm-sidebar label`/`button` deliberately, since `popover_fg_color` is the same value, and
  `LinuxSidebarPolicy.sidebarCSS`'s font size incidentally.
  Accessibility: the same call publishes `GTK_ACCESSIBLE_STATE_SELECTED` on the ROW accessible
  (`publishRowAccessibleSelected`) — with native selection off, GTK publishes no selection state of
  its own, so screen readers only see what is set here.
  Because `GtkListBoxRow` resets that published state while GTK roots a rebuilt hierarchy,
  `rebuildSidebar` re-runs `syncSidebarSelectionStyles` on the next main-loop turn through
  `SelectionRepublishCoordinator` (re-armed by every rebuild, disarmed in `windowWillClose`).
- The state and CSS class go on the row ONLY, never its presentation-only child.
  The GValue must be built as `G_TYPE_INT` + `g_value_set_int`, never boolean: SELECTED is an
  undefined-able state, so GTK's GValue collector reads it with `g_value_get_int`, and a boolean
  GValue trips a GLib-GObject-CRITICAL and silently drops the update (observed on GTK 4.22).
  Verified over AT-SPI on GTK 4.22: the row's `STATE_SELECTED` follows this call — present on the
  selected row, absent after deselection — and the AT-SPI sidebar scenarios assert selection through
  it (`row_selected` in `agterm-linux/tests/atspi_smoke.py`).

## Rows are passive and non-focusable; hover keys on bare `:hover`

- All three calls in `makeRow` are load-bearing: `gtk_list_box_row_set_selectable(row, 0)` +
  `gtk_list_box_row_set_activatable(row, 0)` AND `gtk_widget_set_focusable(row, 0)`.
  With the claim gone the list box's own click gesture is live again, and even under
  `GTK_SELECTION_NONE` it would move keyboard focus to the clicked row on release — after
  `showActive()` grabbed the terminal on press — sending subsequent typing into the sidebar.
  The third is NOT redundant: `GtkListBoxRow` is focusable by default and the toplevel's
  click-to-focus still moved keyboard focus onto a merely-passive row — caught by the AT-SPI
  click-then-type leg, whose typing landed in the sidebar instead of the terminal.
  (`onRowActivated` stays dead code — never connect `row-activated` to the sidebar boxes;
  it would collapse the multi-selection on every click.)
- The trade-off is deliberate: non-focusable rows are never Tab/arrow focus targets, so sidebar
  navigation is keybinding/palette/control-driven (session next/prev, the palettes, `session go`),
  not row-focus-driven — and assistive tech still sees the selected row via the published
  `STATE_SELECTED` above.
- Row hover CSS must key on bare `:hover`, never `.activatable:hover`.
  Non-activatable rows lose the `.activatable` CSS class, and libadwaita keys sidebar row hover on
  `.navigation-sidebar > row.activatable:hover` — so passive rows silently lost hover paint.
  The replacement rule lives host-free as `LinuxSidebarPolicy.sidebarHoverCSS` — keyed on bare
  `:hover`, a pointer state independent of activatable — interpolated into `installAppCSS`
  (`App.swift`) and string-pinned in `LinuxPolicyTests`, including the NEGATIVE assertion that the
  selector never regains `.activatable`.

## Deferred collapse keeps a multi-select block draggable

- A plain press on an UNSELECTED row selects on mouse-DOWN (snappy) and shift/ctrl act on press,
  but a plain press on a row already inside the multi-selection defers its collapse-to-one to
  `"released"`: a drag past the threshold claims the sequence, the click gesture is cancelled,
  `released` never fires, and `handleSessionDrop` still reads the full `sidebarSelectionIDs` block.
  The timing state is the host-free, sequence-table-tested `LinuxSidebarPolicy.SessionClickTracker`:
  the press RECORDS a deferred collapse and the release CONSUMES it, ignoring release-time modifier
  state entirely — so a shift/ctrl key lifted before the mouse button cannot collapse the selection
  that same click just built, and the next press resets a pending collapse a cancelled release left
  behind.
  `alreadyInSelection` comes from `LinuxSidebarPolicy.sessionIsInEffectiveSelection` (the transient
  multi-selection when present, else the sole active session).
- A press or release on the row being INLINE-RENAMED is ignored: a caret click inside the rename
  entry must not run `showActive()`'s terminal `grab_focus`, which would fire the entry's
  focus-leave commit mid-edit.
  End-to-end coverage is the `sidebar-multiselect` AT-SPI scenario (shift-click block build,
  a mid-hold active-session probe pinning "deferred, not applied", and block drags onto a
  session row and a workspace header).
  A DEFERRED press still calls `noteUserActivity` — otherwise the idle auto-follow timer would
  replace `sidebarSelectionIDs` mid-hold, and a block drag would lose its block; that auto-follow
  interplay has no automated scenario (auto-follow's idle window defeats pointer-leg timing) and
  remains a known manual check.

## Y-midpoint drop slots feed the shared `SidebarDrop` math

- `onRowDrop`/`onHeaderDrop` convert the drop's `y` against the target row's height into a REAL
  insertion slot via `LinuxSidebarPolicy.dropInsertionSlot`: top half → before the target
  (`targetIndex`), bottom half (including the exact midpoint) → after (`targetIndex + 1`).
  The slot goes to the UNCHANGED host-free `SidebarDrop.resolveWorkspace`/`resolveSessions` as
  `childIndex` — the same between-rows convention macOS derives from `rect(ofRow:).midY`.
  A WORKSPACE slot is read in VISIBLE-row space (the sidebar renders `store.visibleWorkspaces`,
  under the focus filter a possibly non-contiguous subset) and mapped onto the full array by
  `SidebarDrop.workspaceInsertIndex` before `resolveWorkspace`, so the drop lands immediately
  adjacent to the aimed-at row instead of jumping across the hidden workspaces between rendered
  rows — the same mapping macOS's `resolveWorkspaceMove` applies.
  That slot→`childIndex` composition lives in `LinuxSidebarPolicy.workspaceDropChildIndex`,
  called by BOTH `handleWorkspaceDrop` and the policy tables, so the tables exercise the shipped
  composition rather than a re-derived mirror of it.
  Never pass a raw target index or `SidebarDrop.onItemIndex` where a slot is expected:
  raw-index made the last workspace slot unreachable (drag-to-last was a silent no-op),
  and `onItemIndex` made the first session slot unreachable.
  Dropping a session on a workspace HEADER keeps append semantics (`onItemIndex`, the one
  legitimate use) and carries the SAME selected block as a row drop: both paths expand the
  single-UUID drag payload through `LinuxSidebarPolicy.draggedSessionBlock`, matching the macOS
  pasteboard writer's whole-block payload — a header drop that moved only the pressed row would
  silently split a multi-selection.
- Slot + click-timing tables live in `LinuxPolicyTests`; the pointer-synthesized
  drag/rename/typing scenarios live in `agterm-linux/tests/atspi_smoke.py`.
