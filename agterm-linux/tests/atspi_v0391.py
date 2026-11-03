"""Exercise v0.39.1 model/GTK/socket behavior in the smoke runner's isolated app."""

import os
import time
from gi.repository import Atspi

from atspi_smoke import (
    activate, collect, editable_descendant, launch, named,
    mouse_click, open_palette, palette_row_labels, press_return, press_x11_key, raw_control_json, stop,
    wait_for, window_extents, window_list, window_tree,
)


def verify_v0391(env, state):
    capture = os.path.join(state, "hud-link.txt")
    env = dict(env, AGTERM_ATSPI_URL_CAPTURE=capture)
    process, app = launch(env)
    try:
        window = next(row["id"] for row in window_list(env) if row["open"])

        def request(cmd, target=None, args=None, global_command=False):
            arguments = dict(args or {})
            if not global_command:
                arguments["window"] = window
            response = raw_control_json(env, {"cmd": cmd, "target": target, "args": arguments})
            assert response["ok"], response
            return response.get("result", {})

        event_cursor = request("events.read", global_command=True)["events"]
        event_args = {"run": event_cursor["run"], "after": "0", "limit": 1000}

        def answered(identity):
            result = request("ask.result", identity)["ask"]
            return result if result["result"] != "pending" else None

        def rows():
            return [row for workspace in window_tree(env, window)["workspaces"] for row in workspace["sessions"]]

        def row(identity):
            return next((row for row in rows() if row["id"] == identity), None)

        palette, search = open_palette(app, process.pid)
        assert search.get_editable_text_iface().set_text_contents("Attach Remote")

        def remote_enabled():
            for candidate in collect(palette, role="list item"):
                if named(candidate, "Attach Remote…", role="label"):
                    return candidate.get_state_set().contains(Atspi.StateType.SENSITIVE)
            return False

        remotes = os.path.join(state, "config", "remotes.conf")
        with open(remotes + ".new", "w", encoding="utf-8") as file:
            file.write("local-test Local test machine\n")
        os.replace(remotes + ".new", remotes)
        wait_for(remote_enabled,
                 "open palette did not observe remotes.conf creation")
        os.unlink(remotes)
        try:
            wait_for(lambda: not remote_enabled(),
                     "open palette did not observe remotes.conf removal")
        except AssertionError:
            print("Final remote palette:", palette_row_labels(palette), flush=True)
            raise
        press_x11_key("Escape", process.pid, window_title="Command Palette")

        parent = request("session.new", args={"name": "Parity parent", "tint": "blue", "tintOn": ["icon", "name"]})["id"]
        assert row(parent)["tint"] == "blue" and row(parent)["tintOn"] == ["icon", "name"]
        child = request("session.companion.new", parent, {"name": "Parity child", "noSelect": True})["id"]
        assert row(child)["parent"] == parent
        request("session.collapse", parent)
        assert row(parent)["collapsed"]
        request("session.select", child)
        wait_for(lambda: named(app, "Parity child"), "selected companion was not revealed")
        assert row(parent)["collapsed"], "revealing the selected companion persisted an expansion"
        request("session.expand", parent)
        request("session.tint", child, {"mode": "set", "tint": "orange", "tintOn": ["name"]})
        assert row(child)["tintOn"] == ["name"]
        request("session.flag", parent, {"mode": "on"})
        request("session.flag", child, {"mode": "on"})
        request("session.flag", child, {"mode": "move", "before": parent})
        assert window_tree(env, window)["flaggedOrder"][:2] == [child, parent]
        request("sidebar.flagged-layout", args={"mode": "plain"})
        request("sidebar.mode", args={"mode": "flagged"})
        request("session.collapse", parent)
        wait_for(lambda: named(app, "Parity parent ▸ Parity child") or named(app, "Parity parent / Parity child")
                 or any("Parity child" in node.get_name() for node in collect(app, role="label")),
                 "flagged companion disappeared behind its collapsed parent")
        request("sidebar.mode", args={"mode": "tree"})
        request("session.select", parent)

        request("session.overlay.open", parent, {"command": "printf overlay-alive; exec sleep 3600",
                                                          "sizePercent": 75, "width": 360, "height": 190})
        wait_for(lambda: row(parent).get("overlayWidth") == 360 and row(parent).get("overlayHeight") == 190,
                 "point dimensions did not reach tree read-back")
        request("session.overlay.hide", parent)
        assert row(parent)["hiddenOverlays"] == ["session"]
        wait_for(lambda: "overlay-alive" in request("session.overlay.text", parent)["text"], "hidden overlay stopped answering")
        request("session.overlay.show", parent)
        assert not row(parent).get("hiddenOverlays")
        request("session.overlay.close", parent)
        request("session.split", parent, {"mode": "on"})
        request("session.overlay.open", parent, {"command": "printf session-cover-alive; exec sleep 3600"})
        request("session.overlay.open", parent, {"command": "printf pane-cover-alive; exec sleep 3600", "pane": "right"})
        assert row(parent)["hiddenOverlays"] == ["session"], row(parent)
        request("session.overlay.close", parent, {"pane": "right"})
        assert not row(parent).get("hiddenOverlays"), "closing the newer pane overlay did not restore the session cover"
        wait_for(lambda: "session-cover-alive" in request("session.overlay.text", parent)["text"], "restored session cover stopped answering")
        request("session.overlay.close", parent)
        request("session.hud.open", parent, {"message": "sticky and square", "sticky": True, "frame": False,
                                            "position": "top-right"})
        assert row(parent)["hud"]["sticky"] and row(parent)["hud"]["frame"] is False
        request("session.hud.close", parent)
        request("session.hud.open", parent, {"message": "[Open test link Open test link Open test link](https://example.invalid/hud-link)",
                                            "markdown": True, "sizePercent": 75})

        def hud_panel():
            return named(app, "Floating terminal overlay")

        panel = wait_for(hud_panel, "HUD panel has no accessible bounds")
        time.sleep(0.5)  # Let the real HUD helper write its OSC-8 link into the terminal.
        height = window_extents(panel).height
        for offset in [0, 4, 8, 12, -height // 2 + 12, -height // 2 + 24, -height // 2 + 36]:
            mouse_click(hud_panel, process.pid, button="left", modifier="ctrl", dy=offset)
            if os.path.exists(capture):
                break
        if not os.path.exists(capture) and os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
            from x11_capture import capture as capture_pixels
            capture_pixels(os.path.join(os.environ["AGTERM_UI_ARTIFACT_DIR"], "hud-link-failure.png"))
        wait_for(lambda: os.path.exists(capture), "Ctrl-click did not open the passive HUD's Markdown link")
        with open(capture, encoding="utf-8") as file:
            assert file.read() == "https://example.invalid/hud-link"
        assert row(parent).get("hud"), "opening the link replaced its HUD"
        request("session.hud.close", parent)
        request("browser.links", args={"mode": "overlay50"}, global_command=True)
        assert request("browser.links", global_command=True)["text"] == "overlay50"

        page_path = os.path.join(state, "companion.html")
        with open(page_path, "w", encoding="utf-8") as page:
            page.write("<!doctype html><title>Companion page</title><p>Page without a shell</p>")
        page_row = request("session.companion.page", parent, {"html": page_path, "cwd": state, "follow": True})["id"]
        wait_for(lambda: row(page_row).get("htmlOverlays", [{}])[0].get("state") == "loaded", "page companion did not load")
        assert row(page_row)["content"] == "page" and not row(page_row)["realized"] and all(not surface["visible"] for surface in row(page_row).get("surfaces", [])), row(page_row)
        request("session.select", parent)
        other_page = row(page_row)["htmlOverlays"][0]["id"].lower()
        with open(os.path.join(state, "private.js"), "w", encoding="utf-8") as file:
            file.write('document.title="Cross-page grant leaked";')
        probe = os.path.join(state, "grant-probe.html")
        with open(probe, "w", encoding="utf-8") as file:
            file.write('<!doctype html><title>Checking grant</title><script>let s=document.createElement("script");'
                       's.onerror=()=>document.title="Cross-page grant denied";'
                       's.src="agterm-file://' + other_page + '/private.js";document.head.append(s);</script>')
        request("session.overlay.open", parent, {"html": probe, "javascript": True})
        wait_for(lambda: row(parent)["htmlOverlays"][0].get("title") in ("Cross-page grant leaked", "Cross-page grant denied"),
                 "cross-page grant probe did not finish")
        assert row(parent)["htmlOverlays"][0]["title"] == "Cross-page grant denied", "a page read another page's resource grant"
        request("session.overlay.close", parent)

        for mode, text in [("line", "Привет café"), ("multiline", "first\nsecond\tline")]:
            ask = request("ask.open", parent, {"title": "Form " + mode, "style": "gui", "input": mode, "value": "before"})["id"]
            dialog = wait_for(lambda: named(app, "Form " + mode, role="frame"), "form window did not appear")
            editor = wait_for(lambda: editable_descendant(dialog), "form editor is not accessible")
            assert editor.get_editable_text_iface().set_text_contents(text)
            activate(named(dialog, "OK", role="button"))
            answer = wait_for(lambda: answered(ask), "form answer remained pending")
            assert answer["result"] == "answered" and answer["text"] == text, answer
        ask = request("ask.open", parent, {"title": "Choices", "style": "gui",
            "choices": [{"id": "a", "label": "Alpha"}, {"id": "b", "label": "Beta"}],
            "multiple": True, "checked": ["a"], "other": "Another choice"})["id"]
        dialog = wait_for(lambda: named(app, "Choices", role="frame"), "choice form did not appear")
        press_x11_key("Down", process.pid, window_title="Choices")
        press_x11_key("space", process.pid, window_title="Choices")
        editor = editable_descendant(dialog)
        assert editor.get_editable_text_iface().set_text_contents("custom choice")
        activate(named(dialog, "OK", role="button"))
        answer = wait_for(lambda: answered(ask), "form answer remained pending")
        assert answer["selected"] == ["a", "b"] and answer["text"] == "custom choice", answer
        ask = request("ask.open", parent, {"title": "Cancel form", "style": "gui", "input": "line", "value": "discard"})["id"]
        dialog = wait_for(lambda: named(app, "Cancel form", role="frame"), "cancel form did not appear")
        activate(named(dialog, "Cancel", role="button"))
        answer = wait_for(lambda: answered(ask), "form answer remained pending")
        assert answer["result"] == "escaped" and "text" not in answer, answer

        request("session.overlay.open", parent, {"command": "exec sleep 3600"})
        ask = request("ask.open", parent, {"title": "Pane text over cover", "style": "terminal", "pane": "right",
                                          "input": "line", "value": "before"})["id"]
        title = wait_for(lambda: named(app, "Pane text over cover", role="label"), "pane form stayed behind the session cover")
        editor = editable_descendant(title.get_parent())
        assert editor.get_editable_text_iface().set_text_contents("terminal form answer")
        activate(named(title.get_parent(), "OK", role="button"))
        answer = wait_for(lambda: answered(ask), "terminal form answer remained pending")
        assert answer["text"] == "terminal form answer", answer
        request("session.overlay.close", parent)

        request("session.split", parent, {"mode": "on"})
        request("session.focus", parent, {"pane": "left"})
        time.sleep(0.25)  # Establish the settled pane before observing a focus transition.
        request("session.focus", parent, {"pane": "right"})
        wait_for(lambda: any(event["kind"] == "pane.focused" and event["session"] == parent
                            for event in request("events.read", args=event_args, global_command=True)["events"]["items"]),
                 "pane.focused never arrived through GTK's main loop")
        events = request("events.read", args=event_args, global_command=True)["events"]["items"]
        assert any(event["kind"] == "app.launched" for event in events), events

        request("session.close", child, {"undoable": True})
        assert row(child) is None
        palette, search = open_palette(app, process.pid)
        assert search.get_editable_text_iface().set_text_contents("Reopen Closed Item")
        wait_for(lambda: any("Reopen Closed Item" in labels[0] for labels in palette_row_labels(palette) if labels), "Undo Close action missing")
        press_return(process.pid, window_title="Command Palette")
        wait_for(lambda: row(child), "GUI undo did not restore the companion")
        closed = request("session.close", parent)
        assert parent in closed["closed"] and page_row in closed["closed"], closed
        recent = request("recent.list", global_command=True)["recent"]
        item = next(item for item in recent if parent in item["sessionIDs"])
        restored = request("recent.open", item["id"])["recentOpen"]
        assert restored["complete"] and row(parent) and row(child) and row(page_row) is None, restored
        print("OK: v0.39.1 companions, tints, flagged order, overlay visibility/points, HUD options, forms, Recent, and lifecycle events")
    finally:
        stop(process)
