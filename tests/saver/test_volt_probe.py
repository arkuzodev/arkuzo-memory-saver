import importlib.util
import inspect
import os
import subprocess
import sys
import json
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('probe', Path(__file__).resolve().parents[2] / 'src' / 'saver' / 'Arkuzo-Volt-Probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.path = Path(self.temp.name) / 'state.db'
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute('create table state_documents (name text primary key, value blob not null)')
        self.doc = {'settings': {'autoRelaunchEnabled': True, 'relaunchDelayMs': 10000},
                    'accounts': [{'autoRelaunch': True, 'cookieStatus': 'alive', 'encryptedCookie': 'TEST-SECRET'}]}
    def tearDown(self):
        self.temp.cleanup()
    def save(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute('insert or replace into state_documents values (?,?)', ('accounts', json.dumps(self.doc)))
    def test_ready_read_only_without_secrets(self):
        self.save(); before = self.path.read_bytes()
        value = probe.read_recovery_status(self.path)
        self.assertTrue(value['safeToRecycle'])
        self.assertNotIn('SECRET', json.dumps(value))
        self.assertEqual(before, self.path.read_bytes())
    def test_global_relaunch_disabled(self):
        self.doc['settings']['autoRelaunchEnabled'] = False; self.save()
        self.assertFalse(probe.read_recovery_status(self.path)['safeToRecycle'])
    def test_account_relaunch_disabled(self):
        self.doc['accounts'][0]['autoRelaunch'] = False; self.save()
        self.assertFalse(probe.read_recovery_status(self.path)['safeToRecycle'])
    def test_dead_session(self):
        self.doc['accounts'][0]['cookieStatus'] = 'dead'; self.save()
        self.assertFalse(probe.read_recovery_status(self.path)['safeToRecycle'])
    def test_no_accounts(self):
        self.doc['accounts'] = []; self.save()
        self.assertFalse(probe.read_recovery_status(self.path)['safeToRecycle'])
    def test_unavailable(self):
        self.assertFalse(probe.read_recovery_status(self.path.with_name('missing.db'))['safeToRecycle'])
        self.assertFalse(self.path.with_name('missing.db').exists())
    def test_bad_document(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute('insert into state_documents values (?,?)', ('accounts', '[]'))
        self.assertFalse(probe.read_recovery_status(self.path)['safeToRecycle'])

    def target_status(self, tracker_id):
        # Old global-only authorization reproduces the regression without a
        # missing-parameter error; removing the target gate also goes red.
        if 'tracker_id' in inspect.signature(probe.read_recovery_status).parameters:
            return probe.read_recovery_status(self.path, tracker_id=tracker_id)
        return probe.read_recovery_status(self.path)
    def test_target_unknown_mapping_fails_closed(self):
        self.doc['accounts'][0]['browserTrackerId'] = '987654321'; self.save()
        self.assertFalse(self.target_status('123456789')['safeToRecycle'])
    def test_target_missing_or_malformed_mapping_fails_closed(self):
        self.doc['accounts'][0]['browserTrackerId'] = '987654321'; self.save()
        for tracker in (None, '', '987654321oops', ' 987654321', True, 987654321):
            with self.subTest(tracker=tracker):
                self.assertFalse(self.target_status(tracker)['safeToRecycle'])
        self.doc['accounts'][0].pop('browserTrackerId'); self.save()
        self.assertFalse(self.target_status('987654321')['safeToRecycle'])
    def test_target_duplicate_mapping_fails_closed(self):
        self.doc['accounts'][0]['browserTrackerId'] = '987654321'
        self.doc['accounts'].append(dict(self.doc['accounts'][0])); self.save()
        self.assertFalse(self.target_status('987654321')['safeToRecycle'])
    def test_target_exact_ready_match_is_read_only_and_secret_free(self):
        for stored_id in ('987654321', 987654321):
            self.doc['accounts'][0]['browserTrackerId'] = stored_id; self.save()
            before = self.path.read_bytes()
            result = self.target_status('987654321')
            self.assertTrue(result['safeToRecycle'])
            self.assertIs(result.get('targetReady'), True)
            self.assertEqual(result.get('matchedAccountCount'), 1)
            serialized = json.dumps(result)
            self.assertNotIn('987654321', serialized)
            self.assertNotIn('SECRET', serialized)
            self.assertEqual(before, self.path.read_bytes())
    def test_target_readiness_is_independent_of_unrelated_disabled_account(self):
        self.doc['accounts'][0]['browserTrackerId'] = '987654321'
        self.doc['accounts'].append({'autoRelaunch': False, 'cookieStatus': 'alive', 'browserTrackerId': '123456789'})
        self.save()
        self.assertTrue(self.target_status('987654321')['safeToRecycle'])

    def test_target_unrelated_malformed_or_duplicate_tracker_blocks(self):
        self.doc['accounts'][0]['browserTrackerId'] = '12345'
        for trackers in (('oops',), ('67890', '67890')):
            self.doc['accounts'] = self.doc['accounts'][:1]
            self.doc['accounts'].extend({'autoRelaunch': False, 'cookieStatus': 'dead', 'browserTrackerId': tracker} for tracker in trackers)
            self.save()
            self.assertFalse(self.target_status('12345')['safeToRecycle'])

    def test_target_cli_cannot_fall_back_to_global_ready(self):
        self.doc['accounts'][0]['browserTrackerId'] = '987654321'; self.save()
        volt = Path(self.temp.name) / 'Volt'; volt.mkdir()
        (volt / 'state.db').write_bytes(self.path.read_bytes())
        env = dict(os.environ, LOCALAPPDATA=self.temp.name)
        script = str(Path(__file__).resolve().parents[2] / 'src' / 'saver' / 'Arkuzo-Volt-Probe.py')
        unknown = subprocess.run([sys.executable, script, '--tracker-id', '123456789'], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(unknown.returncode, 0)
        self.assertFalse(json.loads(unknown.stdout)['safeToRecycle'])
        ready = subprocess.run([sys.executable, script, '--tracker-id', '987654321'], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(ready.returncode, 0)
        self.assertIs(json.loads(ready.stdout).get('targetReady'), True)
        self.assertNotIn('SECRET', ready.stdout)

    def test_inventory_allowlist_is_read_only(self):
        self.doc['accounts'][0].update(id='11111111-1111-4111-8111-111111111111', username='alpha', displayName='Alpha', browserTrackerId='12345', lastLaunchAtMs=1234567890, commandLine='AUTH-SECRET')
        self.save(); before = self.path.read_bytes()
        reader = getattr(probe, 'read_account_inventory', None)
        self.assertTrue(callable(reader), 'Sanitized inventory API must exist')
        result = reader(self.path)
        self.assertTrue(result['available'])
        self.assertEqual(result['accounts'], [{'accountId':'11111111-1111-4111-8111-111111111111','username':'alpha','displayName':'Alpha','trackerId':'12345','autoRelaunch':True,'cookieAlive':True,'cookieStatus':'alive','lastLaunchAtMs':1234567890}])
        self.assertTrue(result['safeToRecycle'])
        self.assertEqual(result['relaunchDelayMs'], 10000)
        self.assertNotIn('SECRET', json.dumps(result))
        self.assertEqual(before, self.path.read_bytes())

    def valid_inventory(self):
        self.doc['accounts'][0].update(id='11111111-1111-4111-8111-111111111111', username='alpha', displayName='Alpha', browserTrackerId='12345', lastLaunchAtMs=1234567890)

    def test_mixed_inventory_keeps_unlaunched_and_dead_rows(self):
        self.valid_inventory()
        for index, status in enumerate(('alive', 'dead', 'DEAD', None), 2):
            self.doc['accounts'].append(dict(self.doc['accounts'][0], id=f'{index:08d}-1111-4111-8111-111111111111', username=f'user{index}', displayName=f'User{index}', browserTrackerId=None, lastLaunchAtMs=None, cookieStatus=status))
        self.save(); before = self.path.read_bytes()
        result = probe.read_account_inventory(self.path)
        self.assertTrue(result['available'])
        self.assertTrue(result['safeToRecycle'])
        self.assertEqual([a['cookieStatus'] for a in result['accounts']], ['alive', 'alive', 'dead', 'unknown', 'unknown'])
        self.assertEqual(result['accounts'][1]['lastLaunchAtMs'], 0)
        self.assertIsNone(result['accounts'][1]['trackerId'])
        self.assertEqual(before, self.path.read_bytes())

    def test_inventory_duplicate_identity_and_nonempty_tracker_fail_closed(self):
        for field in ('id', 'username', 'displayName', 'browserTrackerId'):
            self.valid_inventory()
            other = dict(self.doc['accounts'][0], id='22222222-2222-4222-8222-222222222222', username='beta', displayName='Beta', browserTrackerId='67890')
            other[field] = self.doc['accounts'][0][field]
            self.doc['accounts'] = [self.doc['accounts'][0], other]
            self.save()
            self.assertFalse(probe.read_account_inventory(self.path)['available'], field)
        self.doc['accounts'] = self.doc['accounts'][:1]
        for value in ('', ' ', '12x', True):
            self.valid_inventory(); self.doc['accounts'][0]['browserTrackerId'] = value; self.save()
            self.assertFalse(probe.read_account_inventory(self.path)['available'])

    def test_inventory_malformed_identity_fails_closed(self):
        for key, bad in [('id','bad'), ('browserTrackerId','123x'), ('browserTrackerId',True), ('username',None), ('displayName',''), ('lastLaunchAtMs',True), ('lastLaunchAtMs',float('nan')), ('lastLaunchAtMs',-1)]:
            with self.subTest(key=key,bad=bad):
                self.valid_inventory(); self.doc['accounts'][0][key]=bad; self.save()
                result=probe.read_account_inventory(self.path)
                self.assertFalse(result['available'])
                self.assertFalse(result['safeToRecycle'])
                self.assertEqual(result['accounts'], [])

    def test_target_journal_has_stable_account_id_only(self):
        self.valid_inventory(); self.save()
        result=self.target_status('12345')
        self.assertEqual(result.get('accountId'), self.doc['accounts'][0]['id'])
        self.assertNotIn('12345', json.dumps(result))
        self.assertNotIn('alpha', json.dumps(result))

    def test_inventory_cli_is_one_sanitized_json_document(self):
        self.valid_inventory(); self.save()
        volt=Path(self.temp.name)/'Volt'; volt.mkdir()
        (volt/'state.db').write_bytes(self.path.read_bytes())
        result=subprocess.run([sys.executable, '-B', str(Path(__file__).resolve().parents[2]/'src'/'saver'/'Arkuzo-Volt-Probe.py'), '--inventory'],env=dict(os.environ,LOCALAPPDATA=self.temp.name),capture_output=True,text=True,timeout=5)
        self.assertEqual(result.returncode,0)
        self.assertTrue(json.loads(result.stdout)['available'])
        self.assertEqual(result.stderr,'')
        self.assertNotIn('SECRET',result.stdout)

    def test_cli_map_mode_returns_mappings(self):
        self.valid_inventory()
        self.save()
        volt = Path(self.temp.name) / 'Volt'
        volt.mkdir(exist_ok=True)
        (volt / 'state.db').write_bytes(self.path.read_bytes())
        result = subprocess.run([sys.executable, '-B', str(Path(__file__).resolve().parents[2]/'src'/'saver'/'Arkuzo-Volt-Probe.py'), '--map'],
                                env=dict(os.environ, LOCALAPPDATA=self.temp.name), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        data = json.loads(result.stdout)
        self.assertIn('byTracker', data)
        self.assertIn('byUserId', data)
        self.assertIn('byAccountId', data)
        self.assertEqual(data['byTracker'].get('12345'), 'alpha')

    def test_clean_dead_cookie_removes_account(self):
        self.doc['accounts'] = [
            {'id': '11111111-1111-1111-1111-111111111111', 'username': 'alive_user', 'cookieStatus': 'alive', 'encryptedCookie': 'SECRET_1', 'autoRelaunch': True},
            {'id': '22222222-2222-2222-2222-222222222222', 'username': 'dead_user', 'cookieStatus': 'dead', 'encryptedCookie': 'SECRET_2', 'autoRelaunch': True}
        ]
        self.save()
        res = probe.clean_dead_or_deleted_accounts(self.path)
        self.assertTrue(res['cleaned'])
        self.assertEqual(res['removedCount'], 1)
        self.assertEqual(res['removed'][0]['username'], 'dead_user')
        # Check persisted database
        with closing(sqlite3.connect(self.path)) as db:
            row = db.execute('SELECT value, typeof(value) FROM state_documents WHERE name=?', ('accounts',)).fetchone()
            self.assertEqual(row[1], 'blob')
            doc = json.loads(row[0])
            self.assertEqual(len(doc['accounts']), 1)
            self.assertEqual(doc['accounts'][0]['username'], 'alive_user')

    def test_clean_empty_cookie_removes_account(self):
        self.doc['accounts'] = [
            {'id': '11111111-1111-1111-1111-111111111111', 'username': 'alive_user', 'cookieStatus': 'alive', 'encryptedCookie': 'VALID_SECRET', 'autoRelaunch': True},
            {'id': '33333333-3333-3333-3333-333333333333', 'username': 'empty_cookie_user', 'cookieStatus': 'alive', 'encryptedCookie': '', 'autoRelaunch': True}
        ]
        self.save()
        res = probe.clean_dead_or_deleted_accounts(self.path)
        self.assertTrue(res['cleaned'])
        self.assertEqual(res['removedCount'], 1)
        self.assertEqual(res['removed'][0]['username'], 'empty_cookie_user')

    def test_clean_dead_cookies_cli(self):
        self.doc['accounts'] = [
            {'id': '11111111-1111-1111-1111-111111111111', 'username': 'alive_user', 'cookieStatus': 'alive', 'encryptedCookie': 'SECRET_1', 'autoRelaunch': True},
            {'id': '22222222-2222-2222-2222-222222222222', 'username': 'dead_user', 'cookieStatus': 'dead', 'encryptedCookie': 'SECRET_2', 'autoRelaunch': True}
        ]
        self.save()
        volt = Path(self.temp.name) / 'Volt'
        volt.mkdir(exist_ok=True)
        (volt / 'state.db').write_bytes(self.path.read_bytes())
        result = subprocess.run([sys.executable, '-B', str(Path(__file__).resolve().parents[2]/'src'/'saver'/'Arkuzo-Volt-Probe.py'), '--clean-dead-cookies'],
                                env=dict(os.environ, LOCALAPPDATA=self.temp.name), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        data = json.loads(result.stdout)
        self.assertTrue(data.get('cleaned'))
        self.assertEqual(data.get('removedCount'), 1)

if __name__ == '__main__':
    unittest.main(verbosity=2)
