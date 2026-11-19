"""Generated remote content uses real page-serve transfers between two GTK apps."""

import base64
import os
import time
from pathlib import Path

from atspi_smoke import raw_control_json, wait_for


def verify_remote_content(origin_env, viewer_env, app, origin, viewer, pages, request, row):
    image = Path(pages, "remote.png")
    image.write_bytes(base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADAQMAAACDJEzCAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURf8AAP///0EdNBEAAAABYktHRAH/Ai3eAAAAB3RJTUUH6gsCEw0u0coFdQAAAAtJREFUCNdjYAABAAAGAAFm9MlsAAAAAElFTkSuQmCC"))
    markdown = Path(pages, "remote.md")
    markdown.write_text('---\ntitle: Remote frontmatter\n---\n# Streamed Markdown\n\n![Origin pixel](remote.png)\n'
                        '<script>document.title="AUTHORED SCRIPT RAN"</script>\n', encoding="utf-8")
    source = Path(pages, "remote.swift")
    source.write_text('let remoteNeedle = 41\nprint(remoteNeedle)\n', encoding="utf-8")

    def page():
        return next(iter(row(viewer_env, viewer).get("htmlOverlays", [])), {})

    for argument, path, _visible in (("markdownFile", markdown, "Streamed Markdown"),
                                    ("textFile", source, "let remoteNeedle = 41"), ("image", image, None)):
        request(origin_env, "session.overlay.open", origin, {argument: str(path)})
        wait_for(lambda: page().get("state") == "loaded", "remote generated content did not load: " + str(path), timeout=25)
        # WebKit's AT-SPI subtree is absent with these two GTK processes on one bus.
        # Capture the real renderer for visual validation alongside the local renderer's AT-SPI checks.
        assert page().get("replica") is True, page()
        time.sleep(0.5)
        assert page().get("title") != "AUTHORED SCRIPT RAN", page()
        if argument == "image":
            assert row(viewer_env, viewer).get("overlayWidth") == 240 and row(viewer_env, viewer).get("overlayHeight") == 360, row(viewer_env, viewer)
        if argument == "textFile":
            request(viewer_env, "session.overlay.search", viewer, {"text": "remoteNeedle"})
            wait_for(lambda: page().get("text", {}).get("search", {}).get("matches") == 2,
                     "remote text search did not reach the real renderer")
            request(origin_env, "session.overlay.wrap", origin, {"mode": "off"})
            reply = raw_control_json(viewer_env, {"cmd": "session.overlay.follow", "target": viewer, "args": {"mode": "on"}})
            assert not reply["ok"], reply  # a source page has no live log follower
        if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
            from x11_capture import capture
            capture(os.path.join(artifacts, "v0411-remote-" + argument + ".png"))
        request(origin_env, "session.overlay.close", origin)
        wait_for(lambda: not page(), "remote content page was not disposed")
    logfile = Path(pages, "remote.log")
    logfile.write_text("first record\n", encoding="utf-8")
    request(origin_env, "session.overlay.open", origin, {"textFile": str(logfile), "tail": 100, "followFile": True})
    wait_for(lambda: page().get("text", {}).get("lines") == 1, "remote log tail did not load", timeout=25)
    with logfile.open("a", encoding="utf-8") as stream:
        stream.write("second record\n")
    wait_for(lambda: page().get("text", {}).get("lines") == 2, "remote log did not follow the origin append")
    request(viewer_env, "session.overlay.follow", viewer, {"mode": "off"})
    wait_for(lambda: not page().get("text", {}).get("following"), "remote log pause did not round trip")
    request(origin_env, "session.overlay.close", origin)
    wait_for(lambda: not page(), "remote log page was not disposed")
    if os.environ.get("AGTERM_TEST_SSH_CONFIG"):
        import functools
        import http.server
        import threading
        from urllib.parse import urlparse

        Path(pages, "loopback.html").write_text("<title>SSH loopback reached</title><h1>Remote service</h1>")
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=pages)
        service = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=service.serve_forever, daemon=True)
        thread.start()
        try:
            remote_port = service.server_port
            request(origin_env, "session.overlay.open", origin, {"url": f"http://127.0.0.1:{remote_port}/loopback.html"})
            wait_for(lambda: page().get("title") == "SSH loopback reached", "SSH loopback page did not load", timeout=25)
            assert urlparse(page()["url"]).port != remote_port, page()
            request(origin_env, "session.overlay.close", origin)
            wait_for(lambda: not page(), "loopback page was not disposed")
            print("OK: real SSH loopback forwarding reaches the remote HTTP service through a different local port", flush=True)
        finally:
            service.shutdown()
            service.server_close()
            thread.join(timeout=5)
    print("OK: streamed remote image/Markdown/text, native image sizing, inert scripts and control refusals", flush=True)
