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
| `LinuxSettingsController.swift:136` (`setConfigDirectory`) | all windows via `for controller in gWindows.values { _ = … }`, error banner **per window** (each `reloadKeymapDiagnostics()` toasts its own count) |
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

- **unit tests** (`agterm-linux/Tests/AgtermLinuxTests/`, run with `cd agterm-linux && swift test`):
  `keymapReloadToast` (silent when clean, singular and plural error wording), plus host-free pins of the
  AT-SPI fixture — the appended `Late Demo`/`Palette Demo` rows, and that the fan-out check's malformed
  line yields exactly the one-error banner text the AT-SPI leg waits for. Those pins matter because the
  AT-SPI suite cannot run on every box, so a reserved-chord or default-table change should fail as a named
  unit failure rather than an opaque GUI timeout.
- **e2e / UI tests**: this repo's UI e2e layer is the AT-SPI smoke suite
  (`agterm-linux/tests/atspi_smoke.py`, driven by `scripts/test-linux-ui.sh`).
  The palette-cache fix and the reload fanout are both UI-observable and get coverage there, in the same
  task as the code where possible — Task 5.
- **cannot run locally on this box, branch CI covers both** — state this in the PR rather than claiming
  they passed:
  - `scripts/test-linux-ui.sh` — see the ⚠️ correction below; it cannot complete here, but NOT for the
    reason originally written.
  - `swiftlint lint --strict` — swiftlint is not installed
    (Task 7 re-verified: `command -v swiftlint` → nothing).
- ⚠️ **CORRECTION (Task 7): the recorded reason `test-linux-ui.sh` cannot run here was WRONG.**
  The plan claimed "no `Xvfb`/`xvfb-run`/`openbox`/`xdotool` installed".
  All of them ARE installed (`/usr/bin/Xvfb`, `/usr/bin/xvfb-run`, `/usr/bin/openbox`,
  `/usr/bin/xdotool`), as are `dbus-run-session` and the `Atspi` GI bindings — every dependency the
  script's own preflight loop checks.
  Task 7 therefore ATTEMPTED the run rather than accepting the claim, and it fails for a different,
  genuinely environmental reason: `at-spi2-core 2.60.5` activates `org.a11y.atspi.Registry` through a
  systemd USER UNIT, and inside `dbus-run-session` the nested `dbus-broker-launch` cannot reach
  `org.freedesktop.systemd1` (`Activated service 'org.freedesktop.systemd1' failed: … exited with
  status 1`, repeated throughout `artifacts/linux-ui/atspi.log`).
  The registry never starts, so `Atspi.get_desktop(0)` returns an empty tree and the run aborts at
  `FAIL: agterm app not present in the AT-SPI tree` before any scenario executes — including the new
  `check_keymap_reload_fanout`.
  Net effect on the plan is unchanged (the suite still did NOT run locally; branch CI is what runs it),
  but the PR must state the accurate reason, not the missing-tooling one.
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
Moving it to the seam also collapses the two ERROR wordings that disagree today —
`"keymap.conf: N error(s) — bad line(s) ignored"` (KeymapDispatch) versus `"keymap.conf: N diagnostic(s)"`
(Settings) — into one policy, and removes the Settings path's existing double-toast.
The Settings button's `"keymap.conf reloaded"` SUCCESS confirmation stays at that call site, because it is
the only reload the user requested by pressing a button (see the revised decision below).

### Key design decisions

- **REVISED IN REVIEW — a load REPORTS ERRORS AND IS OTHERWISE SILENT, everywhere.**
  The plan originally gave the helper an `isInitialLoad:` flag so the seam could confirm success with
  `"keymap.conf reloaded"` while startup stayed quiet.
  That silently gave `agtermctl keymap reload` and the palette's `Reload Keymap` row a success banner they
  never had, diverging from macOS (`SettingsModel.reloadKeymap()` notifies only on a non-empty
  `keymapDiagnostics`) and bannering the frontmost window on every invocation of a SCRIPTED surface (hooks,
  custom commands) — a user-visible behavior change smuggled into a scope-only fix.
  The helper is now `keymapReloadToast(count:) -> String?`: `nil` when clean, the error wording otherwise.
  The ONE success confirmation is the Settings ▸ Key Mapping reload BUTTON, which posts its own
  `"keymap.conf reloaded"` at its own call site — exactly the behavior it had before this change, and the
  only site where the user pressed a button and expects an answer.
  Net effect: every reload path keeps its pre-change reporting, only the SCOPE changes, as advertised.
- **The wording still lives in a host-free helper**, because two callers (the seam and
  `loadKeymapAtStartup()`) share it and `String?` puts the "do not toast" case in the value instead of an
  `if` each caller repeats.
- **REVISED IN REVIEW — `max() ?? 0` is INLINE in the seam, not a `keymapDiagnosticCount(_:)` helper.**
  The original argument ("extracting it leaves the seam with no host-free logic at all") is circular: the
  seam having no host-free logic is a restatement of the extraction, not a benefit of it, and the three
  tests it bought asserted `Sequence.max()` rather than any agterm behavior.
  The one non-trivial claim — every window parses the same file, so the counts are identical and `max()`
  merely picks one — is a fact about the CALL SITE and now reads as a comment next to the `gWindows` map
  it describes.
- **The seam takes an OPTIONAL controller, and that is behavior-preserving, not sloppy.**
  `onReloadKeymapSettings` (`SettingsKeyMappingPage.swift:112-120`) reloads every window unconditionally and
  optional-chains only its toast. A non-optional `reportingIn:` would turn an unresolved
  `controllerForWidget(button)` into "no window reloads at all" — a real regression smuggled inside a
  refactor advertised as behavior-preserving. So `reportingIn controller: AppController?`: always fan out,
  toast only when a controller resolved.
- **`setConfigDirectory` goes from a PER-WINDOW error banner to ONE — it is not gaining reporting.**
  (Corrected in review: an earlier draft of this bullet claimed it "gains a banner it did not have". It
  already bannered — its `gWindows` loop toasted inside every `reloadKeymapDiagnostics()`, once per open
  window.) It goes through the seam like the others — a new config directory means a DIFFERENT
  `keymap.conf`, so every window must re-parse — and under the revised policy above it never says
  `"keymap.conf reloaded"`, which was the mis-worded case review flagged (the user changed a DIRECTORY).
  That banner is belt-and-braces on this path regardless: an `AdwToast` lands on the window content,
  under the `AdwPreferencesDialog` the user is still in, so the channel that actually reports here is the
  Key Mapping page's Diagnostics group, which the caller rebuilds right after with the per-line detail.
- **No control-API surface changes.** `keymap.reload` keeps its `Command` case, its arguments, and its
  `ControlResult(count:)` return; only its scope becomes app-wide.

## Technical Details

### New seam (`WindowManager.swift`)

```swift
@MainActor func reloadKeymapAllWindows(reportingIn controller: AppController?) -> Int
```

- Maps `reloadKeymapDiagnostics()` over `gWindows.values`, reduces with a commented inline `max() ?? 0`, and
  asks `keymapReloadToast(count:)` for the message.
- On a non-nil message **and** a non-nil `controller`, calls `controller.showToast(_:)` — the fan-out itself
  never depends on the controller resolving (see the optional-controller decision above).
- Returns the count, so `ControlActions.reloadKeymap()` keeps its existing `ControlResult(count:)` shape.
- Lives beside `ensureStarterFiles` / `flushOnQuit` / `openWindow`, the file's existing app-wide free
  functions; named after `WindowLibrary.resetSessionFontSizesAllWindows`.

### One host-free helper (`KeymapDispatch.swift`, file-level, internal not private)

```swift
func keymapReloadToast(count: Int) -> String?
```

| count | toast |
| --- | --- |
| `0` | `nil` (no banner — clean loads and clean reloads are both silent) |
| `n > 0` | `"keymap.conf: n error(s) — bad line(s) ignored"` |

Singular/plural agreement follows the existing `n == 1 ? "" : "s"` shape.
Internal (not `private`) so `AgtermLinuxTests` can reach it.
Its two callers are the seam and `loadKeymapAtStartup()` (`KeymapDispatch.swift`), the one-line
`reloadKeymapDiagnostics()` + report wrapper that window construction calls — the wrapper exists so the
startup rationale lives with the keymap code and `AppController.swift` keeps a single line at the call
site, which matters because that file sits exactly at the 1000-line swiftlint cap.

**The count is deliberately an `Int`, not the diagnostics themselves.**
`reloadKeymapDiagnostics()` holds the full `[KeymapDiagnostic]` — line numbers and messages — and throws all
but the count away.
`docs/issues/20260727-linux-keymap-validated-against-macos-defaults.md:107-116` is an open issue asking for
those messages to reach the toast and the control response, and calls it worth doing independently.
That work widens both helpers and the seam; `Int` is the right narrow choice today (nothing currently
consumes more), and the Task 6 rule bullet is where a future agent will find the seam it has to widen.

### Processing flow after the change

```
startup (AppController.swift)  — deliberately single-window: it builds ONE new controller's cache
  loadKeymapAtStartup()
    reloadKeymapDiagnostics()                                  → this controller's caches, count
    keymapReloadToast(count:)                                  → banner only if count > 0

explicit reload (palette row · keymap.reload · Settings ▸ Reload · setConfigDirectory)
  reloadKeymapAllWindows(reportingIn: self)      // or nil, from the Settings button callback
    gWindows.values.map { $0.reloadKeymapDiagnostics() }.max() ?? 0   → every window's caches, one count
    keymapReloadToast(count:)                                  → error message, or nil when clean
    if let controller, let message { controller.showToast(…) }  → at most one banner, in the acting window
    → count
  Settings ▸ Reload ONLY: `if count == 0 { showToast("keymap.conf reloaded") }` at its own call site
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

> **Superseded by review.** The checkboxes below record what each task did WHEN IT RAN.
> A later review round revised three of those decisions — `keymapDiagnosticCount(_:)` was inlined back into
> the seam, `keymapReloadToast` lost its `isInitialLoad:` flag and now reports errors only (the Settings
> button keeps its own success confirmation), and startup calls a new `loadKeymapAtStartup()` wrapper so
> `AppController.swift` stays at its 1000-line swiftlint cap.
> A later code-smell round also split Task 5's `check_keymap_reload_fanout` in two — the error-banner +
> restore leg became its own `check_keymap_error_banner(app, env, first_title, second_title)` called from
> the same site — and dropped the redundant `config` parameter (it is derived from `env`).
> Where a checkbox and the "Key design decisions" section disagree, the decisions section is current.

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

- [x] change `Palette.swift:62` to `for cmd in keymap.commands {`
- [x] rewrite the comment above it (lines 59-61) to record the *why*: dispatch runs off this same cache, so
      the chord in the shortcut column is exactly the chord that fires, and edits land on Reload Keymap per
      README:679 — plus the macOS parity pointer (`agterm/AppActions+Palette.swift:132`)
- [x] delete `loadKeymapCommands()` from `AppControllerSurfaces.swift:220-223`
      — the function sat at `AppControllerSurfaces.swift:212-215` in the working tree; deleted there
- [x] grep the whole repo to confirm no reference to `loadKeymapCommands` survives
      — no `.swift`/`.py`/`.sh` hit remains; only this plan and the historical
      `docs/plans/completed/20260726-linux-palette-shortcut-column.md:444` record, both deliberately left
- [x] confirm no custom row *disappears*: a command whose shortcut cross-section validation cleared keeps its
      row with `shortcut == ""` (`KeymapDispatch.swift:90`), which `LinuxPaletteRow.custom` already renders
      chord-less via `linuxTrimmedOrNil` (`PalettePresentation.swift:98`)
      — re-verified: `parseKeymap` only assigns `commands[index].shortcut = ""`, it never removes the
      element, and the cached `keymap` holds that same parsed array
- [x] no unit test in this task: the change is a `@MainActor` read of controller state with no host-free
      logic to assert. Its behavioral coverage is the "must NOT appear before reload" leg of Task 5; the
      existing `PalettePresentationTests` already cover `LinuxPaletteRow.custom` and need no change
- [x] run tests + build: `cd agterm-linux && swift test`, `swift build --product AgtermLinux`
      — build clean; `swift test` = 133 tests / 17 suites with the single known-unrelated
      `IntegrationServiceTests.swift:765` failure, identical to the Task 1 baseline
- [x] **commit 1** here — this is the reviewer's ask, complete and reviewable on its own

### Task 3: Extract the reload count reduction and the toast wording

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/KeymapDispatch.swift`
- Modify: `agterm-linux/Tests/AgtermLinuxTests/LinuxKeymapTests.swift`

- [x] add file-level `func keymapDiagnosticCount(_ counts: [Int]) -> Int` to `KeymapDispatch.swift`
      (`counts.max() ?? 0`), commenting that identical per-window counts make `max()` a safe pick rather than
      an arbitrary one, and that `?? 0` is the empty-`gWindows` case
      — both helpers landed together right after `loadLinuxKeymap` (ends at line 93) and before
      `LeaderTimeoutContext`, so they sit with the keymap-loading logic rather than inside the
      `@MainActor extension AppController`
- [x] add file-level `func keymapReloadToast(count: Int, isInitialLoad: Bool) -> String?` implementing the
      four-case table above, reusing the existing `n == 1 ? "" : "s"` pluralization
      — written as `guard count > 0 else { return isInitialLoad ? nil : "keymap.conf reloaded" }` + the
      error string, so the two error rows of the table are one expression rather than two
- [x] doc-comment *why the wording helper exists*: two callers with divergent policy (the seam reloads,
      startup loads, and they disagree about what a clean result should say) — testability is the bonus, not
      the reason — and note that both are internal so the tests reach them
- [x] add a `@Suite("Linux keymap reload toast and count")` to the existing `LinuxKeymapTests.swift` (68
      lines, well under budget — no new file needed)
      — added as a second top-level `struct LinuxKeymapReloadToastTests` in the same file (a `@Suite` is a
      type, so it cannot nest inside the existing `LinuxKeymapTests` struct without changing that suite's
      name); file is now 126 lines
- [x] write tests for the explicit-reload wording: clean → `"keymap.conf reloaded"`, `n > 0` → the error
      wording, with singular/plural agreement at `n == 1` and `n == 2`
- [x] write tests for the initial-load wording: clean → `nil` (the edge case that keeps window-open quiet),
      `n > 0` → the error wording
      — also pins that the dirty wording is byte-identical across both `isInitialLoad` values
- [x] write tests for the reduction: `[]` → `0` (the empty-`gWindows` branch nothing else covers), one
      element, and disagreeing counts → the max
- [x] run tests — must pass before Task 4: `cd agterm-linux && swift test`
      — 141 tests / 18 suites (+8 new tests, +1 suite over Task 2's 133/17), with only the single
      known-unrelated `IntegrationServiceTests.swift:765` failure from the Task 1 baseline. No compiler
      warning for the as-yet-uncalled helpers (Task 4 wires them)

### Task 4: One app-wide reload seam, all four callers rewired

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/WindowManager.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/KeymapDispatch.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/AppController.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/Palette.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/ControlActions+AppController.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/SettingsKeyMappingPage.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/LinuxSettingsController.swift`

- [x] add `@MainActor func reloadKeymapAllWindows(reportingIn controller: AppController?) -> Int` to
      `WindowManager.swift` beside `ensureStarterFiles`/`flushOnQuit`/`openWindow`: map
      `reloadKeymapDiagnostics()` over `gWindows.values` → `keymapDiagnosticCount(_:)` →
      `keymapReloadToast(count:isInitialLoad: false)` → toast when both the message and the controller are
      non-nil → return the count
      — landed at `WindowManager.swift:134-138`, right before `openWindow`
- [x] comment the seam with why it exists (two of four hand-written fanouts fell behind) and why the
      controller is **optional** — `onReloadKeymapSettings` reloads unconditionally today and only
      optional-chains its toast, so a non-optional parameter would silently turn an unresolved button into
      "nothing reloads"
- [x] remove the `showToast` from `reloadKeymapDiagnostics()` (`KeymapDispatch.swift:146-149`), keeping the
      cache rebuild and the returned count, and doc-comment that the **caller** owns the toast
- [x] `AppController.swift:296`: keep the direct single-window `reloadKeymapDiagnostics()` (it is building
      one new controller's cache, not reloading the app) and toast from
      `keymapReloadToast(count:isInitialLoad: true)`, commenting why startup is deliberately not fanned out
      and why one dirty startup still toasts once per window opened
      — the call sat at `AppController.swift:287` in the working tree, not 296
- [x] `Palette.swift:122`: `case .reloadKeymap: return { _ = reloadKeymapAllWindows(reportingIn: self) }`
      — the arm sat at `Palette.swift:129` after Task 2's comment rewrite
- [x] `ControlActions+AppController.swift:560-563`: take the count from the seam, leaving the
      `ControlResponse(ok: true, result: ControlResult(count:))` shape byte-for-byte unchanged
      — only the one call line changed; the `ControlResponse(...)` line is untouched
- [x] `SettingsKeyMappingPage.swift:112-120`: pass `controllerForWidget(button)` straight into
      `reportingIn:` (no `guard`, so the fan-out keeps running when it is nil, exactly as today) and drop its
      own summary toast, which removes the current double-toast; keep `rebuildSettings(page: .keyMapping)`
- [x] `LinuxSettingsController.swift:136` (`setConfigDirectory`): route through the seam so a malformed
      `keymap.conf` in a newly-picked config dir banners ONCE instead of once per open window — comment
      that this is a banner-count reduction, NOT new reporting (the old loop already toasted per window),
      and that the Key Mapping page's Diagnostics group, not the toast, is what the user reads on this path
- [x] no unit test in this task: after Task 3's extraction the seam holds only `map` + `showToast` + `return`
      over live GTK controllers, unreachable from `AgtermLinuxTests`. Wording and reduction are covered by
      Task 3; the fanout behavior by Task 5
- [x] run tests + both builds — must pass before Task 5: `cd agterm-linux && swift test`,
      `swift build --product AgtermLinux`, `swift build --product agtermctl-linux`
      — both builds clean; `swift test` = 141 tests / 18 suites, unchanged from Task 3, with only the
      known-unrelated `IntegrationServiceTests.swift:765` failure. Task 3's helpers are now called
      (`keymapDiagnosticCount`/`keymapReloadToast` from the seam, `keymapReloadToast` from startup), and
      `reloadKeymapDiagnostics()` has exactly two direct callers left: startup and the seam

### Task 5: AT-SPI coverage for the cache fix and the fanout

**Files:**
- Modify: `agterm-linux/tests/atspi_smoke.py`

- [x] add `check_keymap_reload_fanout(app, process_id, env, config, first_title, second_title)` reusing
      `open_palette`, `palette_row_labels`, `press_escape`, and `control_json` — the two titles are **frame**
      titles (`command-origin-a` / `command-origin-b`, the session names), NOT the window name
      `command-window-b`; note that distinction in the docstring, since `open_palette` needs the frame title
      — landed at `atspi_smoke.py:562`; it carries a nested `filtered_rows(title, needle, sentinel, message)`
      helper that opens, filters, waits for a row that MUST be present, closes, and returns every row —
      the sentinel wait is what stops the absence assertions passing vacuously against a not-yet-filtered
      (empty) palette
- [x] in it: APPEND `command "Late Demo" ctrl+shift+y true` to the already-seeded `keymap.conf`, then open
      the palette in **each** window and assert no row titled `Late Demo` — this is the reviewer's fix, an
      unreloaded edit must not appear
      — the sentinel for that leg is the seeded `["Chorded Demo", "custom", "ctrl+shift+e"]` row
- [x] then `agtermctl keymap reload` via `control_json(env, "keymap", "reload", …)` and assert
      `["Late Demo", "custom", "ctrl+shift+y"]` appears in **both** windows' palettes — asserting both is
      what makes it independent of which controller the control server resolved, so it cannot pass
      trivially without the fanout
- [x] cover the **other** broken site too: append a second command, drive the palette's own `Reload Keymap`
      row in window A with the existing `run_palette_action(app, pid, first_title, "Reload Keymap")`
      (`atspi_smoke.py:508`), and assert the new row appears in window **B** — the control command and the
      palette row are two separate bugs (both marked BUG in the scope table) and the fixture is already there
      — the second command (`Palette Demo`) is deliberately CHORD-LESS (asserted as `["Palette Demo",
      "custom"]`): the chord column is already pinned by the `Late Demo` leg, and a second chord would need
      its own cross-section-validation argument to stay meaningful
- [x] comment why `ctrl+shift+y` specifically (free in the reserved-monitor set, the Linux default table,
      and the shared defaults — so validation will not clear its shortcut), mirroring the existing
      `ctrl+shift+e` note
- [x] call it from `verify_custom_command_failures` right after `check_palette_row_layout` (`atspi_smoke.py:1267`),
      where `wait_for(lambda: frame(...))` has already proven both frames exist — reusing that fixture
      rather than adding a scenario, so CI pays no extra app launch
      — the call site sits at `atspi_smoke.py:1361` after this task's insertion; it runs BEFORE the
      `shutil.rmtree` of the two cwds, so the later launch-failure legs are unaffected
- [x] verify the new `"keymap.conf reloaded"` toasts cannot **delay** the four toast assertions immediately
      downstream (`atspi_smoke.py:1276-1302`: the `launch_prefix` / `exit_message` checks and their negative
      cross-window leakage assertions). The risk is queueing, not text collision: `showToast`
      (`AppController.swift:825-828`) posts to an `AdwToastOverlay`, which shows one toast at a time, so a
      success toast can sit in front of the one those assertions wait for. `wait_for` defaults to
      `timeout=12` (`atspi_smoke.py:61`) against AdwToast's ~5 s display, so there is headroom — confirm it
      rather than assume, since this is the shape that would flake in CI rather than fail locally
      — **CONFIRMED, and hardened anyway.** Verified in the source rather than assumed: `showToast`
      (`AppController.swift:823-826`) builds a default `adw_toast_new` (priority NORMAL, timeout 5 s) and
      hands it to `adw_toast_overlay_add_toast`, whose NORMAL priority means QUEUE-behind, not
      dismiss-and-replace. This check produces at most TWO such toasts (the control reload + the palette
      reload), so the worst case is ~10 s of queue in front of the first `launch_prefix` toast, against
      `wait_for`'s 12 s deadline measured from a LATER instant (the palette work between the reloads and
      the failure command already burns part of the queue). Headroom exists but is thin, and thin margins
      are exactly what flake on a loaded CI runner — so the helper now ENDS by draining: a `wait_for`
      (timeout 20) until no accessible whose name starts with `keymap.conf` remains in either frame.
      That removes the queue interaction entirely instead of relying on the margin; no downstream timeout
      needed raising, and no assertion text collides (`keymap.conf …` vs `command failed …`)
- [x] confirm `check_palette_row_layout` and the existing `run_palette_action` calls still hold: that
      scenario writes `keymap.conf` before `launch(env)`, so startup's cache load already carries those rows
      — re-verified: the seed write is at `atspi_smoke.py:1323-1332`, `launch(env)` at 1333, and startup's
      `reloadKeymapDiagnostics()` (`AppController.swift:293`) populates the cache the palette now reads,
      so `Chorded Demo` / `Launch Failure` / `Exit Failure` / `Slow Failure` all render unchanged
- [x] mark clearly (in the PR body, not only here) that this scenario was **not executed locally** — no
      `Xvfb`/`openbox`/`xdotool` on this box — and that branch CI is what runs it
      — recorded here and in Post-Completion; the PR body still owes the same sentence
- [x] run what can run — must pass before Task 6: `python3 -m py_compile agterm-linux/tests/atspi_smoke.py`,
      `cd agterm-linux && swift test`
      — `py_compile` clean; `swift test` = 141 tests / 18 suites, unchanged from Task 4, with only the
      known-unrelated `IntegrationServiceTests.swift:765` failure. No Python linter is configured in this
      repo (no `ruff.toml`/`.flake8`/`pyproject.toml`/`setup.cfg` at the root or under `agterm-linux/`, and
      no CI job lints Python), so the new code was kept inside the file's existing ≤112-column budget by
      hand instead

### Task 6: Record the per-window-cache contract in the keymap rule

**Files:**
- Modify: `.claude/rules/keymap.md`

- [x] **extend the `paths:` frontmatter** (`keymap.md:2-11`, today macOS-only) with
      `agterm-linux/Sources/AgtermLinux/KeymapDispatch.swift`,
      `agterm-linux/Sources/AgtermLinux/Palette.swift`,
      `agterm-linux/Sources/AgtermLinux/LinuxKeyboardPolicy.swift`, and
      `agterm-linux/Tests/AgtermLinuxTests/LinuxKeymapTests.swift` — without this the new note never loads
      when a future agent opens the very files it binds (only `main-loop.md` globs `agterm-linux/**` today).
      `theme-picker.md` and `control-api.md` already precedent per-file Linux path additions
      — all four appended after `agtermUITests/KeymapUITests.swift` in the existing quoted-string style.
      Note: this branch predates `main-loop.md`, so `control-api.md` is the ONLY Linux precedent present in
      the worktree (`theme-picker.md` here is still macOS-only); its style was followed
- [x] add a bullet: on Linux the parsed keymap is cached **per window controller**, so every explicit reload
      must go through `reloadKeymapAllWindows(reportingIn:)`; the bug existed because each call site
      hand-wrote its own `gWindows` fanout and two of the four fell behind
      — added right after the existing "Reload + control" bullet, so the macOS one-path statement is
      immediately followed by the Linux divergence; names all four routed sites and the
      `keymapDiagnosticCount(_:)` reduction, and is worded to CATCH the latent fifth site (README's Edit
      Keymap save-and-quit reload, unimplemented on Linux — `editKeymap()` only opens the overlay), which
      must call the seam rather than hand-write another `gWindows` loop
- [x] note in the same bullet that startup is deliberately single-window, that the toast belongs to the
      caller (`keymapReloadToast`) not to `reloadKeymapDiagnostics()`, and that the controller parameter is
      optional to preserve the Settings button's unconditional fan-out
      — written as the "three details the seam depends on" run, plus the palette's cached-`keymap.commands`
      read and the internal-not-`private` helper visibility that lets `LinuxKeymapTests` reach them
- [x] use semantic line breaks — one sentence per line, per the root `CLAUDE.md` convention for these notes
- [x] no test: documentation only
- [x] run tests — must pass before Task 7: `cd agterm-linux && swift test`
      — 141 tests / 18 suites, unchanged from Tasks 3-5, with only the known-unrelated
      `IntegrationServiceTests.swift:765` failure from the Task 1 baseline
- [x] **commit 2** here (Tasks 3-6 together: the two host-free helpers, the seam, the callers, the AT-SPI
      assertions, and this note)
      — Tasks 3, 4, and 5 already landed as their own commits (`f83216a`, `428d4c8`, `e17237c`) and this
      note commits on top; SQUASHING the four into the single commit 2 is DEFERRED to the finalize phase,
      which owns history rewriting. No commit was rewritten here

### Task 7: Verify acceptance criteria

- [x] the palette's custom rows come from `keymap.commands`; `loadKeymapCommands` no longer exists anywhere
      — `Palette.swift:69` is `for cmd in keymap.commands {`, under the 7-line why-comment at
      `Palette.swift:62-68` (cache = what dispatch runs off; README:679; macOS parity pointer).
      A repo-wide `grep -rn loadKeymapCommands . --exclude-dir=.git --exclude-dir=.build` returns
      **zero code hits**: every hit is markdown — 10 in this plan file and
      `docs/plans/completed/20260726-linux-palette-shortcut-column.md:444` (a historical completed-plan
      record, deliberately left per Task 8). No `.swift`/`.py`/`.sh` hit remains
- [x] all four explicit-reload sites call `reloadKeymapAllWindows`; `reloadKeymapDiagnostics()` has exactly
      one remaining direct caller (startup) plus the seam
      — the four sites, all `reloadKeymapAllWindows(reportingIn:)`:
      `SettingsKeyMappingPage.swift:119` (Settings ▸ Reload, `reportingIn: controller`),
      `Palette.swift:127` (`case .reloadKeymap`, `reportingIn: self`),
      `ControlActions+AppController.swift:559` (`keymap.reload`, `reportingIn: self`),
      `LinuxSettingsController.swift:142` (`setConfigDirectory`, `reportingIn: self`).
      Grepping `reloadKeymapDiagnostics` over the tree enumerates **every** hit: the declaration
      (`KeymapDispatch.swift:156`), two doc-comment mentions (`KeymapDispatch.swift:151-152`,
      `Palette.swift:63`), and exactly TWO call sites — `AppController.swift:293` (startup) and
      `WindowManager.swift:135` (inside the seam). No third caller anywhere
- [x] at most one toast per explicit reload (none when no controller resolved), none on a clean startup, and
      one per window-open on a dirty startup — that last one is deliberately per-window and unchanged from
      today, since startup builds one controller's cache rather than reloading the app
      — read out of the code, not assumed. `grep -n showToast KeymapDispatch.swift` → **no hit**, so the
      fanned-out per-window rebuild cannot toast at all (`reloadKeymapDiagnostics()`, lines 156-176, ends
      at `return diagnostics.count` with no UI call).
      Exactly two `showToast` call sites exist across the whole reload surface:
      `WindowManager.swift:136` — `if let message = keymapReloadToast(count: count, isInitialLoad: false)
      { controller?.showToast(message) }`, a SINGLE statement outside the `map`, so an N-window fanout
      still produces at most ONE toast, and the optional-chain makes it ZERO when the controller is nil;
      and `AppController.swift:294` — `if let message = keymapReloadToast(count: keymapDiagnostics,
      isInitialLoad: true) { showToast(message) }`, once per window construction.
      Clean startup is silent by the helper's own first line (`KeymapDispatch.swift:115`:
      `guard count > 0 else { return isInitialLoad ? nil : "keymap.conf reloaded" }` → `nil` for
      `(0, true)`), so the `if let` never fires; a DIRTY startup returns the error string and toasts once
      per window opened, which the comment at `AppController.swift:287-292` calls out as deliberate
- [x] the Settings ▸ Reload button still reloads every window even when `controllerForWidget(button)`
      resolves nil — the optional `reportingIn:` is what preserves that
      — `SettingsKeyMappingPage.swift:112-122` contains **no `guard` and no early `return`**: it binds
      `let controller = controllerForWidget(button)` (line 118) and passes it straight in on line 119, so
      the fan-out runs unconditionally; only line 120's `controller?.rebuildSettings` and the seam's own
      `controller?.showToast` are optional-chained. Inside the seam
      (`WindowManager.swift:135`) the `gWindows.values.map { … }` runs BEFORE the controller is ever
      consulted, so a nil controller can only cost the toast, never the reload
- [x] `keymap.reload` still returns the diagnostic count with an unchanged response shape
      — `git diff origin/linux-palette-shortcut-column --
      agterm-linux/Sources/AgtermLinux/ControlActions+AppController.swift` shows the ONLY `-`/`+` pair is
      the call line (`reloadKeymapDiagnostics()` → `reloadKeymapAllWindows(reportingIn: self)`), plus 3
      added comment lines. The line
      `return ControlResponse(ok: true, result: ControlResult(count: diagnostics))` is **context, not a
      diff hunk** — byte-for-byte untouched. No `Command` case, argument, or `ControlResult` field changed
- [x] run the full suites: `cd agtermCore && swift test`; `cd agterm-linux && swift test` — green except the
      two known-unrelated pre-existing failures recorded in Task 1's baseline
      — `agtermCore`: **1733 tests in 74 suites, 1 failure** —
      `CodexStatusHookTests.stopReportsBlockedWhenAssistantMessageEndsInQuestionMark`
      (`CodexStatusHookTests.swift:102`). That is the deterministic baseline failure; the INTERMITTENT
      `watcherIgnoresAutoReviewProgress` did not fire this run, so the count landed on the low end of the
      baseline's "1 OR 2". No failure name outside the baseline set.
      `agterm-linux`: **141 tests in 18 suites, 1 failure** — `"Linux integration service"` ▸ `"Flatpak
      process environments do not offer a host launcher"` (`IntegrationServiceTests.swift:765`), the
      recorded baseline failure. Test/suite counts unchanged from Tasks 3-6 (141/18)
- [x] run both builds: `swift build --product AgtermLinux`, `swift build --product agtermctl-linux`
      — both `Build of product '…' complete!`, zero errors and zero Swift warnings (the only noise is the
      pre-existing `prohibited flag(s): -pthread…` C-flag warning and the toolchain's
      `libxml2.so.2: no version information available` linker note, both present on the Task 1 baseline)
- [x] run `scripts/check-linux-cli-drift.sh` and `git diff --check`
      — the script EXISTS at `scripts/check-linux-cli-drift.sh` (absolute:
      `<worktree>/scripts/check-linux-cli-drift.sh`); it ran with **exit 0 and no output**.
      `git diff --check` also exit 0, no whitespace/conflict findings. `git status --porcelain` shows only
      the untracked `?? agterm-linux/vendor` symlink, which is the Task 1 worktree setup and never committed
- [x] state explicitly in the PR that `scripts/test-linux-ui.sh` and `swiftlint lint --strict` did NOT run
      locally (tooling absent) and that branch CI covers them — do not imply they passed
      — recorded here, in Testing Strategy, and in Post-Completion; **the PR body still owes the same
      sentences.** To be stated WITHOUT any implication that they passed:
      `swiftlint lint --strict` **DID NOT RUN** — swiftlint is not installed on this machine
      (`command -v swiftlint` → nothing). Its result is UNKNOWN; branch CI's `lint` job is the first
      thing that will actually evaluate it.
      `scripts/test-linux-ui.sh` **DID NOT COMPLETE** — it was attempted here and ABORTED during
      environment bring-up with `FAIL: agterm app not present in the AT-SPI tree`, because
      `at-spi2-core 2.60.5` activates `org.a11y.atspi.Registry` via a systemd user unit that
      `dbus-run-session` cannot reach on this box. It aborted BEFORE any scenario ran, so the new
      `check_keymap_reload_fanout` assertions have NEVER been executed anywhere yet; branch CI is their
      first real execution and could still fail. See the ⚠️ correction in Testing Strategy — the plan's
      original "no Xvfb/openbox/xdotool" reason was factually wrong and must not be repeated in the PR
- [x] confirm the keep-in-sync ledger below still holds after implementation
      — all seven re-checked against `git diff --stat origin/linux-palette-shortcut-column`, whose entire
      file list is: `.claude/rules/keymap.md`, seven `agterm-linux/Sources/AgtermLinux/*.swift`,
      `agterm-linux/Tests/AgtermLinuxTests/LinuxKeymapTests.swift`, `agterm-linux/tests/atspi_smoke.py`,
      and this plan. (1) **No control command owed** — no `ControlProtocol`/`agtermctl*`/agent-skill file
      in the diff, and the `ControlResult(count:)` line is provably untouched (see above). (2) **`site/`
      untouched** — absent from the diff; the fanout makes Linux MATCH `site/commands.html:1808`, so
      editing it would weaken shipped docs. (3) **No `tree` read-back owed** — nothing sets per-session
      state; no `ControlSessionNode` field added or changed. (4) **No Settings ▸ Interface toggle** —
      nothing hideable added; the shortcut column already shipped in `16b9a04`. (5) **`README.md`
      unchanged** — absent from the diff. (6) **`CHANGELOG.md` untouched** — absent from the diff.
      (7) **`.claude/rules/keymap.md` gains one bullet AND four `paths:` entries** — +45 lines; the
      frontmatter now carries `KeymapDispatch.swift`, `Palette.swift`, `LinuxKeyboardPolicy.swift`, and
      `LinuxKeymapTests.swift` (`keymap.md:10-13`), and the new bullet (`keymap.md:194-234`) states the
      per-window cache, the seam, all four routed sites, the latent fifth (`editKeymap()`), the
      single-window startup, the caller-owned toast, and the optional `reportingIn:`.
      All seven hold; no ⚠️ needed on the ledger itself

### Task 8: [Final] Update documentation

- [x] `README.md`: no change needed — line 679 already lists the three reload entry points without claiming
      per-window scope. Re-read it and confirm rather than assume
      — **prediction CONFIRMED, and the line number did NOT drift this time**: `awk 'NR==679'` lands on the
      sentence, which reads "After editing the file, apply it with **File ▸ Reload Keymap**, the action
      palette (⌃⇧P → \"Reload Keymap\"), or `agtermctl keymap reload`." — three entry points, zero mention
      of a window, so nothing there described the pre-fix per-window behavior and nothing needs rewording
      now that reload is app-wide. A repo-wide sweep for a per-window claim found none: the only other
      reload mentions are `README.md:419` (Settings ▸ Key Mapping "can open or reload `keymap.conf`" — the
      FOURTH entry point, documented separately, also window-free) and `README.md:677` (Edit Keymap
      "reloads automatically when you save and quit"). Neither is scope-qualified.
      `git diff --stat origin/linux-palette-shortcut-column -- README.md` is EMPTY — README stays untouched,
      as the keep-in-sync ledger asserts
- [x] `CLAUDE.md`: no new cross-subsystem pattern; the note belongs in `.claude/rules/keymap.md` (Task 6).
      Re-confirm nothing at the root level needs it
      — **the stated prediction holds**: the per-window-cache + app-wide-seam contract is a Linux
      subsystem implementation detail, not a cross-subsystem keep-in-sync convention, so it does NOT
      belong in the root "Keep-in-sync conventions (HARD)" or "Module boundary" sections; it stays in
      `.claude/rules/keymap.md:194-234` where Task 6 put it. Re-read every root section to confirm: no
      new control command (so the four-point rule is untouched), no session-state write (no `tree`
      read-back rule), no new chrome (no Interface-toggle rule), no `agtermCore` boundary change.
      NOTE: this branch's `CLAUDE.md` differs from the main checkout's `linux-port-wip` copy — it has NO
      `main-loop.md` index bullet, which is consistent, since `ls .claude/rules/` on this branch shows
      13 rules and `main-loop.md` is not among them. Nothing owed there either.
      **[deviation] ONE minimal edit made anyway**, at `CLAUDE.md:470-471`: the subsystem-index bullet's
      "Triggers on …" clause is a summary of `keymap.md`'s `paths:` frontmatter, and before Task 6 it
      enumerated exactly the 8 frontmatter entries. Task 6 added 4 Linux entries
      (`KeymapDispatch.swift`, `Palette.swift`, `LinuxKeyboardPolicy.swift`, `LinuxKeymapTests.swift`),
      leaving the root index stale — a reader consulting the index (which CLAUDE.md says exists for
      exactly that, "consult this index and open the rule yourself") would not learn that `keymap.md`
      now governs Linux keymap files. So the clause gained
      "the Linux `KeymapDispatch`/`Palette`/`LinuxKeyboardPolicy` sources, and the keymap UI +
      `LinuxKeymapTests` tests". This is drift caused BY this branch, not new content: no new pattern,
      no new rule, semantic line breaks preserved, one bullet touched. Conflict risk against
      `linux-port-wip` is nil — its copy of this bullet is byte-identical to the pre-edit text here
- [x] leave `docs/plans/completed/20260726-linux-palette-shortcut-column.md:444` alone — it mentions the
      deleted `loadKeymapCommands()` but is a historical completed-plan record
      — **confirmed untouched**: `git diff --stat origin/linux-palette-shortcut-column -- docs/plans/completed/`
      returns NO output at all (exit 0, zero files), across every commit on this branch, not just the
      working tree. The file still carries its original text at lines 444-446 ("`loadKeymapCommands()`
      (`AppControllerSurfaces.swift:212-215`) returns the parsed `CustomCommand`s…"), which is correct as
      a record of what was true when that plan completed. It is deliberately NOT updated: a completed
      plan is an archive of the work as executed, not a live doc that tracks later refactors
- [x] move this plan to `docs/plans/completed/` (`mkdir -p docs/plans/completed` if needed)
      — **deferred to the orchestrator's end-of-run move**, so the review phases can still read the plan
      at its current path for intent. No `docs/plans/completed/` creation and no `git mv` performed here;
      the directory already exists regardless (it holds the 20260726 record above)

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
  No Linux-specific parity doc exists to update either (`agterm-linux/docs/` holds only `x11-wayland.md`
  on this branch — an earlier draft of this ledger also claimed a `main-loop.md` there, which does not
  exist here; the conclusion is unaffected).
- **`CHANGELOG.md` untouched** — release-only, never in a feature/fix PR.
- **`CLAUDE.md` gains no new pattern, only an index sync** (Task 8).
  The per-window-cache contract stays in `.claude/rules/keymap.md`; the root file's one-line
  subsystem-index entry for `keymap.md` is re-synced with the four `paths:` entries Task 6 added, so the
  index does not under-report what the rule now covers.
- **`.claude/rules/keymap.md` gains one bullet AND four `paths:` entries** (Task 6) — the per-window-cache +
  app-wide-seam contract, plus the frontmatter fix without which the note would never load on Linux files.

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Branch CI (the two checks that cannot run on this machine)**

- `scripts/test-linux-ui.sh` / the AT-SPI suite, including the new `check_keymap_reload_fanout` assertions
  and the `run_palette_action` calls in the scenario it extends.
  Task 7 ATTEMPTED it (every dependency the script preflights is installed here — the plan's original
  "no `Xvfb`/`xvfb-run`/`openbox`/`xdotool`" claim was wrong) and it aborted at
  `FAIL: agterm app not present in the AT-SPI tree`: `at-spi2-core 2.60.5` activates
  `org.a11y.atspi.Registry` through a systemd user unit that `dbus-run-session` cannot reach on this box,
  so the accessibility tree comes up empty before any scenario runs.
  CI is therefore the FIRST place the new assertions execute at all — treat a failure there as untested
  new code, not as a regression.
- `swiftlint lint --strict` — swiftlint is not installed here (`command -v swiftlint` → nothing).
- Push to `origin linux-palette-shortcut-column` and wait for all four checks on PR #7 before asking for
  re-review.

**PR #7 follow-through**

- Reply to melonamin's review comment: the palette now reads cached `keymap.commands` as asked (commit 1,
  readable on its own), and the second commit fixes the adjacent per-window reload-scope bug the
  investigation turned up — quoting `site/commands.html:1808` and `.claude/rules/control-api.md:1077`, which
  already document `keymap.reload` as app-global, so this is the port catching up to shipped docs rather than
  new scope. Include the before/after scope table.
- Offer to drop commit 2 into a follow-up PR if the reviewer would rather keep this one to the one-line ask.
- Mention the two user-visible changes the review comment does not imply: `setConfigDirectory` now banners
  keymap parse errors ONCE instead of once per open window (it already reported — the old `gWindows` loop
  toasted inside every `reloadKeymapDiagnostics()`; do not describe this as newly-added reporting, and note
  that the Key Mapping page's Diagnostics group is what the user actually reads there, since the toast lands
  under the Settings dialog), and the Settings ▸ Reload ERROR
  wording changes from `"keymap.conf: N diagnostic(s)"` to `"keymap.conf: N error(s) — bad line(s) ignored"`
  (one wording everywhere, and its double-toast is gone; its `"keymap.conf reloaded"` success confirmation
  is unchanged).
  Everything else keeps its pre-change reporting: `agtermctl keymap reload` and the palette's
  `Reload Keymap` row stay SILENT on a clean reload, matching macOS.

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
- Confirm a malformed `keymap.conf` produces exactly one banner per explicit reload, not one per open
  window, and no banner at all on a clean app launch or a clean `agtermctl keymap reload`. (A *dirty* launch
  still banners once per window opened — that is unchanged and intended.)
