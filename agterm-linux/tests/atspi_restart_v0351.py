"""Real daemon/process coverage for stable pane addressing and live restart."""

import json
import os
import shlex
import subprocess

from atspi_smoke import ROOT, launch, raw_control_json, stop, wait_for, window_list, window_tree


def verify_restart_v0351(env, state):
    fixture = os.path.join(state, "restart-login-shell.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-o", fixture,
                    os.path.join(ROOT, "tests/login_shell_zsh_fixture.c"), "-ldl"], check=True)
    with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as file:
        json.dump({"restoreMode": "live", "closeGraceUndoEnabled": False}, file)
    configured = env.get("AGTERM_TEST_COMMAND_SHELL")
    if configured:
        config = os.path.join(state, "config")
        os.makedirs(config, exist_ok=True)
        with open(os.path.join(config, "ghostty.conf"), "w", encoding="utf-8") as file:
            file.write("config-file = " + os.path.join(config, "shell.ghostty") + "\n")
        with open(os.path.join(config, "shell.ghostty"), "w", encoding="utf-8") as file:
            file.write("command = " + configured + "\n")
    env = dict(env, LD_PRELOAD=fixture)
    process, _app = launch(env)
    try:
        window = next(row["id"] for row in window_list(env) if row["open"])

        def request(cmd, target=None, args=None):
            return raw_control_json(env, {"cmd": cmd, "target": target, "args": dict(args or {}, window=window)})

        def sessions():
            return [row for workspace in window_tree(env, window)["workspaces"] for row in workspace["sessions"]]

        if configured or env.get("AGTERM_TEST_LOGIN_SHELL") == "/usr/bin/fish":
            wait_for(lambda: any(row.get("foregroundShell") == "fish" for row in sessions()),
                     "Live fish did not start an integrated fish shell")

        if configured:
            with open(os.path.join(state, "config", "shell.ghostty"), "w", encoding="utf-8") as file:
                file.write("command = /usr/bin/zsh\n")
            created = request("session.new", args={"name": "latched shell"})
            assert created["ok"], created
            wait_for(lambda: any(row["id"] == created["result"]["id"] and row.get("foregroundShell") == "fish"
                                 for row in sessions()), "config edit changed this app run's Live shell identity")
            print("OK: Ghostty included command overrides password shell and remains latched", flush=True)

        pid_file = os.path.join(state, "old-job.pid")
        command = f"/bin/sh -c {shlex.quote('echo $$ > ' + shlex.quote(pid_file) + '; exec sleep 3600')}"
        created = request("session.new", args={"name": "restart target", "command": command})
        assert created["ok"], created
        session = created["result"]["id"]
        wait_for(lambda: os.path.exists(pid_file), "initial foreground job did not start", timeout=15)
        with open(pid_file, encoding="utf-8") as file:
            old_job = int(file.read())

        def pane_id():
            row = next(row for row in sessions() if row["id"] == session)
            return next(pane["paneID"] for pane in row["surfaces"] if pane["kind"] == "left")

        identity = pane_id()
        address = session + ":" + identity
        queued = request("msg.send", args={"recipients": [address], "body": "belongs to old job"})
        assert queued["ok"] and queued["result"]["delivered"] == [address], queued
        bad = request("session.restart", session, {"pane": "left", "paneID": "unknown", "command": "sleep 3600"})
        assert not bad["ok"] and "unknown pane id" in bad["error"], bad
        assert os.path.exists(f"/proc/{old_job}"), "refused restart killed the foreground job"
        assert request("msg.read", args={"identity": address})["result"]["messages"], "refused restart discarded mail"
        background = request("session.new", args={"name": "foreground while restarting"})
        assert background["ok"], background
        new_pid_file = os.path.join(state, "new-job.pid")
        line = f"/bin/sh -c {shlex.quote('echo $$ > ' + shlex.quote(new_pid_file) + '; printf restart-screen; exec sleep 3600')}"
        reply = request("session.restart", session, {"paneID": identity, "command": line})
        assert reply["ok"], reply
        receipt = reply["result"]["restart"]
        assert receipt["paneID"].lower() == identity.lower(), receipt
        assert receipt["oldPid"] != receipt["newPid"], receipt
        assert pane_id() == identity, "restart changed the stable pane identity"
        assert not request("msg.read", args={"identity": address})["result"]["messages"], "replacement inherited old job mail"
        assert next(row for row in sessions() if row["id"] == background["result"]["id"])["active"], \
            "background restart stole the active session"
        wait_for(lambda: os.path.exists(new_pid_file), "new foreground job did not start")

        def ended(pid):
            try:
                with open(f"/proc/{pid}/stat", encoding="utf-8") as file:
                    return file.read().rsplit(")", 1)[1].split()[0] == "Z"
            except FileNotFoundError:
                return True

        wait_for(lambda: ended(old_job), "restart left the old foreground program running")
        with open(new_pid_file, encoding="utf-8") as file:
            new_job = int(file.read())
        assert not ended(new_job), "new program already ended"
        daemon = "agterm-" + identity.replace("-", "").lower()
        screen = request("zmx.screen", args={"name": daemon, "all": True})
        assert screen["ok"] and "restart-screen" in screen["result"]["text"], screen
        replay = request("session.restart", session, {"paneID": identity})
        assert replay["ok"], replay
        replay_receipt = replay["result"]["restart"]
        assert os.path.basename(replay_receipt["replayedArgv"][0]) == "sleep", replay_receipt
        assert replay_receipt["replayedArgv"][1:] == ["3600"], replay_receipt
        wait_for(lambda: ended(new_job), "foreground replay left the old program running")
        wait_for(lambda: next(row for row in sessions() if row["id"] == session).get("foreground", [None])[-1] == "3600",
                 "replayed foreground program did not start")
        assert pane_id() == identity, "foreground replay changed pane identity"
        new_job = replay_receipt["newPid"]
        second_window = raw_control_json(env, {"cmd": "window.new", "args": {"name": "cursor route probe"}})
        assert second_window["ok"], second_window
        cursor = raw_control_json(env, {"cmd": "surface.cursor", "target": session, "args": {"paneID": identity}})
        assert cursor["ok"], cursor
        invalid_cursor = raw_control_json(env, {"cmd": "surface.cursor", "target": "quick",
                                               "args": {"paneID": identity}})
        assert not invalid_cursor["ok"] and "takes a session target" in invalid_cursor["error"], invalid_cursor
        closed = request("session.close", session)
        assert closed["ok"], closed
        wait_for(lambda: ended(new_job), "ordinary pane close left the foreground program running")
        print("OK: real live restart retained pane identity, changed shell PID, ended the old job, and pane close ended its replacement")
    finally:
        stop(process)
