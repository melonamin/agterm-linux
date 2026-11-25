"""Exercise actual GTK clipboard shortcuts, palette paste and file/image drag sources."""

import json
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import time
import zlib

from atspi_smoke import (focus_window, launch, press_x11_key, raw_control_json,
                         run_palette_action, stop, wait_for)
from atspi_v0441 import ClipboardOwner


def png_bytes():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\xff')) + chunk(b'IEND', b''))


def drop_payload(env, root, process, kind, paths):
    focus_window(process.pid)
    target = subprocess.check_output(['xdotool', 'getactivewindow'], text=True).strip()
    subprocess.run(['xdotool', 'windowmove', '--sync', target, '0', '0'], check=True)
    geometry = dict(line.split('=', 1) for line in subprocess.check_output(
        ['xdotool', 'getwindowgeometry', '--shell', target], text=True).splitlines())
    end = (int(geometry['X']) + int(geometry['WIDTH']) * 3 // 4,
           int(geometry['Y']) + int(geometry['HEIGHT']) // 2)
    ready = root / ('drag-ready-' + kind)
    script = '''import gi,json,sys
from pathlib import Path
gi.require_version('Gtk','4.0')
from gi.repository import Gtk,Gdk,Gio,GLib,GObject
Gtk.init()
kind,paths,ready=sys.argv[1],json.loads(sys.argv[2]),Path(sys.argv[3])
value=Gdk.FileList.new_from_array([Gio.File.new_for_path(p) for p in paths]) if kind=='files' else GObject.Value(Gdk.Texture,Gdk.Texture.new_from_filename(paths[0]))
provider=Gdk.ContentProvider.new_for_value(value)
window=Gtk.Window(title='Audit Drag Source')
window.set_default_size(180,100)
button=Gtk.Button(label='Drag audit payload')
source=Gtk.DragSource()
source.set_actions(Gdk.DragAction.COPY)
source.connect('prepare',lambda *args:provider)
source.connect('drag-end',lambda *args:ready.with_suffix('.ended').touch())
source.connect('drag-cancel',lambda _source,_drag,reason:print('GTK drag cancelled:',reason,flush=True))
button.add_controller(source)
window.set_child(button)
window.present()
GLib.idle_add(lambda:(ready.touch(),False)[1])
GLib.MainLoop().run()
'''
    source = subprocess.Popen([sys.executable, '-c', script, kind, json.dumps([str(p) for p in paths]), str(ready)], env=env)
    try:
        wait_for(ready.exists, 'real GTK drag source did not start')
        source_window = subprocess.check_output(['xdotool', 'search', '--sync', '--onlyvisible',
            '--pid', str(source.pid), '--name', '^Audit Drag Source$'], text=True, timeout=10).splitlines()[-1]
        subprocess.run(['xdotool', 'windowmove', '--sync', source_window, '1060', '720'], check=True)
        subprocess.run(['xdotool', 'windowactivate', '--sync', source_window], check=True)
        geometry = dict(line.split('=', 1) for line in subprocess.check_output(
            ['xdotool', 'getwindowgeometry', '--shell', source_window], text=True).splitlines())
        start = (int(geometry['X']) + int(geometry['WIDTH']) // 2,
                 int(geometry['Y']) + int(geometry['HEIGHT']) // 2)
        def xdo(*args):
            subprocess.run(['xdotool', *map(str, args)], check=True)
        xdo('mousemove', '--sync', *start)
        time.sleep(.2)
        xdo('mousedown', 1)
        try:
            for step in range(1, 25):
                xdo('mousemove', '--sync', round(start[0] + (end[0] - start[0]) * step / 24),
                    round(start[1] + (end[1] - start[1]) * step / 24))
                time.sleep(.04)
            time.sleep(.5)
        finally:
            xdo('mouseup', 1)
        # A real selection owner must survive until the target has read the offered value.
        wait_for(ready.with_suffix('.ended').exists, 'GTK drag did not finish', timeout=10)
    finally:
        source.terminate()
        source.wait(timeout=5)


def exercise_transfers(env, root, process, app, request, create_receiver, remote=False):
    picture = root / 'input.png'
    picture.write_bytes(png_bytes())
    source = root / "file with 'quotes'.txt"
    source.write_text('copied file bytes\n')
    folder = root / 'folder with spaces'
    folder.mkdir()
    (folder / 'nested.txt').write_text('nested bytes\n')
    cases = [('text-shortcut', 'text/plain;charset=utf-8', b'file:///literal text', 'shortcut'),
             ('files-palette', 'text/uri-list', (source.as_uri() + '\r\n' + folder.as_uri() + '\r\n').encode(), 'palette'),
             ('image-shortcut', 'image/png', picture.read_bytes(), 'shortcut'),
             ('files-drop', None, None, 'drop'), ('image-drop', None, None, 'drop')]
    for name, mime, data, route in cases:
        received = root / (name + '.received')
        command = '/bin/sh -c ' + shlex.quote('stty raw -echo; cat > ' + shlex.quote(str(received)))
        identity = create_receiver(name, command)
        request('session.select', identity)
        wait_for(received.exists, 'paste receiver did not start: ' + name)
        owner = None
        try:
            if mime:
                owner = ClipboardOwner(env, root, mime, data)
            if route == 'shortcut':
                press_x11_key('ctrl+shift+v', process.pid)
            elif route == 'palette':
                run_palette_action(app, process.pid, None, 'Paste')
            else:
                drop_payload(env, root, process, 'files' if name.startswith('files') else 'image',
                             [source, folder] if name.startswith('files') else [picture])
            wait_for(lambda: received.exists() and received.stat().st_size > 0, 'no bytes from ' + name, timeout=30)
            time.sleep(.2)
            value = received.read_text()
            if name.startswith('text'):
                assert value == data.decode(), (name, value)
            elif name.startswith('files'):
                paths = [Path(path) for path in shlex.split(value)]
                assert len(paths) == 2, (name, value)
                assert paths[0].read_bytes() == source.read_bytes()
                assert (paths[1] / 'nested.txt').read_bytes() == (folder / 'nested.txt').read_bytes()
                assert (paths[0] != source) == remote, (name, paths)
            else:
                paths = [Path(path) for path in shlex.split(value)]
                assert len(paths) == 1 and paths[0] != picture, (name, value)
                assert paths[0].read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), paths[0]
            print('OK:', 'remote' if remote else 'local', name, flush=True)
        finally:
            if owner:
                owner.close()
            request('session.close', identity)


def verify_transfers(env, state):
    process, app = launch(env)
    def request(command, target=None, args=None):
        reply = raw_control_json(env, {'cmd': command, 'target': target, 'args': args or {}}, timeout=40)
        assert reply['ok'], reply
        return reply.get('result', {})
    try:
        exercise_transfers(env, Path(state), process, app, request,
                           lambda name, command: request('session.new', args={'name': name, 'command': command})['id'])
    finally:
        stop(process)
