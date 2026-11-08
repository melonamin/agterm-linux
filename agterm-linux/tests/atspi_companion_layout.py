"""Rendered sidebar hierarchy, including disclosure gutters and flattened flagged rows."""

import json
import os
import time

from atspi_smoke import (activate, collect, launch, named, raw_control_json, stop,
                         wait_for, window_extents, window_list, window_tree)
from x11_capture import capture


def verify_companion_layout(env, state):
    artifacts = os.environ.get("AGTERM_UI_ARTIFACT_DIR", state)
    os.makedirs(artifacts, exist_ok=True)
    scale = env.get("GDK_SCALE", "1")
    for theme in ("Catppuccin Mocha", "Catppuccin Latte"):
        for font in (12, 20):
            with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as file:
                json.dump({"welcomeShown": True, "theme": theme, "sidebarFontSize": font,
                           "followSystemAppearance": False}, file)
            process, app = launch(env)
            try:
                window = next(row["id"] for row in window_list(env) if row["open"])

                def request(cmd, target=None, args=None):
                    response = raw_control_json(env, {"cmd": cmd, "target": target,
                                                       "args": dict(args or {}, window=window)})
                    assert response["ok"], response
                    return response.get("result", {})

                # A previous theme/font case may have left a window snapshot behind.
                peer = request("session.new", args={"name": "Layout peer"})["id"]
                parent = request("session.new", args={"name": "Layout parent", "noSelect": True})["id"]

                def row_label(title):
                    for row in collect(app, role="list item"):
                        label = named(row, title, role="label")
                        if label:
                            return row, label
                    return None

                def geometry(title):
                    row, label = wait_for(lambda: row_label(title), "missing sidebar row: " + title)
                    return (wait_for(lambda: window_extents(row), "row has no bounds"),
                            wait_for(lambda: window_extents(label), "label has no bounds"))

                time.sleep(0.2)
                original_x = geometry("Layout parent")[1].x
                children = [request("session.companion.new", parent,
                                    {"name": f"Layout child {index}", "noSelect": True})["id"]
                            for index in range(3)]
                time.sleep(0.25)
                filename = f"companions-{theme.replace(' ', '-')}-{font}pt-{scale}x"
                capture(os.path.join(artifacts, filename + ".png"))
                parent_row, parent_label = geometry("Layout parent")
                peer_row, peer_label = geometry("Layout peer")
                assert abs(parent_label.x - peer_label.x) <= 1, (
                    f"parent/peer labels differ: {parent_label.x} vs {peer_label.x}")
                assert abs(parent_label.x - original_x) <= 1, "adding companions moved the parent's label"
                assert abs(parent_row.height - peer_row.height) <= 1, "disclosure increased row height"
                for index in range(3):
                    child_row, child_label = geometry(f"Layout child {index}")
                    assert 20 <= child_label.x - parent_label.x <= 28, (
                        f"child starts at {child_label.x}, parent at {parent_label.x}")
                    assert abs(child_row.height - parent_row.height) <= 1, "companion row height differs"
                    assert child_row.x == parent_row.x and child_row.width == parent_row.width, (
                        "indentation shrank the row's selection background")
                assert not collect(row_label("Layout peer")[0], role="button"), "leaf exposes a fake disclosure"
                disclosure = collect(row_label("Layout parent")[0], role="button")
                assert len(disclosure) == 1, "parent has no unique disclosure button"
                activate(disclosure[0])
                wait_for(lambda: not row_label("Layout child 0"), "disclosure did not fold companions")
                assert abs(geometry("Layout parent")[1].x - original_x) <= 1
                activate(collect(row_label("Layout parent")[0], role="button")[0])
                wait_for(lambda: row_label("Layout child 0"), "disclosure did not unfold companions")
                for identity in [peer, parent, *children]:
                    request("session.flag", identity, {"mode": "on"})
                for layout in ("flat", "plain", "tree"):
                    request("sidebar.flagged-layout", args={"mode": layout})
                    request("sidebar.mode", args={"mode": "flagged"})
                    time.sleep(0.2)
                    rows = collect(app, role="list item")
                    labels = [next(label for label in collect(row, role="label")
                                   if "Layout " in label.get_name()) for row in rows]
                    starts = [window_extents(label).x for label in labels]
                    assert len(starts) == 5 and max(starts) - min(starts) <= 1, (
                        f"{layout} flagged rows retained tree indentation: {starts}")
                    assert not any(collect(row, role="button") for row in rows), "flagged disclosure leaked"
                request("sidebar.mode", args={"mode": "tree"})
                time.sleep(0.2)
                assert geometry("Layout child 0")[1].x > geometry("Layout parent")[1].x + 16
                capture(os.path.join(artifacts, filename + "-restored.png"))
                # Keep later cases independent, including their flagged projection.
                request("session.close", parent)
                request("session.close", peer)
                print(f"OK: companion indentation, stable gutters, row heights and flagged layouts: {theme}, {font}pt, {scale}x")
            finally:
                stop(process)
