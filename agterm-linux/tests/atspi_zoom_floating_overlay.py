"""The floating GTK frame must yield to base-pane zoom without losing its surface."""

import os
import shlex

from gi.repository import Atspi

from atspi_smoke import (collect, control_json, launch, named, press_return, stop, type_x11_text,
                         wait_for, window_list, window_tree)


def verify_zoom_floating_overlay(env):
    process, app = launch(env)
    try:
        window_id = next(item["id"] for item in window_list(env) if item["open"])
        control_json(env, "session", "new", "--name", "zoom-overlay", "--window", window_id, "--json")

        def session():
            return next((item for workspace in window_tree(env, window_id)["workspaces"]
                         for item in workspace["sessions"] if item["name"] == "zoom-overlay"), None)

        session_id = wait_for(lambda: session() and session()["id"], "zoom target session never appeared")
        control_json(env, "session", "split", "on", "--target", session_id, "--json")
        wait_for(lambda: session().get("hasSplit"), "split pane did not open")
        control_json(env, "session", "overlay", "open", "sleep 3600", "--size-percent", "60",
                     "--target", session_id, "--window", window_id, "--json")
        wait_for(lambda: session().get("overlay"), "floating overlay did not open")

        window = next(item for item in collect(app, role="frame") if item.get_name() == "zoom-overlay")
        bounds = window.get_component_iface().get_extents(Atspi.CoordType.WINDOW)

        frame = wait_for(lambda: named(app, "Floating terminal overlay"),
                         "the floating program card did not map")

        def showing():
            # GTK removes hidden widgets from the traversable AT-SPI tree. The cached proxy can
            # retain SHOWING from its last mapped state, so membership is the reliable signal.
            return frame in collect(app)

        def zoom(slot):
            control_json(env, "surface", "zoom", "show",
                         "--target", f"surface:{session_id}:{slot}", "--json")
            canonical = {"primary": "left", "split": "right"}.get(slot, slot)
            expected = f"surface:{session_id}:{canonical}".lower()
            wait_for(lambda: (window_tree(env, window_id).get("zoomedSurface") or "").lower() == expected,
                     f"{slot} zoom did not engage")

        def type_into_pane(slot):
            marker = os.path.join(env["AGTERM_STATE_DIR"], f"zoom-{slot}.marker")
            type_x11_text(f"printf zoom-{slot} > {shlex.quote(marker)}", process.pid)
            press_return(process.pid)
            wait_for(lambda: os.path.exists(marker), f"zoomed {slot} pane did not receive keyboard input")

        zoom("primary")
        wait_for(lambda: not showing(), "floating card still covered the zoomed primary terminal")
        type_into_pane("primary")

        zoom("overlay")
        wait_for(showing, "zooming the overlay did not restore its card")
        expanded = frame.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert expanded.width > bounds.width * 0.8, "zoomed overlay did not fill the content width"

        zoom("split")
        wait_for(lambda: not showing(), "floating card still covered the zoomed split terminal")
        type_into_pane("split")

        control_json(env, "surface", "zoom", "hide", "--target", f"surface:{session_id}:split", "--json")
        wait_for(showing, "floating card did not return after zoom exit")
        restored = frame.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert restored.width < bounds.width * 0.8, "floating card kept zoomed geometry after exit"
        assert session().get("overlay"), "zoom switching closed the floating program overlay"

        control_json(env, "session", "overlay", "close", "--target", session_id, "--json")
        wait_for(lambda: not session().get("overlay"), "floating overlay did not close")
        control_json(env, "quick", "show", "--json")
        wait_for(lambda: window_tree(env, window_id).get("quickVisible"), "quick terminal did not open")
        quick = wait_for(lambda: named(app, "Quick terminal"), "quick terminal card did not map")
        quick_bounds = quick.get_component_iface().get_extents(Atspi.CoordType.WINDOW)

        def quick_showing():
            return quick in collect(app)

        zoom("primary")
        wait_for(lambda: not quick_showing(), "quick card covered the zoomed session terminal")
        type_into_pane("primary")
        control_json(env, "surface", "zoom", "hide",
                     "--target", f"surface:{session_id}:primary", "--json")
        wait_for(quick_showing, "quick card did not return after session zoom exit")

        control_json(env, "session", "resize", "--split-ratio", "0.37",
                     "--target", session_id, "--json")
        wait_for(lambda: abs((session().get("splitRatio") or 0) - 0.37) < 0.001,
                 "split ratio did not settle before switching zoom targets")
        zoom("primary")
        control_json(env, "surface", "zoom", "show", "--target", "quick", "--json")
        wait_for(lambda: window_tree(env, window_id).get("zoomedSurface") == "quick",
                 "quick terminal did not take over the zoom target")
        wait_for(lambda: quick.get_component_iface().get_extents(Atspi.CoordType.WINDOW).width
                 > quick_bounds.width * 1.05,
                 f"quick zoom did not expand its card (initial width {quick_bounds.width}, "
                 f"current width {quick.get_component_iface().get_extents(Atspi.CoordType.WINDOW).width})")
        control_json(env, "surface", "zoom", "hide", "--target", "quick", "--json")
        wait_for(quick_showing, "quick card did not return after switching zoom targets")
        wait_for(lambda: quick.get_component_iface().get_extents(Atspi.CoordType.WINDOW).width
                 < quick_bounds.width * 1.03, "quick card kept zoomed geometry after target switch")
        try:
            wait_for(lambda: abs((session().get("splitRatio") or 0) - 0.37) < 0.001,
                     "switching zoom targets changed the saved split ratio")
        except AssertionError as error:
            raise AssertionError(f"{error}: {session().get('splitRatio')}") from error

        control_json(env, "quick", "hide", "--json")
        control_json(env, "session", "new", "--name", "selected-other", "--window", window_id, "--json")
        wait_for(lambda: any(item["name"] == "selected-other" and item["active"]
                             for workspace in window_tree(env, window_id)["workspaces"]
                             for item in workspace["sessions"]), "other session was not selected")
        zoom("primary")
        wait_for(lambda: named(app, "zoom-overlay", role="label"),
                 "zoom strip named the selected session instead of the presented one")
    finally:
        stop(process)
