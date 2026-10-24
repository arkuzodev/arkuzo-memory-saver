import importlib.util
import json
import re
import shutil
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.py'
ENGINE = ROOT / 'src' / 'saver' / 'Arkuzo-Memory-Saver.ps1'
spec = importlib.util.spec_from_file_location('control_center', SOURCE)
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)


class FakeProc:
    _next = 900000

    def __init__(self):
        FakeProc._next += 1
        self.pid = FakeProc._next
        self.code = None
        self.killed = False

    def poll(self):
        return self.code

    def kill(self):
        self.killed = True
        self.code = 1


class ParsingTests(unittest.TestCase):
    def test_dotnet_round_trip_timestamps(self):
        self.assertAlmostEqual(cc.parse_utc('2026-10-22T07:40:45.9179814Z'), 1792654845.9179814, places=3)
        self.assertAlmostEqual(cc.parse_utc('2026-10-22T09:40:45.5+02:00'), cc.parse_utc('2026-10-22T07:40:45.5Z'), places=3)
        self.assertIsNone(cc.parse_utc('yesterday'))
        self.assertIsNone(cc.parse_utc(None))


class ConfigTests(unittest.TestCase):
    base = {'selected_preset': 'agressive', 'settings': {'target_ram_mb': 600, 'hard_limit': False}, 'health': {'enabled': True},
            'recovery': {'enabled': True, 'excluded_account_ids': []}, 'notes': 'keep me'}

    def test_valid_changes_merge_and_keep_unknown_existing_keys(self):
        merged, restart = cc.apply_config_changes(self.base, {'settings': {'target_ram_mb': 450, 'memory_priority': 'VeryLow'}, 'selected_preset': 'extreme'})
        self.assertEqual(merged['settings']['target_ram_mb'], 450)
        self.assertEqual(merged['settings']['memory_priority'], 'VeryLow')
        self.assertEqual(merged['notes'], 'keep me')
        self.assertEqual(restart, [])
        self.assertEqual(self.base['settings']['target_ram_mb'], 600, 'input must not be mutated')

    def test_restart_keys_are_reported(self):
        _, restart = cc.apply_config_changes(self.base, {'settings': {'hard_limit': True}})
        self.assertEqual(restart, ['hard_limit'])

    def test_invalid_changes_are_refused(self):
        for changes in ({'settings': {'target_ram_mb': 50}}, {'settings': {'target_ram_mb': True}}, {'settings': {'trim_every_sec': 1.5}},
                        {'settings': {'turbo': 1}}, {'nonsense': {}}, {'health': {'enabled': 'yes'}},
                        {'recovery': {'retry_base_sec': 600, 'retry_max_sec': 300}}, {'settings': {'priority': 'High'}}):
            with self.assertRaises(cc.ConfigError, msg=str(changes)):
                cc.apply_config_changes(self.base, changes)

    def test_account_recovery_toggle(self):
        account = '11111111-1111-4111-8111-111111111111'
        off = cc.set_account_recovery(self.base, account, False)
        self.assertEqual(off['recovery']['excluded_account_ids'], [account])
        on = cc.set_account_recovery(off, account.upper(), True)
        self.assertEqual(on['recovery']['excluded_account_ids'], [])
        with self.assertRaises(cc.ConfigError):
            cc.set_account_recovery(self.base, 'not-a-guid', False)

    def test_presets_match_engine(self):
        text = ENGINE.read_text(encoding='utf-8')
        body = re.search(r'function Get-ArkuzoPresets \{(.*?)\n\}', text, re.S).group(1)
        for name, values in cc.PRESETS.items():
            block = re.search(r"'" + name + r"' = \[ordered\]@\{(.*?)\n        \}", body, re.S).group(1)
            for key, value in values.items():
                match = re.search(r'\b' + key + r'\s*=\s*(\S+)', block)
                self.assertIsNotNone(match, f'{name}.{key} missing in engine')
                raw = match.group(1)
                engine_value = {'$true': True, '$false': False}.get(raw, raw.strip("'"))
                if isinstance(value, int) and not isinstance(value, bool):
                    engine_value = int(engine_value)
                self.assertEqual(engine_value, value, f'{name}.{key}')

    def test_schema_ranges_match_engine(self):
        text = ENGINE.read_text(encoding='utf-8')
        for function, section in (('Get-ArkuzoHealthPolicy', 'health'), ('Get-ArkuzoRestorePolicy', 'recovery')):
            body = re.search('function ' + function + r'\(.*?\n\}', text, re.S).group(0)
            ranges = dict((k, (int(a), int(b))) for k, a, b in re.findall(r'(\w+)\s*=\s*@\((\d+),(\d+)\)', body))
            for key, rule in cc.SCHEMA[section].items():
                if rule[0] == 'int':
                    self.assertEqual(ranges.get(key), (rule[1], rule[2]), f'{section}.{key}')


class StartupCommandTests(unittest.TestCase):
    def test_launcher_install_autostarts_the_launcher(self):
        root = Path(tempfile.mkdtemp())
        try:
            runtime = root / 'app' / 'control-center' / 'v9.9.9'
            runtime.mkdir(parents=True)
            (root / 'ArkuzoMemorySaver.exe').write_bytes(b'')
            original = cc.RUNTIME
            cc.RUNTIME = runtime
            try:
                self.assertEqual(cc.startup_command(root / 'data'), f'"{root / "ArkuzoMemorySaver.exe"}"')
            finally:
                cc.RUNTIME = original
        finally:
            shutil.rmtree(root)

    def test_checkout_autostarts_the_script(self):
        command = cc.startup_command(Path('C:/farm/data'))
        self.assertIn('Arkuzo-Control-Center.py', command)
        self.assertIn('--background', command)


class FeedTests(unittest.TestCase):
    def test_summaries_resolve_names_and_skip_noise(self):
        names = {'a': 'Farmer01'}
        event = cc.summarize_event({'time': '2026-10-22T07:40:45Z', 'event': 'RECOVERY_QUARANTINED', 'data': {'accountId': 'a', 'retryCount': 9}}, names)
        self.assertEqual(event['level'], 'critical')
        self.assertIn('Farmer01', event['text'])
        self.assertIsNone(cc.summarize_event({'event': 'RESOURCE_SAMPLE', 'data': {}}, names))
        self.assertIsNone(cc.summarize_event({'event': 'WORKING_SET_TRIM', 'data': {'pid': 1}}, names))
        self.assertIsNone(cc.summarize_event({'event': 'CLIENT_STATE_CHANGED', 'data': {'sample': {'state': 'WINDOW OPEN'}}}, names))
        self.assertIsNotNone(cc.summarize_event({'event': 'CLIENT_STATE_CHANGED', 'data': {'sample': {'state': 'STUCK CLIENT', 'pid': 4}}}, names))

    def test_log_tail_follows_new_lines_and_sessions(self):
        folder = Path(tempfile.mkdtemp())
        try:
            tail = cc.LogTail(folder)
            first = folder / 'Arkuzo-20261022-100000-1-part0.log'
            first.write_text(json.dumps({'time': '2026-10-22T10:00:00Z', 'event': 'SESSION_START', 'data': {'version': '1.2.0', 'mode': 'extreme'}}) + '\n', encoding='utf-8')
            tail.poll({})
            self.assertEqual(len(tail.since(0)), 1)
            with open(first, 'a', encoding='utf-8') as f:
                f.write(json.dumps({'event': 'WARNING', 'data': {'message': 'Volt busy'}}) + '\n{"partial')
            tail.poll({})
            self.assertEqual([e['text'] for e in tail.since(1)], ['Volt busy'])
            time.sleep(0.05)
            second = folder / 'Arkuzo-20261022-110000-2-part0.log'
            second.write_text(json.dumps({'event': 'SESSION_STOP', 'data': {'uptimeSeconds': 120, 'trims': 4}}) + '\n', encoding='utf-8')
            tail.poll({})
            self.assertIn('2 min', tail.since(2)[0]['text'])
        finally:
            shutil.rmtree(folder)


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.data = Path(tempfile.mkdtemp())
        self.launched = []

    def tearDown(self):
        shutil.rmtree(self.data)

    def make(self, **prefs):
        def launcher():
            proc = FakeProc()
            self.launched.append(proc)
            return proc
        sup = cc.Supervisor(self.data, dict({'autopilot': True, 'startSaverOnLaunch': True}, **prefs), cc.LogTail(self.data), launcher)
        return sup

    @staticmethod
    def heartbeat(proc, at):
        stamp = time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(at)) + '.0000000Z'
        return {'pid': proc.pid, 'startTicks': 1, 'updatedUtc': stamp}

    def test_starts_on_launch_and_reports_running(self):
        (self.data / 'controller.stop').write_text('x')
        sup = self.make()
        now = time.time()
        sup.tick(None, now)
        self.assertEqual(len(self.launched), 1)
        self.assertFalse((self.data / 'controller.stop').exists(), 'a stale operator stop must not block autopilot start')
        sup.tick(self.heartbeat(self.launched[0], now), now + 1)
        self.assertEqual(sup.state, 'running')

    def test_crash_restarts_with_backoff_then_pauses_on_crash_loop(self):
        sup = self.make()
        now = time.time()
        sup.tick(None, now)
        for n in range(1, cc.CRASH_LOOP_LIMIT + 1):
            self.launched[-1].code = 1
            sup.tick(None, now)
            if n < cc.CRASH_LOOP_LIMIT:
                self.assertEqual(sup.state, 'restarting')
                self.assertEqual(round(sup.next_restart - now), cc.restart_delay(n))
                sup.tick(None, now + 1)
                self.assertEqual(len(self.launched), n, 'no restart before the backoff expires')
                now = sup.next_restart
                sup.tick(None, now)
                self.assertEqual(len(self.launched), n + 1)
        self.assertEqual(sup.state, 'crashed')
        self.assertTrue(sup.crash_loop)
        sup.tick(None, now + cc.CRASH_LOOP_RETRY_SEC - 5)
        self.assertEqual(len(self.launched), cc.CRASH_LOOP_LIMIT, 'a crash loop backs off to slow retries')
        self.assertIsNotNone(sup.snapshot(now)['restartInSec'], 'the slow retry is visible')
        sup.tick(None, now + cc.CRASH_LOOP_RETRY_SEC + 1)
        self.assertEqual(len(self.launched), cc.CRASH_LOOP_LIMIT + 1, 'autopilot never gives up on the farm for good')

    def test_operator_stop_is_respected(self):
        sup = self.make()
        sup.tick(None, time.time())
        proc = self.launched[0]
        proc.code = 0  # Saver honours controller.stop and exits.
        self.assertEqual(sup.stop(wait_sec=0.1), 'stopped')
        self.assertTrue((self.data / 'controller.stop').exists())
        sup.tick(None, time.time() + 600)
        self.assertEqual(len(self.launched), 1)
        self.assertEqual(sup.state, 'stopped')

    def test_hung_saver_is_terminated_and_restarted(self):
        sup = self.make()
        start = time.time()
        sup.tick(None, start)
        proc = self.launched[0]
        sup.tick(self.heartbeat(proc, start + 5), start + 6)
        self.assertEqual(sup.state, 'running')
        late = start + cc.START_GRACE_SEC + cc.HANG_SEC + 10
        sup.tick(self.heartbeat(proc, start + 5), late)
        self.assertTrue(proc.killed)
        self.assertEqual(sup.state, 'restarting')

    def test_hang_kill_names_the_stalled_phase(self):
        sup = self.make()
        start = time.time()
        sup.tick(None, start)
        proc = self.launched[0]
        (self.data / 'saver-stall.json').write_text(json.dumps({'pid': proc.pid, 'phase': 'client 6372: first contact', 'stalledSec': 200}))
        sup.tick(self.heartbeat(proc, start + 5), start + cc.START_GRACE_SEC + cc.HANG_SEC + 10)
        self.assertTrue(proc.killed)
        self.assertIn("client 6372: first contact", sup.message)

    def test_autopilot_off_does_not_restart(self):
        sup = self.make(autopilot=False)
        now = time.time()
        sup.tick(None, now)
        self.assertEqual(len(self.launched), 1, 'start-on-launch is independent of autopilot')
        self.launched[0].code = 1
        sup.tick(None, now + 1)
        sup.tick(None, now + 600)
        self.assertEqual(len(self.launched), 1)
        self.assertEqual(sup.state, 'crashed')

    def test_backoff_caps(self):
        self.assertEqual([cc.restart_delay(n) for n in range(1, 8)], [5, 10, 20, 40, 80, 120, 120])


class IssueTests(unittest.TestCase):
    def test_derived_issues(self):
        hb = {'recoveryJournalHealthy': True, 'recovery': {'enabled': True}, 'voltControlAvailable': False,
              'systemMemory': {'commitPercent': 91}, 'quarantined': [{'username': 'Farmer01', 'retryCount': 9}]}
        titles = [i['title'] for i in cc.derive_issues(hb, 3, {'state': 'running'})]
        self.assertTrue(any('Volt' in t for t in titles))
        self.assertTrue(any('91%' in t for t in titles))
        self.assertTrue(any('Farmer01' in t for t in titles))
        self.assertEqual(cc.derive_issues(None, None, {'state': 'stopped'}), [])


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = Path(tempfile.mkdtemp())
        (cls.data / 'config.json').write_text(json.dumps({'selected_preset': 'normal', 'settings': {}, 'health': {}, 'recovery': {}}), encoding='utf-8')
        cls.app = cc.App(cls.data, 48699)
        cls.app.prefs['startSaverOnLaunch'] = False
        cls.app.supervisor.initial_start = False
        cls.app.prefs['autopilot'] = False
        cc.Handler.app = cls.app
        cls.server = cc.ThreadingHTTPServer(('127.0.0.1', 48699), cc.Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        shutil.rmtree(cls.data)

    def request(self, path, body=None, token=None, host=None):
        req = urllib.request.Request('http://127.0.0.1:48699' + path, data=None if body is None else json.dumps(body).encode(), method='GET' if body is None else 'POST')
        if token:
            req.add_header('X-Arkuzo-Token', token)
        if host:
            req.add_header('Host', host)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_state_and_page(self):
        status, state = self.request('/api/state')
        self.assertEqual(status, 200)
        self.assertEqual(state['app'], cc.APP_ID)
        with urllib.request.urlopen('http://127.0.0.1:48699/', timeout=5) as r:
            page = r.read().decode()
        self.assertIn(self.app.token, page)
        self.assertNotIn('__ARKUZO_TOKEN__', page)

    def test_posts_require_token_and_loopback_host(self):
        self.assertEqual(self.request('/api/trim-now', {})[0], 403)
        self.assertEqual(self.request('/api/trim-now', {}, token='wrong')[0], 403)
        self.assertEqual(self.request('/api/state', host='evil.example:48699')[0], 403)
        self.assertEqual(self.request('/api/trim-now', {}, token=self.app.token)[0], 200)
        self.assertTrue((self.data / 'trim-now.signal').exists())

    def test_config_round_trip_with_backup(self):
        status, body = self.request('/api/config', {'changes': {'settings': {'target_ram_mb': 500}}}, token=self.app.token)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads((self.data / 'config.json').read_text(encoding='utf-8'))['settings']['target_ram_mb'], 500)
        self.assertTrue(list((self.data / 'config-backups').glob('config-*.json')))
        status, body = self.request('/api/config', {'changes': {'settings': {'target_ram_mb': 5}}}, token=self.app.token)
        self.assertEqual(status, 400)
        self.assertIn('between', body['error'])


if __name__ == '__main__':
    unittest.main()
