"""Behavioral smoke for cold and warm freedesktop Desktop Entry Action delivery."""

import os
import subprocess
import tempfile
import time

from gi.repository import Atspi, Gio

from atspi_smoke import (
    BIN,
    REPO,
    collect,
    control_json,
    editable_descendant,
    launch,
    named,
    press_escape,
    raw_control_json,
    stop,
    wait_for,
    window_list,
    window_tree,
)


def invoke_arguments(env, *arguments, cwd=None):
    subprocess.run(
        [BIN, *arguments],
        check=True,
        cwd=cwd,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )


def invoke(env, action):
    invoke_arguments(env, f"--desktop-action={action}")


def sessions(env, window_id):
    return [
        session
        for workspace in window_tree(env, window_id)["workspaces"]
        for session in workspace["sessions"]
    ]


def session_ids(env, window_id):
    return [session["id"] for session in sessions(env, window_id)]


def active_session_cwd(env, window_id):
    return next(
        (session.get("cwd") for session in sessions(env, window_id) if session.get("active")),
        None,
    )


def focused_identity(root):
    focused = []
    for item in collect(root):
        try:
            if item.get_state_set().contains(Atspi.StateType.FOCUSED):
                focused.append((item.get_role_name(), item.get_name() or ""))
        except Exception:
            pass
    return sorted(focused)


def modal_snapshot(env, app, window_id):
    tree = window_tree(env, window_id)
    session_state = tuple(
        (session["id"], session.get("active"), session.get("splitFocused"), session.get("cwd"))
        for workspace in tree["workspaces"]
        for session in workspace["sessions"]
    )
    window_state = tuple(
        (window["id"], window.get("open"), window.get("active"))
        for window in window_list(env)
    )
    return (
        session_state,
        window_state,
        tree.get("quickVisible"),
        tuple(tree.get("dashboardMembers") or []),
        tree.get("dashboardHighlighted"),
        tree.get("zoomedSurface"),
        tuple(focused_identity(app)),
    )


def assert_desktop_actions_inert(env, app, window_id, actions, focus_owner=None):
    for action in actions:
        before = modal_snapshot(env, app, window_id)
        invoke(env, action)
        time.sleep(0.3)
        after = modal_snapshot(env, app, window_id)
        assert after == before, f"{action} changed window focus/state through a modal cover"
        assert not named(app, "Go to Recent Session", role="frame"), (
            f"{action} opened the recent-session palette through a modal cover"
        )
        assert not named(app, "Go to Attention", role="frame"), (
            f"{action} opened the attention palette through a modal cover"
        )
        if focus_owner is not None:
            assert focus_owner.get_state_set().contains(Atspi.StateType.FOCUSED), (
                f"{action} stole keyboard focus from the pending picker"
            )


def verify_application_command_line_paths(env):
    path_state = f'{env["AGTERM_STATE_DIR"]}-command-line'
    os.makedirs(path_state)
    path_env = dict(
        env,
        AGTERM_STATE_DIR=path_state,
        AGTERM_CONTROL_SOCKET=os.path.join(path_state, "agterm.sock"),
        AGTERM_APP_ID=f'{env["AGTERM_APP_ID"]}.paths',
    )
    root = os.path.join(path_state, "paths")
    cold_directory = os.path.join(root, "cold-absolute")
    warm_directory = os.path.join(root, "warm-absolute")
    secondary_cwd = os.path.join(root, "secondary-cwd")
    relative_directory = os.path.join(secondary_cwd, "relative-directory")
    file_directory = os.path.join(root, "file-parent")
    file_path = os.path.join(file_directory, "launch.txt")
    for directory in (
        cold_directory, warm_directory, relative_directory, file_directory,
    ):
        os.makedirs(directory)
    with open(file_path, "w", encoding="utf-8") as target:
        target.write("path adapter probe\n")

    process, _ = launch(path_env, [cold_directory])
    try:
        window_id = wait_for(
            lambda: next((item["id"] for item in window_list(path_env) if item["open"]), None),
            "cold absolute path did not register a window",
        )
        wait_for(
            lambda: active_session_cwd(path_env, window_id) == cold_directory,
            "cold absolute directory did not become the active session cwd",
        )

        invoke_arguments(path_env, warm_directory)
        wait_for(
            lambda: active_session_cwd(path_env, window_id) == warm_directory,
            "warm secondary absolute path did not become the active session cwd",
        )

        invoke_arguments(path_env, "relative-directory", cwd=secondary_cwd)
        wait_for(
            lambda: active_session_cwd(path_env, window_id) == relative_directory,
            "relative path did not resolve against the secondary process cwd",
        )

        invoke_arguments(path_env, file_path)
        wait_for(
            lambda: active_session_cwd(path_env, window_id) == file_directory,
            "file path did not resolve to its parent session cwd",
        )
        print("OK: GApplication command-line paths preserve cold/warm cwd semantics")
    finally:
        stop(process)


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
    verify_application_command_line_paths(env)
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
        wait_for(
            lambda: not named(app, "Go to Attention", role="frame"),
            "Attention palette did not close",
        )

        blocked_actions = (
            "new-session", "quick-terminal", "recent-sessions", "attention",
        )
        control_json(env, "dashboard", "--mru", "--window", window_id, "--json")
        wait_for(
            lambda: window_tree(env, window_id).get("dashboardMembers"),
            "control setup did not open Dashboard for modal-safety coverage",
        )
        assert_desktop_actions_inert(env, app, window_id, blocked_actions)
        invoke(env, "dashboard")
        wait_for(
            lambda: not window_tree(env, window_id).get("dashboardMembers"),
            "Dashboard desktop action did not close its own open grid",
        )

        control_json(
            env, "surface", "zoom", "show", "--target", "active",
            "--window", window_id, "--json",
        )
        wait_for(
            lambda: window_tree(env, window_id).get("zoomedSurface"),
            "control setup did not open Terminal Zoom for modal-safety coverage",
        )
        assert_desktop_actions_inert(env, app, window_id, (*blocked_actions, "dashboard"))
        control_json(
            env, "surface", "zoom", "hide", "--target", "active",
            "--window", window_id, "--json",
        )

        opened = raw_control_json(env, {
            "cmd": "pick.open",
            "args": {
                "items": [{"id": "one", "label": "One"}],
                "prompt": "Desktop action picker",
                "follow": True,
                "window": window_id,
            },
        })
        assert opened["ok"] and opened.get("result", {}).get("id"), (
            "control setup did not open the pending picker"
        )
        picker_id = opened["result"]["id"]
        picker = wait_for(
            lambda: named(app, "Select", role="frame"),
            "pending picker did not appear for modal-safety coverage",
        )
        picker_entry = wait_for(
            lambda: editable_descendant(picker),
            "pending picker did not expose its focused query entry",
        )
        wait_for(
            lambda: picker_entry.get_state_set().contains(Atspi.StateType.FOCUSED),
            "pending picker query entry did not take keyboard focus",
        )
        assert_desktop_actions_inert(
            env, app, window_id, (*blocked_actions, "dashboard"), focus_owner=picker_entry,
        )
        cancelled = raw_control_json(env, {
            "cmd": "pick.cancel", "target": picker_id, "args": {"window": window_id},
        })
        assert cancelled["ok"], "pending picker cleanup failed"
        wait_for(
            lambda: not named(app, "Select", role="frame"),
            "pending picker remained after cleanup",
        )

        initial_windows = len([item for item in window_list(env) if item["open"]])
        invoke(env, "new-window")
        wait_for(
            lambda: len([item for item in window_list(env) if item["open"]]) == initial_windows + 1,
            "New Window action did not create a persisted window in the primary instance",
        )
        print("OK: cold/warm desktop actions route to live GTK sessions, surfaces, palettes, and windows")
    finally:
        stop(process)
