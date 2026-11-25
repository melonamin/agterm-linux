"""A process created by the published v0.43.0 app survives reconnection by the candidate."""

import contextlib
import os
from pathlib import Path
import shlex
import subprocess

import atspi_smoke as smoke
from atspi_v0441_audit import live_environment


def verify_upgrade(env, state):
    root = Path(state)
    baseline = Path(env['AGTERM_AUDIT_BASELINE'])
    live_env = live_environment(env, root)
    old_env = dict(live_env, AGTERM_ZMX_PATH=str(baseline / 'bin/zmx'),
                   AGTERM_RESOURCE_ROOT=str(baseline / 'share/agterm'),
                   AGTERM_GHOSTTY_RESOURCES=str(baseline / 'share/ghostty'))
    original_bin = smoke.BIN
    try:
        smoke.BIN = str(baseline / 'bin/agterm-linux')
        process, _ = smoke.launch(old_env)
    finally:
        smoke.BIN = original_bin
    inventory = None
    def request(environment, command, target=None, args=None):
        reply = smoke.raw_control_json(environment, {'cmd': command, 'target': target, 'args': args or {}}, timeout=30)
        assert reply['ok'], reply
        return reply.get('result', {})
    try:
        marker, received = root / 'old-program.pid', root / 'old-program-input'
        command = '/bin/sh -c ' + shlex.quote('echo $$ > ' + shlex.quote(str(marker))
            + '; stty raw -echo; exec cat > ' + shlex.quote(str(received)))
        identity = request(old_env, 'session.new', args={'name': 'Previous release live process', 'command': command})['id']
        smoke.wait_for(lambda: marker.exists() and received.exists(), 'old-release program did not start')
        old_pid = int(marker.read_text())
        request(old_env, 'session.type', identity, {'text': 'BEFORE-UPGRADE'})
        smoke.wait_for(lambda: 'BEFORE-UPGRADE' in received.read_text(), 'old-release pane did not take input')
        inventory = request(old_env, 'zmx.list')['zmx']
        smoke.stop(process)
        assert Path(f'/proc/{old_pid}').exists(), 'quitting old release ended its Live program'
        process, _ = smoke.launch(live_env)
        def row():
            return next((row for ws in request(live_env, 'tree')['tree']['workspaces'] for row in ws['sessions']
                         if row['id'] == identity), {})
        smoke.wait_for(lambda: row().get('backedByZmx'), 'candidate did not restore old Live row', timeout=30)
        smoke.wait_for(lambda: next(iter(row().get('surfaces', [])), {}).get('lead') == 'leader',
                       'candidate did not reconnect to the previous release daemon', timeout=30)
        request(live_env, 'session.type', identity, {'text': 'AFTER-UPGRADE'})
        smoke.wait_for(lambda: 'AFTER-UPGRADE' in received.read_text(), 'upgraded viewer did not drive the old process', timeout=15)
        assert int(marker.read_text()) == old_pid and Path(f'/proc/{old_pid}').exists()
        print('OK: published v0.43.0 Live process kept its PID and accepts input through the v0.44.1 candidate', flush=True)
        inventory = request(live_env, 'zmx.list')['zmx']
    finally:
        with contextlib.suppress(AssertionError, OSError):
            inventory = request(live_env, 'zmx.list')['zmx']
        smoke.stop(process)
        if inventory and (endpoint := inventory.get('endpoint')):
            cleanup = dict(live_env, ZMX_DIR=endpoint['socketDirectory'])
            cleanup.pop('ZMX_SESSION', None)
            for entry in inventory['entries']:
                subprocess.run([endpoint['executable'], 'kill', entry['daemon'], '--force'],
                               env=cleanup, capture_output=True, timeout=5)
