"""User-driven v0.42/v0.43 acceptance against real GTK and WebKit widgets."""

import os
from pathlib import Path
import subprocess
import shlex

from atspi_smoke import (activate, collect, launch, mouse_click, mouse_drag, press_x11_key, raw_control_json,
                         sidebar_session_row, sidebar_session_row_label, stop, type_x11_text, wait_for, describe_tree)


def verify_v0430_gui(env, state):
    process, app = launch(env)

    def request(command, target=None, args=None):
        reply = raw_control_json(env, {"cmd": command, "target": target, "args": args or {}})
        assert reply["ok"], reply
        return reply.get("result", {})

    def row(identity):
        return next(item for workspace in request("tree")["tree"]["workspaces"]
                    for item in workspace["sessions"] if item["id"] == identity)

    def text():
        return next(iter(row(identity).get("htmlOverlays", [])), {}).get("text", {})

    def button(name):
        return wait_for(lambda: next((item for item in collect(app, name=name) if item.get_role_name() in ("push button", "toggle button", "button")), None),
                        "missing real GUI button: " + name)

    def rendered_text():
        pieces = []
        for node in collect(app):
            try:
                interface = node.get_text_iface()
                if interface:
                    from gi.repository import Atspi
                    pieces.append(Atspi.Text.get_text(node, 0, Atspi.Text.get_character_count(node)))
            except Exception:
                pass
        return "\n".join(pieces)

    def capture(name):
        if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
            from x11_capture import capture
            capture(str(Path(artifacts, name + ".png")))

    try:
        marker = Path(state, "gui-program.pid")
        command = "/bin/sh -c " + shlex.quote("echo $$ > " + shlex.quote(str(marker)) + "; exec sleep 3600")
        identity = request("session.new", args={"name": "GUI acceptance", "command": command})["id"]
        wait_for(marker.exists, "GUI fixture program did not start")
        pid = int(marker.read_text())
        source = Path(state, "gui-records.jsonl")
        source.write_text('{"nested":{"message":"needle","array":[1,2,3]}}\n{"nested":{"message":"other"}}\n')
        request("session.overlay.open", identity, {"textFile": str(source)})
        activate(button("Expand: off"))
        wait_for(lambda: text().get("expand"), "GUI Expand did not update the JSONL page")
        wait_for(lambda: '"array"' in rendered_text(), "expanded JSONL records did not render in the real document")
        capture("jsonl-expanded")
        activate(button("Expand: on"))
        wait_for(lambda: not text().get("expand"), "GUI collapse did not update the JSONL page")
        expected_wrap = not bool(text().get("wrap"))
        activate(button("Wrap: off" if expected_wrap else "Wrap: on"))
        wait_for(lambda: bool(text().get("wrap")) == expected_wrap, "GUI Wrap did not change the page")
        press_x11_key("ctrl+f", process.pid)
        type_x11_text("needle", process.pid)
        wait_for(lambda: text().get("search", {}).get("query") == "needle", "GUI find did not own the keyboard")
        request("theme.set", args={"name": "Catppuccin Latte"})
        wait_for(lambda: text().get("search", {}).get("matches") == 1, "theme rebuild lost search results")
        type_x11_text("X", process.pid)
        wait_for(lambda: text().get("search", {}).get("query") == "needleX", "theme rebuild lost the find caret/focus")
        assert bool(text().get("wrap")) == expected_wrap, text()
        request("session.overlay.close", identity)

        diff = Path(state, "gui-files.diff")
        diff.write_text("diff --git a/one.swift b/one.swift\n--- a/one.swift\n+++ b/one.swift\n@@ -1 +1 @@\n-let a = 1\n+let a = 2\n"
                        "diff --git a/two.swift b/two.swift\n--- a/two.swift\n+++ b/two.swift\n@@ -1 +1 @@\n-let b = 3\n+let b = 4\n")
        request("session.overlay.open", identity, {"textFile": str(diff)})
        wait_for(lambda: text().get("files", {}).get("count") == 2, "two-file diff did not report its file list")
        file_button = wait_for(lambda: next((item for item in collect(app)
                                            if item.get_name().startswith("File 1 of 2:")), None), "diff GUI file chooser missing")
        activate(file_button)
        entry = wait_for(lambda: next((item for item in collect(app, role="entry") if item.get_name() != "Find"), None), "diff chooser has no filter entry")
        type_x11_text("two", process.pid)
        match = wait_for(lambda: next((item for item in collect(app) if "two.swift" in item.get_name()), None), "diff file filter did not find two.swift")
        press_x11_key("Return", process.pid)
        wait_for(lambda: text().get("files", {}).get("current") == 2, "GUI file selection did not navigate to the second file")
        capture("diff-file-navigation")
        request("session.overlay.close", identity)

        request("session.select", identity)
        mouse_click(lambda: sidebar_session_row(app, "GUI acceptance"), process.pid, button="right")
        activate(button("Convert to Companion"))
        wait_for(lambda: row(identity).get("parent"), "row-menu conversion did not preserve and nest the running session")
        destination = request("session.new", args={"name": "GUI destination"})["id"]
        request("session.select", identity)
        mouse_click(lambda: sidebar_session_row(app, "GUI acceptance"), process.pid, button="right")
        activate(button("Move to…"))
        type_x11_text("GUI destination", process.pid)
        wait_for(lambda: collect(app, role="label", name="GUI destination"), "companion destination chooser missing")
        press_x11_key("Return", process.pid)
        wait_for(lambda: row(identity).get("parent") == destination, "GUI companion move did not reparent the same session")
        assert int(marker.read_text()) == pid and Path(f"/proc/{pid}").exists(), "GUI placement replaced the running program"
        destination_name = "GUI drag destination"
        destination = request("session.new", args={"name": destination_name})["id"]
        request("session.select", identity)
        mouse_drag(lambda: sidebar_session_row_label(app, "GUI acceptance"),
                   lambda: sidebar_session_row_label(app, destination_name), process.pid, target_fraction=0.5)
        wait_for(lambda: row(identity).get("parent") == destination, "pointer drag did not reparent the companion")
        assert int(marker.read_text()) == pid and Path(f"/proc/{pid}").exists(), "pointer drag replaced the running program"
        capture("companion-reparented")
        request("session.status", identity, {"status": "blocked"})
        request("session.status", destination, {"status": "active", "shape": "checkmark"})
        request("session.collapse", destination)
        request("session.select", destination)
        wait_for(lambda: collect(app, role="label", name="▤") and collect(app, role="label", name="✔"),
                 "folded urgency marker or checkmark glyph was not visible")
        capture("folded-status-light")
        request("theme.set", args={"name": "Catppuccin Mocha"})
        wait_for(lambda: collect(app, role="label", name="▤"), "folded marker disappeared in dark theme")
        def disclosure_has_contrast():
            from gi.repository import Atspi
            from x11_capture import capture
            disclosure = collect(sidebar_session_row(app, destination_name), role="push button", name="Fold or unfold companions")[0]
            bounds = disclosure.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
            frame = collect(app, role="frame")[0].get_component_iface().get_extents(Atspi.CoordType.WINDOW)
            geometry = dict(line.split("=", 1) for line in subprocess.check_output(
                ["xdotool", "getactivewindow", "getwindowgeometry", "--shell"], text=True).splitlines())
            center_x = int(geometry["X"]) + bounds.x - frame.x + bounds.width // 2
            center_y = int(geometry["Y"]) + bounds.y - frame.y + bounds.height // 2
            pixels = capture()
            data, stride = pixels.get_pixels(), pixels.get_rowstride()
            return sum(1 for y in range(center_y - 6, center_y + 6)
                       for x in range(center_x - 6, center_x + 6)
                       if max(data[y * stride + x * 3:y * stride + x * 3 + 3]) < 100) > 4
        wait_for(disclosure_has_contrast, "selected companion fold triangle lost contrast on light selection", timeout=3)
        capture("folded-status-dark")
        request("session.status", identity, {"status": "idle"})
        request("notify", identity, {"title": "Hidden child", "body": "Unread only"})
        wait_for(lambda: row(identity).get("unseen") == 1, "unread companion fixture did not receive a badge")
        assert not collect(app, role="label", name="▤"), "unread-only companion incorrectly showed a status marker"

        print("OK: real GUI JSONL expansion/wrap, diff-file selection, search focus across theme changes, companion conversion/reparenting")
    except Exception:
        capture("failure")
        print("Rendered text:", repr(rendered_text()), flush=True)
        describe_tree(app)
        raise
    finally:
        stop(process)
