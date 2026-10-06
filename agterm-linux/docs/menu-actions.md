# Ctrl-Tab session switcher (GTK/Linux)

How the fork reaches macOS's commit-on-release semantics without app-wide event monitors.
Nothing auto-loads this document — read it before editing `LinuxSessionSwitcher.swift`,
`AppController+SessionSwitchCapture.swift`, the switcher half of `AppControllerSessionPicker.swift`,
`AppControllerCallbacks.swift`, or the `session-switch-*` scenarios in
`agterm-linux/tests/atspi_smoke.py`.
The cross-platform contract it implements is `.claude/rules/menu-actions.md` ("Ctrl-Tab snapshots
`sessionRecency` and cycles without reordering until commit").

## A capture-phase window controller stands in for the monitors

macOS installs app-wide key-down and flags-changed monitors.
GTK has no equivalent; the nearest is one capture-phase key controller on the main window, which sees
every key before whatever holds focus: a surface, a pane-lead cover, the search bar or sidebar rename
entry, an in-window `AdwDialog`, or nothing in a sessionless window.
It owns every switcher key — the Ctrl+Tab variants, Esc while a cycle is up, held-Ctrl tracking, and the
release commit — so `handleKey` never sees one.
Ctrl-Tab is consumed even when no cycle begins, or GTK would turn it into a focus move.
It stays in `isLinuxReservedChord` so no keymap can rebind it.
Esc with no cycle up propagates unchanged to the search bar, rename entry, or terminal.
A consumed press never reaches the surface, so the controller itself notes user activity (a long hold
keeps re-arming the auto-follow idle timer) and abandons an armed custom-command leader.

## The gate, and what ends a live cycle

`SessionSwitcherPolicy.canSwitch` is macOS's `uiActionsEnabled` test: terminal zoom, the dashboard, a
pending modal pick, a visible in-window dialog, or an open popover each owns the keyboard, so a cycle
neither begins nor commits under one.
The dialog term exists because the capture controller also sees a dialog's keys; one
`adw_application_window_get_visible_dialog` read covers every `AdwDialog` with no per-site bookkeeping.
The commit re-checks the gate, which is what covers anything opened mid-hold.
A live cycle also ends without selecting when:

- the window deactivates, because the Ctrl release lands in whichever window took over, including the
  palette and control picker windows;
- `popupPopover` opens a popover, which takes the keyboard;
- a terminal blurs (below).

Cycling leaves an entry's focus alone, and Esc during a cycle cancels only the switcher, so search text
and a rename in progress survive.
A commit grabs the new surface, so a rename entry's focus `leave` commits the rename exactly once through
its own path.

## The commit waits for the LAST Ctrl key

The release handler schedules a GLib idle through `runOnMain`, then reads the keyboard device's
**current** modifier state and commits only once its Ctrl bit clears.
This matches macOS's `.control`-cleared test, which the GDK event mask cannot answer on its own: a
release event carries the modifier state from BEFORE it, so that mask's control bit is set whether or
not the other Ctrl key remains down (see `ModifierKeyMods`).
GTK/X11 updates its cached device state in a separate `XkbStateNotify` after the release event.
The cached state can still report Ctrl held from a zero-delay `MainTimer` callback, stranding the cycle.
The idle runs below GDK's event priority, giving pending GDK work precedence before the read.
The device read also sees physical Ctrl keys already held when the window gained focus.
The deferred closure reacquires the default display, seat, and keyboard; no event-owned pointer leaves
the callback.
`HeldControlKeys` tracks observed Ctrl keycodes as a fallback for a backend that supplies no current
event device.
Any press arriving with the control bit clear resyncs that set, so a lost release heals on the next
unmodified keystroke instead of blocking every later commit.

## A terminal blur cancels the cycle

It is the catch-all for a focus move no gate term names, and it is broader than macOS: a move to a
sibling surface of the same window (an auto-follow reconcile, an opened split) cancels a cycle macOS
would commit.
Accepted — and the reason the overlay card is never focusable.
