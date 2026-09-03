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
  A bare toplevel (`gtk_window_new` + `gtk_window_set_transient_for`, today the theme picker, the command
  palette, and the control-pick window — dismissed there as
  `dismissControlPick(retainResultThroughRegistry: true, refocus: false)`, retaining the pick's terminal
  result so a poll after the window died still reads it) is NOT destroyed with its transient parent under
  GTK4: left up it stays on screen orphaned, keeps
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
- **A deferred job that rebuilds the sidebar defers while the user is interacting with it — including with
  the KEYBOARD.**
  `rebuildSidebar()` destroys every row, so an async rebuild landing on a live inline rename commits its
  half-typed text (the entry's disposal fires a focus-out) and dismisses an open context menu.
  Gate on the shared `AppController.sidebarInteractionInProgress` and re-arm at
  `AppController.sidebarInteractionRetryInterval` instead of dropping the rebuild; a SYNCHRONOUS rebuild is a
  direct consequence of a user action and is deliberately not gated.
  Both live with the GATE, not with either deferred job — `SoftCloseReconcileCoordinator` takes the cadence
  by injection so it stays independent of what its `deferWhile` reads.
  The gate's third disjunct is `sidebarHoldsKeyboardFocus` — the window's focus widget is a MAPPED
  descendant of `sidebarBox` — which covers Tab-parked focus on the disclosure, the add-session "+" or a
  session row; it is read from GTK rather than tracked, because unlike the other two it is a widget
  identity and not a state the app is in.
  Deferral rather than repair, because a deferred rebuild does not leave the window keyboard-dead the way a
  synchronous one does: GTK re-homes focus at the next frame to the first focusable widget (the workspace
  disclosure), silently RESETTING the user's Tab position from a timer they never triggered.
  A regression probe must therefore park ONE Tab further along than the disclosure, which recovers onto its
  own replacement and passes either way (`chrome-focus-sidebar` parks on the add-session button).
  The `mapped` test keeps the gate self-clearing: focus inside a HIDDEN sidebar or a minimized window is
  not a position worth preserving, and deferring on it would stall the refresh with nothing left to repair it.
- **A deferred job must not GRAB keyboard focus — that gate covers the sidebar only.**
  `reconcile()` defaults to `focusActive: true`, which ends in `grab_focus` on the active session's pane, so
  a timer-driven reconcile takes the keyboard away from whatever the user moved to during the delay.
  `sidebarInteractionInProgress` sees only what lives INSIDE the sidebar — the inline rename, the context
  menu, and keyboard focus parked under `sidebarBox`; the in-terminal search entry and the quick terminal
  are plain widgets in the SAME toplevel and are invisible to it, so a grab silently reroutes the rest of
  the user's typing into a live shell.
  Pass `reconcile(focusActive: false)` from any timer (the trailing soft-close reconcile does);
  focus belongs to the SYNCHRONOUS reconcile that the user's own action drives.
  What this bars is a COARSE grab, NOT `refocusIfStranded()`: that helper is steal-proof by its own guard,
  which is why deferred call sites do use it — `firePendingWorkspaceToggle`, `rebuildAfterRename()` behind
  its `runOnMain` hop, and `closeQuick()` from the quick shell's exit callback.
  The deferred sidebar rebuild still DEFERS rather than repairs, for the Tab-position reason in the bullet
  above, not because the helper is barred there.
- **Chrome buttons must never own the keyboard: EVERY chrome construction seam sets
  `gtk_widget_set_focus_on_click(…, 0)`.**
  GTK4's `GtkButton` grabs focus in its click handler by default, and the terminal receives keys ONLY
  through its own surface controller (`onEmptyWindowKeyPressed` returns 0 whenever a session is active), so
  a button left holding focus both re-fires on the next Space and swallows every character typed after it,
  with no chord able to recover.
  `grep -rn focus_on_click agterm-linux/Sources` is the inventory, rather than a list here that goes stale
  at the next seam; a button inside a POPOVER is the one exception, where the flag would be cargo cult
  because the popover itself owns the theft (see the popover bullet below).
  Leave `can-focus` ALONE — Tab reachability and screen readers depend on it — which is why
  `focus-on-click` is only HALF the invariant: it governs the CLICK, and a keyboard user can still hold
  focus ON a chrome button and press Space, so a handler that DESTROYS its own button owes the keyboard
  repair as well (`rebuildSidebarKeepingKeyboard`, next bullet).
- **Hiding or destroying a focused widget strands the keyboard, and GTK will NOT fix it for you.**
  GTK4 does not clear the window's focus widget on unmap — `gtk_window_get_focus` keeps returning the same
  widget with `gtk_widget_get_mapped == 0`, and keystrokes then reach NOTHING.
  So `refocusIfStranded()` (`AppControllerSurfaces.swift`) treats "focus is nil, or focus is unmapped while
  the TOPLEVEL is mapped" as stranded: a nil-only guard would be dead code, and dropping the toplevel
  qualifier would let a minimized window (where every descendant reports `mapped == 0`) steal focus from a
  live owner.
  That qualifier is also the safety property — a live owner (a visible quick terminal, the dashboard
  key-catcher, the in-terminal search entry) is mapped, so the helper can never take the keyboard from one —
  and it opens with the `gWindows[windowID] === self` staleness guard, because `closeQuick()` reaches it
  from the quick shell's exit callback, which `runOnMain` can drain after `windowWillClose`.
  `grep -rn refocusIfStranded agterm-linux/Sources` is the call-site inventory.
  The sidebar's own buttons are the KEYBOARD-only case `focus-on-click` cannot reach: `can-focus` is
  deliberately intact, so Space on the Tab-focused disclosure runs `toggleWorkspaceCollapse`, whose
  `rebuildSidebar()` destroys the button holding the keyboard.
  That handler, and every other workspace-focus mutation that rebuilds the sidebar (the
  `AppControllerWorkspaceFocus.swift` handlers, the `workspace.focus`/`workspace.filter` control arms),
  routes through `rebuildSidebarKeepingKeyboard()` (`AppControllerSidebar.swift`).
  Every NON-FOCUS-CHANGING control mutation that rebuilds sidebar chrome uses the same wrapper; an
  intentional focus operation may use a bare rebuild only when it immediately grabs its explicit target.
  The repair belongs at the HANDLERS, not at the tail of `rebuildSidebar()`: that function also runs from
  the deferred metadata refresh, and a grab inside it re-enters it through `surfaceDidFocus`, rebuilding
  the sidebar from inside a rebuild whose caller still holds pointers to the rows the inner one destroyed.
  The ONE tail repair `rebuildSidebar()` carries is scoped to the popovers it dismisses itself with
  `refocus: false` (the context menu; the session picker its
  `updateAttentionButton`/`updateRecentSessionsButton` calls take down), and fires only when one actually
  came down: it restores the search ENTRY if `popupPopover`'s capture — read before those dismissals
  consume it — says the popover took the keyboard from a live search, else `refocusIfStranded()`.
  Known limitation, accepted: because the unmapped disjunct is qualified by the TOPLEVEL being mapped, a
  HIDE performed while the window itself is unmapped (`agtermctl quick hide` on a minimized window) is
  never repaired; the destroy case still works, since the `focus == nil` disjunct carries no such qualifier.
- **A terminal blur ends the half-finished keyboard interactions that surface owns.**
  `surfaceFocusLeave` (`GhosttySurface.swift`) abandons a typed custom-command leader AND an in-flight
  Ctrl-Tab cycle. Why the cancel is broader than the blur that triggers it:
  `agterm-linux/docs/menu-actions.md`.
  A Ctrl release schedules its commit through `MainTimer.schedule(after: 0)`: GTK's keyboard-device
  modifier state remains pre-release inside the signal callback and becomes current on the next GLib
  turn. Reacquire the display/seat/keyboard there; never retain the event or its borrowed pointers.
- **A GtkPopover takes the keyboard on popup and does NOT give it back — the dismissal has to.**
  Measured (GTK 4.22): `gtk_popover_popup` moves the window's focus widget onto the popover's first item
  WHETHER OR NOT that item sets `focus-on-click`, and `gtk_popover_popdown` hands focus to the popover's
  PARENT — never back to the widget that held it before, and `refocusIfStranded()` cannot see that case
  because the parent is mapped.
  BOTH popovers therefore route every dismissal through `AppController.detachPopover(_:popdown:refocus:)`,
  which unparents and then calls `focusActiveSurface()` when the keyboard is inside the dying popover,
  already parked on its host, or gone — that focus test is what makes it steal-proof, since a live owner
  elsewhere is none of those.
  **The UNPARENT is ordered BEFORE the grab because the grab has to outlive the popdown**: `"closed"` is
  emitted from INSIDE `gtk_popover_popdown` before it moves focus to the parent, so a grab taken while the
  popover is still parented is silently undone; the unparent also stays SYNCHRONOUS for the close-hang
  bullet below, and a programmatic dismissal (`dismissContextMenu`/`dismissSessionPicker`) clears its own
  handle BEFORE popping down so its `"closed"` handler early-returns instead of unparenting twice.
  **The ONE pre-popover owner the repair cannot re-derive is the in-terminal SEARCH ENTRY** —
  `focusActiveSurface()` resolves surfaces, so a dismissal landing in the shell under a still-visible bar
  would reroute the rest of the user's query into the terminal.
  Every opener therefore pops up through `AppController.popupPopover`, which records
  `searchEntryHoldsKeyboard()` (the shared predicate in `Search.swift`); a `refocus: true` dismissal
  restores the ENTRY through `restoreSearchEntryFocus()`, which declines once the search ended or its bar
  is unmapped (a grab on an unmapped entry is a silent no-op that would leave the keyboard NOWHERE), and
  `becameFrontmost()` consults the same predicate and declines its own grab — which is what makes the pair
  ORDER-INDEPENDENT.
  A `refocus: false` dismissal consumes the capture along with the grab, so the two callers whose popovers
  may genuinely have taken the keyboard from the entry — `rebuildSidebar()`'s tail and
  `activateSessionPickerRow` — read the capture BEFORE dismissing and restore the ENTRY first in their own
  repair; and an opener that CHANGES the selection ends a live search BEFORE it selects
  (`endSearchForSelectionChange()`, the `selectSession` convention it mirrors), because its own
  `showActive()` moves the keyboard off the entry before the capture would run.
  **A dismissal that is about to be replaced, or torn down, passes `refocus: false`** — the detach still
  runs and only the grab is skipped, because that grab is not free there: it lands in `surfaceDidFocus`,
  which rebuilds the whole sidebar from inside an opener still holding the row's pointers, or from inside
  `windowWillClose`.
  A new popover needs the `"closed"` seam, not a hand-rolled regrab.
  The bar is on the GRAB, not on the dismissal, so it covers every OTHER grab an opener makes too:
  `showRowContextMenu`'s select-on-right-click branch calls `showActive(focus: false)`, because that grab
  lands in the same rebuild and frees the `GtkListBox` it is about to parent the menu to.
  A REPLACEMENT opener also reads the capture before its own dismissal and hands it to
  `popupPopover(_:keepingCapture:)`, because re-reading the entry there answers `false` — the outgoing
  popover, not the entry, holds the keyboard at that moment.
  It reads it through `searchEntryCaptureSurvives(_:)`, which carries the `true` only while the OUTGOING
  popover still owns the keyboard: focus can move to a live surface while a popover is up (a control
  command grabbing one), and a stale carry would make the replacement's dismissal steal THAT surface's
  keyboard for the entry — the inverse theft.
  That ownership test belongs to the OPENERS ONLY: the two dismissal-time repairs read the flag raw, on
  purpose, because under a reactivating WM the keyboard has already left the popover by the time they run,
  so testing ownership there declines and drops the user into the shell under a live search bar — measured,
  both covering `chrome-focus-popovers` steps fail when it is applied to them.
  A deliberate competing transfer instead invalidates the capture AT ITS OWNERSHIP SEAM before grabbing.
  Every intentional terminal transfer calls `GhosttySurface.grabFocus(supersedingPopoverCapture: true)`,
  which runs `invalidatePopoverSearchEntryCapture()` after GTK accepts the grab on a mapped target; this
  covers Quick, split/pane control, notification reveal, zoom/overlay transitions, pointer clicks, and drops
  without a hidden/background surface erasing the live owner (GTK can accept a focus child on an unmapped
  deck page). Implicit repair grabs keep the default `false`, because a window-manager reactivation while a
  popover is open must not erase the search owner that dismissal still owes.
  This keeps the unconditional dismissal repair needed by reactivating WMs while making the explicit
  transfer win without timing or dismissal-time focus inference.
- **A path that hands the keyboard back after a MODE CHANGE goes through `focusActiveSurface()`, never
  `showActive()`'s own focus leg.**
  `showActive(focus:)` resolves overlay → scratch → split → primary for the active session and knows nothing
  about the surfaces that sit ON TOP of the deck: a visible quick terminal, a zoom host, an open dashboard.
  A path that ALSO has to refresh deck presentation uses `showActiveFocusingVisibleSurface()`, the two-call
  shape (`showActive(focus: false)` then `focusActiveSurface()`); it is behaviour-preserving in the plain
  case, because `focusActiveSurface`'s fallback is `searchTargetSurface(for:)`, byte-for-byte what
  `showActive` inlines.
  Its three call sites are `setTerminalZoom`'s exit leg (`AppControllerZoom.swift`), where nothing on the
  zoom path clears `quickVisible`, so `restoreZoomedSurface(.quick)` re-shows the quick card and the old
  grab landed on the deck pane behind it; `closeDashboard(refocus:)`, whose `mountDashboard` grabbed the
  dashboard host, so the close destroys the keyboard's owner and MUST hand it back — its old
  split-or-primary `focusedSurface()` leg could grab an UNMAPPED widget, a silent no-op that leaves the
  keyboard nowhere at all; and `becameFrontmost()`, the masking path for a popover dismissal, which must
  not be a COARSER refocus than the helper it preempts (the quick card is an overlay inset from the top, so
  the header bar stays clickable with a popover up, and its old grab typed into the deck shell behind a
  visible quick terminal) and which declines outright while the search entry holds the keyboard.
  A path that changes NO presentation calls `focusActiveSurface()` alone: `setQuick`'s hide leg answers
  with `refocusIfStranded()` (the same primitive behind its stranding guard);
  `finishControlPickDismissal` (`ControlPicker.swift`), a bare-toplevel dismissal behind the `gWindows`
  staleness guard, with `refocus: false` threaded from `windowWillClose` and a fire-time
  `searchEntryHoldsKeyboard()` decline; and `activateSessionPickerRow`, whose attention leg delegates to
  `handleAutoFollow` — SHARED with the auto-follow timer and so declining to focus while a quick terminal
  is visible, right for the timer but wrong for the user's own click, so both its legs end in
  `focusActiveSurface()` behind the search-entry restore above.
  The `refocus: false` callers stay on `showActive()`, which is already overlay/scratch-aware, because
  `agtermctl dashboard --close` re-targets nothing of its own.
- **A popover left PARENTED when its window is destroyed HANGS the close — the unparent's second, unmasked
  job.**
  A GtkPopover left parented to a session `GtkListBox` makes `gtk_window_destroy` spin forever: the list
  box's dispose calls `gtk_list_box_remove` on a non-row child, which refuses and never advances (measured:
  needs SIGKILL; the same run with an unparent first exits cleanly).
  GTK does NOT emit `"closed"` during that destroy, so `windowWillClose` calls `dismissContextMenu()`
  itself alongside `dismissSessionPicker()`.
  Because `contextMenuDidClose` clears `contextMenuPopover`, the handle is non-nil only while the menu is
  genuinely open — which is what lets `sidebarInteractionInProgress` defer the two deferred rebuilds
  whenever a menu is up, making the context-menu half of `rebuildSidebar()`'s tail repair unreachable from
  a deferred job.
- **A GTK4 container holds the ONLY reference to a sunk child, so detaching one FREES it — every reparent
  goes through `withWidgetRefHeld` (`GtkInterop.swift`).**
  Except its FOCUS CHILD, which carries a second reference: a reparent that survives may only have been
  holding the keyboard, which is why the fault is intermittent and why a repro must focus the pane it is
  about to destroy.
  `gtk_paned_set_start_child(paned, nil)` finalizes the host that slot held, and re-adding it links freed
  memory into the live tree: the next frame-clock layout calls through the class pointer
  `g_type_free_instance` NULLed, so the fault lands as a SIGSEGV or a `GTK_IS_WIDGET` assertion spray a
  frame away from the code that caused it. `scripts/test-linux-ui.sh` trips every scenario on the one
  spelling GTK gives that spray for a finalized widget; `split-primary-exit` carries the unnarrowed check,
  scoped to its own stderr window, for the call sites that spell the parameter `child` or `self`.
  `grep -rn withWidgetRefHeld agterm-linux/Sources` is the site inventory, rather than a list here that
  goes stale at the next seam.
  The remaining `g_object_ref` sites are not reparents and stay: an async-hop hold and a probe sink,
  plus a standalone `g_object_unref` releasing a constructor ref.
  A detach with no re-add is a teardown, not a reparent, and needs no hold.
  The hold keeps the widget ALIVE but not REALIZED, so a subtree containing a `GtkGLArea` must not be
  moved at all ([[libghostty]]).
- **A teardown path clears its own zoom target BEFORE freeing the surface.**
  While zoomed, the surface's `GtkGLArea` lives in `zoomHost` and `splitView` is hidden, so a surface torn down
  under the host stays MAPPED (the refocus guard correctly declines) over a deck nothing can reach.
  `setQuick(_:)`'s hide leg and `closeQuick()` both start with
  `if terminalZoom.target == .quick { setTerminalZoom(.off, target: .quick) }`; that is what lets
  `refocusIfStranded`'s zoom branch assume its target's surface is live.
- **The refocus lives in the SHARED apply function, not in the GUI handler.**
  `applySidebarVisibility()`'s callers are `toggleSidebar()`, the `sidebar` control arm
  (`setSidebarVisibility`), and `LinuxSettingsController.applyInactiveWindowSidebarHidingIfEnabled()`,
  which fans out over `gWindows.values` — so putting it there makes the button, `agtermctl sidebar hide`
  and the settings-driven fan-out keep-in-sync by construction instead of by three call sites someone must
  remember.
  Deliberately NOT `showActive()`: that also rewrites deck presentation, which `setTerminalZoom` suppresses
  while zoomed and the dashboard suppresses via `focus: false`.
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
