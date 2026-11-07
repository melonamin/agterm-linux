"""Exercise generated pages through real terminal link clicks, and GTK's native divider cursor."""

import ctypes
import os
import pwd
import shlex
import shutil
import struct
import subprocess
import tempfile
import time
import zlib

from atspi_smoke import (collect, focus_window, launch, mouse_click, named, raw_control_json, sidebar_column,
                         stop, wait_for, window_extents, window_list)


class CursorImage(ctypes.Structure):
    _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short),
                ("width", ctypes.c_ushort), ("height", ctypes.c_ushort),
                ("xhot", ctypes.c_ushort), ("yhot", ctypes.c_ushort),
                ("serial", ctypes.c_ulong), ("pixels", ctypes.POINTER(ctypes.c_ulong)),
                ("atom", ctypes.c_ulong), ("name", ctypes.c_char_p)]


def cursor_name():
    xlib = ctypes.CDLL("libX11.so.6")
    fixes = ctypes.CDLL("libXfixes.so.3")
    xlib.XOpenDisplay.argtypes, xlib.XOpenDisplay.restype = [ctypes.c_char_p], ctypes.c_void_p
    xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]
    xlib.XFree.argtypes = [ctypes.c_void_p]
    fixes.XFixesGetCursorImage.argtypes = [ctypes.c_void_p]
    fixes.XFixesGetCursorImage.restype = ctypes.POINTER(CursorImage)
    display = xlib.XOpenDisplay(os.environ["DISPLAY"].encode())
    assert display
    image = None
    try:
        image = fixes.XFixesGetCursorImage(display)
        assert image
        return image.contents.name.decode() if image.contents.name else "unnamed"
    finally:
        if image:
            xlib.XFree(image)
        xlib.XCloseDisplay(display)


def verify_links_v0400(env, state):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    image = os.path.join(state, "link.png")
    with open(image, "wb") as file:
        file.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 80, 40, 8, 2, 0, 0, 0))
                   + chunk(b"IDAT", zlib.compress((b"\x00" + b"\xff\x00\xff" * 80) * 40)) + chunk(b"IEND", b""))
    markdown = os.path.join(state, "link.md")
    with open(markdown, "w", encoding="utf-8") as file:
        file.write("# Clicked Markdown\n\nThis page came through the terminal's real input path.\n")
    # HOME is deliberately redirected to /tmp by the runner. Use the test account's
    # real home to cover Linux /home paths, which the macOS automount policy rejected.
    # CI runs GTK tests as root, whose own home is /root; it can create the fixture in /home directly.
    home_root = "/home" if os.geteuid() == 0 else pwd.getpwuid(os.getuid()).pw_dir
    home_files = tempfile.TemporaryDirectory(prefix="agterm-links-", dir=home_root)
    assert home_files.name.startswith("/home/"), home_files.name
    paths = [image, markdown]
    for path in (image, markdown):
        paths.append(shutil.copy(path, home_files.name))
    process, app = launch(env)

    def request(command, target=None, args=None):
        response = raw_control_json(env, {"cmd": command, "target": target, "args": args or {}})
        assert response["ok"], response
        return response.get("result", {})

    def row(identity):
        return next(row for workspace in request("tree")["tree"]["workspaces"]
                    for row in workspace["sessions"] if row["id"] == identity)

    try:
        window = next(item["id"] for item in window_list(env) if item["open"])
        request("window.resize", window, {"width": 1000, "height": 700})
        for path, kind in ((path, kind) for path in paths for kind in ("plain", "osc8")):
            label = path if kind == "plain" else "OPEN_FILE_" * 6
            output = label if kind == "plain" else "\\033]8;;file://localhost" + path + "\\033\\\\" + label + "\\033]8;;\\033\\\\"
            script = "printf '\\033[2J\\033[H" + output + "'; exec sleep 3600"
            identity = request("session.new", args={"name": "Click " + os.path.basename(path),
                                                    "command": "/bin/sh -c " + shlex.quote(script)})["id"]
            wait_for(lambda: label in request("session.text", identity)["text"], kind + " fixture did not print")
            frame = collect(app, role="frame")[0]
            bounds = window_extents(frame)
            sidebar = wait_for(lambda: sidebar_column(app), "sidebar not allocated")
            if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
                from x11_capture import capture
                location = "home" if path.startswith("/home/") else "tmp"
                capture(os.path.join(artifacts, f"v0400-link-{location}-{kind}-{os.path.basename(path)}.png"))
            for top in (80, 72, 88, 96, 64, 56, 48):
                mouse_click(lambda: frame, process.pid, button="left", modifier="ctrl",
                            x_fraction=(sidebar.x + sidebar.width + 45) / bounds.width,
                            dy=-bounds.height // 2 + top)
                time.sleep(0.15)
                if row(identity).get("htmlOverlays"):
                    break
            wait_for(lambda: row(identity).get("htmlOverlays", [{}])[0].get("state") == "loaded",
                     "Ctrl-click did not open generated page: " + kind + " " + path)
            assert row(identity)["htmlOverlays"][0]["page"] == path, row(identity)
            if path.endswith(".md"):
                wait_for(lambda: named(app, "Clicked Markdown"), "clicked Markdown did not render")
            request("session.overlay.close", identity)
            request("session.close", identity)

        split = request("session.new", args={"name": "Cursor split"})["id"]
        request("session.split", split, {"mode": "on"})
        time.sleep(0.3)
        frame = collect(app, role="frame")[0]
        bounds = window_extents(frame)
        sidebar = sidebar_column(app)
        focus_window(process.pid)
        geometry = dict(line.split("=", 1) for line in subprocess.check_output(
            ["xdotool", "getactivewindow", "getwindowgeometry", "--shell"], text=True).splitlines())
        x = int(geometry["X"]) + (bounds.width + sidebar.x + sidebar.width) // 2
        y = int(geometry["Y"]) + bounds.height // 2

        def hover():
            subprocess.run(["xdotool", "mousemove", "--sync", str(x + 1), str(y)], check=True)
            subprocess.run(["xdotool", "mousemove", "--sync", str(x), str(y)], check=True)
            time.sleep(0.1)
            return cursor_name()

        midpoint = x
        for offset in range(-16, 17, 2):
            x = midpoint + offset
            visible = hover()
            if visible in ("col-resize", "ew-resize", "sb_h_double_arrow"):
                break
        assert visible in ("col-resize", "ew-resize", "sb_h_double_arrow"), visible
        ask = request("ask.open", split, {"title": "Cursor cover", "style": "terminal", "input": "line"})["id"]
        wait_for(lambda: named(app, "Cursor cover"), "ask did not cover split")
        covered = hover()
        assert covered != visible, (visible, covered)
        request("ask.cancel", ask)
        wait_for(lambda: hover() == visible, "divider cursor did not return after ask")
        print("OK: real Ctrl-click image/Markdown pages and native GTK divider cursor ownership under an ask")
    finally:
        stop(process)
        home_files.cleanup()
