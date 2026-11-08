"""A palette launched by a palette action must outlive its predecessor's destroy signal."""

import json

from atspi_smoke import (editable_descendant, launch, named, open_palette,
                         palette_row_labels, press_return, press_x11_key,
                         raw_control_json, stop, wait_for, window_list, window_tree)


def verify_palette_lifecycle(env):
    process, app = launch(env)
    try:
        window = next(row["id"] for row in window_list(env) if row["open"])
        session = window_tree(env, window)["workspaces"][0]["sessions"][0]["id"]
        reply = raw_control_json(env, {"cmd": "session.rename", "target": session,
                                       "args": {"name": "Palette lifecycle session", "window": window}})
        assert reply["ok"], reply
        themes = raw_control_json(env, {"cmd": "theme.list"})
        assert themes["ok"] and ".agterm-resource-manifest" not in json.dumps(themes), themes
        for command, child_title, query, expected in (
            ("Tint Session…", "Command Palette", "Blue", "Blue"),
            ("Edit Flagged Sessions…", "Edit Flagged Sessions", "lifecycle", "Palette lifecycle session"),
        ):
            palette, editor = open_palette(app, process.pid)
            assert editor.get_editable_text_iface().set_text_contents(command)
            wait_for(lambda: any(command in row for row in palette_row_labels(palette)),
                     f"missing palette command: {command}")
            press_return(process.pid, window_title="Command Palette")
            child = wait_for(lambda: named(app, child_title, role="frame"), "child palette did not open")
            search = editable_descendant(child)
            assert search and search.get_editable_text_iface().set_text_contents(query)
            wait_for(lambda: palette_row_labels(child) == [[expected]],
                     f"replacement palette stopped filtering: {palette_row_labels(child)}")
            press_x11_key("Escape", process.pid, window_title=child_title)
            wait_for(lambda: not named(app, child_title, role="frame"), "replacement palette ignored Escape")
        print("OK: nested tint and membership palettes filter and close after their predecessor is destroyed")
    finally:
        stop(process)
