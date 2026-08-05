"""The `background-overlay-grid` AT-SPI scenario: surface sizing at realize time.

MEASUREMENT IS PTY-ONLY: every grid is read out of a terminal actually running a probe that writes its
own `stty size`. `tree` survives only for addressing, the off-screen vacuity guards, and the
`dashboardMembers` waits.

The dashboard leg is a GUARD, not a discriminator: it pins realization to dashboard-open time and is
EXPECTED to pass even with the stored `sizeFallback` removed, since `pushSize`'s deck fallback covers
that path. Do not delete it as pointless — it catches realization moving out from under the fallback.
"""

import os

from atspi_smoke import control_json, launch, stop, wait_for, window_list, window_tree


def assert_near_reference_grid(reference, sample, what):
    """A pty measurement must land within a QUARTER of the reference session's own pty grid.
    A band rather than equality because the two ptys settle at different instants (the only reading that
    ever differed did so by one column). A quarter and not half because half is not slack but a distinct
    failure mode: a deck-half spawn, 15x42 against a 30x84 reference, sits exactly ON a half bound."""
    assert (abs(sample[0] - reference[0]) <= reference[0] // 4
            and abs(sample[1] - reference[1]) <= reference[1] // 4), (
        f"{what} measured {sample[0]}x{sample[1]}, not within a quarter of the "
        f"{reference[0]}x{reference[1]} the selected reference session's own pty reports"
    )


def assert_floating_band(reference, sample, what):
    """A 60% floating panel's pty must be STRICTLY smaller than the reference pane in BOTH axes.
    The ONLY check here that can see the stored `sizeFallback`: delete `ov.sizeFallback = ...` in
    `syncOverlay` and `pushSize` falls through to `controller?.deckAllocationSize()`, so the panel spawns
    at the FULL deck and measures the reference exactly. ROWS are asserted alongside cols because the
    deck fallback is a PAIR: an estimate keeping the panel's width but the deck's HEIGHT passes a
    columns-only band. Both bounds were derived with the percentage (see its `--size-percent 60` open).
    """
    assert (reference[0] // 2 <= sample[0] < reference[0]
            and reference[1] // 2 <= sample[1] < reference[1]), (
        f"{what} reports {sample[0]}x{sample[1]}; expected strictly smaller than the reference pane "
        f"{reference[0]}x{reference[1]} on both axes and at least half of it"
    )


def verify_background_overlay_grid(env):
    """A surface realized while its deck page is HIDDEN must spawn at the pane's grid: a selected
    reference session's pty is the ground truth, and each background leg (full-pane overlay, floating
    overlay, dashboard-realized session) is measured against it through its own pty."""
    state = env["AGTERM_STATE_DIR"]
    probe = os.path.join(state, "grid-probe.sh")
    with open(probe, "w", encoding="utf-8") as target:
        # Two samples: libghostty spawns the pty inside `ghostty_surface_new` at its configured default
        # (28x79) and only then takes the `set_size` this scenario is about, so the FIRST sample is the
        # never-resized default and the SECOND, taken once everything settled, is the ground truth.
        target.write(
            "#!/bin/sh\n"
            'stty size > "$1" 2>&1\n'
            "sleep 3\n"
            'stty size > "$2" 2>&1\n'
            "sleep 3600\n"
        )
    os.chmod(probe, 0o755)

    def markers(tag):
        return os.path.join(state, f"{tag}-spawn"), os.path.join(state, f"{tag}-settled")

    def pty_grid(path):
        """(rows, cols) from one of the probe's `stty size` samples, or None until it is readable.
        An `os.path.exists` check would RACE: `stty size > "$1"` creates and truncates the marker at
        REDIRECT time and only then forks and execs `/usr/bin/stty` (not a shell builtin), so a tick
        landing in that window reads a zero-byte file. Parsing IS therefore the readiness predicate."""
        try:
            with open(path, encoding="utf-8") as source:
                rows, _, cols = source.read().strip().partition(" ")
            return int(rows), int(cols)
        except (OSError, ValueError):
            return None

    def wait_for_pty(path, what, timeout=30):
        """`pty_grid` under `wait_for`, quoting the file so a failing `stty` (the probe redirects `2>&1`)
        is distinguishable from a probe that never ran."""
        try:
            return wait_for(lambda: pty_grid(path), what, timeout=timeout)
        except AssertionError as timed_out:
            try:
                with open(path, encoding="utf-8") as source:
                    held = repr(source.read())
            except OSError as unreadable:
                held = f"<unreadable: {unreadable}>"
            raise AssertionError(f"{what}; the marker file held {held}") from timed_out

    process, _ = launch(env)
    try:
        window_id = next(item["id"] for item in window_list(env) if item["open"])

        def make_session(name, *extra):
            control_json(env, "session", "new", "--name", name, *extra, "--window", window_id, "--json")
            session = wait_for(
                lambda: next((item for workspace in window_tree(env, window_id)["workspaces"]
                              for item in workspace["sessions"] if item["name"] == name), None),
                f"session {name!r} never appeared in the tree",
            )
            return session["id"]

        # The experimental control: a SELECTED session running the same probe. Its surface is mapped, so
        # GTK layout emits `GtkGLArea::resize` and libghostty re-sizes the pty to the real pane within a
        # frame, overwriting whatever `pushSize()` estimated — which makes this settled sample ground
        # truth on a fixed build and a fix-disabled one alike. Every band below is expressed against it.
        spawn, settled = markers("reference")
        reference_id = make_session("grid-reference", "--command", f"{probe} {spawn} {settled}")
        reference = wait_for_pty(settled,
                                 "the selected reference session never reported its settled pty size")
        spawn_default = wait_for_pty(spawn,
                                     "the selected reference session never reported its spawn pty size")
        # An ABSOLUTE floor on the control, because every other band here is RELATIVE to it: a uniform
        # regression sizing every surface at half the pane satisfies them all. Measured full pane on this
        # harness (pinned 1440x900 screen) is 30x84, so 18x50 leaves ~1.67x headroom for a larger cell;
        # 16x43 is the hard lower limit, since the uniform half-shrink to reject lands on 15x42.
        assert reference[0] >= 18 and reference[1] >= 50, (
            f"the reference grid is implausibly small at {reference[0]}x{reference[1]}; every band here "
            "derives from it"
        )
        # The libghostty spawn default (28x79) sits INSIDE every band here against a ~30x84 reference, so
        # no band can tell a correctly sized surface from one never sized at all. Each leg therefore also
        # asserts its settled grid differs from this ONE captured default, not from its own spawn sample,
        # which races `pushSize()`. Failing here names a HARNESS condition, never a sizing regression.
        assert reference != spawn_default, (
            f"the reference's spawn `stty` {spawn_default[0]}x{spawn_default[1]} equals its settled "
            f"{reference[0]}x{reference[1]}, so the `settled != spawn default` guards below are vacuous"
        )

        def assert_off_screen(target, what):
            """The leg's target must be unmapped AND the reference must still be the selected session.
            A mapped surface is `::resize`-corrected, which heals whatever `pushSize()` spawned at. And
            selection is not the only way a page gets mapped: a dashboard open flips EVERY deck page
            child-visible, realizing and `::resize`-correcting every hidden surface WITHOUT moving any
            `active` flag — hence the `dashboardMembers` half. Every leg calls this on BOTH sides of its
            settle window: the sample lands seconds later and the whole span must stay unmapped."""
            tree = window_tree(env, window_id)
            sessions = {item["id"]: item
                        for workspace in tree["workspaces"]
                        for item in workspace["sessions"]}
            missing = [name for name, sid in (("the target", target), ("the reference", reference_id))
                       if sid not in sessions]
            assert not missing, (
                f"{' and '.join(missing)} session is missing from the window tree, so this guard for "
                f"{what} says nothing"
            )
            assert not sessions[target]["active"], (
                f"{what} is the ACTIVE session, so its surface is mapped and `::resize`-corrected"
            )
            assert sessions[reference_id]["active"], (
                "selection moved off the reference session, so it is no longer the mapped control"
            )
            assert not tree.get("dashboardMembers"), (
                f"the dashboard is open while {what} is measured; it maps EVERY deck page"
            )

        # Leg 1: full-pane overlay opened against a session whose deck page is hidden.
        spawn, settled = markers("full")
        background = make_session("grid-background", "--no-select")
        assert_off_screen(background, "the full-pane overlay's target session")
        control_json(env, "session", "overlay", "open", f"{probe} {spawn} {settled}",
                     "--target", background, "--window", window_id, "--json")
        settled_full = wait_for_pty(settled, "the background overlay never reported its settled pty size")
        assert_off_screen(background, "the full-pane overlay's target session")
        spawn_full = wait_for_pty(spawn, "the background overlay never reported its spawn pty size")
        assert_near_reference_grid(reference, settled_full,
                                   "the background overlay's settled pty")
        # Against the ONE default captured off the reference, not this leg's own spawn sample.
        assert settled_full != spawn_default, (
            f"the background overlay's pty never moved off the libghostty spawn default "
            f"({spawn_default[0]}x{spawn_default[1]}); the surface was never sized"
        )

        # Leg 2: floating variant. Its frame is `gtk_widget_set_visible(0)` while hidden, so the widget
        # is genuinely skipped in layout and only a stored size request can size it.
        spawn, settled = markers("floating")
        floating = make_session("grid-floating", "--no-select")
        # The 60 and the bounds in `assert_floating_band` were derived TOGETHER against a 30x84
        # reference. `--size-percent` is taken against `deckOverlay` — wider than the deck by the sidebar,
        # taller by the header bar — so the panel's share of the DECK runs ahead of the percentage, by a
        # different amount per axis: cols reach the reference at 78 % (binding the strict `<`), rows fall
        # below half at 47 % (binding the lower bound). Only 47 % <= pct <= 77 % brackets both; 60 is mid.
        assert_off_screen(floating, "the floating overlay's target session")
        control_json(env, "session", "overlay", "open", f"{probe} {spawn} {settled}",
                     "--size-percent", "60", "--target", floating, "--window", window_id, "--json")
        # The pty is the ONLY channel here: the frame is never mapped while the session is backgrounded,
        # so no `::resize` can correct the spawn estimate.
        settled_floating = wait_for_pty(
            settled, "the floating background overlay never reported its settled pty size")
        assert_off_screen(floating, "the floating overlay's target session")
        spawn_floating = wait_for_pty(
            spawn, "the floating background overlay never reported its spawn pty size")
        assert_floating_band(reference, settled_floating, "the floating overlay's settled pty")
        assert settled_floating != spawn_default, (
            f"the floating overlay's pty never moved off the libghostty spawn default "
            f"({spawn_default[0]}x{spawn_default[1]}); the stored frame estimate was never applied"
        )

        # Leg 3: a dashboard open flips EVERY page child-visible, realizing sessions never shown yet.
        spawn, settled = markers("dashboard")
        # The id is kept only to bracket the settle window with `assert_off_screen`; nothing may SELECT
        # this session, or `::resize` would overwrite the grid the map storm gave it.
        dashboard_id = make_session("grid-dashboard", "--no-select",
                                    "--command", f"{probe} {spawn} {settled}")
        # Vacuity guard: the probe has not run yet, so nothing could have been measured yet.
        assert not os.path.exists(spawn), (
            "the --no-select session ran its command before the dashboard opened; the leg is vacuous"
        )
        control_json(env, "dashboard", "--mru", "--window", window_id, "--json")
        wait_for(lambda: window_tree(env, window_id).get("dashboardMembers"), "dashboard did not open")
        # Realization happened AT DASHBOARD-OPEN TIME: GTK4 maps and realizes synchronously inside
        # `gtk_widget_set_child_visible(1)`, which is what lets this tell map-storm realization from
        # realization later on.
        wait_for(lambda: os.path.exists(spawn),
                 "the dashboard open did not realize the --no-select session", timeout=30)
        control_json(env, "dashboard", "--close", "--window", window_id, "--json")
        wait_for(lambda: not window_tree(env, window_id).get("dashboardMembers"), "dashboard did not close")
        # Bracketed like the two overlay legs, so the settled sample can only describe the map storm.
        assert_off_screen(dashboard_id, "the dashboard-realized session")
        settled_dashboard = wait_for_pty(
            settled, "the dashboard-realized session never reported its settled pty size")
        assert_off_screen(dashboard_id, "the dashboard-realized session")
        assert_near_reference_grid(reference, settled_dashboard,
                                   "a session realized by a DASHBOARD open, before any select")
        # Same anti-vacuity check the other two legs carry, against the same captured default.
        assert settled_dashboard != spawn_default, (
            f"the dashboard-realized session's pty never moved off the libghostty spawn default "
            f"({spawn_default[0]}x{spawn_default[1]}); the surface was never sized"
        )
        # The floating leg's bounds are DERIVED from these pairs, so keep them in the log.
        def show(grid):
            return f"{grid[0]}x{grid[1]}"

        print(f"measured: reference {show(reference)} (spawn default {show(spawn_default)}) | "
              f"full-pane {show(settled_full)} (spawn {show(spawn_full)}) | "
              f"floating-60 {show(settled_floating)} (spawn {show(spawn_floating)}) | "
              f"dashboard {show(settled_dashboard)}")
        print("OK: surfaces realized behind a hidden deck page spawn at the pane grid")
    finally:
        stop(process)
