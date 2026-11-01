"""Every surface teardown path under gl_teardown_shim.c, judged by gl_teardown_analyze.py."""

import base64
import errno
import json
import os
import shlex
import shutil
import subprocess

import gl_teardown_analyze
from atspi_clipboard_osc52 import Gdk, Gtk, clipboard_text
from atspi_smoke import APP_STDERR_ATTACHED, ROOT, launch, stop, wait_for
from gl_teardown_paths import Paths, call, judge_run, require_clean_exit, write_app_config

CLIPBOARD_TOKEN = "gl-quarantine-clipboard-before"
LEAKED_TOKEN = "gl-quarantine-clipboard-after"


def build_preload(state):
    shim = os.path.join(state, "gl-teardown-shim.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-o", shim, os.path.join(ROOT, "tests/gl_teardown_shim.c"), "-ldl"],
                   check=True)
    fixture = os.path.join(state, "restart-login-shell.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-o", fixture, os.path.join(ROOT, "tests/login_shell_zsh_fixture.c"), "-ldl"],
                   check=True)
    return f"{shim}:{fixture}"


def artifact_path(name):
    directory = os.environ.get("AGTERM_UI_ARTIFACT_DIR", ROOT)
    os.makedirs(directory, exist_ok=True)
    return os.path.join(directory, name)


def stderr_offset():
    path = os.environ.get("AGTERM_UI_APP_STDERR")
    return os.path.getsize(path) if path and os.path.exists(path) else 0


def stderr_slice(offset, name):
    """The shared stderr log holds every scenario of a suite run; judge only this one's.

    The sink's marker proves the capture ran: an uncaptured stderr is empty, which reads as no degraded line.
    """
    source = os.environ.get("AGTERM_UI_APP_STDERR")
    assert source and os.path.exists(source), "AGTERM_UI_APP_STDERR names no capture, so stderr cannot be judged"
    slice_path = artifact_path(name)
    with open(slice_path, "wb") as output, open(source, "rb") as file:
        file.seek(offset)
        shutil.copyfileobj(file, output)
    with open(slice_path, encoding="utf-8", errors="replace") as file:
        assert APP_STDERR_ATTACHED in file.read(), f"{source} holds no capture of this launch"
    return slice_path


def verify_gl_teardown(env, state, scenario, require_api=None):
    if require_api == "glx":
        if (Gtk.get_major_version(), Gtk.get_minor_version()) >= (4, 16):
            print(f"SKIP: {scenario}: GDK_DEBUG=gl-glx needs GTK below 4.16; this is not GLX evidence")
            return
        env = dict(env, GDK_DEBUG="gl-glx")
    log_path = artifact_path(f"{scenario}.log")
    if os.path.exists(log_path):
        os.remove(log_path)
    write_app_config(state)
    env = dict(env, LD_PRELOAD=build_preload(state), GL_TEARDOWN_LOG=log_path)
    offset = stderr_offset()
    process, _app = launch(env)
    try:
        wait_for(lambda: os.path.exists(env["AGTERM_CONTROL_SOCKET"]), "control socket never appeared")
        Paths(env["AGTERM_CONTROL_SOCKET"], log_path, state).run_all()
    finally:
        stop(process)
    arguments = [log_path, "--app-stderr", stderr_slice(offset, f"{scenario}-stderr.log")]
    if os.environ.get("AGTERM_GL_TEARDOWN_MODE") == "baseline":
        arguments.append("--baseline")
    if require_api:
        arguments += ["--require-api", require_api]
    judge_run(process, arguments)
    print(f"OK: {scenario}: analyzer clean on {log_path}")


def write_quarantine_child(state):
    """Blocks until the harness says the widget is gone, then speaks every protocol a dead widget must not hear."""
    ready, fifo, marker = (os.path.join(state, name) for name in ("child-ready", "child-fifo", "child-done"))
    os.mkfifo(fifo)
    encoded = base64.b64encode(LEAKED_TOKEN.encode()).decode()
    script = os.path.join(state, "quarantine-child.sh")
    with open(script, "w", encoding="utf-8") as file:
        file.write(f"""#!/bin/sh
: > {ready}
read _ < {fifo}
printf '\\033]22;crosshair\\007'
printf '\\033]2;quarantine-title\\007'
printf '\\033]52;c;{encoded}\\007'
printf '\\033]9;quarantine-notification\\007'
touch {marker}
""")
    return script, ready, fifo, marker


def release_child(fifo):
    def opened():
        try:
            os.close(os.open(fifo, os.O_WRONLY | os.O_NONBLOCK))
            return True
        except OSError as error:
            if error.errno != errno.ENXIO:
                raise
            return False

    wait_for(opened, "the quarantined child stopped reading its FIFO")


def retained_gl_lines(offset):
    with open(os.environ["AGTERM_UI_APP_STDERR"], "rb") as file:
        file.seek(offset)
        lines = file.read().decode("utf-8", "replace").splitlines()
    return [line for line in lines if gl_teardown_analyze.PREFIX in line]


def require_no_dead_widget_touched(offset, name):
    with open(stderr_slice(offset, name), encoding="utf-8", errors="replace") as file:
        assert "assertion 'GTK_IS_WIDGET" not in file.read(), "a dead widget was touched"


def verify_gl_teardown_quarantine(env, state):
    """The engine of a skipped free keeps running; everything it says afterwards must die at the registry."""
    os.makedirs(os.path.join(state, "config"))
    with open(os.path.join(state, "config", "ghostty.conf"), "w", encoding="utf-8") as config:
        config.write("clipboard-write = allow\ndesktop-notifications = true\n")
    script, ready, fifo, marker = write_quarantine_child(state)
    env = dict(env, AGTERM_ATSPI_SURFACE_FAILURE="gl-skip-free:overlay")
    socket_path = env["AGTERM_CONTROL_SOCKET"]
    offset = stderr_offset()

    def log_has(text):
        return any(text in line for line in retained_gl_lines(offset))

    process, _app = launch(env)
    try:
        wait_for(lambda: os.path.exists(socket_path), "control socket never appeared")
        Gtk.init()
        clipboard = Gdk.Display.get_default().get_clipboard()
        encoded = base64.b64encode(CLIPBOARD_TOKEN.encode()).decode()
        call(socket_path, "session.type", text=f"printf '\\033]52;c;{encoded}\\007'\r")
        wait_for(lambda: clipboard_text(clipboard) == CLIPBOARD_TOKEN, "a live pane's OSC 52 never reached the clipboard")

        call(socket_path, "session.overlay.open", command=f"sh {script}")
        wait_for(lambda: os.path.exists(ready), "the overlay child never started")
        call(socket_path, "session.overlay.close")
        wait_for(lambda: log_has("quarantined widget destroyed"), "the quarantined widget was never destroyed")

        release_child(fifo)
        wait_for(lambda: os.path.exists(marker), "the quarantined engine's child never finished")
        for kind in ("MOUSE_SHAPE", "SET_TITLE", "DESKTOP_NOTIFICATION", "clipboard write", "close"):
            wait_for(lambda kind=kind: log_has(f"dropped {kind}"), f"no dropped line for {kind}")

        assert clipboard_text(clipboard) == CLIPBOARD_TOKEN, "a quarantined engine wrote the clipboard"
        assert call(socket_path, "window.list")["windows"], "control stopped answering"
    finally:
        stop(process)
    require_clean_exit(process)
    require_no_dead_widget_touched(offset, "gl-teardown-quarantine-stderr.log")
    print("OK: gl-teardown-quarantine: every late callback dropped, clipboard unchanged, control answering")


def verify_gl_teardown_quarantine_close(env, state):
    """A surface with no `command` closes through close_surface_cb, after SHOW_CHILD_EXITED's own `close` drop."""
    with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as file:
        json.dump({"restoreMode": "none", "closeGraceUndoEnabled": False}, file)
    script, ready, fifo, marker = write_quarantine_child(state)
    env = dict(env, AGTERM_ATSPI_SURFACE_FAILURE="gl-skip-free:split")
    socket_path = env["AGTERM_CONTROL_SOCKET"]
    offset = stderr_offset()

    def logged(entry):
        return f"{gl_teardown_analyze.PREFIX} {entry}" in retained_gl_lines(offset)

    def session_rows():
        tree = call(socket_path, "tree")["tree"]
        return [row for workspace in tree["workspaces"] for row in workspace["sessions"]]

    def primary_shell_pid(session, name):
        path = os.path.join(state, name)
        call(socket_path, "session.type", session, text=f"echo $$ > {shlex.quote(path)}\r", pane="primary")
        wait_for(lambda: os.path.exists(path) and os.path.getsize(path) > 0, f"the primary shell never wrote {name}")
        with open(path, encoding="utf-8") as file:
            return file.read()

    process, _app = launch(env)
    try:
        wait_for(lambda: os.path.exists(socket_path), "control socket never appeared")
        session = next(row["id"] for row in session_rows() if row["active"])
        primary_pid = primary_shell_pid(session, "primary-before")

        call(socket_path, "session.split", session, mode="on", axis="vertical")
        call(socket_path, "session.type", session, text=f"exec sh {shlex.quote(script)}\r", pane="split")
        wait_for(lambda: os.path.exists(ready), "the split's child never started")
        call(socket_path, "session.split.close", session)
        wait_for(lambda: logged("quarantined widget destroyed"), "the quarantined widget was never destroyed")
        assert not logged("dropped close_surface"), "the split closed before its child was released"

        release_child(fifo)
        wait_for(lambda: os.path.exists(marker), "the quarantined engine's child never finished")
        wait_for(lambda: logged("dropped close"), "the child's exit never reached the engine")
        wait_for(lambda: logged("dropped close_surface"), "close_surface_cb never reached its quarantine check")

        row = next(row for row in session_rows() if row["id"] == session)
        assert not row.get("hasSplit"), f"the closed split is still in the tree: {row}"
        assert primary_shell_pid(session, "primary-after") == primary_pid, "the primary pane's shell changed"
        assert call(socket_path, "window.list")["windows"], "control stopped answering"
    finally:
        stop(process)
    require_clean_exit(process)
    require_no_dead_widget_touched(offset, "gl-teardown-quarantine-close-stderr.log")
    print("OK: gl-teardown-quarantine-close: close_surface_cb dropped, primary pane intact, control answering")
