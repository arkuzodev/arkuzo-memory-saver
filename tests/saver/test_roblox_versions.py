"""The Roblox tab's backend (docs/roblox-versions.md): weao.gg parsing of hostile data, the build
the selected exploits support, Roblox's package manifest, verified and atomic installs from a fake
CDN (checksums, mirrors, cancel, failure cleanup, hostile ZIPs), removal rules and the routes.
Nothing here talks to the real weao.gg or Roblox: fake servers on ephemeral ports stand in."""
import hashlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('control_center_roblox', ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.py')
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)

V1, V2, V3 = 'version-4ea8e85481e34f46', 'version-f0ea5da9412f4e35', 'version-2fc79d515be6449d'


def exploit(ident, title, rbx, platform='Windows', **extra):
    row = {'_id': ident, 'title': title, 'version': '1.0', 'updatedDate': '11/10/2026 at 5:04 PM UTC', 'rbxversion': rbx,
           'updateStatus': rbx == V1, 'platform': platform, 'extype': 'wexecutor', 'detected': False, 'free': True, 'beta': False}
    row.update(extra)
    return row


def make_zip(entries: dict) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in entries.items():
            z.writestr(name, data)
    return buf.getvalue()


class FakeWeb:
    """One fake server for weao.gg, Roblox's version service and three CDN mirrors (by path prefix)."""

    def __init__(self):
        self.routes, self.seen, self.slow = {}, [], None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                owner.seen.append((self.path, self.headers.get('User-Agent')))
                if self.path.startswith('/weao/') and (self.headers.get('User-Agent') or '').startswith('Python-urllib'):
                    return self._reply(403, b'{"error":"blocked"}')  # Like weao.gg's Cloudflare rule.
                route = owner.routes.get(self.path)
                if route is None:
                    return self._reply(403, b'<Error>AccessDenied</Error>')  # Roblox's CDN: unknown build = 403.
                status, body, headers = route if len(route) == 3 else (route[0], route[1], {})
                if owner.slow and self.path.endswith(owner.slow):
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    for i in range(0, len(body), 4096):
                        self.wfile.write(body[i:i + 4096])
                        time.sleep(0.05)
                    return
                self._reply(status, body, headers)

            def _reply(self, status, body, headers=None):
                self.send_response(status)
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.base = f'http://127.0.0.1:{self.server.server_address[1]}'
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class WebTestCase(unittest.TestCase):
    def setUp(self):
        self.web = FakeWeb()
        self.saved = {k: getattr(cc, k) for k in ('url_allowed', 'ROBLOX_SETUP_BASES', 'WEAO_API', 'ROBLOX_CLIENT_VERSION_URL')}
        base = self.web.base
        cc.url_allowed = lambda url: url.startswith(base + '/')
        cc.ROBLOX_SETUP_BASES = (base + '/cdn1/', base + '/cdn2/', base + '/cdn3/')
        cc.WEAO_API = base + '/weao'
        cc.ROBLOX_CLIENT_VERSION_URL = base + '/roblox/client-version'
        self.root = Path(tempfile.mkdtemp())

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(cc, k, v)
        self.web.close()
        shutil.rmtree(self.root, ignore_errors=True)

    def publish_build(self, version, mirrors=('cdn1',), extra=None, corrupt=None):
        """Put a small fake build on the fake CDN; returns the player's bytes."""
        player = b'MZ fake player ' + version.encode()
        packages = {
            'RobloxApp.zip': make_zip({'RobloxPlayerBeta.exe': player, 'RobloxPlayerBeta.dll': b'dll'}),
            'content-fonts.zip': make_zip({'arial.ttf': b'font', 'sub/x.otf': b'otf'}),
            'shaders.zip': make_zip({'shaders_d3d11.pack': b'shader' * 100}),
        }
        packages.update(extra or {})
        lines = ['v0']
        for name, data in packages.items():
            size = sum(i.file_size for i in zipfile.ZipFile(io.BytesIO(data)).infolist())
            lines += [name, hashlib.md5(data).hexdigest(), str(len(data)), str(size)]
        lines += ['RobloxPlayerInstaller.exe', hashlib.md5(b'installer').hexdigest(), '9', '9']
        lines += ['WebView2RuntimeInstaller.zip', hashlib.md5(b'wv').hexdigest(), '2', '2']
        files = f'RobloxPlayerBeta.exe\r\n{hashlib.md5(player).hexdigest()}\r\ncontent\\fonts\\arial.ttf\r\n{hashlib.md5(b"font").hexdigest()}\r\n'
        for mirror in mirrors:
            self.web.routes[f'/{mirror}/{version}-rbxPkgManifest.txt'] = (200, '\r\n'.join(lines).encode() + b'\r\n')
            self.web.routes[f'/{mirror}/{version}-rbxManifest.txt'] = (200, files.encode())
            for name, data in packages.items():
                self.web.routes[f'/{mirror}/{version}-{name}'] = (200, data if name != corrupt else data[:-3] + b'xyz')
        return player


class WeaoParsingTests(unittest.TestCase):
    def test_versions_keep_only_a_valid_windows_build(self):
        raw = {'Windows': V1, 'WindowsDate': '11/10/2026, 5:01:13 PM UTC', 'WindowsResponse': {'version': '0.747.0.7471481'}, 'Mac': V3}
        self.assertEqual(cc.parse_weao_versions(raw), {'version': V1, 'date': '11/10/2026, 5:01:13 PM UTC', 'build': '0.747.0.7471481'})
        for hostile in (None, [], 'x', {'Windows': 'version-../../../evil'}, {'Windows': V1.upper()}, {'Windows': V1 + '0'},
                        {'Windows': '<script>alert(1)</script>'}, {'Mac': V3}, {'Windows': 7}):
            self.assertEqual(cc.parse_weao_versions(hostile), {}, hostile)
        odd = cc.parse_weao_versions({'Windows': V1, 'WindowsDate': '\x00' + 'x' * 500, 'WindowsResponse': {'version': '1.2; rm -rf'}})
        self.assertEqual((len(odd['date']), odd['build']), (40, None))

    def test_exploit_rows_are_validated_and_only_windows_builds_are_sources(self):
        raw = [
            exploit('a1', 'Volt', V2, multiInject=True, uncPercentage=99, suncPercentage=100),
            exploit('a2', 'Xeno', V1),
            exploit('a3', 'Delta', '2.729.840', platform='Android'),
            exploit('a4', 'Delta', '2.729.838', platform='iOS'),
            exploit('a5', 'MacSploit', V3, platform='Mac'),  # A valid-looking hash, but a Mac build.
            exploit('a6', 'Gone', V2, hidden=True),
            exploit('a7', 'Broken', 'version-zzzz'),
            exploit('a1', 'Duplicate id', V1),
            exploit('bad id!', 'Bad', V1),
            exploit('a8', '', V1),
            exploit('a9', 'Evil\x07<b>name</b>', V1, uncPercentage=250, suncPercentage=True, websitelink='https://evil.example'),
            'not a row', None, 5,
        ]
        rows = {r['id']: r for r in cc.parse_weao_exploits(raw)}
        self.assertEqual(set(rows), {'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a9'})
        self.assertEqual((rows['a1']['robloxVersion'], rows['a1']['usable'], rows['a1']['multiInstance'], rows['a1']['unc']), (V2, True, True, 99))
        for ident in ('a3', 'a4', 'a5'):
            self.assertFalse(rows[ident]['usable'], ident)
            self.assertIsNone(rows[ident]['robloxVersion'], ident)
            self.assertEqual(rows[ident]['reason'], 'Not a Windows exploit')
        self.assertEqual(rows['a3']['listedVersion'], '2.729.840')
        self.assertEqual((rows['a6']['usable'], rows['a6']['reason']), (False, 'No longer listed on weao.gg'))
        self.assertEqual((rows['a7']['usable'], rows['a7']['reason']), (False, 'Lists no valid Roblox build'))
        self.assertEqual(rows['a9']['title'], 'Evil <b>name</b>', 'control characters go; the page renders it as text')
        self.assertEqual((rows['a9']['unc'], rows['a9']['sunc']), (None, None))
        self.assertFalse(any('evil.example' in json.dumps(r) for r in rows.values()), 'links are dropped')
        ordered = [r['id'] for r in cc.parse_weao_exploits(raw)]
        self.assertEqual(set(ordered[:2]), {'a2', 'a9'}, 'usable and updated first')
        for hostile in (None, {}, 'x', 7):
            self.assertEqual(cc.parse_weao_exploits(hostile), [])
        self.assertEqual(len(cc.parse_weao_exploits([exploit(f'id{i}', f'E{i}', V1) for i in range(800)])), 500)


class ExploitBuildTests(unittest.TestCase):
    def setUp(self):
        self.rows = cc.parse_weao_exploits([exploit('w', 'Wave', V2), exploit('v', 'Volt', V2), exploit('x', 'Xeno', V1),
                                            exploit('m', 'MacSploit', V3, platform='Mac'), exploit('s', 'Synapse', V2)])

    def test_one_exploit(self):
        r = cc.exploit_build(self.rows, ['x'], V1)
        self.assertEqual((r['version'], r['current'], r['notes']), (V1, True, []))

    def test_several_that_agree_and_none_updated(self):
        r = cc.exploit_build(self.rows, ['w', 'v', 's'], V1)
        self.assertEqual((r['version'], r['current'], r['conflict']), (V2, False, []))
        self.assertEqual(len(r['notes']), 2)
        self.assertIn('not Roblox\'s current build', r['notes'][0])
        self.assertIn('Wave, Volt, Synapse are not updated', r['notes'][1])

    def test_conflict(self):
        r = cc.exploit_build(self.rows, ['v', 'x'], V1)
        self.assertIsNone(r['version'])
        self.assertEqual({c['version']: c['exploits'] for c in r['conflict']}, {V2: ['Volt'], V1: ['Xeno']})
        self.assertIn('different Roblox builds', r['reason'])

    def test_refused_rows_unknown_ids_and_empty(self):
        r = cc.exploit_build(self.rows, ['m', 'x'], V1)
        self.assertIsNone(r['version'])
        self.assertIn('MacSploit (Mac): Not a Windows exploit', r['reason'])
        for bad in ([], None, 'x', ['nope'], [5], ['x'] * 61):
            with self.assertRaises(cc.VaultError):
                cc.exploit_build(self.rows, bad, V1)


class ManifestTests(unittest.TestCase):
    MANIFEST = 'v0\r\nRobloxApp.zip\r\n' + 'a' * 32 + '\r\n10\r\n20\r\nRobloxPlayerInstaller.exe\r\n' + 'b' * 32 + '\r\n5\r\n5\r\n' \
               'WebView2RuntimeInstaller.zip\r\n' + 'c' * 32 + '\r\n3\r\n3\r\ncontent-textures3.zip\r\n' + 'd' * 32 + '\r\n7\r\n9\r\n'

    def test_parse_and_plan(self):
        packages = cc.parse_package_manifest(self.MANIFEST)
        self.assertEqual([p['name'] for p in packages], ['RobloxApp.zip', 'RobloxPlayerInstaller.exe', 'WebView2RuntimeInstaller.zip', 'content-textures3.zip'])
        self.assertEqual(packages[0], {'name': 'RobloxApp.zip', 'md5': 'a' * 32, 'packed': 10, 'size': 20})
        plan = cc.plan_packages(packages)
        self.assertEqual([(p['name'], p['folder']) for p in plan], [('RobloxApp.zip', ''), ('content-textures3.zip', 'PlatformContent/pc/textures')],
                         'Roblox\'s installer and the WebView2 installer are never installed')

    def test_damaged_or_unknown(self):
        for bad in ('', 'v1\nRobloxApp.zip\n' + 'a' * 32 + '\n1\n1', 'v0\nRobloxApp.zip\n' + 'a' * 32 + '\n1',
                    'v0\n../evil.zip\n' + 'a' * 32 + '\n1\n1', 'v0\nRobloxApp.zip\nnot-md5\n1\n1', 'v0\nRobloxApp.zip\n' + 'a' * 32 + '\n-1\n1',
                    'v0\nRobloxApp.zip\n' + 'a' * 32 + '\n1\n1\nRobloxApp.zip\n' + 'a' * 32 + '\n1\n1'):
            with self.assertRaises(cc.VaultError, msg=bad):
                cc.parse_package_manifest(bad)
        with self.assertRaisesRegex(cc.VaultError, 'content-new.zip'):
            cc.plan_packages(cc.parse_package_manifest(self.MANIFEST + 'content-new.zip\r\n' + 'e' * 32 + '\r\n1\r\n1\r\n'))
        with self.assertRaisesRegex(cc.VaultError, 'RobloxApp.zip'):
            cc.plan_packages([{'name': 'ssl.zip', 'md5': 'a' * 32, 'packed': 1, 'size': 1}])

    def test_file_manifest(self):
        files = cc.parse_file_manifest('RobloxPlayerBeta.exe\r\n' + 'a' * 32 + '\r\ncontent\\fonts\\A.ttf\r\n' + 'b' * 32 + '\r\n')
        self.assertEqual(files, {'robloxplayerbeta.exe': 'a' * 32, 'content/fonts/a.ttf': 'b' * 32})


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_hostile_paths_are_refused(self):
        for name in ('../evil.txt', 'a/../../evil.txt', 'C:/Windows/evil.txt', '/abs/evil.txt', 'C:evil.txt'):
            archive = self.tmp / 'p.zip'
            archive.write_bytes(make_zip({'ok.txt': b'ok', name: b'evil'}))
            target = self.tmp / 'build' / 'sub'
            if name == '/abs/evil.txt':
                # A leading slash is stripped to a path inside the target, which is safe.
                self.assertEqual(cc.extract_package(archive, target, 100), 6)
                self.assertTrue((target / 'abs' / 'evil.txt').is_file())
            else:
                with self.assertRaises(cc.VaultError, msg=name):
                    cc.extract_package(archive, target, 100)
            self.assertFalse((self.tmp / 'build' / 'evil.txt').exists(), name)
            self.assertFalse((self.tmp / 'evil.txt').exists(), name)
            shutil.rmtree(self.tmp / 'build', ignore_errors=True)

    def test_size_limit_and_backslashes(self):
        archive = self.tmp / 'p.zip'
        archive.write_bytes(make_zip({'big.bin': b'x' * 5000}))
        with self.assertRaisesRegex(cc.VaultError, 'larger'):
            cc.extract_package(archive, self.tmp / 'build', 1000)
        archive.write_bytes(make_zip({'dir\\file.txt': b'abc'}))
        self.assertEqual(cc.extract_package(archive, self.tmp / 'build2', 1000), 3)
        self.assertTrue((self.tmp / 'build2' / 'dir' / 'file.txt').is_file())

    def test_files_keep_roblox_file_times(self):
        """The saver's Auto choice ranks builds by the player's file time: an old build installed
        today must keep its old time, not look like the newest build."""
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w') as z:
            z.writestr(zipfile.ZipInfo('RobloxPlayerBeta.exe', date_time=(2026, 5, 23, 8, 21, 4)), b'MZ')
        archive = self.tmp / 'p.zip'
        archive.write_bytes(buf.getvalue())
        cc.extract_package(archive, self.tmp / 'build3', 100)
        stamp = time.localtime(os.path.getmtime(self.tmp / 'build3' / 'RobloxPlayerBeta.exe'))
        self.assertEqual((stamp.tm_year, stamp.tm_mon, stamp.tm_mday, stamp.tm_hour, stamp.tm_min), (2026, 5, 23, 8, 21))


class InstallTests(WebTestCase):
    def install(self, version, cancel=None):
        steps = []
        marker = cc.install_roblox_build(version, self.root, lambda **k: steps.append(k), cancel or threading.Event())
        return marker, steps

    def test_install_lays_out_a_complete_verified_build(self):
        player = self.publish_build(V1)
        marker, steps = self.install(V1)
        build = self.root / 'Versions' / V1
        self.assertEqual((build / 'RobloxPlayerBeta.exe').read_bytes(), player)
        self.assertTrue((build / 'content' / 'fonts' / 'sub' / 'x.otf').is_file())
        self.assertTrue((build / 'shaders' / 'shaders_d3d11.pack').is_file())
        self.assertEqual((build / 'AppSettings.xml').read_bytes(), cc.ROBLOX_APP_SETTINGS.encode())
        self.assertIn(b'<ContentFolder>content</ContentFolder>\r\n', (build / 'AppSettings.xml').read_bytes())
        self.assertFalse((build / 'RobloxPlayerInstaller.exe').exists(), 'Roblox\'s installer is never put there')
        self.assertFalse((build / 'WebView2RuntimeInstaller').exists())
        self.assertEqual(json.loads((build / cc.ROBLOX_INSTALL_MARKER).read_text())['version'], V1)
        self.assertEqual(marker['packages'], ['RobloxApp.zip', 'content-fonts.zip', 'shaders.zip'])
        self.assertTrue(cc.roblox_build_complete(build))
        self.assertEqual(list((self.root / '.staging').iterdir()), [], 'the staging folder is gone')
        self.assertTrue(any(s.get('phase', '').startswith('Downloading') for s in steps))
        self.assertFalse(any('Installer' in path for path, _ in self.web.seen), 'Roblox\'s installer is never downloaded')
        with self.assertRaisesRegex(cc.VaultError, 'already installed'):
            self.install(V1)

    def test_checksum_mismatch_on_every_mirror_installs_nothing(self):
        self.publish_build(V1, mirrors=('cdn1', 'cdn2', 'cdn3'), corrupt='shaders.zip')
        with self.assertRaisesRegex(cc.VaultError, 'shaders.zip.*checksum'):
            self.install(V1)
        self.assertFalse((self.root / 'Versions' / V1).exists())
        self.assertEqual(list((self.root / '.staging').iterdir()), [])

    def test_a_bad_mirror_falls_back_to_the_next(self):
        self.publish_build(V1, mirrors=('cdn2',))
        self.publish_build(V1, mirrors=('cdn1',), corrupt='content-fonts.zip')
        self.web.routes[f'/cdn1/{V1}-shaders.zip'] = (500, b'oops')
        self.install(V1)
        self.assertTrue(cc.roblox_build_complete(self.root / 'Versions' / V1))
        self.assertIn((f'/cdn2/{V1}-shaders.zip', cc.ROBLOX_UA), self.web.seen)

    def test_unknown_build_and_redirects(self):
        with self.assertRaisesRegex(cc.VaultError, 'not on Roblox\'s CDN'):
            self.install(V2)
        self.publish_build(V1)
        self.web.routes[f'/cdn1/{V1}-shaders.zip'] = (302, b'', {'Location': 'http://127.0.0.1:1/evil.zip'})
        with self.assertRaisesRegex(cc.VaultError, 'shaders.zip'):
            self.install(V1)
        self.assertFalse((self.root / 'Versions' / V1).exists())
        self.assertFalse(any('evil' in path for path, _ in self.web.seen), 'the redirect is not followed')
        with self.assertRaises(cc.VaultError):
            self.install('version-../../evil00')

    def test_player_must_match_the_file_manifest(self):
        self.publish_build(V1)
        self.web.routes[f'/cdn1/{V1}-rbxManifest.txt'] = (200, ('RobloxPlayerBeta.exe\r\n' + '0' * 32 + '\r\n').encode())
        with self.assertRaisesRegex(cc.VaultError, 'file manifest'):
            self.install(V1)
        self.assertFalse((self.root / 'Versions' / V1).exists())

    def test_an_incomplete_folder_in_the_way_is_not_overwritten(self):
        self.publish_build(V1)
        (self.root / 'Versions' / V1).mkdir(parents=True)
        (self.root / 'Versions' / V1 / 'RobloxPlayerBeta.exe').write_bytes(b'locked leftover')
        with self.assertRaisesRegex(cc.VaultError, 'not a complete build'):
            self.install(V1)
        self.assertEqual((self.root / 'Versions' / V1 / 'RobloxPlayerBeta.exe').read_bytes(), b'locked leftover')

    def test_cancel_and_status_through_the_manager(self):
        self.publish_build(V1, extra={'extracontent-models.zip': make_zip({'big.bin': os.urandom(400000)})})
        self.web.slow = 'extracontent-models.zip'
        data = Path(tempfile.mkdtemp())
        try:
            cc.update_vault_settings(data, {'robloxVersionsDir': str(self.root)})
            manager = cc.RobloxVersions(data)
            status = manager.start_install(V1)
            self.assertEqual(status['state'], 'running')
            with self.assertRaisesRegex(cc.VaultError, 'already running'):
                manager.start_install(V1)
            deadline = time.time() + 20
            while 'extracontent' not in manager.progress().get('phase', '') and time.time() < deadline:
                time.sleep(0.02)
            manager.cancel()
            manager.thread.join(20)
            self.assertEqual(manager.progress()['state'], 'cancelled')
            self.assertFalse((self.root / 'Versions' / V1).exists())
            self.assertEqual(list((self.root / '.staging').iterdir()), [])
            with self.assertRaisesRegex(cc.VaultError, 'No install'):
                manager.cancel()
            self.web.slow = None
            manager.start_install(V1)
            manager.thread.join(30)
            self.assertEqual(manager.progress()['state'], 'done', manager.progress())
            view = manager.view(cached_only=True)
            mine = [b for b in view['builds'] if b['managed']]
            self.assertEqual([(b['version'], b['complete'], b['removable']) for b in mine], [(V1, True, True)])
            self.assertGreater(mine[0]['bytes'], 0)
            self.assertEqual(view['root'], str(self.root))
        finally:
            shutil.rmtree(data, ignore_errors=True)

    def test_stale_staging_is_cleaned_but_a_live_one_is_kept(self):
        staging = self.root / '.staging'
        (staging / 'install-old').mkdir(parents=True)
        (staging / 'install-live').mkdir()
        (staging / 'install-live' / '.busy').write_text('x')
        old = time.time() - cc.ROBLOX_STAGING_STALE_SEC - 60
        os.utime(staging / 'install-old', (old, old))
        cc.clean_staging(staging)
        self.assertEqual([p.name for p in staging.iterdir()], ['install-live'])


class CatalogTests(WebTestCase):
    def publish_weao(self):
        self.web.routes['/weao/versions/current'] = (200, json.dumps({'Windows': V1, 'WindowsResponse': {'version': '0.747.0.7471481'}}).encode())
        self.web.routes['/weao/versions/past'] = (200, json.dumps({'Windows': V2}).encode())
        self.web.routes['/weao/versions/future'] = (200, b'not json')
        self.web.routes['/weao/status/exploits'] = (200, json.dumps([exploit('v', 'Volt', V2), exploit('x', 'Xeno', V1)]).encode())
        self.web.routes['/roblox/client-version'] = (200, json.dumps({'version': '0.747.0.7471481', 'clientVersionUpload': V1}).encode())

    def test_catalog_sends_weaos_user_agent_and_tolerates_bad_parts(self):
        self.publish_weao()
        catalog = cc.fetch_roblox_catalog()
        self.assertEqual(catalog['roblox'], {'version': V1, 'build': '0.747.0.7471481'})
        self.assertEqual((catalog['weao']['current']['version'], catalog['weao']['past']['version'], catalog['weao']['future']), (V1, V2, {}))
        self.assertEqual([e['title'] for e in catalog['exploits']], ['Xeno', 'Volt'])
        self.assertEqual(catalog['errors'], [])
        agents = {path: agent for path, agent in self.web.seen if path.startswith('/weao/')}
        self.assertEqual(set(agents.values()), {cc.WEAO_UA}, 'weao.gg blocks Python\'s default user agent')

    def test_roblox_wins_when_weao_disagrees_and_failures_are_reported(self):
        self.publish_weao()
        self.web.routes['/weao/versions/current'] = (200, json.dumps({'Windows': V2}).encode())
        catalog = cc.fetch_roblox_catalog()
        self.assertEqual(cc.RobloxVersions.current_version(catalog), V1)
        del self.web.routes['/roblox/client-version']
        del self.web.routes['/weao/status/exploits']
        catalog = cc.fetch_roblox_catalog()
        self.assertEqual(cc.RobloxVersions.current_version(catalog), V2, 'weao.gg is the fallback')
        self.assertEqual(len(catalog['errors']), 2)

    def test_the_catalog_is_cached_and_concurrent_fetches_merge(self):
        calls = []
        real = cc.fetch_roblox_catalog

        def slow():
            calls.append(1)
            time.sleep(0.3)
            return {'roblox': {'version': V1}, 'weao': {}, 'exploits': [], 'errors': []}
        cc.fetch_roblox_catalog = slow
        try:
            manager = cc.RobloxVersions(self.root)
            self.assertIsNone(manager.catalog(cached_only=True), 'cached=1 never fetches')
            threads = [threading.Thread(target=manager.catalog) for _ in range(4)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            self.assertEqual(len(calls), 1)
            manager.catalog(refresh=True)
            self.assertEqual(len(calls), 1, 'a refresh within 15 s reuses the answer')
            manager.catalog_at -= cc.WEAO_REFRESH_MIN_SEC + 1
            manager.catalog(refresh=True)
            self.assertEqual(len(calls), 2)
            manager.catalog_at -= cc.WEAO_CACHE_SEC + 1
            manager.catalog()
            self.assertEqual(len(calls), 3)
        finally:
            cc.fetch_roblox_catalog = real

    def test_only_allowed_hosts(self):
        cc.url_allowed = self.saved['url_allowed']
        for url in ('https://setup.rbxcdn.com/version-x', 'https://weao.gg/api/versions/current', 'https://clientsettings.roblox.com/v2/x'):
            self.assertTrue(cc.url_allowed(url), url)
        for url in ('http://setup.rbxcdn.com/x', 'https://evil.example/x', 'https://setup.rbxcdn.com.evil.example/x', 'https://user@weao.gg/x',
                    'https://weao.gg:8443/x', 'https://cdn.weao.gg/slug/logo.png', 'file:///C:/x'):
            self.assertFalse(cc.url_allowed(url), url)
        with self.assertRaises(cc.WebError):
            cc.web_get('https://evil.example/x', 10)


class RemoveAndSettingsTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        for v in (V1, V2):
            folder = self.root / 'Versions' / v
            folder.mkdir(parents=True)
            (folder / 'RobloxPlayerBeta.exe').write_bytes(b'MZ')
            (folder / 'AppSettings.xml').write_text('x')

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_removal_rules(self):
        exe = str(self.root / 'Versions' / V1 / 'RobloxPlayerBeta.exe')
        with self.assertRaisesRegex(cc.VaultError, 'pinned'):
            cc.remove_roblox_build(self.root, V2, V2, [])
        with self.assertRaisesRegex(cc.VaultError, 'running client'):
            cc.remove_roblox_build(self.root, V1, 'auto', [(42, exe)])
        with self.assertRaisesRegex(cc.VaultError, 'Could not check'):
            cc.remove_roblox_build(self.root, V1, 'auto', None)
        with self.assertRaisesRegex(cc.VaultError, 'Only builds Arkuzo installed'):
            cc.remove_roblox_build(self.root, V3, 'auto', [])
        with self.assertRaises(cc.VaultError):
            cc.remove_roblox_build(self.root, '..', 'auto', [])
        with open(exe, 'rb'):  # A process holding a file: the rename fails, nothing is deleted.
            if os.name == 'nt':
                with self.assertRaisesRegex(cc.VaultError, 'in use'):
                    cc.remove_roblox_build(self.root, V1, 'auto', [])
                self.assertTrue(os.path.exists(exe))
        cc.remove_roblox_build(self.root, V1, 'auto', [(42, str(self.root / 'Versions' / V2 / 'RobloxPlayerBeta.exe'))])
        self.assertFalse((self.root / 'Versions' / V1).exists())
        self.assertTrue((self.root / 'Versions' / V2).exists())

    def test_versions_folder_setting(self):
        self.assertEqual(cc.validate_versions_dir(''), '')
        self.assertEqual(cc.validate_versions_dir('D:/Arkuzo/Roblox/'), 'D:\\Arkuzo\\Roblox')
        bad = ['relative\\path', 'D:\\a\\..\\..\\b', 'C:\\', 'D:\\x|y', 5, 'x' * 300, 'C:\\Windows\\Temp\\r']
        local = os.environ.get('LOCALAPPDATA')
        if local:
            bad += [os.path.join(local, 'Roblox', 'Versions'), os.path.join(local, 'Bloxstrap'), os.path.join(local, 'Fishstrap', 'x')]
        if os.environ.get('ProgramFiles'):
            bad.append(os.path.join(os.environ['ProgramFiles'], 'Roblox'))
        for value in bad:
            with self.assertRaises(cc.VaultError, msg=value):
                cc.validate_versions_dir(value)

    def test_vault_settings_validate_and_default(self):
        data = Path(tempfile.mkdtemp())
        try:
            settings = cc.load_vault(data)['settings']
            self.assertEqual((settings['robloxVersion'], settings['robloxVersionFallback'], settings['robloxVersionsDir']), ('auto', False, ''))
            self.assertEqual(cc.update_vault_settings(data, {'robloxVersion': V1, 'robloxVersionFallback': True})['robloxVersion'], V1)
            for bad in ({'robloxVersion': 'latest'}, {'robloxVersion': V1.upper()}, {'robloxVersion': None}, {'robloxVersionsDir': 'rel'}):
                with self.assertRaises(cc.VaultError, msg=bad):
                    cc.update_vault_settings(data, bad)
            raw = json.loads((data / 'accounts.json').read_text(encoding='utf-8'))
            raw['settings']['robloxVersion'] = '../evil'
            (data / 'accounts.json').write_text(json.dumps(raw), encoding='utf-8')
            self.assertEqual(cc.load_vault(data)['settings']['robloxVersion'], 'auto', 'a hand-edited bad value falls back to auto')
        finally:
            shutil.rmtree(data, ignore_errors=True)


class RouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = Path(tempfile.mkdtemp())
        cls.root = Path(tempfile.mkdtemp())
        cc.update_vault_settings(cls.data, {'robloxVersionsDir': str(cls.root)})
        cls.app = cc.App(cls.data, 0)
        cls.app.supervisor.initial_start = False
        cls.app.roblox.protocol_base = r'Software\ArkuzoTest\routes\Classes'  # Never Roblox's own keys.
        cc.Handler.app = cls.app
        cls.server = cc.ThreadingHTTPServer(('127.0.0.1', 0), cc.Handler)
        cls.port = cls.app.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.real_fetch = cc.fetch_roblox_catalog
        cls.fetches = []
        cc.fetch_roblox_catalog = lambda: cls.fetches.append(1) or {
            'roblox': {'version': V1}, 'weao': {}, 'errors': [],
            'exploits': cc.parse_weao_exploits([exploit('v', 'Volt', V2), exploit('x', 'Xeno', V1)])}

    @classmethod
    def tearDownClass(cls):
        cc.fetch_roblox_catalog = cls.real_fetch
        cls.server.shutdown()
        cls.server.server_close()
        shutil.rmtree(cls.data, ignore_errors=True)
        shutil.rmtree(cls.root, ignore_errors=True)

    def request(self, path, body=None, token=None):
        req = urllib.request.Request(f'http://127.0.0.1:{self.port}' + path, data=None if body is None else json.dumps(body).encode(),
                                     method='GET' if body is None else 'POST')
        if token:
            req.add_header('X-Arkuzo-Token', token)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_every_action_needs_the_token(self):
        for path in cc.ROBLOX_ROUTES:
            self.assertEqual(cc.POST_ROUTES[path][1], cc.Handler.AUTH_TOKEN, path)
            self.assertEqual(self.request(path, {'version': 'auto'})[0], 403, path)
            self.assertEqual(self.request(path, {'version': 'auto'}, token='wrong')[0], 403, path)
        self.assertNotIn('/api/roblox/install', cc.GET_ROUTES)
        self.assertEqual(self.request('/api/roblox/nothing', {}, token=self.app.token)[0], 404)

    def test_view_cached_does_not_fetch(self):
        before = len(self.fetches)
        status, view = self.request('/api/roblox?cached=1')
        self.assertEqual(status, 200)
        self.assertEqual(len(self.fetches), before)
        self.assertEqual(view['root'], str(self.root))
        self.assertEqual(view['selection']['version'], 'auto')
        status, view = self.request('/api/roblox')
        self.assertEqual((status, view['current']), (200, V1))

    def test_select_validates(self):
        token = self.app.token
        status, body = self.request('/api/roblox/select', {'version': '../../evil'}, token=token)
        self.assertEqual(status, 400)
        status, body = self.request('/api/roblox/select', {'version': 'version-0123456789abcdef'}, token=token)
        self.assertEqual((status, 'not installed' in body['error']), (400, True))
        build = self.root / 'Versions' / 'version-0123456789abcdef'
        build.mkdir(parents=True)
        (build / 'RobloxPlayerBeta.exe').write_bytes(b'MZ')
        status, body = self.request('/api/roblox/select', {'version': 'version-0123456789abcdef'}, token=token)
        self.assertEqual(status, 400, 'an incomplete build (no AppSettings.xml) cannot be pinned')
        (build / 'AppSettings.xml').write_text('x')
        status, body = self.request('/api/roblox/select', {'version': 'version-0123456789abcdef', 'fallback': True}, token=token)
        self.assertEqual(status, 200)
        self.assertEqual((body['result']['robloxVersion'], body['result']['robloxVersionFallback']), ('version-0123456789abcdef', True))
        status, body = self.request('/api/roblox/remove', {'version': 'version-0123456789abcdef'}, token=token)
        self.assertEqual(status, 400, 'the pinned build cannot be removed')
        self.assertEqual(self.request('/api/roblox/select', {'version': 'auto'}, token=token)[0], 200)
        self.assertEqual(self.request('/api/roblox/remove', {'version': 'version-0123456789abcdef'}, token=token)[0], 200)
        self.assertFalse(build.exists())

    def test_install_and_exploit_routes_validate(self):
        token = self.app.token
        for bad in ('', None, 'version-xyz', 'https://evil.example/x.zip', ['x']):
            self.assertEqual(self.request('/api/roblox/install', {'version': bad}, token=token)[0], 400, bad)
        self.assertEqual(self.request('/api/roblox/install/cancel', {}, token=token)[0], 400)
        status, body = self.request('/api/roblox/exploits', {'ids': ['v']}, token=token)
        self.assertEqual((status, body['result']['version'], body['result']['current']), (200, V2, False))
        status, body = self.request('/api/roblox/exploits', {'ids': ['v', 'x']}, token=token)
        self.assertEqual((status, body['result']['version'], len(body['result']['conflict'])), (200, None, 2))
        self.assertEqual(self.request('/api/roblox/exploits', {'ids': 'v'}, token=token)[0], 400)


if __name__ == '__main__':
    unittest.main()
