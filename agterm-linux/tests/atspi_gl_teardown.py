"""Every surface teardown path under gl_teardown_shim.c, judged by gl_teardown_analyze.py."""

import os
import shutil
import subprocess

import gl_teardown_analyze
from atspi_smoke import ROOT, Gtk, launch, stop, wait_for
from gl_teardown_paths import Paths, write_app_config


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
    """The shared stderr log holds every scenario of a suite run; judge only this one's."""
    source = os.environ.get("AGTERM_UI_APP_STDERR")
    slice_path = artifact_path(name)
    with open(slice_path, "wb") as output:
        if source and os.path.exists(source):
            with open(source, "rb") as file:
                file.seek(offset)
                shutil.copyfileobj(file, output)
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
    status = gl_teardown_analyze.main(arguments)
    assert status == 0, f"gl_teardown_analyze exited {status} on {log_path}"
    print(f"OK: {scenario}: analyzer clean on {log_path}")
