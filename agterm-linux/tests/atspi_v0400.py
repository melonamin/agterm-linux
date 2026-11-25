"""Real GTK/socket coverage for v0.40.0 messages, sidebar info and generated file pages."""

import base64
import http.server
import os
import shlex
import subprocess
import threading
import time

from atspi_smoke import CTL, collect, launch, named, raw_control_json, stop, wait_for, window_list


def verify_v0400(env, state):
    process, app = launch(env)
    network_requests = []

    class NetworkProbe(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            network_requests.append(self.path)
            self.send_response(404)
            self.end_headers()

        def log_message(self, *_args):
            pass

    network = http.server.ThreadingHTTPServer(("127.0.0.1", 0), NetworkProbe)
    threading.Thread(target=network.serve_forever, daemon=True).start()

    def request(command, target=None, args=None):
        reply = raw_control_json(env, {"cmd": command, "target": target, "args": args or {}})
        assert reply["ok"], reply
        return reply.get("result", {})

    def row(identity):
        return next((row for workspace in request("tree", args={"window": window})["tree"]["workspaces"]
                     for row in workspace["sessions"] if row["id"] == identity), None)

    def pane(identity, role="left"):
        return next((surface for surface in row(identity).get("surfaces", [])
                     if surface["kind"] == role and surface.get("paneID") and row(identity).get("realized")), None)

    def address(identity, role="left"):
        return identity + ":" + wait_for(lambda: pane(identity, role), "pane not realized")["paneID"]

    def page(identity):
        return next(iter(row(identity).get("htmlOverlays", [])), {})

    try:
        window = next(item["id"] for item in window_list(env) if item["open"])
        parent = request("session.new", args={"name": "v0.40 sidebar parent"})["id"]
        sender = address(parent)
        request("session.split", parent, {"mode": "on"})
        reader = address(parent, "right")
        cursor = request("events.read")["events"]
        sent = request("msg.send", args={"body": "private message body", "identity": sender,
                                         "recipients": [parent + ":right", reader]})
        assert sent["delivered"] == [reader] and not sent.get("rejected"), sent
        assert pane(parent, "right")["pendingMessages"] == 1
        messages = request("msg.read", args={"identity": reader})["messages"]
        assert len(messages) == 1 and messages[0]["body"] == "private message body", messages
        assert request("msg.read", args={"identity": reader})["messages"] == messages
        events = request("events.read", args={"run": cursor["run"], "after": str(cursor["next"]),
                                               "kinds": ["message"], "limit": 100})["events"]["items"]
        assert len(events) == 1 and "private message body" not in str(events), events
        request("msg.ack", args={"identity": reader, "ids": [sent["messageID"]]})
        assert not pane(parent, "right").get("pendingMessages")
        request("session.type", parent, {"pane": "left", "text": shlex.quote(CTL)
                + " msg send 'from the pane environment' --to " + shlex.quote(reader)
                + ' --socket "$AGTERM_CONTROL_SOCKET"\r'})
        batch = wait_for(lambda: request("msg.read", args={"identity": reader}).get("messages"),
                         "shell CLI did not resolve its own pane identity")
        assert batch[0]["from"] == sender, batch
        request("msg.read", args={"identity": reader, "ack": True})
        timeout = subprocess.run([CTL, "msg", "read", "--as", reader, "--wait", "--timeout", "0.3",
                                  "--socket", env["AGTERM_CONTROL_SOCKET"]], env=env, capture_output=True, timeout=5)
        assert timeout.returncode == 124, (timeout.returncode, timeout.stderr)
        waiter = subprocess.Popen([CTL, "msg", "read", "--as", reader, "--wait", "--ack", "--json",
                                   "--socket", env["AGTERM_CONTROL_SOCKET"]], env=env, stdout=subprocess.PIPE)
        try:
            request("msg.send", args={"body": "wake the waiter", "recipients": [reader]})
            output, _ = waiter.communicate(timeout=5)
            assert waiter.returncode == 0 and b"wake the waiter" in output, output
        finally:
            if waiter.poll() is None:
                waiter.kill()
                waiter.wait()
        request("msg.send", args={"body": "discard with split", "recipients": [reader]})
        request("session.split", parent, {"mode": "off"})
        request("session.split", parent, {"mode": "on"})
        assert address(parent, "right") == reader
        assert pane(parent, "right")["pendingMessages"] == 1, "hiding a live split discarded mail"
        request("session.split.close", parent)
        request("session.split", parent, {"mode": "on"})
        assert address(parent, "right") != reader
        assert not pane(parent, "right").get("pendingMessages")
        request("session.scratch", parent, {"mode": "on"})
        scratch = address(parent, "scratch")
        request("msg.send", args={"body": "scratch mail", "recipients": [scratch]})
        assert request("msg.read", args={"identity": scratch, "ack": True})["messages"][0]["body"] == "scratch mail"
        request("msg.send", args={"body": "scratch lifetime", "recipients": [scratch]})
        request("session.scratch", parent, {"mode": "off"})
        assert request("msg.read", args={"identity": scratch})["messages"], "hiding scratch discarded its mail"
        request("session.scratch", parent, {"mode": "on"})
        request("session.type", parent, {"pane": "scratch", "text": "exit\r"})
        wait_for(lambda: not pane(parent, "scratch"), "scratch did not exit")
        request("session.scratch", parent, {"mode": "on"})
        assert address(parent, "scratch") != scratch
        assert not pane(parent, "scratch").get("pendingMessages"), "new scratch inherited old mail"
        request("session.scratch", parent, {"mode": "off"})
        second_window = request("window.new", args={"name": "Mailbox second window"})["id"]
        remote_row = request("tree", args={"window": second_window})["tree"]["workspaces"][0]["sessions"][0]
        remote_id = remote_row["id"]

        def other_pane():
            tree = request("tree", args={"window": second_window})["tree"]
            session = next(row for workspace in tree["workspaces"] for row in workspace["sessions"] if row["id"] == remote_id)
            return next((surface.get("paneID") for surface in session.get("surfaces", []) if surface["kind"] == "left"), None)

        cross_address = remote_id + ":" + wait_for(other_pane, "second window pane did not realize")
        request("msg.send", args={"body": "cross window", "identity": sender, "recipients": [cross_address]})
        assert request("msg.read", args={"identity": cross_address, "ack": True})["messages"][0]["body"] == "cross window"
        workspace = request("tree", args={"window": window})["tree"]["workspaces"][0]["id"]
        broadcast = request("msg.send", args={"body": "workspace only", "all": True, "workspace": workspace, "identity": sender})
        assert sender not in broadcast["delivered"] and cross_address not in broadcast["delivered"], broadcast
        request("window.close", second_window)
        child = request("session.companion.new", parent, {"name": "v0.40 companion"})["id"]
        request("session.select", child)
        child_address = address(child)
        request("msg.send", args={"body": "discard on soft close", "recipients": [child_address]})
        request("session.close", child, {"undoable": True})
        recent = request("recent.list")["recent"]
        closed = next(item for item in recent if child in item["sessionIDs"])
        request("recent.open", closed["id"])
        assert not wait_for(lambda: pane(child), "undo did not restore pane").get("pendingMessages")

        request("session.info", parent, {"mode": "set", "text": "**Build** <ready> `42`", "markdown": True})
        wait_for(lambda: named(app, "Build <ready> 42", role="label"), "safe Markdown info line not rendered")
        request("session.info", child, {"mode": "set", "text": "companion info"})
        request("session.select", parent)
        wait_for(lambda: named(app, "companion info", role="label"), "companion info missing")
        artifacts = os.environ.get("AGTERM_UI_ARTIFACT_DIR")
        if artifacts:
            from x11_capture import capture
            capture(os.path.join(artifacts, "v0400-sidebar.png"))
        request("session.info", parent, {"mode": "set", "text": "old deadline", "hideAfter": 0.3})
        request("session.info", parent, {"mode": "set", "text": "replacement survives", "hideAfter": 0})
        time.sleep(0.5)
        assert row(parent)["info"] == "replacement survives"
        request("session.info", parent, {"mode": "set", "text": "expires", "hideAfter": 0.2})
        wait_for(lambda: not row(parent).get("info"), "GLib info expiry did not fire")

        image = os.path.join(state, "picture.png")
        with open(image, "wb") as file:
            file.write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAADAQMAAACDJEzCAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURf8AAP///0EdNBEAAAABYktHRAH/Ai3eAAAAB3RJTUUH6gsCEw0u0coFdQAAAAtJREFUCNdjYAABAAAGAAFm9MlsAAAAAElFTkSuQmCC"))
        request("session.overlay.open", parent, {"image": image})
        wait_for(lambda: page(parent).get("state") == "loaded", "image page did not load")
        assert page(parent)["page"] == image, page(parent)
        request("session.overlay.close", parent)
        markdown = os.path.join(state, "guide.md")
        with open(markdown, "w", encoding="utf-8") as file:
            file.write('# Native Markdown\n\n**Bold** and *italic*, `inline code`.\n\n'
                       '```swift\nlet answer = 42\n```\n\n![Local picture](picture.png)\n\n'
                       '[Jump](#details)\n\n## Details\n\n'
                       '<script>document.title="AUTHORED SCRIPT RAN";agterm.request("session.close")</script>\n'
                       '<img src="https://example.invalid/forbidden.png">\n')
            file.write(f'\n![Network image denied](http://127.0.0.1:{network.server_port}/forbidden.png)\n')
        request("session.overlay.open", parent, {"markdownFile": markdown, "sizePercent": 80})
        wait_for(lambda: page(parent).get("state") == "loaded", "Markdown page did not load")
        wait_for(lambda: named(app, "Native Markdown"), "Markdown renderer did not populate WebKit accessibility")
        assert page(parent)["page"] == markdown and page(parent).get("title") != "AUTHORED SCRIPT RAN", page(parent)
        assert named(app, "Details") and named(app, "Local picture"), [node.get_name() for node in collect(app)]
        time.sleep(0.5)
        assert not network_requests, network_requests
        if artifacts:
            from x11_capture import capture
            capture(os.path.join(artifacts, "v0400-markdown.png"))
        request("session.overlay.reload", parent)
        request("session.overlay.close", parent)
        time.sleep(0.3)
        assert not row(parent).get("htmlOverlays"), "async reload resurrected a closed page"
        print("OK: v0.40 messages/read/ack/wait/events/disposal, sidebar info/deadlines, image and Markdown pages")
    finally:
        stop(process)
        network.shutdown()
        network.server_close()
