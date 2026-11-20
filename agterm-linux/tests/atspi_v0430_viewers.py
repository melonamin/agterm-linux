"""Real-SSH acceptance for work migration, mail and attached lifecycle in two GTK viewers."""

import os
from pathlib import Path
import shlex

from atspi_smoke import activate, collect, launch, press_x11_key, stop, wait_for, describe_tree, mouse_click, sidebar_session_row, type_x11_text


def verify_viewer_handoffs(origin_env, viewer_env, first_process, first_app, local_window, attached, origin, root, request):
    second_dir = root / "v2"
    second_dir.mkdir()
    second_env = dict(viewer_env, AGTERM_STATE_DIR=str(second_dir), AGTERM_CONTROL_SOCKET=str(second_dir / "agterm.sock"),
                      AGTERM_APP_ID=viewer_env["AGTERM_APP_ID"] + ".second")
    second_process, second_app = launch(second_env)

    def rows(environment, window=None):
        return [row for workspace in request(environment, "tree", args={"window": window} if window else {})["tree"]["workspaces"]
                for row in workspace["sessions"]]

    def row(environment, identity, window=None):
        return next((item for item in rows(environment, window) if item["id"] == identity), None)

    def shows(app, name):
        return next(iter(collect(app, name=name)), None)

    def claim(environment, identity, window):
        request(environment, "window.select", window)
        request(environment, "session.select", identity, {"window": window})
        wait_for(lambda: row(environment, identity, window)["surfaces"][0].get("lead") in ("leader", "follower"), "viewer pane never attached its lead channel")
        request(environment, "session.lead", identity, {"pane": "left", "window": window})
        wait_for(lambda: row(environment, identity, window)["surfaces"][0].get("lead") == "leader", "viewer did not take the pane lead")

    def page(environment, identity, window):
        return next(iter(row(environment, identity, window).get("htmlOverlays", [])), {})

    try:
        second_window = request(second_env, "window.list")["windows"][0]["id"]
        second = request(second_env, "zmx.attach", origin, {"host": "local-test", "window": second_window})["id"]
        wait_for(lambda: row(second_env, second).get("presentation", {}).get("state") == "connected", "second viewer did not connect")
        claim(viewer_env, attached, local_window)
        ask = request(origin_env, "ask.open", origin, {"title": "Migrating GUI question", "style": "gui",
                                                       "buttons": [{"id": "yes", "label": "Confirm migration"}], "timeout": 60})["id"]
        wait_for(lambda: shows(first_app, "Confirm migration"), "ask was not visible on the leading viewer")
        claim(second_env, second, second_window)
        wait_for(lambda: shows(second_app, "Confirm migration") and not shows(first_app, "Confirm migration"),
                 "GUI ask did not move between real viewers")
        activate(shows(second_app, "Confirm migration"))
        wait_for(lambda: request(origin_env, "ask.result", ask)["ask"]["result"] == "answered", "GUI ask answer did not reach origin")
        print("OK: an open GUI ask moves to the new leading viewer and answers its origin", flush=True)

        claim(viewer_env, attached, local_window)
        pick = request(origin_env, "pick.open", origin, {"prompt": "Migrating session picker", "items": [
            {"id": "alpha", "label": "Migration alpha"}, {"id": "beta", "label": "Migration beta"}], "timeout": 60})["id"]
        wait_for(lambda: shows(first_app, "Migration beta"), "session picker did not appear in the first viewer")
        claim(second_env, second, second_window)
        wait_for(lambda: shows(second_app, "Migration beta") and not shows(first_app, "Migration beta"),
                 "session picker did not move between viewers")
        press_x11_key("Down", second_process.pid)
        press_x11_key("Return", second_process.pid)
        wait_for(lambda: request(origin_env, "pick.result", pick)["pick"].get("id") == "beta", "moved picker did not resolve the chosen item")
        print("OK: a session picker moves with pane leadership and resolves the real GUI choice", flush=True)

        claim(viewer_env, attached, local_window)
        document = root / "migration.html"
        document.write_text("<title>Migrating live page</title><h1>Move me with the pane</h1>")
        request(origin_env, "session.overlay.open", origin, {"html": str(document), "cwd": str(root)})
        wait_for(lambda: page(viewer_env, attached, local_window).get("state") == "loaded", "first viewer did not load origin page")
        claim(second_env, second, second_window)
        wait_for(lambda: page(second_env, second, second_window).get("state") == "loaded"
                 and not page(viewer_env, attached, local_window), "open page did not move between viewers")
        request(origin_env, "session.overlay.close", origin)
        wait_for(lambda: not page(second_env, second, second_window), "moved page did not close")

        claim(second_env, second, second_window)
        ask = request(origin_env, "ask.open", origin, {"title": "Owner loss question", "style": "gui",
                                                       "buttons": [{"id": "yes", "label": "Survived viewer exit"}], "timeout": 60})["id"]
        wait_for(lambda: shows(second_app, "Survived viewer exit"), "owner-loss question did not appear")
        stop(second_process)
        second_process = None
        wait_for(lambda: shows(first_app, "Survived viewer exit"), "question stayed stranded after its viewer exited", timeout=30)
        activate(shows(first_app, "Survived viewer exit"))
        wait_for(lambda: request(origin_env, "ask.result", ask)["ask"]["result"] == "answered", "handed-back question did not answer")
        print("OK: open pages migrate and an unanswered GUI ask survives its viewer exiting", flush=True)

        claim(viewer_env, attached, local_window)
        pane = row(origin_env, origin)["surfaces"][0]["paneID"]
        address = origin + ":" + pane
        mail = request(origin_env, "msg.send", args={"recipients": [address], "body": "remote mailbox acceptance"})
        wait_for(lambda: row(viewer_env, attached, local_window)["surfaces"][0].get("pendingMessages") == 1,
                 "origin mail count did not reach attached viewer")
        messages = request(origin_env, "msg.read", args={"identity": address})["messages"]
        assert any(message["body"] == "remote mailbox acceptance" for message in messages), messages
        request(origin_env, "msg.ack", args={"identity": address, "ids": [mail["messageID"]]})
        wait_for(lambda: not row(viewer_env, attached, local_window)["surfaces"][0].get("pendingMessages"), "mail acknowledgement did not clear remote count")
        request(origin_env, "session.status", origin, {"status": "blocked", "shape": "checkmark"})
        wait_for(lambda: row(viewer_env, attached, local_window).get("status") == "blocked", "origin status did not mirror")
        request(viewer_env, "window.select", local_window)
        mouse_click(lambda: sidebar_session_row(first_app, row(viewer_env, attached, local_window)["name"]), first_process.pid, button="right")
        activate(wait_for(lambda: next(iter(collect(first_app, role="push button", name="Clear Status")), None), "GUI Clear Status missing"))
        wait_for(lambda: row(origin_env, origin).get("status") != "blocked", "clearing mirrored status stayed local")
        request(origin_env, "notify", origin, {"title": "Origin badge", "body": "Mirrored badge acceptance"})
        wait_for(lambda: row(viewer_env, attached, local_window).get("unseen") == 1, "origin unseen badge did not mirror")
        request(viewer_env, "session.seen", attached, {"window": local_window})
        wait_for(lambda: not row(origin_env, origin).get("unseen"), "acknowledging mirrored badge stayed local")
        print("OK: headless mailbox send/read/ack counts and status clearing round trip to the origin", flush=True)

        from atspi_v0430_remote_content import verify_remote_content
        verify_remote_content(origin_env, viewer_env, first_process, first_app, origin, attached, local_window, root, request)

        from atspi_v0430_history import verify_attached_history
        verify_attached_history(origin_env, viewer_env, first_process, first_app, local_window, root, request)
        request(viewer_env, "session.select", attached, {"window": local_window})

        marker = root / "attached-restart.pid"
        command = "/bin/sh -c " + shlex.quote("echo $$ > " + shlex.quote(str(marker)) + "; exec sleep 3600")
        local_pane = row(viewer_env, attached, local_window)["surfaces"][0]["paneID"]
        restarted = request(viewer_env, "session.restart", attached, {"paneID": local_pane, "command": command, "window": local_window})
        wait_for(marker.exists, "attached restart did not start a real origin process")
        assert restarted["restart"]["paneID"] == local_pane, restarted
        assert restarted["restart"]["oldPid"] != restarted["restart"]["newPid"], restarted
        print("OK: attached restart runs on the origin and returns the stable viewer pane identity", flush=True)

        config = Path(viewer_env["AGTERM_STATE_DIR"], "config")
        config.mkdir(exist_ok=True)
        (config / "remotes.conf").write_text("local-test Isolated acceptance origin\n")

        def palette_action(title):
            press_x11_key("ctrl+shift+p", first_process.pid)
            type_x11_text(title, first_process.pid)
            wait_for(lambda: any(item.get_name().startswith(title) for item in collect(first_app, role="label")),
                     "new GUI palette action missing: " + title)
            press_x11_key("Return", first_process.pid)

        before = {item["id"] for item in rows(origin_env)}
        palette_action("New Remote Session")
        wait_for(lambda: any(item["id"] not in before for item in rows(origin_env)), "GUI New Remote Session did not create on origin", timeout=30)
        new_origin = next(item["id"] for item in rows(origin_env) if item["id"] not in before)
        wait_for(lambda: any(item.get("remoteSessionID") == new_origin for item in rows(viewer_env, local_window)),
                 "GUI New Remote Session did not attach its new origin row", timeout=30)
        windows_before = {item["id"] for item in request(viewer_env, "window.list")["windows"] if item["open"]}
        palette_action("Open Remote Window")
        wait_for(lambda: any(item["id"] not in windows_before and item["open"] for item in request(viewer_env, "window.list")["windows"]),
                 "GUI Open Remote Window did not open a catalog window", timeout=30)
        remote_window = next(item["id"] for item in request(viewer_env, "window.list")["windows"] if item["id"] not in windows_before and item["open"])
        wait_for(lambda: any(item["id"] == new_origin for item in rows(viewer_env, remote_window)), "GUI remote window did not show origin catalog", timeout=30)
        request(viewer_env, "window.close", remote_window)
        request(viewer_env, "window.select", local_window)
        request(viewer_env, "session.select", attached, {"window": local_window})
        print("OK: actual palette New Remote Session creates/attaches on origin; Open Remote Window displays its live catalog", flush=True)
    except AssertionError:
        describe_tree(first_app)
        if second_process:
            describe_tree(second_app)
        raise
    finally:
        if second_process:
            stop(second_process)
