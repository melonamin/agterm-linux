"""A managed Live command's hold prompt must preserve its screen and scrollback."""

import contextlib
import json
import os
import shlex
import subprocess

from atspi_smoke import ROOT, launch, raw_control_json, stop, wait_for


def verify_live_wait_output(env, state):
    fixture = os.path.join(state, "login-shell.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-o", fixture,
                    os.path.join(ROOT, "tests/login_shell_zsh_fixture.c"), "-ldl"], check=True)
    with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as file:
        json.dump({"restoreMode": "live", "closeGraceUndoEnabled": False}, file)
    live_env = dict(env, LD_PRELOAD=fixture,
                    AGTERM_ZMX_PATH=env.get("AGTERM_TEST_ZMX_PATH", os.path.join(ROOT, "vendor/zmx/zmx")))
    gate = os.path.join(state, "release-command")
    command = ("printf 'WAIT-START-MARK\\n'; while [ ! -f " + shlex.quote(gate)
               + " ]; do sleep 0.05; done; printf 'WAIT-FINAL-MARK\\n'; exit 3")
    process, _ = launch(live_env)
    inventory = None
    try:
        def request(cmd, target=None, args=None):
            reply = raw_control_json(live_env, {"cmd": cmd, "target": target, "args": args or {}})
            assert reply["ok"], reply
            return reply.get("result", {})

        restore = request("restore.mode")["restore"]
        assert restore["active"] == "live", restore
        identity = request("session.new", args={"name": "Live held output", "command": command, "wait": True})["id"]

        def row():
            return next((session for workspace in request("tree")["tree"]["workspaces"]
                         for session in workspace["sessions"] if session["id"] == identity), None)

        def text():
            return request("session.text", identity, {"all": True})["text"]

        wait_for(lambda: "WAIT-START-MARK" in text(), "Live command did not print its initial output")
        running = row()
        assert running["commandWait"] and running["surfaces"][0]["backedByZmx"], running
        inventory = request("zmx.list")["zmx"]
        assert any(entry.get("sessionID", "").lower() == identity.lower() and entry["observation"] == "running"
                   for entry in inventory["entries"]), inventory
        with open(gate, "w", encoding="utf-8") as file:
            file.write("exit\n")
        wait_for(lambda: "Press any key" in text(), "Live command did not reach its exit hold")
        held = text()
        assert "WAIT-START-MARK" in held and "WAIT-FINAL-MARK" in held, held
        visible = request("session.text", identity)["text"]
        assert "WAIT-FINAL-MARK" in visible, "final output was cleared from the held screen: " + visible
        assert row() is not None, "the held session closed instead of retaining its output"
        request("session.close", identity)
        print("OK: Live --wait keeps initial/final command output under the exit prompt")
    finally:
        with contextlib.suppress(AssertionError, OSError):
            inventory = request("zmx.list")["zmx"]
        stop(process)
        if inventory and (endpoint := inventory.get("endpoint")):
            cleanup_env = dict(live_env, ZMX_DIR=endpoint["socketDirectory"])
            cleanup_env.pop("ZMX_SESSION", None)
            for entry in inventory["entries"]:
                subprocess.run([endpoint["executable"], "kill", entry["daemon"], "--force"],
                               env=cleanup_env, capture_output=True, timeout=5)
