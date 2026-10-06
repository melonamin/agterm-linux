"""Real WebKit page and control-socket coverage under the isolated GTK smoke runner."""

import os
import json
import subprocess
import threading
import time
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

import gi

gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, GObject, Gtk  # noqa: E402

from atspi_smoke import CTL, collect, control_json, launch, raw_control_json, stop, wait_for, window_list, window_tree


def verify_html_overlay(env, state):
    def cli(*args):
        command = subprocess.run([CTL, *args, "--socket", env["AGTERM_CONTROL_SOCKET"]],
                                 env=env, capture_output=True, text=True, timeout=10)
        assert command.returncode == 0, f"agtermctl failed: {command.stdout} {command.stderr}"
        return json.loads(command.stdout)

    pages = os.path.join(state, "pages")
    os.makedirs(pages)
    path = os.path.join(pages, "index.html")
    with open(path, "w", encoding="utf-8") as target:
        target.write("<!doctype html><title>Linux page overlay</title><h1>Rendered by WebKit</h1>")
    scripted = os.path.join(pages, "scripted.html")
    with open(scripted, "w", encoding="utf-8") as target:
        target.write('<!doctype html><title>Pending script</title><script src="inside.js"></script>'
                     '<script src="../outside.js"></script><script src="link.js"></script>')
    with open(os.path.join(pages, "inside.js"), "w", encoding="utf-8") as target:
        target.write('document.title = "Granted script loaded";')
    with open(os.path.join(state, "outside.js"), "w", encoding="utf-8") as target:
        target.write('document.title = "Unapproved script loaded";')
    os.symlink(os.path.join(state, "outside.js"), os.path.join(pages, "link.js"))

    process, app = launch(env)
    try:
        window = next(item["id"] for item in window_list(env) if item["open"])
        session = window_tree(env, window)["workspaces"][0]["sessions"][0]["id"]

        def page(pane=None):
            node = next(item for workspace in window_tree(env, window)["workspaces"]
                        for item in workspace["sessions"] if item["id"] == session)
            return next((item for item in node.get("htmlOverlays", []) if item.get("pane") == pane), None)

        opened = cli("session", "overlay", "open", "--html", path,
                              "--cwd", pages, "--navigation", "--target", session,
                              "--window", window, "--json")
        assert opened["ok"], opened
        wait_for(lambda: page() and page()["state"] == "loaded" and
                 page().get("title") == "Linux page overlay",
                 f"WebKit did not load the local page: {page()}", timeout=20)
        assert page()["page"] == path, page()
        assert control_json(env, "session", "overlay", "reload", "--target", session,
                            "--window", window, "--json")["ok"]
        wait_for(lambda: page() and page()["state"] == "loaded", "WebKit did not reload the page")

        for command, error in (("session.overlay.result", "no overlay result: the slot holds an html page"),
                               ("session.overlay.text", "no overlay to read: the slot holds an html page")):
            reply = raw_control_json(env, {"cmd": command, "target": session, "args": {"window": window}})
            assert not reply["ok"] and reply.get("error") == error, reply

        assert control_json(env, "session", "overlay", "close", "--target", session,
                            "--window", window, "--json")["ok"]
        wait_for(lambda: page() is None, "closed page remained in the control tree")

        opened = cli("session", "overlay", "open", "--html", path,
                              "--size-percent", "60", "--target", session,
                              "--window", window, "--json")
        assert opened["ok"], opened
        wait_for(lambda: page() and page()["state"] == "loaded", "floating page did not load")
        assert control_json(env, "session", "overlay", "close", "--target", session,
                            "--window", window, "--json")["ok"]

        assert control_json(env, "session", "split", "on", "--target", session,
                            "--window", window, "--json")["ok"]
        opened = cli("session", "overlay", "open", "--html", path,
                              "--cwd", pages, "--pane", "right", "--target", session,
                              "--window", window, "--json")
        assert opened["ok"], opened
        wait_for(lambda: page("right") and page("right")["state"] == "loaded",
                 f"pane page did not load: {page('right')}")
        wait_for(lambda: collect(app, role="document web"), "pane page was not visible")
        assert control_json(env, "surface", "zoom", "show",
                            "--target", f"surface:{session}:split", "--window", window, "--json")["ok"]
        wait_for(lambda: not collect(app, role="document web"),
                 "pane HTML page still covered the zoomed split terminal")
        assert control_json(env, "surface", "zoom", "hide",
                            "--target", f"surface:{session}:split", "--window", window, "--json")["ok"]
        wait_for(lambda: collect(app, role="document web"), "pane page did not return after zoom exit")
        assert control_json(env, "session", "overlay", "close", "--pane", "right",
                            "--target", session, "--window", window, "--json")["ok"]
        wait_for(lambda: page("right") is None, "closed pane page remained in the control tree")

        opened = cli("session", "overlay", "open", "--html", scripted,
                     "--cwd", pages, "--target", session, "--window", window, "--json")
        assert opened["ok"], opened
        wait_for(lambda: page() and page()["state"] == "loaded" and
                 page().get("title") == "Pending script",
                 f"JavaScript ran without --js: {page()}")
        assert control_json(env, "session", "overlay", "close", "--target", session,
                            "--window", window, "--json")["ok"]

        opened = cli("session", "overlay", "open", "--html", scripted,
                     "--js", "--target", session, "--window", window, "--json")
        assert opened["ok"], opened
        wait_for(lambda: page() and page()["state"] == "loaded" and
                 page().get("title") == "Pending script",
                 f"a file page without --cwd loaded a local asset: {page()}")
        assert control_json(env, "session", "overlay", "close", "--target", session,
                            "--window", window, "--json")["ok"]

        opened = cli("session", "overlay", "open", "--html", scripted,
                     "--cwd", pages, "--js", "--target", session,
                     "--window", window, "--json")
        assert opened["ok"], opened
        wait_for(lambda: page() and page()["state"] == "loaded" and
                 page().get("title") == "Granted script loaded",
                 f"WebKit did not load the granted script or loaded an outside file: {page()}")
        assert control_json(env, "session", "overlay", "close", "--target", session,
                            "--window", window, "--json")["ok"]

        class QuietHandler(SimpleHTTPRequestHandler):
            redirect_to = None

            def log_message(self, *_args):
                pass

            def do_GET(self):
                if self.path == "/redirect" and self.redirect_to:
                    self.send_response(302)
                    self.send_header("Location", self.redirect_to)
                    self.end_headers()
                else:
                    super().do_GET()

        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=pages))
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        other = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=pages))
        other_thread = threading.Thread(target=other.serve_forever, daemon=True)
        other_thread.start()
        QuietHandler.redirect_to = f"http://127.0.0.1:{other.server_port}/index.html"
        try:
            address = f"http://127.0.0.1:{server.server_port}/index.html"
            opened = cli("session", "overlay", "open", "--url", address,
                         "--target", session, "--window", window, "--json")
            assert opened["ok"], opened
            wait_for(lambda: page() and page()["state"] == "loaded" and
                     page().get("title") == "Linux page overlay",
                     f"WebKit did not load the local HTTP page: {page()}")
            assert page()["page"] == address, page()
            assert control_json(env, "session", "overlay", "close", "--target", session,
                                "--window", window, "--json")["ok"]
            opened = cli("session", "overlay", "open", "--url",
                         f"http://127.0.0.1:{server.server_port}/redirect",
                         "--target", session, "--window", window, "--json")
            assert opened["ok"], opened
            wait_for(lambda: page() and page()["state"] == "failed",
                     f"a redirect to another origin was not blocked: {page()}")
            assert "navigation blocked" in page().get("error", ""), page()
            assert control_json(env, "session", "overlay", "close", "--target", session,
                                "--window", window, "--json")["ok"]
        finally:
            server.shutdown()
            server.server_close()
            other.shutdown()
            other.server_close()

        paste_path = os.path.join(pages, "paste.html")
        with open(paste_path, "w", encoding="utf-8") as target:
            target.write('<!doctype html><title>Paste check</title>'
                         '<textarea style="width:100vw;height:100vh" '
                         'oninput="document.title=\'pasted:\'+this.value"></textarea>')
        opened = cli("session", "overlay", "open", "--html", paste_path, "--js",
                     "--target", session, "--window", window, "--json")
        assert opened["ok"], opened
        wait_for(lambda: page() and page()["state"] == "loaded" and page().get("title") == "Paste check",
                 "paste test page did not load")

        Gtk.init()
        clipboard = Gdk.Display.get_default().get_clipboard()

        def send_into_page(*keys):
            from atspi_smoke import collect, find_app, mouse_click

            mouse_click(lambda: next(iter(collect(find_app(process.pid), role="document web")), None),
                        process.pid, button="left")
            subprocess.run(["xdotool", *keys], check=True)

        def wait_clipboard(predicate):
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                while GLib.MainContext.default().pending():
                    GLib.MainContext.default().iteration(False)
                if predicate():
                    return
                time.sleep(0.05)
            assert predicate(), f"clipboard test did not reach expected page state: {page()}"

        plain = GObject.Value(GObject.TYPE_STRING)
        plain.set_string("plain")
        clipboard.set(plain)
        send_into_page("key", "--clearmodifiers", "ctrl+v")
        wait_clipboard(lambda: page() and page().get("title") == "pasted:plain")

        assert cli("session", "overlay", "reload", "--target", session,
                   "--window", window, "--json")["ok"]
        wait_for(lambda: page() and page().get("title") == "Paste check", "paste page did not reload")
        uri_provider = Gdk.ContentProvider.new_for_bytes("text/uri-list", GLib.Bytes.new(b"file:///tmp/x\r\n"))
        blocked = GObject.Value(GObject.TYPE_STRING)
        blocked.set_string("blocked")
        text_provider = Gdk.ContentProvider.new_for_value(blocked)
        clipboard.set_content(Gdk.ContentProvider.new_union([uri_provider, text_provider]))
        assert clipboard.get_formats().contain_mime_type("text/uri-list")
        time.sleep(1)
        send_into_page("key", "--clearmodifiers", "ctrl+v")
        for _ in range(30):
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            time.sleep(0.05)
        assert page().get("title") == "Paste check", f"URI-list clipboard reached the page: {page()}"
        assert cli("session", "overlay", "close", "--target", session,
                   "--window", window, "--json")["ok"]

        verify_page_answers(env, process, session, window, pages, page)

        print("OK: WebKit loaded full, floating, pane, and HTTP pages; JavaScript, file grants, and URI-list paste stayed scoped")
    finally:
        stop(process)


def verify_page_answers(env, process, session, window, pages, page):
    """A blocked open returns what its page submits, through agterm.request or a data-agterm tag, or exits 2."""
    from atspi_smoke import find_app, mouse_click

    def blocked_open(*args):
        return subprocess.Popen([CTL, "session", "overlay", "open", "--html", *args, "--block",
                                 "--target", session, "--window", window, "--socket", env["AGTERM_CONTROL_SOCKET"]],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def answer(command):
        try:
            stdout, stderr = command.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            command.kill()
            raise AssertionError(f"the blocked open never returned; page: {page()}")
        return command.returncode, json.loads(stdout) if stdout.strip() else stderr

    def session_name():
        return next(item["name"] for workspace in window_tree(env, window)["workspaces"]
                    for item in workspace["sessions"] if item["id"] == session)

    with open(os.path.join(pages, "bridge.html"), "w", encoding="utf-8") as target:
        target.write("""<!doctype html><title>Bridge</title><script>
            const frame = new Promise(resolve => window.addEventListener('message', event => resolve(event.data)));
            agterm.request('session.rename', {args: {name: 'bridged'}})
              .then(() => { document.title = 'renamed'; return frame; })
              .then(heard => agterm.request('session.overlay.submit', {args: {value: 'main|' + heard}}))
              .catch(error => { document.title = 'error:' + error.message; });
            </script><iframe src="frame.html"></iframe>""")
    with open(os.path.join(pages, "frame.html"), "w", encoding="utf-8") as target:
        target.write("""<!doctype html><script>
            const answer = text => parent.postMessage(text, '*');
            try {
              window.webkit.messageHandlers.agterm.postMessage({cmd: 'tree'})
                .then(() => answer('accepted'), error => answer(error.message));
            } catch (error) { answer('no handler'); }
            </script>""")
    original = session_name()
    command = blocked_open(os.path.join(pages, "bridge.html"), "--cwd", pages, "--js")
    code, outcome = answer(command)
    assert code == 0, (code, outcome, page())
    assert outcome["outcome"] == "submitted", outcome
    assert outcome["value"] == "main|requests from frames are refused", f"a frame reached the bridge: {outcome}"
    assert session_name() == "bridged", "agterm.request did not rename the page's own session"
    read = control_json(env, "session", "overlay", "result", "--page", outcome["pageID"], "--json")
    assert read["result"]["pageOutcome"] == outcome, read
    assert control_json(env, "session", "rename", original, "--target", session, "--window", window, "--json")["ok"]

    with open(os.path.join(pages, "selector.html"), "w", encoding="utf-8") as target:
        target.write("""<!doctype html><title>Selector</title><button type="button" data-agterm="session.overlay.submit"
            data-agterm-args='{"value":"clicked"}' style="position:fixed;inset:0;width:100%;height:100%">Pick</button>""")
    command = blocked_open(os.path.join(pages, "selector.html"))
    wait_for(lambda: page() and page()["state"] == "loaded", f"selector page did not load: {page()}", timeout=20)
    mouse_click(lambda: next(iter(collect(find_app(process.pid), role="document web")), None),
                process.pid, button="left")
    code, outcome = answer(command)
    assert code == 0 and outcome["outcome"] == "submitted" and outcome["value"] == "clicked", (code, outcome)

    command = blocked_open(os.path.join(pages, "index.html"))
    wait_for(lambda: page() and page().get("id"), f"blocked page did not open: {page()}")
    opened = page()["id"]
    assert control_json(env, "session", "overlay", "close", "--target", session,
                        "--window", window, "--json")["ok"]
    code, outcome = answer(command)
    assert code == 2 and outcome == {"pageID": opened, "outcome": "dismissed"}, (code, outcome)
    print("OK: pages answered --block through agterm.request and a data-agterm tag, a frame was refused, "
          "and a closed page read dismissed")
