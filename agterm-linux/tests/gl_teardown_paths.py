"""Drive every surface teardown path over the control socket. No AT-SPI, so the headless runner can share it."""

import base64
import json
import os
import socket
import struct
import threading
import time
import zlib

import gl_teardown_analyze

WAIT_SECONDS = 20
READ_LIMIT_SECONDS = 1.0
BACKGROUND_SIZE = (37, 23)
IMAGE_SIZE = (29, 31)
SETTINGS = {"restoreMode": "live", "closeGraceUndoEnabled": False}
PASSTHROUGH_SHADER = """void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);
}
"""


def png_bytes(width, height):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    row = b"\x00" + b"\xc0\x40\x80" * width
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b"")


def kitty_image(width, height):
    payload = base64.b64encode(png_bytes(width, height))
    return b"\x1b_Gf=100,a=T,t=d;" + payload + b"\x1b\\"


def write_app_config(state):
    """Settings and ghostty.conf the scenario needs before launch."""
    with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as file:
        json.dump(SETTINGS, file)
    shader = os.path.join(state, "passthrough.glsl")
    with open(shader, "w", encoding="utf-8") as file:
        file.write(PASSTHROUGH_SHADER)
    config = os.path.join(state, "config")
    os.makedirs(config, exist_ok=True)
    with open(os.path.join(config, "ghostty.conf"), "w", encoding="utf-8") as file:
        file.write(f"custom-shader = {shader}\ncustom-shader-animation = false\n")


def require_clean_exit(process):
    """The GLib SIGTERM handler quits cleanly, so anything but 0 is a failure. A trace cannot show it: its END proves only
    that the shim's destructor ran, which `exit(nonzero)` does too, and a later library finalizer can still abort."""
    print(f"app exit status {process.returncode}")
    assert process.returncode == 0, f"the app exited {process.returncode}"


def judge_run(process, analyzer_arguments):
    """Both verdicts print first, so a failing exit never hides what the trace said."""
    status = gl_teardown_analyze.main(analyzer_arguments)
    require_clean_exit(process)
    assert status == 0, f"gl_teardown_analyze exited {status} on {analyzer_arguments[0]}"


class ControlError(AssertionError):
    pass


def call(socket_path, cmd, target=None, timeout=10, **args):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    try:
        client.connect(socket_path)
        client.sendall(json.dumps({"cmd": cmd, "target": target, "args": args}).encode("utf-8") + b"\n")
        response = b""
        while b"\n" not in response:
            data = client.recv(64 * 1024)
            if not data:
                raise ControlError(f"{cmd}: the control socket closed")
            response += data
    finally:
        client.close()
    reply = json.loads(response.split(b"\n", 1)[0])
    if not reply.get("ok"):
        raise ControlError(f"{cmd}: {reply}")
    return reply.get("result") or {}


class ControlProbe:
    """Times control reads on a thread. `finish` raises whatever stopped them, so a dead reader cannot read as a fast one."""

    def __init__(self, read):
        self.read = read
        self.worst = 0.0
        self.completed = 0
        self.error = None
        self.done = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        try:
            while not self.done.is_set():
                started = time.monotonic()
                self.read()
                self.worst = max(self.worst, time.monotonic() - started)
                self.completed += 1
                time.sleep(0.02)
        except Exception as error:
            self.error = error

    def start(self):
        self.thread.start()

    def finish(self):
        self.done.set()
        self.thread.join(WAIT_SECONDS)
        if self.thread.is_alive():
            raise AssertionError(f"a control read was still running {WAIT_SECONDS} s after the close")
        if self.error is not None:
            raise AssertionError(f"a control read failed around the busy close: {self.error!r}") from self.error
        if not self.completed:
            raise AssertionError("no control read completed around the busy close")
        return self.worst


class Log:
    """Incremental reader of the shim's log, so waits are bounded on what actually happened."""

    def __init__(self, path):
        self.path = path
        self.offset = 0
        self.pending = b""
        self.counts = {"NEW_END": 0, "FREE_END": 0, "DRAW_END": 0}
        self.uploads = set()
        self.fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)

    def write(self, line):
        os.write(self.fd, (line + "\n").encode())

    def refresh(self):
        with open(self.path, "rb") as file:
            file.seek(self.offset)
            data = file.read()
        self.offset += len(data)
        lines = (self.pending + data).split(b"\n")
        self.pending = lines.pop()
        for raw in lines:
            line = raw.decode("utf-8", "replace")
            kind = line.split(" ", 1)[0]
            if kind == "NEW_END" and "surface=0 " in line:
                continue
            if kind in self.counts:
                self.counts[kind] += 1
            elif kind == "TEX_IMAGE" and "caller=libghostty" in line:
                fields = dict(token.split("=", 1) for token in line.split()[1:])
                self.uploads.add((int(fields["width"]), int(fields["height"])))

    def wait(self, predicate, message):
        deadline = time.monotonic() + WAIT_SECONDS
        while time.monotonic() < deadline:
            self.refresh()
            if predicate():
                return
            time.sleep(0.05)
        raise AssertionError(f"timed out: {message}")

    def wait_count(self, kind, above, message):
        self.wait(lambda: self.counts[kind] > above, message)


class Paths:
    def __init__(self, socket_path, log_path, work_directory):
        self.socket = socket_path
        self.log = Log(log_path)
        self.work = work_directory

    def request(self, cmd, target=None, **args):
        return call(self.socket, cmd, target, **args)

    def first_session(self):
        tree = self.request("tree")["tree"]
        return next(row["id"] for workspace in tree["workspaces"] for row in workspace["sessions"] if row["active"])

    def new_surface(self, action, message):
        self.log.refresh()
        before = self.log.counts["NEW_END"]
        action()
        self.log.wait_count("NEW_END", before, message)

    def new_session(self, name):
        created = {}

        def create():
            created["id"] = self.request("session.new", name=name)["id"]

        self.new_surface(create, f"{name} never created a surface")
        return created["id"]

    def closing(self, path, action):
        self.log.refresh()
        before = self.log.counts["FREE_END"]
        self.log.write(f"MARK {path} begin")
        action()
        self.log.wait_count("FREE_END", before, f"{path} never freed a surface")
        self.log.write(f"MARK {path} end")

    def session_selected(self):
        session = self.new_session("gl-selected")
        self.log.refresh()
        draws = self.log.counts["DRAW_END"]
        self.request("session.type", session, text="yes\r")
        self.log.wait_count("DRAW_END", draws + 5, "yes never reached the renderer")
        probe = ControlProbe(lambda: self.request("window.list"))
        probe.start()
        try:
            self.closing("session-selected", lambda: self.request("session.close", session))
        finally:
            worst = probe.finish()
        assert worst < READ_LIMIT_SECONDS, f"a control read took {worst:.3f} s around the busy close"
        print(f"OK: worst control read around the busy close {worst * 1000:.0f} ms ({probe.completed} reads)")

    def session_background(self, main):
        session = self.new_session("gl-background")
        self.seed_background(session)
        self.seed_image(session)
        self.request("session.select", main)
        self.closing("session-background", lambda: self.request("session.close", session))

    def seed_background(self, session):
        path = os.path.join(self.work, "gl-teardown-background.png")
        with open(path, "wb") as file:
            file.write(png_bytes(*BACKGROUND_SIZE))
        self.log.write("SEED background session-background {} {}".format(*BACKGROUND_SIZE))
        self.request("session.background", session, mode="image", path=path)
        self.log.wait(lambda: BACKGROUND_SIZE in self.log.uploads, "the background image never reached a draw")

    def seed_image(self, session):
        path = os.path.join(self.work, "gl-teardown-image.kitty")
        with open(path, "wb") as file:
            file.write(kitty_image(*IMAGE_SIZE))
        self.log.write("SEED image session-background {} {}".format(*IMAGE_SIZE))
        self.request("session.type", session, text=f"cat {path}\r")
        self.log.wait(lambda: IMAGE_SIZE in self.log.uploads, "the Kitty image never reached a draw")

    def split(self, main):
        self.new_surface(lambda: self.request("session.split", main, mode="on", axis="vertical"), "split never started")
        self.closing("split", lambda: self.request("session.split.close", main))

    def scratch(self, main):
        self.new_surface(lambda: self.request("session.scratch", main, mode="on"), "scratch never started")
        self.closing("scratch", lambda: self.request("session.type", main, text="exit\r", pane="scratch"))

    def overlay(self, main):
        self.new_surface(lambda: self.request("session.overlay.open", main, command="exec sleep 600"),
                         "overlay never started")
        self.closing("overlay", lambda: self.request("session.overlay.close", main))

    def hud(self, main):
        self.new_surface(lambda: self.request("session.hud.open", main, message="gl teardown", sticky=True),
                         "hud never started")
        self.closing("hud", lambda: self.request("session.hud.close", main))

    def quick_exit(self):
        self.new_surface(lambda: self.request("quick", mode="show"), "quick never started")
        self.closing("quick-exit", lambda: self.request("quick.type", text="exit\r"))

    def restart(self, main):
        tree = self.request("tree")["tree"]
        row = next(row for workspace in tree["workspaces"] for row in workspace["sessions"] if row["id"] == main)
        pane = next(pane["paneID"] for pane in row["surfaces"] if pane["kind"] == "left")
        self.closing("restart", lambda: self.request("session.restart", main, paneID=pane, command="exec sleep 600"))

    def window(self):
        created = {}

        def create():
            created["id"] = self.request("window.new", name="gl teardown")["id"]

        self.new_surface(create, "the second window never created a surface")
        self.closing("window", lambda: self.request("window.close", created["id"]))

    def run_all(self):
        self.log.wait_count("DRAW_END", 0, "the first surface never drew")
        main = self.first_session()
        self.session_selected()
        self.session_background(main)
        self.split(main)
        self.scratch(main)
        self.overlay(main)
        self.hud(main)
        self.quick_exit()
        self.restart(main)
        self.window()
        self.request("window.list")
