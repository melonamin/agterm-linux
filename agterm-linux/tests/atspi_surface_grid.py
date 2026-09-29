"""The `background-overlay-grid` AT-SPI scenario: surface sizing at realize time.

MEASUREMENT IS PTY-ONLY: every grid is read out of a terminal actually running a probe that writes its
own `stty size`. `tree` survives only for addressing, the off-screen vacuity guards, and the
`dashboardMembers` waits.

The dashboard leg is a GUARD, not a discriminator: it pins realization to dashboard-open time and is
EXPECTED to pass even with the stored `sizeFallback` removed, since `pushSize`'s deck fallback covers
that path. Do not delete it as pointless — it catches realization moving out from under the fallback.

The deterministic `GhosttySurfaceGeometryTests.creationPushesFallbackSize` test records the exact size
sent through the immediate post-creation libghostty boundary. This E2E deliberately samples only settled
PTY grids; it must never infer correctness from whether a child happened to run before that size push.
"""

import os

from atspi_smoke import control_json, launch, stop, wait_for, window_list, window_tree


def assert_near_reference_grid(reference, sample, what):
    """A pty measurement must land within a QUARTER of the reference session's own pty grid.
    A band rather than equality because the two ptys settle at different instants (the only reading that
    ever differed did so by one column). A quarter and not half because half is not slack but the distinct
    deck-half failure mode, which would sit exactly ON an inclusive half bound."""
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
        # One SETTLED sample only. An earlier sample is scheduler-dependent: a correct host may push the
        # initial size before the child runs, so no assertion may require observing libghostty's default.
        target.write(
            "#!/bin/sh\n"
            'if [ -n "$2" ]; then : > "$2"; fi\n'
            "sleep 3\n"
            'stty size > "$1" 2>&1\n'
            "sleep 3600\n"
        )
    os.chmod(probe, 0o755)

    def markers(tag):
        return os.path.join(state, f"{tag}-grid")

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
        sample = markers("reference")
        reference_id = make_session("grid-reference", "--command", f"{probe} {sample}")
        reference = wait_for_pty(sample,
                                 "the selected reference session never reported its settled pty size")
        # An ABSOLUTE floor on the control, because every other band here is RELATIVE to it: a uniform
        # regression sizing every surface at half the pane satisfies them all. These conservative bounds
        # stay well below the pinned 1440x900 harness's normal full-pane grid but above a half-size spawn.
        assert reference[0] >= 18 and reference[1] >= 45, (
            f"the reference grid is implausibly small at {reference[0]}x{reference[1]}; every band here "
            "derives from it"
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
        sample = markers("full")
        background = make_session("grid-background", "--no-select")
        assert_off_screen(background, "the full-pane overlay's target session")
        control_json(env, "session", "overlay", "open", f"{probe} {sample}",
                     "--target", background, "--window", window_id, "--json")
        settled_full = wait_for_pty(sample, "the background overlay never reported its settled pty size")
        assert_off_screen(background, "the full-pane overlay's target session")
        assert_near_reference_grid(reference, settled_full,
                                   "the background overlay's settled pty")

        # Leg 2: floating variant. Its frame is `gtk_widget_set_visible(0)` while hidden, so the widget
        # is genuinely skipped in layout and only a stored size request can size it.
        sample = markers("floating")
        floating = make_session("grid-floating", "--no-select")
        # `--size-percent` is taken against the same terminal deck as the reference. The half-to-full band
        # allows frame chrome and terminal-cell rounding while rejecting either a full-deck fallback or a
        # severely undersized initial surface.
        assert_off_screen(floating, "the floating overlay's target session")
        control_json(env, "session", "overlay", "open", f"{probe} {sample}",
                     "--size-percent", "60", "--target", floating, "--window", window_id, "--json")
        # The pty is the ONLY channel here: the frame is never mapped while the session is backgrounded,
        # so no `::resize` can correct the spawn estimate.
        settled_floating = wait_for_pty(
            sample, "the floating background overlay never reported its settled pty size")
        assert_off_screen(floating, "the floating overlay's target session")
        assert_floating_band(reference, settled_floating, "the floating overlay's settled pty")

        # Leg 3: a dashboard open flips EVERY page child-visible, realizing sessions never shown yet.
        sample = markers("dashboard")
        started = os.path.join(state, "dashboard-started")
        # The id is kept only to bracket the settle window with `assert_off_screen`; nothing may SELECT
        # this session, or `::resize` would overwrite the grid the map storm gave it.
        dashboard_id = make_session("grid-dashboard", "--no-select",
                                    "--command", f"{probe} {sample} {started}")
        # Vacuity guard: the probe writes `started` before its deliberate settle delay. Checking the
        # later pty marker here would allow a prematurely running child to hide inside that delay.
        assert not os.path.exists(started), (
            "the --no-select session ran its command before the dashboard opened; the leg is vacuous"
        )
        assert not os.path.exists(sample), (
            "the --no-select session reported a pty grid before the dashboard opened; the leg is vacuous"
        )
        control_json(env, "dashboard", "--mru", "--window", window_id, "--json")
        wait_for(lambda: window_tree(env, window_id).get("dashboardMembers"), "dashboard did not open")
        # Realization happened AT DASHBOARD-OPEN TIME: GTK4 maps and realizes synchronously inside
        # `gtk_widget_set_child_visible(1)`, which is what lets this tell map-storm realization from
        # realization later on.
        wait_for(lambda: os.path.exists(started),
                 "the dashboard-open surface did not start its probe", timeout=30)
        control_json(env, "dashboard", "--close", "--window", window_id, "--json")
        wait_for(lambda: not window_tree(env, window_id).get("dashboardMembers"), "dashboard did not close")
        # Bracketed like the two overlay legs, so the settled sample can only describe the map storm.
        assert_off_screen(dashboard_id, "the dashboard-realized session")
        settled_dashboard = wait_for_pty(
            sample, "the dashboard-realized session never reported its settled pty size")
        assert_off_screen(dashboard_id, "the dashboard-realized session")
        assert_near_reference_grid(reference, settled_dashboard,
                                   "a session realized by a DASHBOARD open, before any select")
        # The floating leg's bounds are DERIVED from these pairs, so keep them in the log.
        def show(grid):
            return f"{grid[0]}x{grid[1]}"

        print(f"measured: reference {show(reference)} | "
              f"full-pane {show(settled_full)} | "
              f"floating-60 {show(settled_floating)} | "
              f"dashboard {show(settled_dashboard)}")
        print("OK: surfaces realized behind a hidden deck page spawn at the pane grid")
    finally:
        stop(process)
