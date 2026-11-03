"""Duplicated programs must address their own session and pane, including argv overrides."""

import json
import os
import shlex

from atspi_smoke import (launch, open_palette, palette_row_labels, press_return,
                         raw_control_json, stop, wait_for, window_list, window_tree)


def verify_companion_identity(env):
    state = env["AGTERM_STATE_DIR"]
    probe = os.path.join(state, "identity-probe.py")
    with open(probe, "w", encoding="utf-8") as file:
        file.write("import json,os,sys,time\n"
                   "session=os.environ['AGTERM_SESSION_ID']\n"
                   "data=dict(session=session,pane=os.environ['AGTERM_PANE_ID'],"
                   "sessionArgument=sys.argv[1],paneArgument=sys.argv[2])\n"
                   "with open(os.path.join(os.path.dirname(__file__),session+'.json'),'w') as f: json.dump(data,f)\n"
                   "while True: time.sleep(1)\n")
    process, app = launch(env)
    try:
        window = next(item["id"] for item in window_list(env) if item["open"])

        def request(cmd, target=None, args=None):
            response = raw_control_json(env, {"cmd": cmd, "target": target,
                                               "args": dict(args or {}, window=window)})
            assert response["ok"], response
            return response.get("result", {})

        def sessions():
            return [item for workspace in window_tree(env, window)["workspaces"]
                    for item in workspace["sessions"]]

        def check(identity):
            path = os.path.join(state, identity + ".json")

            def read():
                try:
                    with open(path, encoding="utf-8") as file:
                        return json.load(file)
                except (FileNotFoundError, json.JSONDecodeError):
                    return None

            data = wait_for(read, "duplicated program did not start")
            assert data["session"] == data["sessionArgument"] == identity, data
            assert data["pane"] == data["paneArgument"], data

        command = f'exec /usr/bin/python3 {shlex.quote(probe)} "$AGTERM_SESSION_ID" "$AGTERM_PANE_ID"'
        source = request("session.new", args={"name": "Identity source", "command": command, "cwd": state})["id"]
        check(source)
        copy = request("session.companion.duplicate", source, {"noSelect": True})["id"]
        check(copy)

        before = {item["id"] for item in sessions()}
        request("session.select", source)
        palette, search = open_palette(app, process.pid)
        assert search.get_editable_text_iface().set_text_contents("Duplicate as Companion")
        wait_for(lambda: palette_row_labels(palette) == [["Duplicate as Companion"]],
                 "duplicate companion palette action is missing")
        press_return(process.pid, window_title="Command Palette")
        gui_copy = wait_for(lambda: next((item["id"] for item in sessions() if item["id"] not in before), None),
                            "GUI companion was not created")
        assert next(item for item in sessions() if item["id"] == gui_copy)["parent"] == source
        check(gui_copy)
        request("session.close", source)
        print("OK: GUI and control companion duplication rebind live program session/pane argv overrides")
    except Exception:
        print("Companion identity evidence:", state, flush=True)
        print(json.dumps(window_tree(env, window)), flush=True)
        for path in sorted(os.listdir(state)):
            if path.endswith(".json"):
                with open(os.path.join(state, path), encoding="utf-8") as file:
                    print(path, file.read(), flush=True)
        raise
    finally:
        stop(process)
