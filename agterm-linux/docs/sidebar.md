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
