# GTK main loop and deferred work

`agterm-linux` hands its main thread to GTK: `g_application_run` enters the GLib main loop and never
returns until the app quits.
That loop is not the AppKit run loop upstream assumes, and the difference is invisible at compile time —
code that defers work the macOS way builds fine, runs, and then silently does nothing.

## What the GLib loop drains

| Mechanism | Drained under `g_application_run`? |
|---|:---:|
| GLib sources (`g_idle_add`, `g_timeout_add`, GTK events, GSocket watches) | yes |
| libdispatch main queue (`DispatchQueue.main.async` / `.asyncAfter`) | **no** |
| Swift Concurrency main-actor executor (`Task { @MainActor }`, `Task.sleep`) | **no** |
| libdispatch global queues (`DispatchQueue.global`) | n/a — they run on their own threads, unaffected |

This was established with a standalone repro that starts a GLib main loop and arms all three mechanisms
at once; the result was `dispatch=NEVER mainActorTask=NEVER glib=FIRED`.
There is no partial draining and no timing window: the two non-GLib mechanisms simply never wake.

The failure mode is silence, not a crash — nothing logs, nothing throws, the closure is retained forever.
The Linux theme picker's live preview was dead for exactly this reason (the debounced preview scheduled 36
times and fired 0 times), along with every debounced save, the tree-change control events, and the
soft-close grace finalizer.

## The three ways to defer work

**Hop to the main thread now** — use `runOnMain` (`GhosttyApp.swift`), which wraps `g_idle_add`.
This is for callbacks that fire off-main (libghostty's C callbacks, worker-queue jobs) and need to touch
GTK or main-actor state.
`GhosttyApp.scheduleTick` is the same pattern hand-rolled with a coalescing flag.
`runOnMain` exists only in the Linux target, so host-free `agtermCore` has no hop seam: from code that is
already on the main actor, `MainTimer.schedule(after: 0)` is the next-turn hop; a genuine nonisolated→main
hop in core would need a hop seam added alongside `MainTimer` (none exists today, and nothing needs one).

**Run something after a delay** — use `agtermCore`'s `MainTimer` seam:
`MainTimer.schedule(after:_:)` returns a cancel closure, and `Debouncer` (which most call sites actually
use) routes through it.
`MainTimer.scheduleTimer` is the injection point; its default is `DispatchQueue.main.asyncAfter`, which is
correct on macOS and dead here, so the Linux app replaces it exactly once.
`installGLibMainTimer()` (`GLibMainTimer.swift`) runs at the top of `activateApplication`, ahead of the
`WindowLibrary`, the control server, and any window or surface, so nothing can schedule against the dead
default.
Each schedule becomes one one-shot `g_timeout_add_full` source (`GLibMainTimerSource`), retained as the
source's user data and released by its destroy notify on both the fire and the cancel path.

**Own a repeating or long-lived timer** — call `g_timeout_add` directly from the Linux target, as
`LinuxAutoFollowCoordinator` (the idle tick) and `SplitRatioRestoreCoordinator` do; the latter's 50 ms
divider-restore poll (`AppControllerSurfaces.scheduleSplitRatioRestore`) returns `G_SOURCE_CONTINUE` until
the paned has a width, and each coordinator owns its `guint` source id plus its own `g_source_remove` cancel.
`MainTimer` is deliberately one-shot; a subsystem that owns a re-arming timer keeps that logic on the Linux
side rather than growing the shared seam.

## Rules

- Do not use `DispatchQueue.main.async`, `DispatchQueue.main.asyncAfter`, `Task { @MainActor }` + `Task.sleep`,
  `Timer.scheduledTimer`, or `RunLoop` scheduling in any code the GTK app runs — including shared `agtermCore`
  code, where the dependency is easiest to miss because the file looks host-free.
- Deferred main-actor work goes through `MainTimer` (or `Debouncer` on top of it), main-thread hops go through
  `runOnMain`.
- `DispatchQueue.global` is fine — global queues have their own threads
  (`LinuxAgentIntegrations.swift` runs its integration-file disk work there and hops back with `runOnMain`).
- `MainTimer`'s default must stay Dispatch-based: it is what upstream macOS uses, and the GLib implementation
  belongs in the Linux target — `scripts/check-linux-core-boundary.sh` rejects GTK/Adwaita/GhosttyKit imports
  (including `CGtk`) and `ghostty_`/`gtk_`/`adw_` symbols in `agtermCore`.
- Prefer deriving a coupled delay from the constant it trails rather than re-hardcoding it — the Linux
  `reconcileSoftClose` schedules at `AppStore.pendingCloseGraceInterval + 0.1`, reading the constant rather
  than taking a grace argument, so it can neither drift from the core finalizer nor be handed a shorter grace
  that would reap a surface a pending undo still owns.

**One deliberate exception**, so a grep of the rule does not look like an unreported violation: the
`withObservationTracking` `onChange` in `agtermCore/Sources/agtermCore/AppStore+AutoFollow.swift` still uses
`DispatchQueue.main.async`.
That callback is nonisolated and can run off-main, so it is a THREAD HOP, and the `@MainActor` `MainTimer`
seam cannot express one (you must already be on the main actor to call it) — see "Hop to the main thread now"
above.
It is also unreachable under GTK: the observer is registered only on the off→on `setAutoFollow(timeout:)`
edge, which the port never takes (`LinuxSettingsController.applyAutoFollowSettings` always passes
`timeout: nil` and hands the runtime to `LinuxAutoFollowCoordinator`).
Its deferred half, `scheduleAutoFollowRearm`, IS main-actor code and goes through
`MainTimer.schedule(after: 0)`.

If a debounce, delay, or grace window "does nothing on Linux", check which mechanism scheduled it before
suspecting the logic — that symptom is almost always this contract.

## Testing through the seam

`MainTimer.scheduleTimer` is a process-global mutable static and swift-testing runs tests in parallel, so a
test that swaps it steals every schedule the whole process makes for as long as the swap is up.
Two rules keep that safe, both enforced by the shared `withFakeMainTimer` fixture
(`agtermCore/Tests/agtermCoreTests/AppStoreTestFixtures.swift`) rather than by review:

- **No `await` between install and restore.**
  The fixture's closure is synchronous by type, which makes the mistake unrepresentable; an `await` would let
  a concurrently running test arm its timer on the fake and starve.
- **Select entries by delay, never by position.**
  The fake records EVERY schedule — including the store's 0.3 s save debouncer and the 0.1 s tree-event one —
  so tests use an unmistakable delay (`index(ofDelay:)` / `lastIndex(ofDelay:)`) to find their own.
  `TimerRecorder.fire(_:)` also asserts the entry was not already cancelled; the "a late host fire must be
  inert" cases call `fireEvenIfCancelled(_:)` explicitly.

The GLib implementation itself is covered in the Linux package (`AgtermLinuxTests/GLibMainTimerTests.swift`),
which installs the real seam and pumps `g_main_context_iteration` synchronously — no display, no `gtk_init`.

## Preview state: the unpersisted-override pattern

Reviving the timers unmasked a second Linux-specific hazard, worth knowing before adding any other live
preview.

A preview applies settings that are deliberately **not** persisted.
But applying them makes libghostty emit `config_change` and OSC color-change actions, and those handlers
re-derive chrome/palette by reading settings from disk — so every preview immediately repainted itself with
the OLD persisted theme (the sidebar flashed the new theme, then reverted).

The fix is an in-memory override that every preview-path reader resolves through:
`AppController.themePreviewSettings` (declared in `GhosttyConfigTheme.swift` next to its readers) holds the
live preview, set by `previewTheme` and cleared on commit (`applyTheme`) and by `teardownThemePicker()` —
the single exit path `closeThemePicker` and `themePickerWasDestroyed` share, so preview state added later
cannot be cleared on only one of them.
The override is a process-global static, so an exit path that misses it pins EVERY window to an unpersisted
theme until restart.
Two such paths had to be closed explicitly: the picker is its own toplevel that GTK does not destroy with
its transient parent, so `windowWillClose` calls `cancelTheme()` itself; and an Enter on a query that matches
no theme has nothing to commit, so `commitTheme` falls through to `cancelTheme()` rather than closing with
the last preview still applied.
`cancelTheme` therefore guards on the picker still being up BEFORE it sets the override, not after: three
call sites now reach it (Esc in `onThemeKey`, the `commitTheme` fallthrough, and the window-close dismissal;
the `row-activated` and entry-`activate` signals arrive only through `commitTheme`), and its
clear happens inside `closeThemePicker`, which is a no-op with no picker — so a cancel that arrived after
teardown would set a process-global override nothing would ever clear.
Both readers — `applyResolvedWindowThemeColors` and `GhosttyApp.configWithOverlay` — call
`AppController.resolvedThemeSettings(persisted:)`, which is the one place `preview ?? persisted` is spelled
out.

The general rule: **if a feature applies unpersisted state to the surfaces, every re-resolver reachable from
that application must read the override, not the store** — otherwise the toolkit's own change notifications
undo the preview.
Note that this made `configWithOverlay` `@MainActor` (a `@MainActor` static cannot be reached from a
nonisolated autoclosure), which is the shape any future override reader will need too.
