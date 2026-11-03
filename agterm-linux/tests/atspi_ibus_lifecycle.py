"""Real IBus focus idles must not dereference a terminal removed by a dialog response."""

import os
from pathlib import Path
import subprocess
import time

from atspi_smoke import (ABSOLUTE_DYS, activate, launch, named, poll, raw_control_json, right_click,
                         stop, type_x11_text, wait_for, window_list, window_tree)


def verify_ibus_lifecycle(env):
    env = dict(env, GTK_IM_MODULE="ibus")
    daemon = subprocess.Popen(["ibus-daemon", "--replace", "--panel=disable", "--config=disable",
                               "--emoji-extension=disable"], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    process = None
    try:
        def ready():
            result = subprocess.run(["ibus", "address"], env=env, text=True, capture_output=True, timeout=3)
            return result.returncode == 0 and result.stdout.strip().startswith("unix:")

        wait_for(ready, "private IBus daemon did not publish its address")
        process, app = launch(env)
        window = next(item["id"] for item in window_list(env) if item["open"])

        def request(cmd, target=None, args=None):
            assert process.poll() is None, f"IBus terminated agterm: {process.returncode}"
            response = raw_control_json(env, {"cmd": cmd, "target": target,
                                               "args": dict(args or {}, window=window)})
            assert response["ok"], response
            return response.get("result", {})

        for index in range(4):
            name = f"IBus victim {index}"
            workspace = request("workspace.new", args={"name": name})["id"]
            request("session.new", args={"workspace": workspace, "name": "IBus terminal"})
            time.sleep(0.2)
            maps = Path(f"/proc/{process.pid}/maps").read_text()
            assert "libim-ibus.so" in maps, "the real GTK IBus module was not loaded"
            for offset in ABSOLUTE_DYS:
                right_click(lambda: named(app, name, role="label"), process.pid, dy=offset)
                if poll(lambda: named(app, "Delete Workspace", role="button"), timeout=1):
                    break
            activate(wait_for(lambda: named(app, "Delete Workspace", role="button"), "workspace menu did not open"))
            activate(wait_for(lambda: named(app, "Delete", role="button"), "delete confirmation did not open"))
            time.sleep(0.3)  # Drain the IBus idle queued when the dialog restores terminal focus.
            assert process.poll() is None, f"IBus crashed during workspace deletion: {process.returncode}"
            assert all(item["id"] != workspace for item in window_tree(env, window)["workspaces"])
        # Exercise actual GTK keyboard input through IBus after the deleted clients are gone.
        marker = "ibus_input_survived"
        type_x11_text(f"echo {marker}", process.pid)
        from atspi_smoke import press_return
        press_return(process.pid)
        session = window_tree(env, window)["workspaces"][0]["sessions"][0]["id"]
        wait_for(lambda: marker in request("session.text", session).get("text", ""),
                 "IBus no longer commits typed text after workspace deletion")
        print("OK: real IBus survives four focused workspace deletions and still commits keyboard input")
    except Exception:
        if process and process.poll() is None:
            from atspi_smoke import describe_tree
            from x11_capture import capture
            capture(os.path.join(env["AGTERM_STATE_DIR"], "ibus-failure.png"))
            print("IBus evidence:", env["AGTERM_STATE_DIR"], flush=True)
            describe_tree(app)
        raise
    finally:
        if process:
            stop(process)
        daemon.terminate()
        daemon.wait(timeout=5)
