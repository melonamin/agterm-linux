"""Resource writes and libghostty's locale initialization precede GTK worker startup."""

import os
import subprocess

from atspi_smoke import ROOT, launch, raw_control_json, stop, wait_for


def verify_startup_environment(env, state):
    fixture = os.path.join(state, "startup-environment.so")
    trace = os.path.join(state, "startup-environment.log")
    subprocess.run(["cc", "-shared", "-fPIC", "-o", fixture,
                    os.path.join(ROOT, "tests/startup_environment_fixture.c"), "-ldl"], check=True)
    audit_env = dict(env, LD_PRELOAD=fixture, AGTERM_STARTUP_AUDIT_LOG=trace)
    process, _ = launch(audit_env)
    try:
        wait_for(lambda: raw_control_json(audit_env, {"cmd": "tree"})["ok"], "startup did not reach the control server")
        with open(trace, encoding="utf-8") as file:
            events = file.read().splitlines()
        assert events == ["resources", "ghostty", "gtk"], "late or repeated runtime initialization: " + repr(events)
        print("OK: resource environment and libghostty locale initialization precede GTK startup")
    finally:
        stop(process)
