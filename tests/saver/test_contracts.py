"""Reader side of contracts/runtime-status.json: the Control Center, its page and
the launcher only rely on keys the engine is checked to write
(tests/saver/RuntimeStatusContract.Tests.ps1), and an older or newer heartbeat
never breaks them."""
import importlib.util
import json
import re
import shutil
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.py'
spec = importlib.util.spec_from_file_location('control_center_contracts', SOURCE)
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)

CONTRACT = json.loads((ROOT / 'contracts' / 'runtime-status.json').read_text(encoding='utf-8'))
PAGE = (ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.html').read_text(encoding='utf-8')
SCRIPT = PAGE[PAGE.index('<script>'):PAGE.rindex('</script>')]


def heartbeat(**changes) -> dict:
    """A heartbeat with every contract key, as the engine writes it."""
    client = dict.fromkeys(CONTRACT['client'])
    client.update(pid=4242, startTicks=638000000000000000, cpuPercent=1.5, residentMB=600.0, privateMB=2000.0, state='WINDOW OPEN',
                  responding=True, windowPresent=True, launchError=False, isDisconnected=False, gameReady=True, slot=0, ageSec=300,
                  account='alpha', sampleTime='2026-11-01T10:00:00.0000000Z')
    account = dict.fromkeys(CONTRACT['account'])
    account.update(accountId='11111111-1111-1111-1111-111111111111', username='alpha', processId=4242, uiStatus='Connected',
                   controlReady=True, cookieStatus='alive', suspensionSafe=False, autoRelaunch=True)
    hb = dict.fromkeys(CONTRACT['topLevel'])
    hb.update(schemaVersion=CONTRACT['schemaVersion'], version='9.9.9', pid=1, startTicks=1, controller=True, monitorOnly=False,
              updatedUtc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), clients=[client], accounts=[account],
              pending=[], quarantined=[], suspendedAccounts=[], alerts=[], accountProvider='arkuzo', recoveryJournalHealthy=True,
              recovery={'enabled': True}, health={}, settings=dict.fromkeys(CONTRACT['settings']),
              systemMemory={'commitPercent': 40.0, 'availablePhysicalMB': 8000.0}, totalPhysicalMB=32000.0,
              totals={'residentMB': 600.0, 'privateMB': 2000.0})
    hb.update(changes)
    return hb


class ContractFileTests(unittest.TestCase):
    def test_the_contract_is_consistent(self):
        self.assertIsInstance(CONTRACT['schemaVersion'], int)
        for name in ('topLevel', 'client', 'account', 'settings'):
            self.assertEqual(len(CONTRACT[name]), len(set(CONTRACT[name])), f'{name} lists each key once')
        self.assertIn('schemaVersion', CONTRACT['topLevel'])
        readers = CONTRACT['readers']
        for key in readers['supervisor'] + readers['launcherTakeover'] + readers['controlCenterState'] + readers['instantClose']['topLevel']:
            self.assertIn(key, CONTRACT['topLevel'])
        self.assertLessEqual(set(readers['instantClose']['client']), set(CONTRACT['client']))
        self.assertLessEqual(set(readers['instantClose']['account']), set(CONTRACT['account']))


class ControlCenterReaderTests(unittest.TestCase):
    def setUp(self):
        self.data = Path(tempfile.mkdtemp())
        self.app = cc.App(self.data, 0)
        self.app.supervisor.initial_start = False

    def tearDown(self):
        shutil.rmtree(self.data, ignore_errors=True)

    def test_it_knows_the_schema_version_it_was_written_for(self):
        self.assertEqual(cc.HEARTBEAT_SCHEMA_VERSION, CONTRACT['schemaVersion'])

    def test_state_forwards_exactly_the_documented_keys(self):
        self.assertEqual(sorted(cc.HEARTBEAT_VIEW_KEYS), sorted(CONTRACT['readers']['controlCenterState']))
        self.app.heartbeat = heartbeat()
        view = self.app.state(0, 0)['heartbeat']
        self.assertEqual(sorted(view), sorted(set(cc.HEARTBEAT_VIEW_KEYS) | {'pagefile'}))
        self.assertEqual(view['schemaVersion'], CONTRACT['schemaVersion'])
        self.assertEqual(sorted(view['clients'][0]), sorted(CONTRACT['client']))

    def test_a_heartbeat_from_an_engine_without_a_schema_version_still_works(self):
        old = heartbeat()
        del old['schemaVersion']
        old['clients'][0].pop('sampleTime')
        old['clients'].append({'pid': 7, 'privateMB': 1234.56789, 'systemCommitPercent': 40.0})  # The old, partial row.
        self.app.heartbeat = old
        state = self.app.state(0, 0)
        self.assertIsNone(state['heartbeat']['schemaVersion'])
        self.assertFalse([i for i in state['issues'] if 'newer' in i['title'].lower()])
        self.app._sample(time.time())
        self.assertEqual(len(self.app.history), 1)

    def test_a_newer_schema_is_reported_and_still_read(self):
        self.app.heartbeat = heartbeat(schemaVersion=CONTRACT['schemaVersion'] + 1, somethingNew={'a': 1})
        state = self.app.state(0, 0)
        self.assertEqual(len([i for i in state['issues'] if 'newer' in i['title'].lower()]), 1)
        self.assertEqual(state['heartbeat']['clients'][0]['pid'], 4242)
        self.assertNotIn('somethingNew', state['heartbeat'])

    def test_instant_close_reads_only_contract_keys(self):
        (self.data / 'runtime-status.json').write_text(json.dumps(heartbeat()), encoding='utf-8')
        asked = []
        real = cc.WIN32.terminate
        cc.WIN32.terminate = lambda pid, ticks, images=(): asked.append((pid, ticks, images)) or True
        try:
            self.assertEqual(cc.close_live_clients(self.data), 1)
        finally:
            cc.WIN32.terminate = real
        self.assertEqual(asked, [(4242, 638000000000000000, ('robloxplayerbeta.exe',))])

    def test_instant_close_never_guesses_from_a_row_without_a_start_time(self):
        hb = heartbeat()
        hb['clients'][0]['startTicks'] = None
        (self.data / 'runtime-status.json').write_text(json.dumps(hb), encoding='utf-8')
        asked = []
        real = cc.WIN32.terminate
        cc.WIN32.terminate = lambda *a: asked.append(a) or True
        try:
            self.assertEqual(cc.close_live_clients(self.data), 0)
        finally:
            cc.WIN32.terminate = real
        self.assertEqual(asked, [])


class PageReaderTests(unittest.TestCase):
    """Static: every heartbeat and client key the page reads is one the Control Center forwards."""

    def test_heartbeat_keys_read_by_the_page_are_forwarded(self):
        used = set(re.findall(r'\bhb\.([A-Za-z_]\w*)', SCRIPT)) | set(re.findall(r'\bheartbeat\.([A-Za-z_]\w*)', SCRIPT))
        self.assertTrue(used, 'the page reads the heartbeat')
        forwarded = set(CONTRACT['readers']['controlCenterState']) | {'pagefile'}
        self.assertEqual(sorted(used - forwarded), [], 'the page reads heartbeat keys the Control Center does not forward')

    def test_client_keys_read_by_the_page_are_in_the_contract(self):
        dom = {'addEventListener', 'dataset'}  # "c" is also a DOM element in two places.
        used = set(re.findall(r'\bc\.([A-Za-z_]\w*)', SCRIPT)) - dom
        self.assertGreaterEqual(len(used), 10, 'the page reads client rows')
        self.assertEqual(sorted(used - set(CONTRACT['client'])), [], 'the page reads client keys the engine does not write')


class LauncherReaderTests(unittest.TestCase):
    def test_the_launcher_reads_only_the_documented_takeover_keys(self):
        source = (ROOT / 'src' / 'launcher' / 'Core' / 'ControllerTakeover.cs').read_text(encoding='utf-8')
        heartbeat_part = source[:source.index('internal static bool Matches')]
        used = set(re.findall(r'row\.GetProperty\("(\w+)"\)', heartbeat_part))
        self.assertEqual(sorted(used), sorted(CONTRACT['readers']['launcherTakeover']))
        # The kill fallback (LauncherEntry, InstallProcesses) reads no heartbeat key: it matches
        # processes of this install by their command line, not by the heartbeat's pid.
        for name in ('LauncherEntry.cs', 'InstallProcesses.cs'):
            code = (ROOT / 'src' / 'launcher' / 'Core' / name).read_text(encoding='utf-8')
            self.assertEqual(set(re.findall(r'RootElement\.TryGetProperty\("(\w+)"', code)), set(), name)
            self.assertNotIn('runtime-status.json', code, name)


if __name__ == '__main__':
    unittest.main()
