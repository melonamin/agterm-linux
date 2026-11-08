"""Exercise the real v0.41 text renderer, file follower, controls, and sidebar presentation."""

import http.server
import os
import re
import shlex
from pathlib import Path
import subprocess
import threading
import time
from urllib.parse import urlparse

from atspi_smoke import (CTL, collect, launch, mouse_click, raw_control_json, sidebar_column,
                         stop, wait_for, window_extents, window_list)


def verify_v0411(env, state):
    reveal = Path(state, "file-reveal.url")
    env = dict(env, AGTERM_ATSPI_URL_CAPTURE=str(reveal))
    config = Path(state, "config")
    config.mkdir(exist_ok=True)
    (config / "ghostty.conf").write_text("mouse-shift-capture = true\n", encoding="utf-8")
    process, app = launch(env)
    requests = []

    class NetworkProbe(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            self.send_response(404)
            self.end_headers()

        def log_message(self, *_args):
            pass

    network = http.server.ThreadingHTTPServer(("127.0.0.1", 0), NetworkProbe)
    threading.Thread(target=network.serve_forever, daemon=True).start()

    def request(command, target=None, args=None):
        reply = raw_control_json(env, {"cmd": command, "target": target, "args": args or {}})
        assert reply["ok"], reply
        return reply.get("result", {})

    def row():
        return next(row for workspace in request("tree")["tree"]["workspaces"]
                    for row in workspace["sessions"] if row["id"] == identity)

    def page():
        return next(iter(row().get("htmlOverlays", [])), {})

    def text():
        return page().get("text", {})

    def open_text(path, *options):
        result = subprocess.run([CTL, "session", "overlay", "open", "--text", str(path), "--target", identity,
                                 "--socket", env["AGTERM_CONTROL_SOCKET"], *options], env=env, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
        wait_for(lambda: page().get("state") == "loaded", "text page did not load")

    try:
        identity = request("session.new", args={"name": "v0411 page fixture"})["id"]
        assert request("sidebar.density", args={"mode": "compact"})["text"] == "compact"
        assert request("tree")["tree"]["sidebarDensity"] == "compact"
        assert request("sidebar.density", args={"mode": "toggle"})["text"] == "default"
        for color in ("teal", "pink", "brown", "indigo", "mint", "#A0B1C2"):
            request("session.tint", identity, {"mode": "set", "tint": color, "tintOn": ["name"]})
            assert row()["tint"] == color.lower() and row()["tintOn"] == ["name"], row()
        for shape in ("triangle-down", "play", "seal", "bolt", "bell"):
            request("session.status", identity, {"status": "active", "shape": shape})
            assert row()["statusShape"] == shape, row()

        source = Path(state, "fixture.swift")
        source.write_text("let needle = 1\nlet beta = 2\nprint(needle)\n", encoding="utf-8")
        open_text(source, "--line", "2")
        assert text()["file"] == str(source) and text()["line"] == 2 and text()["language"] == "swift", text()
        request("session.overlay.search", identity, {"text": "needle"})
        wait_for(lambda: text().get("search", {}).get("matches") == 2, "trusted text renderer did not find matches")
        assert request("session.overlay.search", identity, {"to": "next"})["text"].endswith("of 2")
        request("session.overlay.search", identity, {"to": "close"})
        request("session.select", identity)
        subprocess.run(["xdotool", "key", "ctrl+f"], check=True, env=env)
        subprocess.run(["xdotool", "type", "beta"], check=True, env=env)
        wait_for(lambda: text().get("search", {}).get("query") == "beta", "Ctrl+F did not focus the page's real find field")
        wait_for(lambda: text().get("search", {}).get("matches") == 1, "typed search did not report its matches")
        request("session.overlay.close", identity)

        diff = Path(state, "review.diff")
        diff.write_text("--- a/main.swift\n+++ b/main.swift\n@@ -1 +1 @@\n-let n = 1\n+let n = 2\n"
                        "@@ -10 +10 @@\n-print(1)\n+print(2)\n", encoding="utf-8")
        open_text(diff)
        wait_for(lambda: text().get("changes", {}).get("count") == 2, "diff renderer did not report its changes")
        assert request("session.overlay.changes", identity, {"to": "next"})["text"] == "1 of 2"
        assert request("session.overlay.changes", identity, {"to": "next"})["text"] == "2 of 2"
        assert request("session.overlay.changes", identity, {"to": "prev"})["text"] == "1 of 2"
        if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
            from x11_capture import capture
            capture(os.path.join(artifacts, "v0411-diff.png"))
        request("session.overlay.close", identity)

        log = Path(state, "follow.log")
        log.write_text("one\ntwo\n", encoding="utf-8")
        open_text(log, "--tail", "3", "--follow-file")
        wait_for(lambda: text().get("lines") == 2, "initial log snapshot was not reported")
        request("session.overlay.search", identity, {"text": "three"})
        with log.open("a", encoding="utf-8") as stream:
            stream.write("three\n")
        wait_for(lambda: text().get("search", {}).get("matches") == 1, "following did not update actual page text")
        assert request("session.overlay.follow", identity, {"mode": "off"})["text"] == "paused"
        with log.open("a", encoding="utf-8") as stream:
            stream.write("three\n")
        time.sleep(1.3)
        assert text()["search"]["matches"] == 1, text()
        request("session.overlay.follow", identity, {"mode": "on"})
        wait_for(lambda: text().get("search", {}).get("matches") == 2, "resuming failed to show appended text")
        log.rename(log.with_suffix(".old"))
        wait_for(lambda: text().get("waiting") is True, "missing rotated log was not reported")
        log.write_text("replacement\n", encoding="utf-8")
        wait_for(lambda: text().get("lines") == 1 and text().get("waiting") is False, "rotation was not picked up")
        log.write_bytes(b"binary\0tail\n")
        wait_for(lambda: text().get("unreadable") is True, "binary log was not refused")
        log.write_text("valid again\n", encoding="utf-8")
        wait_for(lambda: text().get("unreadable") is False, "readable log did not recover")
        request("session.overlay.reload", identity)
        request("session.overlay.close", identity)
        time.sleep(0.2)
        assert not row().get("htmlOverlays"), "a late read resurrected the closed log page"

        html = Path(state, "inert.html")
        endpoint = f"http://127.0.0.1:{network.server_port}/denied"
        html.write_text(f'<title>Inert document</title><h1>Untrusted local HTML</h1><img src="{endpoint}">'
                        f'<script>document.title="AUTHORED SCRIPT RAN";fetch("{endpoint}")</script>', encoding="utf-8")
        window = next(item["id"] for item in window_list(env) if item["open"])
        request("window.resize", window, {"width": 1000, "height": 700})
        original = identity
        for label, kind in ((str(html) + ".", "document"), (str(source) + ":2:1", "text"), (str(log), "log")):
            script = "printf '\\033[2J\\033[H%s' " + shlex.quote(label) + "; exec sleep 3600"
            identity = request("session.new", args={"name": "Clicked " + kind,
                                                    "command": "/bin/sh -c " + shlex.quote(script)})["id"]
            wait_for(lambda: label in request("session.text", identity)["text"], "clicked path fixture did not print")
            frame = collect(app, role="frame")[0]
            bounds = window_extents(frame)
            sidebar = wait_for(lambda: sidebar_column(app), "sidebar not allocated")
            for top in (80, 72, 88, 96, 64, 56, 48):
                mouse_click(lambda: frame, process.pid, button="left", modifier="ctrl",
                            x_fraction=(sidebar.x + sidebar.width + 45) / bounds.width,
                            dy=-bounds.height // 2 + top)
                time.sleep(0.15)
                if row().get("htmlOverlays"):
                    break
            wait_for(lambda: page().get("state") == "loaded", "Ctrl-click did not show " + label)
            if kind == "document":
                assert page()["document"] == str(html), page()
                assert page().get("title") != "AUTHORED SCRIPT RAN", page()
                assert not requests, requests
            elif kind == "text":
                assert text()["file"] == str(source) and text()["line"] == 2, text()
            else:
                assert text()["following"] is True, text()
            previous = page()["id"]
            request("session.overlay.hide", identity)
            wait_for(lambda: row().get("surfaces", [{}])[0].get("visible"), "hidden page did not restore terminal")
            time.sleep(1)
            for retry_top in (top, 80, 72, 88, 96, 64, 56, 48):
                subprocess.run(["xdotool", "mousemove", "0", "0"], check=True, env=env)
                mouse_click(lambda: frame, process.pid, button="left", modifier="ctrl",
                            x_fraction=(sidebar.x + sidebar.width + 45) / bounds.width,
                            dy=-bounds.height // 2 + retry_top)
                time.sleep(0.15)
                if page().get("id") != previous:
                    break
            if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
                from x11_capture import capture
                capture(os.path.join(artifacts, "v0411-hidden-reclick.png"))
            wait_for(lambda: page().get("state") == "loaded" and page().get("id") != previous,
                     "re-click did not replace hidden clicked page: " + kind + " " + str(row()))
            request("session.overlay.close", identity)
            reveal.unlink(missing_ok=True)
            for reveal_top in (retry_top, 80, 72, 88, 96, 64, 56, 48):
                subprocess.run(["xdotool", "mousemove", "0", "0"], check=True, env=env)
                mouse_click(lambda: frame, process.pid, button="left", modifier="ctrl+shift",
                            x_fraction=(sidebar.x + sidebar.width + 45) / bounds.width,
                            dy=-bounds.height // 2 + reveal_top)
                time.sleep(0.15)
                if reveal.exists():
                    break
            assert reveal.exists(), "Ctrl+Shift-click did not dispatch file-manager reveal: " + kind
            assert urlparse(reveal.read_text()).path.rstrip("/") == state, reveal.read_text()
            assert not row().get("htmlOverlays"), "reveal chord opened another page"
            request("session.close", identity)
        identity = original
        invalid = Path(state, "binary.txt")
        invalid.write_bytes(b"a\0b")
        refused = raw_control_json(env, {"cmd": "session.overlay.open", "target": identity, "args": {"textFile": str(invalid)}})
        assert not refused["ok"] and "UTF-8" in refused["error"], refused
        assert not row().get("htmlOverlays"), row()
        assert not requests, requests
        mouse_report = Path(state, "mouse-report.bin")
        reporter = Path(state, "mouse-report.py")
        reporter.write_text("import os, tty\ntty.setraw(0)\n"
                            "os.write(1, b'\\x1b[?1000h\\x1b[?1006hTUI pointer fixture')\n"
                            "while True:\n"
                            "    data = os.read(0, 4096)\n"
                            "    if not data: break\n"
                            f"    with open({str(mouse_report)!r}, 'ab') as output: output.write(data)\n", encoding="utf-8")
        identity = request("session.new", args={"name": "Captured pointer fixture",
                                                "command": "/usr/bin/python3 " + shlex.quote(str(reporter))})["id"]
        wait_for(lambda: "TUI pointer fixture" in request("session.text", identity)["text"], "mouse-reporting TUI did not start")
        reveal.unlink(missing_ok=True)
        subprocess.run(["xdotool", "mousemove", "0", "0"], check=True, env=env)
        mouse_click(lambda: frame, process.pid, button="left", modifier="ctrl+shift", x_fraction=0.75, dy=100)
        wait_for(lambda: mouse_report.exists() and re.search(rb"\x1b\[<20;\d+;\d+M", mouse_report.read_bytes()),
                 "mouse-reporting TUI lost Ctrl+Shift modifiers")
        assert not reveal.exists(), "mouse-reporting TUI dispatched desktop reveal"
        request("session.close", identity)
        print("OK: Ctrl+Shift reveals clicked files and preserves captured TUI pointer modifiers")
        print("OK: v0.41 text/search/diff/log lifecycle, density, tint and status control/readback")
    finally:
        network.shutdown()
        network.server_close()
        stop(process)
