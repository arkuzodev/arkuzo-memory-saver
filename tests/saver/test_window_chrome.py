"""The desktop window host: registered windows only, theme validation, caption hit-testing,
the embedded Arkuzo icon and the taskbar identity. No window is created here."""
import importlib.util
import json
import os
import re
import struct
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'src/saver/Arkuzo-Control-Center.py'
spec = importlib.util.spec_from_file_location('chrome_cc', SOURCE)
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)

GRAPHITE = dict(cc.DESKTOP_THEME_DEFAULT)
FROST = {'bar': '#EDF0F5', 'barEnd': '#fafbfd', 'line': '#e2e7ef', 'text': '#151922', 'muted': '#6a7282',
         'hover': '#e9edf4', 'pressed': '#f4f6fa', 'closeHover': '#c42b1c'}


class WindowChromeTests(unittest.TestCase):
    def test_profile_slots_are_reserved_before_launch_and_reused_after_exit(self):
        with tempfile.TemporaryDirectory() as root:
            desktop = cc.DesktopWindows(Path(root))
            with patch.object(cc.threading, 'Thread') as thread:
                desktop.open('http://127.0.0.1/', 'unused')
                first = thread.call_args.kwargs['target'].__self__
                desktop.open('http://127.0.0.1/', 'unused')
                second = thread.call_args.kwargs['target'].__self__
                self.assertEqual((first.slot, second.slot), (0, 1))
                profile = Path(root) / '0'
                profile.mkdir()
                (profile / 'appearance').write_text('preserved')
                with patch.object(first, '_run'):
                    first.run('unused', 'unused')
                self.assertEqual((profile / 'appearance').read_text(), 'preserved')
                desktop.open('http://127.0.0.1/', 'unused')
                reused = thread.call_args.kwargs['target'].__self__
                self.assertEqual(reused.slot, 0)

    def test_unknown_and_non_string_keys_cannot_select_window(self):
        desktop = cc.DesktopWindows()
        for key in ('', 'a' * 32, None, {}, 123):
            self.assertEqual(desktop.status(key), {'attached': False, 'maximized': False})
            with self.assertRaises(cc.VaultError):
                desktop.action(key, 'theme', GRAPHITE)

    def test_http_can_only_recolour_a_registered_live_host(self):
        desktop = cc.DesktopWindows()
        host = SimpleNamespace(alive=Mock(return_value=True), hwnd=123, u=Mock(), theme=dict(GRAPHITE))
        host.u.IsZoomed.return_value = False
        desktop.windows['registered'] = host
        result = desktop.action('registered', 'theme', FROST)
        self.assertEqual(result['result'], 'applied')
        host.u.PostMessageW.assert_called_once_with(123, cc.WM_APP_THEME, 0, 0)
        self.assertEqual(host.theme['bar'], '#edf0f5')
        self.assertEqual(desktop.theme, host.theme)  # the next window starts in the page's colours
        host.u.PostMessageW.reset_mock()
        # Moving, sizing and window commands are Windows' own (native title bar): never HTTP actions.
        for action in ('drag', 'minimize', 'maximize', 'close', 'resize-left', 'resize-bottom-right', 'terminate', None):
            with self.assertRaises(cc.VaultError):
                desktop.action('registered', action, FROST)
        with self.assertRaises(cc.VaultError):
            desktop.action('registered', 'theme', dict(FROST, bar='red'))
        host.alive.return_value = False
        with self.assertRaises(cc.VaultError):
            desktop.action('registered', 'theme', FROST)
        host.u.PostMessageW.assert_not_called()
        self.assertEqual(cc.DesktopWindows.ACTIONS, ('theme',))

    def test_theme_colours_are_validated_strictly(self):
        self.assertEqual(cc.desktop_theme(FROST)['bar'], '#edf0f5')
        self.assertEqual(set(cc.desktop_theme(GRAPHITE)), set(cc.DESKTOP_THEME_KEYS))
        bad = [None, [], 'theme', {}, dict(FROST, extra='#000000'), {k: v for k, v in FROST.items() if k != 'text'}]
        bad += [dict(FROST, bar=value) for value in ('#fff', 'red', '#12345g', '#1234567', ' #123456', '#123456\n', 0x123456, None)]
        for colors in bad:
            with self.assertRaises(cc.VaultError, msg=repr(colors)):
                cc.desktop_theme(colors)

    def test_colour_helpers(self):
        self.assertEqual(cc.colorref('#112233'), 0x332211)
        self.assertEqual(cc.shade('#c42b1c', 0.5), '#62160e')
        self.assertEqual(cc.shade('#ffffff', 2), '#ffffff')

    def test_caption_hit_test_geometry(self):
        hit = cc.caption_hit_test
        width = 1000
        # 96 DPI: 32 px strip, 46 px buttons, 5 px top resize band.
        self.assertEqual(cc.caption_metrics(96), (32, 46, 5))
        self.assertEqual(hit(500, 2, width, 96, False), cc.HTTOP)
        self.assertEqual(hit(3, 2, width, 96, False), cc.HTTOPLEFT)
        self.assertEqual(hit(997, 2, width, 96, False), cc.HTTOPRIGHT)
        self.assertEqual(hit(500, 2, width, 96, True), cc.HTCAPTION)  # maximized: no resize band
        self.assertEqual(hit(500, 16, width, 96, False), cc.HTCAPTION)
        self.assertEqual(hit(10, 16, width, 96, False), cc.HTCAPTION)  # the icon drags too
        self.assertEqual(hit(999, 16, width, 96, False), cc.HTCLOSE)
        self.assertEqual(hit(954, 16, width, 96, False), cc.HTCLOSE)
        self.assertEqual(hit(953, 16, width, 96, False), cc.HTMAXBUTTON)
        self.assertEqual(hit(908, 16, width, 96, False), cc.HTMAXBUTTON)
        self.assertEqual(hit(907, 16, width, 96, False), cc.HTMINBUTTON)
        self.assertEqual(hit(862, 16, width, 96, False), cc.HTMINBUTTON)
        self.assertEqual(hit(861, 16, width, 96, False), cc.HTCAPTION)
        self.assertEqual(hit(500, 31, width, 96, False), cc.HTCAPTION)
        self.assertEqual(hit(500, 32, width, 96, False), cc.HTCLIENT)  # below the strip: the page
        self.assertEqual(hit(-1, 16, width, 96, False), cc.HTCLIENT)
        # 150 %: everything scales.
        self.assertEqual(cc.caption_metrics(144), (48, 69, 8))
        self.assertEqual(hit(1000 - 69, 40, width, 144, False), cc.HTCLOSE)
        self.assertEqual(hit(1000 - 70, 40, width, 144, False), cc.HTMAXBUTTON)
        self.assertEqual(hit(500, 7, width, 144, False), cc.HTTOP)
        self.assertEqual(hit(500, 47, width, 144, False), cc.HTCAPTION)
        self.assertEqual(hit(500, 48, width, 144, False), cc.HTCLIENT)

    def test_embedded_icon_is_the_logo_at_every_size(self):
        data = cc.app_icon()
        images = cc.icon_images(data)
        self.assertEqual([size for size, _ in images], [16, 20, 24, 32, 40, 48, 64, 96, 128, 256])
        for size, image in images:
            self.assertTrue(image.startswith(b'\x89PNG\r\n\x1a\n'), size)
            self.assertEqual(struct.unpack('>II', image[16:24]), (size, size))
        self.assertTrue(cc.icon_image(data, 16) == images[0][1])
        self.assertTrue(cc.icon_image(data, 30) == images[3][1])  # smallest image at least that big
        self.assertTrue(cc.icon_image(data, 512) == images[-1][1])
        for broken in (b'', b'\x00\x00\x01\x00', b'\x00\x00\x02\x00\x01\x00' + b'\x00' * 16,
                       data[:6] + b'\x10\x10\x00\x00\x01\x00\x20\x00' + struct.pack('<II', 10 ** 7, 22)):
            with self.assertRaises(ValueError):
                cc.icon_images(broken)

    def test_icon_block_is_generated_from_the_logo(self):
        text = SOURCE.read_text(encoding='utf-8')
        self.assertEqual(text.count('# BEGIN GENERATED app-icon:'), 1)
        self.assertIn('src/saver/assets/arkuzo-logo-512.png', text[text.index('# BEGIN GENERATED app-icon:'):][:200])
        self.assertTrue((ROOT / 'src/saver/assets/arkuzo-logo-512.png').is_file())

    def test_icon_file_is_written_once_for_the_taskbar(self):
        self.assertIsNone(cc.DesktopWindows().icon_file())
        with tempfile.TemporaryDirectory() as root:
            desktop = cc.DesktopWindows(Path(root) / 'desktop-browser')
            path = desktop.icon_file()
            self.assertEqual(path.read_bytes(), cc.app_icon())
            stamp = path.stat().st_mtime_ns
            self.assertEqual(desktop.icon_file(), path)
            self.assertEqual(path.stat().st_mtime_ns, stamp)

    def test_taskbar_identity(self):
        self.assertEqual(cc.DESKTOP_APP_ID, 'Arkuzo.MemorySaver.ControlCenter')
        data = Path(tempfile.gettempdir()) / 'arkuzo data'
        command = cc.desktop_relaunch_command(data, cc.DEFAULT_PORT)
        self.assertIn('"' + str(data) + '"', command)
        self.assertIn(str(SOURCE.resolve()), command)
        self.assertNotIn('--port', command)
        self.assertTrue(cc.desktop_relaunch_command(data, 50000).endswith('--port 50000'))
        # The process ID is set before any window of the process exists.
        main = SOURCE.read_text(encoding='utf-8')
        main = main[main.index('def main(argv=None):'):]
        self.assertLess(main.index('set_process_app_id()'), main.index('App(data, args.port)'))
        self.assertLess(main.index('set_process_app_id()'), main.index('open_window('))

    @unittest.skipUnless(os.name == 'nt', 'Windows API')
    def test_win32_prototypes_bind(self):
        api = cc._desktop_win32()
        self.assertIs(api, cc._desktop_win32())
        self.assertGreaterEqual(api.u.GetDpiForSystem(), 96)
        self.assertEqual(bytes(cc._guid(api, cc._AUMID_KEYS).data)[:4], bytes.fromhex('55284c9f'))

    def test_recycled_browser_window_owner_is_rejected(self):
        host = cc._DesktopHost(cc.DesktopWindows(), 'test')
        host.attached, host.hwnd, host.child = True, 1, 2
        host.proc = SimpleNamespace(pid=999, poll=lambda: None)
        host.u = Mock()
        host.u.IsWindow.return_value = True
        # GetWindowThreadProcessId leaves owner zero, simulating foreign HWND.
        self.assertFalse(host.alive())

    def test_http_auth_and_no_caller_supplied_handle(self):
        desktop = cc.DesktopWindows()
        app = SimpleNamespace(port=0, desktop=desktop, token='secret')
        server = cc.make_server(app)
        app.port = server.server_port
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = 'http://127.0.0.1:' + str(server.server_port)

        def request(method, token='', body=None):
            req = urllib.request.Request(base + '/api/desktop-window?key=unknown',
                headers={'X-Arkuzo-Token': token, 'Content-Type': 'application/json'},
                data=json.dumps(body).encode() if body is not None else None, method=method)
            try:
                with urllib.request.urlopen(req) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as exc:
                return exc.code, json.load(exc)
        try:
            self.assertEqual(request('GET')[0], 403)
            self.assertEqual(request('GET', 'secret'), (200, {'attached': False, 'maximized': False}))
            self.assertEqual(request('POST', body={'key': 'unknown', 'action': 'theme', 'colors': GRAPHITE})[0], 403)
            self.assertEqual(request('POST', 'secret', {'hwnd': 1, 'action': 'theme', 'colors': GRAPHITE})[0], 400)
            self.assertEqual(request('POST', 'secret', {'key': 'unknown', 'action': 'drag'})[0], 400)
            self.assertEqual(request('POST', 'secret', {'key': 'unknown', 'action': 'theme', 'colors': GRAPHITE})[0], 400)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_page_title_handshake_matches_host_lookup(self):
        # The host finds Edge's window by the key in its title; the page puts it there.
        page = (ROOT / 'src/saver/control-center/03-app.js').read_text(encoding='utf-8-sig')
        self.assertIn("document.title = 'Arkuzo Memory Saver · ' + key;", page)
        self.assertTrue(re.search(r"if self\.key in title", SOURCE.read_text(encoding='utf-8')))


if __name__ == '__main__':
    unittest.main()
