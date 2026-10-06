"""Drop actual pane attachments with SSH's failure status, then observe reattachment."""

import contextlib
import os
import signal

from atspi_smoke import wait_for


def verify_pane_reconnect(viewer_session, ssh, ssh_down, origin_state):
    panes = {row["kind"]: row["paneID"] for row in viewer_session()["surfaces"]
             if row["kind"] in ("left", "right")}
    marker = ("AGTERM_TEST_ORIGIN_STATE=" + origin_state).encode()
    with open(ssh_down, "w", encoding="utf-8"):
        pass
    dropped = 0
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as source:
                argv = source.read().split(b"\0")
            with open(f"/proc/{pid}/environ", "rb") as source:
                environment = source.read().split(b"\0")
        except OSError:
            continue
        if ssh.encode() in argv and any(b"'attach'" in argument for argument in argv) and marker in environment:
            with contextlib.suppress(ProcessLookupError):
                os.kill(int(pid), signal.SIGTERM)
                dropped += 1
    assert dropped == len(panes), f"dropped {dropped} pane attachments for {panes}"

    def waiting():
        rows = {row["kind"]: row for row in viewer_session()["surfaces"] if row["kind"] in panes}
        return len(rows) == len(panes) and all(
            row.get("reconnect", {}).get("failures", 0) > 0
            and "Connection refused" in row.get("reconnect", {}).get("reason", "") for row in rows.values())

    wait_for(waiting, "pane link loss did not publish failed-probe reason/count", timeout=25)
    assert {row["kind"]: row["paneID"] for row in viewer_session()["surfaces"]
            if row["kind"] in panes} == panes, "link loss changed pane identity"
    os.remove(ssh_down)

    def reattached():
        rows = {row["kind"]: row for row in viewer_session()["surfaces"] if row["kind"] in panes}
        return len(rows) == len(panes) and all(not row.get("reconnect") and row.get("lead") in ("leader", "follower")
                                              for row in rows.values())

    assert wait_for(reattached, "pane did not reconnect after its host recovered", timeout=30, required=False), viewer_session()
    assert {row["kind"]: row["paneID"] for row in viewer_session()["surfaces"]
            if row["kind"] in panes} == panes, "reattachment changed pane identity"
    print("OK: SSH-255 pane loss published retry reason/count and reattached with stable pane identities")
