"""Focused acceptance of the v0.43.0 -> v0.44.1 GUI and Live lifecycle changes."""

import contextlib
import json
from pathlib import Path
import shlex
import subprocess

from atspi_smoke import (ABSOLUTE_DYS, ROOT, activate, collect, launch, mouse_click, mouse_drag,
                         poll, press_escape, press_x11_key, raw_control_json, run_palette_action,
                         sidebar_session_row_label, stop, wait_for)


def live_environment(env, root):
    fixture = root / 'login-shell.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-o', str(fixture),
                    str(Path(ROOT, 'tests/login_shell_zsh_fixture.c')), '-ldl'], check=True)
    (root / 'settings.json').write_text(json.dumps({'restoreMode': 'live', 'closeGraceUndoEnabled': False}))
    return dict(env, LD_PRELOAD=str(fixture))


def verify_gui(env, state):
    root = Path(state)
    config = root / 'config'
    config.mkdir(exist_ok=True)
    (config / 'keymap.conf').write_text('map ctrl+alt+r new_root_session\n')
    process, app = launch(env)

    def request(command, target=None, args=None):
        reply = raw_control_json(env, {'cmd': command, 'target': target, 'args': args or {}}, timeout=30)
        assert reply['ok'], reply
        return reply.get('result', {})

    def tree():
        return request('tree')['tree']

    def rows():
        return [row for workspace in tree()['workspaces'] for row in workspace['sessions']]

    def row(identity):
        return next(row for row in rows() if row['id'] == identity)

    def context_action(name, action):
        identity = next(item['id'] for item in rows() if item['name'] == name)
        try:
            # Reacquire the moved label and calibrate pointer placement as the other sidebar tests do.
            # Only retry a missed/wrong-row click; a correct menu missing its action must still fail.
            for dy in ABSOLUTE_DYS:
                mouse_click(lambda: sidebar_session_row_label(app, name), process.pid, button='right', dy=dy)
                if poll(lambda: collect(app, role='push button', name='Close Session')
                        and row(identity).get('active'), timeout=1):
                    print('CONTEXT opened:', name, 'pointer offset:', dy, flush=True)
                    break
                press_escape(process.pid)
            else:
                raise AssertionError('context menu did not open on ' + name)
            activate(wait_for(lambda: next(iter(collect(app, role='push button', name=action)), None),
                              'missing context action: ' + action))
        except AssertionError:
            from atspi_smoke import describe_tree
            from x11_capture import capture
            print('CONTEXT failure model:', tree(), flush=True)
            describe_tree(app)
            with contextlib.suppress(Exception):
                capture(Path(env['AGTERM_UI_ARTIFACT_DIR']) / 'v0441-context-failure.png')
            raise

    try:
        before = {row['id'] for row in rows()}
        run_palette_action(app, process.pid, None, 'New Top-Level Session')
        parent = wait_for(lambda: next((row['id'] for row in rows() if row['id'] not in before), None),
                          'palette did not create a root session')
        request('session.rename', parent, {'name': 'Audit root'})
        assert any(row['id'] == parent for ws in tree()['workspaces'] if ws.get('root') for row in ws['sessions'])
        before = {row['id'] for row in rows()}
        press_x11_key('ctrl+alt+r', process.pid)
        keyed = wait_for(lambda: next((row['id'] for row in rows() if row['id'] not in before), None),
                         'new_root_session keymap action did not create a session')
        assert any(row['id'] == keyed for ws in tree()['workspaces'] if ws.get('root') for row in ws['sessions'])
        destination = request('workspace.new', args={'name': 'Audit destination'})['id']
        marker = root / 'placement.pid'
        command = '/bin/sh -c ' + shlex.quote('echo $$ > ' + shlex.quote(str(marker)) + '; exec sleep 3600')
        child = request('session.companion.new', parent, {'name': 'Audit child', 'command': command})['id']
        wait_for(marker.exists, 'placement program did not start')
        pid = int(marker.read_text())
        context_action('Audit child', 'Move to Audit destination')
        wait_for(lambda: row(child).get('parent') is None, 'Move to did not promote the companion')
        assert any(row['id'] == child for ws in tree()['workspaces'] if ws['id'] == destination for row in ws['sessions'])
        request('session.select', child)
        mouse_drag(lambda: sidebar_session_row_label(app, 'Audit child'),
                   lambda: sidebar_session_row_label(app, 'Audit root'), process.pid, target_fraction=.5)
        wait_for(lambda: row(child).get('parent') == parent, 'middle drop did not nest a top-level session')
        context_action('Audit child', 'Move to Top-Level Sessions')
        wait_for(lambda: row(child).get('parent') is None, 'root Move to did not promote the companion')
        assert Path(f'/proc/{pid}').exists() and int(marker.read_text()) == pid, 'placement replaced the running program'
        request('session.companion.move', child, {'parent': parent})
        request('session.select', child)
        mouse_drag(lambda: sidebar_session_row_label(app, 'Audit child'),
                   lambda: sidebar_session_row_label(app, 'Audit root'), process.pid, target_fraction=.05)
        wait_for(lambda: row(child).get('parent') is None, 'gap drop did not promote a companion')
        request('workspace.focus', 'root')
        for workspace in list(tree()['workspaces']):
            if not workspace.get('root'):
                request('workspace.delete', workspace['id'])
        assert len(tree()['workspaces']) == 1 and tree()['workspaces'][0].get('root'), tree()
        stop(process)
        process, app = launch(env)
        assert any(row['id'] == parent for row in rows()) and row(child).get('parent') is None
        original = next(window['id'] for window in request('window.list')['windows'] if window['open'])
        second = request('window.new', args={'name': 'Cold launch survivor'})['id']
        request('session.select', parent, {'window': original})
        stop(process)
        process, app = launch(env, ['agterm://session/' + parent])
        opened = {window['id'] for window in request('window.list')['windows'] if window['open']}
        assert {original, second} <= opened, 'cold URI launch lost a saved window'
        assert next(item for ws in request('tree', args={'window': original})['tree']['workspaces']
                    for item in ws['sessions'] if item['id'] == parent).get('active'), 'cold URI did not select its target window'
        process.kill()
        process.wait(timeout=5)
        process, app = launch(env)
        opened = {window['id'] for window in request('window.list')['windows'] if window['open']}
        assert {original, second} <= opened, 'unclean exit prevented saved windows from reopening'
        print('OK: root palette/keymap, GUI promotion/nesting/gap drag, program identity, last workspace deletion, root restore, multiwindow cold URI and SIGKILL relaunch')
    finally:
        stop(process)


def verify_live(env, state):
    root = Path(state)
    env = live_environment(env, root)
    hangup_fixture = root / 'pty-hangup.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', '-o', str(hangup_fixture),
                    str(Path(ROOT, 'tests/pty_hangup_fixture.c')), '-ldl'], check=True)
    observed_hangup = root / 'pty-hangup-observed'
    env = dict(env, LD_PRELOAD=env['LD_PRELOAD'] + ':' + str(hangup_fixture),
               AGTERM_TEST_PTY_HUP_GATE=str(root / 'startup-answer'),
               AGTERM_TEST_PTY_HUP_OBSERVED=str(observed_hangup))
    process, app = launch(env)
    inventory = None

    def request(command, target=None, args=None):
        reply = raw_control_json(env, {'cmd': command, 'target': target, 'args': args or {}}, timeout=40)
        assert reply['ok'], reply
        return reply.get('result', {})

    def rows(window=None):
        tree = request('tree', args={'window': window} if window else {})['tree']
        return [row for ws in tree['workspaces'] for row in ws['sessions']]

    def row(identity, window=None):
        return next(row for row in rows(window) if row['id'] == identity)

    try:
        assert request('restore.mode')['restore']['active'] == 'live'
        window = request('window.list')['windows'][0]['id']
        if env.get('AGTERM_AUDIT_LIVE_PART') != 'lifecycle':
            variant = env.get('AGTERM_AUDIT_CONFIG_CHANGE', 'reload')
            gate = root / 'exit-gate'
            script = 'printf "HOLD-FIRST\\n"; while [ ! -f ' + shlex.quote(str(gate)) + ' ]; do sleep .05; done; printf "HOLD-LAST\\n"'
            identity = request('session.new', args={'name': 'Audit held', 'command': script, 'wait': True})['id']
            wait_for(lambda: 'HOLD-FIRST' in request('session.text', identity)['text'], 'held program did not render initial output')
            if variant in ('background', 'both'):
                request('session.background', identity, {'color': '#123456'})
            if variant in ('reload', 'both'):
                request('config.reload')
            print('WAIT variant:', variant, 'row:', row(identity), flush=True)
            gate.touch()
            wait_for(lambda: 'Press any key' in request('session.text', identity)['text'], 'wait policy was lost: ' + variant)
            text = request('session.text', identity, {'all': True})['text']
            assert 'HOLD-FIRST' in text and 'HOLD-LAST' in text, text
            request('session.close', identity)
            print('OK: wait with zero exit status and config change ' + variant, flush=True)
            if env.get('AGTERM_AUDIT_LIVE_PART') == 'wait':
                return

        startup_repeats = int(env.get('AGTERM_AUDIT_STARTUP_REPEATS', '5'))
        assert startup_repeats > 0, 'startup query coverage requires at least one attempt'
        for startup_attempt in range(startup_repeats):
            # A real DSR query must be answered at startup, including its first screen paint.
            query = root / 'startup-query.py'
            answer = root / 'startup-answer'
            answer.unlink(missing_ok=True)
            query.write_text('import os,select,sys,tty\n'
                             'tty.setraw(0)\nos.write(1,b"\\x1b[6n")\n'
                             'r=select.select([0],[],[],3)[0]\n'
                             'data=os.read(0,1024) if r else b"TIMEOUT"\n'
                             'open(sys.argv[1],"wb").write(data)\n'
                             'os.write(1,b"STARTUP-QUERY-DONE\\r\\n")\n')
            queried = request('session.new', args={'name': 'Startup terminal query',
                'command': '/usr/bin/python3 ' + shlex.quote(str(query)) + ' ' + shlex.quote(str(answer)), 'wait': True})['id']
            wait_for(answer.exists, 'startup query did not complete')
            assert answer.read_bytes().startswith(b'\x1b[') and answer.read_bytes().endswith(b'R'), answer.read_bytes()
            if startup_attempt == 0:
                wait_for(observed_hangup.exists, 'fixture did not observe a readable PTY hangup')
            try:
                wait_for(lambda: 'STARTUP-QUERY-DONE' in request('session.text', queried)['text'], 'startup output was lost')
                if startup_attempt == 0:
                    print('STARTUP readable HUP output:', request('session.text', queried)['text'], flush=True)
            except AssertionError:
                print('STARTUP failed attempt:', startup_attempt + 1, 'of', startup_repeats, flush=True)
                print('STARTUP failure row:', row(queried), flush=True)
                print('STARTUP visible text:', request('session.text', queried), flush=True)
                print('STARTUP all text:', request('session.text', queried, {'all': True}), flush=True)
                print('STARTUP DSR response:', answer.read_bytes().hex(), flush=True)
                with contextlib.suppress(Exception):
                    from x11_capture import capture
                    capture(str(Path(env['AGTERM_UI_ARTIFACT_DIR'], 'startup-failure.png')))
                raise
            request('session.close', queried)
        print('OK:', startup_repeats, 'fast startup queries answered and retained their output', flush=True)

        # Save lead on a running pane, then exercise both relaunch and closed-window restoration.
        leader = request('session.new', args={'name': 'Saved lead'})['id']
        wait_for(lambda: row(leader)['surfaces'][0].get('lead') == 'leader', 'local pane did not lead')
        pane = row(leader)['surfaces'][0]['paneID']
        stop(process)
        process, app = launch(env)
        wait_for(lambda: row(leader)['surfaces'][0].get('lead') == 'leader', 'relaunch did not reclaim saved local lead')
        assert row(leader)['surfaces'][0]['paneID'] == pane
        other = request('window.new')['id']
        request('window.close', window)
        request('window.select', window)
        wait_for(lambda: row(leader, window)['surfaces'][0].get('lead') == 'leader', 'window reopen did not reclaim local lead')
        request('window.close', other)
        inventory = request('zmx.list')['zmx']
        print('OK: startup DSR response/output and saved local lead after relaunch and window reopen')
    finally:
        with contextlib.suppress(AssertionError, OSError):
            inventory = request('zmx.list')['zmx']
        stop(process)
        if inventory and (endpoint := inventory.get('endpoint')):
            clean_env = dict(env, ZMX_DIR=endpoint['socketDirectory'])
            clean_env.pop('ZMX_SESSION', None)
            for entry in inventory['entries']:
                subprocess.run([endpoint['executable'], 'kill', entry['daemon'], '--force'],
                               env=clean_env, capture_output=True, timeout=5)
