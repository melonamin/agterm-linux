"""Info and icon settings must affect actual sidebar rows, including companions and flagged views."""

import json
import os
import time

from atspi_smoke import collect, launch, named, raw_control_json, stop, wait_for, window_extents
from x11_capture import capture


def verify_sidebar_v0400(env, state):
    artifacts = os.environ.get("AGTERM_UI_ARTIFACT_DIR", state)
    standard_height = None
    for mode, hidden, font, theme, density in (("always", False, 13, "Catppuccin Mocha", "default"),
                                               ("always", False, 13, "Catppuccin Mocha", "compact"),
                                               ("off", True, 20, "Catppuccin Latte", "default"),
                                               ("flagged", True, 13, "Catppuccin Mocha", "default")):
        with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as file:
            json.dump({"welcomeShown": True, "theme": theme, "sidebarFontSize": font,
                       "followSystemAppearance": False, "sessionInfoDisplay": mode, "sidebarDensity": density,
                       "hiddenInterfaceElements": ["sessionIcons", "workspaceIcons"] if hidden else []}, file)
        process, app = launch(env)

        def request(command, target=None, args=None):
            response = raw_control_json(env, {"cmd": command, "target": target, "args": args or {}})
            assert response["ok"], response
            return response.get("result", {})

        def row_label(title):
            return next((row for row in collect(app, role="list item") if named(row, title, role="label")), None)

        def info_visible(text):
            return named(app, text, role="label") is not None

        try:
            # Info is deliberately runtime-only; none of the previous launch's values may survive.
            assert not any(row.get("info") for workspace in request("tree")["tree"]["workspaces"]
                           for row in workspace["sessions"])
            parent_name, child_name = "Info parent " + mode + density, "Info child " + mode + density
            parent = request("session.new", args={"name": parent_name})["id"]
            child = request("session.companion.new", parent, {"name": child_name})["id"]
            request("session.info", parent, {"mode": "set", "text": "**Build** ^[ready](color: 'green')", "markdown": True})
            request("session.info", child, {"mode": "set", "text": "child info <literal> & safe"})
            request("session.select", parent)
            row = wait_for(lambda: row_label(parent_name), "parent missing")
            images = collect(row_label(child_name), role="image")
            assert bool(images) == (not hidden), (mode, hidden, len(images))
            if mode == "always":
                wait_for(lambda: info_visible("Build ready"), "Always info did not render")
                parent_info = window_extents(named(app, "Build ready", role="label"))
                child_info = window_extents(named(app, "child info <literal> & safe", role="label"))
                indent = 20 if density == "compact" else 24
                assert indent - 2 <= child_info.x - parent_info.x <= indent + 2, (parent_info.x, child_info.x)
                height = window_extents(row_label(parent_name)).height
                if density == "default":
                    standard_height = height
                else:
                    assert height < standard_height, (height, standard_height)
                    assert request("tree")["tree"]["sidebarDensity"] == "compact"
                assert window_extents(row_label(parent_name)).height > window_extents(row_label("home")).height
            else:
                assert not info_visible("Build ready"), mode
            for identity in (parent, child):
                request("session.flag", identity, {"mode": "on"})
            request("sidebar.mode", args={"mode": "flagged"})
            time.sleep(0.2)
            assert info_visible("Build ready") == (mode != "off"), mode
            capture(os.path.join(artifacts, f"v0400-info-{mode}-{font}-{density}.png"))
            request("sidebar.mode", args={"mode": "tree"})
            request("session.info", child, {"mode": "set", "text": "timed close info", "hideAfter": 10})
            request("session.close", child, {"undoable": True})
            item = next(item for item in request("recent.list")["recent"] if child in item["sessionIDs"])
            request("recent.open", item["id"])
            assert not info_visible("timed close info"), "undo restored a discarded timed info line"
            print(f"OK: sidebar info {mode}, icons {'hidden' if hidden else 'visible'}, {font}pt, {theme}")
        finally:
            stop(process)
