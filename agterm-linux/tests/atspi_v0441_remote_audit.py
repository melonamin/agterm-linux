"""Extra real-SSH coverage of the new remote routes and refusal boundaries."""

import os
from pathlib import Path
import shlex
import signal
import time

from atspi_smoke import launch, press_x11_key, raw_control_json, stop, type_x11_text, wait_for
from atspi_v0441_late_restart import tty_clients
from atspi_v0441_transfers import exercise_transfers


def verify_remote(origin_env, viewer_env, viewer, app, window, root, request):
    def local(command, target=None, args=None):
        return request(viewer_env, command, target, args)

    def rows(environment, destination=None):
        tree = request(environment, 'tree', args={'window': destination} if destination else {})['tree']
        return [row for workspace in tree['workspaces'] for row in workspace['sessions']]

    def receiver(name, command):
        origin = request(origin_env, 'session.new', args={'name': name, 'command': command})['id']
        identity = local('zmx.attach', origin, {'host': 'local-test', 'window': window})['id']
        wait_for(lambda: next(row for row in rows(viewer_env, window) if row['id'] == identity)
                 .get('presentation', {}).get('state') == 'connected', 'transfer attachment did not connect', timeout=30)
        local('session.lead', identity, {'window': window})
        return identity

    if not viewer_env.get('AGTERM_AUDIT_SKIP_TRANSFERS'):
        exercise_transfers(viewer_env, root, viewer, app, local, receiver, remote=True)
    query = root / 'remote-startup-query.py'
    answer = root / 'remote-startup-answer'
    query.write_text('import os,select,sys,tty\n'
                     'tty.setraw(0)\nos.write(1,b"\\x1b[6n")\n'
                     'r=select.select([0],[],[],3)[0]\n'
                     'data=os.read(0,1024) if r else b"TIMEOUT"\n'
                     'open(sys.argv[1],"wb").write(data)\n'
                     'os.execl("/usr/bin/sleep","sleep","3600")\n')
    remote = local('session.remote.new', args={'host': 'local-test', 'cwd': '',
        'command': '/usr/bin/python3 ' + shlex.quote(str(query)) + ' ' + shlex.quote(str(answer)), 'window': window})['id']
    wait_for(answer.exists, 'remote held startup query did not complete')
    assert answer.read_bytes().startswith(b'\x1b[') and answer.read_bytes().endswith(b'R'), answer.read_bytes()
    print('OK: remote program startup query answered after attachment', flush=True)
    origin = next(row['remoteSessionID'] for row in rows(viewer_env, window) if row['id'] == remote)
    assert any(row['id'] == origin for row in rows(origin_env))
    failures = []
    child = None
    for name, extra in [('plain', {}), ('--dash child', {}), ('cwd empty', {'cwd': ''}),
                        ('command', {'command': 'exec sleep 3600'}),
                        ('--dash full', {'cwd': '', 'command': 'exec sleep 3600'})]:
        reply = raw_control_json(viewer_env, {'cmd': 'session.companion.new', 'target': remote,
            'args': dict(extra, name=name, window=window)}, timeout=40)
        print('COMPANION argument case:', name, extra, reply, flush=True)
        if not reply['ok']:
            failures.append((name, reply.get('error')))
            direct = raw_control_json(origin_env, {'cmd': 'session.companion.new', 'target': origin,
                'args': dict(extra, name=name)}, timeout=40)
            print('DIRECT origin argument case:', name, direct, flush=True)
        elif child is None:
            child = reply['result']['id']
    assert child is not None, 'even ordinary remote companion creation failed'
    origin_child = next(row['remoteSessionID'] for row in rows(viewer_env, window) if row['id'] == child)
    assert next(row for row in rows(origin_env) if row['id'] == origin_child)['name'] == 'plain'
    local('session.companion.promote', child, {'workspace': 'root', 'window': window})
    wait_for(lambda: next(row for row in rows(origin_env) if row['id'] == origin_child).get('parent') is None,
             'promotion did not run on the remote origin')
    print('OK: remote empty cwd/dash-valued arguments and companion promotion on origin', flush=True)

    workspace = local('workspace.new', args={'name': 'Attach reuse'})['id']
    attached = local('zmx.attach', origin_child, {'host': 'local-test', 'window': window,
                                               'workspaceName': 'Attach reuse'})['id']
    tree = local('tree', args={'window': window})['tree']
    assert any(row['id'] == attached for ws in tree['workspaces'] if ws['id'] == workspace for row in ws['sessions'])
    refusal = raw_control_json(viewer_env, {'cmd': 'zmx.attach', 'target': origin_child,
        'args': {'host': 'local-test', 'workspace': 'root', 'workspaceName': 'Attach reuse', 'window': window}})
    assert not refusal['ok'], refusal
    print('OK: named workspace reuse and conflicting-placement refusal', flush=True)

    victim = request(origin_env, 'session.new', args={'name': 'Origin recent must remain closed'})['id']
    request(origin_env, 'session.close', victim)
    local('session.close', attached, {'window': window})
    local('window.select', window)
    recent_before = local('recent.list')['recent']
    assert recent_before, 'closing an attachment did not create a recent entry'
    catalog = local('window.remote.open', args={'host': 'local-test'})['id']
    wait_for(lambda: rows(viewer_env, catalog), 'server catalog did not connect', timeout=30)
    local('window.select', catalog)
    wait_for(lambda: local('recent.list', args={'window': catalog}).get('recent'), 'origin history did not reach the catalog')
    reply = raw_control_json(viewer_env, {'cmd': 'recent.open'})
    print('BARE recent reply:', reply, 'origin victim reopened:', any(row['id'] == victim for row in rows(origin_env)), flush=True)
    assert not reply['ok'], ('bare attached reopen was allowed into a remote catalog', reply)
    local('window.select', window)
    assert local('recent.list')['recent'] == recent_before, 'refused reopen consumed a Recent Closed entry'
    assert any(row['id'] == origin_child for row in rows(origin_env)), 'refused reopen changed the origin'
    print('OK: bare attached reopen refused with remote catalog frontmost and history preserved', flush=True)
    local('recent.open', args={'window': catalog})
    wait_for(lambda: any(row['id'] == victim for row in rows(origin_env)),
             'explicit catalog recent.open did not reopen its own origin history')
    print('OK: explicit catalog destination still owns its origin history', flush=True)
    assert not failures, ('remote companion argument failures', failures)


def verify_lead(origin_env, viewer_env, viewer, app, window, root, request):
    received = root / 'typed-on-origin'
    command = '/bin/sh -c ' + shlex.quote('stty raw -echo; cat > ' + shlex.quote(str(received)))
    origin = request(origin_env, 'session.new', args={'name': 'Reconnect acceptance', 'command': command})['id']
    attached = request(viewer_env, 'zmx.attach', origin, {'host': 'local-test', 'window': window})['id']
    second_dir = root / 'second-viewer'
    second_dir.mkdir()
    second_env = dict(viewer_env, AGTERM_STATE_DIR=str(second_dir),
                      AGTERM_CONTROL_SOCKET=str(second_dir / 'agterm.sock'), AGTERM_APP_ID=viewer_env['AGTERM_APP_ID'] + '.second')
    second, _ = launch(second_env)
    wait_for(lambda: Path(second_env['AGTERM_CONTROL_SOCKET']).exists(), 'second viewer socket did not appear')
    second_window = request(second_env, 'window.list')['windows'][0]['id']
    second_row = request(second_env, 'zmx.attach', origin, {'host': 'local-test', 'window': second_window})['id']
    def row(environment, identity, destination):
        return next((row for ws in request(environment, 'tree', args={'window': destination})['tree']['workspaces']
                     for row in ws['sessions'] if row['id'] == identity), {'surfaces': [{}]})
    def role(environment, identity, destination):
        return row(environment, identity, destination)['surfaces'][0].get('lead')
    def claim(environment, identity, destination):
        wait_for(lambda: role(environment, identity, destination) in ('leader', 'follower'),
                 'pane did not report its initial lead', timeout=30)
        request(environment, 'session.lead', identity, {'window': destination})
        wait_for(lambda: role(environment, identity, destination) == 'leader', 'explicit lead did not take', timeout=30)
    ssh = root / 'tools/ssh'
    original = ssh.read_text()
    real = root / 'tools/ssh-underlying'
    real.write_text(original)
    real.chmod(0o755)
    blocked = root / 'block-first-transport'
    attempted = root / 'blocked-transport-attempt'
    ssh.write_text('#!/bin/sh\n'
        'if [ "${AGTERM_STATE_DIR:-}" = ' + shlex.quote(viewer_env['AGTERM_STATE_DIR']) + ' ]; then\n'
        'case " $* " in *" -tt "*)\n'
        ' if [ -f ' + shlex.quote(str(blocked)) + ' ]; then touch ' + shlex.quote(str(attempted)) + '; exit 255; fi\n'
        ' child=\n trap \'[ -z "$child" ] || kill "$child" 2>/dev/null; exit 255\' TERM\n'
        ' ' + shlex.quote(str(real)) + ' "$@" <&0 &\n child=$!\n wait "$child"\n exit $?;;\nesac\nfi\n'
        'exec ' + shlex.quote(str(real)) + ' "$@"\n')
    def drop_first():
        clients = tty_clients(viewer.pid)
        assert len(clients) == 1, ('unexpected first-viewer SSH clients', clients)
        client = next(iter(clients))
        parent = int(Path(f'/proc/{client}/stat').read_text().rsplit(')', 1)[1].split()[1])
        assert b'/tools/ssh' in Path(f'/proc/{parent}/cmdline').read_bytes(), 'fault wrapper does not own the SSH transport'
        blocked.touch()
        attempted.unlink(missing_ok=True)
        os.kill(parent, signal.SIGTERM)
        wait_for(attempted.exists, 'first viewer did not retry its failed SSH transport', timeout=30)
        wait_for(lambda: role(second_env, second_row, second_window) == 'leader', 'second viewer did not fill vacant lead', timeout=30)
    try:
        # Reattach once after installing the fault wrapper, so it owns the real interactive transport.
        claim(second_env, second_row, second_window)
        wait_for(lambda: role(viewer_env, attached, window) == 'follower', 'first viewer did not yield its lead')
        claim(viewer_env, attached, window)
        drop_first()
        blocked.unlink()
        wait_for(lambda: role(viewer_env, attached, window) == 'leader', 'unused fallback lead was not reclaimed', timeout=30)
        print('OK: dropped SSH transport reclaims its unused fallback lead', flush=True)
        drop_first()
        request(second_env, 'session.select', second_row, {'window': second_window})
        type_x11_text('USED-BY-SECOND', second.pid)
        wait_for(lambda: received.exists() and 'USED-BY-SECOND' in received.read_text(), 'second viewer did not send real input')
        blocked.unlink()
        wait_for(lambda: role(viewer_env, attached, window) == 'follower', 'used fallback lead was stolen during reconnect', timeout=30)
        time.sleep(1)
        assert role(second_env, second_row, second_window) == 'leader'
        print('OK: reconnect preserves another viewer that used the pane', flush=True)
        for trigger in ('control', 'keyboard'):
            claim(viewer_env, attached, window)
            drop_first()
            request(second_env, 'session.select', second_row, {'window': second_window})
            marker = 'SECOND-USED-' + trigger.upper()
            type_x11_text(marker, second.pid)
            wait_for(lambda: marker in received.read_text(), 'second input did not invalidate automatic reclaim')
            if trigger == 'control':
                deferred = raw_control_json(viewer_env, {'cmd': 'session.lead', 'target': attached,
                    'args': {'window': window}}, timeout=40)
                assert deferred['ok'], ('claim during reconnect', deferred)
            else:
                request(viewer_env, 'session.select', attached, {'window': window})
                press_x11_key('Return', viewer.pid)
            # Keep the transport blocked until another failed attempt has exercised preservation
            # of the queued claim across a replacement surface and remoteLinkLost/forget.
            attempted.unlink(missing_ok=True)
            wait_for(attempted.exists, 'deferred claim did not survive a blocked retry', timeout=30)
            blocked.unlink()
            wait_for(lambda: role(viewer_env, attached, window) == 'leader',
                     trigger + ' claim during reconnect was not applied on report', timeout=30)
            print('OK: disconnected ' + trigger + ' takeover survives a failed retry and claims on reconnect', flush=True)
        claim(second_env, second_row, second_window)
        stop(second)
        second, _ = launch(second_env)
        wait_for(lambda: Path(second_env['AGTERM_CONTROL_SOCKET']).exists(), 'restored viewer socket did not appear')
        wait_for(lambda: role(second_env, second_row, second_window) == 'leader', 'relaunch did not reclaim saved remote lead', timeout=30)
        print('OK: saved remote lead survives viewer relaunch', flush=True)
    finally:
        blocked.unlink(missing_ok=True)
        ssh.write_text(original)
        stop(second)
