"""Sidebar glyph bounds and repeated compact split switches, measured on real PTYs."""

import json
import os
from pathlib import Path
import shlex
import subprocess

from atspi_smoke import CTL, collect, launch, raw_control_json, sidebar_session_row, stop, wait_for, window_extents


def verify_sidebar_v0430(env, state):
    for font in (10, 13, 20):
        Path(state, "settings.json").write_text(json.dumps({"sidebarFontSize": font, "sidebarDensity": "compact",
            "theme": "Catppuccin Mocha", "followSystemAppearance": False, "welcomeShown": True}))
        process, app = launch(env)

        def request(command, target=None, args=None):
            result = raw_control_json(env, {"cmd": command, "target": target, "args": args or {}})
            assert result["ok"], result
            return result.get("result", {})

        try:
            identity = request("session.new", args={"name": "Glyph bounds " + str(font)})["id"]
            info = "ÁÉgjpqy — info " + str(font)
            request("session.info", identity, {"mode": "set", "text": info})
            label = wait_for(lambda: next(iter(collect(app, role="label", name=info)), None), "info label did not render")
            bounds = window_extents(label)
            parent = window_extents(sidebar_session_row(app, "Glyph bounds " + str(font)))
            assert parent.y <= bounds.y and bounds.y + bounds.height <= parent.y + parent.height, (font, bounds.y, bounds.height, parent.y, parent.height)
            assert bounds.height >= font, (font, bounds.height)
            child = request("session.companion.new", identity, {"name": "Fold triangle", "noSelect": True})["id"]
            request("session.select", identity)
            request("session.collapse", identity)
            request("session.expand", identity)
            wait_for(lambda: sidebar_session_row(app, "Fold triangle"), "selected row chevron did not unfold its child")
            if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
                from x11_capture import capture
                capture(str(Path(artifacts, "sidebar-info-" + str(font) + ".png")))
            if font != 13:
                continue

            marker = Path(state, "compact-grid")
            script = Path(state, "compact-probe.sh")
            script.write_text("#!/bin/sh\nwhile :; do stty size > " + shlex.quote(str(marker)) + ".next; mv "
                              + shlex.quote(str(marker)) + ".next " + shlex.quote(str(marker)) + "; sleep 0.1; done\n")
            script.chmod(0o755)
            identity = request("session.new", args={"name": "Compact PTY probe", "command": str(script)})["id"]
            def grid():
                if marker.exists():
                    values = marker.read_text().split()
                    if len(values) == 2:
                        return tuple(map(int, values))
                return None

            full = wait_for(lambda: grid() if grid() and min(grid()) > 5 else None, "PTY did not report its grid")
            request("session.split", identity, {"mode": "on"})
            reference = wait_for(lambda: grid() if grid() and 0.3 * full[1] < grid()[1] < 0.7 * full[1] else None,
                                 "split did not resize its real PTY to half the content width")
            other = request("session.new", args={"name": "Other compact session"})["id"]
            request("session.split", other, {"mode": "on"})
            for _ in range(8):
                request("session.select", identity)
                wait_for(lambda: grid() == reference, "compact split switch changed its PTY grid")
                request("session.select", other)
            def active():
                return next(item["id"] for workspace in request("tree")["tree"]["workspaces"]
                            for item in workspace["sessions"] if item.get("active"))

            before = active()
            request("session.new", args={"name": "Background no-select", "noSelect": True})
            assert active() == before, "no-select changed selection"
            rows = [item for workspace in request("tree")["tree"]["workspaces"] for item in workspace["sessions"]]
            subprocess.run([CTL, "session", "go", "--to", "2", "--socket", env["AGTERM_CONTROL_SOCKET"]], env=env, check=True, capture_output=True)
            wait_for(lambda: active() == rows[1]["id"], "CLI positional navigation disagreed with sidebar order")
            print("OK: repeated compact split switches preserve the real PTY grid; CLI position and no-select agree with sidebar", flush=True)
        finally:
            stop(process)
    print("OK: sidebar info ascenders/descenders and selected companion chevrons at 10/13/20pt", flush=True)
