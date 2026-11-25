"""v0.44.1 behavior through real GTK, control, clipboard, terminal links and launch forwarding."""

import os
import pwd
from pathlib import Path
import shlex
import subprocess
import struct
import sys
import time
import zlib

from atspi_smoke import (BIN, collect, launch, mouse_click, raw_control_json, sidebar_column,
                         stop, wait_for, window_extents)


class ClipboardOwner:
    def __init__(self, env, root, mime, data):
        payload, ready = root / 'clipboard-data', root / 'clipboard-ready'
        payload.write_bytes(data)
        ready.unlink(missing_ok=True)
        script = '''import gi,sys
from pathlib import Path
gi.require_version('Gtk','4.0')
from gi.repository import Gtk,Gdk,GLib
Gtk.init()
p=Gdk.ContentProvider.new_for_bytes(sys.argv[1],GLib.Bytes.new(Path(sys.argv[2]).read_bytes()))
Gdk.Display.get_default().get_clipboard().set_content(p)
Path(sys.argv[3]).touch()
GLib.MainLoop().run()
'''
        self.process = subprocess.Popen([sys.executable, '-c', script, mime, str(payload), str(ready)], env=env)
        wait_for(ready.exists, 'clipboard owner did not start')

    def close(self):
        self.process.terminate()
        self.process.wait(timeout=5)


def verify_v0441(env, state):
    root = Path(state)
    process, app = launch(env)

    def request(command, target=None, args=None):
        reply = raw_control_json(env, {'cmd': command, 'target': target, 'args': args or {}}, timeout=40)
        assert reply['ok'], reply
        return reply.get('result', {})

    def tree():
        return request('tree')['tree']

    def row(identity):
        return next(item for workspace in tree()['workspaces'] for item in workspace['sessions'] if item['id'] == identity)

    def page(identity):
        return row(identity).get('htmlOverlays', [{}])[0]

    try:
        window = request('window.list')['windows'][0]['id']
        request('window.resize', window, {'width': 1000, 'height': 700})
        parent = request('session.new', args={'name': 'Root parent', 'workspace': 'root'})['id']
        root_workspace = next(workspace for workspace in tree()['workspaces'] if workspace.get('root'))
        assert root_workspace['sessions'][0]['id'] == parent, root_workspace
        child = request('session.companion.new', parent, {'name': 'Promoted child'})['id']
        assert row(child)['parent'] == parent
        request('session.companion.promote', child, {'workspace': 'root'})
        assert row(child).get('parent') is None
        named = request('workspace.new', args={'name': 'Named destination'})['id']
        request('session.move', child, {'workspace': named})
        assert any(item['id'] == child for workspace in tree()['workspaces'] if workspace['id'] == named for item in workspace['sessions'])
        request('session.companion.move', child, {'parent': parent})
        assert row(child)['parent'] == parent
        for command in ('workspace.rename', 'workspace.delete', 'workspace.collapse', 'workspace.select'):
            refusal = raw_control_json(env, {'cmd': command, 'target': 'root', 'args': {'name': 'Refused'}})
            assert not refusal['ok'] and 'not a workspace' in refusal['error'], refusal

        # Warm launch forwarding must select the target after the default activation raises a window.
        applications = Path(env['XDG_DATA_HOME'], 'applications')
        applications.mkdir(parents=True, exist_ok=True)
        (applications / 'agterm-audit-uri.desktop').write_text(
            '[Desktop Entry]\nType=Application\nName=agterm isolated URI acceptance\n'
            'Exec=' + BIN + ' %u\nNoDisplay=true\nMimeType=x-scheme-handler/agterm;\n')
        subprocess.run(['gio', 'mime', 'x-scheme-handler/agterm', 'agterm-audit-uri.desktop'], env=env, check=True)
        request('session.select', child)
        subprocess.run(['gio', 'open', 'agterm://session/' + parent], env=env, check=True, timeout=10)
        wait_for(lambda: row(parent).get('active'), 'external URI did not select root session')

        source = root / 'clicked.txt'
        source.write_text('configured opener fixture\n')
        marker = root / 'opened-context'
        keymap = root / 'config/keymap.conf'
        keymap.write_text('open *.txt printf \'%s\\n\' "$AGT_PATH" "$AGT_PANE" "$PWD" > ' + shlex.quote(str(marker)) + '\n')
        request('keymap.reload')
        assert request('keymap.list')['keymap']['openers'][0]['selectors'] == ['*.txt']
        script = "printf '\\033[2J\\033[H%s' " + shlex.quote(str(source)) + '; exec sleep 3600'
        linked = request('session.new', args={'name': 'Detected opener', 'command': '/bin/sh -c ' + shlex.quote(script)})['id']
        wait_for(lambda: str(source) in request('session.text', linked).get('text', ''), 'link fixture did not print')
        cursor = request('events.read')['events']
        frame = collect(app, role='frame')[0]
        bounds = window_extents(frame)
        sidebar = wait_for(lambda: sidebar_column(app), 'sidebar not allocated')
        for top in (80, 72, 88, 96, 64, 56, 48):
            mouse_click(lambda: frame, process.pid, button='left', modifier='ctrl',
                        x_fraction=(sidebar.x + sidebar.width + 45) / bounds.width, dy=-bounds.height // 2 + top)
            time.sleep(0.15)
            if marker.exists():
                break
        wait_for(marker.exists, 'detected file did not run configured opener')
        assert marker.read_text().splitlines() == [str(source), 'left', pwd.getpwuid(os.getuid()).pw_dir], marker.read_text()
        assert not row(linked).get('htmlOverlays'), row(linked)
        events = request('events.read', args={'run': cursor['run'], 'after': str(cursor['next']),
                                              'kinds': ['opener.run'], 'limit': 100})['events']['items']
        assert any(event.get('session') == linked and event.get('payload', {}).get('path') == str(source)
                   for event in events), ('configured opener did not emit its real control event', events)
        marker.unlink()
        script = ("printf '\\033[2J\\033[H\\033]8;;file://" + str(source)
                  + "\\007OPEN_FILE_OPEN_FILE_OPEN_FILE\\033]8;;\\007'; exec sleep 3600")
        osc8 = request('session.new', args={'name': 'OSC8 keeps page', 'command': '/bin/sh -c ' + shlex.quote(script)})['id']
        wait_for(lambda: 'OPEN_FILE' in request('session.text', osc8).get('text', ''), 'OSC8 fixture did not print')
        for top in (80, 72, 88, 96, 64, 56, 48):
            mouse_click(lambda: frame, process.pid, button='left', modifier='ctrl',
                        x_fraction=(sidebar.x + sidebar.width + 45) / bounds.width, dy=-bounds.height // 2 + top)
            time.sleep(.15)
            if row(osc8).get('htmlOverlays'):
                break
        wait_for(lambda: page(osc8).get('state') == 'loaded', 'OSC8 did not retain its built-in page route')
        assert not marker.exists(), 'OSC8 ran a detected-path opener'
        request('session.overlay.close', osc8)

        # A real clipboard image is staged before its path enters the program.
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        image = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
                 + chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\xff')) + chunk(b'IEND', b''))
        received = root / 'pasted-input'
        script = 'stty -echo; cat > ' + shlex.quote(str(received))
        pasted = request('session.new', args={'name': 'Image paste', 'command': '/bin/sh -c ' + shlex.quote(script)})['id']
        wait_for(received.exists, 'paste receiver did not start')
        owner = ClipboardOwner(env, root, 'image/png', image)
        try:
            request('session.paste', pasted)
            request('session.type', pasted, {'text': '\n'})
            wait_for(lambda: received.read_text().strip(), 'image path was not inserted')
            path = Path(shlex.split(received.read_text().strip())[0])
            assert path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), path
        finally:
            owner.close()

        image_file = root / 'page.png'
        # Exercise the large-byte path that previously exceeded WebKit's base64 document limit.
        large_image = image[:-12] + chunk(b'tEXt', b'Comment\x00' + b'x' * (48 << 20)) + image[-12:]
        image_file.write_bytes(large_image)
        del large_image
        request('session.select', parent)
        request('session.overlay.open', parent, {'image': str(image_file)})
        wait_for(lambda: page(parent).get('state') == 'loaded', 'image scheme page did not load')
        from x11_capture import capture
        def picture_is_visible():
            pixels = capture().get_pixels()
            return sum(pixels[index] > 240 and pixels[index + 1] < 20 and pixels[index + 2] > 240
                       for index in range(0, len(pixels) - 2, 3)) > 10_000
        wait_for(picture_is_visible, '48 MB PNG did not render through the image scheme')
        image_file.unlink()
        request('theme.set', args={'name': 'Catppuccin Latte'})
        assert page(parent).get('state') == 'loaded', 'changing the theme reread the removed image'
        wait_for(picture_is_visible, 'changing the theme lost the checked image bytes')
        request('session.overlay.reload', parent)
        wait_for(lambda: page(parent).get('state') == 'failed', 'missing image reload did not fail')
        time.sleep(0.5)
        assert page(parent)['state'] == 'failed', page(parent)
        image_file.write_bytes(image)
        request('session.overlay.reload', parent)
        wait_for(lambda: page(parent).get('state') == 'loaded', 'image reload did not recover')
        request('session.overlay.close', parent)
        request('session.select', child)
        stop(process)
        process, app = launch(env, ['agterm://session/' + parent])
        wait_for(lambda: row(parent).get('active'), 'cold URI did not select the restored root session')
        print('OK: v0.44.1 roots, promotion, nesting, URI, opener, clipboard image, image reload failure/recovery')
    finally:
        stop(process)
