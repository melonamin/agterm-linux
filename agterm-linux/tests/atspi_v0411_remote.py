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
            for command, args in (("session.overlay.search", {"text": "remoteNeedle"}),
                                  ("session.overlay.follow", {"mode": "on"})):
                reply = raw_control_json(viewer_env, {"cmd": command, "target": viewer, "args": args})
                assert not reply["ok"], reply
        if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
            from x11_capture import capture
            capture(os.path.join(artifacts, "v0411-remote-" + argument + ".png"))
        request(origin_env, "session.overlay.close", origin)
        wait_for(lambda: not page(), "remote content page was not disposed")
    print("OK: streamed remote image/Markdown/text, native image sizing, inert scripts and control refusals", flush=True)
