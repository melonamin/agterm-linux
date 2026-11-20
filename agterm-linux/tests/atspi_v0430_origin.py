"""The native remote-window picker selects among real Live GTK origin windows."""

from pathlib import Path

from atspi_smoke import collect, press_x11_key, type_x11_text, wait_for


def verify_origin_window_picker(origin_env, viewer_env, process, app, request):
    second = request(origin_env, "window.new", args={"name": "Second Live Origin"})["id"]
    identity = request(origin_env, "session.new", args={"window": second, "name": "Second origin session"})["id"]
    config = Path(viewer_env["AGTERM_STATE_DIR"], "config")
    config.mkdir(exist_ok=True)
    (config / "remotes.conf").write_text("local-test Isolated Live GTK origin\n")
    before = {item["id"] for item in request(viewer_env, "window.list")["windows"] if item["open"]}
    press_x11_key("ctrl+shift+p", process.pid)
    type_x11_text("Open Remote Window", process.pid)
    wait_for(lambda: any(item.get_name().startswith("Open Remote Window") for item in collect(app, role="label")),
             "Open Remote Window GUI action missing")
    press_x11_key("Return", process.pid)
    wait_for(lambda: collect(app, role="label", name="Second Live Origin"), "multi-window origin picker did not list the second window")
    type_x11_text("Second Live Origin", process.pid)
    press_x11_key("Return", process.pid)
    window = wait_for(lambda: next((item["id"] for item in request(viewer_env, "window.list")["windows"]
                                   if item["open"] and item["id"] not in before), None), "GUI origin picker did not open its remote window")
    wait_for(lambda: any(row["id"] == identity for workspace in request(viewer_env, "tree", args={"window": window})["tree"]["workspaces"]
                         for row in workspace["sessions"]), "GUI origin picker opened the wrong window")
    request(viewer_env, "window.close", window)
    request(origin_env, "window.close", second)
    print("OK: real GUI origin picker selects the second of multiple Live GTK windows", flush=True)
