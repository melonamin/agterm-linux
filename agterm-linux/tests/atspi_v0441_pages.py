"""Hidden config-editor pages, bounded inputs, and a followed log with active search."""

import os
from pathlib import Path
import subprocess
import time

from atspi_smoke import (collect, describe_tree, launch, press_x11_key, raw_control_json, run_palette_action,
                         stop, wait_for)


def verify_pages(env, state):
    root = Path(state)
    process, app = launch(env)
    def request(command, target=None, args=None):
        reply = raw_control_json(env, {'cmd': command, 'target': target, 'args': args or {}}, timeout=30)
        assert reply['ok'], reply
        return reply.get('result', {})
    def row():
        return next(row for ws in request('tree')['tree']['workspaces'] for row in ws['sessions'] if row['id'] == identity)
    def page():
        return row().get('htmlOverlays', [{}])[0]
    try:
        identity = request('session.new', args={'name': 'Page acceptance'})['id']
        if not env.get('AGTERM_AUDIT_SEARCH_ONLY'):
            source = root / 'covered.html'
            source.write_text('<title>Existing config blocker</title><h1>Existing overlay retained</h1>')
            request('session.overlay.open', identity, {'html': str(source)})
            wait_for(lambda: page().get('state') == 'loaded', 'config blocker did not load')
            page_id = page()['id']
            for title in ('Edit Keymap', 'Edit Hooks', 'Edit ghostty.conf'):
                request('session.overlay.hide', identity)
                assert page().get('hidden') is True
                run_palette_action(app, process.pid, None, title)
                wait_for(lambda: not page().get('hidden'), 'hidden blocker was not revealed by ' + title)
                assert page()['id'] == page_id, 'editing replaced the blocking page'
            request('session.overlay.hide', identity)
            request('session.overlay.open', identity, {'command': 'sleep 3600', 'pane': 'left'})
            run_palette_action(app, process.pid, None, 'Edit Keymap')
            assert page().get('hidden') is True, 'session blocker was revealed over a visible pane overlay'
            request('session.overlay.close', identity, {'pane': 'left'})
            request('session.overlay.close', identity)
            print('OK: all three config editors reveal hidden blockers and respect visible pane overlays', flush=True)

            fifo = root / 'pipe.log'
            os.mkfifo(fifo)
            for path in ('/dev/fd/0', str(fifo), '/dev/null'):
                start = time.monotonic()
                reply = raw_control_json(env, {'cmd': 'session.overlay.open', 'target': identity,
                                              'args': {'textFile': path}}, timeout=3)
                assert not reply['ok'], (path, reply)
                assert time.monotonic() - start < 2, 'non-regular input blocked the control channel'
                print('OK: refused non-regular page input', path, reply.get('error'), flush=True)

        count = int(env.get('AGTERM_AUDIT_LOG_LINES', '5000'))
        logfile = root / 'follow.log'
        logfile.write_text(''.join(f'{line}: needle initial log record\n' for line in range(count)))
        request('session.overlay.open', identity, {'textFile': str(logfile), 'tail': 10000, 'followFile': True})
        wait_for(lambda: page().get('state') == 'loaded', 'followed log did not load')
        press_x11_key('ctrl+f', process.pid)
        wait_for(lambda: collect(app, role='entry', name='Find'), 'GUI log search did not open')
        if env.get('AGTERM_AUDIT_LOG_QUERY') == 'control':
            request('session.overlay.search', identity, {'text': 'needle'})
        else:
            subprocess.run(['xdotool', 'type', '--clearmodifiers', '--delay',
                            env.get('AGTERM_AUDIT_TYPE_DELAY', '1'), '--', 'needle'], check=True)
        print('GUI search state after typing:', page().get('text', {}).get('search'), flush=True)
        try:
            wait_for(lambda: page().get('text', {}).get('search', {}).get('query') == 'needle'
                     and page().get('text', {}).get('search', {}).get('matches') == count,
                     'initial followed-log search did not count matches', timeout=30)
        except AssertionError:
            print('Final search state:', page().get('text', {}).get('search'), flush=True)
            raise
        start = time.monotonic()
        with logfile.open('a') as output:
            output.write(f'{count}: needle appended while searching\n')
        wait_for(lambda: page().get('text', {}).get('search', {}).get('matches') == count + 1,
                 'followed-log search did not update', timeout=15)
        assert page()['text']['search']['query'] == 'needle'
        # WebKit does not expose the match-counter span through AT-SPI. Check real highlighted
        # pixels and retain the rendered counter/search field for visual inspection.
        from x11_capture import capture
        def highlight_pixels():
            pixbuf = capture()
            pixels, stride = pixbuf.get_pixels(), pixbuf.get_rowstride()
            return sum(1 for y in range(0, pixbuf.get_height(), 2) for x in range(0, pixbuf.get_width(), 2)
                       if (lambda r, g, b: r > b * 1.5 and g > b * 1.3 and r + g > 100)
                       (*pixels[y * stride + x * 3:y * stride + x * 3 + 3]))
        def highlights_painted():
            return highlight_pixels() > min(count + 1, 25) * 160
        wait_for(highlights_painted, 'log-search highlights were not painted', timeout=15)
        painted = highlight_pixels()
        capture(str(Path(env['AGTERM_UI_ARTIFACT_DIR'], 'log-search.png')))
        print('OK: active log search followed an append across', count + 1, 'matches in', round(time.monotonic() - start, 3), 'seconds', flush=True)
        # Move well outside the old painted viewport without changing the active match.
        # The complete match count must survive, and the newly visible matches must be painted.
        subprocess.run(['xdotool', 'mousemove', '1000', '600', 'click', '--repeat', '30', '--delay', '20', '4'], check=True)
        wait_for(lambda: page()['text'].get('following') is False,
                 'wheel scrolling did not pause log following')
        wait_for(lambda: highlight_pixels() >= painted * .98,
                 'search highlights did not cover the scrolled viewport', timeout=15)
        capture(str(Path(env['AGTERM_UI_ARTIFACT_DIR'], 'log-search-scrolled.png')))
        for _ in range(3):
            request('session.overlay.search', identity, {'to': 'next'})
            if page()['text']['search']['current'] == 1:
                break
        wait_for(lambda: page()['text']['search']['current'] == 1,
                 'search navigation did not wrap to the distant first match')
        assert page()['text']['search']['matches'] == count + 1
        wait_for(highlights_painted, 'distant search navigation did not paint matches')
        capture(str(Path(env['AGTERM_UI_ARTIFACT_DIR'], 'log-search-first.png')))
        print('OK: scrolled search painting and distant match navigation retain the full count', flush=True)
    except Exception:
        from x11_capture import capture
        capture(str(Path(env['AGTERM_UI_ARTIFACT_DIR'], 'pages-failure.png')))
        print('Failure page state:', page(), flush=True)
        describe_tree(app)
        raise
    finally:
        stop(process)
