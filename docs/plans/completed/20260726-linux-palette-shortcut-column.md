# Fix: command-palette rows render the shortcut as inline title text (Linux port)

## Overview

- On macOS a palette row renders the action name left-aligned and its shortcut
  right-aligned in the dimmed secondary color. On the GTK port the row reads
  `Dashboard   ctrl+shift+m` — one left-aligned, same-colored run of text.
- Root cause: the shortcut is concatenated into the *title string* before the row exists
  (`Palette.swift:29-30`), and the row builder emits exactly one `GtkLabel`
  (`Palette.swift:209-215`). The port's item model is `[(String, () -> Void)]`
  (`AppController.swift:57-58`), so a secondary field can only be expressed by
  string-mangling the title. macOS carries a multi-field `PaletteItem` struct rendered as
  `HStack` + `Spacer` + `.foregroundStyle(.secondary)` (`agterm/Views/Palette.swift:6-43`,
  `215-251`).
- Fix: introduce a host-free `LinuxPaletteRow` presentation struct (title / shortcut /
  badge / search keys) plus pure builders, and make `filterPalette` a thin GTK composer
  that builds a horizontal box: title label (`hexpand`) + optional badge + shortcut label
  carrying Adwaita's `dim-label`. Matches the port's "logic host-free and tested, GTK code
  a thin side-effect adapter" convention.
- Scope decision (user, 2026-07-26): **shortcut column + custom-command parity**. Custom
  keymap commands stop appending `"  (custom)"` to their title and instead render a real
  trailing badge plus their own bound chord in the shortcut column, as macOS does
  (`agterm/AppActions+Palette.swift:123`, `131-140`). Session/attention rows keep their
  single-line `"name  —  workspace"` form — two-line rows and attention status glyphs are
  explicitly OUT of scope.
- `Chord.displayString` (kitty syntax, `agtermCore/.../Keybind.swift:53`) stays the Linux
  renderer. The `ctrl+shift+m`-vs-`⌘0` difference from macOS's `glyphString` (`:67`) is
  intentional and NOT part of this fix.
- Keep-in-sync verdicts (recorded so they are not relitigated):
  - **Control API: exempt.** This is palette row *rendering* — pure visual chrome with
    nothing to drive headless. No `Command` case, no `agtermctl` subcommand, no `tree`
    read-back field. Opening a palette is already interactive-only/exempt per
    `.claude/rules/menu-actions.md`.
  - **Settings ▸ Interface toggle: not proposed.** The shortcut column is not a new,
    hideable chrome affordance; it is the correct rendering of an element that already
    ships. No `InterfaceElement` case.
  - **Agent skill: already correct, no edit needed — and this change closes a gap.**
    `agterm/Resources/agent-skill/reference.md:697` already documents custom commands as
    "listed in the action palette marked `custom`", which is what the badge finally makes
    true on Linux.
  - **`site/commands.html` / `site/docs.html`: untouched** (no control command, keymap
    format, or model change). **`CHANGELOG.md`: untouched** (release-only).

## Context (from discovery)

Files involved:

- `agterm-linux/Sources/AgtermLinux/Palette.swift` (319 lines) —
  `paletteActionList()` lines 26-31 build the concatenated title
  (`let suffix = chord.map { "   \($0.displayString)" } ?? ""`); lines 33-42 append the
  Linux-only rows; line 64 appends `"  (custom)"`; `sessionPaletteList()`/
  `attentionPaletteList()` lines 141-153 build `"name  —  workspace"`; `filterPalette`
  lines 198-219 ranks via `fuzzyRank(query:items:keys: { [$0.0] })` (line 206) and renders
  one `gtk_label_new(item.0)` per `GtkListBoxRow` (lines 209-215).
- `agterm-linux/Sources/AgtermLinux/AppController.swift` — `paletteAll`/`paletteItems`
  declared as `[(String, () -> Void)]` (lines 57-58); `resolvedBuiltinChords:
  [Chord: BuiltinAction]` (line 145).
- `agterm-linux/Sources/AgtermLinux/App.swift` — `installAppCSS()` (lines 126-150) holds
  the app-wide CSS block at `GTK_STYLE_PROVIDER_PRIORITY_APPLICATION` (600); the badge
  rule goes here.
- `agterm-linux/tests/atspi_smoke.py` — **hard blocker if missed.** `collect()` matches
  accessible names **exactly** (`node_name == name`, line 38) and two places encode the
  concatenated text:
  - line 894: types `"New Session"` but asserts `named(palette, "New Session   ctrl+shift+t")`
    (deliberately different from the query, so only a row can satisfy it);
  - lines 1209 / 1227 / 1237 pass `"Launch Failure  (custom)"` / `"Exit Failure  (custom)"`
    / `"Slow Failure  (custom)"` to `run_palette_action` (line 478), which uses that ONE
    string both as the text typed into the search entry (line 493) and as the expected row
    name (line 495). The three commands it seeds (lines 1169-1174) are all **chordless**,
    so their rows will show a badge and no shortcut.
- `agterm-linux/Tests/AgtermLinuxTests/` — Swift Testing suites; new presentation tests
  follow `DashboardPresentationTests.swift` / `DeckPagePresentationTests.swift`.

Related patterns found:

- Composite-row precedent in-port: `AppControllerSessionPicker.swift:55-85` builds
  icon + `heading` title + `dim-label` subtitle (`:80`) inside `GtkBox`es, using
  `gtk_widget_set_hexpand` where SwiftUI would use `Spacer`.
- `dim-label` also used at `AppControllerSidebar.swift:79` and `Search.swift:28`.
- Host-free presentation types living in the Linux module and unit-tested:
  `DashboardPresentation.swift`, `SplitPaneLayout.swift`, `LinuxSidebarPolicy.swift`.
- `CustomCommand` (`agtermCore/Sources/agtermCore/CustomCommand.swift:9-24`) carries
  `name` + `shortcut` (empty string = palette-only).
- `ThemePicker.swift:57` keeps its own `[String]` row list and is unaffected.

**Fuzzy-ranking contract (drives a design decision below).** `fuzzyScore`
(`agtermCore/Sources/agtermCore/Fuzzy.swift:12-22`) splits the query on whitespace and
requires **every term to match the SAME key**; `fuzzyRank` (`:29-41`) takes the best (min)
score across an item's keys and tie-breaks alphabetically on `keys.first`. `termScore`
(`:47-59`) scores a prefix **0**, a substring `5 + offset`, a subsequence `40 + gap`. Two
consequences the naive "one key per field" split would hit:

- a query spanning two fields (`"custom launch"`, or the AT-SPI suite's literal
  `"Launch Failure  (custom)"`) matches **no** single key and the row disappears;
- `shortcut`/`badge` as standalone keys turn every short `c…` query into a **prefix**
  (score 0) against `ctrl+…`/`custom`, flattening the ranking so chord-bound rows tie with
  genuine title matches.

So `searchKeys` keeps a **composite** key next to the title (see Solution Overview), which
reproduces today's scores while making `keys.first` the clean title for the tie-break.

**Pre-existing issues surfaced by this work** (recorded; only the first is fixed here):

- `"Open Directory…"` is rendered **twice** today — once from the shared catalog
  (`PaletteCatalog.swift:38`, title at `:80`, always visible per the `default: return true`
  in `isVisible`) and once from the Linux-only append at `Palette.swift:33`. Harmless while
  both rows are bare text; after this change one gains `ctrl+shift+o` and the other stays
  bare, which reads as a bug this change caused. Task 2 drops the redundant append.
- `Preferences…`, `Manage Integrations…`, `Keyboard Shortcuts`, `About agterm`,
  `Copy Selection`, `Paste`, `Select All` have **no `BuiltinAction`**, so no chord resolves
  and their rows show no shortcut — even though Ctrl+, opens Preferences via a hardcoded
  keyval (`KeymapDispatch.swift:305`) and copy/paste ride libghostty binding actions. Out
  of scope; deliberately NOT hardcoding chord text into rows (see the next item for why).
- `AppController.swift:230` hardcodes the tooltip `"Toggle Sidebar (Ctrl+Shift+B)"` while
  the Linux default is `ctrl+shift+s` (`LinuxKeyboardPolicy.swift:21`) — already stale.
  macOS routes palette hints and toolbar tooltips through ONE resolver
  (`.claude/rules/menu-actions.md`); the Linux title bar does not. Out of scope, flagged.

Local toolchain (this box, per project memory):

```sh
export PATH="$HOME/.local/share/mise/installs/swift/6.3.2/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/share/swift-linux-compat"
cd agterm-linux && swift test      # and: swift build
```

`swiftlint` is not installed locally (CI installs it per-run in the separate lint job,
`.github/workflows/ci.yml:89-101`), and the AT-SPI harness needs `xvfb-run`, `xdotool`,
`openbox` — verified absent here via `which`, and `scripts/test-linux-ui.sh:16-21` hard-fails
on any missing dependency. Installing those three would let the suite run locally (it is
fully self-isolated: own `HOME`/XDG/`AGTERM_STATE_DIR`, `:30-42`); otherwise both gates land
in CI (`ci.yml:166-180`).

## Development Approach

- **testing approach**: Regular (code first, then tests, same task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task.
  The pure row model is covered by Swift Testing unit tests; the GTK composition is not
  unit-testable, so **its tests are the AT-SPI assertions**, updated in the same task that
  changes rendering. No task changes rendered text without touching `atspi_smoke.py`.
- **CRITICAL: all tests must pass before starting next task** — no exceptions, and each
  task must leave the AT-SPI suite logically green (the search keys, the rendered text, and
  the AT-SPI expectations move together, never across a task boundary)
- **CRITICAL: update this plan file when scope changes during implementation**
- run `swift test` after each change
- maintain backward compatibility: no control-protocol, persistence, or settings change;
  palette keyboard/mouse behavior (toggle, filter, ↑/↓, Enter, Esc, scroll clamp) untouched

## Testing Strategy

- **unit tests** (`agterm-linux/Tests/AgtermLinuxTests/`): the pure row model and builders —
  row composition, chord presence/absence, badge, the search-key set, and a **ranking**
  test proving a short `c` query still orders title matches above chord matches.
- **e2e tests**: the AT-SPI smoke suite (`agterm-linux/tests/atspi_smoke.py` via
  `scripts/test-linux-ui.sh`) is the only automated check of the visible fix. It gets
  **stronger**, not weaker: assert the title label AND the shortcut label AND (for custom
  rows) the badge label, each with `role="label"` — the suite's existing idiom
  (`atspi_smoke.py:509`). Asserting the shortcut/badge text is what pins the split, because
  those strings are never typed into the search entry.
- **Accessible-name contract** (decided here, documented in code):
  - A `GtkLabel` exposes its text as its AT-SPI name, so after the split a node named
    exactly `New Session` and one named exactly `ctrl+shift+t` both exist. No
    `gtk_accessible_update_property` is required for the assertions above.
  - The `GtkListBoxRow`'s own computed name will change (likely to empty) once its child is
    a multi-label box. **Nothing depends on it** — `actionable()` is never applied to
    palette rows and the `"command-palette"` widget id (`Palette.swift:179`) is unused by
    the Linux suite. Written down because it is the failure mode a future reader would
    suspect first.
  - Deliberately NOT doing: an explicit row-level `GTK_ACCESSIBLE_PROPERTY_LABEL`. Three
    sibling labels announce as three nodes under Orca, which is acceptable; if a single
    coherent row announcement is later wanted, that property on the row is the right fix
    (and would restore a stable row name) — a separate, deliberate change, not a fallback.
- **Visual acceptance**: isolated dev instance with a seeded keymap — see Post-Completion.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

Three layers, mirroring how macOS separates model from row rendering:

1. **`LinuxPaletteRow`** (new, host-free): `title`, `shortcut: String?`, `badge: String?`,
   plus `searchKeys: [String]` = `[title]` and — only when a shortcut or badge exists — a
   second **composite** key `[title, badge, shortcut].compactMap { $0 }.joined(separator: " ")`.
   `min`-over-keys then reproduces today's scores for both title and chord queries, keeps
   cross-field queries (`"custom launch"`) working, and leaves `keys.first == title` as the
   alphabetical tie-break.
2. **`LinuxPaletteRows`** (new, pure namespace): `action(title:chord:)`, `custom(_:)`,
   `plain(_:)`.
3. **`Palette.swift`** keeps ONLY GTK: `filterPalette` composes a horizontal `GtkBox` per
   row — title label (`xalign 0`, `hexpand 1`, ellipsize end) → optional badge label
   (`agterm-palette-badge`) → optional shortcut label (`dim-label`, `xalign 1`) — and
   passes `row.searchKeys` to `fuzzyRank`.

⚠️ **AS SHIPPED, this overview is stale in three places — see Tasks 6 and 7 for the why.**
Layer 1 is unchanged. The rest:

- the `LinuxPaletteRows` namespace does **not** exist: `action` and `custom` are static members
  of `extension LinuxPaletteRow`, and `plain(_:)` was deleted in favour of the
  `LinuxPaletteRow(title:)` initializer it merely forwarded to (Task 6);
- `action` takes the live palette context — `action(_ command: PaletteCommand, in context:
  PaletteContext, chord: Chord?)` — because two catalog titles flip with UI state (Task 7);
- `filterPalette` does **not** call `fuzzyRank` itself. It calls
  `paletteAll.filtered(query:)` on a new `LinuxPaletteList`, which owns the single ordering
  seam (Task 7). The row widget tree is otherwise as described, with
  `PANGO_ELLIPSIZE_MIDDLE` instead of `END` and no `xalign` on the chord label (Task 6).

Key design decisions and rationale:

- **Why a struct, not a wider tuple**: the mapping logic (chord → display string, badge
  assignment, search-key set) becomes unit-testable outside the `@MainActor` GTK code. A
  tuple leaves all of it inside untestable render code.
- **Why the composite search key**: see the fuzzy-ranking contract in Context. Splitting
  fields into standalone keys would break the AT-SPI suite's own query and silently reorder
  short-prefix results.
- **Why the badge is a CSS class**: GTK4/Adwaita has no generic pill class for labels, and
  `agterm-focus-pill` / `agterm-session-picker` are added in-tree with **no CSS rule
  anywhere**, so a real rule must be added to `installAppCSS()`. It follows
  `.agterm-dashboard-caption`'s shape (padding / border-radius / `alpha(@window_fg_color, …)`)
  so it tracks the desktop theme instead of hardcoding a color.
- **Why the title ellipsizes**: dynamic rows get long (`Delete Window: <name>`,
  `Move Session to <workspace>`); without ellipsize the title pushes the shortcut column
  out of the 480 px palette instead of truncating. `gtk_label_set_ellipsize` /
  `PANGO_ELLIPSIZE_END` are available — `Sources/CGtk/shim.h:3` includes
  `pango/pangocairo.h` (same path as `PANGO_ALIGN_CENTER` at `WatermarkRenderer.swift:42`).
- **Why custom rows change in their own task**: keeping `"  (custom)"` in the title through
  Task 2 keeps the three `run_palette_action` scenarios green on the unchanged query, so
  each task ends with a logically green suite and no throwaway transitional code.

## Technical Details

- `LinuxPaletteRow` (new file `agterm-linux/Sources/AgtermLinux/PalettePresentation.swift`):

  ```swift
  struct LinuxPaletteRow: Equatable {
      let title: String
      let shortcut: String?
      let badge: String?

      // computed, NOT stored: stays out of the memberwise init and Equatable synthesis
      var searchKeys: [String] { … }
  }
  ```

- `paletteAll` / `paletteItems` become `[(row: LinuxPaletteRow, run: () -> Void)]` (named
  tuple elements so `$0.row.title` reads clearly at the sort/rank sites).
  ⚠️ AS SHIPPED: that tuple is the `LinuxPaletteItem` typealias, `paletteItems` is
  `[LinuxPaletteItem]`, and `paletteAll` is a `LinuxPaletteList` (Task 7).
- Empty-query sort keys off `row.title.lowercased()`. Today it sorts the *concatenated*
  string, so same-prefix titles can reorder slightly — intended.
  ⚠️ AS SHIPPED: there is no separate empty-query sort at all. `fuzzyRank` scores every row
  `0` for an empty query and tie-breaks on the title, so it already **is** that sort — a
  second hand-rolled one only risked a different collation (Tasks 6 and 7).
- `fuzzyRank(query:items:keys: { $0.row.searchKeys })`.
  ⚠️ AS SHIPPED: called inside `LinuxPaletteList.filtered(query:)`, not at the GTK call site.
- Row widget tree per entry:
  `GtkListBoxRow > GtkBox(HORIZONTAL, spacing 8, margins 6/6/10/10)` containing
  `GtkLabel(title, xalign 0, hexpand 1, ellipsize END)`, optional
  `GtkLabel(badge, css: agterm-palette-badge)`, optional `GtkLabel(shortcut, css: dim-label,
  xalign 1)`.
- CSS added to `installAppCSS()`:
  `.agterm-palette-badge { font-size: 0.8em; padding: 1px 6px; border-radius: 6px;
  background-color: alpha(@window_fg_color, 0.14); }`
- Custom rows: title = `command.name`, badge = `"custom"`, shortcut =
  `command.shortcut.linuxTrimmedOrNil` (reuses the existing `LinuxStringPolicy` helper, so a
  whitespace-only keymap `shortcut` yields nil).

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): the Swift model + builders, the GTK row
  composition, the CSS rule, the AT-SPI expectation updates, unit tests, `swift test` /
  `swift build`.
- **Post-Completion** (no checkboxes): `swiftlint`, the AT-SPI smoke run, and the manual
  visual check in an isolated dev instance.

## Implementation Steps

⚠️ **Tasks 1-5 record the API as it stood when each task ran.** Two review passes renamed part
of it; the map from what these tasks say to what SHIPPED is:

| Tasks 1-5 name | As shipped | Where it changed |
| --- | --- | --- |
| `LinuxPaletteRows.action(title:chord:)` | `LinuxPaletteRow.action(_:in:chord:)` | Tasks 6, 7 |
| `LinuxPaletteRows.custom(_:)` | `LinuxPaletteRow.custom(_:)` | Task 6 |
| `LinuxPaletteRows.plain(_:)` | `LinuxPaletteRow(title:)` (deleted) | Task 6 |
| `LinuxPaletteRow.sortedByTitle(_:row:)` | deleted | Task 7 |
| `[(row: LinuxPaletteRow, run: () -> Void)]` | `LinuxPaletteItem` / `LinuxPaletteList` | Task 7 |
| `verify_palette_row_layout` | `check_palette_row_layout` | Task 7 |

### Task 1: Add the host-free palette row model and builders

**Files:**
- Create: `agterm-linux/Sources/AgtermLinux/PalettePresentation.swift`
- Create: `agterm-linux/Tests/AgtermLinuxTests/PalettePresentationTests.swift`

- [x] create `LinuxPaletteRow` (`title`, `shortcut: String?`, `badge: String?`, `Equatable`)
      with `searchKeys` as a **computed** property: `[title]`, plus the composite
      `[title, badge, shortcut].compactMap { $0 }.joined(separator: " ")` only when a
      shortcut or badge exists
- [x] add the pure `LinuxPaletteRows` builders: `action(title:chord:)` (nil chord → nil
      shortcut, else `chord.displayString`), `custom(_:)` (badge `"custom"`, shortcut from
      `command.shortcut.linuxTrimmedOrNil`), `plain(_:)` (title only)
- [x] document in a doc comment WHY the composite key exists (cite `fuzzyScore`'s
      every-term-one-key rule and `termScore`'s prefix-is-0), so nobody "simplifies" it to
      one key per field
- [x] write tests for `action` (chord → `ctrl+shift+t`; no chord → nil shortcut) and `plain`
- [x] write tests for `custom` (badge `custom`; bound chord surfaces as shortcut; empty and
      whitespace-only `CustomCommand.shortcut` → nil)
- [x] write tests for `searchKeys`: bare row → `[title]` only; chorded row → title +
      composite; badged row → title + composite; both → composite contains title, badge,
      shortcut in that order
- [x] write a **ranking** test over `fuzzyRank` with the real row set: query `"c"` keeps
      `Clear Status` / `Copy Selection` (title prefix) ahead of `Dashboard`
      (chord-only match), and query `"custom launch"` still finds a badged custom row
- [x] run `swift test` — must pass before task 2
      (⚠️ one PRE-EXISTING unrelated failure on this box: `IntegrationServiceTests`
      "Flatpak process environments do not offer a host launcher" — reproduced with the new
      files removed, so it is not caused by this task. All 12 new tests pass.)
- ➕ [x] added a third ranking case (`ctrl+shift+m` finds `Dashboard`) — the composite key's
      other half; without it nothing pins find-by-chord at the model layer.

### Task 2: Route the palette through the row model and render the shortcut column

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/AppController.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/Palette.swift`
- Modify: `agterm-linux/tests/atspi_smoke.py`

- [x] change `paletteAll`/`paletteItems` (`AppController.swift:57-58`) to
      `[(row: LinuxPaletteRow, run: () -> Void)]`
- [x] rebuild `paletteActionList()`: catalog commands via
      `LinuxPaletteRows.action(title:chord:)`; `.plain(_:)` for the Linux-only rows
      (`Preferences…`, `Manage Integrations…`, `Keyboard Shortcuts`, `About agterm`,
      `Copy Selection`, `Paste`, `Select All`) and the dynamic rows (window switch/rename/
      delete, move-session, workspace focus)
- [x] drop the redundant `"Open Directory…"` append (`Palette.swift:33`) — the shared
      catalog already emits it, and after this change the duplicate rows would differ
      visibly (one chorded, one bare)
- [x] keep custom commands on `.plain(cmd.name + "  (custom)")` for now, so the three
      `run_palette_action` scenarios stay green until Task 3 changes them deliberately
- [x] convert `sessionPaletteList()`/`attentionPaletteList()` to `.plain(_:)`, keeping the
      `"name  —  workspace"` text verbatim (out of scope to change)
- [x] replace the single-label row in `filterPalette` with a horizontal `GtkBox` (spacing 8,
      the existing 6/6 vertical + 10 start margins moved onto the box, plus a 10 end margin)
      hosting the title label (`xalign 0`, `hexpand 1`, ellipsize end), and append the
      shortcut label (`dim-label`, `xalign 1`) when `row.shortcut != nil`
- [x] point the empty-query sort at `row.title.lowercased()` and `fuzzyRank`'s `keys:` at
      `$0.row.searchKeys`; keep `runPaletteIndex` on `.run`
- [x] add a comment in `filterPalette` recording the accessible-name contract (title and
      shortcut are separate label nodes; the row's own name goes empty and nothing depends
      on it) so a future refactor does not re-merge the labels
- [x] update `atspi_smoke.py:894` to assert BOTH `named(palette, "New Session", role="label")`
      and `named(palette, "ctrl+shift+t", role="label")` — the shortcut label is never typed,
      so this is what pins the split end-to-end
- [x] run `swift test` and `swift build` — must pass before task 3
      (`swift build` clean; `swift test` = 130 tests, only the known PRE-EXISTING
      `IntegrationServiceTests` "Flatpak process environments do not offer a host launcher"
      failure, unrelated to this branch)
- ➕ [x] `[deviation]` the builders are called as `LinuxPaletteRows.plain(…)` /
      `LinuxPaletteRows.action(…)`, not the plan's leading-dot `.plain(_:)`: the builders live
      on the `LinuxPaletteRows` namespace enum (Task 1), not on `LinuxPaletteRow`, so
      leading-dot member lookup does not resolve against the tuple's `LinuxPaletteRow` type.
      Spelling them out keeps the Task 1 API unchanged; no behavior difference.

### Task 3: Custom-command rows get a real badge + their own chord

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/Palette.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/App.swift`
- Modify: `agterm-linux/tests/atspi_smoke.py`

- [x] switch custom keymap commands to `LinuxPaletteRows.custom(_:)`, dropping the
      `"  (custom)"` title suffix
- [x] append the badge label between title and shortcut when `row.badge != nil`, with the
      `agterm-palette-badge` CSS class
- [x] add the `.agterm-palette-badge` rule to `installAppCSS()` (`App.swift:126-150`),
      themed via `alpha(@window_fg_color, …)` like `.agterm-dashboard-caption`
- [x] update the three `run_palette_action` call sites (`atspi_smoke.py:1209`, `1227`,
      `1237`) to the plain names (`"Launch Failure"`, `"Exit Failure"`, `"Slow Failure"`) —
      required, not cosmetic: the old query `"Launch Failure  (custom)"` spans two fields
      and `fuzzyScore` would drop the row entirely
      (actual lines after Task 2: 1215 / 1233 / 1243)
- [x] add a badge assertion in the custom-command scenario:
      `named(palette, "custom", role="label")` (its three seeded commands are chordless, so
      they render title + badge and no shortcut)
- [x] leave `run_palette_action`'s signature alone — with the suffix gone, the typed query
      and the expected row name are the same string again, so no extra parameter is needed
- [x] run `swift test` and `swift build` — must pass before task 4
      (`swift build` clean; `swift test` = 130 tests, only the known PRE-EXISTING
      `IntegrationServiceTests` "Flatpak process environments do not offer a host launcher"
      failure)
- ➕ [x] `[decision]` the badge assertion went INSIDE `run_palette_action`'s existing
      `wait_for` rather than a separate palette open/close cycle: all three call sites are
      custom commands (the helper's own error text already says "custom-command window"), so
      every invocation now pins the badge with no extra keystroke round-trip.
- ➕ [x] `[decision]` tightened the helper's title assertion to `role="label"`, matching the
      Task 2 idiom at `atspi_smoke.py:897` — the row's own accessible name is now empty, so
      only the title label can satisfy it and the assertion says so explicitly.
- ➕ [x] `[decision]` no new Swift unit tests in this task: `LinuxPaletteRows.custom(_:)` is
      already covered by the Task 1 suite (badge, bound chord, empty/whitespace shortcut →
      nil), and everything Task 3 adds is GTK composition + CSS, whose tests are the AT-SPI
      assertions per the Development Approach.

### Task 4: Verify acceptance criteria

⚠️ **No GUI on this box and no human reviewer.** `xvfb-run` / `xdotool` / `openbox` are absent
and `scripts/test-linux-ui.sh:16-21` hard-fails on any missing dependency, so the AT-SPI suite
could NOT be executed here. Every rendering criterion below was discharged by **code inspection
+ host-free unit tests + the AT-SPI assertions as written in source**; each is annotated with
how, and what is left as a CI-only gate. Nothing below claims an observed GUI.

⚠️ The API names and `file:line` citations in this task are **as of Task 4** and were
superseded by the two review-fix passes below: `LinuxPaletteRows.custom(_:)` is now
`LinuxPaletteRow.custom(_:)`, `LinuxPaletteRows.action(title:chord:)` is now
`LinuxPaletteRow.action(_:in:chord:)`, and every line number has moved. Each criterion still
holds — only the spelling of what discharges it changed. Read Tasks 6 and 7 for the current
shape.

- [x] verify a bound catalog command renders title + right-aligned dim chord, and an
      unbound one renders title only
      — CODE: `Palette.swift:27-31` fills `shortcut` from the resolved chord only when one
      resolves; `:218-223` gives the title `xalign 0` + `hexpand 1` (the `Spacer` equivalent,
      so the box's spare width goes to the title and the chord sits flush right) and `:231-235`
      appends the chord label with Adwaita's `dim-label` ONLY when `row.shortcut != nil` —
      an unbound row emits one label. `dim-label` is the in-port idiom
      (`AppControllerSidebar.swift:79`, `AppControllerSessionPicker.swift:80`, `Search.swift:28`).
      TESTS: `PalettePresentationTests` "a bound catalog command carries its chord…" /
      "an unbound catalog command has no shortcut".
      AT-SPI (CI-only): `atspi_smoke.py:903-907` asserts `named(palette, "New Session", role="label")`
      AND `named(palette, "ctrl+shift+t", role="label")`.
- [x] verify a custom command renders title + `custom` badge + its own chord, and a
      chordless custom command renders title + badge only
      — CODE: `Palette.swift:62-65` → `LinuxPaletteRows.custom`, whose title is the bare
      `command.name` (no `"  (custom)"` anywhere in the tree) and whose shortcut is
      `command.shortcut.linuxTrimmedOrNil`; `Palette.swift:227-230` emits the badge label with
      `agterm-palette-badge` only when `row.badge != nil`, positioned between title and chord.
      The CSS rule is live at `App.swift:143-144`. `loadKeymapCommands()`
      (`AppControllerSurfaces.swift:212-215`) returns the parsed `CustomCommand`s with their
      `shortcut` intact, so a chorded keymap command really does reach the row.
      TESTS: "a custom command is badged and shows its own chord" / "a palette-only custom
      command is badged with no shortcut" (empty AND whitespace-only shortcut → nil).
      AT-SPI (CI-only): `run_palette_action` (`:498-502`) now asserts `named(palette, "custom",
      role="label")` on all three seeded (chordless) commands. The CHORDED custom row stays
      unit-covered only — the suite seeds no bound custom command.
- [x] verify search: find-by-chord still filters, `custom` still filters custom commands,
      `"custom launch"`-style cross-field queries still match, and a short `c` query still
      ranks title matches first (the Task 1 ranking test)
      — TESTS (all four, over the real `fuzzyRank` seam): "a chord query still finds its
      command" (`ctrl+shift+m` → `Dashboard`), ➕ "the bare badge word still filters to the
      custom rows" (`custom` → only the badged row), "a cross-field query still finds a badged
      custom row" (`custom launch`), "a short query ranks title matches above chord-only
      matches" (`c` → `Clear Status`, `Copy Selection`, … `Dashboard` last).
      CODE: `Palette.swift:207` passes `$0.row.searchKeys` to `fuzzyRank`, so the tested keys
      are the shipped keys.
- [x] verify `Open Directory…` now appears exactly once, with `ctrl+shift+o`
      — CODE: the Linux-only `items.append(("Open Directory…", …))` is gone (`git show
      3d8f1cf:…/Palette.swift` had it at `:33`); a tree-wide grep finds the string in the Linux
      palette path ONLY via the shared catalog (`PaletteCatalog.swift:80`), wired once at
      `Palette.swift:86` to `.openDirectory`, which `isVisible` admits through its
      `default: return true` (`PaletteCatalog.swift:67-68`). The chord is the Linux default
      `ctrl+shift+o` (`LinuxKeyboardPolicy.swift:15`), rendered through the same
      `resolvedBuiltinChords` lookup the `New Session` AT-SPI assertion pins.
- [x] verify long dynamic titles (`Delete Window: <long name>`) ellipsize instead of pushing
      the shortcut column out of the 480 px palette
      — CODE: `Palette.swift:223` sets `PANGO_ELLIPSIZE_END` on the title label (compiles in
      Debug AND release/WMO). GTK box layout gives every child its MINIMUM first and hands the
      surplus to the `hexpand` child: an ellipsizing label's minimum width collapses to about
      the ellipsis, while the non-ellipsizing chord label's minimum equals its natural width,
      so the title is what truncates. The window keeps its 480 px
      `gtk_window_set_default_size` (`:167`) because the list lives in a `GtkScrolledWindow`
      (`:175-181`), which does not propagate its child's natural width.
      Pixel-level confirmation is a manual/CI-visual gate, not reproducible headless.
- [x] verify session/attention rows are unchanged (`"name  —  workspace"`, single line)
      — CODE: `Palette.swift:141-153` builds `LinuxPaletteRows.plain("\(s.displayName)  —  \(ws)")`;
      diffed against `3d8f1cf` the interpolated string is byte-identical, and `plain(_:)` leaves
      `shortcut`/`badge` nil, so the row still renders exactly one label.
      ⚠️ **"Unchanged" was overstated and is now wrong in two ways.** The TEXT is still verbatim,
      but these rows do now ellipsize (middle) and carry the box's 10px end margin like every
      other row — flagged as informational in review round 1, no code change. And the ATTENTION
      palette's row ORDER changed in Task 7 (see Scope expansion 1). The two builders were also
      collapsed into `sessionRows(_:)`, so the cited lines no longer exist as written.
- [x] run the full host-free suites: `cd agterm-linux && swift test` and
      `cd agtermCore && swift test`
      — `agterm-linux`: 131 tests / 17 suites, ONE failure, the known PRE-EXISTING
      `IntegrationServiceTests` "Flatpak process environments do not offer a host launcher".
      `agtermCore`: 1733 tests / 74 suites, ONE failure, `CodexStatusHookTests`
      "stopReportsBlockedWhenAssistantMessageEndsInQuestionMark" — ⚠️ a SECOND pre-existing
      environmental failure (bash agent-status hook), proven unrelated: this branch changes
      ZERO files under `agtermCore/` or `agterm/` (`git diff 3d8f1cf..HEAD --name-only --
      agtermCore agterm` is empty, working tree clean there), so it fails identically at the
      branch base. Not chased.
- [x] run `swift build` and `swift build -c release` (release/WMO is a separate CI gate)
      — both clean, no warnings from the touched files.
- [x] run `git diff --check` (CI's "Reject whitespace errors" step, `ci.yml:105`) and
      eyeball the 200-column `line_length` limit on the touched files, since swiftlint
      cannot run locally
      — `git diff --check` clean for both the working tree and `3d8f1cf..HEAD`. Longest ADDED
      line across the whole diff is 143 cols; per-file maxima 107 (`PalettePresentation.swift`),
      165 (`Palette.swift`, pre-existing), 104 (the test file). `Palette.swift` is 341 lines
      (limit 1000), the new source file 67, the test file 129. Tuple arity stays 2, under the
      `large_tuple: 3` warning. swiftlint itself remains a CI-only gate (not installed here).
- [x] grep the tree for leftover concatenated palette strings (`"   ctrl+"`, `"  (custom)"`)
      outside `docs/plans/`
      — no leftovers in any code path. The only non-plan hits are (a) two DELIBERATE
      explanatory comments naming the old form (`PalettePresentation.swift:9`,
      `Palette.swift:61`) and (b) unrelated `keymap.conf` starter examples using the `ctrl+a>g`
      chord (`README.md:635`, `ConfigPaths.swift:66`, its test, `site/docs.html`).
- ➕ [x] `[decision]` added ONE new unit test, "the bare badge word still filters to the custom
      rows". Task 4 is a verification task, but with no GUI available the "`custom` still
      filters custom commands" criterion had no executable evidence — the Task 1 suite only
      covered the two-term `"custom launch"` query. Six lines over the existing `sampleRows`
      turn a reasoned claim into a run one; suite is now 13 tests.
- ➕ [x] `[decision]` the AT-SPI smoke run and swiftlint stay UNRUN and are recorded as CI-only
      gates rather than marked verified: the three X11 dependencies are absent and installing
      them is a system-level change no one is here to approve.

### Task 5: [Final] Update documentation

- [x] record the README verdict: the row layout is not documented, so no change is needed —
      but note that `README.md:405` describes a "custom-commands palette (Ctrl-Shift-O)"
      that does not exist on Linux (`customCommandPalette` is deliberately keyless,
      `LinuxKeyboardPolicy.swift:26-28`, and Ctrl+Shift+O is Open Directory). Flag it; fix
      only if the user wants it in this change
      — **VERDICT: no README change needed for THIS fix.** The palette *row layout* (title /
      badge / shortcut column) is documented nowhere in `README.md`, so the shipped prose is
      still accurate after the change; the one line that mentions custom commands in the
      palette (`README.md:405`) describes the *list*, not the row rendering.
      **FLAGGED, NOT FIXED — needs a user decision.** `README.md:405` reads "the
      **custom-commands palette** (Ctrl-Shift-O) lists the shell commands you define in
      `keymap.conf`". Verified stale for Linux: `LinuxKeyboardPolicy.swift:28` returns `nil`
      for `.customCommandPalette` (deliberately keyless) and `:15` binds Ctrl+Shift+O to
      `.openDirectory`, so on Linux that sentence names a shortcut that opens a different
      thing. The line sits in the SHARED "Keyboard and navigation" section that also documents
      macOS, where Ctrl-Shift-O is correct — so fixing it means deciding how the shared README
      splits platform-specific chords, which is a documentation-policy call beyond this
      rendering fix's scope. The change was NOT made: no human was available to approve it and
      the checkbox is explicitly gated on user preference.
- ➕ [x] `[decision]` **REVISED IN THE REVIEW-FIX PASS: the README note WAS added.** The deferral
      premise did not hold — the fork's README already carries inline `On Linux, …` notes for exactly
      this situation (`README.md:53`, `:185`, `:412`, `:437`), so it is a one-sentence edit in an
      established style, not a documentation-policy call. `README.md:406` now records that Linux has
      no separate custom-commands palette, that Ctrl-Shift-O is Open Directory there, and that keymap
      commands appear in the Ctrl-Shift-P action palette tagged `custom` with their own chord — which
      is precisely what this branch makes true.
- ➕ [x] ⚠️ **The Task 5 grep claim above was WRONG and is corrected here.** `site/docs.html` DOES
      carry the same entry (`⌃⇧O` at `:856` → "Custom-commands palette — your keymap.conf commands"
      at `:866`). It is deliberately NOT edited: that whole Navigation table is verbatim upstream
      macOS notation on the Linux-branded page (`⌥⌘↑↓` for prev/next session, `⌘⇧D` for the dashboard,
      "its own on-screen macOS window", "Settings (⌘,) has six tabs"), so correcting one row would
      leave the neighbouring rows equally wrong and read as inconsistent. That page-wide divergence is
      pre-existing and far larger than this branch.
- [x] confirm the agent-skill verdict in the Overview (reference.md:697 already says
      "marked `custom`" — this change makes Linux match the shipped doc)
      — **CONFIRMED, no edit needed.** `agterm/Resources/agent-skill/reference.md` still reads
      `command "<name>" [chord] <shell...>` — define a custom shell command, listed in the
      action palette marked `custom`". Linux now renders that `custom` marker as a real badge
      instead of a `"  (custom)"` title suffix, so the skill doc goes from aspirational to
      accurate without changing a word. No command/arg/return, keymap-format, or
      window/workspace/session/pane model change in this branch, so no other agent-skill file
      (SKILL.md, examples.md, troubleshooting.md, scripts, command count) is affected.
- [x] add a Linux-palette note to `AGENTS.md` or a `.claude/rules/` file **only if the user
      wants one** — no rule file currently owns the Linux palette (`.claude/rules/menu-actions.md`
      is macOS-path-scoped); otherwise the contract lives in the Task 2 code comment
      — **NOT ADDED — needs a user decision** (the checkbox is explicitly gated on "only if the
      user wants one" and no human was available to ask). Verified the premise: none of the 13
      `.claude/rules/*.md` files scopes to `agterm-linux/`, and `menu-actions.md`'s `paths:`
      frontmatter lists only `agterm/AppActions*.swift`, `agterm/agtermApp*.swift`,
      `agterm/Views/{Palette,PaneShortcuts,SessionSwitcher}.swift`, and
      `agtermCore/.../RecencyStack.swift` — all macOS-target paths, so it never auto-loads for
      Linux palette work. The fallback named in the plan is in place and sufficient: the
      accessible-name contract, the composite-search-key rationale, and the ellipsize rationale
      are all recorded as code comments in `Palette.swift`'s `filterPalette` and in
      `PalettePresentation.swift`'s doc comment, so the invariants a future refactor would
      break are documented where they are edited. Creating a new rule file is a repo-convention
      decision (a new path-scoped rule also owes an index entry in `CLAUDE.md`), so it is left
      to the user.
- ➕ [x] `[decision]` **REVIEW-FIX PASS: still NOT added, decided deliberately rather than deferred.**
      Two options existed and both cost more than they return.
      A NEW `.claude/rules/linux-palette.md` owes an index entry in `CLAUDE.md`'s rule list, i.e. a
      repo-convention change, and would be the only rule in the tree scoped to `agterm-linux/` — a
      one-palette rule is the wrong first instance of that convention.
      EXTENDING the inherited `menu-actions.md` with Linux globs puts fork-only content into an
      upstream-tracked file, which `AGENTS.md` explicitly argues against ("Keep Linux-specific code
      isolated to the Linux UI", "Preserve a small, reviewable downstream delta from upstream").
      The plan-sanctioned fallback stands and is the better home anyway: the composite-search-key
      rationale is the `searchKeys` doc comment, the accessible-name contract and the ellipsize
      rationale are comments inside `filterPalette` — i.e. each invariant is written exactly where a
      refactor would break it, not in a file that only loads if someone remembers to open it.
- [x] re-confirm the keep-in-sync verdicts still hold at merge time (no control command, no
      Interface toggle, no site change)
      — **ALL FOUR HOLD.** `git diff 3d8f1cf..HEAD --name-only` is exactly: `App.swift`,
      `AppController.swift`, `Palette.swift`, `PalettePresentation.swift`,
      `PalettePresentationTests.swift`, `atspi_smoke.py` (all under `agterm-linux/`) plus this
      plan file. So: no `Command` case / `ControlServer` arm / `agtermctl` subcommand / `tree`
      field (control API exempt — palette row rendering has nothing to drive headless); no
      `InterfaceElement` case (the shortcut column is the correct rendering of shipped chrome,
      not a new hideable affordance); `site/commands.html` and `site/docs.html` untouched (no
      control command, keymap format, or model change); `CHANGELOG.md` untouched (release-only
      per `CLAUDE.md`); and `agtermCore/` + `agterm/` are byte-untouched, so the macOS target
      and the shared core cannot have drifted.
- [x] move this plan to `docs/plans/completed/`
      — NOT done here by design: the move is the orchestrator's final step at the end of the
      run, after the review phases. Left in `docs/plans/` intentionally.

### Task 6: ➕ Review-fix pass (code review, iteration 1)

Fixes applied after the five-reviewer pass; each deviates from a Technical Detail above and says why.

- [x] **Duplicate row, same class as `Open Directory…`:** dropped the Linux-only
      `Clear Workspace Focus` append (`Palette.swift:66-68`). The shared catalog already emits
      `Clear Focus` (`PaletteCatalog.swift` title `:116`, `isVisible` gated on `hasFocusedWorkspace`
      `:57-58`) running the same `focusWorkspace(nil)`. Task 2's audit missed it because both rows are
      chordless, so the duplication never became visually inconsistent.
- [x] **Badge pill stretched to the full row height:** a `GtkBox` child defaults to `GTK_ALIGN_FILL`,
      so the CSS background covered the whole allocation instead of the label's natural height. Added
      `gtk_widget_set_valign(W(pill), GTK_ALIGN_CENTER)`, the port's own convention for a styled box
      child (`AppControllerDashboard.swift:216`).
- [x] **Badge text now dimmed** (`App.swift`): added `color: alpha(@window_fg_color, 0.7)` to
      `.agterm-palette-badge`. macOS renders the badge `.foregroundStyle(.secondary)` inside its
      capsule; without this the pill read heavier than both the macOS badge and the chord beside it.
- [x] **`PANGO_ELLIPSIZE_END` → `PANGO_ELLIPSIZE_MIDDLE`** (deviates from Technical Details).
      `filterPalette` is shared, so END also applied to `sessionPaletteList()`/`attentionPaletteList()`
      rows (`"<name>  —  <workspace>"`) and truncated the WORKSPACE — the only disambiguator between
      two same-named sessions (macOS middle-truncates that field, `agterm/Views/Palette.swift:222`).
      Every long Linux palette title has the same shape (`Delete Window: <name>`,
      `Move Session to <workspace>`), so END always ate the distinguishing tail; MIDDLE keeps both ends
      and still prevents the title pushing the shortcut column out of the 480px palette.
- [x] **Dead `gtk_label_set_xalign(chord, 1)` removed** (deviates from Technical Details). The chord
      label is not `hexpand`, and a `GtkBox` gives surplus width only to expanding children, so it was
      allocated exactly its natural width and had nothing to align within. The right-alignment comes
      from the title's `hexpand`; the comment now says so.
- [x] **`LinuxPaletteRows` namespace deleted** (erases the Task 2 `[deviation]`). `plain(_:)` was a
      verbatim forwarder to an initializer that already defaults both fields, at 15 of 17 call sites.
      `action(title:chord:)` and `custom(_:)` moved onto `extension LinuxPaletteRow`; plain rows now
      call `LinuxPaletteRow(title:)` directly. One fewer type, one fewer API entry point.
- [x] **Render loop can no longer desync row indices from `paletteItems`.** `runPaletteIndex` maps a
      `GtkListBoxRow`'s index straight into `paletteItems`, but the loop's
      `guard let row … else { continue }` skipped the widget while leaving the item in the list, so one
      skip would run the WRONG action for every later row. `filterPalette` now ranks into a local
      `ranked`, appends only successfully built rows to `rendered`, and assigns `paletteItems` after —
      the one-to-one invariant is structural instead of assumed.
- [x] **Empty-query order hoisted host-free and aligned with the ranked order.** It sorted on
      `title.lowercased() <` while `fuzzyRank` tie-breaks on `localizedCaseInsensitiveCompare`
      (`Fuzzy.swift:39`) — two collations for one list, neither testable inside `@MainActor` GTK code.
      Now `LinuxPaletteRow.sortedByTitle(_:row:)` in `PalettePresentation.swift`, unit-tested against
      `fuzzyRank`'s own empty-query output.
      ⚠️ **SUPERSEDED — `sortedByTitle` does NOT ship.** Task 7 deleted it: aligning it with
      `fuzzyRank`'s collation made it a re-implementation of `fuzzyRank(query: "")`, so the empty
      query now goes through the same seam as every other query. The test that covered it became
      `emptyQueryListsAlphabetically`.
- [x] **Vestigial `let command = cmd`** removed from the custom-command loop (`for` bindings are
      already per-iteration immutable).
- [x] **Tests, net +1 with the redundancy removed:** the four near-duplicate `searchKeys` cases
      collapsed into one, `plainRow` (which only asserted the compiler's own nil defaults) dropped, and
      the doubled field assertions in `actionWithoutChord` folded into the whole-row `==`. Added: raw
      shortcut passthrough (`Ctrl+Shift+E`, `ctrl+a>g` — `parseCommandLine` stores `firstToken`
      verbatim, so the old `ctrl+shift+e` case could not tell a normalizing implementation apart);
      ranking over the REAL `PaletteCommand.allCases` catalog (`custom`, `ctrl+shift+m`,
      `ctrl+shift+o` each still resolve to exactly one row, which a 4-row sample cannot see); and
      `sortedByTitle`.
- [x] **`LinuxKeymapTests` gained the keymap→row leg** the AT-SPI addition rests on: a chorded
      `command "Chorded Demo" ctrl+shift+e true` survives `loadLinuxKeymap`'s Linux re-validation with
      no diagnostic and reaches `LinuxPaletteRow.custom` as `Chorded Demo | custom | ctrl+shift+e`.
      Written because the GUI gate cannot run on this box.
- [x] **AT-SPI suite:** `run_palette_action` took the hardcoded `named(palette, "custom")` as a
      `badge="custom"` parameter (assert only when truthy, and the failure text now names the badge);
      the shared open-and-focus preamble moved to `open_palette`; new `palette_row_labels(palette)`
      returns each row's label names IN ORDER, so the assertions can finally see label order and row
      ownership instead of searching the whole subtree. New `verify_palette_row_layout` seeds a fourth,
      CHORDED custom command and pins `["Chorded Demo", "custom", "ctrl+shift+e"]` — the three-label
      arrangement this change introduces had zero coverage in any layer — then pins the `Open
      Directory…` de-duplication (exactly one row, with `ctrl+shift+o`), which nothing asserted either.
      The background-palette check now compares one row's labels in order too.
      ⚠️ **RENAMED in Task 7: the helper ships as `check_palette_row_layout`** (`atspi_smoke.py:532`).
      `verify_*` is the suite's convention for a top-level scenario `main()` dispatches by name; this
      one is a check called from inside another scenario, so it took the `check_*` prefix and dropped
      its own `OK:` print.
- [x] re-ran `swift build` and `swift test` (131 tests / 17 suites, only the known PRE-EXISTING
      `IntegrationServiceTests` Flatpak failure), `python3 -m py_compile` on `atspi_smoke.py`,
      `git diff --check`.
- ➕ **NOT changed, and why:** the blank shortcut column on `Preferences…` / `Copy Selection` / … is
      the plan's explicit out-of-scope call (`Context` → "Pre-existing issues surfaced by this work"),
      not a defect this pass introduces — Linux has no single chord resolver, and hardcoding chord text
      into rows is exactly what makes `AppController.swift:230`'s tooltip stale.

### Task 7: ➕ Review-fix pass (code smells, iteration 2)

Twelve smell findings, ten confirmed and fixed. This is the pass that produced the **three
abstractions the plan never anticipated**, so they are recorded here in full — a reader of the
Solution Overview alone would not know they exist.

**New host-free API (`PalettePresentation.swift`, 100 lines):**

- [x] **`LinuxPaletteItem`** — a typealias for `(row: LinuxPaletteRow, run: () -> Void)`, the
      pair every palette seam traffics in. It was spelled out eight times (`paletteAll`,
      `paletteItems`, each list builder, `filterPalette`'s local); naming it once removed the
      repetition and made the `LinuxPaletteList` signature readable.
- [x] **`LinuxPaletteList`** (`items: [LinuxPaletteItem]`, `preservesNaturalOrder: Bool`) —
      owns `filtered(query:)`, the ONE ordering seam `filterPalette` calls. `paletteAll` is now
      this struct instead of a bare array, and `showPalette` builds it per palette kind.
- [x] **`preservesNaturalOrder`** — true only for the attention palette, whose rows arrive
      already ranked blocked→active→completed. `filtered(query:)` returns them untouched while
      the query is empty or whitespace-only, and falls through to `fuzzyRank` as soon as
      anything is typed. See the scope-expansion section below: this is a **behavior** change,
      not just a rendering one.
- [x] **`action(_:in:chord:)` replaced `action(title:chord:)`** — it now takes the live
      `PaletteContext` and calls `command.title(in: context)` itself. With the context-free
      `PaletteCommand.title`, the `toggleFlag` row read `Flag Session` for an already-flagged
      session and `toggleFlaggedView` read `Show Flagged Only` while the flagged view was
      already on — the palette offered the wrong verb. macOS passes the context the same way.
- [x] **`sortedByTitle` deleted** (added one pass earlier) — see the ⚠️ under Task 6.

**New app-target API:**

- [x] **`resolvedChord(for:)`** on `AppController` (`KeymapDispatch.swift:158`) — the
      `resolvedBuiltinChords.first(where: { $0.value == action })?.key` reverse lookup, which
      the palette's shortcut column and `AppControllerPrimaryMenu.swift:41` had each written
      out separately. One resolver means the two surfaces cannot render different chords for
      one action. ⚠️ It is deliberately **not** named `chord(for:)`: an instance method named
      `chord` shadows the module-global `chord(fromKeyval:state:)` inside the same extension
      and broke the build. Its doc comment says so, so it is not "simplified" back.

**Duplication removed in `Palette.swift` (345 lines):**

- [x] `entry(for:)`'s 43-arm switch returned closure AND built-in per command, duplicating
      `PaletteCommand.builtinAction` in agtermCore. Reduced to `run(for:)` — closure only; the
      chord now comes from `cmd.builtinAction.flatMap(resolvedChord(for:))` at the one call
      site. Verified case-by-case equivalent in review phase 4: 35 commands mapped (including
      `.find` → `.toggleSearch`), 8 nil — no command gains or loses a shortcut.
- [x] `sessionPaletteList()` / `attentionPaletteList()` had become byte-identical apart from
      the source collection; collapsed into `sessionRows(_ sessions: [Session])`.
- [x] `App.swift`'s multi-line CSS block comment reduced to a trailing `/* keymap-command pill */`
      — the rationale already lives at the call site in `filterPalette`.

**Tests and the AT-SPI suite:**

- [x] new `actionTitleFollowsContext` (both `toggleFlag` and `toggleFlaggedView` context states)
      and `attentionPaletteKeepsNaturalOrder` (empty query, whitespace-only query, a typed
      query, and the same rows with `preservesNaturalOrder` off);
      `emptyQueryListsAlphabetically` replaced the `sortedByTitle` test;
      `realCatalogQueriesStayUnambiguous` now builds rows through the same `builtinAction`
      mapping production uses, instead of a local copy.
- [x] `run_palette_action` takes `badge=None` and asserts **row-scoped**
      (`labels[:1] == [action_name]` and `badge in labels[1:]`) rather than subtree-wide;
      `verify_palette_row_layout` → `check_palette_row_layout`; three multi-line docstrings
      reduced to the file's one-line convention.
- [x] `swift build` + `swift build -c release` clean; `swift test` 133 tests / 17 suites with
      only the known PRE-EXISTING `IntegrationServiceTests` Flatpak failure;
      `python3 -m py_compile` on `atspi_smoke.py`; `git diff --check` clean.

## ⚠️ Scope expansions and open maintainer decisions

*Everything here landed (or was deliberately left) during the review rounds, beyond the plan's
original "palette row rendering only" scope. Recorded so the maintainer sees it without reading
the progress log.*

**➕ Scope expansion 1 — the attention palette's Return target changed (user-visible behavior).**

- The plan scoped this change to *rendering*. This one is not rendering: with an empty query the
  attention palette (⌃⇧I) no longer alphabetizes, so **Return now runs the blocked session
  instead of the alphabetically-first one**.
- Why it rode along: routing the palette through one ordering seam meant the empty query started
  going through `fuzzyRank`, whose alphabetical tie-break re-sorted a list that arrives already
  ranked blocked→active→completed, newest change first. Alphabetizing it was **pre-existing
  Linux behavior and a divergence from macOS**, which special-cases exactly this
  (`agterm/Views/Palette.swift`); the fix restores parity rather than inventing an ordering.
- It is unit-tested: `attentionPaletteKeepsNaturalOrder` pins the empty, whitespace-only, and
  typed-query cases plus the same rows with the flag off. Review phase 4 verified
  `preservesNaturalOrder` on all four palette-open paths and that `showPalette` /
  `closePalette` / `paletteWasDestroyed` clear it structurally.
- ⚠️ If the maintainer prefers the old Linux alphabetical order for ⌃⇧I, the revert is one
  field: drop `preservesNaturalOrder` from `LinuxPaletteList`.

**➕ Scope expansion 2 — a palette row's visible label changed (`Clear Workspace Focus` → `Clear Focus`).**

- The Linux-only `Clear Workspace Focus` append was dropped because the shared catalog already
  emits `Clear Focus` under the same visibility condition (`hasFocusedWorkspace`) running the
  same `focusWorkspace(nil)` — the identical duplication class as the `Open Directory…` row the
  plan did scope in. Task 2's audit missed it because both rows are chordless, so the
  duplication never became visually inconsistent the way `Open Directory…` did.
- Behavior is identical; **the visible text is not** — the row now reads `Clear Focus`. Review
  phase 4 verified the catalog row is an exact behavioral equal of the dropped one.

**➕ Scope expansion 3 — two catalog titles now follow UI state.**

- `Flag Session` / `Unflag Session` and `Show Flagged Only` / `Show All Sessions` now flip with
  the current state, where the Linux palette previously always showed the context-free title.
  Also a fix rather than a feature (the palette was offering the wrong verb), also unit-tested
  (`actionTitleFollowsContext`), but it does change what the user reads on those two rows.

**➕ Scope expansion 4 — a README line outside the palette was corrected.**

- `README.md:407` gained the Linux note about there being no separate custom-commands palette.
  Task 5 had deferred this to the maintainer; the review pass took it back because the deferral
  premise was wrong — the fork's README already carries inline `On Linux, …` notes for exactly
  this case (`:53`, `:185`, `:412`, `:437`), so it is a one-sentence edit in an established
  style rather than a documentation-policy call.

**⚠️ Open decision 1 — `site/docs.html:856`/`:866` left deliberately stale.**

- The page carries the same entry the README note fixes (`⌃⇧O` → "Custom-commands palette").
  It was NOT edited, which is an explicit divergence from `CLAUDE.md`'s keep-in-sync rule for
  the website and **needs maintainer sign-off**.
- Rationale: that entire Navigation table is verbatim upstream **macOS** notation sitting on a
  Linux-branded page (`⌥⌘↑↓` for prev/next session, `⌘⇧D` for the dashboard, "its own on-screen
  macOS window", "Settings (⌘,) has six tabs"). Correcting the single `⌃⇧O` row would leave
  every neighbouring row equally wrong and read as inconsistent. The divergence is pre-existing
  and page-wide — a macOS-notation cleanup of the whole table, far larger than this branch.

**⚠️ Open decision 2 — `AppController.swift` sits at EXACTLY the 1000-line swiftlint limit.**

- This is why `preservesNaturalOrder` rides on the `LinuxPaletteList` struct rather than a new
  stored property on the controller: any added property would have pushed the file to 1001 and
  broken `swiftlint --strict`, and splitting the file needs maintainer sign-off per `CLAUDE.md`.
- Replacing `paletteAll`'s type kept the line count identical, and it also removes the reset
  hazard a separate controller flag would carry on every palette close path — so the struct is
  the better design regardless. But the file has **zero headroom**: the next feature that needs
  a controller property has to split it first.
- Related headroom note from review phase 4: `App.swift:143` (the badge CSS line) is 198
  columns against the 200-column `line_length` limit.

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification** — the recipe matters, because `scripts/run-linux.sh` sets **no**
`AGTERM_STATE_DIR` (`:1-26`), so a bare run reads/writes the real state dir and
`ControlServer.start()` unlink-rebinds the **default** socket, stealing it from an installed
daily driver. An isolated state dir also redirects the **config** dir
(`AppControllerSurfaces.swift` → `ConfigPaths.configDirectory(setting:stateDir:)`), so an
isolated instance sees only the seeded starter `keymap.conf` and would have **no custom
commands at all** — making the badge half of the fix unobservable. Seed it first:

```sh
D=/tmp/agterm-palette          # SHORT path: unix sockets cap at ~104 bytes
mkdir -p "$D/config"
# first command is CHORDED (renders title + badge + shortcut), second is bare (title + badge only).
# ctrl+shift+e is free in both chord tables, so it survives Linux keymap validation verbatim.
printf 'command "Chorded Demo" ctrl+shift+e true\ncommand "Chordless Demo" true\n' > "$D/config/keymap.conf"
AGTERM_STATE_DIR="$D" scripts/run-linux.sh   # run from the repo root
```

Then open the palette with **Ctrl+Shift+P** (not Ctrl+Shift+O — that is Open Directory on
Linux, and the custom-command palette is keyless) and confirm: the shortcut column is
right-aligned and dimmed; the `custom` badge reads as a badge in both light and dark desktop
themes; the `Chorded Demo` row carries all three labels in order (title, `custom`,
`ctrl+shift+e`) while the `Chordless Demo` row shows a badge and no shortcut; nothing
overflows at the 480 px palette width. Hands-off after launch unless asked to drive it.

Optional: screen-reader sanity with Orca — a row announces its title, badge, and shortcut as
separate labels (see the Testing Strategy note on why no row-level a11y label is set).

**CI-only gates** (not runnable here — `swiftlint`, `xvfb-run`, `xdotool`, `openbox` absent):
- `swiftlint lint --strict --quiet` (`ci.yml:89-101`) — the new file must be clean and
  `Palette.swift` must stay under the 1000-line limit (was 319; **shipped at 345**, with
  `PalettePresentation.swift` at 100). ⚠️ `AppController.swift` is at **exactly 1000** — see
  Open decision 2 above; it has no headroom and `App.swift:143` is 198 of the 200 columns.
- The GTK AT-SPI smoke suite (`scripts/test-linux-ui.sh`, `ci.yml:177-180`) — the real gate
  on the accessible-name changes. On failure read `artifacts/linux-ui/accessibility-tree.txt`
  from the run to see what names the rows actually expose before adjusting either side.
  Installing the three missing dependencies would make this runnable locally.
