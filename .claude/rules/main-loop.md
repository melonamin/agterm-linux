---
paths:
  - "agtermCore/Sources/agtermCore/MainTimer.swift"
  - "agtermCore/Sources/agtermCore/Debouncer.swift"
  - "agtermCore/Sources/agtermCore/AppStore.swift"
  - "agtermCore/Sources/agtermCore/AppStore+PendingClose.swift"
  - "agtermCore/Sources/agtermCore/AppStore+AutoFollow.swift"
  - "agtermCore/Sources/agtermCore/WindowLibrary.swift"
  - "agterm-linux/Sources/AgtermLinux/**"
  - "agterm-linux/docs/main-loop.md"
---

## Main loop and deferred work (GTK/Linux port)

- **Before the loop exists: the GDK environment assignments run as the FIRST statements of `main()`,
  above any GTK/GDK call.**
  `LinuxGdkPolicy` derives them from the linked GTK version and the pre-launch `GDK_DISABLE`/`GDK_DEBUG`
  values, and `AgtermApp.main()` applies them with `setenv` before `adw_application_new`/`g_application_run`
  — GDK parses both variables exactly once, while GTK initializes, and ignores them afterwards, so anything
  that opens a display earlier silently turns the assignment into a no-op.
  Both tokens are load-bearing.
  libghostty's renderer is desktop-GL-only (the terminal's `GtkGLArea` pins itself to `GDK_GL_API_GL`), so
  GDK's GLES API must be disabled pre-init: on GTK ≥ 4.16 GDK otherwise builds its own paint context with
  the GLES API and the desktop-GL sibling context cannot be realized at all, leaving every surface on the
  "failed to create a GL context" overlay.
  GTK's Vulkan GSK renderer must be disabled with it, because Vulkan-GSK cannot import the desktop-GL
  GLArea texture and falls back to a per-frame CPU readback of the window that is retained forever —
  verified at ~400 MB/s under a sustained output flood on GTK 4.22.4, against flat RSS with the pair set.
  Upstream ghostty's `setGtkEnv()` sets the same pair, and the spellings follow it across GTK's rename:
  `GDK_DISABLE=gles-api,vulkan` on 4.16 and above, `GDK_DEBUG=gl-disable-gles,vulkan-disable` on 4.14–4.15,
  nothing below.
  An ordinary user value is appended to per token rather than clobbered, so a `GDK_DEBUG=frames` survives.
  GDK's special `all` token complements the rest of the list, so there the required flags must be removed
  from the textual exclusions instead; appending them would re-enable GLES and Vulkan.
  `gtk_get_major_version`/`gtk_get_minor_version` are the ONLY GTK calls allowed above the `setenv` loop:
  each reports the linked library's own version number, initializing nothing and opening no display.
  Children get the PRE-LAUNCH value of every variable the policy actually ASSIGNED handed back
  (`PreLaunchEnvironment.childRestore`, derived from the assignments so the two cannot drift) — `""` for
  one that was unset, which these parse-only variables treat exactly like being unset, and nothing at all
  for the variable this GTK version's branch did not touch, so on 4.16+ a child sees a restored
  `GDK_DISABLE` and no `GDK_DEBUG` key.
  This mirrors upstream's `defaultTermioEnv` scrub — agterm's renderer constraints are agterm's, and a GTK
  app launched out of agterm must never inherit them.
  Every path that spawns a child owes that restore, and they use one of two helpers because the
  precedence differs: a child environment built from scratch merges it UNDER the caller
  (`childEnvironment(merging:)` at the `GhosttySurface` env choke point, which covers every surface
  construction site at once), while a child environment COPIED from agterm's own already-mutated process
  needs the restore to WIN (`restoringChildEnvironment(_:)` — the custom-command `/bin/sh -c` and
  `notify-send`).
  A desktop-handler launch has no environment dictionary of its own, so `launchDefaultHandler(forURI:)` is
  the single seam for `g_app_info_launch_default_for_uri`: it applies the same pairs through a
  `GAppLaunchContext`, because GIO otherwise spawns the handler from agterm's own environ.
  A new child-spawning site owes one of those three, and a user who set the tokens themselves before
  launch gets THEIR value back, tokens included — that is the restore working as specified, and the one
  place the behaviour differs from upstream's unconditional removal.
- **Deferred main-actor work goes through `agtermCore`'s `MainTimer` seam — never a dispatch or
  `Task.sleep` timer.**
  The Linux app hands its main thread to GTK (`g_application_run`), and the GLib main loop drains neither
  libdispatch's main queue nor the Swift Concurrency main-actor executor.
  `DispatchQueue.main.async`/`asyncAfter`, `Task { @MainActor }` + `Task.sleep`, `Timer.scheduledTimer`, and
  `RunLoop` scheduling compile, run, and then silently never fire there — the failure mode is silence, not a
  crash, which is why it survives review.
  This binds in shared `agtermCore` too, where the dependency is easiest to miss because the file looks
  host-free.
- **Use `MainTimer.schedule(after:_:)` (it returns a cancel closure) or `Debouncer`, which is built on it.**
  `MainTimer.scheduleTimer` is the injection point; its default is `DispatchQueue.main.asyncAfter` (correct
  on macOS, dead on Linux) and the Linux app replaces it exactly once in `installGLibMainTimer()`
  (`GLibMainTimer.swift`), at the top of `activateApplication`.
  Keep that default Dispatch-based — the GLib code belongs in the Linux target.
- **Main-thread HOPS use `runOnMain` (`g_idle_add`), which exists only in the Linux target.**
  Host-free `agtermCore` has no hop seam: from main-actor core code use `MainTimer.schedule(after: 0)`; add a
  hop seam next to `MainTimer` only if a real need appears.
  The one deliberate exception in core is `AppStore+AutoFollow`'s observation callback, a nonisolated→main
  hop the `@MainActor` timer seam cannot express — and unreachable under GTK.
- **A repeating or long-lived timer stays on the Linux side** with a direct `g_timeout_add`;
  `MainTimer` is deliberately one-shot.
  Two live here: `LinuxAutoFollowCoordinator`'s idle tick, and `SplitRatioRestoreCoordinator`'s 50 ms
  divider-restore poll (`AppControllerSurfaces.scheduleSplitRatioRestore`, whose tick returns
  `G_SOURCE_CONTINUE` until the paned has a width), each owning its `guint` source id and its own
  `g_source_remove` cancel.
- **Derive a coupled delay from the constant it trails**, never re-hardcode it — `reconcileSoftClose`
  schedules at the soft-close `grace + 0.1` so it cannot drift from the finalizer it must follow.
- **The grace window is a state, not a schedule — nothing that runs DURING it may reap a held session.**
  `AppController.reconcile` drops the host surfaces of every session the visible tree no longer names, and a
  soft close deliberately takes its session OUT of the tree while its record waits out the grace, so
  `reconcile` unions `AppStore.pendingHeldSessionIDs()` into the live set ITSELF rather than trusting the
  soft-close caller to pass the ids.
  A per-call opt-out would only cover the one reconcile the soft close arms; the ~40 other `reconcile()`
  calls (sidebar edits, `session.new`, the auto-follow timer) would still free the shells an undo promises
  to bring back — and the undo would then quietly spawn a fresh login shell and report success.
- **A deferred job that touches GTK widgets must be CANCELLED in `windowWillClose`, and `[weak self]` is not
  enough.**
  `windowWillClose` runs synchronously inside the close-request handler and GTK destroys the widget tree
  right after, but the controller itself survives whenever something still `passRetained`s it (a Settings
  dialog, the palette, the theme picker), so a live weak reference is exactly the use-after-free case.
  Keep the returned cancel closure — `AppController.softCloseReconcile`
  (`SoftCloseReconcileCoordinator`) is the pattern for a one-shot job, the `Debouncer`s for repeated ones —
  and disarm it alongside the other teardown there.
- **A STORE-scoped deferred job is not covered by those cancels — `windowWillClose` FINALIZES it.**
  The soft-close grace finalizer is armed on `AppStore`, not on the controller, so no window-scoped
  `cancel()` reaches it and it ends in `AppStore.save()`, which would re-create `windows/<id>.json` after
  `WindowLibrary.removeWindow` deleted it (window delete closes the window first, then removes it).
  `windowWillClose` calls `store.finalizeAllPendingCloses()` and the quit path calls
  `WindowLibrary.finalizeAllPendingCloses()` from `flushOnQuit`.
  Finalize, never cancel: cancelling strands the held records and leaks the surfaces, watermark PNGs and
  recency entries that only the finalizer's teardown sweeps.
- **EVERY dialog this window owns is dismissed in `windowWillClose` — not just the theme picker.**
  A bare toplevel (`gtk_window_new` + `gtk_window_set_transient_for`, today the theme picker and the command
  palette) is NOT destroyed with its transient parent under GTK4: left up it stays on screen orphaned, keeps
  the controller alive through the `passRetained` on its "destroy" handler — which is what lets every other
  deferred job outlive the window — and runs its rows against a freed widget tree.
  An AdwDialog hosted in the window (the Settings dialog, and the Keyboard Shortcuts / About dialogs its
  `prepareAuxiliaryDialog` sibling builds) does go away with it, but it holds the same `passRetained` on
  "closed", so force-close it here rather than trusting libadwaita's host teardown to emit the signal.
  The auxiliary pair is tracked in `AppController.auxiliaryDialogs` and swept by `dismissAuxiliaryDialogs()`,
  because it is built ad hoc (no single `settingsDialog`-style slot) and the Keyboard Shortcuts dialog's
  "Open Settings" button would otherwise drive `showSettings` against a destroyed widget tree.
  Dismissal for a dialog carrying unpersisted preview state is a CANCELLATION (revert + clear the override),
  never a bare close — the theme picker goes through `cancelTheme()` (which guards on "is a picker up?"
  itself), not `closeThemePicker`.
  Adding a dialog to `AppController` means adding its dismissal there in the same change.
  A dialog whose retained context is released by its OWN async callback and re-checked with a
  `gWindows[controller.windowID] === controller` staleness guard (the GtkFileDialog choosers) needs no
  dismissal — GTK owns the dialog and the guard is what makes the late callback a no-op.
- **A deferred job that rebuilds the sidebar defers while the user is interacting with it.**
  `rebuildSidebar()` destroys every row, so an async rebuild landing on a live inline rename commits its
  half-typed text (the entry's disposal fires a focus-out) and dismisses an open context menu.
  Gate on the shared `AppController.sidebarInteractionInProgress` and re-arm at
  `AppController.sidebarInteractionRetryInterval` instead of dropping the rebuild; a SYNCHRONOUS rebuild is a
  direct consequence of a user action and is deliberately not gated.
  Both live with the GATE, not with either deferred job — `SoftCloseReconcileCoordinator` takes the cadence
  by injection so it stays independent of what its `deferWhile` reads.
- **A deferred job must not GRAB keyboard focus — that gate covers the sidebar only.**
  `reconcile()` defaults to `focusActive: true`, which ends in `grab_focus` on the active session's pane, so
  a timer-driven reconcile takes the keyboard away from whatever the user moved to during the delay.
  `sidebarInteractionInProgress` sees only the inline rename and the context menu; the in-terminal search
  entry and the quick terminal are plain widgets in the SAME toplevel and are invisible to it, so a grab
  silently reroutes the rest of the user's typing into a live shell.
  Pass `reconcile(focusActive: false)` from any timer (the trailing soft-close reconcile does);
  focus belongs to the SYNCHRONOUS reconcile that the user's own action drives.
- **Tests that swap `MainTimer.scheduleTimer` go through `withFakeMainTimer`** (agtermCore test fixtures):
  the seam is a process-global static and swift-testing runs in parallel, so the swap window must contain no
  `await` — the helper's synchronous closure makes that unrepresentable.
  The exception is the Linux `AgtermLinuxTests` suite, which cannot see the core test fixtures at all
  (separate package): `GLibMainTimerTests` installs the REAL GLib seam through its own synchronous
  `withGLibMainTimer` helper, holding the same no-`await` contract.
  A Linux test whose subject takes its scheduler by INJECTION (`SoftCloseReconcileCoordinator`) touches no
  global seam and needs neither helper.
- If a debounce, delay, or grace window "does nothing on Linux", check which mechanism scheduled it before
  suspecting the logic.
  Full contract, the repro matrix, and the unpersisted-preview override pattern:
  `agterm-linux/docs/main-loop.md`.
