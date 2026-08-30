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

`HeldControlKeys` tracks held Ctrl **keycodes**, and the commit fires only once the set empties.
This matches macOS's `.control`-cleared test, which the GDK event cannot answer on its own: a
release carries the modifier state from BEFORE it, so the control bit is set on every Ctrl release
whether or not the other Ctrl key is still down (see `ModifierKeyMods`).
Keycodes, not keyvals — a Caps-remapped Control_L reports the same keyval as the real one.
Any press arriving with the control bit clear resyncs the set, so a release lost to a blur or a
keyboard grab heals on the next unmodified keystroke instead of stranding a phantom that would
block every later commit.

## A terminal blur cancels the cycle

The release reaches only the surface that still holds the keyboard, so a blur would otherwise
strand a frozen candidate list for the next Ctrl release to commit.
The cancel is deliberately broader than that reason: a focus move to a sibling surface of the same
window (an auto-follow reconcile, an opened split) cancels a cycle macOS would still commit.
Accepted — and the reason the overlay card is never focusable.
