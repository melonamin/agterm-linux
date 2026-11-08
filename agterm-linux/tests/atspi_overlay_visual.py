"""Hide/Show must change floating pixels while preserving the underlying page or process."""

import os
import subprocess
import time

from atspi_smoke import (collect, launch, named, raw_control_json, stop,
                         wait_for, window_extents, window_list, window_tree, sidebar_column)
from x11_capture import capture


def verify_overlay_visual(env, state):
    process, app = launch(env)
    try:
        window = next(row["id"] for row in window_list(env) if row["open"])
        session = window_tree(env, window)["workspaces"][0]["sessions"][0]["id"]
        scale = int(env.get("GDK_SCALE", "1"))
        artifacts = os.environ.get("AGTERM_UI_ARTIFACT_DIR", state)
        os.makedirs(artifacts, exist_ok=True)
        pages = os.path.join(state, "overlay-pages")
        os.makedirs(pages, exist_ok=True)
        page = os.path.join(pages, "marker.html")
        with open(page, "w", encoding="utf-8") as file:
            file.write('<title>Overlay visual marker</title><body style="background:#ff00ff;margin:0"></body>')

        def request(cmd, args=None):
            result = raw_control_json(env, {"cmd": cmd, "target": session,
                                           "args": dict(args or {}, window=window)})
            assert result["ok"], result
            return result.get("result", {})

        def session_row():
            return next(row for workspace in window_tree(env, window)["workspaces"]
                        for row in workspace["sessions"] if row["id"] == session)

        def picture(case, point):
            time.sleep(0.3)
            clients = subprocess.check_output(
                ["xdotool", "search", "--onlyvisible", "--pid", str(process.pid)], text=True).splitlines()
            origin = dict(line.split("=", 1) for line in subprocess.check_output(
                ["xdotool", "getwindowgeometry", "--shell", clients[-1]], text=True).splitlines())
            shot = capture(os.path.join(artifacts, f"overlay-{case}-{scale}x.png"))
            x = int(origin["X"]) + int(point[0] * scale)
            y = int(origin["Y"]) + int(point[1] * scale)
            offset = y * shot.get_rowstride() + x * 3
            return tuple(shot.get_pixels()[offset:offset + 3])

        for kind in ("html", "program"):
            for geometry in ("percent", "points"):
                options = {"sizePercent": 70}
                if geometry == "points":
                    options.update(width=420, height=260)
                if kind == "html":
                    options.update(html=page, cwd=pages)
                else:
                    options.update(command="printf retained-overlay-process; exec sleep 3600",
                                   color="#ff00ff")
                request("session.overlay.open", options)
                if kind == "html":
                    wait_for(lambda: session_row().get("htmlOverlays", [{}])[0].get("state") == "loaded",
                             "marker page did not load")
                else:
                    wait_for(lambda: "retained-overlay-process" in request("session.overlay.text").get("text", ""),
                             "overlay program did not start")
                    wait_for(lambda: named(app, "Floating terminal overlay"), "program card did not appear")
                outer = window_extents(collect(app, role="frame")[0])
                sidebar = sidebar_column(app)
                # WebKit's document coordinates belong to its child view. Sample the deck center
                # from GTK's window/column geometry instead; both card layouts are centered there.
                point = ((outer.width + sidebar.x + sidebar.width) / 2, outer.height / 2)
                case = kind + "-" + geometry
                before = picture(case + "-visible", point)
                assert before[0] > 220 and before[1] < 35 and before[2] > 220, (case, before)
                request("session.overlay.hide")
                hidden = picture(case + "-hidden", point)
                assert max(abs(a - b) for a, b in zip(before, hidden)) > 30, (
                    f"{case} still paints after Hide: {before} -> {hidden}")
                if kind == "program":
                    assert "retained-overlay-process" in request("session.overlay.text")["text"]
                request("session.overlay.show")
                shown = picture(case + "-shown", point)
                assert max(abs(a - b) for a, b in zip(before, shown)) <= 2, (
                    f"{case} did not restore its pixels: {before} -> {shown}")
                request("session.overlay.close")
        print(f"OK: floating HTML and program overlays hide and restore pixels at {scale}x without losing content")
    finally:
        stop(process)
