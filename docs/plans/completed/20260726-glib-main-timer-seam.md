# Main-loop timer seam for GTK (GLib-backed deferred work)

## Overview

Deferred main-actor work in agterm-linux silently never runs. GTK owns the Linux main thread through
`g_application_run`, which drains neither libdispatch's main queue nor the Swift Concurrency MainActor
executor — both empirically proven with a standalone GLib-loop repro
(`dispatch=NEVER mainActorTask=NEVER glib=FIRED`). Two mechanisms are affected:

1. `agtermCore.Debouncer` schedules via `DispatchQueue.main.asyncAfter` — so the theme-picker live
   preview (the reported bug: navigating `Select Theme` never applied themes; runtime-probed: 36
   `SCHEDULE` lines, 0 `FIRED`), the Linux layout/sidebar-metadata debouncers, `AppStore`'s debounced
   selection/font saves, and `WindowLibrary`'s debounced `treeChanged` control events all silently
   never fire.
2. `Task { @MainActor }` + `Task.sleep` — so the soft-close grace finalizer
   (`AppStore.schedulePendingCloseFinalization`) never finalizes on Linux (undo window never expires,
   closed sessions/shells retained forever) and the Linux delayed deck reconcile
   (`AppController.reconcileSoftClose`) never runs (dead deck pages after soft-close).

Fixing (1) unmasked a secondary bug: preview-path re-resolvers read **persisted** settings and stomp
the unpersisted live preview — every preview's own `ghostty_surface_update_config` fires a
`config_change` action whose handler repainted the chrome from the old theme (sidebar
flash-then-revert), and the preview's own OSC 11 fires a color-change whose watermark reapply rebuilt
surfaces with the old theme's palette.

**Solution**: ONE host-injectable main-actor timer seam in `agtermCore` (default implementation:
`DispatchQueue.main` — macOS behavior unchanged), a GLib `g_timeout_add`-backed implementation
installed once at Linux startup, every deferred mechanism routed through it; plus an in-memory
`themePreviewSettings` override that preview-path settings readers resolve through.

Behavior changes this brings to Linux (intended): debounced selection/font saves now persist without
waiting for the quit-flush; `treeChanged` control events reach `agtermctl subscribe` for the first
time; the soft-close undo window actually expires and closed shells tear down after the grace.

Control-API keep-in-sync note: the seam itself adds no command — it *resurrects* the existing
`treeChanged` subscribe surface rather than adding one. The review loop did change two observable
control behaviors on Linux, both RESTORATIONS of what the already-published surfaces
(`site/commands.html`, the bundled agent skill, `.claude/rules/control-api.md`) already document, so
no external doc owes an update: `window.list` now carries the `fullscreen`/`zoomed` read-back (the
inline copy in `handleControl` had lost it — `ControlActions+AppControllerWindows.swift:21-28`), and
`window.delete` bypasses the GUI quit-confirm via `ctl.confirmedClose = true` (`:83`) instead of
deleting the store out from under a window the modal kept on screen.

## Context (from discovery)

- Root-cause investigation, mechanism repro, and runtime probe all happened in this worktree
  (`debounce-theme-preview-glib`); the theme-preview fix is already implemented and manually
  verified (live preview + sidebar + palette + Esc revert + Enter commit) on an isolated dev instance.
- The port already replaced *direct* `DispatchQueue.main` uses with GLib (`runOnMain`/`g_idle_add`,
  `g_timeout_add`, `LinuxAutoFollowCoordinator`); the dispatch dependency hidden inside shared
  "host-free" code was what got missed.
- Files involved: `agtermCore/Sources/agtermCore/{Debouncer,AppStore,AppStore+PendingClose,AppStore+AutoFollow,WindowLibrary}.swift`,
  `agterm-linux/Sources/AgtermLinux/{App,AppController,AppControllerControl,GLibDebounce,GhosttyApp,GhosttyConfigTheme,ThemePicker}.swift`.
- Deferred-mechanism inventory (full grep of `asyncAfter|DispatchQueue.main|Task.sleep|Timer.scheduledTimer`,
  independently re-verified as exhaustive by plan review):
  - `Debouncer.swift` — seam added (done).
  - `AppStore+PendingClose.swift:269` — the ONLY `Task {` in agtermCore: grace finalizer
    (**dead on Linux, to fix**); its `pendingCloseTasks` property (renamed `pendingCloseCancels` in the
    review loop) is declared in `AppStore.swift:96`,
    with exactly four `.cancel()`/replace sites (`:206` undo, `:223` finalize, `:267` reschedule,
    `:287` fold).
  - `AppControllerControl.swift:150` — the ONLY `Task {` in AgtermLinux: delayed reconcile
    (**dead on Linux, to fix**; delay `3.1` is silently coupled to
    `AppStore.pendingCloseGraceInterval` = 3.0).
  - `AppStore+AutoFollow.swift:104,115` — `DispatchQueue.main.async` hops; armed only on the
    off→on timeout edge, and Linux always passes `setAutoFollow(timeout: nil)`
    (owns `LinuxAutoFollowCoordinator` instead) — **unreachable on Linux, document only**.
  - `LinuxAgentIntegrations.swift` — `DispatchQueue.global` worker-queue usage; global queues have
    their own threads and work fine on Linux — **unaffected**.
- Existing test coverage relevant to the remaining tasks:
  - `AppStoreEventTests.swift:264-342` already covers tree-event coalescing/independence via the
    test-only `flushTreeEvents()`; the TIMER path (production emission) has never been exercised.
  - `WindowLibraryTests.swift:458-475` asserts the debounced-save cancel contract without ever
    firing the timer.
  - `AppStoreCloseReselectionTests.swift:345` (`graceExpiryAfterASoftCloseLeavesTheSelectionAlone`,
    `grace: 0.01` + poll) rides the real timer and must survive the finalizer conversion.
- Pre-existing, machine-specific test failures on this box (fail identically on the clean checkout):
  `CodexStatusHookTests.stopReportsBlockedWhenAssistantMessageEndsInQuestionMark` (agtermCore) and
  `IntegrationServiceTests."Flatpak process environments do not offer a host launcher"`
  (`LinuxIntegrationsTests`; the box has a real `/usr/bin/agtermctl` package install — details in the
  Task 2 note). Neither is related.
- Fork principles (AGENTS.md): keep shared core upstream-compatible; small reviewable downstream
  delta — hence one mechanical seam, no broad refactors.
- Plan review (auto): structural verdict sound; its CRITICAL/IMPORTANT findings are folded into the
  task list below (soft-close conversions bound into one task, seam wrapper func, `AppStore.swift`
  in files/conflict lists, multi-entry fake timer, seam-swap isolation rule, Task 4 retargeting).

## Development Approach

- **Testing approach**: TDD for the remaining work — write failing seam-injection tests first, then
  convert the mechanism; the already-landed part (Task 1) was built verification-first and carries
  its tests.
- Constraints (user-selected): minimize upstream-merge friction; ONE shared seam (no scattered
  per-site `g_timeout` calls); no new dependencies or targets.
- Complete each task fully before moving to the next; small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task; tests cover
  success and error scenarios. GTK-side (`AgtermLinux`) has no unit harness for `AppController` —
  its conversions are covered by the core seam tests, the Linux package test targets, build
  verification, and the manual acceptance task; everything host-free lands in `agtermCore` with
  unit tests.
- **CRITICAL: all tests must pass before starting next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**
- **Seam-swap isolation rule (applies to EVERY test that replaces `MainTimer.scheduleTimer`):**
  test bodies stay fully synchronous (no `await` between install and restore) and restore via
  `defer` — an `await` would let a parallel test's timer land on the swapped seam and starve it.
- **Fake-timer design (applies to Tasks 3-4):** the global seam catches EVERY debouncer in the
  process (`saveDebouncer` 0.3 s armed by `selectSession`, tree debouncer 0.1 s, auto-follow), so a
  single `pendingFire` slot gets clobbered by unrelated schedules. The fake must record an ordered
  list of `(delay, fire, cancelled)` entries and fire selectively (by delay or index); do store
  setup before installing the fake where possible.
- Maintain backward compatibility: the seam's default must preserve upstream macOS semantics
  (one named delta accepted — see Technical Details on clocks).

## Testing Strategy

- **Unit tests** (agtermCore, host-free, `swift test`): required for every task — seam contract
  (default + injection + cancel + wrapper), Debouncer delegation, pending-close
  finalization/undo/fold through an injected fake timer, tree-event TIMER-path emission,
  debounced-save fire-persists.
- **Linux package tests** (`cd agterm-linux && swift test`): the three targets (`AgtermLinuxTests`,
  `LinuxIntegrationsTests`, `agtermctlLinuxTests`) must stay green after every Linux-target task.
- **No UI e2e harness on Linux** — the AT-SPI smoke test doesn't cover the picker; manual acceptance
  on an isolated dev instance replaces it (checklist in Task 6).
- Lint: pinned SwiftLint 0.65.0 `--strict` must stay clean (CI enforces; local run available via the
  toolchain's `LINUX_SOURCEKIT_LIB_PATH`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview

- `MainTimer` (agtermCore): the host timer seam. The INJECTION POINT is
  `static var scheduleTimer: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)`
  (returns a cancel closure; default: `DispatchWorkItem` + `DispatchQueue.main.asyncAfter`).
  Callers use the thin labeled wrapper
  `@discardableResult static func schedule(after: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)`
  which forwards to `scheduleTimer` — a closure property has no argument labels and its result can't
  be `@discardableResult`, so the wrapper is what call sites and fire-and-forget users see; tests
  still swap the `var`.
- `Debouncer` keeps its public API and delegates its scheduling to `MainTimer` (the interim
  `Debouncer.scheduleTimer` static from Task 1 moves there — exactly 3 references exist, all in
  this branch).
- `AppStore.schedulePendingCloseFinalization` stores `MainTimer` cancel closures instead of `Task`
  handles in `pendingCloseCancels` (né `pendingCloseTasks`, declared in `AppStore.swift`); the four cancel/replace sites call
  the closure where they called `.cancel()`.
- Linux `reconcileSoftClose` replaces its `Task.sleep` with `MainTimer.schedule(after:)`, delay
  derived from `AppStore.pendingCloseGraceInterval + 0.1` (today's `3.1` re-hardcodes it).
- `GLibMainTimer.swift` (Linux; renamed from `GLibDebounce.swift` — Linux-only, no upstream cost):
  one-shot `g_timeout_add_full`, retained user data released by the destroy notify on fire and on
  cancel, plus the single install point (`installGLibMainTimer()`, called first in
  `activateApplication`) that sets `MainTimer.scheduleTimer`.
- `AppController.themePreviewSettings` (Linux): the picker's unpersisted preview settings, set by
  `previewTheme`, cleared on commit/close/destroy; `applyResolvedWindowThemeColors` and
  `configWithOverlay` resolve `preview ?? persisted`.

## Technical Details

- Seam shape: parameters of function types are implicitly escaping, but the `fire` parameter still
  needs an explicit `@escaping` annotation in the stored-closure type (compiler-verified in Task 1).
- `configWithOverlay` became `@MainActor` (its only caller, `GhosttySurface`, is `@MainActor`);
  a `@MainActor` static cannot be referenced from a nonisolated `??` autoclosure.
- GLib timer lifetime: `g_timeout_add_full` retains the timer object via `Unmanaged.passRetained`;
  the destroy notify balances it on both the fire path (callback returns `G_SOURCE_REMOVE`) and the
  cancel path (`g_source_remove`); `cancel()` after fire is a guarded no-op (`sourceID == 0`).
- Grace-finalizer conversion: `pendingCloseTasks: [UUID: Task<Void, Never>]` (in `AppStore.swift`)
  → `pendingCloseCancels: [UUID: @MainActor () -> Void]` (cancel closures). `finalizeAllPendingCloses` (quit flush) does
  not wait on the timer, but it routes through `finalizePendingClose`, whose cancel site
  (`AppStore+PendingClose.swift:223`) IS part of the conversion.
- One named macOS semantic delta: `Task.sleep` runs on the continuous clock, the seam default on
  `asyncAfter`'s uptime clock (pauses across system sleep). For a ~3 s grace this is inconsequential;
  accepted knowingly.
- Under `swift test` the concurrency runtime drains the dispatch main queue, so the DEFAULT seam
  also fires in tests — injection tests exist to pin the contract, not to make tests pass.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests, and doc changes in this repo.
- **Post-Completion** (no checkboxes): upstream-merge watch, potential upstream contribution,
  release-time changelog (CHANGELOG.md is release-only — never touched in a feature PR).

### Core vs Linux-target split

This is NOT Linux-only: the dead mechanisms live in SHARED `agtermCore` code, so the seam must land
there — but every core change is inert on macOS (the Dispatch default preserves upstream behavior;
only the Linux app installs the GLib implementation).

**How this fork carries core changes** (per AGENTS.md branch model + CI): `agtermCore` is NEVER
patched at build time — `linux/patches/` applies only to the vendored upstream *ghostty* source when
building libghostty. Core changes are ordinary commits carried on `linux-port` ("carried portable
core fixes"), sanctioned when deliberately portable and upstream-compatible. CI enforces this via
`scripts/check-linux-core-boundary.sh "$UPSTREAM_BASE_TAG"` (boundary tag currently v0.16.1): it
rejects host imports/symbols in core (AppKit/SwiftUI/Metal/GhosttyKit/CoreGraphics/CGtk/Gtk/Adwaita,
`ghostty_`/`gtk_`/`adw_`) and prints the portable core delta against the boundary tag so it stays
small and reviewable. `MainTimer` passes by construction (Foundation-only, Dispatch default). A
change intended FOR upstream goes on a dedicated upstream-PR branch kept free of Linux-only bits
(see Post-Completion).

**`agtermCore` (shared with upstream macOS — the reviewable downstream delta):**
- `Debouncer.swift` — an UPSTREAM file, not fork-added (upstream commit `6935431`
  "feat: add host-free Debouncer utility", an ancestor of the v0.16.1 boundary commit); upstream's
  version is pure Foundation (`DispatchQueue.main`) with zero Linux-related code, and it stays that
  way after our change — the fork's delta is only the injectable seam (Task 1), delegating to
  `MainTimer` in Task 2. All GLib code lives in the Linux target (the boundary check enforces this).
- `MainTimer.swift` — NEW in Task 2 (injectable `scheduleTimer` var + `schedule(after:_:)` wrapper,
  Dispatch default).
- `AppStore.swift` + `AppStore+PendingClose.swift` — Task 4 (finalizer timer storage/scheduling;
  mechanical, macOS-equivalent).
  **API-SURFACE change (review loop):** `AppStore.pendingHeldSessionIDs()` was widened from internal to
  **public** (`AppStore+PendingClose.swift:301`) so the Linux `reconcile` can union the held ids itself
  instead of trusting the soft-close caller to pass them.
  This is the ONE shared-core visibility change this branch carries downstream — flagged again in
  Post-Completion, since a future upstream merge must keep it.
- `AppStore+AutoFollow.swift` — Task 5, comments only; the review loop (5ebfffd) additionally routed the
  main-actor half (`scheduleAutoFollowRearm`) through `MainTimer.schedule(after: 0)` and REPLACED the
  commentary, leaving only the nonisolated→main hop.
- `agtermCoreTests` — new/extended suites (MainTimer, PendingCloseTimer, tree-event timer path,
  debounced save, Debouncer seam) plus the shared `AppStoreTestFixtures` timer recorder the review loop
  hoisted the per-file fakes into.

**`AgtermLinux` (Linux-only, no upstream cost):**
- `GLibMainTimer.swift` (né `GLibDebounce.swift`) — the GLib timer + the single install point.
- `App.swift` — one install call in `activateApplication`.
- `AppControllerControl.swift` — delayed reconcile through the seam (Task 4).
- Task 1's preview-override files (`AppController`, `GhosttyConfigTheme`, `GhosttyApp`,
  `ThemePicker`).
- `agterm-linux/Package.swift` — `AgtermLinuxTests` gains `CGtk` + the ghostty header path so the GLib
  seam can be pumped headlessly (`GLibMainTimerTests`).

**Review-loop delta (the six `fix: address code review findings` batches — 5ebfffd, e0b6333, 584a552,
ebe06db, 1d22972, 6381679 — not part of the original task list):**
- Create: `SoftCloseReconcileCoordinator.swift` (+ `SoftCloseReconcileCoordinatorTests.swift`) — the
  trailing reconcile became a cancellable, deferrable, injectable-scheduler coordinator instead of a
  fire-and-forget `MainTimer.schedule`.
- Create: `ControlActions+AppControllerWindows.swift` — the `window.*` arms split out of
  `ControlActions+AppController.swift` (1000-line cap) and made the SINGLE implementation, which restored
  the `window.list` fullscreen/zoom read-back and the `window.delete` quit-confirm bypass the inline copy
  in `handleControl` had lost.
- Modify: `AppControllerSurfaces.swift` — `reconcile(focusActive:)` signature, the
  `pendingHeldSessionIDs()` union inside `reconcile`, and the nil-active `showActive` pass.
- Modify: `AppControllerWindowLifecycle.swift` (dialog/deferred-job teardown + `finalizeAllPendingCloses`),
  `AppControllerSidebar.swift` (`sidebarInteractionInProgress` + the retry cadence),
  `AppControllerContextMenus.swift`, `AppControllerPrimaryMenu.swift`, `DeckPagePresentation.swift`
  (+ its tests), `WindowManager.swift`, `ControlActions+AppController.swift`,
  `GhosttyConfigTheme.swift` (+ `GhosttyConfigThemeTests.swift`), `ThemePicker.swift`.
- Create: `.claude/rules/main-loop.md` (the path-scoped rule); modify `.claude/rules/theme-picker.md`,
  `ARCHITECTURE.md`, `CLAUDE.md`, `AGENTS.md`, `agterm-linux/docs/main-loop.md`.

## Implementation Steps

### Task 1: Debouncer seam + GLib timer + preview-settings override (already implemented, verified)

Landed verification-first in this worktree before the plan; recorded here for review and tracking.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Debouncer.swift`
- Create: `agterm-linux/Sources/AgtermLinux/GLibDebounce.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/App.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/AppController.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/GhosttyConfigTheme.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/GhosttyApp.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/ThemePicker.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/DebouncerTests.swift`

- [x] add the injectable timer seam to `Debouncer` (static `scheduleTimer`, dispatch default,
      cancel-closure contract; `schedule`/`flush`/`cancel` route through it)
- [x] create `GLibDebounceTimer` + installer; install first in `activateApplication`
- [x] add `AppController.themePreviewSettings`; set in `previewTheme`, clear in `applyTheme`,
      `closeThemePicker`, `themePickerWasDestroyed`
- [x] resolve `applyResolvedWindowThemeColors` and `configWithOverlay` through
      `themePreviewSettings ?? persisted` (`configWithOverlay` promoted to `@MainActor`)
- [x] write seam tests (`scheduleRoutesThroughInjectedTimerSeam`,
      `cancelAndFlushStopTheInjectedTimer`) — synchronous per the seam-swap isolation rule
- [x] run tests — `DebouncerTests` 8/8 green; full core suite green modulo the pre-existing
      machine-specific `CodexStatusHookTests` failure
- [x] manual acceptance on isolated dev instance: live preview follows arrow nav (terminal palette,
      sidebar tint, header bar); Esc reverts; Enter commits

⚠️ Known coverage gap — CLOSED in the review loop (5ebfffd): the `themePreviewSettings ?? persisted`
resolution is now covered host-free by `AppControllerThemeSettingsTests`
(`agterm-linux/Tests/AgtermLinuxTests/GhosttyConfigThemeTests.swift`), which exercises
`AppController.themeSettings(_:base:)` and the `resolvedThemeSettings(persisted:)` precedence (preview
wins, persisted returns once the override is cleared) by driving the statics directly — no
`AppController` instance needed. What remains manual is only the picker's own GUI flow (arrow-nav
preview, Esc revert, Enter commit), which the Task 6 checklist guards.

Relocated at Task 6: `themePreviewSettings` / `previewTheme` / `applyTheme` are still
`AppController` members but are now DECLARED in `GhosttyConfigTheme.swift`'s
`@MainActor extension AppController` (next to `applyResolvedWindowThemeColors`), because keeping them
in `AppController.swift` pushed that file past the 1000-line SwiftLint budget — see the Task 6 notes.

### Task 2: Hoist the seam into a shared `MainTimer` (TDD)

**Files:**
- Create: `agtermCore/Sources/agtermCore/MainTimer.swift`
- Create: `agtermCore/Tests/agtermCoreTests/MainTimerTests.swift`
- Modify: `agtermCore/Sources/agtermCore/Debouncer.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/DebouncerTests.swift`
- Rename: `agterm-linux/Sources/AgtermLinux/GLibDebounce.swift` → `GLibMainTimer.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/App.swift`

- [x] write `MainTimerTests` FIRST (red): injected `scheduleTimer` receives delay and fire via the
      `schedule(after:_:)` wrapper; the wrapper's result is discardable; returned cancel closure is
      invoked exactly once per cancel; default implementation fires via the drained test main queue
      (synchronous bodies + `defer`-restore per the seam-swap isolation rule)
- [x] create `MainTimer` (`@MainActor` enum): injectable `static var scheduleTimer` (default moved
      from `Debouncer.scheduleTimer`) + the `@discardableResult static func schedule(after:_:)`
      labeled wrapper
- [x] delegate `Debouncer` to `MainTimer`; delete `Debouncer.scheduleTimer` (3 references total,
      all this branch); update the two seam tests to inject via `MainTimer.scheduleTimer`
- [x] rename the Linux file/class/installer (`GLibMainTimer.swift`, `installGLibMainTimer()`
      setting `MainTimer.scheduleTimer`); update the `App.swift` call site and header comment
- [x] run `agtermCore` tests + `cd agterm-linux && swift test` — green before Task 3

Notes:
- The GLib timer CLASS is `GLibMainTimerSource` (a file and a type may share a name in Swift, but the
  type wraps one one-shot `GSource`, so the name says what it is); callbacks renamed to match
  (`onGLibMainTimerTimeout` / `releaseGLibMainTimerSource`).
- `MainTimerTests` covers six facts: delay+fire forwarding, cancel-closure passthrough (one call per
  invocation), `@discardableResult`, independent per-schedule cancels, and BOTH default-seam paths
  (fires on the drained main queue / cancel stops the fire).
- SwiftLint is NOT installed on this box (no `swiftlint` binary, no mise install) — lint verification
  stays with Task 6 / CI. New/changed lines were kept inside the 200-col budget and trailing-whitespace
  free by hand.

⚠️ Second pre-existing machine-specific failure, found while running the Linux targets (unrelated to
this work, out of scope): `LinuxIntegrationsTests` →
`IntegrationServiceTests."Flatpak process environments do not offer a host launcher"`. This box has a
real system-package install at `/usr/bin/agtermctl` → `/opt/agterm-linux/bin/agtermctl`, so
`IntegrationEnvironment.packageCLI()` finds it and `commandLineToolStatus()` returns `.installed`
before reaching the flatpak `sandboxedCLIStatus()` guard; the test expects `.unavailable`. It probes
absolute host paths that the fixture cannot isolate. `LinuxIntegrationsTests` depends only on
`LinuxIntegrations` + `agtermCore` (Package.swift) — not on `AgtermLinux` — and nothing in the seam
work touches that code path. Treat as environmental, like the `CodexStatusHookTests` one.

### Task 3: Pin the Debouncer-routed paths — tree-event timer emission + debounced save (TDD)

No production change expected (both already use `Debouncer` → `MainTimer`); these tests pin the
behavior so a future refactor cannot silently detach them. Existing coverage already asserts
tree-event coalescing/independence via the test-only `flushTreeEvents()` (`AppStoreEventTests`) —
the ONE uncovered fact is that production emission happens on the TIMER path at all
(`flushTreeEvents` has no production caller, which is exactly why the dead timer went unnoticed).

**Files:**
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreEventTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/WindowLibraryTests.swift`

- [x] write test in `AppStoreEventTests` (red until wired to the injected timer): with a multi-entry
      fake `MainTimer.scheduleTimer`, a store mutation emits `treeChanged` only after the fake's
      0.1 s entry fires — no `flushTreeEvents()` involved
- [x] write test in `WindowLibraryTests` (alongside the existing cancel-contract test at `:458`):
      `selectSession` schedules the debounced save through the injected timer; firing the 0.3 s
      entry persists the selection; a structural `save()` cancels the pending entry
- [x] both tests follow the multi-entry fake + synchronous-body rules from Development Approach
- [x] run tests — green before Task 4

Notes:
- Test names: `treeChangedReachesTheRingOnlyWhenTheDebounceTimerFires` (`AppStoreEventTests`) and
  `debouncedSelectionSavePersistsOnlyWhenTheTimerFires` (`WindowLibraryTests`).
  No production change was needed, as predicted.
- Red-first was verified by temporarily removing the `fire()` call from each test: both then failed on
  the observable effect (empty `treeChanged` batch / `selectedSessionID` still the pre-select value),
  proving neither test is vacuous. The `fire()` calls were restored and both suites pass.
- [decision] The debounced-save test observes the write on disk (`persistedSelection` helper reading
  `windows/<id>.json` through `PersistenceStore`) rather than an in-memory flag — that is what the
  Linux bug actually broke, and `AppStore.saveDebounceInterval` is `private` so the fake selects the
  entry by its literal `0.3` delay (commented), no production visibility change just for a test.
- [decision] The fake records `cancelled` indices in BOTH tests (uniform shape per the plan's
  fake-timer design); the tree test asserts its entry was never cancelled, the save test asserts the
  structural `save()` cancels the pending entry.
- Validation: full `agtermCore` suite — 1743 tests, only the documented `CodexStatusHookTests`
  failure; `cd agterm-linux && swift test` — 118 tests, only the documented `IntegrationServiceTests`
  flatpak failure. SwiftLint still not installed on this box (Task 2 note); new lines kept
  trailing-whitespace-free and inside the 200-col budget, and both test files stay under the 2000-line
  test budget (406 / 1267).

### Task 4: Soft-close grace — core finalizer AND Linux reconcile through the seam (TDD, ONE commit)

These two conversions are deliberately ONE task and must land as ONE commit (never bisected):
every Linux soft-close entry point pairs the core finalizer (teardown at grace ≈3.0 s) with the
delayed deck reconcile (cleanup at grace+0.1 s). Converting only one side leaves a regression
window that exists in neither today's state nor the end state — finalizer-only tears down surfaces
that stay parented in the deck; reconcile-only destroys a live surface out from under a
still-pending undo.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (the `pendingCloseTasks` → `pendingCloseCancels` declaration)
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
  (review loop: `pendingHeldSessionIDs()` widened to `public`)
- Create: `agtermCore/Tests/agtermCoreTests/PendingCloseTimerTests.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/AppControllerControl.swift`

Added by the review loop, same subject (see the Review-loop delta in the split section above):
- Create: `agterm-linux/Sources/AgtermLinux/SoftCloseReconcileCoordinator.swift`
- Create: `agterm-linux/Tests/AgtermLinuxTests/SoftCloseReconcileCoordinatorTests.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/AppControllerSurfaces.swift` (`reconcile(focusActive:)`,
  the `pendingHeldSessionIDs()` union, the nil-active `showActive`)
- Modify: `agterm-linux/Sources/AgtermLinux/AppControllerWindowLifecycle.swift` (cancel the coordinator,
  finalize the store-scoped grace records), `AppControllerSidebar.swift` (the deferral gate + cadence),
  `DeckPagePresentation.swift` (+ its tests)

- [x] write `PendingCloseTimerTests` FIRST (red), multi-entry fake + synchronous bodies:
      `softCloseSession` schedules with the grace delay; firing that entry finalizes (session gone,
      recent-closed recorded); `undoPendingClose` cancels the entry; workspace folding cancels the
      superseded record's entry; two pending closes keep independent entries; re-close of the same
      id reschedules (old entry cancelled)
- [x] convert `pendingCloseTasks` to `[UUID: @MainActor () -> Void]` in `AppStore.swift`; route
      `schedulePendingCloseFinalization` through `MainTimer.schedule`; convert all four cancel
      sites (`:206` undo, `:223` finalize, `:267` reschedule, `:287` fold)
- [x] verify no `Task.sleep` remains in `AppStore+PendingClose.swift`
- [x] replace the `Task { @MainActor }` + `Task.sleep` in Linux `reconcileSoftClose` with
      `MainTimer.schedule(after: AppStore.pendingCloseGraceInterval + 0.1)` (fire-and-forget
      parity, `[weak self]`; the constant replaces the silently-coupled hardcoded `3.1`)
- [x] verify `graceExpiryAfterASoftCloseLeavesTheSelectionAlone`
      (`AppStoreCloseReselectionTests`) still passes on the new mechanism (it rides the REAL
      default timer with `grace: 0.01`)
- [x] run `agtermCore` tests + `cd agterm-linux && swift test` — green before Task 5; land both
      conversions as a single commit

Notes:
- Red-first verified: all six tests failed before the conversion, every one on
  `index(ofDelay:) → nil` — the finalizer never touched the seam because it was a bare `Task`.
- The multi-entry fake is a small `TimerRecorder` helper class in the test file (install/restore +
  `index(ofDelay:)`/`fire(_:)`) instead of the inline closure the Tasks 2-3 tests use: six tests
  would otherwise repeat the same eight lines. Same contract — synchronous bodies, `defer { restore() }`,
  every schedule recorded, entries selected by an unmistakable grace (5/7/9 s, never colliding with
  the 0.3 s save or 0.1 s tree debouncers).
- [decision] `pendingCloseTasks` keeps its name (the plan's wording) even though it now stores cancel
  closures, so the upstream-merge diff stays line-local; a doc comment on the declaration says what it
  holds now.
  *(REVERSED in the review loop: renamed to `pendingCloseCancels`. The merge-delta argument does not
  survive inspection — all six references were ALREADY rewritten by the conversion (`.cancel()` → `()`
  plus the declaration), so the rename adds no line to the downstream diff, while `…Tasks` names a type
  the property no longer holds.)*
- [decision] "re-close of the same id reschedules" is covered as the same SESSION id
  (`reclosingASessionAfterAnUndoArmsAFreshEntry`: close → undo → close, stale entry cancelled and inert,
  fresh entry finalizes). Every close mints a FRESH record UUID, so the record-level replace at
  `schedulePendingCloseFinalization` is unreachable through the public API — it stays as a defensive
  guard and the test documents that.
- ➕ Review loop: the trailing reconcile runs `reconcile(focusActive: false)`. The `Task.sleep` version
  never fired on Linux, so its default `focusActive: true` was newly-live behavior: a `grab_focus` on the
  active deck page ~3.1 s after a close would steal the keyboard from the in-terminal search entry or the
  quick terminal (both plain widgets in the SAME toplevel, neither covered by the `deferWhile` sidebar
  gate) and misroute the rest of the user's typing into a live shell. The trailing pass only drops dead
  deck pages, so it has no reason to move focus; the immediate reconcile still focuses because that one is
  the user's own close action.
- ➕ Added a sixth test, `quitFlushFinalizationCancelsEveryPendingGraceEntry`, for the
  `finalizeAllPendingCloses` (quit-flush) route through cancel site `:223`: both records finalize
  immediately, both entries are cancelled, and a late host fire cannot tear a surface down twice.
- Validation (counts as of THIS task; the review loop's added tests move the final baseline to 1752 /
  131 — see Task 6): `agtermCore` — 1749 tests, only the documented `CodexStatusHookTests` failure;
  `cd agterm-linux && swift test` — 118 tests, only the documented `IntegrationServiceTests` flatpak
  failure; `swift build --target AgtermLinux` clean (the GTK target compiles the converted reconcile).
  SwiftLint still not installed on this box (Task 2 note): new lines are trailing-whitespace-free and
  inside the 200-col budget, the new test file is 216 lines (2000-line test budget), and
  `AppStore.swift` grew by the 2-line doc comment to 997 lines — still under the 1000-line source
  budget but close, worth noting for whoever next grows that file.

### Task 5: Residual audit — no dead deferred paths remain

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+AutoFollow.swift` (comments only)

- [x] re-run the inventory grep (`asyncAfter|DispatchQueue.main|Task.sleep|Timer.scheduledTimer`)
      over `agtermCore` + `AgtermLinux`; every remaining hit must be either the `MainTimer` default
      or provably Linux-unreachable — record the final list in this plan
- [x] add a comment on the two `AppStore+AutoFollow` `DispatchQueue.main.async` hops noting they are
      armed only on the off→on timeout edge, which the GTK port never takes
      (`LinuxAutoFollowCoordinator` owns the Linux runtime) — unreachable under GLib
      *(superseded in the review loop, 5ebfffd: the main-actor half now goes through
      `MainTimer.schedule(after: 0)`, so ONE hop — the nonisolated→main one — carries the comment;
      see the inventory entry and the reversed decision below)*
- [x] note `LinuxAgentIntegrations`' `DispatchQueue.global` usage is worker-thread and unaffected
      (no change)
- [x] run full core suite — green before Task 6

**Final inventory (re-run at Task 5, `agtermCore/Sources` + `agterm-linux/Sources`):**

Live deferral hits — each accounted for:

1. `agtermCore/Sources/agtermCore/MainTimer.swift:23` — the seam DEFAULT
   (`DispatchWorkItem` + `DispatchQueue.main.asyncAfter`). Correct on macOS; on Linux
   `installGLibMainTimer()` (first statement of `activateApplication`) replaces it before any store
   or window exists, so the default never schedules under GTK.
2. `agtermCore/Sources/agtermCore/AppStore+AutoFollow.swift` — the two next-turn HOPS (not delays).
   Reachable only after a non-nil `setAutoFollow(timeout:)`; the port's ONLY caller
   (`LinuxSettingsController.applyAutoFollowSettings:305`) always passes `timeout: nil` and hands the
   runtime to `LinuxAutoFollowCoordinator` (GLib `g_timeout_add`), so the observer is never
   registered on Linux. **Unreachable under GLib — commented in place this task, no code change.**
   *(Superseded during the review loop, commit 5ebfffd: the MAIN-ACTOR half — `scheduleAutoFollowRearm`
   — now defers through `MainTimer.schedule(after: 0)`, so only the nonisolated→main hop inside
   `observeAttentionForAutoFollow`'s `onChange` is still a `DispatchQueue.main.async`. The `@MainActor`
   seam cannot express a thread hop and core has no hop seam, so that one stays and is documented as
   the single deliberate exception in `agterm-linux/docs/main-loop.md`.)*
3. `agterm-linux/Sources/AgtermLinux/LinuxAgentIntegrations.swift:66,113,171` —
   `DispatchQueue.global(qos: .userInitiated).async` worker jobs (`IntegrationService` disk work).
   Global queues own their own threads and run fine; every one hops back via `runOnMain`
   (`g_idle_add`), never `DispatchQueue.main`. **Unaffected, no change.**
4. `agtermCore/Sources/agtermctlKit/{SessionCommands.swift:654,EventCommands.swift:18,131}` —
   `Thread.sleep` poll waits inside the `agtermctl` CLI process. Blocking sleeps on the CLI's own
   thread, no GTK/GLib loop in that process. **Unaffected, no change.**

Everything else that matched is either a comment (`AppStore+PendingClose.swift:266`,
`AppControllerControl.swift:149-150`, `ControlServer.swift:4`, `LinuxAutoFollowCoordinator.swift:8`,
`LinuxSettingsController.swift:303`) or already GLib-native: `g_timeout_add*` at
`GLibMainTimer.swift:29`, `AppControllerSurfaces.swift:378`, `AppControllerControl.swift:215`,
`KeymapDispatch.swift:214`, `AppControllerDashboard.swift:264`, `LinuxSettingsController.swift:212`,
`AppController.swift:561`, `LinuxAutoFollowCoordinator.swift:75`; `g_idle_add` at
`GhosttyApp.swift:147,480`.

Zero `Task {` blocks and zero live `Task.sleep` calls remain in either module (grep exits 1 / only
comment hits) — Task 4 converted the last two. No `Timer.scheduledTimer` / `RunLoop` anywhere.

Notes:
- [decision] No new tests for this task: it is a pure audit — the only edit is two explanatory
  comments on provably unreachable code, and the Development Approach's per-task test mandate covers
  "code changes", of which this task has none. Testing that a hop is unreachable would mean asserting
  a Linux-only call-site convention from host-free tests, which the module boundary forbids.
- [decision] The two hops were left as-is rather than routed through `MainTimer.schedule(after: 0)`:
  they are hops, not timers, the code is dead on Linux, and rewriting them would grow the
  upstream-merge delta in a shared file for zero behavior change. The comments say what a future port
  of that runtime must do instead.
  *(Superseded in the review loop by commit 5ebfffd — see the inventory entry above. The main-actor
  half went through the seam after all: two changed lines make the AGENTS.md rule true by construction
  there and REPLACE ~6 lines of commentary, so the shared-file delta shrank rather than grew. The
  nonisolated hop is the only one left.)*
- Validation (count as of THIS task — final baseline is 1752, see Task 6): full `agtermCore` suite —
  1749 tests, only the documented `CodexStatusHookTests`
  failure. Linux targets not re-run (no `AgtermLinux` source changed this task; last green at Task 4).

### Task 6: Verify acceptance criteria

- [x] `cd agtermCore && swift test` — green (pre-existing machine-specific `CodexStatusHookTests`
      failure documented as out of scope; verify it is STILL the only failure)
- [x] `cd agterm-linux && swift test` — all three Linux test targets green
- [x] SwiftLint 0.65.0 `--strict` — zero findings
- [x] `scripts/check-linux-core-boundary.sh v0.16.1` — passes; review the printed portable core
      delta (should list exactly the files in the Core vs Linux-target split section)
- [x] rebuild and relaunch the isolated dev instance (`AGTERM_STATE_DIR=/tmp/agterm-dev-theme`,
      `AGTERM_APP_ID` override); manual checklist:
      theme preview follows arrow nav (palette + sidebar + header), Esc reverts, Enter commits
      **[manual — skipped, needs a human at the display; verified once at Task 1]**;
      soft-close a session with grace undo on → undo window expires after the grace and the deck
      page is reconciled away **[automated below]**; sidebar row title/cwd updates as the shell
      `cd`s **[automated below]**; `agtermctl subscribe` (dev socket) receives `treeChanged` after
      a session mutation **[automated below]**
- [x] verify all Overview items are implemented and every task checkbox above is `[x]`

**Validation results:**

- `agtermCore` — 1752 tests in 76 suites, single failure
  `CodexStatusHookTests.stopReportsBlockedWhenAssistantMessageEndsInQuestionMark`
  (the documented machine-specific one). `agterm-linux` — 131 tests in 19 suites, single failure
  `IntegrationServiceTests."Flatpak process environments do not offer a host launcher"` (the other
  documented one). Both baselines unchanged; no new failures.
  (Counts re-taken after the six review-loop fix batches, which added `GLibMainTimerTests`,
  `SoftCloseReconcileCoordinatorTests`, `AppControllerThemeSettingsTests` and the extra
  pending-close / deck-presentation / window-library cases; they were 1749 / 118 in 16 at the first
  pass through this task.)
- SwiftLint 0.65.0 `--strict --quiet`: **zero findings, exit 0** — run with SourceKit enabled so no
  rule was skipped.
- `scripts/check-linux-core-boundary.sh v0.16.1`: **exit 0**. Printed portable core delta matches the
  Core vs Linux-target split exactly for this branch's files (`Debouncer.swift`, new `MainTimer.swift`,
  `AppStore.swift`, `AppStore+PendingClose.swift`, `AppStore+AutoFollow.swift`, plus the four test
  files); the other listed entries (`Package.swift`, `agtermctlKit/Commands.swift`,
  `CommandsTests.swift`, `PublicCatalogTests.swift`) are pre-existing `linux-port` deltas, untouched
  by this branch (`git diff --name-status d3b05b8..HEAD` confirms).

**Runtime acceptance on an isolated dev instance** (own `AGTERM_STATE_DIR` + `AGTERM_APP_ID`,
socket-probed with the freshly built `agtermctl-linux`, torn down by PID afterwards; the maintainer's
own running install was never touched) — this is the FIRST end-to-end proof the GLib timer fires
under a real `g_application_run`:

1. **`tree.changed` reaches `agtermctl events`** — a `session new` and a `session rename` each
   produced one `tree.changed` event (seq 4 and 5) on the dev socket. This is the 0.1 s tree debouncer
   firing through the GLib-backed seam; before this work the event never arrived at all.
2. **Soft-close grace finalizer actually finalizes** — three live shells, a two-target
   `session close` (grace-undo default on → `softCloseSessions`), then: at t+0.5 s the sessions were
   gone from `tree` but **all three shells still alive** (undo window open), and at t+5.5 s **only one
   shell remained** — the grace finalizer tore the other two down on time. Previously it never fired
   on Linux.
3. **Debounced selection save persists without a quit-flush** — a pure `session select` (no structural
   mutation): at t+0.1 s `windows/<id>.json` still held the OLD `selectedSessionID`, at t+1.5 s it held
   the new one. Textbook 0.3 s debounce through the seam.
4. **Sidebar row title/cwd updates as the shell `cd`s** — typing `cd /usr/share` + newline into a
   session moved that row's `tree` cwd and title from `/home/n` to `/usr/share`.
5. App log carried no app-level errors (only environmental fontconfig warnings).
6. Theme **preview** (arrow-nav live preview, Esc revert, Enter commit) is GUI-only and not drivable
   over the control socket — left as the human-verified step from Task 1. `theme set "Nord"` over the
   socket was exercised as a proxy and applied + persisted cleanly.

Notes:
- [decision] SwiftLint IS obtainable on this box after all, contradicting the Tasks 2-4 notes: fetched
  the CI-pinned 0.65.0 `swiftlint_linux_amd64.zip`, verified against CI's `SWIFTLINT_SHA256`, and ran
  it from the scratchpad (nothing installed system-wide). The bundled `swiftlint-static` runs but
  skips `statement_position` ("requires SourceKit"), so the final verdict was taken from the DYNAMIC
  binary with `LD_LIBRARY_PATH` bridging Arch's `libxml2.so.2` (the existing `swift-linux-compat` dir)
  and `LINUX_SOURCEKIT_LIB_PATH` pointed at the toolchain — all rules ran, zero findings.
- ⚠️ [deviation] That first real lint run surfaced **two violations this branch had introduced**, both
  fixed in this task:
  - `orphaned_doc_comment` at `GhosttyApp.swift:109` — Task 1 appended plain `//` lines after the
    `///` block on `configWithOverlay`, detaching the doc comment from the declaration. Merged the
    continuation into the `///` block.
  - `file_length` — `AppController.swift` hit 1010 lines (budget 1000); it was at EXACTLY 1000 before
    this branch and Task 1's `themePreviewSettings` block added the 10 that broke it.
- [decision] Fixed the `file_length` violation by RELOCATING, not by raising the limit (CLAUDE.md:
  "don't reflexively bump the swiftlint `file_length`/`type_body_length` limits to fit new code").
  Moved the theme-preview trio — `themePreviewSettings`, `previewTheme`, `applyTheme` — out of
  `AppController.swift` into the existing `@MainActor extension AppController` in
  `GhosttyConfigTheme.swift`, directly above the preview-aware `applyResolvedWindowThemeColors` that
  reads the property (its only other reader is `GhosttyApp.configWithOverlay`). That is the most
  cohesive home: all theme-preview state and its resolvers now sit in one file, and
  `AppController.swift` dropped to 984 (992 after the review-loop batches, still under the 1000 cap).
  A two-line pointer comment marks where they went. CLAUDE.md
  normally requires ASKING before restructuring a file; no human was available for this run and the
  only alternative (raising the limit) is explicitly forbidden, so the minimal cohesive move was taken
  — flagging it here for the maintainer to veto if they'd rather it lived elsewhere.
- [decision] The boundary tag `v0.16.1` does not exist in this clone (no tags are fetched), so the
  script exited 2 with "unknown upstream base". Materialized it exactly the way CI does
  (`git tag --force v0.16.1 d597d059edb99c69675e74b9f2ba159bdc194cc6`, from `ci.yml`'s
  `UPSTREAM_BASE_COMMIT`) and confirmed `git merge-base --is-ancestor` before running the check.
- [decision] The AT-SPI UI smoke harness (`scripts/test-linux-ui.sh`) was NOT run: it requires
  `xvfb-run`/`openbox`/`xdotool`, and `Xvfb` is absent on this box. The plan already states that
  harness does not cover the picker anyway; the socket probes above replace it.
- ⚠️ Third environmental finding, unrelated and out of scope: the `watcher*` tests in
  `CodexStatusHookTests` are FLAKY under the full parallel suite — across five full runs a different
  one failed twice (`watcherIgnoresAutoReviewProgress`, then `watcherReportsVisibleSubmitAllPrompt`),
  and three runs showed only the documented `stopReportsBlocked…` failure. All of them pass in
  isolation (`--filter CodexStatusHookTests`, 3/3 runs, only `stopReportsBlocked…` failing). They
  spawn the real `agterm-agent-status.sh` hook as a `__watch-blocked` worker SUBPROCESS with a bounded
  check budget, so they race under load — a bash-subprocess timing flake with no Swift main-actor
  timer anywhere in the path, i.e. nothing this work touches. The deterministic-failure baseline is
  unchanged.
- The boundary tag `v0.16.1` now exists as a LOCAL tag in this clone (created as described above). It
  was not pushed; delete it with `git tag -d v0.16.1` if it is unwanted, at the cost of making
  `check-linux-core-boundary.sh` unrunnable locally again.

### Task 7: [Final] Update documentation

- [x] AGENTS.md: add a fork principle — main-actor deferred work must go through the `MainTimer`
      seam; `DispatchQueue.main` / `Task.sleep` timers silently never run under the GLib main loop
- [x] Create `agterm-linux/docs/main-loop.md`: the GTK main-loop contract (what GLib does not drain,
      the repro result, `runOnMain`/`g_idle` for hops, `MainTimer` for delays, the
      `themePreviewSettings` override pattern for unpersisted preview state)
- [x] update this plan's checkboxes/notes; move it to `docs/plans/completed/`
      (plan move performed by the exec orchestrator at completion)

**Files:**
- Modify: `AGENTS.md`
- Create: `agterm-linux/docs/main-loop.md`

Notes:
- AGENTS.md gains one new section, `## Main-actor deferred work must go through the MainTimer seam`,
  placed between `## Host-free core rules` and `## Control API coverage is a first-class requirement`
  — the rule binds hardest on shared core code, so it reads directly after the host-free rules.
  It states the contract (GLib drains neither libdispatch's main queue nor the main-actor executor),
  the four do/don't bullets (`MainTimer`/`Debouncer` for delays, `runOnMain` for hops, Dispatch default
  stays for macOS, `DispatchQueue.global` is fine), and points at the new doc.
- `agterm-linux/docs/main-loop.md` follows the existing `x11-wayland.md` shape (matrix table + prose):
  what the loop drains, the repro verdict (`dispatch=NEVER mainActorTask=NEVER glib=FIRED`), the three
  ways to defer (`runOnMain`/`g_idle_add` hops, `MainTimer` one-shot delays, direct `g_timeout_add` for
  a subsystem-owned repeating timer like `LinuxAutoFollowCoordinator`), the rules, the "does nothing on
  Linux" symptom guide, and the unpersisted-override pattern (`AppController.themePreviewSettings`,
  its setters/clearers, and the two preview-path readers).
- [decision] The new doc is NOT linked from `README.md`: the sibling `agterm-linux/docs/x11-wayland.md`
  is unlinked too (grep: zero references repo-wide), so linking only this one would be inconsistent, and
  the doc is a contributor/agent note rather than user-facing. AGENTS.md carries the pointer, which is
  what an agent or contributor actually reads first.
- [decision] Docs-only task, so no tests were added and no suite was re-run (last green at Tasks 5-6).
  Validation was name-accuracy instead: every symbol the two docs name was grepped in the tree
  (`installGLibMainTimer`, `GLibMainTimerSource`, `MainTimer.scheduleTimer`/`schedule(after:_:)`,
  `Debouncer`, `runOnMain`, `GhosttyApp.scheduleTick`, `LinuxAutoFollowCoordinator`,
  `LinuxAgentIntegrations.swift`, `AppStore.pendingCloseGraceInterval`, `reconcileSoftClose`,
  `themePreviewSettings`, `previewTheme`, `applyTheme`, `closeThemePicker`, `themePickerWasDestroyed`,
  `applyResolvedWindowThemeColors`, `configWithOverlay`, `scripts/check-linux-core-boundary.sh`).
- Two drafting inaccuracies were caught by that pass and corrected: `installGLibMainTimer()` is NOT the
  literal first statement of `activateApplication` (the re-activate guard and `gApp = app` precede it —
  reworded to "at the top of, ahead of the WindowLibrary/control server/any window"), and
  `LinuxAgentIntegrations` is a FILE name, not a type name (the type is `IntegrationService`), so the doc
  cites `LinuxAgentIntegrations.swift`.
- Semantic line breaks throughout both files, per the repo convention.

## Post-Completion

**Manual verification:**
- Watch the next few days of daily-driver use after release for soft-close regressions (the grace
  finalizer changes behavior on Linux from "never finalizes" to "finalizes on time" — closed
  sessions now actually tear down after the grace window, and the undo window genuinely expires).

**External / future:**
- Next `chore(upstream): merge` — expect small conflicts in the four shared-core files this touches
  (`Debouncer.swift`, `AppStore.swift`, `AppStore+PendingClose.swift`, `AppStore+AutoFollow.swift`);
  re-apply is mechanical (seam delegation + cancel-closure storage + the `scheduleAutoFollowRearm` hop).
- One API-surface change must survive that merge: `AppStore.pendingHeldSessionIDs()` is now **public**
  (`AppStore+PendingClose.swift`), because the Linux `AppController.reconcile` unions the held ids itself
  so no reconcile from any path can reap a session a pending undo still offers to restore. An upstream
  merge that restores the internal visibility breaks the Linux build; upstream has no caller outside the
  module, so widening it is a one-word downstream delta rather than a behavior change.
- Consider offering the `MainTimer` seam upstream (default preserves macOS semantics; would shrink
  the fork's downstream delta to just the GLib installer). Per AGENTS.md policy this happens on a
  DEDICATED upstream-PR branch (`MainTimer.swift` + `Debouncer` delegation + the pending-close
  conversion, WITHOUT the GLib installer or any Linux-only bits).
- Changelog: release-time only (`CHANGELOG.md` is never touched in a feature PR).
