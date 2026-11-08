"""Exercise repeat leaders through real GTK key press/release and focus transitions."""

import os
import shlex
import subprocess
import time

from atspi_smoke import (focus_window, launch, raw_control_json, stop, wait_for,
                         window_list)


def verify_leader_repeat(env):
    state = env["AGTERM_STATE_DIR"]
    config = os.path.join(state, "config")
    os.makedirs(config)
    marker = os.path.join(state, "repeat.marker")
    with open(os.path.join(config, "keymap.conf"), "w", encoding="utf-8") as file:
        file.write(f'command "Repeat A" ctrl+x>a --repeat printf a >> {shlex.quote(marker)}\n'
                   f'command "Repeat B" ctrl+x>b --repeat printf b >> {shlex.quote(marker)}\n'
                   'map ctrl+x>w --repeat next_window\n'
                   'map ctrl+x>p --repeat command_palette\n')
    process, _app = launch(env)
    try:
        def keys(*args):
            subprocess.run(["xdotool", *args], check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)

        def read():
            try:
                with open(marker, encoding="utf-8") as file:
                    return file.read()
            except FileNotFoundError:
                return ""

        def prefix():
            keys("key", "ctrl+x")

        focus_window(process.pid)
        time.sleep(0.5)
        prefix()
        keys("keydown", "a", "sleep", "1.3", "keyup", "a", "key", "b")
        wait_for(lambda: read().count("a") > 1 and read().endswith("b"),
                 "held repeat tail or another tail under its live prefix did not fire")
        before = read()
        time.sleep(0.8)
        keys("key", "a")
        time.sleep(0.3)
        assert read() == before, "repeat tail survived its key-release timeout"

        # A held prefix's autorepeats must not postpone its 1.5-second deadline.
        keys("keydown", "Control_L", "keydown", "x", "sleep", "1.9",
             "keyup", "x", "keyup", "Control_L", "key", "a")
        time.sleep(0.3)
        assert read() == before, "consumed prefix autorepeats extended the leader deadline"

        first = next(row["id"] for row in window_list(env) if row["open"])
        created = raw_control_json(env, {"cmd": "window.new", "args": {"name": "repeat second"}})
        assert created["ok"], created
        wait_for(lambda: len([row for row in window_list(env) if row["open"]]) == 2,
                 "second window did not open")
        wait_for(lambda: any(row["active"] and row["id"] != first for row in window_list(env)),
                 "new window did not become active")
        time.sleep(0.5)
        prefix()
        keys("key", "w", "sleep", "0.1", "key", "b")
        wait_for(lambda: len(read()) > len(before), "window switch reset the repeat prefix")
        wait_for(lambda: any(row["active"] and row["id"] == first for row in window_list(env)),
                 "repeatable next_window did not switch to the first window")
        assert read() == before + "b", read()
        before = read()

        prefix()
        keys("key", "p", "sleep", "0.15", "key", "a", "key", "Escape")
        time.sleep(0.3)
        keys("key", "a")
        time.sleep(0.3)
        assert read() == before, "auxiliary palette retained a terminal repeat prefix"

        selected = raw_control_json(env, {"cmd": "window.select", "target": first})
        assert selected["ok"], selected
        time.sleep(0.3)
        prefix()
        keys("key", "a", "key", "Escape", "key", "b")
        wait_for(lambda: read() == before + "a", "Esc did not close the repeat prefix")
        run = raw_control_json(env, {"cmd": "keymap.run", "args": {"name": "Repeat B"}})
        assert run["ok"], run
        wait_for(lambda: read() == before + "ab", "keymap.run did not launch its named command")
        print("OK: leader autorepeats, key-release timeout, window switching, auxiliary focus, and Esc")
    finally:
        keys("keyup", "a", "keyup", "x", "keyup", "Control_L")
        stop(process)
