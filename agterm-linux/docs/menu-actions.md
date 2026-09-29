# Ctrl-Tab session switcher (GTK/Linux)

How the fork reaches macOS's commit-on-release semantics without app-wide event monitors.
Nothing auto-loads this document — read it before editing `LinuxSessionSwitcher.swift`,
the switcher half of `AppControllerSessionPicker.swift`, `AppControllerCallbacks.swift`, or the
`session-switch-commit` scenario in `agterm-linux/tests/atspi_smoke.py`.
The cross-platform contract it implements is `.claude/rules/menu-actions.md` ("Ctrl-Tab snapshots
`sessionRecency` and cycles without reordering until commit").

## No app-wide monitor, and none needed

macOS installs app-wide key-down and flags-changed monitors.
GTK has no equivalent, and the fork needs none: Ctrl-Tab, its Ctrl release, and Esc all reach the
focused surface's key controller.
The window's own controller carries a second Ctrl-release handler for the sessionless case, where a
restore that dropped a dangling selected id leaves `activeSession == nil` over live sessions and no
surface holds focus — without it a cycle could begin there and nothing would ever commit it.
Both handlers are bubble-phase and `commitSessionSwitch` is idempotent, so the double delivery a
focused surface produces is a no-op.

## The commit waits for the LAST Ctrl key

The release handler schedules one zero-delay `MainTimer` turn, then reads the keyboard device's
**current** modifier state and commits only once its Ctrl bit clears.
This matches macOS's `.control`-cleared test, which the GDK event mask cannot answer on its own: a
release event carries the modifier state from BEFORE it, so that mask's control bit is set whether or
not the other Ctrl key remains down (see `ModifierKeyMods`).
GTK's device state is also still pre-release while the signal callback runs, which is why the read is
deferred through the installed GLib timer seam rather than performed inline.
The device read also sees physical Ctrl keys already held when the controller gained focus.
The deferred closure reacquires the default display, seat, and keyboard; no event-owned pointer leaves
the callback.
`HeldControlKeys` tracks observed Ctrl keycodes as a fallback for a backend that supplies no current
event device.
Any press arriving with the control bit clear resyncs that set, so a lost release heals on the next
unmodified keystroke instead of blocking every later commit.

## A terminal blur cancels the cycle

The release reaches only the surface that still holds the keyboard, so a blur would otherwise
strand a frozen candidate list for the next Ctrl release to commit.
The cancel is deliberately broader than that reason: a focus move to a sibling surface of the same
window (an auto-follow reconcile, an opened split) cancels a cycle macOS would still commit.
Accepted — and the reason the overlay card is never focusable.
