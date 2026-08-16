#!/usr/bin/env python3
"""AT-SPI smoke coverage for the real GTK frontend, always under isolated state and HOME."""

import json
import os
import re
import shlex
import shutil
import socket as socket_module
import subprocess
import sys
import tempfile
import time

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("Gtk", "4.0")
from gi.repository import Atspi, Gtk  # noqa: E402


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(ROOT)
BIN = os.environ.get("AGTERM_TEST_BIN", os.path.join(ROOT, ".build/debug/AgtermLinux"))
CTL = os.environ.get("AGTERM_TEST_CTL", os.path.join(ROOT, ".build/debug/agtermctl-linux"))
RESOURCE_ROOT = os.environ.get("AGTERM_RESOURCE_ROOT", os.path.join(REPO, "agterm/Resources"))
# Stamped into the app-stderr log on every attach; `scripts/test-linux-ui.sh` owns the value and greps
# for it verbatim. The literal below is only the standalone-dev-run fallback — see `app_stderr_sink`.
APP_STDERR_ATTACHED = os.environ.get(
    "AGTERM_UI_APP_STDERR_MARKER", "agterm-ui-smoke: app stderr sink attached"
)


def collect(node, role=None, name=None, out=None):
    """Depth-first collection that tolerates transiently disappearing GTK nodes."""
    if out is None:
        out = []
    try:
        node_name = node.get_name() or ""
        node_role = node.get_role_name()
        role_matches = role is None or node_role == role or (
            role == "button" and node_role == "push button"
        )
        if role_matches and (name is None or node_name == name):
            out.append(node)
        for index in range(node.get_child_count()):
            collect(node.get_child_at_index(index), role, name, out)
    except Exception:
        pass
    return out


def find_app(process_id):
    desktop = Atspi.get_desktop(0)
    matches = []
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if (
            app.get_process_id() == process_id
            and "agterm" in (app.get_name() or "").lower()
            and app.get_child_count() > 0
        ):
            matches.append(app)
    return matches[-1] if matches else None


def wait_for(predicate, message, timeout=12, required=True):
    """Poll `predicate` until it returns something truthy.

    `required=False` returns None on timeout instead of asserting, for a leg whose PRECONDITION the host
    may decline to provide (a compositor ignoring a window resize) — the caller then reports a SKIP.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    if not required:
        return None
    raise AssertionError(message)


def named(root, name, role=None):
    matches = collect(root, role=role, name=name)
    return matches[0] if matches else None


def named_prefix(root, prefix):
    """The first accessible under `root` whose name STARTS WITH `prefix`, or None (None `root` included).

    Toast and banner names carry their payload (`command failed: …`, `keymap.conf: 1 error — …`), so they
    can only be found by prefix; tolerating a missing `root` lets a caller compose this with a frame
    lookup inside a `wait_for` predicate.
    """
    if root is None:
        return None
    return next((item for item in collect(root) if (item.get_name() or "").startswith(prefix)), None)


def preferences_windows(root):
    return collect(root, role="dialog", name="Preferences") + collect(
        root, role="panel", name="Preferences"
    )


def preferences_window(root):
    matches = preferences_windows(root)
    return matches[0] if matches else None


def actionable(root, name):
    for item in reversed(collect(root, name=name)):
        try:
            actions = item.get_action_iface()
            if actions and actions.get_n_actions() > 0:
                return item
        except Exception:
            pass
    return None


def activate(node):
    assert node is not None, "cannot activate a missing accessible"
    actions = node.get_action_iface()
    assert actions and actions.get_n_actions() > 0, f"{node.get_name()!r} has no accessible action"
    assert actions.do_action(0), f"accessible action failed for {node.get_name()!r}"


def descendants(node, role=None, name=None):
    result = collect(node, role=role, name=name)
    return [item for item in result if item != node]


def editable_descendant(node):
    for item in descendants(node):
        try:
            if item.get_editable_text_iface():
                return item
        except Exception:
            pass
    return None


def describe_tree(node, depth=0):
    """Print a compact tree on failure so toolkit accessibility changes are diagnosable."""
    try:
        name = node.get_name() or ""
        if name or depth < 2:
            print(f"A11Y {'  ' * depth}{node.get_role_name()}: {name!r}")
        for index in range(node.get_child_count()):
            describe_tree(node.get_child_at_index(index), depth + 1)
    except Exception:
        pass


def press_x11_key(key, process_id, window_title=None):
    if window_title:
        app = wait_for(lambda: find_app(process_id), "agterm app disappeared before key input")
        window = wait_for(
            lambda: named(app, window_title, role="frame"),
            f"agterm window {window_title!r} disappeared before key input",
        )
        focus_accessible_window(window, process_id)
    else:
        focus_window(process_id)
    time.sleep(0.5)
    subprocess.run(
        ["xdotool", "key", "--clearmodifiers", key],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def type_x11_text(value, process_id, window_title=None):
    """Type through the real X11 keyboard path used by the isolated UI suite."""
    if window_title:
        app = wait_for(lambda: find_app(process_id), "agterm app disappeared before text input")
        window = wait_for(
            lambda: named(app, window_title, role="frame"),
            f"agterm window {window_title!r} disappeared before text input",
        )
        focus_accessible_window(window, process_id)
    else:
        focus_window(process_id)
    time.sleep(0.5)
    subprocess.run(
        ["xdotool", "type", "--clearmodifiers", "--delay", "1", "--", value],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def press_ctrl_comma(process_id, window_title=None):
    # AT-SPI's device-event controller cannot inject keys on non-Mutter Wayland.
    # Hyprland's compositor dispatcher sends the real shortcut to this test PID;
    # The isolated X11 path uses xdotool against its private Xvfb display.
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        target = f"title:^({window_title})$" if window_title else f"pid:{process_id}"
        subprocess.run(
            [
                "hyprctl", "dispatch", "sendshortcut",
                f"CTRL,comma,{target}",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    press_x11_key("ctrl+comma", process_id, window_title)


def press_ctrl_shift_p(process_id, window_title=None):
    """Open the command palette in the focused isolated window."""
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        target = f"title:^({window_title})$" if window_title else f"pid:{process_id}"
        subprocess.run(
            [
                "hyprctl", "dispatch", "sendshortcut",
                f"CTRL SHIFT,P,{target}",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    press_x11_key("ctrl+shift+p", process_id, window_title)


def press_escape(process_id, window_title=None):
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        target = f"title:^({window_title})$" if window_title else f"pid:{process_id}"
        subprocess.run(
            ["hyprctl", "dispatch", "sendshortcut", f",escape,{target}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    press_x11_key("Escape", process_id, window_title)


def press_return(process_id, window_title=None):
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        target = f"title:^({window_title})$" if window_title else f"pid:{process_id}"
        subprocess.run(
            ["hyprctl", "dispatch", "sendshortcut", f",return,{target}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    press_x11_key("Return", process_id, window_title)


def press_right(process_id, window_title=None):
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        target = f"title:^({window_title})$" if window_title else f"pid:{process_id}"
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", target],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if shutil.which("dotool"):
            keyboard = subprocess.Popen(
                ["dotool"], stdin=subprocess.PIPE, text=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                time.sleep(0.5)
                keyboard.stdin.write("key right\n")
                keyboard.stdin.flush()
                time.sleep(0.2)
            finally:
                keyboard.stdin.close()
                keyboard.wait(timeout=3)
            return
        subprocess.run(
            ["hyprctl", "dispatch", "sendshortcut", f",right,{target}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    press_x11_key("Right", process_id, window_title)


def focus_window(process_id):
    """Give the isolated app real keyboard focus before testing its shortcut."""
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", f"pid:{process_id}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    app = wait_for(lambda: find_app(process_id), "agterm app disappeared before focus")
    windows = collect(app, role="frame")
    assert windows, "agterm has no accessible window to focus"
    focus_accessible_window(windows[-1], process_id)


def focus_accessible_window(window, process_id):
    """Focus one exact window when the isolated process owns more than one."""
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        title = window.get_name() or ""
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", f"title:^({title})$"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    title = window.get_name() or ""
    subprocess.run(
        [
            "xdotool", "search", "--onlyvisible", "--name", f"^{re.escape(title)}$",
            "windowactivate", "--sync", "%@",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def mouse_click(node_provider, process_id, window_title=None, button="right"):
    """Send a real pointer click to an accessible in one exact GTK window."""
    if window_title and not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        app = wait_for(lambda: find_app(process_id), "agterm app disappeared before pointer input")
        window = wait_for(
            lambda: named(app, window_title, role="frame"),
            f"agterm window {window_title!r} disappeared before pointer input",
        )
        focus_accessible_window(window, process_id)
    else:
        focus_window(process_id)
    deadline = time.monotonic() + 8
    bounds = None
    while time.monotonic() < deadline:
        try:
            node = node_provider()
            component = node.get_component_iface() if node else None
            if component:
                bounds = component.get_extents(Atspi.CoordType.SCREEN)
                break
        except Exception:
            pass
        time.sleep(0.1)
    assert bounds, "session row did not expose stable screen bounds"
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        # Wayland intentionally hides global coordinates from AT-SPI (SCREEN reports 0,0), while
        # WINDOW coordinates remain valid. Combine those with Hyprland's own client origin.
        local = component.get_extents(Atspi.CoordType.WINDOW)
        clients = json.loads(subprocess.check_output(["hyprctl", "-j", "clients"], text=True))
        client = next(
            (
                item for item in clients
                if item.get("pid") == process_id
                and (window_title is None or item.get("title") == window_title)
            ),
            None,
        )
        assert client, "Hyprland did not expose the isolated agterm client"
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", f"address:{client['address']}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        x = client["at"][0] + local.x + max(1, local.width // 2)
        y = client["at"][1] + local.y + max(1, local.height // 2)
        if shutil.which("dotool"):
            pointer = subprocess.Popen(
                ["dotool"], stdin=subprocess.PIPE, text=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                time.sleep(0.5)  # Let Hyprland register the temporary uinput pointer.
                subprocess.run(
                    ["hyprctl", "dispatch", "movecursor", str(x), str(y)],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                time.sleep(0.2)
                pointer.stdin.write(f"click {button}\n")
                pointer.stdin.flush()
                time.sleep(0.2)
            finally:
                pointer.stdin.close()
                pointer.wait(timeout=3)
            return
        number = 3 if button == "right" else 1
        assert Atspi.generate_mouse_event(x, y, f"b{number}c"), "AT-SPI click failed"
        return
    local = component.get_extents(Atspi.CoordType.WINDOW)
    geometry = subprocess.check_output(
        ["xdotool", "getactivewindow", "getwindowgeometry", "--shell"], text=True
    )
    origin = dict(line.split("=", 1) for line in geometry.splitlines() if "=" in line)
    x = int(origin["X"]) + local.x + max(1, local.width // 2)
    y = int(origin["Y"]) + local.y + max(1, local.height // 2)
    number = 3 if button == "right" else 1
    time.sleep(0.2)
    subprocess.run(
        ["xdotool", "mousemove", "--sync", str(x), str(y), "click", str(number)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def right_click(node_provider, process_id, window_title=None):
    mouse_click(node_provider, process_id, window_title=window_title, button="right")


def app_stderr_sink():
    """Open the exact log the runner scans for GTK CSS parse errors, or DEVNULL when it named none.

    GTK drops an unparseable CSS declaration SILENTLY — a `Theme parser error` line on the app's stderr
    is the only signal anywhere that a rule in `installAppCSS` was rejected, and a rejected rule presents
    as missing chrome, not as a test failure. A plain file (never the runner's pipe) keeps a leaked child
    from holding the pipeline open.

    The runner hands over BOTH the path (`AGTERM_UI_APP_STDERR`) and the marker
    (`AGTERM_UI_APP_STDERR_MARKER`, stamped on every attach as `APP_STDERR_ATTACHED`) rather than either
    side re-deriving them. That is what keeps the guard from failing OPEN: a filename or marker spelled
    independently on the two sides would drift, turning the runner's `grep` into a permanent pass over an
    empty log with nothing to notice.
    """
    path = os.environ.get("AGTERM_UI_APP_STDERR")
    if not path:
        return subprocess.DEVNULL
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    sink = open(path, "ab", buffering=0)
    sink.write((APP_STDERR_ATTACHED + "\n").encode())
    return sink


def launch(env):
    sink = app_stderr_sink()
    try:
        process = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=sink)
    finally:
        if sink is not subprocess.DEVNULL:
            sink.close()
    app = wait_for(lambda: find_app(process.pid), "agterm app not present in the AT-SPI tree")
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        subprocess.run(
            ["hyprctl", "dispatch", "movetoworkspacesilent", f"3,pid:{process.pid}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return process, app


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    wait_for(lambda: find_app(process.pid) is None, "agterm remained in the accessibility tree after exit")


def control_json(env, *arguments):
    output = subprocess.check_output(
        [CTL, *arguments, "--socket", env["AGTERM_CONTROL_SOCKET"]],
        env=env,
        text=True,
        timeout=10,
    )
    return json.loads(output)


def raw_control_json(env, request):
    """Send one wire request so protocol-only commands can be exercised without a CLI polling loop."""
    client = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
    client.settimeout(10)
    try:
        client.connect(env["AGTERM_CONTROL_SOCKET"])
        client.sendall(json.dumps(request).encode("utf-8") + b"\n")
        response = b""
        while b"\n" not in response:
            chunk = client.recv(64 * 1024)
            assert chunk, "control socket closed before returning a response"
            response += chunk
        return json.loads(response.split(b"\n", 1)[0])
    finally:
        client.close()


def window_list(env):
    return control_json(env, "window", "list", "--json")["result"]["windows"]


def select_window(env, window_id):
    control_json(env, "window", "select", window_id, "--json")
    wait_for(
        lambda: next(
            (item for item in window_list(env) if item["id"] == window_id), {}
        ).get("active"),
        f"window {window_id} did not become active",
    )


def window_tree(env, window_id):
    return control_json(env, "tree", "--window", window_id, "--json")["result"]["tree"]


def session_count(tree):
    return sum(len(workspace["sessions"]) for workspace in tree["workspaces"])


def activate_reveal_action(env, identity):
    subprocess.run(
        ["gapplication", "action", env["AGTERM_APP_ID"], "reveal", f"'{identity}'"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )


def palette_row_labels(palette):
    """Every palette row's label names, in widget order."""
    # A row is a horizontal box of separate labels: title, then the optional `custom` badge, then the
    # optional right-aligned chord. named() searches the whole subtree and so cannot see order or which
    # row a label belongs to; comparing this list is what pins the arrangement.
    return [
        [label.get_name() or "" for label in collect(row, role="label")]
        for row in collect(palette, role="list item")
    ]


def open_palette(app, process_id, window_title):
    """Focus one window, open its command palette, and return (palette frame, search entry)."""
    window = wait_for(
        lambda: named(app, window_title, role="frame"),
        f"window {window_title!r} is missing",
    )
    focus_accessible_window(window, process_id)
    press_ctrl_shift_p(process_id, window_title=window_title)
    palette = wait_for(
        lambda: named(app, "Command Palette", role="frame"),
        f"command palette did not open in {window_title!r}",
    )
    search = wait_for(
        lambda: editable_descendant(palette),
        "command palette search is missing",
    )
    return palette, search


def run_palette_action(app, process_id, window_title, action_name, badge=None):
    """Filter the palette to one action and run it."""
    palette, search = open_palette(app, process_id, window_title)
    assert search.get_editable_text_iface().set_text_contents(action_name)
    # `badge` is the pill the matching row must also render (None = the row carries none). It is never
    # typed into the search entry, and it is checked ROW-SCOPED — a subtree-wide named() would be
    # satisfied by any other row's badge.
    wait_for(
        lambda: any(
            labels[:1] == [action_name] and (badge is None or badge in labels[1:])
            for labels in palette_row_labels(palette)
        )
        and not named(palette, "About agterm"),
        f"palette action {action_name!r}"
        + (f" with its {badge!r} badge" if badge else "")
        + " did not become the selected result",
    )
    press_return(process_id, window_title="Command Palette")
    wait_for(
        lambda: not named(app, "Command Palette", role="frame"),
        f"command palette did not close after {action_name!r}",
    )


def check_palette_row_layout(app, process_id, window_title):
    """Pin the full three-label row and the de-duplicated catalog row, without running anything."""
    # run_palette_action only ever drives chordless custom commands, so title + badge + chord together —
    # the arrangement this rendering actually introduces — has no other coverage.
    palette, search = open_palette(app, process_id, window_title)
    editable = search.get_editable_text_iface()

    assert editable.set_text_contents("Chorded Demo")
    wait_for(
        lambda: ["Chorded Demo", "custom", "ctrl+shift+e"] in palette_row_labels(palette),
        "a chorded custom row did not render title, custom badge, and chord in that order",
    )

    # "Open Directory…" comes from the shared PaletteCommand catalog only — the Linux-only duplicate
    # append is gone, so exactly one row may carry that title, and it must show its own chord.
    assert editable.set_text_contents("Open Directory")
    rows = wait_for(
        lambda: [labels for labels in palette_row_labels(palette)
                 if labels and labels[0] == "Open Directory…"],
        "the catalog Open Directory… row did not render",
    )
    assert rows == [["Open Directory…", "ctrl+shift+o"]], f"unexpected Open Directory… rows: {rows}"

    press_escape(process_id, window_title="Command Palette")
    wait_for(
        lambda: not named(app, "Command Palette", role="frame"),
        "command palette did not close after the row-layout check",
    )


def check_keymap_reload_fanout(app, process_id, env, first_title, second_title):
    """Pin that an explicit keymap reload reaches EVERY window, and an unreloaded edit reaches none.

    `first_title`/`second_title` are FRAME titles — the SESSION names (`command-origin-a` /
    `command-origin-b`), never the window NAME (`command-window-b`) — because `open_palette` looks its
    window up with `named(app, title, role="frame")`.

    Two separate bugs are covered, both of which used to rebuild a SINGLE controller's caches while every
    other window kept dispatching the previous bindings: the `keymap.reload` control command and the
    palette's own `Reload Keymap` row. Each is asserted in BOTH windows — asserting both is what makes
    the check independent of which controller the reload resolved, so it cannot pass without the fan-out.
    The palette rows themselves come from the cached keymap, so the pre-reload leg doubles as the
    "an edited-but-not-yet-reloaded chord must not be advertised" assertion.

    `keymap.conf` is APPENDED to along the way and RESTORED to the caller's seeded content before
    returning, so nothing downstream runs against keymap state this function wrote.
    """
    # Derived the same way the scenario itself derives its config dir, so `env` alone locates the fixture.
    keymap = os.path.join(env["AGTERM_STATE_DIR"], "config", "keymap.conf")
    with open(keymap, encoding="utf-8") as source:
        seeded = source.read()

    def filtered_rows(title, needle, sentinel, message):
        """Open one window's palette, filter it to `needle`, wait for `sentinel`, and return every row.

        Waiting for a row that MUST be present is what keeps the caller's ABSENCE assertions honest: a
        palette that has not finished filtering renders no rows at all, so a bare "row is missing" check
        would pass vacuously against an empty list.
        """
        palette, search = open_palette(app, process_id, title)
        assert search.get_editable_text_iface().set_text_contents(needle)

        def settled():
            rows = palette_row_labels(palette)
            return rows if sentinel in rows else None

        rows = wait_for(settled, message)
        press_escape(process_id, window_title="Command Palette")
        wait_for(
            lambda: not named(app, "Command Palette", role="frame"),
            f"command palette did not close in {title!r}",
        )
        return rows

    chorded_row = ["Chorded Demo", "custom", "ctrl+shift+e"]
    # ctrl+shift+y is free everywhere the parser looks, the same reasoning as the seeded ctrl+shift+e:
    # isReservedMonitorChord covers only ctrl+tab / ctrl+1 / ctrl+2, isLinuxReservedChord adds only
    # ctrl+comma, the Linux default table binds no `y`, and no shared default uses key "y" — so
    # cross-section validation never clears this shortcut and it reaches the row as the raw token.
    with open(keymap, "a", encoding="utf-8") as target:
        target.write('command "Late Demo" ctrl+shift+y true\n')

    for title in (first_title, second_title):
        rows = filtered_rows(title, "Demo", chorded_row,
                             f"the seeded custom rows did not render in {title}'s palette")
        assert not any(row[:1] == ["Late Demo"] for row in rows), (
            f"an edited-but-unreloaded keymap.conf already shows in {title}'s palette"
        )

    # Bug one: `agtermctl keymap reload` used to rebuild only the controller it resolved.
    control_json(env, "keymap", "reload", "--json")
    for title in (first_title, second_title):
        filtered_rows(title, "Demo", ["Late Demo", "custom", "ctrl+shift+y"],
                      f"agtermctl keymap reload did not reach {title}'s palette")

    # Bug two: the palette's own `Reload Keymap` row — driven in the FIRST window, asserted in the SECOND.
    # The second command is deliberately chord-less; the chord column is already pinned above, and a
    # second chord would need its own cross-section-validation argument to stay meaningful.
    with open(keymap, "a", encoding="utf-8") as target:
        target.write('command "Palette Demo" true\n')
    run_palette_action(app, process_id, first_title, "Reload Keymap")
    filtered_rows(second_title, "Demo", ["Palette Demo", "custom"],
                  f"the palette's Reload Keymap row did not reach {second_title}'s palette")

    # Restore the fixture the CALLER seeded, so everything after this returns to the keymap state it wrote
    # rather than to whatever this check appended. Every reload above was clean, hence silent, so there is
    # no banner left queued for the next check to trip over.
    with open(keymap, "w", encoding="utf-8") as target:
        target.write(seeded)
    control_json(env, "keymap", "reload", "--json")


def check_keymap_error_banner(app, env, first_title, second_title):
    """Pin that a malformed `keymap.conf` still banners its parse errors on reload.

    A clean reload is SILENT, so no other leg posts a banner. Surfacing parse errors also moved from
    inside `reloadKeymapDiagnostics` (where it was guaranteed) out to each caller, so assert one actually
    reaches the user. `map ctrl+, new_session` is a reserved Linux chord and yields exactly one
    diagnostic; `LinuxKeymapTests` pins that count host-free, so the expected text below is derived rather
    than guessed.

    Like `check_keymap_reload_fanout`, this RESTORES `keymap.conf` before returning — and additionally
    waits its own banner out, so nothing downstream runs against the malformed file or the toast queue.
    """
    keymap = os.path.join(env["AGTERM_STATE_DIR"], "config", "keymap.conf")
    with open(keymap, encoding="utf-8") as source:
        seeded = source.read()

    def banner_in(title):
        return named_prefix(named(app, title, role="frame"), "keymap.conf")

    with open(keymap, "a", encoding="utf-8") as target:
        target.write("map ctrl+, new_session\n")
    control_json(env, "keymap", "reload", "--json")
    # Asserted in EITHER window rather than a specific one: the seam reports once, in whichever controller
    # the command resolved, and pinning that resolution here would test `gController`, not the banner.
    banner = wait_for(
        lambda: banner_in(first_title) or banner_in(second_title),
        "a malformed keymap.conf reloaded without reporting the parse error",
    )
    assert banner.get_name() == "keymap.conf: 1 error — bad line ignored", (
        f"unexpected keymap banner: {banner.get_name()!r}"
    )

    # Restore, then wait the banner out. showToast posts to an AdwToastOverlay that shows one toast at a
    # time and queues the rest at AdwToast's ~5 s default, so a live banner would sit in FRONT of the
    # launch/exit-failure toasts the caller asserts next.
    with open(keymap, "w", encoding="utf-8") as target:
        target.write(seeded)
    control_json(env, "keymap", "reload", "--json")
    wait_for(
        lambda: not banner_in(first_title) and not banner_in(second_title),
        "the keymap.conf error banner never cleared",
    )


def verify_normal_toolbar(env, state, home):
    process, app = launch(env)
    try:
        rows = wait_for(lambda: collect(app, role="list item"), "expected at least one session row")
        wait_for(lambda: named(app, "workspace 1", role="label"), "workspace label is missing")

        subprocess.run(
            [CTL, "session", "new", "--socket", env["AGTERM_CONTROL_SOCKET"]],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        wait_for(
            lambda: len(collect(app, role="list item")) == len(rows) + 1,
            "session.new did not update the accessibility tree",
        )

        # Closing a native window removes its AppController before GTK finishes unmapping it. Exercise
        # the late notify::is-active callback and prove it cannot dereference the retired controller.
        created = control_json(env, "window", "new", "teardown-check", "--json")["result"]["id"]
        control_json(env, "window", "close", created, "--json")
        assert process.poll() is None, "closing a secondary window terminated the application"
        control_json(env, "tree", "--json")

        assert not named(app, "Main Menu"), "toolbar still exposes the removed Main Menu button"

        assert not preferences_window(app), "Preferences was open before shortcut verification"
        focus_window(process.pid)
        press_ctrl_comma(process.pid)
        wait_for(
            lambda: preferences_window(app),
            "Ctrl+, did not open Preferences",
        )
        press_ctrl_comma(process.pid)
        wait_for(
            lambda: len(preferences_windows(app)) == 1,
            "Ctrl+, did not preserve the single Preferences dialog",
        )
        print("OK: menu-free toolbar and Ctrl+, Preferences shortcut")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_upstream_control_parity(env):
    """Round-trip the upstream v0.16 control additions through the real Linux socket and GTK host."""
    process, app = launch(env)
    try:
        window_id = next(item["id"] for item in window_list(env) if item["open"])
        initial_tree = window_tree(env, window_id)
        initial_session = initial_tree["workspaces"][0]["sessions"][0]["id"]

        # v0.22 Linux control adapters: prove the shared pane/HUD model reaches a realized GTK host and
        # returns through the real socket. The HUD's short settle also proves its helper received the body
        # file environment; without it the helper exits immediately and the tree drops `hud`.
        control_json(
            env, "session", "split", "on", "--target", initial_session,
            "--window", window_id, "--json",
        )

        def parity_session():
            return next(
                session for workspace in window_tree(env, window_id)["workspaces"]
                for session in workspace["sessions"] if session["id"] == initial_session
            )

        assert parity_session().get("hasSplit"), "tree did not report the realized split"
        pane_open = raw_control_json(env, {
            "cmd": "session.overlay.open", "target": initial_session,
            "args": {"command": "sleep 5", "pane": "right", "window": window_id},
        })
        assert pane_open["ok"], f"right-pane overlay open failed: {pane_open}"
        wait_for(
            lambda: parity_session().get("paneOverlays") == ["right"],
            "tree did not report the right-pane overlay",
        )
        pane_close = raw_control_json(env, {
            "cmd": "session.overlay.close", "target": initial_session,
            "args": {"pane": "right", "window": window_id},
        })
        assert pane_close["ok"], f"right-pane overlay close failed: {pane_close}"
        wait_for(
            lambda: not parity_session().get("paneOverlays"),
            "right-pane overlay stayed open after close",
        )
        pane_exit = raw_control_json(env, {
            "cmd": "session.overlay.open", "target": initial_session,
            "args": {"command": "exit 7", "pane": "right", "window": window_id},
        })
        assert pane_exit["ok"], f"right-pane exit overlay failed: {pane_exit}"
        wait_for(
            lambda: not parity_session().get("paneOverlays"),
            "exited right-pane overlay stayed in the tree",
        )
        pane_result = raw_control_json(env, {
            "cmd": "session.overlay.result", "target": initial_session,
            "args": {"pane": "right", "window": window_id},
        })
        assert pane_result["ok"] and pane_result["result"].get("exitCode") == 7, (
            f"right-pane overlay result did not return exit 7: {pane_result}"
        )

        hud_open = raw_control_json(env, {
            "cmd": "session.hud.open", "target": initial_session,
            "args": {
                "message": "Preparing", "detail": "Linux parity", "spinner": "bar",
                "position": "top-right", "window": window_id,
            },
        })
        assert hud_open["ok"], f"HUD open failed: {hud_open}"
        wait_for(lambda: parity_session().get("hud", {}).get("message") == "Preparing",
                 "tree did not report the live HUD")
        time.sleep(0.3)
        assert parity_session().get("hud", {}).get("message") == "Preparing", (
            "HUD helper exited instead of remaining attached to its body file"
        )
        hud_update = raw_control_json(env, {
            "cmd": "session.hud.update", "target": initial_session,
            "args": {"message": "Ready", "textColor": "#00ff88", "window": window_id},
        })
        assert hud_update["ok"], f"HUD update failed: {hud_update}"
        wait_for(lambda: parity_session().get("hud", {}).get("message") == "Ready",
                 "tree did not report the HUD update")
        hud_close = raw_control_json(env, {
            "cmd": "session.hud.close", "target": initial_session,
            "args": {"window": window_id},
        })
        assert hud_close["ok"], f"HUD close failed: {hud_close}"
        wait_for(lambda: not parity_session().get("hud"), "HUD stayed open after close")

        bootstrap = raw_control_json(env, {"cmd": "events.read"})
        assert bootstrap["ok"], f"events.read bootstrap failed: {bootstrap}"
        anchor = bootstrap["result"]["events"]
        assert anchor["items"] == [], "events.read bootstrap replayed prior history"

        workspace_id = control_json(
            env, "workspace", "new", "parity-work", "--collapsed",
            "--window", window_id, "--json",
        )["result"]["id"]
        wait_for(
            lambda: named(app, "parity-work", role="label"),
            "collapsed workspace was not rendered",
        )

        def workspace_node():
            return next(
                workspace for workspace in window_tree(env, window_id)["workspaces"]
                if workspace["id"] == workspace_id
            )

        assert workspace_node().get("collapsed"), "workspace.new --collapsed did not persist model state"
        control_json(
            env, "workspace", "expand", "--target", workspace_id,
            "--window", window_id, "--json",
        )
        assert not workspace_node().get("collapsed"), "workspace.expand did not update tree read-back"
        control_json(
            env, "workspace", "collapse", "--target", workspace_id,
            "--window", window_id, "--json",
        )
        assert workspace_node().get("collapsed"), "workspace.collapse did not update tree read-back"

        restore_line = "printf restored-by-parity-hook"
        control_json(
            env, "session", "restore", restore_line, "--target", initial_session,
            "--window", window_id, "--json",
        )
        restored = window_tree(env, window_id)["workspaces"][0]["sessions"][0]
        assert restored.get("restoreCommand") == restore_line, "session.restore was not persisted"

        held_id = control_json(
            env, "session", "new", "--name", "held-command", "--command", "true", "--wait",
            "--no-select", "--window", window_id, "--json",
        )["result"]["id"]
        time.sleep(1.0)
        held = next((
            session for workspace in window_tree(env, window_id)["workspaces"]
            for session in workspace["sessions"] if session["id"] == held_id
        ), None)
        assert held and held.get("commandWait"), "session.new --wait did not keep the exited command session"

        page = raw_control_json(env, {
            "cmd": "events.read",
            "args": {
                "run": anchor["run"],
                "after": str(anchor["next"]),
                "kinds": ["session.created"],
                "limit": 100,
            },
        })
        assert page["ok"], f"events.read cursor failed: {page}"
        assert any(
            item.get("kind") == "session.created" and item.get("session") == held_id
            for item in page["result"]["events"]["items"]
        ), "events.read did not return the Linux-created session event"
        stop(process)
        process = None

        process, app = launch(env)
        persisted_tree = window_tree(env, window_id)
        persisted_workspace = next(
            workspace for workspace in persisted_tree["workspaces"] if workspace["id"] == workspace_id
        )
        persisted_initial = next(
            session for workspace in persisted_tree["workspaces"]
            for session in workspace["sessions"] if session["id"] == initial_session
        )
        persisted_held = next(
            session for workspace in persisted_tree["workspaces"]
            for session in workspace["sessions"] if session["id"] == held_id
        )
        assert persisted_workspace.get("collapsed"), "workspace collapse state did not survive relaunch"
        assert persisted_initial.get("restoreCommand") == restore_line, (
            "restore override did not survive relaunch"
        )
        assert persisted_held.get("commandWait"), "command wait state did not survive relaunch"
        print("OK: v0.22 pane overlays/HUD plus events, restore, held commands, and collapse round-trip")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        if process is not None:
            stop(process)


def verify_dashboard_modal(env):
    process, app = launch(env)
    try:
        window_id = wait_for(
            lambda: next((item["id"] for item in window_list(env) if item["open"]), None),
            "initial window was not registered",
        )
        tree = window_tree(env, window_id)
        session_id = tree["workspaces"][0]["sessions"][0]["id"]
        control_json(env, "session", "rename", "modal-session", "--window", window_id, "--json")
        control_json(env, "window", "rename", window_id, "release", "--json")
        control_json(
            env, "session", "split", "on", "--target", session_id,
            "--window", window_id, "--json",
        )
        wait_for(lambda: named(app, "modal-session", role="frame"), "renamed modal window is missing")

        dashboard_button = wait_for(
            lambda: actionable(app, "Dashboard (Ctrl+Shift+M)"),
            "Dashboard header button is not actionable",
        )
        activate(dashboard_button)
        wait_for(
            lambda: named(app, "Dashboard — release", role="label"),
            "dashboard did not expose its custom-window title",
        )
        exit_dashboard = wait_for(
            lambda: named(app, "Exit Dashboard", role="button"),
            "dashboard close button is not actionable",
        )
        dashboard_tree = window_tree(env, window_id)
        assert dashboard_tree.get("dashboardMembers") == [
            f"{session_id}:left", f"{session_id}:right",
        ], "Dashboard header button did not open the pane-exact MRU grid"
        activate(exit_dashboard)
        wait_for(
            lambda: not window_tree(env, window_id).get("dashboardMembers"),
            "Exit Dashboard did not close the dashboard",
        )

        # Keyboard navigation changes the already-visible highlight and Enter selects immediately.
        activate(wait_for(
            lambda: actionable(app, "Dashboard (Ctrl+Shift+M)"),
            "Dashboard header button did not return after close",
        ))
        press_right(process.pid, window_title="modal-session")
        wait_for(
            lambda: window_tree(env, window_id).get("dashboardHighlighted") == f"{session_id}:right",
            "Right Arrow did not move the dashboard highlight to the split pane",
        )
        press_return(process.pid, window_title="modal-session")
        wait_for(
            lambda: not window_tree(env, window_id).get("dashboardMembers"),
            "Enter did not close the dashboard immediately",
        )
        assert window_tree(env, window_id)["workspaces"][0]["sessions"][0].get("splitFocused"), (
            "keyboard dashboard entry did not focus the exact split pane"
        )
        input_marker = os.path.join(env["AGTERM_STATE_DIR"], "dashboard-input-restored")
        type_x11_text(
            f"printf dashboard-restored > {shlex.quote(input_marker)}",
            process.pid,
            window_title="modal-session",
        )
        press_return(process.pid, window_title="modal-session")
        wait_for(
            lambda: os.path.exists(input_marker),
            "terminal did not accept keyboard input after Dashboard closed",
        )
        with open(input_marker, encoding="utf-8") as marker:
            assert marker.read() == "dashboard-restored", (
                "post-Dashboard terminal command produced unexpected output"
            )

        # A real single pointer click flashes the split cell, then enters it after the 180 ms delay.
        control_json(
            env, "session", "focus", "left", "--target", session_id,
            "--window", window_id, "--json",
        )
        activate(wait_for(
            lambda: actionable(app, "Dashboard (Ctrl+Shift+M)"),
            "Dashboard header button did not reopen for pointer coverage",
        ))
        wait_for(
            lambda: named(app, "modal-session · Right", role="label"),
            "dashboard split cell caption is missing",
        )
        mouse_click(
            lambda: named(app, "modal-session · Right", role="label"),
            process.pid,
            window_title="modal-session",
            button="left",
        )
        wait_for(
            lambda: not window_tree(env, window_id).get("dashboardMembers"),
            "single-click dashboard entry did not close after its highlight flash",
        )
        assert window_tree(env, window_id)["workspaces"][0]["sessions"][0].get("splitFocused"), (
            "single-click dashboard entry did not focus the exact split pane"
        )

        # The zoom chrome carries the normal composite title. Opening either modal closes the other.
        control_json(
            env, "surface", "zoom", "show", "--target", "active",
            "--window", window_id, "--json",
        )
        wait_for(
            lambda: named(app, "modal-session — release", role="label"),
            "terminal zoom did not expose its session/window title",
        )
        wait_for(
            lambda: actionable(app, "Exit Terminal Zoom"),
            "terminal zoom close button is not actionable",
        )
        control_json(env, "dashboard", "--mru", "--window", window_id, "--json")
        wait_for(
            lambda: window_tree(env, window_id).get("dashboardMembers")
            and not window_tree(env, window_id).get("zoomedSurface"),
            "opening Dashboard did not close Terminal Zoom",
        )
        control_json(
            env, "surface", "zoom", "show", "--target", "active",
            "--window", window_id, "--json",
        )
        wait_for(
            lambda: window_tree(env, window_id).get("zoomedSurface")
            and not window_tree(env, window_id).get("dashboardMembers"),
            "opening Terminal Zoom did not close Dashboard",
        )
        wait_for(
            lambda: named(app, "Exit Terminal Zoom", role="button"),
            "Terminal Zoom exit button disappeared",
        )
        activate(named(app, "Exit Terminal Zoom", role="button"))
        wait_for(
            lambda: not window_tree(env, window_id).get("zoomedSurface"),
            "Exit Terminal Zoom did not restore the normal window",
        )
        print("OK: dashboard single-click, modal titles, exact panes, and zoom exclusion")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_context_menu(env):
    process, app = launch(env)
    try:
        rows = wait_for(lambda: collect(app, role="list item"), "expected at least one session row")
        flag = None
        for _ in range(3):
            right_click(lambda: next(iter(collect(app, role="list item")), None), process.pid)
            try:
                flag = wait_for(lambda: actionable(app, "Flag"), "session context menu did not open", timeout=1)
                break
            except AssertionError:
                pass
        assert flag, "session context menu did not open"
        assert process.poll() is None, "session context menu terminated the app"
        press_escape(process.pid)
        primary_window = wait_for(lambda: next(iter(window_list(env)), None), "primary window did not register")
        primary_id = primary_window["id"]
        primary_session = window_tree(env, primary_id)["workspaces"][0]["sessions"][0]["id"]
        control_json(env, "session", "split", "on", "--target", primary_session, "--json")
        wait_for(
            lambda: window_tree(env, primary_id)["workspaces"][0]["sessions"][0].get("hasSplit"),
            "session split did not become active",
        )
        right_click(lambda: next(iter(collect(app, role="list item")), None), process.pid)
        wait_for(lambda: actionable(app, "Close Session"), "split session context menu did not open")
        assert process.poll() is None, "split session context menu terminated the app"
        press_escape(process.pid)
        created = control_json(env, "window", "new", "context-background", "--json")["result"]["id"]
        assert process.poll() is None, "backgrounding a window with a context menu terminated the app"
        control_json(env, "window", "close", created, "--json")
        activate(wait_for(lambda: actionable(app, "New Session"), "New Session button is not actionable"))
        wait_for(
            lambda: len(collect(app, role="list item")) == len(rows) + 1,
            "creating a session with a context menu open blocked the app",
        )
        control_json(env, "tree", "--json")
        print("OK: session context menu survives a sidebar rebuild")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_split_exit_sidebar(env):
    process, app = launch(env)
    try:
        primary_window = wait_for(
            lambda: next(iter(window_list(env)), None),
            "primary window did not register",
        )
        window_id = primary_window["id"]
        session_id = window_tree(env, window_id)["workspaces"][0]["sessions"][0]["id"]
        control_json(
            env, "session", "split", "on", "--target", session_id,
            "--window", window_id, "--json",
        )
        wait_for(
            lambda: window_tree(env, window_id)["workspaces"][0]["sessions"][0].get("hasSplit"),
            "session split did not become active",
        )
        time.sleep(0.5)
        control_json(
            env, "session", "type", "printf '\\033]2;split-exit-left\\007'; sleep 30\n",
            "--target", session_id, "--pane", "left", "--window", window_id, "--json",
        )
        control_json(
            env, "session", "type", "printf '\\033]2;split-exit-right\\007'; sleep 5; exit\n",
            "--target", session_id, "--pane", "right", "--window", window_id, "--json",
        )
        control_json(
            env, "session", "status", "blocked", "--target", session_id,
            "--pane", "right", "--window", window_id, "--json",
        )

        def session_state():
            return window_tree(env, window_id)["workspaces"][0]["sessions"][0]

        wait_for(
            lambda: session_state().get("name") == "split-exit-right"
            and session_state().get("status") == "blocked",
            "right-pane title/status did not reach the model",
        )
        wait_for(
            lambda: sidebar_row_settled(app, "split-exit-right", images=1, labels=2),
            "right-pane title/status did not reach the sidebar row",
        )
        wait_for(
            lambda: not session_state().get("hasSplit")
            and session_state().get("name") == "split-exit-left"
            and session_state().get("status", "idle") == "idle",
            "split exit did not restore the primary-pane model presentation",
        )
        row = wait_for(
            lambda: sidebar_row_settled(app, "split-exit-left", images=1, labels=1),
            "split exit left a stale sidebar name/status presentation",
        )
        labels = [item.get_name() or "" for item in descendants(row, role="label")]
        assert labels == ["split-exit-left"], f"split exit left stale sidebar labels: {labels}"
        assert process.poll() is None, "split exit terminated the app"
        print("OK: split exit refreshes the sidebar name and status")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_window_callback_ownership(env):
    process, app = launch(env)
    try:
        primary_id = wait_for(
            lambda: next((item["id"] for item in window_list(env) if item["open"]), None),
            "primary window was not registered",
        )
        control_json(env, "session", "rename", "primary-session", "--window", primary_id, "--json")
        secondary_id = control_json(env, "window", "new", "secondary", "--json")["result"]["id"]
        control_json(env, "session", "rename", "secondary-session", "--window", secondary_id, "--json")

        primary = wait_for(
            lambda: named(app, "primary-session", role="frame"),
            "primary window did not expose its unique session title",
        )
        wait_for(
            lambda: named(app, "secondary-session", role="frame"),
            "secondary window did not expose its unique session title",
        )
        select_window(env, secondary_id)
        before_primary = session_count(window_tree(env, primary_id))
        before_secondary = session_count(window_tree(env, secondary_id))
        activate(wait_for(
            lambda: actionable(primary, "New Session"),
            "background primary window's New Session button is not actionable",
        ))
        wait_for(
            lambda: session_count(window_tree(env, primary_id)) == before_primary + 1,
            "background-window action did not mutate its owning window",
        )
        assert session_count(window_tree(env, secondary_id)) == before_secondary, (
            "background-window action mutated the frontmost window"
        )
        control_json(env, "session", "rename", "primary-session", "--window", primary_id, "--json")
        primary = wait_for(
            lambda: named(app, "primary-session", role="frame"),
            "primary frame title did not follow its new active session",
        )

        # Open an auxiliary palette from the primary window, then make the secondary window frontmost
        # before editing its search. The callback must filter the originating palette, not look for a
        # nonexistent palette on the newly frontmost controller.
        select_window(env, primary_id)
        focus_accessible_window(primary, process.pid)
        wait_for(
            lambda: next(
                (item for item in window_list(env) if item["id"] == primary_id), {}
            ).get("active"),
            "primary window did not receive keyboard focus",
        )
        press_ctrl_shift_p(process.pid, window_title="primary-session")
        palette = wait_for(
            lambda: named(app, "Command Palette", role="frame"),
            "primary command palette did not open",
        )
        select_window(env, secondary_id)
        palette_search = wait_for(
            lambda: editable_descendant(palette),
            "background command palette did not expose an editable search",
        )
        assert palette_search.get_editable_text_iface().set_text_contents("New Session")
        # A palette row is a horizontal box of SEPARATE labels: title (left) and, when the command is
        # bound, its chord (right-aligned, dimmed). Comparing ONE row's labels in order is what pins
        # that split end-to-end — "ctrl+shift+t" is never typed into the search entry, so only a
        # rendered shortcut label on that same row can satisfy it.
        wait_for(
            lambda: ["New Session", "ctrl+shift+t"] in palette_row_labels(palette)
            and not named(palette, "About agterm"),
            "background command palette search routed to the frontmost window",
        )
        press_escape(process.pid, window_title="Command Palette")
        wait_for(
            lambda: not named(app, "Command Palette", role="frame"),
            "background command palette did not close through its owner-bound key callback",
        )

        # Exercise a pending split restore while another window becomes active, then prove the original
        # session still accepts and persists a divider resize through its explicit window address.
        primary_session = window_tree(env, primary_id)["workspaces"][0]["sessions"][0]["id"]
        select_window(env, primary_id)
        control_json(
            env, "session", "split", "on", "--target", primary_session,
            "--window", primary_id, "--json",
        )
        select_window(env, secondary_id)
        control_json(
            env, "session", "resize", "--split-ratio", "0.31", "--target", primary_session,
            "--window", primary_id, "--json",
        )
        wait_for(
            lambda: abs(
                window_tree(env, primary_id)["workspaces"][0]["sessions"][0].get("splitRatio", 0) - 0.31
            ) < 0.001,
            "background split ratio was not persisted after its restore timer",
        )

        # Keep Preferences open on the primary, move focus away, and toggle a setting through the
        # background dialog. This covers both the GAction root context and settings widget ancestry.
        select_window(env, primary_id)
        primary = wait_for(
            lambda: named(app, "primary-session", role="frame"),
            "primary frame disappeared before Preferences coverage",
        )
        focus_accessible_window(primary, process.pid)
        press_ctrl_comma(process.pid, window_title="primary-session")
        preferences = wait_for(
            lambda: preferences_window(app),
            "primary Preferences dialog did not open",
        )
        select_window(env, secondary_id)
        right_click_switch = wait_for(
            lambda: actionable(preferences, "Right-click pastes"),
            "background Preferences switch is not actionable",
        )
        activate(right_click_switch)
        assert process.poll() is None, "background Preferences activity terminated the application"
        select_window(env, primary_id)
        press_escape(process.pid, window_title="primary-session")
        wait_for(
            lambda: not preferences_window(app),
            "background Preferences dialog did not close through its owning window",
        )

        # Repeatedly close secondary windows with a fresh split restore and palette/window callbacks in
        # flight. The application and the surviving primary controller must remain usable.
        for index in range(4):
            transient_id = control_json(
                env, "window", "new", f"teardown-{index}", "--json"
            )["result"]["id"]
            transient_session = window_tree(env, transient_id)["workspaces"][0]["sessions"][0]["id"]
            control_json(
                env, "session", "split", "on", "--target", transient_session,
                "--window", transient_id, "--json",
            )
            control_json(env, "window", "close", transient_id, "--json")
            assert process.poll() is None, "closing a secondary window terminated the application"
        control_json(env, "tree", "--window", primary_id, "--json")

        print("OK: background callbacks and pending secondary-window teardown keep their owners")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_notification_reveal(env):
    process, app = launch(env)
    try:
        primary_id = wait_for(
            lambda: next((item["id"] for item in window_list(env) if item["open"]), None),
            "primary notification window was not registered",
        )
        primary_tree = window_tree(env, primary_id)
        session_id = primary_tree["workspaces"][0]["sessions"][0]["id"]
        control_json(
            env, "session", "split", "on", "--target", session_id,
            "--window", primary_id, "--json",
        )
        control_json(
            env, "session", "focus", "right", "--target", session_id,
            "--window", primary_id, "--json",
        )
        secondary_id = control_json(env, "window", "new", "reveal-survivor", "--json")["result"]["id"]
        control_json(env, "window", "close", primary_id, "--json")
        wait_for(
            lambda: not next(
                (item for item in window_list(env) if item["id"] == primary_id), {"open": True}
            )["open"],
            "source notification window did not close",
        )

        identity = f"{primary_id}:{session_id}:split"
        activate_reveal_action(env, identity)
        wait_for(
            lambda: next(
                (item for item in window_list(env) if item["id"] == primary_id), {}
            ).get("open"),
            "notification reveal did not reopen its encoded window",
        )

        def revealed_split():
            tree = window_tree(env, primary_id)
            sessions = [session for workspace in tree["workspaces"] for session in workspace["sessions"]]
            target = next((session for session in sessions if session["id"] == session_id), None)
            return target and target.get("active") and target.get("splitFocused")

        wait_for(revealed_split, "notification reveal did not select the encoded split pane")
        assert next(
            item for item in window_list(env) if item["id"] == secondary_id
        )["open"], "notification reveal disturbed the surviving window"
        assert process.poll() is None, "notification reveal terminated the application"
        print("OK: notification action reopens its encoded window and split pane")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def gdk_supported_keys(variable, env):
    """Ask this runner's GTK for the exact key table consumed by its complement parser."""
    probe_env = dict(env)
    probe_env[variable] = "help"
    probe = subprocess.run(
        [
            sys.executable, "-c",
            "import gi; gi.require_version('Gtk', '4.0'); "
            "from gi.repository import Gtk; Gtk.init()",
        ],
        env=probe_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
        check=False,
    )
    heading = f"Supported {variable} values:"
    lines = probe.stderr.splitlines()
    try:
        start = lines.index(heading) + 1
    except ValueError as error:
        raise AssertionError(f"GTK did not report its {variable} key table: {probe.stderr}") from error
    keys = []
    for line in lines[start:]:
        if not line.startswith("  "):
            if keys:
                break
            continue
        key = line.split()[0]
        if key == "all":
            break
        if key != "help":
            keys.append(key)
    assert keys, f"GTK reported an empty {variable} key table"
    return tuple(keys)


def gdk_inversion_fixture(env):
    """An `all` value whose effective GTK flags are exactly the policy-required pair.

    Every ordinary key is listed after `all`, so GDK's complement parser subtracts it. The input also
    deliberately lists the required pair; LinuxGdkPolicy must remove those exclusions before GTK parses
    the value. This lets the real app exercise inversion without turning on every unrelated debug flag.
    """
    if Gtk.get_major_version() > 4 or Gtk.get_minor_version() >= 16:
        variable = "GDK_DISABLE"
        required = ("gles-api", "vulkan")
    else:
        variable = "GDK_DEBUG"
        required = ("gl-disable-gles", "vulkan-disable")
    keys = gdk_supported_keys(variable, env)
    assert set(required).issubset(keys), f"GTK's {variable} table is missing {required}"
    original = ",".join(("all", *keys))
    normalized = ",".join(("all", *(key for key in keys if key not in required)))
    return variable, required, original, normalized


def verify_child_gdk_environment(env, expected_assignment=None):
    """A spawned shell must see the PRE-LAUNCH GDK environment, not agterm's own overrides.

    agterm sets GDK_DISABLE/GDK_DEBUG on itself before GTK initializes; the restore merged in
    GhosttySurface.init is the only thing keeping every child -- and any GTK app it launches -- from
    inheriting agterm's renderer constraints. Reverting that one line leaves every unit test green, so
    the wiring is pinned here instead.

    The normal scenario scrubs both variables before launch. The inversion scenario deliberately supplies
    an `all` fixture that excludes the required flags; the app must normalize its own value while restoring
    that original fixture byte-for-byte to the shell. In either case the expected readback comes directly
    from the environment captured before launch, rather than from the app's post-policy process environment.
    """
    readback = os.path.join(env["AGTERM_STATE_DIR"], "gdk-child-env.txt")
    command = (
        'printf "gdk[%s][%s]end\\n" "$GDK_DISABLE" "$GDK_DEBUG" > '
        f'"{readback}"\n'
    )
    process, app = launch(env)
    try:
        tree = control_json(env, "tree", "--json")["result"]["tree"]
        session_id = tree["workspaces"][0]["sessions"][0]["id"]
        window_id = next(item["id"] for item in window_list(env) if item["open"])

        def captured():
            if not os.path.exists(readback):
                return None
            with open(readback, encoding="utf-8", errors="replace") as source:
                text = source.read()
            return text if "end" in text else None

        # Typing before the login shell reaches its prompt loses the line for good, and the prompt can be
        # slow under software GL, so re-type until the file appears rather than betting on one sleep.
        # wait_for() cannot express this: it polls a predicate, it cannot re-send the input between polls.
        # The budget matches wait_for's own 12 s default, spent as 12 attempts one second apart.
        retype_attempts, retype_interval = 12, 1.0
        text = None
        for _ in range(retype_attempts):
            control_json(
                env, "session", "type", command, "--target", session_id,
                "--window", window_id, "--json",
            )
            time.sleep(retype_interval)
            text = captured()
            if text:
                break
        assert text, "the session shell never wrote its GDK environment back"
        expected = f"gdk[{env.get('GDK_DISABLE', '')}][{env.get('GDK_DEBUG', '')}]end"
        assert expected in text, (
            "spawned shell did not see the exact pre-launch GDK environment: "
            f"expected {expected!r}, got {text.strip()!r}"
        )
        if expected_assignment:
            stderr_path = env["AGTERM_UI_APP_STDERR"]

            def assignment_was_emitted():
                try:
                    with open(stderr_path, encoding="utf-8", errors="replace") as source:
                        return expected_assignment in source.read()
                except OSError:
                    return False

            wait_for(
                assignment_was_emitted,
                f"app did not emit normalized GDK assignment: {expected_assignment}",
            )
        assert process.poll() is None, "the child-environment check terminated the application"
        print("OK: spawned shells see the pre-launch GDK environment, not agterm's normalized overrides")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_notification_focus_policy(env):
    with open(os.path.join(env["AGTERM_STATE_DIR"], "settings.json"), "w", encoding="utf-8") as target:
        json.dump({"notificationsEnabled": False}, target)
    process, app = launch(env)
    try:
        focus_window(process.pid)
        tree = control_json(env, "tree", "--json")["result"]["tree"]
        initial = tree["workspaces"][0]["sessions"][0]
        window_id = next(item["id"] for item in window_list(env) if item["open"])
        time.sleep(1.0)  # let the initial login shell reach its prompt before injecting printf

        def unseen(session_id):
            current = window_tree(env, window_id)
            sessions = [session for workspace in current["workspaces"] for session in workspace["sessions"]]
            return next(session for session in sessions if session["id"] == session_id).get("unseen", 0)

        def emit_osc(session_id, title):
            command = f"printf '\\033]9;{title} Body\\007'\n"
            control_json(
                env, "session", "type", command, "--target", session_id,
                "--window", window_id, "--json",
            )

        emit_osc(initial["id"], "Focused")
        time.sleep(0.6)
        assert unseen(initial["id"]) == 0, "focused pane OSC notification created an unseen badge"

        foreground_id = control_json(
            env, "session", "new", "--name", "foreground", "--window", window_id, "--json"
        )["result"]["id"]
        wait_for(
            lambda: window_tree(env, window_id)["workspaces"][0]["sessions"][-1].get("active"),
            "new foreground session did not become active",
        )
        wait_for(
            lambda: named(app, "foreground", role="frame"),
            "new foreground session did not become the visible GTK surface",
        )
        time.sleep(0.5)
        emit_osc(initial["id"], "Hidden")
        wait_for(
            lambda: unseen(initial["id"]) == 1,
            "hidden pane OSC notification did not create an unseen badge",
        )

        control_json(
            env, "notify", "--title", "Explicit", "--target", foreground_id,
            "control bypass", "--window", window_id, "--json",
        )
        wait_for(
            lambda: unseen(foreground_id) == 1,
            "explicit control notification did not bypass focused-pane suppression",
        )
        assert process.poll() is None, "notification focus policy terminated the application"
        print("OK: focused OSC suppresses badge while hidden and explicit notifications deliver")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_notification_banner_round_trip(env):
    assert shutil.which("makoctl"), "makoctl is required for the desktop-banner round trip"
    notification_id = None
    process, app = launch(env)
    try:
        focus_window(process.pid)
        tree = control_json(env, "tree", "--json")["result"]["tree"]
        initial = tree["workspaces"][0]["sessions"][0]
        window_id = next(item["id"] for item in window_list(env) if item["open"])
        time.sleep(1.0)

        def unseen(session_id):
            current = window_tree(env, window_id)
            sessions = [session for workspace in current["workspaces"] for session in workspace["sessions"]]
            return next(session for session in sessions if session["id"] == session_id).get("unseen", 0)

        def emit_osc(session_id, body):
            control_json(
                env, "session", "type", f"printf '\\033]9;{body}\\007'\n",
                "--target", session_id, "--window", window_id, "--json",
            )

        test_suffix = os.path.basename(env["AGTERM_STATE_DIR"])
        suppressed_body = f"Focused banner must suppress {test_suffix}"
        delivered_body = f"Hidden banner must deliver {test_suffix}"
        emit_osc(initial["id"], suppressed_body)
        time.sleep(0.8)
        assert unseen(initial["id"]) == 0
        assert not any(
            item.get("body") == suppressed_body
            for item in json.loads(subprocess.check_output(["makoctl", "list", "-j"], text=True))
        ), "focused pane posted a desktop banner"

        control_json(env, "session", "new", "--name", "banner-foreground", "--window", window_id, "--json")
        wait_for(lambda: named(app, "banner-foreground", role="frame"), "foreground banner session not visible")
        time.sleep(0.5)
        emit_osc(initial["id"], delivered_body)
        wait_for(lambda: unseen(initial["id"]) == 1, "hidden pane did not raise its badge")
        notification = wait_for(
            lambda: next((
                item for item in json.loads(subprocess.check_output(["makoctl", "list", "-j"], text=True))
                if item.get("body") == delivered_body
            ), None),
            "hidden pane did not post a desktop banner",
        )
        notification_id = notification["id"]

        survivor = control_json(env, "window", "new", "banner-survivor", "--json")["result"]["id"]
        control_json(env, "window", "close", window_id, "--json")
        wait_for(
            lambda: not next(item for item in window_list(env) if item["id"] == window_id)["open"],
            "banner source window did not close",
        )
        subprocess.run(["makoctl", "invoke", "-n", str(notification_id)], check=True)
        wait_for(
            lambda: next(item for item in window_list(env) if item["id"] == window_id)["open"],
            "desktop banner action did not reopen the source window",
        )
        wait_for(
            lambda: next(
                session for workspace in window_tree(env, window_id)["workspaces"]
                for session in workspace["sessions"] if session["id"] == initial["id"]
            ).get("active"),
            "desktop banner action did not select its source session",
        )
        assert next(item for item in window_list(env) if item["id"] == survivor)["open"]
        print("OK: real desktop banner suppresses, delivers, and reopens its source window")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        if notification_id is not None:
            subprocess.run(
                ["makoctl", "dismiss", "-n", str(notification_id), "-h"], check=False
            )
        stop(process)


def verify_custom_command_failures(env):
    config = os.path.join(env["AGTERM_STATE_DIR"], "config")
    os.makedirs(config)
    with open(os.path.join(config, "keymap.conf"), "w", encoding="utf-8") as target:
        target.write(
            'command "Launch Failure" true\n'
            'command "Exit Failure" exit 23\n'
            'command "Slow Failure" sleep 1; exit 29\n'
            # never fired — it exists so one palette row carries all three labels at once. ctrl+shift+e
            # is free in both the Linux and the upstream default chord tables, so it survives keymap
            # validation and reaches the row as the user's own raw token.
            'command "Chorded Demo" ctrl+shift+e true\n'
        )
    process, app = launch(env)
    try:
        first_window = next(item["id"] for item in window_list(env) if item["open"])
        first_cwd = os.path.join(env["AGTERM_STATE_DIR"], "command-cwd-a")
        second_cwd = os.path.join(env["AGTERM_STATE_DIR"], "command-cwd-b")
        os.makedirs(first_cwd)
        os.makedirs(second_cwd)
        first_session = control_json(
            env, "session", "new", "--name", "command-origin-a", "--cwd", first_cwd,
            "--window", first_window, "--json",
        )["result"]["id"]
        second_window = control_json(env, "window", "new", "command-window-b", "--json")["result"]["id"]
        second_session = control_json(
            env, "session", "new", "--name", "command-origin-b", "--cwd", second_cwd,
            "--window", second_window, "--json",
        )["result"]["id"]

        def frame(title):
            return named(app, title, role="frame")

        wait_for(lambda: frame("command-origin-a"), "first command window did not become accessible")
        wait_for(lambda: frame("command-origin-b"), "second command window did not become accessible")
        check_palette_row_layout(app, process.pid, "command-origin-a")
        # Both frames are proven present by the waits above, so the keymap checks reuse this two-window
        # fixture instead of launching a scenario of their own. Each restores keymap.conf before returning.
        check_keymap_reload_fanout(app, process.pid, env, "command-origin-a", "command-origin-b")
        check_keymap_error_banner(app, env, "command-origin-a", "command-origin-b")
        time.sleep(0.5)
        shutil.rmtree(first_cwd)
        shutil.rmtree(second_cwd)
        exit_titles = {}
        for window_id, session_id, title, other_title in (
            (first_window, first_session, "command-origin-a", "command-origin-b"),
            (second_window, second_session, "command-origin-b", "command-exit-a"),
        ):
            run_palette_action(app, process.pid, title, "Launch Failure", badge="custom")
            launch_prefix = "command failed to launch: Launch Failure —"
            wait_for(
                lambda: named_prefix(frame(title), launch_prefix),
                f"launch failure toast did not appear in {title}",
            )
            assert not named_prefix(frame(other_title), launch_prefix), (
                f"launch failure from {title} leaked into {other_title}"
            )

            suffix = "a" if window_id == first_window else "b"
            exit_title = f"command-exit-{suffix}"
            control_json(
                env, "session", "new", "--name", exit_title, "--cwd", "/tmp",
                "--window", window_id, "--json",
            )
            wait_for(lambda: frame(exit_title), f"{exit_title} did not become accessible")
            exit_titles[window_id] = exit_title
            run_palette_action(app, process.pid, exit_title, "Exit Failure", badge="custom")
            exit_message = "command failed (exit 23): Exit Failure"
            wait_for(
                lambda: named(frame(exit_title), exit_message),
                f"non-zero failure toast did not appear in {exit_title}",
            )
            assert not named(frame(other_title), exit_message), (
                f"non-zero failure from {exit_title} leaked into {other_title}"
            )

        run_palette_action(app, process.pid, exit_titles[first_window], "Slow Failure", badge="custom")
        control_json(env, "window", "close", first_window, "--json")
        wait_for(
            lambda: not next(item for item in window_list(env) if item["id"] == first_window)["open"],
            "slow-command source window did not close",
        )
        control_json(env, "window", "select", first_window, "--json")
        wait_for(
            lambda: next(item for item in window_list(env) if item["id"] == first_window)["open"],
            "slow-command source window did not reopen",
        )
        time.sleep(1.4)
        slow_message = "command failed (exit 29): Slow Failure"
        assert not named(frame(exit_titles[first_window]), slow_message), (
            "old command completion reached the reopened controller incarnation"
        )
        assert not named(frame(exit_titles[second_window]), slow_message), (
            "old command completion leaked into the other window"
        )
        print("OK: custom-command failures stay with their originating controller incarnation")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_surface_configuration_lifetimes(env):
    """Exercise libghostty-owned command, cwd, overlay, and restored initial-input buffers."""
    state = env["AGTERM_STATE_DIR"]
    runner = os.path.join(state, "surface-lifetime-probe.sh")
    with open(runner, "w", encoding="utf-8") as target:
        target.write(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$PWD\" > \"$1\"\n"
            "sleep 0.4\n"
        )
    os.chmod(runner, 0o755)
    command_cwd = os.path.join(state, "command-cwd")
    overlay_cwd = os.path.join(state, "overlay-cwd")
    os.makedirs(command_cwd)
    os.makedirs(overlay_cwd)
    command_marker = os.path.join(state, "command.marker")
    overlay_marker = os.path.join(state, "overlay.marker")
    full_overlay_marker = os.path.join(state, "overlay-full.marker")
    restore_marker = os.path.join(state, "restore.marker")
    url_marker = os.path.join(state, "url.marker")
    url_callback_marker = os.path.join(state, "url-callback.marker")
    url = "https://example.test/agterm/" + ("length-delimited-" * 10) + "end?q=one%20two#fragment"
    xdg_data = os.path.join(state, "xdg-data")
    xdg_config = os.path.join(state, "xdg-config")
    applications = os.path.join(xdg_data, "applications")
    os.makedirs(applications)
    os.makedirs(xdg_config)
    url_capture = os.path.join(state, "capture-url.sh")
    with open(url_capture, "w", encoding="utf-8") as target:
        target.write(f"#!/bin/sh\nprintf '%s' \"$1\" > {url_marker}\n")
    os.chmod(url_capture, 0o755)
    with open(os.path.join(applications, "agterm-url-test.desktop"), "w", encoding="utf-8") as target:
        target.write(
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=agterm URL test\n"
            f"Exec={url_capture} %u\n"
            "MimeType=x-scheme-handler/https;\n"
            "NoDisplay=true\n"
        )
    with open(os.path.join(xdg_config, "mimeapps.list"), "w", encoding="utf-8") as target:
        target.write("[Default Applications]\nx-scheme-handler/https=agterm-url-test.desktop;\n")
    env["XDG_DATA_HOME"] = xdg_data
    env["XDG_CONFIG_HOME"] = xdg_config
    env["GTK_A11Y"] = "atspi"
    subprocess.run(["gio", "open", url], env=env, check=True)
    wait_for(lambda: os.path.exists(url_marker), "test URL handler did not register")
    os.remove(url_marker)

    process, _ = launch(env)
    try:
        window_id = next(item["id"] for item in window_list(env) if item["open"])
        initial = window_tree(env, window_id)["workspaces"][0]["sessions"][0]
        control_json(
            env, "session", "new", "--name", "surface-command", "--cwd", command_cwd,
            "--command", f"{runner} {command_marker}", "--window", window_id, "--json",
        )
        wait_for(lambda: os.path.exists(command_marker), "session --command did not run")
        with open(command_marker, encoding="utf-8") as source:
            assert source.read().strip() == command_cwd

        # --size-percent makes this the FLOATING overlay: a framed card added to the deck overlay and
        # clipped to its rounded corners (GTK_OVERFLOW_HIDDEN in syncOverlay). --follow selects the
        # target so that card is actually VISIBLE and therefore rendered — a hidden frame is skipped in
        # layout, so without it the rounded clip over the GL texture node never reaches GSK and this
        # exercises nothing beyond construction. --follow also makes `initial` (not the just-created
        # `surface-command`) the SELECTED session, which is what the snapshot below persists and the
        # restore leg re-launches into; the restore assertion is unaffected either way, because
        # reconcile() realizes a surface for EVERY session in the tree, so the restored foreground
        # command is delivered whether or not its session is the selected one. The assertions stay
        # exactly as they were: the overlay's program must still run in its own cwd, whichever variant
        # hosts it.
        control_json(
            env, "session", "overlay", "open", f"{runner} {overlay_marker}",
            "--cwd", overlay_cwd, "--size-percent", "60", "--follow",
            "--target", initial["id"], "--window", window_id, "--json",
        )
        wait_for(lambda: os.path.exists(overlay_marker), "overlay command did not run")
        with open(overlay_marker, encoding="utf-8") as source:
            assert source.read().strip() == overlay_cwd

        # The floating card is one of TWO overlay shapes, and this scenario is the suite's only
        # `session overlay open`, so the un-sized DEFAULT shape has to run here as well or it has no
        # coverage anywhere: it takes syncOverlay's other branch entirely — gtk_stack_add_named
        # "overlay" / set_visible_child_name, and on teardown set_visible_child_name back plus
        # gtk_stack_remove — none of which the framed branch touches. openOverlay refuses a second
        # overlay while one is open, so wait out the card's teardown first; the tree's `overlay` flag is
        # the read side of that close, and polling it (rather than sleeping) also proves the floating
        # teardown ran. Waiting for the second close then carries the stack teardown too.
        def overlay_open():
            tree = window_tree(env, window_id)
            node = next(item for workspace in tree["workspaces"] for item in workspace["sessions"]
                        if item["id"] == initial["id"])
            return bool(node.get("overlay"))

        wait_for(lambda: not overlay_open(), "floating overlay stayed open after its command exited")
        control_json(
            env, "session", "overlay", "open", f"{runner} {full_overlay_marker}",
            "--cwd", overlay_cwd, "--target", initial["id"], "--window", window_id, "--json",
        )
        wait_for(lambda: os.path.exists(full_overlay_marker), "full-pane overlay command did not run")
        with open(full_overlay_marker, encoding="utf-8") as source:
            assert source.read().strip() == overlay_cwd
        wait_for(lambda: not overlay_open(), "full-pane overlay stayed open after its command exited")
    finally:
        stop(process)

    snapshot_path = os.path.join(state, "windows", f"{window_id}.json")
    with open(snapshot_path, encoding="utf-8") as source:
        snapshot = json.load(source)
    restored = next(
        session for workspace in snapshot["workspaces"] for session in workspace["sessions"]
        if session["id"] == initial["id"]
    )
    restored["foregroundCommand"] = [runner, restore_marker]
    with open(snapshot_path, "w", encoding="utf-8") as target:
        json.dump(snapshot, target)
    with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as target:
        json.dump({"restoreRunningCommand": True}, target)
    env["AGTERM_ATSPI_OPEN_URL"] = url
    env["AGTERM_ATSPI_URL_CAPTURE"] = url_callback_marker

    process, _ = launch(env)
    try:
        wait_for(
            lambda: os.path.exists(restore_marker),
            "restored foreground command was not delivered through initial input",
        )
        with open(restore_marker, encoding="utf-8") as source:
            assert source.read().strip() == initial["cwd"]
        wait_for(
            lambda: os.path.exists(url_callback_marker),
            "runtime URL action did not reach the Linux launch boundary",
        )
        with open(url_callback_marker, encoding="utf-8") as source:
            assert source.read() == url, "libghostty URL callback was truncated or changed"
        wait_for(lambda: os.path.exists(url_marker), "runtime URL action did not reach the URL launcher")
        with open(url_marker, encoding="utf-8") as source:
            assert source.read() == url, "terminal hyperlink was truncated or changed"
        print("OK: libghostty buffers survive command/cwd/restore paths and exact URL launch")
    finally:
        stop(process)


def verify_surface_failure_diagnostics(env):
    """Injected creation and GL-context failures select local and display-wide presentation."""
    failure_env = dict(env, AGTERM_ATSPI_SURFACE_FAILURE="creation:quick")
    process, app = launch(failure_env)
    try:
        window_id = next(item["id"] for item in window_list(failure_env) if item["open"])
        initial_tree = window_tree(failure_env, window_id)
        session_id = initial_tree["workspaces"][0]["sessions"][0]["id"]

        control_json(failure_env, "quick", "show", "--json")
        wait_for(
            lambda: named_prefix(app, "Quick terminal failed to start."),
            "generic quick-surface failure did not expose its role-local diagnostic",
        )
        assert not named_prefix(app, "Terminal rendering needs OpenGL."), (
            "generic surface failure incorrectly used the display-wide GL diagnostic"
        )

        marker = "healthy-sibling-visible"
        typed = control_json(
            failure_env, "session", "type", f"printf '{marker}\\n'\n",
            "--target", session_id, "--window", window_id, "--json",
        )
        assert typed["ok"], f"healthy sibling rejected terminal input: {typed}"

        def healthy_sibling_text():
            try:
                response = control_json(
                    failure_env, "session", "text", "--lines", "10",
                    "--target", session_id, "--window", window_id, "--json",
                )
                return marker in response.get("result", {}).get("text", "")
            except (subprocess.CalledProcessError, KeyError, TypeError):
                return False

        wait_for(
            healthy_sibling_text,
            "healthy main terminal stopped rendering/read-back after the quick surface failed",
        )
        control_json(failure_env, "quick", "hide", "--json")
        wait_for(
            lambda: not named_prefix(app, "Quick terminal failed to start."),
            "role-local failure diagnostic remained visible after its quick host was hidden",
        )
        control_json(failure_env, "quick", "show", "--json")
        wait_for(
            lambda: named_prefix(app, "Quick terminal failed to start."),
            "role-local failure diagnostic did not return with its retained quick host",
        )
        print("OK: generic failure stays role-local and leaves a healthy sibling usable")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)

    gl_env = dict(env, AGTERM_ATSPI_SURFACE_FAILURE="gl-context:quick")
    process, app = launch(gl_env)
    try:
        control_json(gl_env, "quick", "show", "--json")
        wait_for(
            lambda: named_prefix(app, "Terminal rendering needs OpenGL."),
            "injected GtkGLArea context failure did not use the display-wide diagnostic",
        )
        assert not named_prefix(app, "Quick terminal failed to start."), (
            "proven GL context failure incorrectly used a generic role-local diagnostic"
        )
        print("OK: proven GL context failure keeps the display-wide diagnostic")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_sidebar_row_height_follows_font_size(env):
    """Sidebar rows must follow the sidebar font size instead of Adwaita's 36px navigation-sidebar pin."""
    settings_path = os.path.join(env["AGTERM_STATE_DIR"], "settings.json")

    def sample_row_height(app):
        # Preferences AdwActionRows carry the same `list item` role, so this scenario's single-session
        # state is what pins the measurement to the sidebar row; an extra row means something else
        # opened and the reading would be meaningless, so that case ASSERTS (naming the count) instead
        # of polling, which would otherwise surface 12s later as a generic timeout. Extents are read in
        # WINDOW coordinates because SCREEN reports a 0,0 origin under Wayland. A row is published to
        # the accessibility tree before its first allocate and reports height 0, so an implausible
        # sample returns None and lets the caller poll; the 20px gate sits deliberately BELOW the
        # smallest CSS floor this scenario can reach (24px at 9pt) so an override that never applied
        # fails loudly in the band assertion rather than as "never reported a settled height".
        rows = collect(app, role="list item")
        if not rows:
            return None
        assert len(rows) == 1, f"expected exactly one sidebar row, found {len(rows)} list items"
        try:
            component = rows[0].get_component_iface()
            if component is None:
                return None
            height = component.get_extents(Atspi.CoordType.WINDOW).height
        except Exception:
            return None
        return height if height >= 20 else None

    def settled_row_height(app):
        first = sample_row_height(app)
        if first is None:
            return None
        time.sleep(0.1)
        return first if sample_row_height(app) == first else None

    def measure(font_size, label, check):
        if font_size is not None:
            # Merge rather than clobber, so a future first-run settings write is not silently reset and
            # this keeps measuring a font-size change against otherwise unchanged state.
            settings = {}
            if os.path.exists(settings_path):
                with open(settings_path, encoding="utf-8") as source:
                    settings = json.load(source)
            settings["sidebarFontSize"] = font_size
            with open(settings_path, "w", encoding="utf-8") as destination:
                json.dump(settings, destination)
        process, app = launch(env)
        try:
            height = wait_for(
                lambda: settled_row_height(app),
                f"the sidebar row never reported a settled height {label}",
            )
            check(height)
            return height
        except AssertionError:
            describe_tree(app)
            raise
        finally:
            stop(process)

    def default_band(height):
        # Triage: a height at or near 36 means the emitted CSS override never applied at all - the theme
        # pin makes anything under 36 unreachable without it.
        assert 28 <= height < 36, (
            f"default sidebar row height {height}px left the 28px floor .. 36px Adwaita pin band"
        )

    def dense_band(height):
        # Only the CSS floor is asserted upward: the exact height is host font metrics (Cantarell here,
        # whatever fontconfig picks in the CI container), and the densification claim is carried by the
        # comparison against the default row rather than by a hand-tuned pixel cap.
        assert height >= 24, f"9pt sidebar row height {height}px sank below the 24px floor"
        assert height < default_height, (
            f"9pt rows ({height}px) did not densify below the default rows ({default_height}px)"
        )

    def large_band(height):
        # min-height is a FLOOR, not a cap: 20pt text must grow the row past both its own floor and the
        # default row instead of being clipped to a fixed height.
        assert height >= 35, f"20pt sidebar row height {height}px sank below the 35px floor"
        assert height > default_height, (
            f"20pt rows ({height}px) did not grow past the default rows ({default_height}px)"
        )

    # The two comparison bands read `default_height`, so the passes must stay in this order.
    default_height = measure(None, "at the default sidebar font size", default_band)
    small_height = measure(9, "at the 9pt sidebar font size", dense_band)
    large_height = measure(20, "at the 20pt sidebar font size", large_band)
    print(
        "OK: sidebar row height follows the sidebar font size "
        f"({default_height}px default -> {small_height}px at 9pt -> {large_height}px at 20pt)"
    )


# How far past the sidebar column's right edge a row part may sit — and how far the column itself may
# grow — before it counts as a regression. THEME-INSET tolerance, not a fudge factor: AT-SPI extents
# include a widget's own CSS margin and padding, and a trailing widget's inset from the scroller's
# content edge varies by libadwaita version, so shrinking this back to 1 fails on some hosts for a clip
# nobody can see. It costs no discriminating power: with the fix backed out one leg at a time the
# tree-row name lands 426px past the column's right edge, the flagged breadcrumb 771px and the unwrapped
# hint 114px, so nothing real lands in the 1..8 band.
SIDEBAR_EDGE_SLACK = 8


def window_extents(node):
    """Window-relative extents for an accessible, or None while it is still unallocated.

    WINDOW and never SCREEN: Wayland withholds global coordinates from AT-SPI, so SCREEN reports a 0,0
    origin. Returning None for the empty box GTK publishes before a node's first allocate lets `wait_for`
    keep polling instead of asserting on a placeholder.

    ⚠️ A NEGATIVE ORIGIN is NORMAL, never "not yet allocated" — WINDOW coordinates start inside the CSD
    border. Every caller is origin-relative, so do not add an `x < 0` guard here.
    """
    try:
        component = node.get_component_iface()
        if not component:
            return None
        bounds = component.get_extents(Atspi.CoordType.WINDOW)
    except Exception:
        return None
    return bounds if bounds.width > 1 and bounds.height > 1 else None


def sidebar_column(app):
    """The sidebar column's own window-relative box, or None while it is still unallocated.

    The `GtkScrolledWindow` IS the column: it is the clipping boundary, so its allocation tracks the
    paned position rather than the overflowing content — unlike the viewport, content box, list box and
    row parent box BELOW it, which inherit the overflow under the bug and would make containment
    vacuously true. It is the LEFTMOST scrolled window in the tree, and both edges come from it because
    the CSD inset means the left edge is not reliably 0.
    """
    boxes = [box for node in collect(app, role="scroll pane") if (box := window_extents(node))]
    return min(boxes, key=lambda box: box.x) if boxes else None


def sidebar_settled_label(app, prefix):
    """The box of the first label whose name starts with `prefix` and that reports a real extent."""
    for candidate in collect(app, role="label"):
        if (candidate.get_name() or "").startswith(prefix) and (box := window_extents(candidate)):
            return box
    return None


def sidebar_fits(app, box, description, column=None):
    """CONTAINMENT: fails when `box` sticks out past the sidebar column's right edge.

    `column` defaults to a fresh read and must never be hoisted ACROSS the scenario's steps — each goes
    through `rebuildSidebar`, so a limit captured once would be stale for the rest. Callers measuring
    several parts of ONE row pass the column they resolved for it (see `sidebar_row_parts_fit`).

    ⚠️ Half the gate on any site — `sidebar_does_not_widen` is the other half.
    """
    if column is None:
        column = wait_for(lambda: sidebar_column(app), "the sidebar column never allocated")
    limit = column.x + column.width
    edge = box.x + box.width
    assert edge <= limit + SIDEBAR_EDGE_SLACK, (
        f"{description} is pushed past the {column.width}px sidebar column (right edge {limit}px): "
        f"x={box.x} width={box.width} right={edge} — a sidebar label lost its PANGO_ELLIPSIZE_END (or a "
        "new row builder never set one), so it reports its whole text as its minimum width")


def sidebar_does_not_widen(app, baseline, description):
    """NO GROWTH: fails when the sidebar column had to grow to hold `description`.

    Never redundant with `sidebar_fits`: containment is the load-bearing half while the sidebar's minimum
    stays pinned independent of its rows, and goes quiet the moment that minimum follows them instead,
    because every part then sits inside the widened column.

    Asserting no width of its own is what makes this independent of the host font family and text
    scaling: a part that truncates correctly reports a minimum FAR narrower than the decorated row that
    already sized the column, so it cannot move that column at any font size.

    `baseline` must be an EARLIER column read, never a re-read: re-reading it after the offending text
    appeared would measure the regression against itself.
    """
    column = wait_for(lambda: sidebar_column(app), "the sidebar column never allocated")
    assert column.width <= baseline + SIDEBAR_EDGE_SLACK, (
        f"the sidebar column GREW from {baseline}px to {column.width}px when {description} appeared — "
        "correctly truncated it is narrower than the decorated row that already sized the column and "
        "cannot move it, so this is a sidebar label reporting its whole text as its minimum width (a "
        "lost PANGO_ELLIPSIZE_END on a user-text label, or a lost wrap on the fixed hint)")


def sidebar_row_settled(app, carrying=None, images=0, labels=0):
    """The settled sidebar row PROVABLY the one under test, or None while it is not in the tree yet.

    Never merely "the first list item reporting an extent": rows rebuild ASYNCHRONOUSLY while the model
    state flips as soon as the control call returns, so a stale accessible from before a rebuild and a
    freshly built but not-yet-decorated one both report an extent, and either would satisfy every
    assertion downstream against the wrong row. `carrying` pins the row's TEXT, `images`/`labels` its
    DECORATIONS; rows are SEARCHED, not indexed, so a stale sibling is skipped rather than measured.
    """
    for row in collect(app, role="list item"):
        if not window_extents(row):
            continue
        parts = [item for item in descendants(row) if window_extents(item)]
        roles = [item.get_role_name() for item in parts]
        if roles.count("image") < images or roles.count("label") < labels:
            continue
        if carrying is None or any((item.get_name() or "").startswith(carrying) for item in parts):
            return row
    return None


def sidebar_row_parts_fit(app, row, images=0, labels=0):
    """CONTAINMENT for every visible part of one sidebar row; returns how many it measured.

    ⚠️ The row's OWN box is deliberately NOT contained, and restoring that check fails this scenario on
    some libadwaita versions for a clip nobody can see: a `GtkListBoxRow`'s extents include the Adwaita
    `.navigation-sidebar > row` margin, empty space whose inset inside the column is theme-dependent. The
    parts are the reported symptom anyway — the bug pushed the status glyph, flag star and unseen badge
    out of the viewport.

    `images`/`labels` are re-asserted on the parts collected HERE, never inherited from the
    `sidebar_row_settled` poll that found the row: that poll walked an EARLIER collection, and an async
    `rebuildSidebar` in between leaves this one empty — the loop would then assert nothing while the
    caller still printed a success line. The column is resolved once for the whole row, which is the
    limit these parts were laid out under and one AT-SPI round trip instead of one per part.
    """
    column = wait_for(lambda: sidebar_column(app), "the sidebar column never allocated")
    parts = [(item, box) for item in descendants(row) if (box := window_extents(item))]
    roles = [item.get_role_name() for item, _ in parts]
    assert roles.count("image") >= images and roles.count("label") >= labels, (
        f"the sidebar row no longer exposes a fully built set of parts — rebuilt away before they could "
        f"be measured? {len(parts)} parts with extents ({roles.count('image')} images, "
        f"{roles.count('label')} labels), expected at least {images} images and {labels} labels")
    for item, box in parts:
        sidebar_fits(app, box, f"{item.get_role_name()} {(item.get_name() or '')[:32]!r}", column=column)
    return len(parts)


def sidebar_isolated_env(env, css=None):
    """`env` with an ISOLATED, empty `XDG_CONFIG_HOME`, optionally carrying one user `gtk-4.0/gtk.css`.

    Sidebar-geometry scenarios are made of width measurements, so none may inherit the developer's own
    `gtk-4.0/gtk.css` or `settings.ini`: a stray `min-width` on a sidebar label can quietly DISARM a gate
    rather than merely fail it. The optional `css` is the deliberate opposite — a stylesheet for a
    scenario that needs to move the measured minimum on any host, honoured at
    GTK_STYLE_PROVIDER_PRIORITY_USER (800), above the app's own sidebar provider.
    """
    config = os.path.join(env["AGTERM_STATE_DIR"], "xdg-config")
    gtk_config = os.path.join(config, "gtk-4.0")
    os.makedirs(gtk_config, exist_ok=True)
    user_css = os.path.join(gtk_config, "gtk.css")
    if css is None:
        if os.path.exists(user_css):
            os.remove(user_css)
    else:
        with open(user_css, "w", encoding="utf-8") as target:
            target.write(css)
    return dict(env, XDG_CONFIG_HOME=config)


def seed_legacy_sidebar_width(env, width, workspace_name, workspace_id, session_id):
    """Seed the legacy `workspaces.json` with one workspace, one session and a `sidebarWidth` request.

    `sidebarWidth` is per-window state in `windows/<uuid>.json` and that uuid does not exist before the
    FIRST launch of a state dir, so a narrow starting width can only be ASKED FOR through the legacy
    file, which `WindowLibrary` migrates while `windows.json` is absent — a later launch reads the
    migrated record instead, which makes a second call here inert. Callers pass 160,
    `AppStore.sidebarWidthMin`, the narrowest width the shared model will carry; the ids are fixed
    constants so a failing run's `describe_tree` output compares across runs.
    """
    with open(os.path.join(env["AGTERM_STATE_DIR"], "workspaces.json"), "w", encoding="utf-8") as target:
        json.dump({
            "version": 1,
            "sidebarWidth": width,
            "workspaces": [{
                "id": workspace_id,
                "name": workspace_name,
                "sessions": [{"id": session_id, "cwd": env["HOME"]}],
            }],
        }, target)


def verify_sidebar_narrow_clipping(env):
    """A narrow sidebar truncates fully decorated rows instead of overflowing its column.

    Regression cover for the shrink-clipping bug; the label sizing contract it gates — which sites
    ellipsize, which wraps, and which get nothing — is in `agterm-linux/docs/sidebar.md`. Three sites, one
    launch: the tree row's name (`makeNameWidget`), the flagged row's breadcrumb, and the wrapped
    flagged-empty hint, each checked BOTH ways — containment (`sidebar_row_parts_fit`, `sidebar_fits`)
    and no growth (`sidebar_does_not_widen`), neither redundant with the other.

    ⚠️ Driving the decorations REBUILDS the row, and GTK allocates a rebuilt widget only while the window
    is being rendered — always true under Xvfb, which is how this suite runs. On a live Wayland session
    `launch()` parks the window on a silent workspace and the frame clock stalls, so the settle polls
    below time out; run it as `env -u HYPRLAND_INSTANCE_SIGNATURE AGTERM_ATSPI_SCENARIO=…` there.
    """
    workspace_name = "narrow sidebar workspace"
    # Far longer than any sidebar column, so an un-ellipsized label reports a minimum hundreds of pixels
    # past it and the row overflows rather than truncating.
    session_name = "sidebar-clipping-regression-session-name"
    # The LARGEST sidebar font is what gives the flagged-empty hint's leg any discriminating power: its
    # longest LINE measures ~354px at 20pt, comfortably past the column, but already fits at the default.
    with open(os.path.join(env["AGTERM_STATE_DIR"], "settings.json"), "w", encoding="utf-8") as target:
        json.dump({"sidebarFontSize": 20}, target)
    # GTK floors this request at the sidebar's own minimum, which is the tightest column obtainable here.
    seed_legacy_sidebar_width(env, 160, workspace_name,
                              "4C2A1E80-6C1E-4C6B-9B2E-1B0A5F3D77A1",
                              "9E6D3F14-2B77-4A55-8C31-0D5E9A2B6C48")
    # This scenario compares measured widths, so the developer's own `gtk.css` must not be one of the
    # inputs — see `sidebar_isolated_env`.
    process, app = launch(sidebar_isolated_env(env))
    try:
        window_id = next(item["id"] for item in window_list(env) if item["open"])
        session_id = window_tree(env, window_id)["workspaces"][0]["sessions"][0]["id"]
        control_json(env, "session", "flag", "on", "--target", session_id, "--json")
        control_json(env, "session", "status", "blocked", "--target", session_id, "--json")
        # `unseenCount` and `agentIndicator` are EPHEMERAL — SessionSnapshot carries neither — so badge
        # and status glyph can only be driven at runtime, and the session must NOT be re-selected
        # afterwards, because AppStore.selectSession zeroes unseenCount.
        control_json(env, "notify", "--title", "clipping", "narrow sidebar",
                     "--target", session_id, "--window", window_id, "--json")

        def decorated():
            session = window_tree(env, window_id)["workspaces"][0]["sessions"][0]
            return (session.get("status") == "blocked" and session.get("flagged")
                    and session.get("unseen", 0) > 0)

        wait_for(decorated, "session never took the status, flag and unseen-badge decorations")
        # Tree mode: terminal icon and flag star are the two images; the name, the status glyph (a
        # GtkLabel, not a GtkImage — `LinuxStatusGlyph.makeStatusGlyph`) and the unseen badge the three
        # labels. `decorated()` polls the MODEL and the sidebar rebuild LAGS it, so wait on the parts
        # themselves: a yardstick read off the still-undecorated row would be too narrow.
        wait_for(lambda: sidebar_row_settled(app, images=2, labels=3),
                 "the sidebar row never rebuilt with the status glyph, flag star and unseen badge")
        # The YARDSTICK for every `sidebar_does_not_widen` below, captured with the row FULLY decorated
        # but its name still short: the decorations are legitimate chrome a column following its content
        # may widen for, so a baseline taken before them would report that growth as a regression.
        baseline = wait_for(lambda: sidebar_column(app), "the sidebar column never allocated").width

        # Only NOW rename, so the long name is the SINGLE variable between the baseline and the checks.
        control_json(env, "session", "rename", session_name, "--target", session_id, "--json")
        row = wait_for(lambda: sidebar_row_settled(app, session_name, images=2, labels=3),
                       "no rebuilt sidebar row carrying the long session name reported a settled, fully "
                       "decorated extent")
        tree_parts = sidebar_row_parts_fit(app, row, images=2, labels=3)
        sidebar_does_not_widen(app, baseline, "the long tree-row name")

        # Flagged mode renders the sidebar's LONGEST string, the "<session>  —  <workspace>" breadcrumb,
        # through a different label site than makeNameWidget; its flag star is suppressed (every row is
        # flagged), so only the terminal icon remains.
        control_json(env, "sidebar", "mode", "flagged", "--json")
        breadcrumb = f"{session_name}  —  {workspace_name}"
        # Filtered by the BREADCRUMB, not just by role: a tree-mode row still in the accessibility tree
        # carries 2 images and 3 labels, so it satisfies these counts and would pass containment while
        # the breadcrumb site this leg exists to gate went unmeasured.
        flagged_row = wait_for(lambda: sidebar_row_settled(app, breadcrumb, images=1, labels=3),
                               "the flagged view never rebuilt a settled row carrying the breadcrumb")
        flagged_parts = sidebar_row_parts_fit(app, flagged_row, images=1, labels=3)
        sidebar_does_not_widen(app, baseline, "the flagged breadcrumb")

        control_json(env, "session", "flag", "off", "--target", session_id, "--json")
        hint_box = wait_for(lambda: sidebar_settled_label(app, "No flagged sessions"),
                            "the empty flagged view never rebuilt its hint")
        sidebar_fits(app, hint_box, "the flagged-empty hint")
        # The empty view drops the rows entirely, so the column can only be NARROWER than the yardstick
        # — unless the hint stopped wrapping and started reporting its longest LINE.
        sidebar_does_not_widen(app, baseline, "the flagged-empty hint")
        print(f"OK: decorated sidebar rows truncate inside the narrow column and never widen it "
              f"({tree_parts} tree parts, {flagged_parts} flagged parts and the wrapped empty-state "
              f"hint all inside the {baseline}px column the decorated short-named row sized)")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


# `AppStore.sidebarWidthDefault` — the width the floor pins to while the content fits inside it.
SIDEBAR_PIN_WIDTH = 220
# A saved request above the pin and below `AppStore.sidebarWidthMax` (560), so the window-width leg can
# be capped from above with neither the floor nor the shared maximum interfering.
SIDEBAR_REQUESTED_WIDTH = 400


def sidebar_window_frame_width(app):
    """The toplevel frame's own allocated width, or None while it is unallocated.

    The window-width leg's PRECONDITION, read off the FRAME so a compositor declining the resize stays
    distinguishable from the regression that leg gates. The WIDEST frame is the toplevel.
    """
    widths = [box.width for node in collect(app, role="frame") if (box := window_extents(node))]
    return max(widths) if widths else None


def sidebar_column_settled(app, accept):
    """The sidebar column's width once two reads 0.1s apart agree AND `accept` takes it, else None.

    `accept` is REQUIRED: the pre-transition value is itself stable, so without a predicate `wait_for`
    returns the seeded width and the caller fails hard instead of polling on. Re-read per assertion and
    never hoisted — every step below re-measures the floor and re-lays the divider.
    """
    first = sidebar_column(app)
    if first is None:
        return None
    time.sleep(0.1)
    second = sidebar_column(app)
    if second is None or second.width != first.width:
        return None
    return first.width if accept(first.width) else None


def sidebar_width_record(state, width=None):
    """The per-window record's path, after optionally patching its `sidebarWidth` to `width`.

    Launch 1 has no window record yet — `sidebarWidth` is per-window state in `windows/<uuid>.json` — so
    it seeds through the legacy `workspaces.json` and `WindowLibrary` migrates it; every later launch
    patches the migrated record through here.
    """
    windows = os.path.join(state, "windows")
    records = [os.path.join(windows, name) for name in sorted(os.listdir(windows))
               if name.endswith(".json")]
    assert len(records) == 1, (
        f"expected exactly one window record under {windows}, found {len(records)} — the file this "
        "patches and the file the on-disk assertions read are only the same one while there is one")
    path = records[0]
    if width is not None:
        with open(path, encoding="utf-8") as source:
            record = json.load(source)
        record["sidebarWidth"] = width
        with open(path, "w", encoding="utf-8") as target:
            json.dump(record, target)
    return path


def verify_sidebar_width_floor(env):
    """The sidebar's ONE derived width floor: it PINS at the default width, FOLLOWS the measured content
    once that stops fitting, and never lets the LAYOUT overwrite the saved request.

    The contract, and what makes each of the five launches non-redundant, is the width-floor section of
    `agterm-linux/docs/sidebar.md`. Every leg asserts a width the app CHOSE, which is what makes them
    discriminating; `SIDEBAR_EDGE_SLACK` appears throughout as a PIXEL-EQUALITY tolerance, because these
    legs compare the SCROLLER's width against a number applied to the paned start child above it.

    Launches 1-3 seed `toolbarMode: hidden`, the smallest sidebar font, and an isolated `XDG_CONFIG_HOME`
    so the content floor alone holds the column open and no host theming reaches an exact-pixel
    assertion. Launch 4 puts the header back deliberately — see it for why.
    """
    state = env["AGTERM_STATE_DIR"]
    settings_path = os.path.join(state, "settings.json")
    seed_legacy_sidebar_width(env, 160, "width floor workspace",
                              "7B1D4E62-0F3A-4D18-9C55-3E7A2B6F91C0",
                              "1A9C5D30-8E42-4B77-A0F6-2D8B4C1E5093")
    # GTK reads overlay scrolling from the ENVIRONMENT as well as GtkSettings, so a host that already
    # exports 0 would make launches 2 and 2b identical and the scrollbar leg could never fail.
    overlay_env = dict(env, GTK_OVERLAY_SCROLLING="1")

    def seed_settings(**overrides):
        # Merge rather than clobber, so a first-run settings write is not silently reset.
        settings = {}
        if os.path.exists(settings_path):
            with open(settings_path, encoding="utf-8") as source:
                settings = json.load(source)
        settings.update({"toolbarMode": "hidden", "sidebarFontSize": 9, **overrides})
        with open(settings_path, "w", encoding="utf-8") as target:
            json.dump(settings, target)

    # LAUNCH 1 — the PIN gate. The store holds a 160px request and the layout refuses it, because the
    # floor pins at the default width whatever the request says.
    seed_settings()
    process, app = launch(sidebar_isolated_env(overlay_env))
    try:
        # The predicate carries the SAME slack the assertion does, and still excludes the seeded 160.
        pinned = wait_for(
            lambda: sidebar_column_settled(
                app, lambda width: width >= SIDEBAR_PIN_WIDTH - SIDEBAR_EDGE_SLACK),
            f"the sidebar column never settled at or above the {SIDEBAR_PIN_WIDTH}px pin — it stayed at "
            "the seeded 160px request, so nothing floored it")
        # SLACK, not equality: `pinned` is the SCROLLER's width, the floor a request on the view above it.
        assert abs(pinned - SIDEBAR_PIN_WIDTH) <= SIDEBAR_EDGE_SLACK, (
            f"the sidebar laid out at {pinned}px, not the {SIDEBAR_PIN_WIDTH}px "
            "`AppStore.sidebarWidthDefault` the floor pins to while the measured content fits inside "
            "it — that is a SECOND width constraint on the sidebar tree (a `gtk_widget_set_size_request` "
            "that came back) binding ahead of the derived floor")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)

    # LAUNCH 2 — the MEASUREMENT gate. The lever is a user `gtk-4.0/gtk.css` in the isolated
    # XDG_CONFIG_HOME, honoured at GTK_STYLE_PROVIDER_PRIORITY_USER (800), above the app's own sidebar
    # provider. `min-width` in px, so the raised minimum is identical on every host, font family and text
    # scale, and stays under `AppStore.sidebarWidthMax` (560).
    sidebar_width_record(state, 160)
    seed_settings()
    process, app = launch(
        sidebar_isolated_env(overlay_env, ".agterm-sidebar label { min-width: 300px; }\n"))
    try:
        window_id = next(item["id"] for item in window_list(env) if item["open"])
        session_id = window_tree(env, window_id)["workspaces"][0]["sessions"][0]["id"]
        measured = wait_for(
            lambda: sidebar_column_settled(app, lambda width: width > SIDEBAR_PIN_WIDTH),
            f"the sidebar stayed at or below the {SIDEBAR_PIN_WIDTH}px pin while its content needs more "
            "— the floor is no longer following `gtk_widget_measure` (a constant, or a measure pointed "
            "at the wrong widget: the scroller measures ~46px, the sidebar box is the widest sidebar "
            "site by construction)")
        # Decorating the row adds two more labels the lever pins at 300px each, so the content minimum
        # jumps and the floor has to follow it — the shared `rebuildSidebar` -> `refreshSidebarWidthFloor`
        # path every re-measure ends in, and the only half an Xvfb session can drive.
        control_json(env, "session", "status", "blocked", "--target", session_id, "--json")
        control_json(env, "notify", "--title", "floor", "width floor",
                     "--target", session_id, "--window", window_id, "--json")

        def decorated():
            session = window_tree(env, window_id)["workspaces"][0]["sessions"][0]
            return session.get("status") == "blocked" and session.get("unseen", 0) > 0

        wait_for(decorated, "session never took the status and unseen-badge decorations")
        regrown = wait_for(
            lambda: sidebar_column_settled(app, lambda width: width > measured),
            f"the sidebar stayed at {measured}px after the row grew two more 300px labels — the floor "
            "was measured once when the split was built instead of at the end of every "
            "`rebuildSidebar`, so a desktop font or text-scale change would leave the sidebar clipped "
            "for the rest of the session")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)

    # LAUNCH 2b — the SCROLLBAR gate: launch 2's configuration with one env var flipped, so `measured` is
    # the baseline and a non-overlay bar taking width out of the viewport is the ONLY difference.
    sidebar_width_record(state, 160)
    seed_settings()
    process, app = launch(sidebar_isolated_env(
        dict(env, GTK_OVERLAY_SCROLLING="0"), ".agterm-sidebar label { min-width: 300px; }\n"))
    try:
        widened = wait_for(
            lambda: sidebar_column_settled(app, lambda width: width > measured + SIDEBAR_EDGE_SLACK),
            f"the sidebar settled at the same {measured}px it did with overlay scrollbars, so the floor "
            "carries no scrollbar term — the bar now takes ~15px out of the viewport and carries the "
            "row's trailing badge exactly that far past the right edge, the clipping the floor exists to "
            "prevent")
        # A BAND, not a floor: 8px of slack against a ~15px signal is loose enough that an unrelated
        # difference would also clear the lower bound, so cap the delta at a few times the bar's width.
        assert widened <= measured + 40, (
            f"the sidebar widened from {measured}px to {widened}px, far past the ~15px a non-overlay "
            "vertical scrollbar takes out of the viewport — these two launches differ only in "
            "GTK_OVERLAY_SCROLLING, so something other than the scrollbar term moved the column and "
            "this leg is no longer measuring what it names")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)

    # LAUNCH 3 — the WINDOW-WIDTH gate, the only cover for `notify::max-position`: GTK emits no
    # `notify::position` when the window widens again, so without that handler the divider stays at the
    # narrow window's cap. No `gtk.css` lever, so the floor is the plain pin and the request sits above it.
    sidebar_width_record(state, SIDEBAR_REQUESTED_WIDTH)
    seed_settings()
    process, app = launch(sidebar_isolated_env(overlay_env))
    try:
        window_id = next(item["id"] for item in window_list(env) if item["open"])

        def at_request(width):
            return abs(width - SIDEBAR_REQUESTED_WIDTH) <= SIDEBAR_EDGE_SLACK

        wait_for(lambda: sidebar_column_settled(app, at_request),
                 f"the sidebar never restored its saved {SIDEBAR_REQUESTED_WIDTH}px request")

        def resize(width):
            control_json(env, "window", "resize", window_id,
                         "--width", str(width), "--height", "700", "--json")

        wide_window = wait_for(lambda: sidebar_window_frame_width(app),
                               "the window frame never reported an allocation")
        resize(360)

        def narrowed_window():
            width = sidebar_window_frame_width(app)
            return width if width is not None and width < wide_window - SIDEBAR_EDGE_SLACK else None

        # The PRECONDITION is read off the FRAME, never inferred from the sidebar: `window.resize` is
        # `gtk_window_set_default_size` and a Wayland compositor may decline it, which asking the sidebar
        # would conflate with the very regression this leg is the SOLE cover for — printing SKIP and
        # passing. It does take under the Xvfb + openbox session, where this gate is authoritative.
        narrowed = wait_for(narrowed_window, "the window never narrowed", timeout=8, required=False)
        if narrowed is None:
            capped = None
            print(f"SKIP: the compositor kept the window at {wide_window}px instead of the 360px asked "
                  "for, so the sidebar cannot be capped and the widen-restores-the-request cycle cannot "
                  "run here (it runs under the Xvfb + openbox session CI uses)")
        else:
            capped = wait_for(
                lambda: sidebar_column_settled(
                    app, lambda width: width < SIDEBAR_REQUESTED_WIDTH - SIDEBAR_EDGE_SLACK),
                f"the window narrowed from {wide_window}px to {narrowed}px and the sidebar column held "
                f"its {SIDEBAR_REQUESTED_WIDTH}px request anyway — `applySidebarWidth` is not capping at "
                "GtkPaned's `max-position`, so it re-asserts the over-wide position from inside GtkPaned's"
                " own `size_allocate`, where GTK does not re-clamp it, and the sidebar overhangs the "
                "window", timeout=8)
            resize(1100)
            wait_for(lambda: sidebar_column_settled(app, at_request),
                     f"the sidebar stayed at the narrow window's {capped}px cap after the window "
                     f"widened again instead of returning to its {SIDEBAR_REQUESTED_WIDTH}px request — "
                     "`notify::position` does not fire for a widening, so `notify::max-position` is the "
                     "only signal that can pull the divider back up")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)
    # Read AFTER the quit: the 0.4s save debouncer only guarantees a current record once the SIGTERM
    # flush has run. Guarded on `capped`, since without it the divider provably never moved.
    record_path = sidebar_width_record(state)
    if capped is None:
        saved = None
    else:
        with open(record_path, encoding="utf-8") as source:
            saved = json.load(source).get("sidebarWidth")
        assert saved == SIDEBAR_REQUESTED_WIDTH, (
            f"the saved sidebar width is {saved}px, not the {SIDEBAR_REQUESTED_WIDTH}px request — the "
            f"narrow window's {capped}px `max-position` cap was persisted over the request, which "
            "destroys it for good: nothing restores a width the store no longer remembers")

    # LAUNCH 4 — the WIRING gate: `captureSidebarWidth` must weigh the divider against
    # `sidebarEffectiveMinimum`, not the content floor. The launches above HIDE the sidebar header, which
    # leaves the two numbers EQUAL, so three levers separate them here — a 160px request, so the minimum
    # rather than the request decides; `.agterm-sidebar-column headerbar`, lifting the VISIBLE sidebar
    # header's minimum to ~310px without touching the content floor (it is an `AdwToolbarView` top bar,
    # not a child of `sidebarBox`); and `.agterm-sidebar row label`, driving the content floor to ~404px
    # in tree mode. Flagged mode with nothing flagged then empties the list — the wrapped hint is a bare
    # label the second lever misses — and the floor drops back to the 220px pin while the header holds
    # the minimum at 310. That is the one moment the two candidates disagree; see the rule's wiring
    # bullet for the half this cannot cover.
    record_path = sidebar_width_record(state, 160)
    seed_settings(toolbarMode="normal")
    process, app = launch(sidebar_isolated_env(
        overlay_env, ".agterm-sidebar-column headerbar { min-width: 300px; }\n"
                     ".agterm-sidebar row label { min-width: 300px; }\n"))
    try:
        wide = wait_for(
            lambda: sidebar_column_settled(app, lambda width: width > SIDEBAR_PIN_WIDTH),
            "the sidebar never rose above the pin in tree mode, so the row-label lever never reached the "
            "content floor and the mode switch below would not move the divider")
        control_json(env, "sidebar", "mode", "flagged", "--json")
        bound = wait_for(
            lambda: sidebar_column_settled(app, lambda width: width < wide - SIDEBAR_EDGE_SLACK),
            f"the sidebar stayed at {wide}px after flagged mode emptied the list — the floor did not "
            "fall back to the pin, so the divider never moved and this leg cannot see the wiring")
        assert bound > SIDEBAR_PIN_WIDTH + SIDEBAR_EDGE_SLACK, (
            f"the sidebar fell all the way to {bound}px, at or below the {SIDEBAR_PIN_WIDTH}px pin — the "
            "raised `headerbar` minimum never reached the paned start child, so the effective minimum "
            "and the content floor are the same number here and the assertion below cannot fail")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)
    with open(record_path, encoding="utf-8") as source:
        requested = json.load(source).get("sidebarWidth")
    assert requested == 160, (
        f"the saved sidebar width is {requested}px, not the 160px request — the divider settled at "
        f"{bound}px, held there by the start child's minimum rather than by the request, and that LAYOUT "
        "position was persisted over the request. `captureSidebarWidth` is reasoning with the content "
        f"floor ({SIDEBAR_PIN_WIDTH}px here) instead of `sidebarEffectiveMinimum`, so GTK's clamp up to "
        "the real minimum reads as a drag — the user's saved width is destroyed on any client-side-"
        "decorated desktop, and no unit test can see it")
    narrow_leg = (f"survives the narrow window's {capped}px cap" if capped is not None
                  else "SKIPPED the compositor-dependent narrow-window cycle")
    print(f"OK: the sidebar width floor pins at {SIDEBAR_PIN_WIDTH}px, follows its measured content to "
          f"{measured}px, re-measures to {regrown}px when the row grows, widens to {widened}px for a "
          f"non-overlay scrollbar, the saved {SIDEBAR_REQUESTED_WIDTH}px request {narrow_leg}, and a "
          f"160px request survives a {bound}px effective minimum instead of being overwritten by it")


def verify_preferences_pages(env, home):
    process, app = launch(env)
    try:
        focus_window(process.pid)
        assert not named(app, "Main Menu"), "Preferences test found the removed Main Menu button"
        wait_for(
            lambda: named(app, "Right-click pastes"),
            "Preferences did not expose the corrected Right-click pastes row",
        )
        for page in ["General", "Appearance", "Notifications", "Agent Status", "Key Mapping", "Integrations"]:
            assert named(app, page), f"Preferences page {page!r} is missing"

        wait_for(lambda: actionable(app, "Right-click pastes"), "Right-click switch is not actionable")
        stop(process)
        process = None
        os.makedirs(os.path.join(home, ".pi/agent"))
        env = dict(
            env,
            AGTERM_APP_ID=env["AGTERM_APP_ID"] + ".integrations",
            AGTERM_ATSPI_OPEN_PREFERENCES="integrations",
        )
        process, app = launch(env)
        window_title = wait_for(
            lambda: next((item.get_name() for item in collect(app, role="frame") if item.get_name()), None),
            "integration test window title is missing",
        )
        pi_row = wait_for(lambda: named(app, "Pi Extension"), "Pi integration row is missing")
        pi_install = wait_for(
            lambda: next((item for item in descendants(pi_row) if item.get_name() == "Install"), None),
            "Pi extension did not become installable",
        )
        activate(pi_install)
        wait_for(lambda: named(app, "Apply Integration Changes?"), "Pi hooks preflight was not shown")
        pi_extension = os.path.join(home, ".pi/agent/extensions/agterm-status.ts")
        assert not os.path.exists(pi_extension), "Pi preflight mutated HOME"
        wait_for(lambda: actionable(app, "Apply"), "Pi hooks preflight has no Apply action")
        press_return(process.pid, window_title=window_title)
        wait_for(lambda: os.path.exists(pi_extension), "Pi extension was not installed")
        with open(pi_extension, encoding="utf-8") as source:
            assert "// agterm-pi-status-extension" in source.read(), "Pi ownership marker is missing"
        wait_for(lambda: named(app, "Integration Updated"), "Pi hooks result was not shown")
        wait_for(lambda: actionable(app, "OK"), "Pi hooks result has no OK action")
        press_escape(process.pid, window_title=window_title)
        wait_for(
            lambda: next((item for item in descendants(pi_row) if item.get_name() == "Current"), None),
            "Pi row did not refresh to Current",
        )

        skill_row = wait_for(
            lambda: named(app, "Agent Skill", role="list item"),
            "Agent Skill integration row is missing",
        )
        install = wait_for(
            lambda: next((item for item in descendants(skill_row) if item.get_name() == "Install"), None),
            "Agent Skill did not become installable",
        )
        activate(install)
        wait_for(lambda: named(app, "Apply Integration Changes?"), "integration preflight was not shown")
        assert not os.path.exists(os.path.join(home, ".claude/skills/agterm")), "preflight mutated HOME"
        stop(process)
        process = None
        assert not os.path.exists(os.path.join(home, ".claude/skills/agterm")), "closing preflight mutated HOME"

        subprocess.run(
            [CTL, "integration", "install", "skill"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        wait_for(
            lambda: os.path.exists(os.path.join(home, ".claude/skills/agterm/SKILL.md"))
            and os.path.exists(os.path.join(home, ".codex/skills/agterm/SKILL.md")),
            "safe skill installation did not write both isolated destinations",
        )
        assert os.path.realpath(home) not in os.path.realpath(os.path.expanduser("~/.claude")), "test HOME is not isolated"
        print("OK: Preferences pages, Pi hooks preflight/apply, and safe skill install")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        if process is not None:
            stop(process)


def verify_hidden_toolbar(env, state):
    settings_path = os.path.join(state, "settings.json")
    settings = {}
    if os.path.exists(settings_path):
        with open(settings_path, encoding="utf-8") as source:
            settings = json.load(source)
    settings["toolbarMode"] = "hidden"
    with open(settings_path, "w", encoding="utf-8") as destination:
        json.dump(settings, destination)

    process, app = launch(env)
    try:
        assert not named(app, "Main Menu"), "hidden toolbar still exposes the header menu"
        window_id = next(item["id"] for item in window_list(env) if item["open"])
        control_json(env, "dashboard", "--mru", "--window", window_id, "--json")
        wait_for(
            lambda: window_tree(env, window_id).get("dashboardMembers"),
            "hidden-toolbar dashboard did not open over control",
        )
        assert not named(app, "Exit Dashboard", role="button"), (
            "hidden toolbar exposed the dashboard modal header"
        )
        control_json(env, "dashboard", "--close", "--window", window_id, "--json")
        control_json(
            env, "surface", "zoom", "show", "--target", "active",
            "--window", window_id, "--json",
        )
        wait_for(
            lambda: window_tree(env, window_id).get("zoomedSurface"),
            "hidden-toolbar terminal zoom did not open",
        )
        assert not named(app, "Exit Terminal Zoom", role="button"), (
            "hidden toolbar exposed the terminal-zoom modal header"
        )
        control_json(
            env, "surface", "zoom", "hide", "--target", "active",
            "--window", window_id, "--json",
        )
        assert not preferences_window(app), "Preferences was open before hidden-toolbar shortcut"
        focus_window(process.pid)
        press_ctrl_comma(process.pid)
        wait_for(
            lambda: preferences_window(app),
            "Ctrl+, did not open Preferences with toolbar hidden",
        )
        print("OK: hidden modal chrome stays hidden and Preferences remains keyboard-accessible")
    finally:
        stop(process)


def verify_session_pickers(env, state):
    settings_path = os.path.join(state, "settings.json")
    with open(settings_path, "w", encoding="utf-8") as destination:
        json.dump({"attentionButtonEnabled": True}, destination)

    process, app = launch(env)
    try:
        tree = control_json(env, "tree", "--json")["result"]["tree"]
        original_id = tree["workspaces"][0]["sessions"][0]["id"]
        subprocess.run(
            [CTL, "session", "new", "--socket", env["AGTERM_CONTROL_SOCKET"]],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        subprocess.run(
            [
                CTL, "session", "status", "blocked", "--target", original_id,
                "--socket", env["AGTERM_CONTROL_SOCKET"],
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )

        recent = wait_for(
            lambda: actionable(app, "Recent Sessions (Ctrl+Tab)"),
            "Recent Sessions button is missing or not actionable",
        )
        activate(recent)
        recent_row = wait_for(
            lambda: next(
                (
                    item for item in collect(app, role="button")
                    if "workspace 1 ·" in (item.get_name() or "")
                ),
                None,
            ),
            "Recent Sessions popover did not expose a session row",
        )
        activate(recent_row)
        wait_for(
            lambda: actionable(app, "Show sessions that need attention (Ctrl+Shift+I)"),
            "Attention button is missing or not actionable",
        )
        activate(actionable(app, "Show sessions that need attention (Ctrl+Shift+I)"))
        wait_for(
            lambda: next(
                (
                    item for item in collect(app, role="button")
                    if "workspace 1 ·" in (item.get_name() or "")
                ),
                None,
            ),
            "Attention popover did not expose a session row",
        )
        print("OK: recent-session and attention popovers expose actionable rows")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_auto_follow(env, state):
    auto_state = state + "-auto-follow"
    os.makedirs(auto_state)
    auto_env = dict(
        env,
        AGTERM_STATE_DIR=auto_state,
        AGTERM_CONTROL_SOCKET=os.path.join(auto_state, "agterm.sock"),
        AGTERM_APP_ID="io.github.melonamin.agterm.atspi.autofollow",
    )
    with open(os.path.join(auto_state, "settings.json"), "w", encoding="utf-8") as destination:
        json.dump({"autoFollowAttention": "s5"}, destination)

    process, app = launch(auto_env)
    try:
        tree = control_json(auto_env, "tree", "--json")["result"]["tree"]
        blocked_id = tree["workspaces"][0]["sessions"][0]["id"]
        subprocess.run(
            [CTL, "session", "new", "--socket", auto_env["AGTERM_CONTROL_SOCKET"]],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=auto_env,
        )
        def set_status(status):
            subprocess.run(
                [
                    CTL, "session", "status", status, "--target", blocked_id,
                    "--socket", auto_env["AGTERM_CONTROL_SOCKET"],
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=auto_env,
            )

        def auto_followed():
            sessions = control_json(auto_env, "tree", "--json")["result"]["tree"]["workspaces"][0]["sessions"]
            return next((session for session in sessions if session["id"] == blocked_id), {}).get("active")

        wait_for(
            lambda: preferences_window(app),
            "startup Preferences dialog did not open for auto-follow test",
        )
        set_status("blocked")
        time.sleep(6)
        assert not auto_followed(), "auto-follow changed sessions while Preferences was open"
        print("OK: GTK/GLib auto-follow pauses for Preferences")
    finally:
        stop(process)


def main():
    for path in (BIN, CTL):
        if not os.path.exists(path):
            print(f"FAIL: required build product is missing: {path}")
            return 2

    scenario = os.environ.get("AGTERM_ATSPI_SCENARIO")
    if scenario is None:
        failures = []
        for child_scenario in (
            "normal", "upstream-controls", "dashboard-modal", "context-menu",
            "split-exit", "window-ownership", "preferences-pages",
            "notification-reveal", "notification-focus", "session-pickers", "child-gdk-env",
            "child-gdk-env-inverted",
            "custom-command-failures", "surface-lifetimes", "surface-failures",
            "sidebar-row-height",
            "sidebar-narrow-clipping",
            "sidebar-width-floor",
            "auto-follow", "hidden-toolbar",
        ):
            child_env = dict(os.environ, AGTERM_ATSPI_SCENARIO=child_scenario)
            result = subprocess.run([sys.executable, __file__], env=child_env)
            if result.returncode != 0:
                failures.append((child_scenario, result.returncode))
        if failures:
            print("FAILED: " + ", ".join(f"{name} ({code})" for name, code in failures))
            return failures[0][1]
        print("PASS")
        return 0

    root = tempfile.mkdtemp(prefix="agterm-atspi-")
    home = os.path.join(root, "home")
    state = os.path.join(root, "state")
    os.makedirs(os.path.join(home, ".claude"))
    os.makedirs(os.path.join(home, ".codex"))
    os.makedirs(state)
    socket = os.path.join(state, "agterm.sock")
    env = dict(
        os.environ,
        HOME=home,
        AGTERM_STATE_DIR=state,
        AGTERM_CONTROL_SOCKET=socket,
        AGTERM_RESOURCE_ROOT=RESOURCE_ROOT,
        AGTERM_APP_ID=f"io.github.melonamin.agterm.atspi.{scenario.replace('-', '_')}",
        PATH="/usr/bin:/bin",
    )
    # Keep ordinary scenarios free of ambient renderer overrides. The dedicated inversion scenario installs
    # a deterministic `all` fixture after this scrub and proves both the app's normalization and child restore.
    for gdk_variable in ("GDK_DISABLE", "GDK_DEBUG"):
        env.pop(gdk_variable, None)
    inverted_assignment = None
    if scenario == "child-gdk-env-inverted":
        variable, required, original, normalized = gdk_inversion_fixture(env)
        env[variable] = original
        normalized_tokens = set(normalized.lower().split(","))
        assert "all" in normalized_tokens
        assert not normalized_tokens.intersection(required)
        inverted_assignment = f"agterm: setting {variable}={normalized}"
    if scenario in ("preferences-pages", "auto-follow"):
        # Page inspection and auto-follow need an already-mapped modal while another process owns focus.
        env["AGTERM_ATSPI_OPEN_PREFERENCES"] = "general"
    try:
        Atspi.init()
        if scenario == "normal":
            verify_normal_toolbar(env, state, home)
        elif scenario == "upstream-controls":
            verify_upstream_control_parity(env)
        elif scenario == "dashboard-modal":
            verify_dashboard_modal(env)
        elif scenario == "context-menu":
            verify_context_menu(env)
        elif scenario == "split-exit":
            verify_split_exit_sidebar(env)
        elif scenario == "window-ownership":
            verify_window_callback_ownership(env)
        elif scenario == "notification-reveal":
            verify_notification_reveal(env)
        elif scenario == "notification-focus":
            verify_notification_focus_policy(env)
        elif scenario == "child-gdk-env":
            verify_child_gdk_environment(env)
        elif scenario == "child-gdk-env-inverted":
            verify_child_gdk_environment(env, inverted_assignment)
        elif scenario == "notification-banner":
            verify_notification_banner_round_trip(env)
        elif scenario == "custom-command-failures":
            verify_custom_command_failures(env)
        elif scenario == "surface-lifetimes":
            verify_surface_configuration_lifetimes(env)
        elif scenario == "surface-failures":
            verify_surface_failure_diagnostics(env)
        elif scenario == "sidebar-row-height":
            verify_sidebar_row_height_follows_font_size(env)
        elif scenario == "sidebar-narrow-clipping":
            verify_sidebar_narrow_clipping(env)
        elif scenario == "sidebar-width-floor":
            verify_sidebar_width_floor(env)
        elif scenario == "preferences-pages":
            verify_preferences_pages(env, home)
        elif scenario == "auto-follow":
            verify_auto_follow(env, state)
        elif scenario == "session-pickers":
            verify_session_pickers(env, state)
        elif scenario == "hidden-toolbar":
            verify_hidden_toolbar(env, state)
        else:
            raise ValueError(f"unknown AT-SPI scenario: {scenario}")
        print(f"PASS: {scenario}")
        return 0
    except (AssertionError, subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"FAIL: {error}")
        return 1
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
