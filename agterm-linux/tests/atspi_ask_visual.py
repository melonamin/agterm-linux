"""Rendered regressions for forms that accessibility-only checks cannot detect."""

import json
import os
import subprocess
import time

from atspi_smoke import (activate, collect, editable_descendant, launch, named,
                         raw_control_json, stop, wait_for, window_extents,
                         window_list, window_tree)
from x11_capture import capture


def verify_ask_visual(env, state):
    scale = int(env.get("GDK_SCALE", "1"))
    artifacts = os.environ.get("AGTERM_UI_ARTIFACT_DIR", state)
    os.makedirs(artifacts, exist_ok=True)
    pages = os.path.join(state, "visual-pages")
    os.makedirs(pages, exist_ok=True)
    for theme in ("Catppuccin Mocha", "Catppuccin Latte"):
        with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as file:
            json.dump({"welcomeShown": True, "theme": theme, "followSystemAppearance": False}, file)
        process, app = launch(env)
        try:
            window = next(row["id"] for row in window_list(env) if row["open"])
            session = window_tree(env, window)["workspaces"][0]["sessions"][0]["id"]

            def request(cmd, args=None, target=session):
                result = raw_control_json(env, {"cmd": cmd, "target": target,
                                               "args": dict(args or {}, window=window)})
                assert result["ok"], result
                return result.get("result", {})

            request("window.resize", {"width": 1000, "height": 740}, window)
            frame = collect(app, role="frame")[0]
            title = "Opaque centered form"
            samples = []
            for color in ("white", "black"):
                page = os.path.join(pages, color + ".html")
                with open(page, "w", encoding="utf-8") as file:
                    file.write(f'<title>{color}</title><body style="margin:0;background:{color}">'
                               '<h1>PAGE BEHIND THE FORM</h1></body>')
                request("session.overlay.open", {"html": page, "cwd": pages})

                def loaded():
                    rows = window_tree(env, window)["workspaces"][0]["sessions"][0].get("htmlOverlays", [])
                    return rows and rows[0].get("state") == "loaded"

                wait_for(loaded, "visual underlay did not load")
                ask = request("ask.open", {"title": title, "style": "terminal", "input": "line"})["id"]
                label = wait_for(lambda: named(app, title, role="label"), "form did not appear")
                content = label.get_parent()
                bounds = wait_for(lambda: window_extents(content), "form has no bounds")
                outer = window_extents(frame)
                assert abs(bounds.y + bounds.height / 2 - outer.height / 2) < 65, "form is not centered"
                assert named(content, "OK", role="button") and named(content, "Cancel", role="button")
                editor = editable_descendant(content)
                assert editor and editor.get_editable_text_iface().set_text_contents("Rendered answer")
                time.sleep(0.25)
                bounds = window_extents(content)
                geometry = subprocess.check_output(
                    ["xdotool", "search", "--onlyvisible", "--pid", str(process.pid)], text=True).splitlines()
                assert geometry, "form window is not mapped"
                origin = dict(line.split("=", 1) for line in subprocess.check_output(
                    ["xdotool", "getwindowgeometry", "--shell", geometry[-1]], text=True).splitlines())
                shot = capture(os.path.join(artifacts, f"ask-{theme.replace(' ', '-')}-{color}-{scale}x.png"))
                # Inside the frame's padding, clear of text, caret, shadow and rounded corners.
                x = int(origin["X"]) + int((bounds.x + 4) * scale)
                y = int(origin["Y"]) + int((bounds.y + 4) * scale)
                pixels = shot.get_pixels()
                offset = y * shot.get_rowstride() + x * 3
                samples.append(tuple(pixels[offset:offset + 3]))
                activate(named(content, "OK", role="button"))
                answer = wait_for(lambda: (result if (result := request("ask.result", target=ask)["ask"])
                                          ["result"] != "pending" else None), "form answer stayed pending")
                assert answer["text"] == "Rendered answer", answer
                request("session.overlay.close")
            assert len(samples[0]) == 3 and max(abs(a - b) for a, b in zip(*samples)) <= 2, (
                f"form background changes with its HTML underlay: {samples}")

            choices = [{"id": str(index), "label": f"Option {index}: " + "Long option label " * 12}
                       for index in range(12)]
            for style in ("gui", "terminal"):
                ask = request("ask.open", {"title": "Bounded choices", "style": style,
                                           "choices": choices, "multiple": True})["id"]
                label = wait_for(lambda: named(app, "Bounded choices", role="label"), "choices did not appear")
                content = label.get_parent()
                button = named(content, "Cancel", role="button")
                box = window_extents(content)
                assert box.width <= 600, f"long choices expanded to {box.width}px"
                choice = named(content, choices[0]["label"], role="label")
                assert choice and window_extents(choice).height > 35, "long choice did not wrap"
                capture(os.path.join(artifacts, f"choices-{theme.replace(' ', '-')}-{style}-{scale}x.png"))
                button_box = window_extents(button) if button else None
                caption = named(button, "Cancel", role="label") if button else None
                caption_box = window_extents(caption) if caption else None
                # Older GTK reports a button's content origin with its outer width. Its centered
                # label gives a stable center; include the full button width around that center.
                right = caption_box.x + (caption_box.width + button_box.width) / 2 if caption_box and button_box else None
                assert right is not None and right <= box.x + box.width + 2, (
                    f"{style} button bounds {None if button_box is None else (button_box.x, button_box.y, button_box.width, button_box.height)} "
                    f"escape content bounds {(box.x, box.y, box.width, box.height)}; label bounds "
                    f"{None if caption_box is None else (caption_box.x, caption_box.width)}")
                activate(button)
                wait_for(lambda: request("ask.result", target=ask)["ask"]["result"] == "escaped",
                         "choice form did not cancel")
            request("session.split", {"mode": "on"})
            for cover in (False, True):
                if cover:
                    request("session.overlay.open", {"html": os.path.join(pages, "white.html"), "cwd": pages})
                ask = request("ask.open", {"title": "Pane width", "style": "terminal", "pane": "right",
                                           "input": "line", "width": 100})["id"]
                label = wait_for(lambda: named(app, "Pane width", role="label"), "pane form did not appear")
                content = label.get_parent()
                time.sleep(0.2)
                cancel = named(content, "Cancel", role="button")
                box = window_extents(cancel)
                outer = window_extents(frame)
                assert box.x + box.width < outer.width, "pane form buttons extend past the window"
                capture(os.path.join(artifacts, f"pane-ask-{theme.replace(' ', '-')}-{cover}-{scale}x.png"))
                activate(cancel)
                wait_for(lambda: request("ask.result", target=ask)["ask"]["result"] == "escaped",
                         "pane form did not cancel")
                if cover:
                    request("session.overlay.close")
            request("session.split", {"mode": "off"})
            ask = request("ask.open", {"title": "Long explanation", "style": "terminal",
                                       "message": "A long explanation that must wrap inside its host. " * 20,
                                       "buttons": [{"id": "ok", "label": "OK"},
                                                   {"id": "cancel", "label": "Cancel"}]})["id"]
            label = wait_for(lambda: named(app, "Long explanation", role="label"), "long ask did not appear")
            content = label.get_parent()
            time.sleep(0.2)
            box = window_extents(content)
            outer = window_extents(frame)
            assert box.y >= 0 and box.y + box.height <= outer.height, "long ask extends below its window"
            capture(os.path.join(artifacts, f"long-ask-{theme.replace(' ', '-')}-{scale}x.png"))
            activate(named(content, "Cancel", role="button"))
            wait_for(lambda: request("ask.result", target=ask)["ask"]["result"] != "pending",
                     "long ask did not close")
            print(f"OK: {theme} forms are opaque, centered, editable and bounded at {scale}x")
        finally:
            stop(process)
