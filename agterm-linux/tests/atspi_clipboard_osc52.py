"""OSC 52 reaches the GDK clipboard, and a denied read answers the pane once with an empty reply."""

import base64
import json
import os
import sys
import time

import gi

gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

from atspi_smoke import (Atspi, activate, collect, control_json, launch, poll, stop, wait_for,
                         window_list, window_tree)

TOKEN = "agterm-osc52-token"
ENCODED = base64.b64encode(TOKEN.encode()).decode()
REPLY_QUIET_SECONDS = 2

# Raw mode keeps the reply away from the line discipline and the shell; a second reply lands in `replies`.
READER = rf"""
import json, os, select, sys, time, tty
tty.setraw(0)
os.write(1, b"\x1b]52;c;?\x07")
deadline = time.monotonic() + 30
received = b""
while time.monotonic() < deadline:
    if select.select([0], [], [], 0.1)[0]:
        received += os.read(0, 4096)
        if b"\x1b\\" in received:
            deadline = min(deadline, time.monotonic() + {REPLY_QUIET_SECONDS})
with open(sys.argv[1] + ".tmp", "w") as result:
    json.dump(received.decode("latin-1"), result)
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
"""


def clipboard_text(clipboard):
    outcome = []

    def finished(source, result):
        try:
            outcome.append(source.read_text_finish(result))
        except GLib.Error:
            outcome.append(None)

    clipboard.read_text_async(None, finished)
    context = GLib.MainContext.default()
    deadline = time.monotonic() + 3
    while not outcome and time.monotonic() < deadline:
        context.iteration(False)
        time.sleep(0.01)
    return outcome[0] if outcome else None


def prompt_button(app, label):
    buttons = collect(app, role="button", name=label)
    return next((button for button in buttons if button.get_state_set().contains(Atspi.StateType.SHOWING)), None)


def verify_clipboard_osc52(env):
    state = env["AGTERM_STATE_DIR"]
    os.makedirs(os.path.join(state, "config"))
    with open(os.path.join(state, "config", "ghostty.conf"), "w", encoding="utf-8") as config:
        config.write("clipboard-read = ask\nclipboard-write = allow\n")
    reader = os.path.join(state, "osc52-reader.py")
    with open(reader, "w", encoding="utf-8") as script:
        script.write(READER)

    process, app = launch(env)
    try:
        window = next(row["id"] for row in window_list(env) if row["open"])
        session = window_tree(env, window)["workspaces"][0]["sessions"][0]["id"]

        def type_line(line):
            control_json(env, "session", "type", line + "\n", "--target", session, "--window", window, "--json")

        def read_answering(label, result):
            type_line(f"{sys.executable} {reader} {result}")
            activate(wait_for(lambda: prompt_button(app, label), "OSC 52 read did not prompt"))
            wait_for(lambda: not prompt_button(app, label), "the clipboard prompt stayed after its answer")
            assert not poll(lambda: prompt_button(app, "Deny"), REPLY_QUIET_SECONDS), (
                "one OSC 52 read prompted twice"
            )
            wait_for(lambda: os.path.exists(result), "the pane never finished its OSC 52 read", timeout=35)
            with open(result, encoding="utf-8") as reply:
                return json.load(reply)

        Gtk.init()
        clipboard = Gdk.Display.get_default().get_clipboard()
        type_line(f"printf '\\033]52;c;{ENCODED}\\007'")
        wait_for(lambda: clipboard_text(clipboard) == TOKEN, "OSC 52 write did not reach the GDK clipboard")

        denied = read_answering("Deny", os.path.join(state, "denied"))
        assert denied == "\x1b]52;c;\x1b\\", f"a denied read did not get the empty reply once: {denied!r}"

        allowed = read_answering("Allow", os.path.join(state, "allowed"))
        assert allowed == f"\x1b]52;c;{ENCODED}\x1b\\", f"an allowed read did not get the clipboard: {allowed!r}"
        print("OK: OSC 52 write reached GDK; a denied read answered once, empty, and an allowed read got the clipboard")
    finally:
        stop(process)
