"""A real GTK origin delays a replacement beyond the reply deadline, then notifies its SSH viewer."""

import contextlib
import os
from pathlib import Path
import shlex
import subprocess
import time

from atspi_smoke import ROOT, launch, raw_control_json, stop, wait_for
from atspi_v0441_audit import live_environment


def tty_clients(parent):
    table = {}
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        try:
            fields = (path / 'stat').read_text().rsplit(')', 1)[1].split()
            argv = (path / 'cmdline').read_bytes().split(b'\0')
            table[int(path.name)] = (int(fields[1]), argv)
        except (OSError, ValueError, IndexError):
            pass
    descendants = {parent}
    while True:
        enlarged = descendants | {pid for pid, (ppid, _) in table.items() if ppid in descendants}
        if enlarged == descendants:
            break
        descendants = enlarged
    return {pid for pid, (_, argv) in table.items() if pid in descendants
            and Path(os.fsdecode(argv[0])).name == 'ssh' and b'-tt' in argv}


def verify_late_restart(env, state):
    root = Path(state)
    delay = root / 'delay-next-spawn'
    consumed = root / 'delay-consumed'
    executable = str(Path(ROOT, 'vendor/zmx/zmx'))
    wrapper = root / 'zmx-delayed'
    wrapper.write_text('#!/bin/sh\n'
        'if [ "$1" = attach ] && [ "${AGTERM_CONTROL_SOCKET:-}" = ' + shlex.quote(env['AGTERM_CONTROL_SOCKET'])
        + ' ] && [ -f ' + shlex.quote(str(delay)) + ' ]; then\n'
        '  mv ' + shlex.quote(str(delay)) + ' ' + shlex.quote(str(consumed)) + '\n'
        '  sleep 12\nfi\nexec ' + shlex.quote(executable) + ' "$@"\n')
    wrapper.chmod(0o755)
    origin_env = dict(live_environment(env, root), AGTERM_ZMX_PATH=str(wrapper))
    viewer_state = root / 'viewer'
    viewer_state.mkdir()
    tools = root / 'ssh-tools'
    tools.mkdir()
    ssh = tools / 'ssh'
    ssh.write_text('#!/bin/sh\nexec /usr/bin/ssh -F ' + shlex.quote(env['AGTERM_TEST_SSH_CONFIG'])
        + ' -o ' + shlex.quote('SetEnv=AGTERM_STATE_DIR=' + state) + ' "$@"\n')
    ssh.chmod(0o755)
    viewer_env = dict(env, AGTERM_STATE_DIR=str(viewer_state), AGTERM_CONTROL_SOCKET=str(viewer_state / 'agterm.sock'),
                      AGTERM_APP_ID=env['AGTERM_APP_ID'] + '.viewer', PATH=str(tools) + ':' + env['PATH'])
    origin, _ = launch(origin_env)
    viewer = None
    inventory = None
    def request(environment, command, target=None, args=None, allow_error=False):
        reply = raw_control_json(environment, {'cmd': command, 'target': target, 'args': args or {}}, timeout=40)
        if allow_error:
            return reply
        assert reply['ok'], reply
        return reply.get('result', {})
    try:
        identity = request(origin_env, 'session.new', args={'name': 'Delayed restart origin'})['id']
        viewer, _ = launch(viewer_env)
        wait_for(lambda: Path(viewer_env['AGTERM_CONTROL_SOCKET']).exists(), 'viewer control socket did not appear')
        attached = request(viewer_env, 'zmx.attach', identity, {'host': 'local-test'})['id']
        def row():
            return next(row for ws in request(viewer_env, 'tree')['tree']['workspaces']
                        for row in ws['sessions'] if row['id'] == attached)
        wait_for(lambda: row().get('presentation', {}).get('state') == 'connected', 'late-restart viewer did not connect', timeout=30)
        wait_for(lambda: row()['surfaces'][0].get('lead') in ('leader', 'follower'), 'late-restart pane did not attach', timeout=30)
        pane = row()['surfaces'][0]['paneID']
        old_clients = tty_clients(viewer.pid)
        assert old_clients, 'the viewer had no real interactive SSH client'
        marker = root / 'restarted.pid'
        command = '/bin/sh -c ' + shlex.quote('echo $$ > ' + shlex.quote(str(marker))
                                             + '; printf "LATE-RESTART-RECOVERED\\n"; exec sleep 3600')
        delay.touch()
        started = time.monotonic()
        reply = request(origin_env, 'session.restart', identity, {'pane': 'left', 'command': command}, allow_error=True)
        elapsed = time.monotonic() - started
        assert consumed.exists(), 'the fixture did not delay the origin spawn'
        assert not reply['ok'] and elapsed >= 9, ('restart did not outlive its reply deadline', elapsed, reply)
        wait_for(marker.exists, 'delayed replacement never started', timeout=20)
        wait_for(lambda: tty_clients(viewer.pid) - old_clients and row()['surfaces'][0].get('lead') in ('leader', 'follower'),
                 'late respawn did not establish a new interactive SSH attachment', timeout=30)
        request(viewer_env, 'session.lead', attached)
        wait_for(lambda: 'LATE-RESTART-RECOVERED' in request(viewer_env, 'session.text', attached).get('text', ''),
                 'late respawn was not published and reattached on the real SSH viewer', timeout=30)
        assert row()['surfaces'][0]['paneID'] == pane, 'late restart changed the viewer pane identity'
        print('OK: real origin restart reply expired after', round(elapsed, 2),
              'seconds; delayed spawn published and SSH viewer reattached with the same pane', flush=True)
        inventory = request(origin_env, 'zmx.list')['zmx']
    finally:
        if viewer:
            stop(viewer)
        with contextlib.suppress(AssertionError, OSError):
            inventory = request(origin_env, 'zmx.list')['zmx']
        stop(origin)
        if inventory and (endpoint := inventory.get('endpoint')):
            cleanup = dict(origin_env, ZMX_DIR=endpoint['socketDirectory'])
            cleanup.pop('ZMX_SESSION', None)
            for entry in inventory['entries']:
                subprocess.run([endpoint['executable'], 'kill', entry['daemon'], '--force'],
                               env=cleanup, capture_output=True, timeout=5)
