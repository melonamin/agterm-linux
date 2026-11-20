"""Exercise v0.43 protocol/model adapters through the real GTK/WebKit host."""

from pathlib import Path
import subprocess

from atspi_smoke import CTL, collect, launch, mouse_click, raw_control_json, stop, wait_for


def verify_v0430(env, state):
    process, app = launch(env)

    def request(command, target=None, args=None):
        reply = raw_control_json(env, {"cmd": command, "target": target, "args": args or {}})
        assert reply["ok"], reply
        return reply.get("result", {})

    def row(identity):
        return next(row for workspace in request("tree")["tree"]["workspaces"]
                    for row in workspace["sessions"] if row["id"] == identity)

    def cli(*words):
        result = subprocess.run([CTL, *words, "--socket", env["AGTERM_CONTROL_SOCKET"]],
                                env=env, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
        return result

    try:
        identity = request("session.new", args={"name": "v0430 fixture"})["id"]
        request("session.status", identity, {"status": "active", "shape": "checkmark"})
        assert row(identity)["statusShape"] == "checkmark"
        request("session.split", identity, {"mode": "on"})
        request("session.status", identity, {"status": "active", "pane": "right"})
        request("session.status", identity, {"status": "completed", "pane": "left"})
        assert row(identity)["status"] == "active", row(identity)

        refused = raw_control_json(env, {"cmd": "pick.open", "target": "missing-session",
                                        "args": {"items": [{"id": "a", "label": "A"}]}})
        assert not refused["ok"], refused
        pick = request("pick.open", identity, {"items": [{"id": "a", "label": "A"}], "timeout": 0.3})["id"]
        wait_for(lambda: request("pick.result", pick)["pick"]["result"] == "cancelled",
                 "session-bound picker did not expire")
        assert row(identity).get("pick") is None, row(identity)
        pick = request("pick.open", args={"items": [{"id": "b", "label": "B"}], "timeout": 0.3})["id"]
        wait_for(lambda: request("pick.result", pick)["pick"]["result"] == "cancelled",
                 "window picker did not expire")
        ask = request("ask.open", identity, {"title": "Expires", "buttons": [{"id": "ok", "label": "OK"}],
                                               "timeout": 0.3})["id"]
        wait_for(lambda: request("ask.result", ask)["ask"]["result"] == "cancelled", "ask did not expire")

        request("session.scratch", identity, {"mode": "on"})
        directory = Path(state, "scratch-cwd")
        directory.mkdir()
        request("session.type", identity, {"text": f"cd '{directory}'\n", "pane": "scratch"})
        wait_for(lambda: row(identity).get("scratchCwd") == str(directory), "scratch cwd did not reach tree")
        request("session.scratch", identity, {"mode": "off"})

        source = Path(state, "records.jsonl")
        source.write_text('{"message":"one","nested":{"value":1}}\n{"message":"two"}\n', encoding="utf-8")
        cli("session", "overlay", "open", "--text", str(source), "--target", identity)

        def text():
            return next(iter(row(identity).get("htmlOverlays", [])), {}).get("text", {})

        wait_for(lambda: text().get("language") == "jsonl", "JSONL page did not load")
        request("session.overlay.wrap", identity, {"mode": "off"})
        request("session.overlay.expand", identity, {"mode": "on"})
        request("session.overlay.close", identity)

        folder = Path(state, "markdown")
        folder.mkdir()
        first = folder / "first.md"
        second = folder / "second.md"
        first.write_text("# First\n[Linked document](second.md)\n", encoding="utf-8")
        second.write_text("# Second document\n", encoding="utf-8")
        cli("session", "overlay", "open", "--markdown", str(first), "--navigation", "--target", identity)
        request("session.select", identity)
        wait_for(lambda: collect(app, role="link", name="Linked document"), "markdown local link did not render")
        mouse_click(lambda: collect(app, role="link", name="Linked document")[0], process.pid, button="left")
        collect(app, role="link", name="Linked document")[0].get_action_iface().do_action(0)

        def shown_page():
            return next(iter(row(identity).get("htmlOverlays", [])), {})

        try:
            wait_for(lambda: shown_page().get("page") == str(second), "contained markdown link did not navigate")
        except AssertionError:
            print("Markdown page:", shown_page())
            raise
        request("session.overlay.navigate", identity, {"to": "back"})
        wait_for(lambda: shown_page().get("page") == str(first), "markdown back history did not navigate")
        request("session.overlay.close", identity)

        page = Path(state, "page.html")
        page.write_text("<h1>top-level page</h1>", encoding="utf-8")
        created = cli("session", "overlay", "open", "--page", "--html", str(page), "--target", identity)
        assert created.stdout
        converted = request("session.companion.convert", identity)
        assert row(identity)["parent"] == converted["parent"]
        other = request("session.new", args={"name": "new parent"})["id"]
        request("session.companion.move", identity, {"parent": other})
        assert row(identity)["parent"] == other
        print("OK: v0.43 session pick/ask deadlines, pane activity, scratch cwd, JSONL and companion placement")
    finally:
        stop(process)


def verify_live_scratch(env, state):
    import json
    import os
    import shlex
    from atspi_smoke import ROOT

    fixture = Path(state, "scratch-login-shell.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-o", str(fixture),
                    str(Path(ROOT, "tests/login_shell_zsh_fixture.c")), "-ldl"], check=True)
    Path(state, "settings.json").write_text(json.dumps({"restoreMode": "live", "closeGraceUndoEnabled": False}))
    live_env = dict(env, LD_PRELOAD=str(fixture))
    process, _ = launch(live_env)

    def request(command, target=None, args=None):
        reply = raw_control_json(live_env, {"cmd": command, "target": target, "args": args or {}})
        assert reply["ok"], reply
        return reply.get("result", {})

    try:
        assert request("restore.mode")["restore"]["active"] == "live"
        identity = request("session.new", args={"name": "Persistent scratch"})["id"]
        marker = Path(state, "scratch.pid")
        command = "/bin/sh -c " + shlex.quote("echo $$ > " + shlex.quote(str(marker))
                                             + "; printf 'SCRATCH-SURVIVED\\n'; exec sleep 3600")
        request("session.scratch", identity, {"mode": "on", "command": command})
        wait_for(marker.exists, "live scratch program did not start")
        pid = int(marker.read_text())
        request("session.scratch", identity, {"mode": "off"})
        assert Path(f"/proc/{pid}").exists(), "hiding scratch ended its program"
        stop(process)
        assert Path(f"/proc/{pid}").exists(), "application quit ended its live scratch"
        process, _ = launch(live_env)
        request("session.select", identity)
        request("session.scratch", identity, {"mode": "on"})
        wait_for(lambda: "SCRATCH-SURVIVED" in request("session.text", identity, {"pane": "scratch", "all": True})["text"],
                 "relaunch did not restore the scratch daemon's screen")
        assert int(marker.read_text()) == pid and Path(f"/proc/{pid}").exists(), "relaunch replaced the scratch process"
        replacement = Path(state, "scratch-replacement.pid")
        command = "/bin/sh -c " + shlex.quote("echo $$ > " + shlex.quote(str(replacement)) + "; exec sleep 3600")
        request("session.scratch", identity, {"mode": "on", "command": command})
        wait_for(replacement.exists, "scratch command replacement did not start")
        wait_for(lambda: not Path(f"/proc/{pid}").exists() or Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] == "Z",
                 "scratch replacement left its previous program running")
        pid = int(replacement.read_text())
        request("session.close", identity)
        wait_for(lambda: not Path(f"/proc/{pid}").exists() or Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] == "Z",
                 "session close left its scratch program running")
        print("OK: live scratch survives hide/relaunch, replaces its command, and ends with its session")
    finally:
        stop(process)
