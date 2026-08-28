"""Behavioral smoke for cold and warm freedesktop Desktop Entry Action delivery."""

import os

import subprocess
import tempfile

from gi.repository import Gio

from atspi_smoke import (
    BIN,
    REPO,
    control_json,
    launch,
    named,
    press_escape,
    stop,
    wait_for,
    window_list,
    window_tree,
)


def invoke(env, action):
    subprocess.run(
        [BIN, f"--desktop-action={action}"],
        check=True,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )


def session_ids(env, window_id):
    tree = window_tree(env, window_id)
    return [
        session["id"]
        for workspace in tree["workspaces"]
        for session in workspace["sessions"]
    ]

def verify_desktop_entry():
    path = os.path.join(REPO, "packaging/linux/io.github.melonamin.agterm.desktop")
    with tempfile.TemporaryDirectory(prefix="agterm-desktop-entry-") as bindir:
        os.symlink(BIN, os.path.join(bindir, "agterm-linux"))
        previous_path = os.environ.get("PATH", "")
        os.environ["PATH"] = f"{bindir}:{previous_path}"
        try:
            desktop = Gio.DesktopAppInfo.new_from_filename(path)
        finally:
            os.environ["PATH"] = previous_path
    assert desktop, "GIO could not parse the packaged desktop entry"
    expected = [
        "NewSession", "NewWindow", "QuickTerminal",
        "Dashboard", "RecentSessions", "Attention",
    ]
    assert desktop.list_actions() == expected, "packaged desktop action ids or order drifted"
    assert [desktop.get_action_name(action) for action in expected] == [
        "New Session", "New Window", "Quick Terminal",
        "Dashboard", "Recent Sessions", "Sessions Needing Attention",
    ], "packaged desktop action labels drifted"


def verify_desktop_actions(env):
    verify_desktop_entry()
    # The first action starts the primary process itself. This is the path an unpinned launcher takes when
    # agterm is not running; every later invocation is a short-lived secondary process forwarded over D-Bus.
    process, app = launch(env, ["--desktop-action=new-session"])
    try:
        window_id = wait_for(
            lambda: next((item["id"] for item in window_list(env) if item["open"]), None),
            "cold New Session action did not open a window",
        )
        wait_for(
            lambda: len(session_ids(env, window_id)) == 2,
            "cold New Session action did not add a session after activation",
        )

        invoke(env, "quick-terminal")
        wait_for(
            lambda: window_tree(env, window_id).get("quickVisible"),
            "warm Quick Terminal action did not reach the primary instance",
        )
        invoke(env, "quick-terminal")
        wait_for(
            lambda: not window_tree(env, window_id).get("quickVisible"),
            "second Quick Terminal action did not toggle the live surface off",
        )

        invoke(env, "dashboard")
        wait_for(
            lambda: window_tree(env, window_id).get("dashboardMembers"),
            "Dashboard action did not open the MRU dashboard",
        )
        invoke(env, "dashboard")
        wait_for(
            lambda: not window_tree(env, window_id).get("dashboardMembers"),
            "second Dashboard action did not close the live dashboard",
        )

        invoke(env, "recent-sessions")
        wait_for(
            lambda: named(app, "Go to Recent Session", role="frame"),
            "Recent Sessions action did not open the live MRU palette",
        )
        press_escape(process.pid, window_title="Go to Recent Session")
        wait_for(
            lambda: not named(app, "Go to Recent Session", role="frame"),
            "Recent Sessions palette did not close",
        )

        target = session_ids(env, window_id)[0]
        control_json(env, "session", "status", "blocked", "--target", target, "--json")
        invoke(env, "attention")
        wait_for(
            lambda: named(app, "Go to Attention", role="frame"),
            "Attention action did not open the live attention palette",
        )
        press_escape(process.pid, window_title="Go to Attention")

        initial_windows = len([item for item in window_list(env) if item["open"]])
        invoke(env, "new-window")
        wait_for(
            lambda: len([item for item in window_list(env) if item["open"]]) == initial_windows + 1,
            "New Window action did not create a persisted window in the primary instance",
        )
        print("OK: cold/warm desktop actions route to live GTK sessions, surfaces, palettes, and windows")
    finally:
        stop(process)
