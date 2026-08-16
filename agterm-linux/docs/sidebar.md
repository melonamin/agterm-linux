# Sidebar layout contracts

How the GTK sidebar's rows and column negotiate width.
Nothing auto-loads this document — read it before editing `AppController.swift` (`makeNameWidget`),
`AppControllerSidebar.swift` (`makeRow`), `LinuxStatusGlyph.swift` (`makeStatusGlyph`), or the sidebar
scenarios in `agterm-linux/tests/atspi_smoke.py`.

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
