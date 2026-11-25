"""A managed Live command's hold prompt must preserve its screen and scrollback."""

import contextlib
import json
import os
import shlex
import signal
import subprocess

from atspi_smoke import ROOT, launch, raw_control_json, stop, wait_for


def verify_live_wait_output(env, state):
    fixture = os.path.join(state, "login-shell.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-o", fixture,
                    os.path.join(ROOT, "tests/login_shell_zsh_fixture.c"), "-ldl"], check=True)
    with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as file:
        json.dump({"restoreMode": "live", "closeGraceUndoEnabled": False}, file)
    gate = os.path.join(state, "release-command")
    observed = os.path.join(state, "read-after-daemon-exit")
    zmx = env.get("AGTERM_TEST_ZMX_PATH", os.path.join(ROOT, "vendor/zmx/zmx"))
    wrapper = os.path.join(state, "zmx-read-race")
    # Hold the real screen invocation until this command's real daemon has removed its socket.
    # The synchronous control handler cannot process the queued held-exit callback while it waits.
    with open(wrapper, "w", encoding="utf-8") as file:
        file.write("#!/bin/sh\n"
                   f'if [ "$1" = screen ] && [ -f {shlex.quote(gate)} ]; then\n'
                   '  i=0; while [ -S "$ZMX_DIR/$2" ] && [ "$i" -lt 200 ]; do\n'
                   '    sleep .01; i=$((i+1)); done\n'
                   f'  if [ ! -e "$ZMX_DIR/$2" ]; then : > {shlex.quote(observed)}; fi\n'
                   'fi\n'
                   f'exec {shlex.quote(zmx)} "$@"\n')
    os.chmod(wrapper, 0o755)
    live_env = dict(env, LD_PRELOAD=fixture, AGTERM_ZMX_PATH=wrapper)
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
        for first_read in ("text", "cursor"):
            for path in (gate, observed):
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(path)
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
            entry = next(entry for entry in inventory["entries"]
                         if entry.get("sessionID", "").lower() == identity.lower())
            assert entry["observation"] == "running", inventory
            if first_read == "text":
                wait_for(lambda: row()["surfaces"][0].get("lead") == "leader", "pane did not report its lead")
                # The reported PTY leader is a direct child of the daemon; socket credentials may
                # still name a process that created the socket before a fork.
                with open(f'/proc/{entry["leaderPID"]}/stat', encoding="utf-8") as file:
                    status = file.read()
                daemon_pid = int(status[status.rindex(")") + 2:].split()[1])
                assert daemon_pid > 1 and daemon_pid != process.pid, daemon_pid
                os.kill(daemon_pid, signal.SIGSTOP)
                try:
                    failed = raw_control_json(live_env, {"cmd": "session.text", "target": identity, "args": {"all": True}})
                    assert not failed["ok"] and failed["error"] == "failed to read surface buffer", failed
                finally:
                    os.kill(daemon_pid, signal.SIGCONT)
                assert row()["surfaces"][0]["lead"] == "leader", "a live read failure retired the lead"
                print("OK: a live but unresponsive daemon keeps its read error and lead", flush=True)
            with open(gate, "w", encoding="utf-8") as file:
                file.write("exit\n")
            if first_read == "cursor":
                request("surface.cursor", running["surfaces"][0]["id"])
            wait_for(lambda: "Press any key" in text(), "Live command did not reach its exit hold")
            assert os.path.exists(observed), "fixture did not read across the daemon's exit"
            held = text()
            assert "WAIT-START-MARK" in held and "WAIT-FINAL-MARK" in held, held
            visible = request("session.text", identity)["text"]
            assert "WAIT-FINAL-MARK" in visible, "final output was cleared from the held screen: " + visible
            assert row() is not None, "the held session closed instead of retaining its output"
            request("session.close", identity)
            print("OK: held daemon exit with first read", first_read, flush=True)
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
