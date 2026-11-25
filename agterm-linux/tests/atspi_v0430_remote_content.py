"""Real viewer controls and origin-owned content over SSH."""

import os
from pathlib import Path
import shlex
import subprocess
import time

from atspi_smoke import NEGATIVE_SETTLE_SECONDS, activate, collect, focus_window, mouse_click, press_x11_key, sidebar_column, wait_for, window_extents


def verify_remote_content(origin_env, viewer_env, process, app, origin, viewer, window, root, request):
    def page():
        rows = [row for workspace in request(viewer_env, "tree", args={"window": window})["tree"]["workspaces"]
                for row in workspace["sessions"]]
        return next(iter(next(row for row in rows if row["id"] == viewer).get("htmlOverlays", [])), {})

    def button(name):
        return wait_for(lambda: next((item for item in collect(app, name=name)
                                     if item.get_role_name() in ("push button", "toggle button", "button")), None),
                        "remote page GUI button missing: " + name)

    def capture(name):
        if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
            from x11_capture import capture
            capture(str(Path(artifacts, name + ".png")))

    request(viewer_env, "window.select", window)
    request(viewer_env, "session.select", viewer, {"window": window})
    records = root / "remote.jsonl"
    records.write_text('{"message":"remote needle","nested":{"array":[1,2]}}\n')
    request(origin_env, "session.overlay.open", origin, {"textFile": str(records)})
    wait_for(lambda: page().get("state") == "loaded", "remote JSONL did not load")
    capture("remote-jsonl-before")
    # WebKit's AT-SPI plug may disappear after another viewer exits on the shared bus.
    # Real document keyboard shortcuts still exercise the painted page and its origin bridge.
    mouse_click(lambda: collect(app, role="frame")[0], process.pid, button="left", x_fraction=0.7)
    press_x11_key("e", process.pid)
    wait_for(lambda: page().get("text", {}).get("expand"), "viewer Expand did not round trip")
    press_x11_key("w", process.pid)
    wait_for(lambda: page().get("text", {}).get("wrap"), "viewer Wrap did not round trip")
    request(viewer_env, "session.overlay.search", viewer, {"text": "remote needle", "window": window})
    wait_for(lambda: page().get("text", {}).get("search", {}).get("matches") == 1,
             "remote expanded JSONL search did not find rendered text")
    capture("remote-jsonl-expanded")
    request(origin_env, "session.overlay.close", origin)
    wait_for(lambda: not page(), "remote JSONL did not close")

    diff = root / "remote.diff"
    diff.write_text("diff --git a/one.go b/one.go\n--- a/one.go\n+++ b/one.go\n@@ -1 +1 @@\n-one\n+two\n"
                    "diff --git a/two.go b/two.go\n--- a/two.go\n+++ b/two.go\n@@ -1 +1 @@\n-three\n+four\n")
    request(origin_env, "session.overlay.open", origin, {"textFile": str(diff)})
    wait_for(lambda: page().get("text", {}).get("files", {}).get("count") == 2, "remote diff did not render")
    mouse_click(lambda: collect(app, role="frame")[0], process.pid, button="left", x_fraction=0.7)
    press_x11_key("f", process.pid)
    press_x11_key("Down", process.pid)
    press_x11_key("Return", process.pid)
    wait_for(lambda: page().get("text", {}).get("files", {}).get("current") == 2,
             "remote GUI diff file selection did not reach origin")
    request(viewer_env, "session.overlay.files", viewer, {"to": "1", "window": window})
    wait_for(lambda: page().get("text", {}).get("files", {}).get("current") == 1,
             "remote control diff navigation disagreed with GUI")
    request(origin_env, "session.overlay.close", origin)
    wait_for(lambda: not page(), "remote diff did not close")

    logfile = root / "rotate.log"
    logfile.write_text("old one\nold two\n")
    request(origin_env, "session.overlay.open", origin, {"textFile": str(logfile), "tail": 100, "followFile": True})
    wait_for(lambda: page().get("text", {}).get("lines") == 2, "remote log did not load")
    logfile.rename(root / "rotate.log.1")
    logfile.write_text("rotated one\nrotated two\nrotated three\n")
    wait_for(lambda: page().get("text", {}).get("lines") == 3, "remote log did not follow rotation")
    logfile.write_text("truncated\n")
    wait_for(lambda: page().get("text", {}).get("lines") == 1, "remote log did not follow truncation")
    request(origin_env, "session.overlay.close", origin)
    wait_for(lambda: not page(), "remote log did not close")

    folder = root / "remote-markdown"
    folder.mkdir()
    first, second = folder / "one.md", folder / "two.md"
    first.write_text("# Remote first\n[Remote next](two.md)\n[Outside grant](../outside.md)\n")
    second.write_text("# Remote second\n")
    (root / "outside.md").write_text("# Must not navigate here\n")
    request(origin_env, "session.overlay.open", origin, {"markdownFile": str(first), "navigation": True})
    link = wait_for(lambda: next(iter(collect(app, role="link", name="Remote next")), None),
                    "remote Markdown link did not render")
    activate(link)
    try:
        wait_for(lambda: page().get("page") == str(second), "remote Markdown click did not navigate within its grant")
    except AssertionError:
        print("Remote Markdown state:", page(), flush=True)
        capture("remote-markdown-failure")
        raise
    activate(button("Back"))
    wait_for(lambda: page().get("page") == str(first), "remote Markdown GUI history did not navigate back")
    outside = wait_for(lambda: next(iter(collect(app, role="link", name="Outside grant")), None),
                       "remote Markdown outside link missing")
    activate(outside)
    time.sleep(NEGATIVE_SETTLE_SECONDS)
    assert page().get("page") == str(first) and page().get("state") == "loaded", page()
    capture("remote-markdown-contained")
    request(origin_env, "session.overlay.close", origin)
    wait_for(lambda: not page(), "remote Markdown did not close")
    print("OK: real SSH viewer JSONL/wrap/diff controls, log rotation/truncation, contained Markdown and GUI history", flush=True)

    target = request(origin_env, "session.new", args={"name": "Remote namespace target", "noSelect": True})["id"]
    local = request(viewer_env, "zmx.attach", target, {"host": "local-test", "window": window})["id"]
    request(viewer_env, "session.select", viewer, {"window": window})
    uri = "agterm://session/" + target
    command = "printf '\\033[2J\\033[H%s' " + shlex.quote(uri) + "; exec sleep 3600\n"
    request(origin_env, "session.type", origin, {"text": command})
    wait_for(lambda: request(viewer_env, "session.text", viewer, {"window": window})["text"].lstrip().startswith(uri),
             "remote session URI did not reach the cleared terminal screen")
    capture("remote-session-link-before")
    frame = collect(app, role="frame")[0]
    bounds, sidebar = window_extents(frame), sidebar_column(app)
    focus_window(process.pid)
    geometry = dict(line.split("=", 1) for line in subprocess.check_output(
        ["xdotool", "getactivewindow", "getwindowgeometry", "--shell"], text=True).splitlines())
    for top in (80, 72, 88, 96, 64, 56, 48):
        subprocess.run(["xdotool", "keydown", "ctrl", "mousemove", str(int(geometry["X"]) + sidebar.x + sidebar.width + 45),
                        str(int(geometry["Y"]) + top)], check=True)
        try:
            time.sleep(0.2)
            matched = bool(collect(app, role="label", name="Session: Remote namespace target"))
        finally:
            subprocess.run(["xdotool", "keyup", "ctrl"], check=True)
        if matched:
            capture("remote-session-link-preview")
            mouse_click(lambda: frame, process.pid, button="left", modifier="ctrl",
                        x_fraction=(sidebar.x + sidebar.width + 45) / bounds.width, dy=-bounds.height // 2 + top)
            break
    else:
        print("Remote URI screen:", request(viewer_env, "session.text", viewer, {"window": window}), flush=True)
        capture("remote-session-link-failure")
        raise AssertionError("remote session URI preview did not resolve the origin namespace")
    wait_for(lambda: any(row["id"] == local and row.get("active")
                         for workspace in request(viewer_env, "tree", args={"window": window})["tree"]["workspaces"]
                         for row in workspace["sessions"]), "remote session URI did not select the matching local attachment")
    request(viewer_env, "session.select", viewer, {"window": window})
    print("OK: real remote session-link preview and click resolve origin ids to local attachments", flush=True)
