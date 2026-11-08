"""Focus changes while a covered pane's takeover key is still held."""

import os
import shlex
import subprocess
import time

from atspi_smoke import actionable, control_json, named, raw_control_json, wait_for


def verify_takeover_release_in_entry(env, app, session_id, lead, zoom, palette=False):
    """Observe releases both inside the window and in a separate palette toplevel."""
    mode = "palette" if palette else "search"
    marker = os.path.join(env["AGTERM_STATE_DIR"], f"takeover-release-{mode}.marker")

    def entry_visible():
        return named(app, "Command Palette", role="frame") if palette else actionable(app, "Next match (Enter)")
    staged = raw_control_json(env, {
        "cmd": "session.type", "target": session_id,
        "args": {"text": "printf release-recovered > " + shlex.quote(marker), "pane": "right"},
    })
    assert staged["ok"], staged
    wait_for(lambda: "release-recovered" in (raw_control_json(env, {
        "cmd": "session.text", "target": session_id, "args": {"pane": "right", "all": True},
    }).get("result", {}).get("text") or ""), "the release probe command was not staged")
    zoom("right")
    assert lead("right") == "follower", "release probe needs a covered split"
    subprocess.run(["xdotool", "keydown", "Return"], check=True)
    try:
        wait_for(lambda: lead("right") == "leader", "release probe did not take the split lead")
        hidden = control_json(env, "surface", "zoom", "hide",
                              "--target", f"surface:{session_id}:right", "--json")
        assert hidden["ok"], hidden
        subprocess.run(["xdotool", "key", "ctrl+shift+p" if palette else "ctrl+shift+f"], check=True)
        wait_for(entry_visible, f"{mode} did not take the keyboard")
    finally:
        subprocess.run(["xdotool", "keyup", "Return"], check=True)
    time.sleep(0.2)
    assert not os.path.exists(marker), "takeover press, repeat or release reached the shell"
    if palette:
        subprocess.run(["xdotool", "key", "Escape"], check=True)
    else:
        closed = raw_control_json(env, {
            "cmd": "session.search", "target": session_id, "args": {"to": "close"},
        })
        assert closed["ok"], closed
    wait_for(lambda: entry_visible() is None, f"{mode} did not close")
    zoom("right")
    subprocess.run(["xdotool", "key", "Return"], check=True)
    wait_for(lambda: os.path.exists(marker),
             f"first genuine Return was swallowed after its takeover release landed in {mode}")
    hidden = control_json(env, "surface", "zoom", "hide",
                          "--target", f"surface:{session_id}:right", "--json")
    assert hidden["ok"], hidden
    print(f"OK: takeover key release in {mode} clears the latch before the next terminal press")
