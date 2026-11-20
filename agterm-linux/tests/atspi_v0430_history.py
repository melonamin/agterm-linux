"""Attached-row GUI lifecycle keeps ownership and undo on the origin."""

import shlex

from atspi_smoke import activate, collect, describe_tree, focus_accessible_window, mouse_click, press_x11_key, raw_control_json, sidebar_session_row, type_x11_text, wait_for


def verify_attached_history(origin_env, viewer_env, process, app, window, root, request):
    def rows(environment):
        return [row for workspace in request(environment, "tree", args={"window": window} if environment is viewer_env else {})["tree"]["workspaces"]
                for row in workspace["sessions"]]

    def menu(name):
        mouse_click(lambda: sidebar_session_row(app, "History origin"), process.pid, button="right")
        activate(wait_for(lambda: next(iter(collect(app, role="push button", name=name)), None), "missing history GUI action: " + name))

    def palette(name):
        frame = collect(app, role="frame")[-1]
        focus_accessible_window(frame, process.pid)
        mouse_click(lambda: frame, process.pid, button="left", x_fraction=0.8)
        press_x11_key("ctrl+shift+p", process.pid)
        try:
            wait_for(lambda: collect(app, role="label", name=name), "missing history palette action: " + name)
        except AssertionError:
            describe_tree(app)
            raise
        type_x11_text("Reopen Closed" if name == "Reopen Closed Item" else name, process.pid)
        press_x11_key("Return", process.pid)

    marker = root / "history.pid"
    origin = request(origin_env, "session.new", args={"name": "History origin"})["id"]
    request(origin_env, "session.type", origin, {"text": "echo $$ > " + shlex.quote(str(marker)) + "; /usr/bin/sleep 3600\n"})
    wait_for(marker.exists, "origin history program did not start")
    pid = int(marker.read_text())
    viewer = request(viewer_env, "zmx.attach", origin, {"host": "local-test", "window": window})["id"]
    wait_for(lambda: any(row["id"] == viewer and row.get("presentation", {}).get("state") == "connected" for row in rows(viewer_env)),
             "history attachment did not connect")
    request(viewer_env, "window.select", window)
    request(viewer_env, "session.select", viewer, {"window": window})
    menu("Duplicate as Companion")
    try:
        wait_for(lambda: any(row.get("parent") == origin for row in rows(origin_env)), "GUI duplicate did not create companion on origin")
    except AssertionError:
        print("Origin duplicate state:", next(row for row in rows(origin_env) if row["id"] == origin), flush=True)
        print("Duplicate control response:", raw_control_json(viewer_env, {"cmd": "session.companion.duplicate", "target": viewer,
              "args": {"window": window}}), flush=True)
        raise
    request(viewer_env, "session.select", viewer, {"window": window})
    menu("Close Session")
    wait_for(lambda: not any(row["id"] == viewer for row in rows(viewer_env)), "GUI close did not detach the attached row")
    assert any(row["id"] == origin for row in rows(origin_env)), "ordinary GUI close killed its origin"
    palette("Reopen Closed Item")
    try:
        wait_for(lambda: any(row["id"] == viewer for row in rows(viewer_env)), "GUI undo did not restore the detached row")
    except AssertionError:
        print("Undo viewer rows:", rows(viewer_env), flush=True)
        print("Undo recent:", request(viewer_env, "recent.list"), flush=True)
        raise
    request(viewer_env, "session.select", viewer, {"window": window})
    menu("Terminate on Origin")
    wait_for(lambda: not any(row["id"] == viewer for row in rows(viewer_env)), "GUI terminate did not close its local attachment")
    palette("Reopen Closed Item")
    wait_for(lambda: any(row["id"] == origin for row in rows(origin_env)), "GUI terminate undo did not restore on origin")
    assert int(marker.read_text()) == pid, "grace undo replaced the origin program"
    request(origin_env, "session.close", origin)
    request(viewer_env, "window.select", window)
    # The origin publishes history; reopen from a catalog palette uses that host's Recent Closed list.
    catalog = request(viewer_env, "window.remote.open", args={"host": "local-test"})["id"]
    wait_for(lambda: any(row.get("presentation", {}).get("state") == "connected"
                         for workspace in request(viewer_env, "tree", args={"window": catalog})["tree"]["workspaces"]
                         for row in workspace["sessions"]), "history catalog did not finish connecting")
    request(viewer_env, "window.select", catalog)
    palette("Reopen Last Closed Item")
    wait_for(lambda: any(row["name"] == "History origin" for row in rows(origin_env)), "GUI Recent Closed did not reopen on origin")
    reopened = next(row["id"] for row in rows(origin_env) if row["name"] == "History origin")
    request(origin_env, "session.close", reopened)
    request(viewer_env, "window.close", catalog)
    request(viewer_env, "window.select", window)
    print("OK: attached GUI duplicate, detach, undo, terminate/undo and origin Recent Closed", flush=True)
