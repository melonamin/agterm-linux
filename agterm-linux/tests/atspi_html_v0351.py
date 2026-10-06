"""Exercise the v0.35 HTML bridge and browser store through real WebKit views."""

import json
import os
import subprocess
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from atspi_smoke import activate, collect, focus_window, launch, raw_control_json, stop, wait_for, window_list, window_tree


def verify_html_v0351(env, state):
    pages = os.path.join(state, "bridge-pages")
    os.makedirs(pages, exist_ok=True)
    path = os.path.join(pages, "bridge.html")
    with open(path, "w", encoding="utf-8") as file:
        file.write('<!doctype html><title>Trusted DOM</title>'
                   '<script>document.title="unexpected page JS"</script>'
                   '<button type="button" data-agterm="session.rename" data-agterm-args=\'{"name":"DOM renamed"}\'>Rename from DOM</button>'
                   '<button type="button" data-agterm="session.overlay.submit" data-agterm-args=\'{"value":"chosen"}\'>Submit from DOM</button>')
    script_path = os.path.join(pages, "helper.html")
    with open(script_path, "w", encoding="utf-8") as file:
        file.write('<!doctype html><title>Helper pending</title><script>'
                   'agterm.request("session.rename",{args:{name:"JS renamed"}})'
                   '.then(()=>document.title="Helper ran")'
                   '.catch(e=>document.title="Helper error:"+e.message);</script>')
    storage_path = os.path.join(pages, "storage.html")
    with open(storage_path, "w", encoding="utf-8") as file:
        file.write('<!doctype html><title>Storage pending</title><script>'
                   'document.title="storage:"+localStorage.getItem("agterm-test")+":"+'
                   '(typeof agterm==="undefined"?"no-bridge":"unexpected-bridge");'
                   'localStorage.setItem("agterm-test","saved");</script>')

    process, app = launch(env)
    try:
        window = next(row["id"] for row in window_list(env) if row["open"])
        session = window_tree(env, window)["workspaces"][0]["sessions"][0]["id"]

        def request(cmd, args=None, target=session):
            reply = raw_control_json(env, {"cmd": cmd, "target": target, "args": dict(args or {}, window=window)})
            assert reply["ok"], reply
            return reply.get("result", {})

        def node():
            return next(row for workspace in window_tree(env, window)["workspaces"]
                        for row in workspace["sessions"] if row["id"] == session)

        def page():
            return next(iter(node().get("htmlOverlays", [])), None)

        def loaded(title):
            wait_for(lambda: page() and page().get("state") == "loaded" and page().get("title") == title,
                     f"page did not reach {title}: {page()}", timeout=20)

        opened = request("session.overlay.open", {"html": path, "cwd": pages, "chromeless": True})
        page_id = opened["pageID"]
        loaded("Trusted DOM")
        assert page()["chromeless"] is True, page()
        wait_for(lambda: collect(app, role="push button", name="Rename from DOM"), "DOM button missing")
        activate(collect(app, role="push button", name="Rename from DOM")[0])
        wait_for(lambda: node().get("name") == "DOM renamed", "DOM bridge did not route the default session target")
        zoom = page().get("zoom", 1)
        request("font.inc")
        assert page()["zoom"] > zoom
        request("font.reset")
        config = os.path.join(state, "config", "keymap.conf")
        with open(config, "a", encoding="utf-8") as file:
            file.write("\nmap ctrl+y increase_font_size\n")
        request("keymap.reload")
        focus_window(process.pid)
        subprocess.run(["xdotool", "key", "ctrl+y"], check=True)
        wait_for(lambda: page()["zoom"] > zoom, "rebound font shortcut changed the hidden terminal instead of the page")
        request("font.reset")
        activate(collect(app, role="push button", name="Submit from DOM")[0])
        wait_for(lambda: page() is None, "submitted page stayed open")
        outcome = raw_control_json(env, {"cmd": "session.overlay.result", "args": {"page": page_id}})
        assert outcome["ok"] and outcome["result"]["pageOutcome"]["value"] == "chosen", outcome

        request("session.overlay.open", {"html": script_path, "cwd": pages, "javascript": True})
        loaded("Helper ran")
        assert node().get("name") == "JS renamed", node()
        request("session.overlay.close")

        class Quiet(SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Quiet, directory=pages))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            address = f"http://127.0.0.1:{server.server_port}/storage.html"
            for persistent, expected in [(True, "null"), (True, "saved"), (False, "null")]:
                request("session.overlay.open", {"url": address, "persistent": persistent, "javascript": True})
                loaded(f"storage:{expected}:no-bridge")
                if persistent:
                    refused = raw_control_json(env, {"cmd": "browser.clear"})
                    assert not refused["ok"] and "still open" in refused["error"], refused
                request("session.overlay.close")
            cleared = raw_control_json(env, {"cmd": "browser.clear"})
            assert cleared["ok"], cleared
            request("session.overlay.open", {"url": address, "persistent": True, "javascript": True})
            loaded("storage:null:no-bridge")
            request("session.overlay.close")
            assert os.path.isdir(os.path.join(state, "browser")), "browser storage escaped the isolated state directory"
            other_state = os.path.join(state, "other-instance")
            os.makedirs(other_state)
            other_env = dict(env, AGTERM_STATE_DIR=other_state,
                             AGTERM_CONTROL_SOCKET=os.path.join(other_state, "agterm.sock"),
                             AGTERM_APP_ID=env["AGTERM_APP_ID"] + ".browser_other")
            other_process, _other_app = launch(other_env)
            try:
                other_window = next(row["id"] for row in window_list(other_env) if row["open"])
                other_session = window_tree(other_env, other_window)["workspaces"][0]["sessions"][0]["id"]
                opened = raw_control_json(other_env, {"cmd": "session.overlay.open", "target": other_session,
                                                     "args": {"url": address, "persistent": True, "javascript": True}})
                assert opened["ok"], opened

                def other_page():
                    row = window_tree(other_env, other_window)["workspaces"][0]["sessions"][0]
                    return next(iter(row.get("htmlOverlays", [])), {})

                wait_for(lambda: other_page().get("title") == "storage:null:no-bridge",
                         "separate agterm instance reused the first instance's browser data", timeout=20)
            finally:
                stop(other_process)

            background = request("session.new", {"name": "background browser"})["id"]
            request("session.select")
            request("session.overlay.open", {"url": address, "persistent": True}, target=background)
            refused = raw_control_json(env, {"cmd": "browser.clear"})
            assert not refused["ok"] and "still open" in refused["error"], refused
            request("session.overlay.close", target=background)
        finally:
            server.shutdown()
            server.server_close()
        print("OK: trusted DOM and JS bridges, page submit/outcome, zoom, persistent/ephemeral isolation, and browser.clear")
    finally:
        stop(process)
