import importlib.util
import json
import re
import shutil
import subprocess
import sys
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
        queued = cc.summarize_event({'time': '2026-10-26T13:44:14Z', 'event': 'EXITED_CLIENT_RECOVERY_QUEUED', 'data': {'accountId': 'a', 'pid': 4856}}, names)
        self.assertEqual((queued['level'], queued['category']), ('warning', 'recovery'))
        self.assertIn('Farmer01 closed after a disconnect', queued['text'])

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

    def test_ping_and_state_report_version_and_instance(self):
        status, ping = self.request('/api/ping')
        self.assertEqual(status, 200)
        self.assertEqual(ping['version'], cc.RUNTIME_VERSION)
        self.assertEqual(ping['instance'], self.app.instance)
        _, state = self.request('/api/state')
        self.assertEqual((state['version'], state['instance']), (cc.RUNTIME_VERSION, self.app.instance))

    def test_window_close_beacon_carries_its_token_in_the_body(self):
        self.request('/api/state?page=win1')
        self.assertIn('win1', self.app.pages)
        self.assertEqual(self.request('/api/window-closed', {'page': 'win1', 'token': 'wrong'})[0], 403)
        self.assertEqual(self.request('/api/trim-now', {'token': self.app.token})[0], 403, 'only the beacon may put its token in the body')
        self.app.pages.clear()
        self.request('/api/state?page=win1')
        status, _ = self.request('/api/window-closed', {'page': 'win1', 'token': self.app.token})
        self.assertEqual(status, 200)
        self.assertIsNotNone(self.app.close_at, 'closing the last window schedules the quit')
        self.request('/api/state?page=win2')
        self.assertIsNone(self.app.close_at, 'a reloaded page cancels it')
        self.app.pages.clear()

    def test_config_round_trip_with_backup(self):
        status, body = self.request('/api/config', {'changes': {'settings': {'target_ram_mb': 500}}}, token=self.app.token)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads((self.data / 'config.json').read_text(encoding='utf-8'))['settings']['target_ram_mb'], 500)
        self.assertTrue(list((self.data / 'config-backups').glob('config-*.json')))
        status, body = self.request('/api/config', {'changes': {'settings': {'target_ram_mb': 5}}}, token=self.app.token)
        self.assertEqual(status, 400)
        self.assertIn('between', body['error'])


class VersionTests(unittest.TestCase):
    def test_engine_version_is_read_from_the_engine(self):
        stamped = re.search(r"^\$ArkuzoRuntimeVersion = '([\d.]+)'", ENGINE.read_text(encoding='utf-8-sig'), re.M).group(1)
        self.assertEqual(cc.RUNTIME_VERSION, stamped)
        self.assertIsNone(cc.engine_version(ROOT / 'missing.ps1'))

    def test_only_a_newer_version_takes_over(self):
        self.assertTrue(cc.should_take_over('2.1.2', '2.1.1'))
        self.assertTrue(cc.should_take_over('v2.10.0', '2.9.9'))
        self.assertTrue(cc.should_take_over('2.1.2', None), 'Control Centers from before the handover report no version')
        self.assertFalse(cc.should_take_over('2.1.2', '2.1.2'))
        self.assertFalse(cc.should_take_over('2.1', '2.1.0'))
        self.assertFalse(cc.should_take_over('2.1.2', '3.0.0'))
        self.assertFalse(cc.should_take_over(None, '1.0.0'), 'an unknown own version never takes over')


class WindowCloseTests(unittest.TestCase):
    def setUp(self):
        self.data = Path(tempfile.mkdtemp())
        self.app = cc.App(self.data, 48698)
        self.stops = []
        self.app.supervisor.stop = lambda wait_sec=25.0: self.stops.append(wait_sec)

    def tearDown(self):
        shutil.rmtree(self.data)

    def test_quits_only_after_the_last_window_closes_and_stays_closed(self):
        now = time.time()
        self.assertFalse(self.app.window_close_due(now + 3600), 'no window yet (started with Windows): keep running')
        self.app.page_seen('a')
        self.app.page_seen('b')
        self.app.page_closed('a', now)
        self.assertFalse(self.app.window_close_due(now + 3600), 'another window is still open')
        self.app.page_closed('b', now)
        self.assertFalse(self.app.window_close_due(now + cc.WINDOW_CLOSE_GRACE_SEC - 1), 'a reload gets a grace period')
        self.assertTrue(self.app.window_close_due(now + cc.WINDOW_CLOSE_GRACE_SEC))
        self.app.page_seen('c')
        self.assertFalse(self.app.window_close_due(now + 3600), 'the reloaded page cancels the quit')
        self.app.page_closed('never-seen', now)
        self.assertFalse(self.app.window_close_due(now + 3600), 'a page this instance never served cannot close it')

    def test_loop_stops_the_saver_and_exits_when_due(self):
        self.app.page_seen('a')
        self.app.page_closed('a', time.time() - cc.WINDOW_CLOSE_GRACE_SEC - 1)
        worker = threading.Thread(target=self.app.loop, daemon=True)
        worker.start()
        worker.join(5)
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(self.stops), 1, 'the saver is stopped cleanly, like Stop farm & quit')
        self.assertTrue(self.app.stop_event.is_set())

    def test_a_window_reopened_while_the_saver_stops_keeps_it_running(self):
        starts = []
        self.app.supervisor.initial_start = False
        self.app.supervisor.start = lambda reason='operator': starts.append(reason)
        def stop(wait_sec=25.0):
            self.stops.append(wait_sec)
            self.app.supervisor.operator_stopped = True  # As the real stop does.
            self.app.page_seen('reopened')  # The user opened the window again during the stop.
            self.app.stop_event.set()  # End the loop after this pass.
        self.app.supervisor.stop = stop
        self.app.page_seen('a')
        self.app.page_closed('a', time.time() - cc.WINDOW_CLOSE_GRACE_SEC - 1)
        self.app.loop()
        self.assertEqual((len(self.stops), len(starts)), (1, 1), 'the saver comes back')
        self.assertIsNone(self.app.server, 'and the Control Center never shut down')


class TakeoverTests(unittest.TestCase):
    port = 48690

    def setUp(self):
        TakeoverTests.port += 1
        self.data = Path(tempfile.mkdtemp()).resolve()
        (self.data / 'config.json').write_text('{}', encoding='utf-8')
        self.old = cc.App(self.data, self.port)
        self.old.version = '1.0.0'
        self.old.supervisor.initial_start = False
        self.old.server = cc.make_server(self.old)
        threading.Thread(target=self.old.server.serve_forever, kwargs={'poll_interval': 0.1}, daemon=True).start()

    def tearDown(self):
        self.old.server.shutdown()
        self.old.server.server_close()
        shutil.rmtree(self.data)

    def test_an_older_control_center_on_the_same_data_is_replaced(self):
        self.old.page_seen('open-window')
        self.old.supervisor.state = 'running'
        result = cc.take_over(self.port, self.data, wait_sec=10)
        self.assertEqual(result, {'from': '1.0.0', 'saverWasRunning': True, 'windowsOpen': 1})
        self.assertTrue(self.old.stop_event.is_set(), 'the old Control Center quit')
        self.assertTrue((self.data / 'controller.stop').exists(), 'and stopped its saver the clean way')

    def test_a_control_center_without_a_version_is_replaced(self):
        self.old.version = None
        result = cc.take_over(self.port, self.data, wait_sec=10)
        self.assertIsNotNone(result)
        self.assertEqual((result['from'], result['saverWasRunning']), (None, False))

    def test_same_or_newer_version_is_left_running(self):
        for version in (cc.RUNTIME_VERSION, '99.0.0'):
            self.old.version = version
            self.assertIsNone(cc.take_over(self.port, self.data, wait_sec=2))
            self.assertTrue(cc.already_running(self.port))
            self.assertFalse(self.old.stop_event.is_set())

    def test_another_data_folder_is_left_running(self):
        self.assertIsNone(cc.take_over(self.port, self.data / 'elsewhere', wait_sec=2))
        self.assertTrue(cc.already_running(self.port))


class ProcessHandoverTests(unittest.TestCase):
    """Real processes: an old Control Center keeps the port until a newer one starts."""

    def setUp(self):
        self.work = Path(tempfile.mkdtemp()).resolve()
        self.data = self.work / 'data'
        self.data.mkdir()
        (self.data / 'config.json').write_text('{}', encoding='utf-8')
        # No saver processes in this test: the old one never starts one.
        (self.data / 'control-center.json').write_text(json.dumps({'autopilot': False, 'startSaverOnLaunch': False}), encoding='utf-8')
        self.old_dir = self.work / 'old'
        self.old_dir.mkdir()
        for name in ('Arkuzo-Control-Center.py', 'Arkuzo-Control-Center.html'):
            shutil.copyfile(SOURCE.parent / name, self.old_dir / name)
        (self.old_dir / 'Arkuzo-Memory-Saver.ps1').write_text("$ArkuzoRuntimeVersion = '1.0.0'\n", encoding='utf-8')
        self.procs = []

    def tearDown(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.kill()
                proc.wait(10)
        shutil.rmtree(self.work, ignore_errors=True)

    def start(self, script, port):
        proc = subprocess.Popen([sys.executable, '-I', str(script), '--data', str(self.data), '--port', str(port), '--background'],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(proc)
        return proc

    def wait_for(self, port, version, seconds=20):
        deadline = time.time() + seconds
        while time.time() < deadline:
            info = cc.running_control_center(port)
            if info and info.get('version') == version:
                return info
            time.sleep(0.2)
        self.fail(f'no Control Center {version} on port {port}')

    def test_newer_process_takes_over_the_port(self):
        port = 48689
        old = self.start(self.old_dir / 'Arkuzo-Control-Center.py', port)
        self.wait_for(port, '1.0.0')
        new = self.start(SOURCE, port)
        self.wait_for(port, cc.RUNTIME_VERSION, seconds=60)
        self.assertEqual(old.wait(30), 0, 'the old Control Center exited cleanly')
        self.assertIsNone(new.poll(), 'the new one keeps serving')
        replay = self.start(self.old_dir / 'Arkuzo-Control-Center.py', port)
        self.assertEqual(replay.wait(30), 0, 'an older one started later just opens the newer one')
        self.assertEqual(cc.running_control_center(port)['version'], cc.RUNTIME_VERSION)


if __name__ == '__main__':
    unittest.main()
