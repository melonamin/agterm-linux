"""Ctrl-J/K navigate the palette and picker on a layout without Latin letters."""

import contextlib
import shutil
import subprocess

from atspi_smoke import (Atspi, collect, launch, named, press_return, press_x11_key, raw_control_json, stop,
                         wait_for)

# xdotool binds a named key missing from the map to a spare keycode as a Latin letter, which any comparison
# accepts, and unbinds it after the tap, so an app stalled for 20-50 ms loses the press.
J_KEYCODE, K_KEYCODE, P_KEYCODE = 44, 45, 33
STEPS = ((J_KEYCODE, 1), (J_KEYCODE, 2), (K_KEYCODE, 1))


@contextlib.contextmanager
def russian_layout(env):
    try:
        subprocess.run(["setxkbmap", "ru"], check=True, env=env)
        yield
    finally:
        # Unchecked here so a failed restore cannot replace the error already propagating.
        restored = subprocess.run(["setxkbmap", "us"], check=False, env=env)
    assert restored.returncode == 0, "setxkbmap could not restore us; the shared display stays Russian"


def selected_row_index(frame):
    rows = collect(frame, role="list item")
    return next((index for index, row in enumerate(rows)
                 if row.get_state_set().contains(Atspi.StateType.SELECTED)), None)


def verify_steps(frame, title, process_id):
    wait_for(lambda: selected_row_index(frame) == 0, f"{title} did not select its first row")
    for keycode, expected in STEPS:
        press_x11_key(f"ctrl+{keycode}", process_id, window_title=title)
        wait_for(lambda: selected_row_index(frame) == expected,
                 f"{title}: Ctrl+keycode {keycode} did not select row {expected}", timeout=3)


def verify_palette_layout_navigation(env):
    if not shutil.which("setxkbmap", path=env["PATH"]):
        print("SKIP: setxkbmap is not installed, so no non-Latin layout can be selected")
        return
    process, app = launch(env)
    try:
        with russian_layout(env):
            press_x11_key(f"ctrl+shift+{P_KEYCODE}", process.pid)
            palette = wait_for(lambda: named(app, "Command Palette", role="frame"),
                               "Ctrl+Shift+P did not open the palette under a Russian layout")
            verify_steps(palette, "Command Palette", process.pid)
            press_x11_key("Escape", process.pid, window_title="Command Palette")
            wait_for(lambda: not named(app, "Command Palette", role="frame"), "palette ignored Escape")

            items = [{"id": "alpha", "label": "Alpha"},
                     {"id": "bravo", "label": "Bravo"},
                     {"id": "charlie", "label": "Charlie"}]
            opened = raw_control_json(env, {"cmd": "pick.open", "args": {"items": items}})
            assert opened["ok"], opened
            picker = wait_for(lambda: named(app, "Select", role="frame"), "control picker did not open")
            verify_steps(picker, "Select", process.pid)
            press_return(process.pid, window_title="Select")
            picked = raw_control_json(env, {"cmd": "pick.result", "target": opened["result"]["id"]})
            assert picked["result"]["pick"].get("id") == "bravo", picked
        print("OK: palette and picker Ctrl-J/K navigate under a Russian-only layout")
    finally:
        stop(process)
