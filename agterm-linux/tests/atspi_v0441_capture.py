"""Quit-time Live command capture still saves every pane while one real daemon is SIGSTOPed."""

import json
import os
from pathlib import Path
import signal
import subprocess
import time

from atspi_smoke import launch, raw_control_json, stop, wait_for
from atspi_v0441_audit import live_environment


def verify_capture(env, state):
    root = Path(state)
    env = live_environment(env, root)
    process, _ = launch(env)
    inventory = None
    paused = None
    def request(command, target=None, args=None):
        reply = raw_control_json(env, {'cmd': command, 'target': target, 'args': args or {}}, timeout=30)
        assert reply['ok'], reply
        return reply.get('result', {})
    def row(identity):
        return next(row for workspace in request('tree')['tree']['workspaces'] for row in workspace['sessions']
                    if row['id'] == identity)
    try:
        identities = {}
        for seconds in (3597, 3598):
            identity = request('session.new', args={'name': f'Capture {seconds}'})['id']
            request('session.type', identity, {'text': f'exec /usr/bin/sleep {seconds}\n'})
            wait_for(lambda: (row(identity).get('foreground') or [''])[-1] == str(seconds), 'capture program did not start')
            identities[identity.lower()] = str(seconds)
        inventory = request('zmx.list')['zmx']
        leader = next(item['leaderPID'] for item in inventory['entries']
                      if item.get('sessionID', '').lower() == next(iter(identities)))
        paused = int(Path(f'/proc/{leader}/stat').read_text().rsplit(')', 1)[1].split()[1])
        assert Path(f'/proc/{paused}/comm').read_text().strip() == 'zmx', 'refusing to stop a non-fixture daemon'
        os.kill(paused, signal.SIGSTOP)
        started = time.monotonic()
        process.terminate()
        assert process.wait(timeout=3) == 0, 'quit was not clean'
        elapsed = time.monotonic() - started
        captured = {}
        def walk(node):
            if isinstance(node, dict):
                identity = str(node.get('id', '')).lower()
                if identity in identities:
                    captured[identity] = node.get('foregroundCommand')
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)
        for path in root.glob('windows/*.json'):
            walk(json.loads(path.read_text()))
        if (root / 'workspaces.json').exists():
            walk(json.loads((root / 'workspaces.json').read_text()))
        for identity, seconds in identities.items():
            assert captured.get(identity) and captured[identity][-1] == seconds, (identity, captured)
        print('OK: clean quit captured both foreground argv values with one daemon SIGSTOPed in', round(elapsed, 3), 'seconds')
    finally:
        if paused:
            os.kill(paused, signal.SIGCONT)
        stop(process)
        if inventory and (endpoint := inventory.get('endpoint')):
            cleanup = dict(env, ZMX_DIR=endpoint['socketDirectory'])
            cleanup.pop('ZMX_SESSION', None)
            for entry in inventory['entries']:
                subprocess.run([endpoint['executable'], 'kill', entry['daemon'], '--force'],
                               env=cleanup, capture_output=True, timeout=5)
