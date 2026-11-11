import importlib.util
import json
import re
import shutil
import socket
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


def free_port() -> int:
    """A port Windows hands out right now: fixed ports fail (WinError 10013) when it has reserved their range."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


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

    # Presets and ranges are checked against contracts/config-schema.json in test_config_schema.py.


class PageScriptTests(unittest.TestCase):
    def test_page_script_parses(self):
        """One stray quote in the page script blanks the whole Control Center."""
        node = shutil.which('node')
        if not node:
            self.skipTest('Node.js not installed')
        html = (ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.html').read_text(encoding='utf-8')
        script = html[html.rindex('<script>') + 8:html.rindex('</script>')]
        folder = Path(tempfile.mkdtemp())
        try:
            (folder / 'page.js').write_text(script, encoding='utf-8')
            result = subprocess.run([node, '--check', str(folder / 'page.js')], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr[:500])
        finally:
            shutil.rmtree(folder)


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
        self.assertIn('Farmer01 closed while waiting for recovery', queued['text'])
        frozen = cc.summarize_event({'time': '2026-10-26T18:13:24Z', 'event': 'EXITED_CLIENT_RECOVERY_QUEUED', 'data': {'accountId': 'a', 'reason': 'UNRESPONSIVE_EXIT'}}, names)
        self.assertIn('Farmer01 closed while frozen', frozen['text'])
        kicked = cc.summarize_event({'time': '2026-10-26T13:44:14Z', 'event': 'EXITED_CLIENT_RECOVERY_QUEUED', 'data': {'accountId': 'a', 'reason': 'IN_GAME_DISCONNECT'}}, names)
        self.assertIn('Farmer01 closed while disconnected', kicked['text'])

    def test_farm_freeze_is_explained_in_the_feed(self):
        detected = cc.summarize_event({'time': '2026-11-08T10:00:00Z', 'event': 'FARM_FREEZE_DETECTED',
                                       'data': {'population': 8, 'frozen': 8, 'planned': [{'pid': 1}] * 7, 'spacingSec': 20}}, {})
        self.assertEqual((detected['level'], detected['category']), ('warning', 'recovery'))
        self.assertIn('8 of 8 clients', detected['text'])
        self.assertIn('recycling 7, 20 s apart', detected['text'])
        ended = cc.summarize_event({'time': '2026-11-08T10:03:00Z', 'event': 'FARM_FREEZE_EPISODE_END',
                                    'data': {'outcome': 'Completed', 'members': {'Closed': 7, 'Exited': 1}}}, {})
        self.assertIn('completed: 7 closed', ended['text'])
        state = cc.summarize_event({'event': 'CLIENT_STATE_CHANGED', 'data': {'sample': {'state': 'FARM FREEZE', 'pid': 4}}}, {})
        self.assertIsNotNone(state)

    def test_farm_freeze_settings_validate(self):
        merged, _ = cc.apply_config_changes(ConfigTests.base, {'health': {'farm_freeze_enabled': False, 'farm_freeze_spacing_sec': 25}})
        self.assertEqual((merged['health']['farm_freeze_enabled'], merged['health']['farm_freeze_spacing_sec']), (False, 25))
        for bad in ({'farm_freeze_spacing_sec': 5}, {'farm_freeze_confirm_sec': 10}, {'farm_freeze_enabled': 1}, {'farm_freeze_min_clients': 2}):
            with self.assertRaises(cc.ConfigError, msg=str(bad)):
                cc.apply_config_changes(ConfigTests.base, {'health': bad})

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

    @staticmethod
    def run_until(sup, beat, start, end, step=2.0):
        """Ticks every 2 s like App.loop until the first kill; beat(t) is the heartbeat written by then."""
        proc, t = sup.proc, start
        while t <= end and not proc.killed:
            sup.tick(beat(t), t)
            t += step

    def test_hung_saver_is_terminated_and_restarted(self):
        sup = self.make()
        start = time.time()
        sup.tick(None, start)
        proc = self.launched[0]
        sup.tick(self.heartbeat(proc, start + 5), start + 6)
        self.assertEqual(sup.state, 'running')
        late = start + cc.START_GRACE_SEC + cc.HANG_SEC + 10
        self.run_until(sup, lambda t: self.heartbeat(proc, start + 5), start + 8, late)
        self.assertTrue(proc.killed)
        self.assertEqual(sup.state, 'restarting')
        silent = int(re.search(r'stopped responding for (\d+)s', sup.message).group(1))
        self.assertLessEqual(silent, cc.START_GRACE_SEC + 5, 'silence is measured from the last heartbeat, not reported as the session age')

    def test_hang_kill_names_the_stalled_phase(self):
        sup = self.make()
        start = time.time()
        sup.tick(None, start)
        proc = self.launched[0]
        (self.data / 'saver-stall.json').write_text(json.dumps({'pid': proc.pid, 'phase': 'client 6372: first contact', 'stalledSec': 200}))
        self.run_until(sup, lambda t: self.heartbeat(proc, start + 5), start + 2, start + cc.START_GRACE_SEC + cc.HANG_SEC + 10)
        self.assertTrue(proc.killed)
        self.assertIn("client 6372: first contact", sup.message)

    def test_one_unreadable_heartbeat_never_kills_a_healthy_saver(self):
        # 24-27 Oct: healthy savers were killed as "stopped responding for <session age>".
        sup = self.make()
        start = time.time()
        sup.tick(None, start)
        proc = self.launched[0]
        self.run_until(sup, lambda t: self.heartbeat(proc, t - 1), start + 2, start + 600)
        self.assertEqual(sup.state, 'running')
        for bad in (None, {'pid': 1, 'updatedUtc': 'garbage'}, {}):
            sup.tick(bad, start + 602)
            self.assertFalse(proc.killed, f'one unreadable heartbeat ({bad!r}) is not silence since start')
        sup.tick(self.heartbeat(proc, start + 603), start + 604)
        self.assertEqual(sup.state, 'running')

    def test_sleep_gap_is_not_saver_silence(self):
        sup = self.make()
        start = time.time()
        sup.tick(None, start)
        proc = self.launched[0]
        self.run_until(sup, lambda t: self.heartbeat(proc, t - 1), start + 2, start + 400)
        wake = start + 400 + 3600  # The PC slept for an hour; the saver has not written since.
        sup.tick(self.heartbeat(proc, start + 399), wake)
        self.assertFalse(proc.killed, 'waking from sleep gives the saver time for a new heartbeat')
        self.run_until(sup, lambda t: self.heartbeat(proc, t - 1), wake + 2, wake + 30)
        self.assertEqual(sup.state, 'running')
        # A saver that really stays silent after waking is still caught once the grace ends.
        self.run_until(sup, lambda t: self.heartbeat(proc, wake + 29), wake + 32, wake + 32 + 2 * cc.HANG_SEC)
        self.assertTrue(proc.killed)

    def test_unreadable_heartbeat_of_an_external_saver_is_no_verdict(self):
        sup = self.make()
        sup.initial_start = False
        sup.state = 'external'
        now = time.time()
        sup.tick(None, now)
        self.assertEqual((sup.state, sup.failures, len(self.launched)), ('external', 0, 0))
        # A heartbeat that stays unreadable (a saver that died mid-write) must not leave the farm
        # unmanaged forever: after HANG_SEC the normal verdict applies and autopilot restarts it.
        t = now
        while t <= now + cc.HANG_SEC + 4 and not self.launched:
            t += 2
            sup.tick(None, t)
        self.assertEqual(sup.failures, 1, 'the vanished external saver is recorded')
        t += cc.restart_delay(1) + 2
        sup.tick(None, t)
        self.assertEqual(len(self.launched), 1, 'and autopilot starts a new one')

    def test_supervisor_actions_are_written_to_a_log(self):
        sup = self.make()
        sup.tick(None, time.time())
        lines = (self.data / 'control-center.log').read_text(encoding='utf-8').splitlines()
        self.assertTrue(any('Saver started with the Control Center' in json.loads(line)['text'] for line in lines))
        self.assertFalse(list(self.data.glob('Arkuzo-*.log')), 'never mistaken for a saver session log')

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
        # A short fixed wait: a 5 s floor (never a busy loop), then 10 s, never growing.
        self.assertEqual([cc.restart_delay(n) for n in range(1, 8)], [5, 10, 10, 10, 10, 10, 10])
        self.assertLessEqual(cc.CRASH_LOOP_RETRY_SEC, 15)
        self.assertGreaterEqual(min(cc.restart_delay(1), cc.CRASH_LOOP_RETRY_SEC), 5)

    def test_crash_loop_keeps_retrying_quickly_and_logs_every_crash(self):
        sup = self.make()
        now = time.time()
        sup.tick(None, now)
        for n in range(1, cc.CRASH_LOOP_LIMIT + 4):
            self.launched[-1].code = 1
            sup.tick(None, now)
            self.assertEqual(sup.crash_loop, n >= cc.CRASH_LOOP_LIMIT)
            if sup.crash_loop:
                self.assertIn(f'every {cc.CRASH_LOOP_RETRY_SEC} s', sup.message)
            self.assertLessEqual(sup.next_restart - now, cc.CRASH_LOOP_RETRY_SEC, 'never a long wait')
            now = sup.next_restart
            sup.tick(None, now)
        self.assertEqual(len(self.launched), cc.CRASH_LOOP_LIMIT + 4, 'every crash is followed by a restart')
        crashes = [e for e in sup.feed.since(0) if e.get('level') == 'critical']
        self.assertEqual(len(crashes), cc.CRASH_LOOP_LIMIT + 3, 'each crash is logged')


class IssueTests(unittest.TestCase):
    def test_derived_issues(self):
        hb = {'recoveryJournalHealthy': True, 'recovery': {'enabled': True}, 'voltControlAvailable': False,
              'systemMemory': {'commitPercent': 91}, 'quarantined': [{'username': 'Farmer01', 'retryCount': 9}]}
        titles = [i['title'] for i in cc.derive_issues(hb, 3, {'state': 'running'})]
        self.assertTrue(any('Volt' in t for t in titles))
        self.assertTrue(any('91%' in t for t in titles))
        self.assertTrue(any('Farmer01' in t for t in titles))
        self.assertEqual(cc.derive_issues(None, None, {'state': 'stopped'}), [])
        # Arkuzo launches the clients: Volt's Account Manager is not needed.
        titles = [i['title'] for i in cc.derive_issues(dict(hb, accountProvider='arkuzo'), 3, {'state': 'running'})]
        self.assertFalse(any('Volt' in t for t in titles))


class RemoteSessionTests(unittest.TestCase):
    BASE = {'recoveryJournalHealthy': True, 'recovery': {'enabled': True}, 'accountProvider': 'arkuzo', 'clients': [{}, {}, {}]}

    def titles(self, remote, **extra):
        return [i['title'] for i in cc.derive_issues(dict(self.BASE, remoteSession=remote, **extra), 3, {'state': 'running'})]

    def test_chrome_remote_desktop_connected_warns_not_to_disconnect(self):
        crd = {'protocol': 'console', 'sessionState': 'active', 'chromeRemoteDesktop': {'connected': True}}
        self.assertTrue(any('do not disconnect' in t for t in self.titles(crd)))
        # No clients, nothing to lose; not connected, nothing to say.
        self.assertFalse(any('Chrome Remote Desktop' in t for t in self.titles(crd, clients=[])))
        self.assertFalse(any('Chrome Remote Desktop' in t for t in self.titles(dict(crd, chromeRemoteDesktop={'connected': False}))))
        self.assertFalse(any('Remote' in t for t in self.titles(None)))

    def test_rdp_notices(self):
        active = {'protocol': 'rdp', 'sessionState': 'active'}
        self.assertTrue(any('Leave Remote Desktop safely' in t for t in self.titles(active)))
        held = self.titles({'protocol': 'rdp', 'sessionState': 'disconnected', 'hold': True, 'holdLeftSec': 300})
        self.assertTrue(any('recovery is paused' in t for t in held))

    def test_feed_summary(self):
        record = {'event': 'REMOTE_SESSION_CHANGED', 'time': '2026-11-08T16:19:46+01:00',
                  'data': {'changes': ['CRD_DISCONNECTED'], 'clients': 11, 'current': {'display': '1920x1080x144x32'}}}
        row = cc.summarize_event(record, {})
        self.assertEqual(row['level'], 'warning')
        self.assertIn('Chrome Remote Desktop disconnected', row['text'])
        self.assertIn('11 clients', row['text'])
        quiet = cc.summarize_event(dict(record, data={'changes': ['DISPLAY_MODE_CHANGED'], 'clients': 0, 'current': {'display': '1280x720x60x32'}}), {})
        self.assertEqual(quiet['level'], 'info')
        self.assertIn('1280x720', quiet['text'])
        self.assertIsNotNone(cc.summarize_event({'event': 'KEEP_AWAKE', 'data': {'on': True}}, {}))

    def test_leave_remote_desktop_runs_tscon_only_for_rdp(self):
        calls = []

        class Done:
            returncode, stdout, stderr = 0, '', ''

        def runner(command, **kwargs):
            calls.append(command)
            return Done()

        with self.assertRaises(cc.ConfigError):
            cc.leave_remote_desktop({'sessionId': 1, 'protocol': 0}, runner)  # Console (Chrome Remote Desktop): nothing to move.
        self.assertEqual(calls, [])
        self.assertEqual(cc.leave_remote_desktop({'sessionId': 3, 'protocol': 2}, runner), 'moved to console')
        self.assertEqual(calls[0][1:], ['3', '/dest:console'])
        self.assertTrue(calls[0][0].lower().endswith('tscon.exe'))

        class Denied:
            returncode, stdout, stderr = 1, '', 'Access is denied.'

        with self.assertRaises(cc.ConfigError) as ctx:
            cc.leave_remote_desktop({'sessionId': 3, 'protocol': 2}, lambda *a, **k: Denied())
        self.assertIn('administrator', str(ctx.exception))
        self.assertIn('tscon 3 /dest:console', str(ctx.exception))

    def test_own_session_reads_this_process(self):
        info = cc.own_session()
        self.assertIn('protocol', info)
        if sys.platform == 'win32':
            self.assertGreaterEqual(info['sessionId'], 0)

    def test_settings_page_lists_the_remote_settings(self):
        html = (ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.html').read_text(encoding='utf-8')
        for key in ('farm_freeze_remote_confirm_sec', 'keep_display_awake', 'remote_hold_max_sec'):
            self.assertIn(key, cc.SCHEMA['health'])
            self.assertIn(f"'health', '{key}'", html)
        defaults = json.loads((ROOT / 'config' / 'defaults.json').read_text(encoding='utf-8'))['health']
        self.assertEqual((defaults['farm_freeze_remote_confirm_sec'], defaults['keep_display_awake']), (20, True))


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = Path(tempfile.mkdtemp())
        (cls.data / 'config.json').write_text(json.dumps({'selected_preset': 'normal', 'settings': {}, 'health': {}, 'recovery': {}}), encoding='utf-8')
        cls.app = cc.App(cls.data, 0)
        cls.app.prefs['startSaverOnLaunch'] = False
        cls.app.supervisor.initial_start = False
        cls.app.prefs['autopilot'] = False
        cc.Handler.app = cls.app
        cls.server = cc.ThreadingHTTPServer(('127.0.0.1', 0), cc.Handler)
        cls.port = cls.app.port = cls.server.server_address[1]  # Ephemeral: the host check uses app.port.
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        shutil.rmtree(cls.data)

    def request(self, path, body=None, token=None, host=None):
        req = urllib.request.Request(f'http://127.0.0.1:{self.port}' + path, data=None if body is None else json.dumps(body).encode(), method='GET' if body is None else 'POST')
        if token:
            req.add_header('X-Arkuzo-Token', token)
        if host:
            req.add_header('Host', host)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_unexpected_handler_error_is_a_json_500_without_secrets(self):
        original = self.app.vault_view

        def broken():
            raise KeyError('secret-' + self.app.token)
        self.app.vault_view = broken
        try:
            status, body = self.request('/api/vault')
        finally:
            self.app.vault_view = original
        self.assertEqual(status, 500)
        self.assertEqual(body, {'error': 'Internal error (KeyError)'})
        self.assertNotIn(self.app.token, json.dumps(body))
        texts = ' '.join(str(e.get('text')) for e in self.app.feed.since(0))
        self.assertIn('/api/vault failed (KeyError)', texts)
        self.assertNotIn(self.app.token, texts)
        original_start = self.app.supervisor.start
        self.app.supervisor.start = lambda *a, **k: 1 / 0
        try:
            status, body = self.request('/api/saver/start', {}, token=self.app.token)
        finally:
            self.app.supervisor.start = original_start
        self.assertEqual((status, body), (500, {'error': 'Internal error (ZeroDivisionError)'}))
        status, _ = self.request('/api/state')
        self.assertEqual(status, 200, 'the server keeps answering')

    def test_state_and_page(self):
        status, state = self.request('/api/state')
        self.assertEqual(status, 200)
        self.assertEqual(state['app'], cc.APP_ID)
        with urllib.request.urlopen(f'http://127.0.0.1:{self.port}/', timeout=5) as r:
            page = r.read().decode()
        self.assertIn(self.app.token, page)
        self.assertNotIn('__ARKUZO_TOKEN__', page)

    def test_posts_require_token_and_loopback_host(self):
        self.assertEqual(self.request('/api/trim-now', {})[0], 403)
        self.assertEqual(self.request('/api/trim-now', {}, token='wrong')[0], 403)
        self.assertEqual(self.request('/api/state', host=f'evil.example:{self.port}')[0], 403)
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

    def test_a_page_of_a_replaced_control_center_is_not_a_window(self):
        self.app.pages.clear()
        self.request(f'/api/state?page=stale&inst=someoneelse')
        self.assertNotIn('stale', self.app.pages, 'an old page polling once before it reloads would block the close-to-quit')
        self.request(f'/api/state?page=fresh&inst=')
        self.request(f'/api/state?page=current&inst={self.app.instance}')
        self.assertEqual(set(self.app.pages), {'fresh', 'current'})
        self.app.pages.clear()

    def test_route_table_declares_auth_per_route(self):
        self.assertEqual({p for p, (_, auth) in cc.POST_ROUTES.items() if auth == cc.Handler.AUTH_BEACON}, {'/api/window-closed'}, 'only the close beacon may carry its token in the body')
        self.assertTrue(all(auth in (cc.Handler.AUTH_TOKEN, cc.Handler.AUTH_BEACON) for _, auth in cc.POST_ROUTES.values()), 'every POST needs the token')
        self.assertFalse(set(cc.GET_ROUTES) & {'/api/trim-now', '/api/quit', '/api/farm/start'}, 'nothing that changes state answers GET')
        html = (ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.html').read_text(encoding='utf-8')
        used = set(re.findall(r"'(/api/[a-z/-]+)'", html))
        self.assertGreaterEqual(len(used), 20)
        self.assertEqual(used - set(cc.GET_ROUTES) - set(cc.POST_ROUTES), set(), 'every path the page calls has a route')

    def test_unknown_paths(self):
        self.assertEqual(self.request('/api/nothing')[0], 404)
        self.assertEqual(self.request('/api/nothing', {})[0], 403, 'an unknown POST path reveals nothing without the token')
        self.assertEqual(self.request('/api/nothing', {}, token=self.app.token)[0], 404)
        status, body = self.request('/api/vault/nothing', {}, token=self.app.token)
        self.assertEqual((status, body), (400, {'error': 'Unknown account action'}))
        self.assertEqual(self.request('/api/trim-now')[0], 404, 'a POST route does not answer GET')

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


class LoopSurvivalTests(unittest.TestCase):
    """The supervisor loop is the only thing that restarts the saver: bad input must not end it."""

    def setUp(self):
        self.data = Path(tempfile.mkdtemp())
        self.app = cc.App(self.data, free_port())
        self.ticks = []
        self.app.supervisor.tick = lambda heartbeat, now=None: self.ticks.append(now)

    def tearDown(self):
        shutil.rmtree(self.data, ignore_errors=True)

    def test_a_malformed_heartbeat_value_does_not_end_the_loop(self):
        updated = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        (self.data / 'runtime-status.json').write_text(json.dumps({
            'pid': 1, 'updatedUtc': updated, 'totalPhysicalMB': 'lots', 'systemMemory': {'availablePhysicalMB': 'n/a'},
            'clients': [{'residentMB': 'many', 'privateMB': None}]}), encoding='utf-8')
        with self.assertRaises(ValueError):
            self.app.heartbeat = cc.read_json(self.data / 'runtime-status.json')
            self.app._sample(time.time())  # The unguarded call this fix wraps.
        self.app.step(1.0)
        self.app.step(2.0)
        self.assertEqual(self.ticks, [1.0, 2.0], 'the supervisor was still ticked on every pass')

    def test_a_failing_log_feed_or_cookie_check_does_not_end_the_loop(self):
        def boom(*_):
            raise TypeError('unexpected log record')
        self.app.feed.poll = boom
        self.app.cookies.tick = boom
        self.app.step(5.0)
        self.assertEqual(self.ticks, [5.0])

    def test_an_error_outside_step_does_not_end_the_loop(self):
        calls = []

        def broken_close_check(now):
            calls.append(now)
            raise RuntimeError('window bookkeeping failed')
        self.app.window_close_due = broken_close_check
        waits = []

        def wait(timeout):
            waits.append(timeout)
            if len(waits) >= 3:
                self.app.stop_event.set()
        self.app.stop_event.wait = wait
        self.app.loop()
        self.assertEqual(len(calls), 3, 'the loop carried on after each failure')
        self.assertEqual(waits, [2.0, 2.0, 2.0], 'and still waited between passes (no busy loop)')
        self.assertIn('RuntimeError', self.app.supervisor.message)

    def test_a_log_line_with_unexpected_types_is_survived(self):
        logs = self.data / 'Arkuzo-Logs'
        logs.mkdir()
        (logs / 'Arkuzo-20260101-000000-1-part0.log').write_text(
            json.dumps({'event': 'CLIENT_START', 'data': {'pid': 5, 'slot': 'first'}}) + '\n' +
            json.dumps({'event': 'SESSION_STOP', 'data': {'uptimeSeconds': 'long'}}) + '\n', encoding='utf-8')
        self.app.step(7.0)
        self.app.step(8.0)
        self.assertEqual(self.ticks, [7.0, 8.0])


class WindowCloseTests(unittest.TestCase):
    def setUp(self):
        self.data = Path(tempfile.mkdtemp())
        self.app = cc.App(self.data, free_port())
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
        self.assertFalse(self.app.window_close_due(now + 60), 'another window is still open')
        self.app.page_seen('b', now + 3500)  # It keeps polling...
        self.assertFalse(self.app.window_close_due(now + 3600), '...so it never quits while that window lives')
        self.app.page_closed('b', now)
        self.assertFalse(self.app.window_close_due(now + cc.WINDOW_CLOSE_GRACE_SEC - 1), 'a reload gets a grace period')
        self.assertTrue(self.app.window_close_due(now + cc.WINDOW_CLOSE_GRACE_SEC))
        self.app.page_seen('c')
        self.assertFalse(self.app.window_close_due(now + 3600), 'the reloaded page cancels the quit')
        self.app.page_closed('never-seen', now)
        self.assertFalse(self.app.window_close_due(now + 3600), 'a page this instance never served cannot close it')

    def test_a_stale_page_id_from_an_update_does_not_block_quitting(self):
        # A v2.1.3 page polls the new Control Center once before it reloads, without an instance id.
        now = time.time()
        self.app.page_seen('reloaded-old-page', now - cc.PAGE_STALE_SEC - 60)
        self.app.page_seen('real-window', now)
        self.app.page_closed('real-window', now)
        self.assertTrue(self.app.window_close_due(now + cc.WINDOW_CLOSE_GRACE_SEC), 'closing the real window still quits')
        self.app.close_at = None
        self.app.page_seen('minimized', now - 70)  # Throttled to one poll a minute: still a window.
        self.app.page_seen('other', now)
        self.app.page_closed('other', now)
        self.assertFalse(self.app.window_close_due(now + 60), 'a minimized window keeps it running')
        self.app.page_seen('minimized', now + 50)  # Its once-a-minute poll.
        self.assertFalse(self.app.window_close_due(now + 200), 'and keeps doing so while it polls')

    def test_closing_right_after_an_update_still_quits_once_the_stray_id_ages_out(self):
        now = time.time()
        self.app.page_seen('old-page-polled-once', now - 5)
        self.app.page_seen('real-window', now)
        self.app.page_closed('real-window', now)
        self.assertFalse(self.app.window_close_due(now + 60), 'the stray id is still recent')
        self.assertTrue(self.app.window_close_due(now - 5 + cc.PAGE_STALE_SEC + 1), 'it quits once the stray id is stale')
        self.app.page_seen('reopened', now + 90)
        self.assertFalse(self.app.window_close_due(now + 3600), 'a window that polls again cancels the pending quit')

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
        self.app.supervisor.state = 'running'
        self.app.page_seen('a')
        self.app.page_closed('a', time.time() - cc.WINDOW_CLOSE_GRACE_SEC - 1)
        self.app.loop()
        self.assertEqual((len(self.stops), len(starts)), (1, 1), 'the saver comes back')
        self.assertIsNone(self.app.server, 'and the Control Center never shut down')

    def test_a_held_quit_with_only_a_stray_id_left_really_quits(self):
        # Found end to end: the stray id of a reloaded old page made every due quit look like a
        # reopened window, so it stopped and restarted the saver every 7 s instead of quitting.
        starts = []
        self.app.supervisor.start = lambda reason='operator': starts.append(reason)
        self.app.supervisor.state = 'running'
        now = time.time()
        self.app.page_seen('stray', now - cc.PAGE_STALE_SEC - 30)
        self.app.page_seen('real', now - 5)
        self.app.page_closed('real', now - 5)
        worker = threading.Thread(target=self.app.loop, daemon=True)
        worker.start()
        worker.join(5)
        self.assertFalse(worker.is_alive(), 'the Control Center quits')
        self.assertEqual((len(self.stops), starts), (1, []), 'the saver is stopped once and not restarted')

    def test_a_reopened_window_never_starts_a_saver_that_was_not_running(self):
        starts = []
        self.app.supervisor.initial_start = False
        self.app.supervisor.start = lambda reason='operator': starts.append(reason)
        def stop(wait_sec=25.0):
            self.stops.append(wait_sec)
            self.app.supervisor.operator_stopped = True
            self.app.page_seen('reopened')
            self.app.stop_event.set()
        self.app.supervisor.stop = stop
        self.app.supervisor.state = 'stopped'
        self.app.page_seen('a')
        self.app.page_closed('a', time.time() - cc.WINDOW_CLOSE_GRACE_SEC - 1)
        self.app.loop()
        self.assertEqual(starts, [], 'a farm the operator had stopped stays stopped')


class TakeoverTests(unittest.TestCase):
    def setUp(self):
        self.port = free_port()
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
        port = free_port()
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
