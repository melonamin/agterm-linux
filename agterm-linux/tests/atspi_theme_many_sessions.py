"""The `theme-many-sessions` AT-SPI scenario: a theme change with many live surfaces.

Colors are TERMINAL STATE read back through in-shell OSC 10/11 queries, never rendered pixels.
"""

import itertools
import os
import re
import shlex
import subprocess
import sys
import time

from atspi_smoke import control_json, launch, stop, wait_for, window_list, window_tree

# Measured to deadlock this harness when the main thread feeds theme OSC per surface, overflowing
# libghostty's 64-slot app mailbox that only it drains.
SESSION_COUNT = 16
BOUND_SECONDS = 4
LIGHT, DARK = "Atom One Light", "Dracula"
THEMES = {
    LIGHT: ("#f9f9f9", "#2a2c33"),
    DARK: ("#282a36", "#f8f8f2"),
    None: ("#282c34", "#ffffff"),
}
SESSION_COLOR, PROGRAM_COLOR = "#335577", "#aa0000"

PROBE = r'''
import os, re, select, sys, termios, time
query, tag = sys.argv[1], sys.argv[2]
fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
saved = termios.tcgetattr(fd)
value = "timeout"
try:
    mode = termios.tcgetattr(fd)
    mode[3] &= ~(termios.ICANON | termios.ECHO)
    mode[6][termios.VMIN], mode[6][termios.VTIME] = 0, 0
    termios.tcsetattr(fd, termios.TCSANOW, mode)
    termios.tcflush(fd, termios.TCIFLUSH)
    os.write(fd, f"\033]{query};?\033\\".encode())
    reply, deadline = b"", time.monotonic() + 2
    pattern = re.compile(rb"\033\]" + query.encode() + rb";rgb:([0-9a-fA-F/]+)(?:\007|\033\\)")
    while time.monotonic() < deadline:
        if select.select([fd], [], [], max(0.0, deadline - time.monotonic()))[0]:
            reply += os.read(fd, 256)
            match = pattern.search(reply)
            if match:
                channels = match.group(1).decode().split("/")
                value = "#" + "".join(
                    "%02x" % round(int(c, 16) * 255 / (16 ** len(c) - 1)) for c in channels)
                break
finally:
    termios.tcsetattr(fd, termios.TCSANOW, saved)
    os.close(fd)
print(f"COLORPROBE-{tag}={value}")
'''


def verify_theme_many_sessions(env):
    state = env["AGTERM_STATE_DIR"]
    probe_path = os.path.join(state, "color-probe.py")
    with open(probe_path, "w", encoding="utf-8") as target:
        target.write(PROBE)
    probe_tags = itertools.count()

    process, _ = launch(env)
    try:
        window_id = next(item["id"] for item in window_list(env) if item["open"])

        def sessions():
            return [item for workspace in window_tree(env, window_id)["workspaces"]
                    for item in workspace["sessions"]]

        def new_session(name):
            control_json(env, "session", "new", "--name", name, "--cwd", state,
                         "--window", window_id, "--json")
            return wait_for(lambda: next((item["id"] for item in sessions() if item["name"] == name), None),
                            f"session {name!r} never appeared in the tree")

        def bounded(what, *arguments):
            try:
                return control_json(env, *arguments, timeout=BOUND_SECONDS)
            except subprocess.TimeoutExpired as error:
                raise AssertionError(
                    f"{what} did not answer within {BOUND_SECONDS}s with {SESSION_COUNT} live sessions; "
                    "the app main thread is wedged") from error

        def osc(session_id, query):
            """One probe run in the session's shell; None when its marker never appeared."""
            tag = f"q{next(probe_tags)}"
            control_json(env, "session", "type",
                         f"\n{shlex.quote(sys.executable)} {shlex.quote(probe_path)} {query} {tag}\n",
                         "--target", session_id, "--window", window_id, "--json")
            marker = re.compile(rf"COLORPROBE-{tag}=(\S+)")

            def reported():
                text = control_json(env, "session", "text", "--lines", "40", "--target", session_id,
                                    "--window", window_id, "--json")["result"].get("text", "")
                match = marker.search(text)
                return match.group(1) if match else None

            return wait_for(reported, "", timeout=5, required=False)

        def expect(session_id, query, expected, what, timeout=30):
            """Poll fresh probes until OSC `query` reports `expected`; the mutation is never repeated."""
            deadline, seen = time.monotonic() + timeout, []
            while time.monotonic() < deadline:
                value = osc(session_id, query)
                seen.append(value)
                if value == expected:
                    return
            raise AssertionError(f"{what}: OSC {query} reported {seen[-3:]}, expected {expected}")

        def expect_theme(session_id, theme, what):
            background, foreground = THEMES[theme]
            expect(session_id, 10, foreground, f"{what} foreground")
            expect(session_id, 11, background, f"{what} background")

        def set_theme(theme):
            name = [] if theme is None else [theme]
            result = control_json(env, "theme", "set", *name, "--json")
            assert result["ok"] and not result["result"].get("dark"), f"theme set {theme!r} failed: {result}"

        def program_writes(session_id, sequence):
            control_json(env, "session", "type", f"\nprintf '{sequence}'\n",
                         "--target", session_id, "--window", window_id, "--json")

        def session_background(session_id, *arguments):
            control_json(env, "session", "background", *arguments, "--target", session_id,
                         "--window", window_id, "--json")

        first = sessions()[0]["id"]
        for index in range(1, SESSION_COUNT):
            new_session(f"theme-{index}")

        def live():
            nodes = sessions()
            return len(nodes) >= SESSION_COUNT and all(
                node.get("fontSize") and (node.get("foregroundShell") or node.get("foreground"))
                for node in nodes)

        wait_for(live, f"{SESSION_COUNT} sessions never all had a realized surface and a live shell",
                 timeout=60)

        for theme in (LIGHT, DARK, LIGHT):
            bounded(f"hang step: `theme set {theme}`", "theme", "set", theme, "--json")
            bounded(f"hang step: `tree` after `theme set {theme}`", "tree", "--json")
        print(f"OK: {SESSION_COUNT} live sessions survived three theme changes")

        expect_theme(first, LIGHT, "a surface created before the theme change")
        after = new_session("theme-after")
        expect_theme(after, LIGHT, "a surface created after the theme change")

        set_theme(None)
        expect_theme(first, None, "the built-in default theme")
        set_theme(LIGHT)
        expect_theme(first, LIGHT, "the light theme after the built-in default")

        program_writes(first, f"\\033]11;{PROGRAM_COLOR}\\007")
        expect(first, 11, PROGRAM_COLOR, "a program's OSC 11")
        set_theme(DARK)
        expect(first, 10, THEMES[DARK][1], "the dark theme's foreground under a program background")
        expect(first, 11, PROGRAM_COLOR, "a program's OSC 11 after a theme change", timeout=6)
        program_writes(first, "\\033]111\\007")
        expect(first, 11, THEMES[DARK][0], "OSC 111 after a theme change")

        session_background(after, "color", SESSION_COLOR)
        expect(after, 11, SESSION_COLOR, "a session background color")
        session_background(after, "clear")
        expect_theme(after, DARK, "a cleared session background color")

        session_background(after, "color", SESSION_COLOR)
        expect(after, 11, SESSION_COLOR, "a session background color before a program override")
        program_writes(after, f"\\033]11;{PROGRAM_COLOR}\\007")
        expect(after, 11, PROGRAM_COLOR, "a program's OSC 11 over a session color")
        set_theme(LIGHT)
        expect(after, 10, THEMES[LIGHT][1], "the light theme's foreground under a session color")
        expect(after, 11, PROGRAM_COLOR, "a program's OSC 11 over a session color after a theme change",
               timeout=6)
        program_writes(after, "\\033]111\\007")
        expect(after, 11, SESSION_COLOR, "OSC 111 over a session color after a theme change")
        print("OK: terminal colors follow the theme, session colors, and program OSC 10/11/111")
    finally:
        stop(process)
