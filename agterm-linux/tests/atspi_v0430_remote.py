"""Real OpenSSH, headless origin and GTK catalog/attached-row integration."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

from atspi_smoke import ROOT, launch, raw_control_json, stop, wait_for


def verify_v0430_remote(env, state, acceptance=False, history_only=False, v0441_only=False):
    config = env.get("AGTERM_TEST_SSH_CONFIG")
    assert config, "this scenario requires an isolated real SSH host"
    root = Path(state)
    origin = root / "origin"
    origin.mkdir()
    # Only Unix sockets live here; keep paths short without reusing container PIDs across test runs.
    runtime = Path(tempfile.mkdtemp(prefix="rt43-", dir="/tmp"))
    resources = root / "server-resources"
    resources.mkdir()
    (resources / "shell-integration").symlink_to(Path(ROOT, "vendor/ghostty/share/ghostty/shell-integration"))
    (resources / "terminfo").symlink_to(Path(ROOT, "vendor/ghostty/share/terminfo"))
    tools = root / "tools"
    tools.mkdir()
    ssh = tools / "ssh"
    setting = "SetEnv=AGTERM_STATE_DIR=" + str(origin)
    if remote_cli := env.get("AGTERM_TEST_REMOTE_CLI"):
        setting += " AGTERM_TEST_REMOTE_CLI=" + remote_cli
    ssh.write_text("#!/bin/sh\nexec /usr/bin/ssh -F " + shlex.quote(config) + " -o " + shlex.quote(setting) + ' "$@"\n')
    ssh.chmod(0o755)
    origin_env = dict(env, AGTERM_STATE_DIR=str(origin), AGTERM_CONTROL_SOCKET=str(origin / "agterm.sock"), XDG_RUNTIME_DIR=str(runtime))
    viewer_env = dict(env, PATH=str(tools) + ":" + env["PATH"])
    binary = Path(env.get("AGTERM_TEST_ORIGIN_SERVER", str(Path(ROOT).parent / "agtermCore/.build/debug/agterm-server")))
    log = open(root / "server.log", "w", encoding="utf-8")
    server = subprocess.Popen([str(binary), "--state-dir", str(origin), "--zmx", env.get("AGTERM_TEST_ORIGIN_ZMX", str(Path(ROOT, "vendor/zmx/zmx"))),
                               "--resources", str(resources)], env=origin_env, stdout=log, stderr=log)
    viewer = None

    def request(environment, command, target=None, args=None):
        response = raw_control_json(environment, {"cmd": command, "target": target, "args": args or {}}, timeout=45)
        assert response["ok"], response
        return response.get("result", {})

    def tree(window):
        return request(viewer_env, "tree", args={"window": window})["tree"]

    def rows(window):
        return [row for workspace in tree(window)["workspaces"] for row in workspace["sessions"]]

    def row(window, identity):
        return next((row for row in rows(window) if row["id"] == identity), None)

    try:
        wait_for(lambda: (origin / "agterm.sock").exists(), "headless server did not start")
        if v0441_only:
            viewer, viewer_app = launch(viewer_env)
            local_window = request(viewer_env, "window.list")["windows"][0]["id"]
            if env.get("AGTERM_AUDIT_REMOTE") in ("extended", "lead"):
                from atspi_v0441_remote_audit import verify_remote, verify_lead
                check = verify_lead if env.get("AGTERM_AUDIT_REMOTE") == "lead" else verify_remote
                check(origin_env, viewer_env, viewer, viewer_app, local_window, root, request)
            else:
                from atspi_v0441_remote import verify_v0441_remote
                verify_v0441_remote(origin_env, viewer_env, viewer, viewer_app, local_window, root, request)
            return
        created = request(origin_env, "session.new", args={"name": "SSH origin"})["id"]
        for index in range(19):
            request(origin_env, "session.new", args={"name": "SSH scale " + str(index), "noSelect": True})
        viewer, viewer_app = launch(viewer_env)
        local_window = request(viewer_env, "window.list")["windows"][0]["id"]
        remote_window = request(viewer_env, "window.remote.open", args={"host": "local-test"})["id"]
        wait_for(lambda: row(remote_window, created), "remote catalog did not install its snapshot", timeout=30)
        wait_for(lambda: len(rows(remote_window)) == 20 and all(
            row.get("presentation", {}).get("state") == "connected" for row in rows(remote_window)),
            "20 remote rows did not connect under sshd's stock MaxSessions limit", timeout=60)
        request(viewer_env, "session.rename", created, {"name": "Renamed through SSH", "window": remote_window})
        wait_for(lambda: row(remote_window, created).get("name") == "Renamed through SSH", "catalog receipt did not update the GTK row")
        fresh = request(viewer_env, "session.new", args={"window": remote_window, "name": "Created remotely"})["id"]
        wait_for(lambda: row(remote_window, fresh), "created catalog row did not arrive")
        request(viewer_env, "session.detach", fresh, {"window": remote_window})
        assert row(remote_window, fresh) is None
        request(viewer_env, "session.reattach", fresh, {"window": remote_window})
        wait_for(lambda: row(remote_window, fresh), "detached catalog row did not reattach")
        attached = request(viewer_env, "zmx.attach", created, {"host": "local-test", "window": local_window})["id"]
        assert row(local_window, attached).get("remoteSessionID") == created, "attachment tree omitted the origin session id"
        wait_for(lambda: row(local_window, attached).get("presentation", {}).get("state") == "connected",
                 "attached row did not connect its presentation stream", timeout=30)
        document = root / "catalog-page.html"
        document.write_text("<title>Catalog page over SSH</title><h1>Catalog page</h1>", encoding="utf-8")
        page = request(origin_env, "session.page", created, {"html": str(document), "cwd": str(root)})["id"]
        wait_for(lambda: row(remote_window, page) and row(remote_window, page).get("htmlOverlays", [{}])[0].get("state") == "loaded",
                 "catalog page row did not load from its origin", timeout=30)
        standalone = request(viewer_env, "zmx.attach", page, {"host": "local-test", "window": local_window})["id"]
        wait_for(lambda: row(local_window, standalone).get("htmlOverlays", [{}])[0].get("state") == "loaded",
                 "top-level page did not attach", timeout=30)
        stop(viewer)
        viewer, viewer_app = launch(viewer_env)
        wait_for(lambda: row(local_window, attached) and row(local_window, attached).get("presentation", {}).get("state") == "connected",
                 "persisted terminal attachment did not reconnect", timeout=30)
        wait_for(lambda: row(local_window, standalone) and row(local_window, standalone).get("htmlOverlays", [{}])[0].get("state") == "loaded",
                 "persisted page attachment did not reclaim its page", timeout=30)
        if history_only:
            from atspi_v0430_history import verify_attached_history
            request(viewer_env, "window.close", remote_window)
            verify_attached_history(origin_env, viewer_env, viewer, viewer_app, local_window, root, request)
            return
        if acceptance:
            request(viewer_env, "window.close", remote_window)
            from atspi_v0430_viewers import verify_viewer_handoffs
            verify_viewer_handoffs(origin_env, viewer_env, viewer, viewer_app, local_window, attached, created, root, request)
            remote_window = request(viewer_env, "window.remote.open", args={"host": "local-test"})["id"]
            wait_for(lambda: row(remote_window, created), "catalog did not reconnect after viewer acceptance")
        request(viewer_env, "session.split", attached, {"mode": "on", "window": local_window})
        wait_for(lambda: row(local_window, attached).get("hasSplit"), "origin split did not reach attached row", timeout=30)
        request(viewer_env, "session.split.close", attached, {"window": local_window})
        wait_for(lambda: not row(local_window, attached).get("hasSplit"), "origin split close did not reach attached row", timeout=30)
        request(viewer_env, "session.scratch", attached, {"mode": "on", "window": local_window})
        wait_for(lambda: row(local_window, attached).get("scratch"), "origin scratch did not reach attached row", timeout=30)
        request(viewer_env, "session.scratch", attached, {"mode": "off", "window": local_window})
        request(viewer_env, "session.terminate", attached, {"window": local_window})
        wait_for(lambda: row(local_window, attached) is None, "terminated attached row stayed open")
        wait_for(lambda: row(remote_window, created) is None, "terminated origin stayed in catalog")
        print("OK: real SSH headless catalog, receipts, create, detach/reattach, attached split/scratch/terminate", flush=True)
    finally:
        if viewer:
            stop(viewer)
        try:
            entries = request(origin_env, "zmx.list").get("zmx", {}).get("entries", [])
            for identity in {entry["sessionID"] for entry in entries if entry.get("sessionID")}:
                request(origin_env, "session.close", identity)
        except (AssertionError, OSError):
            pass
        server.terminate()
        server.wait(timeout=10)
        log.close()
        if artifacts := os.environ.get("AGTERM_UI_ARTIFACT_DIR"):
            shutil.copyfile(root / "server.log", Path(artifacts, "server.log"))
        shutil.rmtree(runtime, ignore_errors=True)
