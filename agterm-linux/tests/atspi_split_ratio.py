"""Check actual pane proportions across cold restoration and hidden control resizing."""

import json
import os

from atspi_smoke import launch, raw_control_json, stop, wait_for, window_list
from x11_capture import capture


def verify_split_ratio_restore(env, state):
    def request(command, target=None, **args):
        response = raw_control_json(env, {"cmd": command, "target": target, "args": args})
        assert response["ok"], response
        return response.get("result", {})

    def rendered_ratio(expected, label):
        last = {}

        def measured():
            pixbuf = capture()
            pixels, stride = pixbuf.get_pixels(), pixbuf.get_rowstride()
            red = blue = 0
            # Whole-display sampling avoids toolkit-specific widget bounds; terminal backgrounds
            # dominate incidental icons, and the minimum counts require both panes to be painted.
            for y in range(0, pixbuf.get_height(), 4):
                for x in range(0, pixbuf.get_width(), 4):
                    offset = y * stride + x * 3
                    r, g, b = pixels[offset:offset + 3]
                    red += r > 70 and r > g * 1.6 and r > b * 1.6
                    blue += b > 70 and b > r * 1.6 and b > g * 1.3
            last.update(red=red, blue=blue)
            if min(red, blue) < 500:
                return None
            actual = red / (red + blue)
            return actual if abs(actual - expected) < 0.06 else None

        try:
            actual = wait_for(measured, f"{label}: rendered ratio did not reach {expected}", timeout=15)
        finally:
            if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
                capture(os.path.join(artifacts, label + ".png"))
            print(f"{label}: sampled pane pixels {last}", flush=True)
        print(f"OK: {label}: primary ratio {actual:.3f}, expected {expected:.3f}")

    process = None
    try:
        process, _ = launch(env)
        window = next(item["id"] for item in window_list(env) if item["open"])
        request("window.resize", window, width=1000, height=700)
        sessions = []
        for axis, ratio in (("vertical", 0.30), ("horizontal", 0.65)):
            identity = request("session.new", name="Ratio " + axis)["id"]
            sessions.append(identity)
            request("session.split", identity, mode="on", axis=axis)
            request("session.background", identity, mode="color", color="#b02020", pane="primary")
            request("session.background", identity, mode="color", color="#2050b0", pane="split")
            request("session.resize", identity, ratio=ratio)
            rendered_ratio(ratio, "initial-" + axis)

        def persisted():
            try:
                with open(os.path.join(state, "windows", window + ".json"), encoding="utf-8") as source:
                    snapshot = json.load(source)
            except (OSError, ValueError):
                return False
            rows = {row["id"]: row for workspace in snapshot["workspaces"] for row in workspace["sessions"]}
            return (snapshot.get("selectedSessionID") == sessions[1]
                    and rows.get(sessions[0], {}).get("splitRatio") == 0.30
                    and rows.get(sessions[1], {}).get("splitRatio") == 0.65)

        wait_for(persisted, "split ratios and selection were not persisted before restart")
        stop(process)
        process = None
        process, _ = launch(env)
        rendered_ratio(0.65, "cold-restored-horizontal")
        request("session.select", sessions[0])
        rendered_ratio(0.30, "cold-restored-hidden-vertical")
        request("session.resize", sessions[1], ratio=0.40)
        request("session.select", sessions[1])
        rendered_ratio(0.40, "hidden-control-horizontal")
        request("session.resize", sessions[0], ratio=0.60)
        request("session.select", sessions[0])
        rendered_ratio(0.60, "hidden-control-vertical")
        assert process.poll() is None, "app exited during split restoration"
    finally:
        if process is not None:
            stop(process)
