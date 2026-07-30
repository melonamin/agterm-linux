# Linux palette reads the cached keymap; one app-wide reload seam

## Overview

PR [melonamin/agterm-linux#7](https://github.com/melonamin/agterm-linux/pull/7) ("render the palette
shortcut in its own column") got one review finding to fix before merge.

`Palette.swift` builds its custom-command rows from a fresh `loadKeymapCommands()` disk read, while key
dispatch runs off the cached `keymap` / `customCommandEngine` state that only an explicit reload rebuilds.
That was harmless while every palette row was bare text.
Now that the row renders `cmd.shortcut` in its own column, an edited-but-not-reloaded chord appears in the
palette looking active while pressing it does nothing — contradicting README:679, which documents that
`keymap.conf` edits apply on **File ▸ Reload Keymap**, the action palette's `Reload Keymap`, or
`agtermctl keymap reload`.

Investigating that turned up an adjacent, pre-existing bug — one that violates already-shipped
documentation.
The parsed keymap is cached **per window controller** on Linux, and only two of the four reload paths fan
out over `gWindows.values`; the palette's own `Reload Keymap` row and the `keymap.reload` control command
rebuild one controller's caches and leave every other window dispatching the previous bindings.
`site/commands.html:1808` already tells users `keymap.reload` is *"App-global; the same path as File ▸
Reload Keymap"*, and `.claude/rules/control-api.md:1077-1078` states the same (no `--window` selector,
because on macOS the keymap is one app-wide `SettingsModel`).
So the Linux implementation contradicts its own shipped docs; this is not a new feature but the port
catching up.

Both go in together: the palette reads the cache, and every explicit reload routes through one app-wide
seam so the four surfaces cannot drift again.
They stay **separate commits** (see Commit structure below) so the reviewer can read their one-line ask in
isolation.

**Benefits**

- The shortcut column shows exactly the chord that fires — the palette can no longer advertise a binding
  dispatch does not have.
- `Reload Keymap` from the palette, and `agtermctl keymap reload`, apply to every open window — which is what
  `site/commands.html:1808` and `.claude/rules/control-api.md:1077` already promise and macOS already does.
- One reload seam instead of four hand-written `gWindows` loops, which is what let two of them fall behind.
- One toast wording instead of today's two, and one toast per reload instead of N (the Settings path
  currently toasts per window *and* posts its own summary).

## Context (from discovery)

Verified in the working tree during the brainstorm — these are established facts, do not re-derive them:

- `agterm-linux/Sources/AgtermLinux/Palette.swift:62` — `for cmd in loadKeymapCommands().commands {`.
- `agterm-linux/Sources/AgtermLinux/AppControllerSurfaces.swift:220-223` — `loadKeymapCommands()` calls
  `loadLinuxKeymap(configDirectory:)` directly and has **no other caller anywhere in the repo**, so it is
  dead code the moment the palette switches.
- `agterm-linux/Sources/AgtermLinux/KeymapDispatch.swift:125-151` — `reloadKeymapDiagnostics()` is the only
  thing that rebuilds `keymap`, `resolvedBuiltinChords`, and `customCommandEngine`; it toasts on non-empty
  diagnostics (~lines 146-149) and returns the count.
- `agterm-linux/Sources/AgtermLinux/AppController.swift:296` — startup calls it during window construction;
  the AdwToastOverlay already exists by then (built at ~line 272), so a toast there lands.
- `agterm-linux/Sources/AgtermLinux/WindowManager.swift:10` — `@MainActor var gWindows: [UUID: AppController]`,
  and the file already hosts the app-wide `@MainActor` free functions `ensureStarterFiles`, `flushOnQuit`,
  and `openWindow`.
- `agterm-linux/Sources/AgtermLinux/LinuxSettingsController.swift` is an `@MainActor extension AppController`,
  so `self` is available at its `setConfigDirectory` fanout.
- `agterm-linux/Sources/AgtermLinux/SettingsKeyMappingPage.swift:112-120` — `onReloadKeymapSettings` runs
  `gWindows.values.map { … }` **unconditionally**; only `showToast` and `rebuildSettings` are
  optional-chained off `controllerForWidget(button)`.
  So the seam must accept an **optional** controller, or an unresolved button would stop reloading
  altogether instead of just skipping the toast.
- **Shipped docs already promise app-global behavior**: `site/commands.html:1808` — "App-global; the same
  path as File ▸ Reload Keymap"; `.claude/rules/control-api.md:1077-1078` — "no `--window` selector (the
  keymap is app-global)".
  The fanout fix brings Linux into line with those; nothing in either file needs editing.
- **Out of scope, recorded so the PR has an answer ready**: `SettingsKeyMappingPage.swift:50` renders the
  Settings ▸ Key Mapping diagnostics list from its own fresh `loadLinuxKeymap(configDirectory:).diagnostics`
  read — the same read-the-file-not-the-cache shape as the palette bug.
  It cannot switch to the cache: `reloadKeymapDiagnostics()` keeps only the *count*, discarding the
  `[KeymapDiagnostic]` array a list needs. That page also `rebuildSettings`es right after its own reload, so
  its list is fresh exactly when it matters. Leave it; the pending message-surfacing issue
  (`docs/issues/20260727-linux-keymap-validated-against-macos-defaults.md:107-116`) is where it belongs.
- **A latent fifth reload site, informational**: `README.md:677` promises the Edit Keymap overlay "reloads
  automatically when you save and quit", and no Linux caller implements it (`editKeymap()`,
  `AppControllerSurfaces.swift:282-287`, only opens the overlay).
  Pre-existing and out of scope — but Task 6's rule bullet is worded to catch it when someone does implement
  it, since it will be a fifth caller that must use the seam.
- macOS parity: `agterm/AppActions+Palette.swift:132` reads `settingsModel?.keymap.commands` — cached.
- Naming precedent for the seam: `agtermCore/Sources/agtermCore/WindowLibrary.swift:495`
  `resetSessionFontSizesAllWindows()`.
- `ctrl+shift+y` is free for the new AT-SPI fixture: `isReservedMonitorChord`
  (`agtermCore/Sources/agtermCore/Keybind.swift:32-36`) covers only `ctrl+tab` / `ctrl+1` / `ctrl+2`,
  `isLinuxReservedChord` adds only `ctrl+,`, the Linux default table
  (`LinuxKeyboardPolicy.swift`) binds letters `d f g i j m n o p q s t w`, and no shared default uses
  `key: "y"`.
  So the parser will not clear its shortcut during cross-section validation.

### The four reload call sites

| site | current scope |
| --- | --- |
| `SettingsKeyMappingPage.swift:113-115` (`onReloadKeymapSettings`) | all windows via `gWindows.values.map { … }.max() ?? 0`, then its **own** summary toast — double-toasts today |
| `LinuxSettingsController.swift:136` (`setConfigDirectory`) | all windows via `for controller in gWindows.values { _ = … }`, silent |
| `Palette.swift:122` (the `.reloadKeymap` palette row) | `self` only — **BUG** |
| `ControlActions+AppController.swift:560-563` (`reloadKeymap()` → `keymap.reload`) | the resolved controller only — **BUG** |

### Related patterns found

- The PR being fixed already applied this exact "one seam so two surfaces cannot render different values"
  move for chords: `AppController.resolvedChord(for:)` (`KeymapDispatch.swift:158-160`) replaced a reverse
  lookup written out twice.
  The reload fanout is the same shape of bug one level up.
- AT-SPI helpers to reuse: `open_palette`, `palette_row_labels`, `press_escape`, `control_json`,
  `named(app, …, role="frame")` — in `agterm-linux/tests/atspi_smoke.py`: `palette_row_labels:478`,
  `open_palette:489`, `run_palette_action:508`, `check_palette_row_layout:532`, `press_escape:207`,
  `control_json:419`.
- `verify_custom_command_failures` (`atspi_smoke.py:1229`) already seeds `keymap.conf` **before**
  `launch(env)` and already creates a **second window** (`command-window-b`), waiting for both frames right
  before `check_palette_row_layout` — exactly the two-window fixture the fanout assertion needs, at no extra
  app launch.

### Dependencies identified

- No new package dependency, no new file outside the Linux target and its tests.
- `agtermCore` is untouched; nothing here is host-free enough to belong there (the toast wording is Linux UI
  text with no core consumer, and the fanout is `gWindows` over live GTK controllers).

## Development Approach

- **testing approach**: Regular (code first, then tests) — the reviewer's fix is a known one-line change
  and the seam's shape is already settled, so there is no design to discover through tests.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional — they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility

**Honest coverage note.** Most of this change is `@MainActor` GTK-side code — a `gWindows` fanout over live
`AppController`s — which no unit test in `AgtermLinuxTests` can construct.
The plan therefore pushes *all* the host-free logic into one extracted helper (Task 3) — the count reduction
**and** the toast wording, so the seam itself is left with nothing but `map`, `showToast`, and `return` — and
puts the behavioral proof in the AT-SPI scenario (Task 5).
Tasks 2 and 4 then carry no unit tests of their own because, after that extraction, they genuinely contain no
host-free logic; each says so explicitly and names the task that covers it, rather than inventing a test that
asserts nothing.

## Testing Strategy

- **unit tests** (`agterm-linux/Tests/AgtermLinuxTests/`, run with `cd agterm-linux && swift test`): the two
  extracted helpers — `keymapReloadToast` (four wording cases, plus singular/plural) and
  `keymapDiagnosticCount` (empty, single, disagreeing counts).
- **e2e / UI tests**: this repo's UI e2e layer is the AT-SPI smoke suite
  (`agterm-linux/tests/atspi_smoke.py`, driven by `scripts/test-linux-ui.sh`).
  The palette-cache fix and the reload fanout are both UI-observable and get coverage there, in the same
  task as the code where possible — Task 5.
- **cannot run locally on this box, branch CI covers both** — state this in the PR rather than claiming
  they passed:
  - `scripts/test-linux-ui.sh` — no `Xvfb`/`xvfb-run`/`openbox`/`xdotool` installed.
  - `swiftlint lint --strict` — swiftlint is not installed.
- **known-unrelated pre-existing failures** (they fail identically on unmodified base here — do NOT chase
  them, do NOT "fix" them in this change):
  - `agtermCore`: `CodexStatusHookTests.stopReportsBlockedWhenAssistantMessageEndsInQuestionMark`
  - `agterm-linux`: `IntegrationServiceTests` — "Flatpak process environments do not offer a host launcher"
    (this machine has a real `agtermctl` installed, so the probe resolves `.installed`, not `.unavailable`)

#### Recorded baseline (Task 1, at `cd3ee02`, before any change)

Measured in this worktree on the unmodified branch tip, so later tasks can tell new breakage from
pre-existing failure.
Toolchain: Swift 6.3.2 at `~/.local/share/mise/installs/swift/6.3.2/usr/bin`, run with
`LD_LIBRARY_PATH=~/.local/share/swift-linux-compat` (the inherited `LD_LIBRARY_PATH=/opt/agterm-linux/lib`
must be overridden — see the staging memory note).

- `swift build --product AgtermLinux` — **succeeds** (179 steps, links clean).
- `cd agtermCore && swift test` — **1733 tests in 74 suites, 1 failure**:
  - `CodexStatusHookTests.stopReportsBlockedWhenAssistantMessageEndsInQuestionMark`
    (`CodexStatusHookTests.swift:102` — `run("stop", …).statusCalls == ["blocked"]`).
    Exactly what the plan predicted; reproduced on 4 of 4 runs.
- `cd agterm-linux && swift test` — **133 tests in 17 suites, 1 failure**:
  - `"Linux integration service"` ▸ `"Flatpak process environments do not offer a host launcher"`
    (`IntegrationServiceTests.swift:765` — resolves `.installed`, expected `.unavailable`).
    Exactly what the plan predicted.
- ⚠️ **One additional, INTERMITTENT `agtermCore` failure the plan did not predict**:
  `CodexStatusHookTests.watcherIgnoresAutoReviewProgress()` (`CodexStatusHookTests.swift:131` —
  `result.controlCalls` came back `[]` instead of the expected one-element array).
  It failed on 1 of 4 baseline runs and passed on the other 3, so `agtermCore` baselines at either 1 or 2
  failures depending on the run.
  Same suite as the deterministic failure, unrelated to the keymap/palette work, and not chased per the
  rule above — but a later task seeing 2 `agtermCore` failures should check for this name before treating
  it as new breakage.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

Two coupled changes, both narrowing to a single source of truth.

**1. The palette reads the cache.** One line at `Palette.swift:62` switches from a fresh disk read to the
`keymap.commands` that dispatch itself uses, and the now-unreferenced `loadKeymapCommands()` is deleted.
This is the reviewer's ask verbatim, and it is what macOS already does.

**2. One app-wide reload seam.** `reloadKeymapDiagnostics()` keeps rebuilding one controller's three caches
and returning the diagnostic count, but stops toasting; a new
`reloadKeymapAllWindows(reportingIn:)` free function in `WindowManager.swift` maps it over `gWindows.values`
and toasts once in the acting window (when one resolved — see the optional-controller decision below).
All four explicit-reload sites route through it.
Startup stays deliberately single-window — it is building one new controller's cache, not reloading the app
— so it keeps calling `reloadKeymapDiagnostics()` directly and toasts itself.

**Why a seam rather than two more loops.** The alternative considered was to leave
`reloadKeymapDiagnostics()` alone and paste `gWindows.values.map { … }.max() ?? 0` into the two broken
sites.
Rejected: the bug exists *precisely because* each site hand-wrote its own fanout, so adding two more
hand-written loops re-creates its cause, and it would leave an N-window app toasting N times per reload.

**Why the toast moves.** A per-window toast inside the fanned-out reload means window B banners a reload the
user performed in window A.
Moving it to the seam also collapses the two wordings that disagree today —
`"keymap.conf: N error(s) — bad line(s) ignored"` (KeymapDispatch) versus `"keymap.conf reloaded"` /
`"keymap.conf: N diagnostic(s)"` (Settings) — into one policy, and removes the Settings path's existing
double-toast.

### Key design decisions

- **The wording lives in a host-free helper because two callers disagree on policy.** The seam reloads
  (`isInitialLoad: false`) and startup loads (`isInitialLoad: true`), and they disagree about what a clean
  result should say — that divergence, not testability, is why the helper exists.
  Testability is the bonus: these helpers are the only part of this change a unit test can reach, and pulling
  the `max() ?? 0` reduction out into `keymapDiagnosticCount(_:)` alongside them leaves the seam with no
  host-free logic at all.
- **The toast is a returned `String?`, not an `if` at each call site.** `nil` = "do not toast" puts the
  clean-startup case in the value itself instead of a condition each caller has to remember.
- **Startup does not say "reloaded".** Nothing was reloaded — it is the initial load — and a success toast on
  every window open would be noise, so a clean initial load returns `nil`.
- **`max()` over the per-window counts, with a comment.** Every window parses the same file so the counts
  are identical; `max()` is just a safe way to pick one and must be commented as such so it does not read as
  an arbitrary choice. The `?? 0` empty-`gWindows` branch is covered by Task 3's tests.
- **The seam takes an OPTIONAL controller, and that is behavior-preserving, not sloppy.**
  `onReloadKeymapSettings` (`SettingsKeyMappingPage.swift:112-120`) reloads every window unconditionally and
  optional-chains only its toast. A non-optional `reportingIn:` would turn an unresolved
  `controllerForWidget(button)` into "no window reloads at all" — a real regression smuggled inside a
  refactor advertised as behavior-preserving. So `reportingIn controller: AppController?`: always fan out,
  toast only when a controller resolved.
- **`setConfigDirectory` gains the toast it did not have.** It goes through the seam like the others, so a
  malformed `keymap.conf` in a newly-picked config directory surfaces instead of failing silently. That is a
  deliberate behavior addition, not an accident of the refactor.
- **No control-API surface changes.** `keymap.reload` keeps its `Command` case, its arguments, and its
  `ControlResult(count:)` return; only its scope becomes app-wide.

## Technical Details

### New seam (`WindowManager.swift`)

```swift
@MainActor func reloadKeymapAllWindows(reportingIn controller: AppController?) -> Int
```

- Maps `reloadKeymapDiagnostics()` over `gWindows.values`, reduces with `keymapDiagnosticCount(_:)`, and asks
  `keymapReloadToast(count:isInitialLoad: false)` for the message.
- On a non-nil toast **and** a non-nil `controller`, calls `controller.showToast(_:)` — the fan-out itself
  never depends on the controller resolving (see the optional-controller decision above).
- Returns the count, so `ControlActions.reloadKeymap()` keeps its existing `ControlResult(count:)` shape.
- Lives beside `ensureStarterFiles` / `flushOnQuit` / `openWindow`, the file's existing app-wide free
  functions; named after `WindowLibrary.resetSessionFontSizesAllWindows`.
- Contains **no** host-free logic of its own — the reduction moved into the helper below, deliberately, so
  the untestable part is only `map` + `showToast` + `return`.

### Two host-free helpers (`KeymapDispatch.swift`, file-level, internal not private)

```swift
func keymapDiagnosticCount(_ counts: [Int]) -> Int
func keymapReloadToast(count: Int, isInitialLoad: Bool) -> String?
```

`keymapDiagnosticCount` is the commented `counts.max() ?? 0` — every window parses the same file so the
values are identical, and `?? 0` covers an empty `gWindows`.
`keymapReloadToast`:

| count | isInitialLoad | toast |
| --- | --- | --- |
| `0` | `false` | `"keymap.conf reloaded"` |
| `n > 0` | `false` | `"keymap.conf: n error(s) — bad line(s) ignored"` |
| `n > 0` | `true` | `"keymap.conf: n error(s) — bad line(s) ignored"` |
| `0` | `true` | `nil` (no toast) |

Singular/plural agreement follows the existing `n == 1 ? "" : "s"` shape already at
`KeymapDispatch.swift:147-148`.
Both internal (not `private`) so `AgtermLinuxTests` can reach them.

**Two functions rather than one `(count:, toast:)` summary.** A single helper taking `counts: [Int]` would
force startup — which fans out over nothing and already holds its count — to pass a one-element array and
discard a tuple member, and would make every wording test wrap a scalar in an array literal.
Splitting keeps one definition of the wording policy just the same, keeps the reduction out of the seam
(it is a call, not an inline `max()`), and keeps both branches reachable from tests.

**The count is deliberately an `Int`, not the diagnostics themselves.**
`reloadKeymapDiagnostics()` holds the full `[KeymapDiagnostic]` — line numbers and messages — and throws all
but the count away.
`docs/issues/20260727-linux-keymap-validated-against-macos-defaults.md:107-116` is an open issue asking for
those messages to reach the toast and the control response, and calls it worth doing independently.
That work widens both helpers and the seam; `Int` is the right narrow choice today (nothing currently
consumes more), and the Task 6 rule bullet is where a future agent will find the seam it has to widen.

### Processing flow after the change

```
startup (AppController.swift:296)  — deliberately single-window: it builds ONE new controller's cache
  reloadKeymapDiagnostics()                                    → this controller's caches, count
  keymapReloadToast(count:, isInitialLoad: true)                → toast only if count > 0

explicit reload (palette row · keymap.reload · Settings ▸ Reload · setConfigDirectory)
  reloadKeymapAllWindows(reportingIn: self)      // or nil, from the Settings button callback
    gWindows.values.map { $0.reloadKeymapDiagnostics() }        → every window's caches + counts
    keymapDiagnosticCount(_:)                                  → count
    keymapReloadToast(count:, isInitialLoad: false)             → message or nil
    if let controller, let toast { controller.showToast(toast) } → at most one toast, in the acting window
    → count
```

### Commit structure

Two commits on `linux-palette-shortcut-column`, in this order, so PR #7's reviewer can read their own ask in
isolation rather than hunting a one-liner inside a seven-file diff:

1. `fix(linux): build palette custom rows from the cached keymap` — Task 2 only (the `Palette.swift:62`
   switch + the dead `loadKeymapCommands()` delete). This is the review comment, complete on its own: after
   it, a non-reloaded window's palette reads the *same* cache dispatch uses, so the palette can no longer
   advertise a chord that does not fire, in any window.
2. `fix(linux): reload the keymap in every window` — Tasks 3, 4, 5, 6 (the two host-free helpers + the seam +
   the four callers + the AT-SPI fanout assertions + the rule note).

Commit 2 is the pre-existing scope defect. It is in the same PR because `site/commands.html:1808` and
`.claude/rules/control-api.md:1077` already document `keymap.reload` as app-global, so it is a
documented-behavior violation rather than a new feature — but if the reviewer would rather take it as a
follow-up PR, commit 1 stands alone and can be pushed by itself.

### Branch and worktree

The fix must land on **`linux-palette-shortcut-column`** (PR #7's head; present locally and on
`origin` = `git@github.com:n2tr2/agterm-linux.git`) and be pushed to update PR #7 — **not** on the current
`linux-port-wip` checkout.

Per the root `CLAUDE.md` worktree rule this belongs in an isolated worktree, with one deviation to note:
`EnterWorktree` creates a *new* branch from `origin/master`, so it cannot check out an existing PR head.
That means a manual `git worktree add <path> linux-palette-shortcut-column`, which the global rule otherwise
discourages — confirm with the user before creating it.
A fresh worktree needs `agterm-linux/vendor` symlinked from the main checkout (`agterm-linux/.gitignore:3`
ignores `vendor/`, and `Package.swift:6` resolves `vendor/ghostty` relative to the **package root**, so the
build cannot find libghostty without it). Use an absolute symlink target.
Whatever is chosen, cleanup must not leave the main checkout on a different branch.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): the Swift changes, the unit tests, the AT-SPI scenario, and
  the `.claude/rules/keymap.md` note — all achievable in this repo.
- **Post-Completion** (no checkboxes): pushing the branch, updating PR #7, replying to the review, carrying
  the fix onto `linux-port-wip` after the merge, and the two checks that can only run in branch CI.

## Implementation Steps

### Task 1: Move onto the PR branch

**Files:**
- Modify: none (git state only)

- [x] confirm with the user: manual `git worktree add` onto the existing `linux-palette-shortcut-column`,
      or a direct checkout (the `EnterWorktree` deviation above is why this needs a decision)
      — user chose the manual-worktree option; worktree lives at
      `.claude/worktrees/linux-palette-shortcut-column`
- [x] `git fetch origin linux-palette-shortcut-column` and confirm the local branch matches the remote tip
      (`cd3ee02` at plan time — re-check, it may have moved)
      — re-verified: local `HEAD` == `origin/linux-palette-shortcut-column` == `cd3ee02`, unmoved
- [x] check out that branch in the chosen location; the main `/home/n/p/github/agterm-linux` checkout must
      remain on `linux-port-wip`
      — re-verified: worktree on `linux-palette-shortcut-column`, main checkout still on `linux-port-wip`
- [x] if a worktree: symlink `agterm-linux/vendor` to the main checkout's copy using an **absolute** target
      — re-verified: `agterm-linux/vendor -> /home/n/p/github/agterm-linux/agterm-linux/vendor`
- [x] verify the baseline builds before changing anything: `cd agterm-linux && swift build --product AgtermLinux`
- [x] record the baseline test results, so the two known-unrelated failures are provably pre-existing here:
      `cd agtermCore && swift test`, `cd agterm-linux && swift test`
      — recorded under "Recorded baseline (Task 1)" in Testing Strategy above

### Task 2: Palette custom rows read the cached keymap *(commit 1 — the review comment)*

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/Palette.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/AppControllerSurfaces.swift`

- [ ] change `Palette.swift:62` to `for cmd in keymap.commands {`
- [ ] rewrite the comment above it (lines 59-61) to record the *why*: dispatch runs off this same cache, so
      the chord in the shortcut column is exactly the chord that fires, and edits land on Reload Keymap per
      README:679 — plus the macOS parity pointer (`agterm/AppActions+Palette.swift:132`)
- [ ] delete `loadKeymapCommands()` from `AppControllerSurfaces.swift:220-223`
- [ ] grep the whole repo to confirm no reference to `loadKeymapCommands` survives
- [ ] confirm no custom row *disappears*: a command whose shortcut cross-section validation cleared keeps its
      row with `shortcut == ""` (`KeymapDispatch.swift:90`), which `LinuxPaletteRow.custom` already renders
      chord-less via `linuxTrimmedOrNil` (`PalettePresentation.swift:98`)
- [ ] no unit test in this task: the change is a `@MainActor` read of controller state with no host-free
      logic to assert. Its behavioral coverage is the "must NOT appear before reload" leg of Task 5; the
      existing `PalettePresentationTests` already cover `LinuxPaletteRow.custom` and need no change
- [ ] run tests + build: `cd agterm-linux && swift test`, `swift build --product AgtermLinux`
- [ ] **commit 1** here — this is the reviewer's ask, complete and reviewable on its own

### Task 3: Extract the reload count reduction and the toast wording

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/KeymapDispatch.swift`
- Modify: `agterm-linux/Tests/AgtermLinuxTests/LinuxKeymapTests.swift`

- [ ] add file-level `func keymapDiagnosticCount(_ counts: [Int]) -> Int` to `KeymapDispatch.swift`
      (`counts.max() ?? 0`), commenting that identical per-window counts make `max()` a safe pick rather than
      an arbitrary one, and that `?? 0` is the empty-`gWindows` case
- [ ] add file-level `func keymapReloadToast(count: Int, isInitialLoad: Bool) -> String?` implementing the
      four-case table above, reusing the existing `n == 1 ? "" : "s"` pluralization
- [ ] doc-comment *why the wording helper exists*: two callers with divergent policy (the seam reloads,
      startup loads, and they disagree about what a clean result should say) — testability is the bonus, not
      the reason — and note that both are internal so the tests reach them
- [ ] add a `@Suite("Linux keymap reload toast and count")` to the existing `LinuxKeymapTests.swift` (68
      lines, well under budget — no new file needed)
- [ ] write tests for the explicit-reload wording: clean → `"keymap.conf reloaded"`, `n > 0` → the error
      wording, with singular/plural agreement at `n == 1` and `n == 2`
- [ ] write tests for the initial-load wording: clean → `nil` (the edge case that keeps window-open quiet),
      `n > 0` → the error wording
- [ ] write tests for the reduction: `[]` → `0` (the empty-`gWindows` branch nothing else covers), one
      element, and disagreeing counts → the max
- [ ] run tests — must pass before Task 4: `cd agterm-linux && swift test`

### Task 4: One app-wide reload seam, all four callers rewired

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/WindowManager.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/KeymapDispatch.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/AppController.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/Palette.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/ControlActions+AppController.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/SettingsKeyMappingPage.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/LinuxSettingsController.swift`

- [ ] add `@MainActor func reloadKeymapAllWindows(reportingIn controller: AppController?) -> Int` to
      `WindowManager.swift` beside `ensureStarterFiles`/`flushOnQuit`/`openWindow`: map
      `reloadKeymapDiagnostics()` over `gWindows.values` → `keymapDiagnosticCount(_:)` →
      `keymapReloadToast(count:isInitialLoad: false)` → toast when both the message and the controller are
      non-nil → return the count
- [ ] comment the seam with why it exists (two of four hand-written fanouts fell behind) and why the
      controller is **optional** — `onReloadKeymapSettings` reloads unconditionally today and only
      optional-chains its toast, so a non-optional parameter would silently turn an unresolved button into
      "nothing reloads"
- [ ] remove the `showToast` from `reloadKeymapDiagnostics()` (`KeymapDispatch.swift:146-149`), keeping the
      cache rebuild and the returned count, and doc-comment that the **caller** owns the toast
- [ ] `AppController.swift:296`: keep the direct single-window `reloadKeymapDiagnostics()` (it is building
      one new controller's cache, not reloading the app) and toast from
      `keymapReloadToast(count:isInitialLoad: true)`, commenting why startup is deliberately not fanned out
      and why one dirty startup still toasts once per window opened
- [ ] `Palette.swift:122`: `case .reloadKeymap: return { _ = reloadKeymapAllWindows(reportingIn: self) }`
- [ ] `ControlActions+AppController.swift:560-563`: take the count from the seam, leaving the
      `ControlResponse(ok: true, result: ControlResult(count:))` shape byte-for-byte unchanged
- [ ] `SettingsKeyMappingPage.swift:112-120`: pass `controllerForWidget(button)` straight into
      `reportingIn:` (no `guard`, so the fan-out keeps running when it is nil, exactly as today) and drop its
      own summary toast, which removes the current double-toast; keep `rebuildSettings(page: .keyMapping)`
- [ ] `LinuxSettingsController.swift:136` (`setConfigDirectory`): route through the seam so a malformed
      `keymap.conf` in a newly-picked config dir surfaces — comment that this toast is a deliberate addition,
      and call it out in the PR body since it is user-visible and not implied by the review comment
- [ ] no unit test in this task: after Task 3's extraction the seam holds only `map` + `showToast` + `return`
      over live GTK controllers, unreachable from `AgtermLinuxTests`. Wording and reduction are covered by
      Task 3; the fanout behavior by Task 5
- [ ] run tests + both builds — must pass before Task 5: `cd agterm-linux && swift test`,
      `swift build --product AgtermLinux`, `swift build --product agtermctl-linux`

### Task 5: AT-SPI coverage for the cache fix and the fanout

**Files:**
- Modify: `agterm-linux/tests/atspi_smoke.py`

- [ ] add `check_keymap_reload_fanout(app, process_id, env, config, first_title, second_title)` reusing
      `open_palette`, `palette_row_labels`, `press_escape`, and `control_json` — the two titles are **frame**
      titles (`command-origin-a` / `command-origin-b`, the session names), NOT the window name
      `command-window-b`; note that distinction in the docstring, since `open_palette` needs the frame title
- [ ] in it: APPEND `command "Late Demo" ctrl+shift+y true` to the already-seeded `keymap.conf`, then open
      the palette in **each** window and assert no row titled `Late Demo` — this is the reviewer's fix, an
      unreloaded edit must not appear
- [ ] then `agtermctl keymap reload` via `control_json(env, "keymap", "reload", …)` and assert
      `["Late Demo", "custom", "ctrl+shift+y"]` appears in **both** windows' palettes — asserting both is
      what makes it independent of which controller the control server resolved, so it cannot pass
      trivially without the fanout
- [ ] cover the **other** broken site too: append a second command, drive the palette's own `Reload Keymap`
      row in window A with the existing `run_palette_action(app, pid, first_title, "Reload Keymap")`
      (`atspi_smoke.py:508`), and assert the new row appears in window **B** — the control command and the
      palette row are two separate bugs (both marked BUG in the scope table) and the fixture is already there
- [ ] comment why `ctrl+shift+y` specifically (free in the reserved-monitor set, the Linux default table,
      and the shared defaults — so validation will not clear its shortcut), mirroring the existing
      `ctrl+shift+e` note
- [ ] call it from `verify_custom_command_failures` right after `check_palette_row_layout` (`atspi_smoke.py:1267`),
      where `wait_for(lambda: frame(...))` has already proven both frames exist — reusing that fixture
      rather than adding a scenario, so CI pays no extra app launch
- [ ] verify the new `"keymap.conf reloaded"` toasts cannot **delay** the four toast assertions immediately
      downstream (`atspi_smoke.py:1276-1302`: the `launch_prefix` / `exit_message` checks and their negative
      cross-window leakage assertions). The risk is queueing, not text collision: `showToast`
      (`AppController.swift:825-828`) posts to an `AdwToastOverlay`, which shows one toast at a time, so a
      success toast can sit in front of the one those assertions wait for. `wait_for` defaults to
      `timeout=12` (`atspi_smoke.py:61`) against AdwToast's ~5 s display, so there is headroom — confirm it
      rather than assume, since this is the shape that would flake in CI rather than fail locally
- [ ] confirm `check_palette_row_layout` and the existing `run_palette_action` calls still hold: that
      scenario writes `keymap.conf` before `launch(env)`, so startup's cache load already carries those rows
- [ ] mark clearly (in the PR body, not only here) that this scenario was **not executed locally** — no
      `Xvfb`/`openbox`/`xdotool` on this box — and that branch CI is what runs it
- [ ] run what can run — must pass before Task 6: `python3 -m py_compile agterm-linux/tests/atspi_smoke.py`,
      `cd agterm-linux && swift test`

### Task 6: Record the per-window-cache contract in the keymap rule

**Files:**
- Modify: `.claude/rules/keymap.md`

- [ ] **extend the `paths:` frontmatter** (`keymap.md:2-11`, today macOS-only) with
      `agterm-linux/Sources/AgtermLinux/KeymapDispatch.swift`,
      `agterm-linux/Sources/AgtermLinux/Palette.swift`,
      `agterm-linux/Sources/AgtermLinux/LinuxKeyboardPolicy.swift`, and
      `agterm-linux/Tests/AgtermLinuxTests/LinuxKeymapTests.swift` — without this the new note never loads
      when a future agent opens the very files it binds (only `main-loop.md` globs `agterm-linux/**` today).
      `theme-picker.md` and `control-api.md` already precedent per-file Linux path additions
- [ ] add a bullet: on Linux the parsed keymap is cached **per window controller**, so every explicit reload
      must go through `reloadKeymapAllWindows(reportingIn:)`; the bug existed because each call site
      hand-wrote its own `gWindows` fanout and two of the four fell behind
- [ ] note in the same bullet that startup is deliberately single-window, that the toast belongs to the
      caller (`keymapReloadToast`) not to `reloadKeymapDiagnostics()`, and that the controller parameter is
      optional to preserve the Settings button's unconditional fan-out
- [ ] use semantic line breaks — one sentence per line, per the root `CLAUDE.md` convention for these notes
- [ ] no test: documentation only
- [ ] run tests — must pass before Task 7: `cd agterm-linux && swift test`
- [ ] **commit 2** here (Tasks 3-6 together: the two host-free helpers, the seam, the callers, the AT-SPI
      assertions, and this note)

### Task 7: Verify acceptance criteria

- [ ] the palette's custom rows come from `keymap.commands`; `loadKeymapCommands` no longer exists anywhere
- [ ] all four explicit-reload sites call `reloadKeymapAllWindows`; `reloadKeymapDiagnostics()` has exactly
      one remaining direct caller (startup) plus the seam
- [ ] at most one toast per explicit reload (none when no controller resolved), none on a clean startup, and
      one per window-open on a dirty startup — that last one is deliberately per-window and unchanged from
      today, since startup builds one controller's cache rather than reloading the app
- [ ] the Settings ▸ Reload button still reloads every window even when `controllerForWidget(button)`
      resolves nil — the optional `reportingIn:` is what preserves that
- [ ] `keymap.reload` still returns the diagnostic count with an unchanged response shape
- [ ] run the full suites: `cd agtermCore && swift test`; `cd agterm-linux && swift test` — green except the
      two known-unrelated pre-existing failures recorded in Task 1's baseline
- [ ] run both builds: `swift build --product AgtermLinux`, `swift build --product agtermctl-linux`
- [ ] run `scripts/check-linux-cli-drift.sh` and `git diff --check`
- [ ] state explicitly in the PR that `scripts/test-linux-ui.sh` and `swiftlint lint --strict` did NOT run
      locally (tooling absent) and that branch CI covers them — do not imply they passed
- [ ] confirm the keep-in-sync ledger below still holds after implementation

### Task 8: [Final] Update documentation

- [ ] `README.md`: no change needed — line 679 already lists the three reload entry points without claiming
      per-window scope. Re-read it and confirm rather than assume
- [ ] `CLAUDE.md`: no new cross-subsystem pattern; the note belongs in `.claude/rules/keymap.md` (Task 6).
      Re-confirm nothing at the root level needs it
- [ ] leave `docs/plans/completed/20260726-linux-palette-shortcut-column.md:444` alone — it mentions the
      deleted `loadKeymapCommands()` but is a historical completed-plan record
- [ ] move this plan to `docs/plans/completed/` (`mkdir -p docs/plans/completed` if needed)

## Keep-in-sync ledger

Recorded so it is not relitigated at review time:

- **No control command owed.** No new `Command` case, no argument change, no return-shape change —
  `keymap.reload` already exists and still returns the diagnostic count; only its scope becomes app-wide.
  So: no `agtermctl` subcommand, no round-trip test, no `tree` read-back field, no `agterm/Resources/agent-skill/`
  edit.
- **`site/` untouched, and for a stronger reason than "nothing changed".**
  `site/commands.html:1808` already documents `keymap.reload` as "App-global; the same path as File ▸ Reload
  Keymap", and `.claude/rules/control-api.md:1077-1078` already states there is no `--window` selector
  because the keymap is app-global.
  The fanout makes the Linux implementation match those; editing them would mean *weakening* shipped docs to
  describe a bug.
  Lead with this in the PR — it is a better argument than "no surface changed", and it reframes the fanout as
  a documented-behavior fix rather than scope creep.
- **No `tree` read-back owed.** Nothing here sets per-session state.
- **No Settings ▸ Interface toggle.** Nothing hideable is added; the palette shortcut column already ships.
- **`README.md` unchanged** — README:679 covers the reload entry points already, without a per-window claim.
  No Linux-specific parity doc exists to update either (`agterm-linux/docs/` holds only `main-loop.md` and
  `x11-wayland.md`).
- **`CHANGELOG.md` untouched** — release-only, never in a feature/fix PR.
- **`.claude/rules/keymap.md` gains one bullet AND four `paths:` entries** (Task 6) — the per-window-cache +
  app-wide-seam contract, plus the frontmatter fix without which the note would never load on Linux files.

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Branch CI (the two checks that cannot run on this machine)**

- `scripts/test-linux-ui.sh` / the AT-SPI suite, including the new `check_keymap_reload_fanout` assertions
  and the `run_palette_action` calls in the scenario it extends — no `Xvfb`/`xvfb-run`/`openbox`/`xdotool`
  here.
- `swiftlint lint --strict` — swiftlint is not installed here.
- Push to `origin linux-palette-shortcut-column` and wait for all four checks on PR #7 before asking for
  re-review.

**PR #7 follow-through**

- Reply to melonamin's review comment: the palette now reads cached `keymap.commands` as asked (commit 1,
  readable on its own), and the second commit fixes the adjacent per-window reload-scope bug the
  investigation turned up — quoting `site/commands.html:1808` and `.claude/rules/control-api.md:1077`, which
  already document `keymap.reload` as app-global, so this is the port catching up to shipped docs rather than
  new scope. Include the before/after scope table.
- Offer to drop commit 2 into a follow-up PR if the reviewer would rather keep this one to the one-line ask.
- Mention the two user-visible changes the review comment does not imply: `setConfigDirectory` now toasts
  keymap diagnostics, and the Settings ▸ Reload wording changes from `"keymap.conf: N diagnostic(s)"` to
  `"keymap.conf: N error(s) — bad line(s) ignored"` (one wording everywhere, and its double-toast is gone).

**Bring the fix onto `linux-port-wip`**

- `linux-port-wip` — the branch actually developed on in this checkout — already carries the shortcut-column
  work (`16b9a04`) *and* still has `Palette.swift:62 loadKeymapCommands()`, so it keeps both bugs until this
  lands there too.
- After PR #7 merges, rebase or cherry-pick both commits onto `linux-port-wip`. Do not do it before the
  merge, or the branches diverge on the same lines.

**Manual verification (optional, needs a GUI session)**

- Two windows open, edit `keymap.conf` to bind a new custom command, `Reload Keymap` from window A's
  palette, then press the new chord in window B — it should fire, and B's palette should show it.
  That is the user-visible half of the fanout bug and the one thing AT-SPI proves only indirectly.
- Confirm a malformed `keymap.conf` produces exactly one toast per explicit reload, not one per open window,
  and no toast at all on a clean app launch. (A *dirty* launch still toasts once per window opened — that is
  unchanged and intended.)
