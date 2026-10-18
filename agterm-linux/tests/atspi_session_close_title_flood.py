"""The `session-close-title-flood` AT-SPI scenario: closing a session whose program floods OSC titles.

`session close` frees the surface on the main thread, and the free joins the surface's io thread, which joins
its reader. Titles go to libghostty's 64-slot app mailbox, which only the main thread drains, so a reader
waiting for room there never returns. Measured to deadlock this harness within three closes, 3 of 3 runs.
The program writes in bursts with short gaps: an unbroken flood keeps a debug build's main thread draining the
app mailbox forever, so the close request would never be dispatched at all.
"""

import os
import subprocess

from atspi_smoke import control_json, launch, stop, wait_for, window_list, window_tree

ROUNDS = 3
BOUND_SECONDS = 4
FLOOD = "while :; do for i in $(seq 100); do printf '\\033]0;flood-%d\\007' \"$i\"; done; sleep 0.05; done\n"


def verify_session_close_title_flood(env):
    state = env["AGTERM_STATE_DIR"]
    flood_path = os.path.join(state, "title-flood.sh")
    with open(flood_path, "w", encoding="utf-8") as target:
        target.write(FLOOD)

    process, _ = launch(env)
    try:
        window_id = next(item["id"] for item in window_list(env) if item["open"])

        def sessions():
            return [item for workspace in window_tree(env, window_id)["workspaces"]
                    for item in workspace["sessions"]]

        def bounded(what, *arguments):
            try:
                return control_json(env, *arguments, timeout=BOUND_SECONDS)
            except subprocess.TimeoutExpired as error:
                raise AssertionError(
                    f"{what} did not answer within {BOUND_SECONDS}s; the app main thread is wedged") from error

        for round_index in range(ROUNDS):
            name = f"flood-{round_index}"
            control_json(env, "session", "new", "--name", name, "--cwd", state,
                         "--command", f"bash {flood_path}", "--window", window_id, "--json")
            session_id = wait_for(
                lambda: next((item["id"] for item in sessions() if item["name"] == name), None),
                f"session {name!r} never appeared in the tree")

            def flooding():
                node = next((item for item in sessions() if item["id"] == session_id), None)
                return bool(node and node.get("realized") and (node.get("title") or "").startswith("flood-"))

            wait_for(flooding, f"session {name!r} never realized a surface showing the flood's title")
            bounded(f"hang step: `session close` of {name!r}", "session", "close", "--target", session_id,
                    "--window", window_id, "--json")
            bounded(f"hang step: `tree` after closing {name!r}", "tree", "--json")
            assert all(item["id"] != session_id for item in sessions()), f"{name!r} is still in the tree"
        print(f"OK: {ROUNDS} sessions flooding OSC titles closed without wedging the main thread")
    finally:
        stop(process)
