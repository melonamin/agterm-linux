"""Real SSH coverage for companion following, workspace placement, remote paste and openers."""

from pathlib import Path
import os
import shlex
import time

from atspi_smoke import collect, mouse_click, sidebar_column, wait_for, window_extents
from atspi_v0441 import ClipboardOwner


def verify_v0441_remote(origin_env, viewer_env, viewer, app, window, root, request):
    def local_tree():
        return request(viewer_env, 'tree', args={'window': window})['tree']

    def rows():
        return [row for workspace in local_tree()['workspaces'] for row in workspace['sessions']]

    def origin_row(identity):
        return next((row for row in rows() if row.get('remoteSessionID') == identity), None)

    received = root / 'origin-paste-input'
    script = 'stty -echo; cat > ' + shlex.quote(str(received))
    parent = request(origin_env, 'session.new', args={'name': 'Follow parent', 'command': '/bin/sh -c ' + shlex.quote(script)})['id']
    old = request(origin_env, 'session.companion.new', parent, {'name': 'Existing companion'})['id']
    attached = request(viewer_env, 'zmx.attach', parent, {'host': 'local-test', 'window': window,
        'workspaceName': 'SSH placement', 'createWorkspace': True})['id']
    wait_for(lambda: (origin_row(parent) or {}).get('followsCompanions'), 'attached parent did not baseline companions', timeout=30)
    assert not origin_row(old), 'existing companion was attached without an explicit group attach'
    workspace = next(workspace for workspace in local_tree()['workspaces'] if workspace['name'] == 'SSH placement')
    assert attached in [row['id'] for row in workspace['sessions']]
    child = request(origin_env, 'session.companion.new', parent, {'name': 'New followed companion'})['id']
    wait_for(lambda: (origin_row(child) or {}).get('parent') == attached, 'new terminal companion was not followed', timeout=30)
    assert next(row['id'] for row in rows() if row.get('active')) == attached, 'following stole the selection'
    moved = request(origin_env, 'session.new', args={'name': 'Moved origin row'})['id']
    request(origin_env, 'session.companion.move', moved, {'parent': parent})
    wait_for(lambda: (origin_row(moved) or {}).get('parent') == attached, 'moved terminal companion was not followed', timeout=30)
    html = root / 'followed.html'
    html.write_text('<title>Followed page</title><h1>Followed page over SSH</h1>')
    page = request(origin_env, 'session.companion.page', parent, {'html': str(html), 'cwd': str(root)})['id']
    wait_for(lambda: (origin_row(page) or {}).get('parent') == attached, 'new page companion was not followed', timeout=30)
    wait_for(lambda: (origin_row(page) or {}).get('htmlOverlays', [{}])[0].get('state') == 'loaded', 'followed page did not load', timeout=30)
    explicit = request(viewer_env, 'session.companion.new', attached, {'name': '--dash child'})['id']
    time.sleep(1)
    assert len([row for row in rows() if row.get('name') == '--dash child']) == 1, 'explicit creation raced automatic following'
    assert any(row['id'] == explicit for row in rows())

    source = root / 'paste file.txt'
    source.write_text('remote paste bytes\n')
    folder = root / 'paste-folder'
    folder.mkdir()
    (folder / 'nested.txt').write_text('nested bytes\n')
    owner = ClipboardOwner(viewer_env, root, 'text/uri-list', (source.as_uri() + '\r\n' + folder.as_uri() + '\r\n').encode())
    try:
        request(viewer_env, 'session.select', attached)
        request(viewer_env, 'session.paste', attached)
        request(viewer_env, 'session.type', attached, {'text': '\n'})
        wait_for(lambda: received.exists() and received.read_text().strip(), 'remote paste paths did not enter the origin program')
        paths = [Path(path) for path in shlex.split(received.read_text().strip())]
        assert len(paths) == 2 and paths[0] != source and paths[1] != folder, paths
        assert paths[0].read_bytes() == source.read_bytes()
        assert (paths[1] / 'nested.txt').read_bytes() == (folder / 'nested.txt').read_bytes()
    finally:
        owner.close()

    clicked = root / 'remote-opener.txt'
    clicked.write_text('remote opener snapshot\n')
    marker = root / 'remote-opened-context'
    keymap = Path(viewer_env['AGTERM_STATE_DIR'], 'config/keymap.conf')
    keymap.write_text('open *.txt printf \'%s\\n\' "$AGT_PATH" > ' + shlex.quote(str(marker)) + '\n')
    request(viewer_env, 'keymap.reload')
    assert request(viewer_env, 'keymap.list')['keymap'].get('openers'), 'remote opener rule was dropped'
    # Keep the printed link on one terminal line; the origin resolves it against the pane's actual cwd.
    printed_path = './remote-opener.txt'
    script = "printf '\\033[2J\\033[H%s' " + shlex.quote(printed_path) + '; exec sleep 3600'
    printed = request(origin_env, 'session.new', args={'name': 'Remote opener', 'cwd': str(root),
                                                     'command': '/bin/sh -c ' + shlex.quote(script)})['id']
    opened = request(viewer_env, 'zmx.attach', printed, {'host': 'local-test', 'window': window, 'workspace': 'root'})['id']
    wait_for(lambda: (origin_row(printed) or {}).get('presentation', {}).get('state') == 'connected',
             'opener presentation stream did not connect', timeout=30)
    wait_for(lambda: printed_path in request(viewer_env, 'session.text', opened).get('text', ''),
             'remote path did not render', timeout=30)
    frame = collect(app, role='frame')[0]
    bounds = window_extents(frame)
    sidebar = wait_for(lambda: sidebar_column(app), 'sidebar not allocated')
    if artifacts := os.environ.get('AGTERM_UI_ARTIFACT_DIR'):
        from x11_capture import capture
        capture(str(Path(artifacts, 'remote-opener-before.png')))
    for top in (80, 72, 88, 96, 64, 56, 48):
        mouse_click(lambda: frame, viewer.pid, button='left', modifier='ctrl',
                    x_fraction=(sidebar.x + sidebar.width + 45) / bounds.width, dy=-bounds.height // 2 + top)
        time.sleep(.3)
        if marker.exists():
            break
    try:
        wait_for(marker.exists, 'remote detected path did not run opener', timeout=30)
    except AssertionError:
        print('Opener pane:', request(viewer_env, 'session.text', opened))
        row = origin_row(printed)
        print('Opener row:', {key: row.get(key) for key in ('presentation', 'htmlOverlays', 'cwd', 'surfaces')})
        if artifacts:
            capture(str(Path(artifacts, 'remote-opener-after.png')))
        raise
    staged = Path(marker.read_text().strip())
    assert staged != clicked and staged.read_bytes() == clicked.read_bytes(), staged
    print('OK: real SSH workspace placement, terminal/page following, creation hold, file/folder paste and opener snapshot')
