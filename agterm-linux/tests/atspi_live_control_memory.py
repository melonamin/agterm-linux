"""Polling a led Live pane over the control socket must not grow the app's heap."""

import contextlib
import json
import os
import re
import subprocess

from atspi_smoke import ROOT, launch, raw_control_json, stop, wait_for

WARMUP_ROUNDS = 50
MEASURED_ROUNDS = 400
# Unfixed, a round leaked ~35 KiB: three helper Process objects and their empty-stderr read buffers.
MAX_GROWTH_KIB = 1024


def heap_kib(pid):
    """Resident plus swapped KiB of the main malloc arena, where the control handlers allocate."""
    total, in_heap = 0, False
    with open(f"/proc/{pid}/smaps", encoding="utf-8") as smaps:
        for line in smaps:
            if re.match(r"[0-9a-f]+-[0-9a-f]+ ", line):
                in_heap = line.rstrip().endswith("[heap]")
            elif in_heap and line.startswith(("Rss:", "Swap:")):
                total += int(line.split()[1])
    return total


def verify_live_control_memory(env, state):
    fixture = os.path.join(state, "login-shell.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-o", fixture,
                    os.path.join(ROOT, "tests/login_shell_zsh_fixture.c"), "-ldl"], check=True)
    with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as file:
        json.dump({"restoreMode": "live", "closeGraceUndoEnabled": False}, file)
    live_env = dict(env, LD_PRELOAD=fixture,
                    AGTERM_ZMX_PATH=env.get("AGTERM_TEST_ZMX_PATH", os.path.join(ROOT, "vendor/zmx/zmx")))
    process, _ = launch(live_env)
    inventory = None
    try:
        def request(cmd, target=None, args=None):
            reply = raw_control_json(live_env, {"cmd": cmd, "target": target, "args": args or {}})
            assert reply["ok"], (cmd, reply)
            return reply.get("result", {})

        identity = request("session.new", args={"name": "Polled"})["id"]

        def surface():
            return next((session["surfaces"][0] for workspace in request("tree")["tree"]["workspaces"]
                         for session in workspace["sessions"] if session["id"] == identity), {})

        # A led pane is read from its daemon (`zmx screen`), the path every poller takes.
        wait_for(lambda: surface().get("backedByZmx") and surface().get("lead") == "leader",
                 "the Live pane never reported its lead")

        def poll_round():
            request("tree")
            request("session.text", identity, {"lines": 20})
            request("surface.cursor", f"surface:{identity}:left")

        for _ in range(WARMUP_ROUNDS):
            poll_round()
        before = heap_kib(process.pid)
        for _ in range(MEASURED_ROUNDS):
            poll_round()
        grown = heap_kib(process.pid) - before
        assert grown < MAX_GROWTH_KIB, (
            f"heap grew {grown} KiB over {MEASURED_ROUNDS} tree/text/cursor rounds (limit {MAX_GROWTH_KIB})")
        inventory = request("zmx.list")["zmx"]
        print(f"OK: {MEASURED_ROUNDS} Live tree/text/cursor polling rounds grew the heap {grown} KiB")
    finally:
        with contextlib.suppress(AssertionError, OSError):
            inventory = inventory or request("zmx.list")["zmx"]
        stop(process)
        if inventory and (endpoint := inventory.get("endpoint")):
            cleanup_env = dict(live_env, ZMX_DIR=endpoint["socketDirectory"])
            cleanup_env.pop("ZMX_SESSION", None)
            for entry in inventory["entries"]:
                subprocess.run([endpoint["executable"], "kill", entry["daemon"], "--force"],
                               env=cleanup_env, capture_output=True, timeout=5)
