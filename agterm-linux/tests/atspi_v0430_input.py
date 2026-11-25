"""Real keyboard, pointer, badges and session links added since v0.41.1."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import time

from atspi_smoke import (collect, describe_tree, focus_window, launch, mouse_click, press_x11_key,
                         raw_control_json, sidebar_column, stop, wait_for, window_extents)


def verify_input_v0430(env, state):
    for mode in ("firstKey", "enter", "never"):
        Path(state, "settings.json").write_text(json.dumps({"badgeReset": mode, "notificationsEnabled": False}))
        process, app = launch(env)

        def request(command, target=None, args=None):
            reply = raw_control_json(env, {"cmd": command, "target": target, "args": args or {}})
            assert reply["ok"], reply
            return reply.get("result", {})

        def row(identity):
            return next(item for workspace in request("tree")["tree"]["workspaces"]
                        for item in workspace["sessions"] if item["id"] == identity)

        try:
            identity = request("session.new", args={"name": "Badge " + mode})["id"]
            wait_for(lambda: row(identity).get("realized"), "badge fixture terminal did not realize")
            request("notify", identity, {"title": "Explicit badge", "body": "Input acceptance"})
            wait_for(lambda: row(identity).get("unseen") == 1, "explicit notification did not create its badge")
            request("session.type", identity, {"text": "scripted\n"})
            assert row(identity).get("unseen") == 1, "scripted input cleared the badge"
            press_x11_key("Control_L", process.pid)
            assert row(identity).get("unseen") == 1, "a pure modifier cleared the badge"
            press_x11_key("ctrl+shift+p", process.pid)
            assert row(identity).get("unseen") == 1, "an application shortcut cleared the badge"
            press_x11_key("Escape", process.pid)
            # Returning from a modal can legitimately acknowledge the session on activation.
            request("session.seen", identity)
            request("notify", identity, {"title": "Physical input badge", "body": "Input acceptance"})
            wait_for(lambda: row(identity).get("unseen") == 1, "physical input badge was not established")
            press_x11_key("x", process.pid)
            if mode == "firstKey":
                wait_for(lambda: not row(identity).get("unseen"), "first physical key did not clear the badge")
            else:
                assert row(identity).get("unseen") == 1, "plain typing cleared a non-first-key badge"
            press_x11_key("Return", process.pid)
            if mode == "never":
                assert row(identity).get("unseen") == 1, "Disabled badge reset cleared on Enter"
            else:
                wait_for(lambda: not row(identity).get("unseen"), "physical Enter did not clear the badge")
            request("session.split", identity, {"mode": "on"})
            request("session.status", identity, {"status": "active", "pane": "left"})
            request("session.status", identity, {"status": "active", "pane": "right"})
            request("session.focus", identity, {"pane": "left"})
            press_x11_key("ctrl+c", process.pid)
            wait_for(lambda: row(identity).get("activePanes") == ["right"], "interrupt in one pane cleared another pane's retained activity")
            print("OK: physical badge reset " + mode + ", script/modifier/shortcut exclusions, per-pane interrupt", flush=True)
        except Exception:
            describe_tree(app)
            raise
        finally:
            stop(process)

    capture = Path(state, "browser-capture")
    link_env = dict(env, AGTERM_ATSPI_URL_CAPTURE=str(capture))
    process, app = launch(link_env)
    try:
        target = request("session.new", args={"name": "Plain session target"})["id"]
        window = request("window.list")["windows"][0]["id"]
        request("window.resize", window, {"width": 1100, "height": 750})

        def print_link(url):
            command = "/bin/sh -c " + shlex.quote("printf '\\033[2J\\033[H%s' " + shlex.quote(url) + "; exec sleep 3600")
            identity = request("session.new", args={"name": "Plain URI source", "command": command})["id"]
            wait_for(lambda: url in request("session.text", identity)["text"], "plain URI was not printed")
            return identity

        def pointer_link(identity, expected_preview=None, click=True):
            frame = collect(app, role="frame")[0]
            bounds = window_extents(frame)
            sidebar = sidebar_column(app)
            for top in (80, 72, 88, 96, 64, 56, 48):
                if expected_preview:
                    focus_window(process.pid)
                    geometry = dict(line.split("=", 1) for line in subprocess.check_output(
                        ["xdotool", "getactivewindow", "getwindowgeometry", "--shell"], text=True).splitlines())
                    subprocess.run(["xdotool", "keydown", "ctrl", "mousemove", str(int(geometry["X"]) + sidebar.x + sidebar.width + 45),
                                    str(int(geometry["Y"]) + top)], check=True)
                    time.sleep(0.2)
                    found = collect(app, role="label", name=expected_preview)
                    subprocess.run(["xdotool", "keyup", "ctrl"], check=True)
                    if not found:
                        continue
                    if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
                        from x11_capture import capture
                        capture(str(Path(artifacts, "session-link-preview.png")))
                if click:
                    subprocess.run(["xdotool", "mousemove", "0", "0"], check=True)
                    mouse_click(lambda: frame, process.pid, button="left", modifier="ctrl",
                                x_fraction=(sidebar.x + sidebar.width + 45) / bounds.width,
                                dy=-bounds.height // 2 + top)
                return
            raise AssertionError("real pointer did not reveal the link preview")

        identity = print_link("agterm://session/" + target)
        pointer_link(identity, "Session: Plain session target")
        wait_for(lambda: row(target)["active"], "plain-text session URI did not select its target")
        request("session.close", identity)
        identity = print_link("http://100.100.100.100:9999/acceptance")
        pointer_link(identity)
        wait_for(capture.exists, "public/Tailscale HTTP link did not route to desktop handler capture")
        assert "100.100.100.100:9999/acceptance" in capture.read_text(), capture.read_text()
        assert not row(identity).get("htmlOverlays"), "public HTTP IP opened a local overlay"
        print("OK: real pointer session-link preview and plain URI selection; public-IP HTTP uses desktop handler", flush=True)

        folder = Path(state, "scratch-links")
        folder.mkdir()
        document = folder / "scratch.md"
        document.write_text("# Scratch directory link\n")
        script = "cd " + shlex.quote(str(folder)) + "; printf '\\033]7;file://localhost%s\\007' \"$PWD\"; "
        script += "printf '\\033[2J\\033[H\\033]8;;./scratch.md\\033\\\\OPEN_SCRATCH_DOCUMENT\\033]8;;\\033\\\\'; exec sleep 3600"
        request("session.scratch", identity, {"mode": "on", "command": "/bin/sh -c " + shlex.quote(script)})
        wait_for(lambda: row(identity).get("scratchCwd") == str(folder), "scratch fixture cwd did not arrive")
        wait_for(lambda: "OPEN_SCRATCH_DOCUMENT" in request("session.text", identity, {"pane": "scratch"})["text"],
                 "scratch relative link was not printed")
        pointer_link(identity, "./scratch.md")
        wait_for(lambda: row(identity).get("htmlOverlays", [{}])[0].get("page") == str(document),
                 "relative link did not resolve against the scratch directory")
        print("OK: scratch link resolves against its own cwd", flush=True)
        stop(process)
        config = Path(state, "config")
        config.mkdir(exist_ok=True)
        (config / "ghostty.conf").write_text("link-previews = false\n")
        process, app = launch(link_env)
        identity = print_link("agterm://session/" + target)
        frame = collect(app, role="frame")[0]
        bounds = window_extents(frame)
        sidebar = sidebar_column(app)
        focus_window(process.pid)
        geometry = dict(line.split("=", 1) for line in subprocess.check_output(
            ["xdotool", "getactivewindow", "getwindowgeometry", "--shell"], text=True).splitlines())
        subprocess.run(["xdotool", "keydown", "ctrl", "mousemove", str(int(geometry["X"]) + sidebar.x + sidebar.width + 45),
                        str(int(geometry["Y"]) + 80)], check=True)
        try:
            time.sleep(0.3)
            assert not collect(app, role="label", name="Session: Plain session target"), "disabled link preview was shown"
        finally:
            subprocess.run(["xdotool", "keyup", "ctrl"], check=True)
        pointer_link(identity)
        wait_for(lambda: row(target)["active"], "disabling previews disabled session link activation")
        print("OK: link-previews=false hides the preview while preserving real link activation", flush=True)
    except Exception:
        describe_tree(app)
        raise
    finally:
        stop(process)
