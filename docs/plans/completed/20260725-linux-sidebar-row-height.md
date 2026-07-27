# Fix: sidebar font size does not change session row height (Linux port)

## Overview

- Changing Settings → Appearance → Sidebar font size rescales the row *text* in the
  workspace/sessions sidebar, but the row height never changes: libadwaita pins
  `navigation-sidebar` rows at `min-height: 36px`, so smaller text does not densify rows.
  (⚠️ CORRECTED in review: the "larger text gets no more room" half of this premise was
  never true — `min-height` is a floor, so 18–20 pt rows already grew past 36 px before
  this change. Only the densification half was broken.)
  On macOS the same setting scales row height via
  `NSOutlineView.rowHeight = AppSettings.sidebarRowHeight(fontSize:)`.
- Fix: extend the CSS emitted by `applySidebarFontSize()` to override the Adwaita
  `min-height` floor, deriving the height from the existing core helper
  `AppSettings.sidebarRowHeight(fontSize:)` — floors of 13 pt → 28 px, 9 pt → 24 px,
  20 pt → 35 px. The name label keeps its 4 px vertical margins, so at 13 pt the
  rendered height is ~30 px (content sits just above the floor); at 9 pt the 24 px
  floor governs.
  (Measured in Task 4 on this box, Cantarell: **32 px at 13 pt, 25 px at 9 pt** — the
  label line box is a couple of pixels taller than predicted, so both sizes come out
  content-driven just above their floor. Still 4 px under Adwaita's 36 px pin at the
  default and 11 px under it at 9 pt.)
- The CSS derivation moves into a pure `LinuxSidebarPolicy` function so it gets real
  unit coverage, matching the port's "logic host-free, side effects thin" convention.
- Keep-in-sync verdict (recorded so it isn't relitigated): no control command is owed —
  `sidebarFontSize` has no `Command` case in the Linux port or upstream — and no
  Settings ▸ Interface toggle (this fixes an existing setting, adds no chrome).

## Context (from discovery)

- Files involved:
  - `agterm-linux/Sources/AgtermLinux/AppControllerSidebar.swift` —
    `applySidebarFontSize()` (lines 42–55) emits only
    `.agterm-sidebar label { font-size: Xpt; }` into a reloadable CSS provider
    (priority 651); `makeRow` (lines 185+) gives the name label 4 px top/bottom margins;
    session rows are `GtkListBoxRow`s in a `navigation-sidebar` list box (line 163).
  - `agterm-linux/Sources/AgtermLinux/LinuxSidebarPolicy.swift` — existing host-testable
    policy enum (imports `agtermCore` only), new function's home.
  - `agterm-linux/Tests/AgtermLinuxTests/LinuxPolicyTests.swift` — Swift Testing suite
    "Linux-owned policy and adapters", already tests `LinuxSidebarPolicy`.
  - `agtermCore/Sources/agtermCore/AppSettings.swift` — `sidebarRowHeight(fontSize:)`
    (= `clampSidebarFontSize(size).rounded() + 15`, line 436), `clampSidebarFontSize`
    (9…20), `defaultSidebarFontSize` (13). Already tested in core; NOT modified here.
- libadwaita 1.9.2 theme rule being overridden:
  `.navigation-sidebar > row { border-radius: 9px; min-height: 36px; padding: 0 8px; margin: 0 6px 2px; }`.
  CORRECTED in review: this is the ONLY row-height pin that reaches this widget tree.
  The plan originally listed a second rule,
  `.navigation-sidebar > row > box { padding: 3px 14px; min-height: 36px; … }`,
  but the extracted stylesheet (`gresource extract /usr/lib/libadwaita-1.so.0 /org/gnome/Adwaita/styles/gtk.css`)
  shows it exists only as `sidebar .navigation-sidebar > row > box`, scoped to an AdwSidebar `sidebar` NODE
  ancestor.
  The port's tree is
  `scrolledwindow.agterm-sidebar > viewport > box > listbox.navigation-sidebar > row > box` — no `sidebar`
  node — so that rule never applied, and the inner-box override this plan called for was inert CSS.
  It was removed in the review fix.
- Decisions made in brainstorm (do not relitigate):
  - macOS-parity density: default rows get denser than today's 36 px (28 px floor at
    13 pt; ~30 px rendered with the kept margins) — intended, not a regression.
  - Workspace header rows stay content-driven (plain `GtkBox`es, not theme-pinned;
    their buttons keep Adwaita click-target size). CSS scopes to
    `.agterm-sidebar .navigation-sidebar > row` only.
  - REVERSED (2026-07-26, user decision): the label's 4 px top/bottom margins STAY —
    `makeRow` is not touched. Consequence, accepted: at 13 pt the label line (~22 px)
    plus 8 px margins ≈ 30 px slightly exceeds the 28 px floor, so default rows render
    ~30 px rather than macOS's exact 28 (still far denser than the old 36 px pin). At
    9 pt content sits below the floor, so 24 px governs exactly.

## Development Approach

- **testing approach**: Regular (code first, then tests, same task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- maintain backward compatibility (CSS provider identity/priority unchanged; settings
  schema untouched)

## Testing Strategy

- **unit tests**: new `@Test` in `LinuxPolicyTests.swift` covering the emitted CSS
  (success + clamp/nil edge cases). Assert via string-contains on the three rules, not
  full-literal equality, so formatting tweaks don't break tests.
- **e2e/UI**: a NEW AT-SPI scenario is added — row pixel heights ARE observable
  (`atspi_smoke.py` already reads `component.get_extents(...)` and finds session rows
  via `collect(app, role="list item")`, and several scenarios already seed
  `settings.json` in `AGTERM_STATE_DIR` before `launch(env)`). The scenario launches
  with default settings and asserts a session row's extent height is in `28 <= h < 36`
  (32 px measured; the old 36 px pin defeated), then relaunches with seeded
  `{"sidebarFontSize": 9}` and asserts `h >= 24` plus strictly less than the default
  height — proving row height follows the setting end-to-end without coupling to font
  metrics. Visual polish (selection rounding, glyph fit) stays a manual pass
  (Post-Completion).
  ⚠️ REVISED in review: the seeded pass's upper cap (`h <= 26`, tuned to this box's
  Cantarell metrics) was DROPPED — it is the most likely false CI failure, and
  `h >= 24` (the CSS floor) plus `h < default_height` already carry both claims. A
  THIRD pass seeded `{"sidebarFontSize": 20}` was added, asserting `h >= 35` and
  `h > default_height`, so the "min-height is a floor, not a cap / larger text gets
  more room" half is covered end-to-end too.
- The existing AT-SPI suite is also affected: CI's `build-linux` job runs
  `scripts/test-linux-ui.sh` on every push to `linux-port`, and existing scenarios
  click sidebar rows by pointer at AT-SPI extents — this change alters exactly that
  geometry, and there is no PR gate on this branch. Run the suite locally before
  pushing (deps: `dbus-run-session`, `openbox`, `xdotool`, `xvfb-run`, python
  `gi`/`Atspi`); if a dep is missing, note it here and explicitly accept CI as the
  gate.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

- New pure function `LinuxSidebarPolicy.sidebarCSS(fontSize: Double?) -> String`
  (no `@MainActor` — touches no store): clamps via `AppSettings.clampSidebarFontSize`
  (nil → `defaultSidebarFontSize`), derives
  `rowHeight = Int(AppSettings.sidebarRowHeight(fontSize:))`, returns two rules:

  ```css
  .agterm-sidebar label { font-size: <size>pt; }
  .agterm-sidebar .navigation-sidebar > row { min-height: <rowHeight>px; }
  ```

  (The plan originally specified a third `> row > box` rule; review proved it inert — see Context — and
  it was removed.)

- `applySidebarFontSize()` becomes a thin loader: keep the
  `guard let display = gdk_display_get_default() else { return }` early return, load
  settings, call the policy, feed the existing reloadable provider. Provider creation
  and priority 651 untouched.
- Font-size formatting is pinned: keep `\(size)pt` interpolation verbatim (emits
  `13.0pt` today) — do not "tidy" to `Int(size)`; the test asserts the exact substring.
- `makeRow` is untouched — the label keeps its 4 px vertical margins (reversed
  decision, see Context).
- `min-height` is a floor, not a cap: wherever the label's natural height plus the
  8 px margins exceeds the floor (≈30 px at 13 pt, more at 18–20 pt), the row grows —
  that is the desired "larger text gets more room" behavior; at small sizes the floor
  delivers the densification.

## Technical Details

- Height mapping (`round(size) + 15`): 9 → 24, 13 → 28, 18 → 33, 20 → 35 (today: all
  36). These are CSS floors; the rendered height is effectively
  max(floor, label line height + 8 px margins).
- ⚠️ CORRECTED in review: `padding-top/bottom: 0` on the inner box is NOT required and
  was removed. Adwaita's 3 px vertical box padding lives in the AdwSidebar-scoped
  `sidebar .navigation-sidebar > row > box` rule, which never matches this port's
  widget tree. The unscoped row rule sets `padding: 0 8px` (horizontal only), left to
  the theme.
- Flagged risk (visual pass covers it): interaction of the lowered row `min-height`
  with the selection-highlight rounding (`border-radius: 9px`) at small sizes, given
  the port already mirrors selection into an explicit class to work around
  `navigation-sidebar` paint quirks.
- ⚠️ Selector choice moot after the review correction above: no inner-box rule is
  emitted at all, so `makeRow`'s `agterm-session-row-content` tag stays unused (it is
  pre-existing and was left alone).

## What Goes Where

- **Implementation Steps**: code, tests, doc updates in this repo.
- **Post-Completion**: manual visual verification in the running app; upstream
  reporting; AUR release flow.

## Implementation Steps

### Task 1: Verify toolchain and vendored libghostty, baseline build

**Files:**
- none (environment verification)

- [x] verify `agterm-linux/vendor/ghostty/lib/libghostty.so` and
      `vendor/ghostty/include/ghostty.h` exist (background `scripts/setup-linux.sh`
      from this session — task `bi561r3jb` — must have completed; re-run the script if
      not: it is idempotent)
      — both present in the worktree (`libghostty.so` 32 MB, `ghostty.h` 36 KB); no
      re-run needed
- [x] baseline build:
      `cd agterm-linux && PATH="$HOME/.local/share/mise/installs/swift/6.3.2/usr/bin:$PATH" LD_LIBRARY_PATH="$HOME/.local/share/swift-linux-compat" swift build`
      — `Build complete! (27.36s)`, no warnings
- [x] baseline tests: same env, `swift test` — record any pre-existing failures so the
      fix isn't blamed for them
      — 118 tests / 16 suites, **1 pre-existing failure** unrelated to this fix:
      ⚠️ `Linux integration service` ▸ "Flatpak process environments do not offer a host
      launcher" (`Tests/LinuxIntegrationsTests/IntegrationServiceTests.swift:765`) —
      `status()[.commandLineTool]?.state` resolves to `.installed` instead of
      `.unavailable` on this box (host-environment sensitive: a real `agtermctl` is
      installed here). Everything else green. Treat this one failure as the baseline;
      the sidebar work must not add any new failure.
      (This baseline covers only the `agterm-linux` package. Task 5's `agtermCore`
      run surfaced a SECOND pre-existing host-induced failure — GNUstep's `plutil`
      shadowing the hook's macOS probe — recorded there.)

### Task 2: Add `LinuxSidebarPolicy.sidebarCSS(fontSize:)` with tests

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/LinuxSidebarPolicy.swift`
- Modify: `agterm-linux/Tests/AgtermLinuxTests/LinuxPolicyTests.swift`

- [x] add `static func sidebarCSS(fontSize: Double?) -> String` to
      `LinuxSidebarPolicy`: clamp (nil → default), derive row height via
      `AppSettings.sidebarRowHeight`, emit the three rules from Solution Overview
      — added as a non-`@MainActor` static (touches no store), emitting the three
      rules verbatim from a multi-line string literal
- [x] write ONE thematic `@Test` (matching the suite's grouped style, e.g.
      "sidebar CSS derives row height from the shared font-size clamp") with
      `#expect`s covering: 13 pt → `font-size: 13.0pt` + both `min-height: 28px`
      rules; 9 → 24 px; 20 → 35 px; nil → the 13 pt/28 px default; out-of-range
      clamps (40 → the 20 pt/35 px CSS)
      — added `func sidebarCSS()` to `LinuxPolicyTests`; nil and the 40/2 clamps are
      asserted as whole-string equality against the 13/20/9 pt CSS, which is stricter
      than a substring check and needs no duplicated literals
- [x] in the same test, assert the load-bearing selectors verbatim:
      `"> row { min-height: 28px;"` (uniquely pins the row rule — a bare `"> row "`
      substring would also match the box rule) and
      `".agterm-sidebar .navigation-sidebar > row > box"` with
      `"padding-top: 0"` — not just the pixel values
      — [decision] the row-rule assertion uses the full
      `".agterm-sidebar .navigation-sidebar > row { min-height: 28px; }"` (closing
      brace included) instead of the plan's open-ended prefix: the trailing `}` is
      what makes it unambiguously the row rule rather than the box rule, and the
      full-selector form documents the Adwaita rule being overridden
- [x] run tests — must pass before task 3
      — 119 tests / 16 suites; the new test passes; the ONLY failure is the recorded
      Task-1 baseline (`Flatpak process environments do not offer a host launcher`)

### Task 3: Wire the policy into the controller

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/AppControllerSidebar.swift`

- [x] replace `applySidebarFontSize()`'s clamp + CSS literal with
      `LinuxSidebarPolicy.sidebarCSS(fontSize: settings.sidebarFontSize)` (provider
      creation/priority 651 unchanged; `makeRow` and its label margins untouched)
      — the two `let size` / `let css` lines collapse to a single
      `let css = LinuxSidebarPolicy.sidebarCSS(fontSize: settings.sidebarFontSize)`;
      the `guard let display` early return, the provider creation, priority 651, and
      the `withCString`/`gtk_css_provider_load_from_string` load are all untouched.
      The clamp now happens once, inside the policy. `import agtermCore` stays — the
      file still uses `AppSettings`/`Session` elsewhere (`appendSection`,
      `updateAttentionButton`)
- [x] full build of both products (`swift build`) — compiles clean
      — `Build complete! (3.22s)`, no warnings
- [x] run `swift test` — the Task 2 tests plus the whole suite must pass
      — 119 tests / 16 suites; only the recorded Task-1 baseline failure
      ("Flatpak process environments do not offer a host launcher",
      `IntegrationServiceTests.swift:765`) — no new failure
- [x] `swiftlint lint --strict` over the tree if swiftlint is available; if not
      installed, apply the manual substitutes CI would catch (`git diff --check` for
      whitespace; new lines under the 200-col `line_length` limit) and note the skip
      here
      — [deviation] swiftlint is NOT installed on this box (`which swiftlint` →
      not found), so the manual substitutes were applied instead: `git diff --check`
      clean (no trailing/whitespace errors), no line in either touched file exceeds
      200 columns (longest is well under), and both files stay far under the 1000-line
      `file_length` cap (`AppControllerSidebar.swift` 375, `LinuxSidebarPolicy.swift`
      29). The change is a net *reduction* of one line, so no size limit moves

### Task 4: Add AT-SPI scenario asserting row height follows the font size

**Files:**
- Modify: `agterm-linux/tests/atspi_smoke.py`

- [x] add scenario `verify_sidebar_row_height_follows_font_size(env)` modeled on
      `verify_surface_configuration_lifetimes` (the launch → stop → seed → relaunch
      shape; it seeds state files between two launches — closer than the
      single-launch `verify_notification_focus_policy`): launch with default
      settings, find a session row via `collect(app, role="list item")`, read its
      height with this harness's GI binding — `node.get_component_iface()` then
      `component.get_extents(Atspi.CoordType.WINDOW)` (WINDOW, not SCREEN: SCREEN
      reports a 0,0 origin under Wayland; do NOT reach for pyatspi
      `queryComponent()` idioms)
      — added above `verify_preferences_pages`; the local `settled_row_height(app)`
      helper walks every `list item` and returns the first settled extent
- [x] poll for a settled extent before asserting — a11y nodes can appear before first
      allocate and report height 0 (the harness's own `mouse_click` polls up to 8 s
      for stable bounds for exactly this reason): `wait_for(lambda: h(row) > 1, …)`
      in BOTH launches, then assert
      — `settled_row_height` returns `None` for anything `<= 1` so `wait_for` keeps
      polling and hands back the settled height directly (no second read that could
      race the first); used in both launches
- [x] assertions: default launch `28 <= h < 36` (floor respected, Adwaita's 36 px pin
      defeated; ~30 expected with the kept 8 px label margins); `stop(process)`;
      write `{"sidebarFontSize": 9}` to `settings.json` in `AGTERM_STATE_DIR`,
      relaunch, assert `24 <= h <= 26` AND `h < default_h` — the `>= 24` bound is the
      load-bearing "floor governs" claim guaranteed by the CSS; exact-24 would couple
      the test to font metrics that differ between this box (Cantarell) and the CI
      container (no font package installed)
      — implemented verbatim. MEASURED locally: **32 px default, 25 px at 9 pt**
      (both inside the bands, 25 < 32). The default is 32 rather than the predicted
      ~30 because Cantarell's 13 pt line box is ~24 px here, not ~22 — still 4 px
      under Adwaita's 36 px pin, which is only reachable with the override applied
      (the theme floor makes < 36 impossible otherwise), so the band still proves the
      fix. At 9 pt the row is content-driven at 25 px, one pixel above the 24 px
      floor — exactly why the plan's band is 24…26 and not exact-24
- [x] add a one-line triage comment in the test: `h ≈ 36` → the CSS override did not
      apply; off by 1–2 px at 9 pt → font metrics, widen the band
      — [decision] the success `print` also reports the two measured heights
      (`OK: … (32px -> 25px)`), so a CI log shows the numbers without a re-run; the
      triage comment sits above the default-launch assertion
- [x] register the scenario in BOTH `main()` locations: the child-scenario name tuple
      (~line 1631) that the no-arg parent run iterates, AND the `elif scenario == …`
      dispatch chain (~line 1665) — an arm without the tuple entry is a SILENT no-op
      (in-repo precedent: `"notification-banner"` has a dispatch arm but is missing
      from the tuple, so it never runs by default)
      — `"sidebar-row-height"` added to the tuple after `"surface-lifetimes"` and to
      the dispatch chain in the same position, so the two lists stay in the same order
- [x] after the local run, confirm `PASS: sidebar-row-height` appears in the output —
      do not trust an overall PASS
      — confirmed: `OK: sidebar row height follows the sidebar font size (32px -> 25px)`
      followed by `PASS: sidebar-row-height`
- [x] run the full suite locally as
      `LD_LIBRARY_PATH="$HOME/.local/share/swift-linux-compat" scripts/test-linux-ui.sh`
      (the script does NOT set this box's soname bridges itself; existing scenarios
      also click sidebar rows at their extents — this change moves that geometry, and
      CI runs the suite on push with no PR gate); if a dependency is missing or the
      binary won't launch under Xvfb, note it and explicitly accept CI as the gate
      — ⚠️ [deviation] the full suite CANNOT run on this box: `scripts/test-linux-ui.sh`
      bails at its dependency check with `missing Linux UI test dependency: openbox`,
      and `xdotool` + `xvfb-run`/`Xvfb` are absent too (only `dbus-run-session`, `gio`,
      `gapplication`, `makoctl` and python `gi`/`Atspi` are installed).
      **CI's `build-linux` job is explicitly accepted as the gate for the full suite.**
      [decision] the NEW scenario was still verified for real, by running
      `AGTERM_ATSPI_SCENARIO=sidebar-row-height python3 agterm-linux/tests/atspi_smoke.py`
      directly against this box's live Hyprland session: it needs no pointer/key input
      (the missing deps), `main()` still gives it an isolated temp `HOME`/state/socket
      and its own `AGTERM_APP_ID`, and `launch()`'s existing Hyprland arm moves the
      window to a silent workspace so nothing appears on the user's screen.
      Verified afterwards that the installed daily driver (`/opt/agterm-linux/bin/agterm-linux.bin`)
      was untouched and no harness process leaked.
      On the pointer-driven scenarios this change is safe by construction: `mouse_click`
      aims at `local.y + max(1, local.height // 2)`, the row CENTRE, which stays inside
      the row at any height ≥ 24 px — shrinking 36 → 32/25 cannot move the click off
      target

### Task 5: Verify acceptance criteria

- [x] verify all requirements from Overview are implemented (CSS override present,
      policy pure, `makeRow`/margins untouched, headers untouched)
      — verified against `git diff 50d946e..HEAD`: the whole controller change is
      −2/+1 lines inside `applySidebarFontSize()`, so `makeRow` (and its 4 px label
      margins) and the workspace-header `GtkBox`es are byte-identical; the three CSS
      rules live in `LinuxSidebarPolicy.sidebarCSS`, a non-`@MainActor` static that
      takes `Double?` and touches no store (pure); the selector scopes to
      `.agterm-sidebar .navigation-sidebar > row`, so headers stay content-driven
- [x] run full test suite: `cd agterm-linux && swift test` (env as in Task 1)
      — 119 tests / 16 suites, ONE failure = the recorded Task-1 baseline
      (`Flatpak process environments do not offer a host launcher`,
      `IntegrationServiceTests.swift:765`). No new failure
- [x] run `cd agtermCore && swift test` — core untouched, must stay green
      — 1733 tests / 74 suites, ONE failure, ⚠️ pre-existing and host-induced:
      `CodexStatusHookTests.stopReportsBlockedWhenAssistantMessageEndsInQuestionMark`
      (`CodexStatusHookTests.swift:102`). ROOT CAUSE established, NOT a regression:
      `agterm/Resources/agent-status/agterm-codex-status.sh` probes `-x /usr/bin/plutil`
      first (a macOS assumption), and this Manjaro box has GNUstep's `plutil`
      (`pacman -Qo` → `gnustep-base`) at that exact path; it rejects
      `-extract … raw -o - -` with `NSInvalidArgumentException REASON:Invalid fmt raw`
      and exits 1, so `assistant_asked_question` returns 1 and the hook reports
      `completed --auto-reset` instead of `blocked`. Same class as the Task-1
      baseline failure (a host binary the test does not expect). `agtermCore` has a
      ZERO diff across this whole branch (`git diff 50d946e..HEAD -- agtermCore` is
      empty), so this fix cannot have caused it. Task 1 only baselined the
      `agterm-linux` package, which is why it surfaced here — recorded now as the
      second baseline failure
- [x] launch ISOLATED — `scripts/run-linux.sh` sets no state dir, and
      `ControlServer.start()` unlinks-then-binds the DEFAULT socket, which would steal
      it from the installed `agterm-linux-bin` daily driver and touch real workspace
      state. Use `AGTERM_STATE_DIR=/tmp/agterm-rowheight scripts/run-linux.sh` — the
      path must be SHORT (`start()` hard-guards socket paths ≥ 104 bytes and silently
      never binds)
      — launched; log line `agterm: control socket at /tmp/agterm-rowheight/agterm.sock`
      confirms the isolated bind, and the daily driver's
      `~/.local/share/agterm/agterm.sock` is untouched (same inode/mtime, pid 666463
      still alive).
      ➕ [decision] the launch ALSO sets `AGTERM_APP_ID=io.github.melonamin.agterm.rowheight`,
      which the plan did not call for but which is REQUIRED here: `adw_application_new`
      is created with `GApplicationFlags(rawValue: 4)` = HANDLES_OPEN only — NOT
      NON_UNIQUE — so a second instance under the stock
      `io.github.melonamin.agterm` id would register as remote on the session bus and
      forward its launch to the user's RUNNING daily driver (raising its window)
      instead of starting. `App.swift` documents the override as the Linux analogue of
      the macOS `.debug` bundle id. Verified separate: `hyprctl clients` shows both
      classes side by side.
      [decision] `~/.config/agterm/{ghostty,keymap,restore-denylist}.conf` were copied
      into `/tmp/agterm-rowheight/config/` before launch, per the CLAUDE.md rule that
      an isolated `AGTERM_STATE_DIR` also redirects the config dir — so the visual
      pass renders with the user's real theme/font rather than defaults
- [x] the isolated state dir starts empty: create 3–4 sessions across two workspaces
      by hand (or seed copied state) so density is actually visible
      — [decision] seeded rather than created by hand (no interactive input available
      to this agent, and `agtermctl` pokes are banned by the hands-off rule): a legacy
      `workspaces.json` with 5 named sessions across 2 workspaces
      (`row-height demo`: alpha/beta/gamma, `second workspace`: delta/epsilon) was
      written into the state dir, and `WindowLibrary`'s legacy migration wrapped it
      into `windows/<id>.json` + `windows.json` on launch, exactly as a real restore
      would. Confirmed the restored tree from the migrated file
- [x] confirm the app starts with the denser default sidebar, then go HANDS-OFF — the
      user does the detailed visual pass (see Post-Completion); no `agtermctl` pokes
      at the running instance
      — confirmed: window mapped (`hyprctl clients` → class
      `io.github.melonamin.agterm.rowheight`, pid 749436), and ONE read-only AT-SPI
      extent probe reported all five session rows at **32 px** — the same height Task 4
      measured, and 4 px under Adwaita's 36 px pin, which is unreachable without the
      override. [decision] that single probe is read-only (no input injection, no state
      change) and is what makes "starts with the denser sidebar" evidence rather than
      assertion; nothing was touched afterwards. Instance left RUNNING for the user's
      pass — reach it by its own window (class
      `io.github.melonamin.agterm.rowheight`); tear down with `kill 749436` only

### Task 6: [Final] Update documentation

- [x] `README.md` check is expected to be a no-op (it has no "sidebar font size" text,
      and `.claude/rules/settings.md` already documents the `sidebarRowHeight`
      coupling this fix makes true on Linux) — confirm and move on; do NOT touch
      `CHANGELOG.md` (release-only)
      — confirmed a no-op:
      `grep -niE "sidebar font|sidebarFontSize|row height|rowHeight" README.md`
      returns nothing, and `.claude/rules/settings.md:38` already states "the row
      height scales with it via `AppSettings.sidebarRowHeight(fontSize:)`" in
      host-NEUTRAL wording (no "macOS only" qualifier) — this fix simply makes that
      sentence true on Linux as well, so no doc edit is owed.
      `docs/troubleshooting.md` carries no sidebar-metrics content either.
      `CHANGELOG.md` untouched (its only hit is the historical #187 entry for the
      setting itself; changelog text is release-only)
- [x] commit as `fix(linux): scale sidebar row height with sidebar font size` directly
      on `linux-port` (matches repo history; plan file committed alongside or as
      `docs: …`)
      — ⚠️ [deviation] this run uses WORKTREE isolation, so the commit lands on branch
      `linux-sidebar-row-height` in `.claude/worktrees/linux-sidebar-row-height`, NOT
      directly on `linux-port`; merging back to `linux-port` is the user's later step.
      No branch switch, no merge, no push was performed.
      [decision] the source and test changes were already committed by Tasks 2–5
      (`3abc2af` controller wiring, `7be05e9` AT-SPI scenario, `5222a82` acceptance
      notes), so this final commit carries only the plan-file update while reusing the
      mandated subject line
- [ ] move this plan to `docs/plans/completed/`
      — ⚠️ [deviation] deliberately NOT done here: the exec orchestrator performs the
      move with its own script at the very end, AFTER the review phases. The plan file
      stays at `docs/plans/` for now

## Post-Completion

**Manual verification** (user-driven, in the launched dev instance):
- Move Sidebar font size 13 → 9 → 18: session rows densify at 9 (≈25 px measured), sit
  ≈32 px at 13 (kept margins hold them just above the 28 px floor — still well under
  the old 36 px pin), grow at 18. At 18–20 pt confirm glyphs are fully visible vertically
  (ascenders/descenders not cut off): `min-height` is a floor, not a cap, so the row
  must grow with the label rather than truncate it.
- Workspace headers stay content-sized (disclosure/+ buttons unchanged).
- Selection highlight looks right at the smallest size (border-radius vs 24 px rows);
  flagged/status glyphs and the unseen badge still fit the row.
- Inline rename still works (the `GtkEntry` has its own Adwaita min-height and will
  temporarily heighten its row — expected).

**External follow-ups:**
- Report the bug (and this fix) upstream to `melonamin/agterm-linux` — unreported as of
  2026-07-25.
- Next AUR `agterm-linux-bin` release picks the fix up through the normal
  `release-linux` flow; no packaging change needed.
