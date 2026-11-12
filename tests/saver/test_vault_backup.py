"""Crash-safe account vault: durable writes, backups, automatic restore, starting over.

11 Nov: a blue screen hit while data/accounts.json was being saved. The rename was on disk,
the data was not: the file came back as 28 KB of NUL and there was no backup. These tests
damage the vault the ways a crash or a bad edit can (all NUL, truncated, not JSON, not an
object) and check that it is restored from accounts.json.bak or the newest valid snapshot,
that the damaged file is always kept, and that without any valid copy nothing is overwritten
until the user starts a new list. Every file lives in a temp folder and the vault mutex has
a test-only name, so a running Control Center is never touched. No cookie is real: rows carry
an opaque 'dpapi:' placeholder that is never decrypted.
"""
import datetime as dt
import importlib.util
import json
import secrets
import shutil
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('control_center_vault_backup', ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.py')
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)

A = '11111111-1111-4111-8111-111111111111'
B = '22222222-2222-4222-8222-222222222222'


def account(aid, uid, name, tracker):
    return {'id': aid, 'userId': uid, 'username': name, 'displayName': name, 'cookie': 'dpapi:UExBQ0VIT0xERVI=',
            'cookieStatus': 'alive', 'browserTrackerId': tracker, 'autoRelaunch': True}


class VaultBackupTests(unittest.TestCase):
    def setUp(self):
        self.data = Path(tempfile.mkdtemp())
        self.mutex = cc.VAULT_MUTEX
        cc.VAULT_MUTEX = 'Local\\ArkuzoAccountVault-Test-' + secrets.token_hex(8)
        cc.take_vault_events()
        self.path = self.data / cc.VAULT_FILE

    def tearDown(self):
        cc.VAULT_MUTEX = self.mutex
        cc.take_vault_events()
        shutil.rmtree(self.data)

    def save(self, *accounts):
        def change(vault):
            vault['accounts'] = [dict(a) for a in accounts]
        cc.update_vault(self.data, change)

    def names(self, vault):
        return [a['username'] for a in vault['accounts']]

    def write_snapshot(self, stamp, raw: bytes):
        folder = self.data / cc.VAULT_SNAPSHOT_DIR
        folder.mkdir(exist_ok=True)
        (folder / f'accounts-{stamp}.json').write_bytes(raw)

    def damaged_files(self):
        return sorted(p for p in self.data.iterdir() if p.name.startswith(cc.VAULT_FILE + '.damaged-'))

    # ---- backups on save ----
    def test_save_keeps_previous_valid_content_and_one_snapshot_per_hour(self):
        self.save(account(A, 101, 'Alpha', '123456789012'))
        first = self.path.read_bytes()
        self.assertFalse((self.data / cc.VAULT_BACKUP).exists(), 'nothing to back up before the first save')
        self.save(account(A, 101, 'Alpha', '123456789012'), account(B, 102, 'Bravo', '223456789012'))
        self.assertEqual((self.data / cc.VAULT_BACKUP).read_bytes(), first, '.bak holds the exact previous content')
        snaps = cc.vault_snapshots(self.data)
        self.assertEqual(len(snaps), 1, 'at most one snapshot per hour')
        self.assertEqual(self.names(json.loads(snaps[0].read_bytes())), ['Alpha'], 'the first save of the hour is the snapshot')
        self.assertRegex(snaps[0].name, r'\Aaccounts-\d{8}-\d{2}\.json\Z')

    def test_damaged_content_never_becomes_the_backup(self):
        self.save(account(A, 101, 'Alpha', '123456789012'))
        self.save(account(B, 102, 'Bravo', '223456789012'))
        good_backup = (self.data / cc.VAULT_BACKUP).read_bytes()
        self.path.write_bytes(b'\x00' * 512)
        with cc.vault_lock():
            cc.save_vault(self.data, cc.empty_vault())
        self.assertEqual((self.data / cc.VAULT_BACKUP).read_bytes(), good_backup, 'a NUL file is not backed up over a good .bak')

    # ---- automatic restore ----
    def restore_case(self, damage: bytes):
        self.save(account(A, 101, 'Alpha', '123456789012'))
        self.save(account(A, 101, 'Alpha', '123456789012'), account(B, 102, 'Bravo', '223456789012'))
        backup = (self.data / cc.VAULT_BACKUP).read_bytes()
        self.path.write_bytes(damage)
        vault = cc.load_vault(self.data)
        self.assertEqual(self.names(vault), ['Alpha'], 'restored from .bak')
        self.assertEqual(self.path.read_bytes(), backup, 'the backup bytes are written back exactly')
        kept = self.damaged_files()
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0].read_bytes(), damage, 'the damaged file is kept, unchanged')
        events = cc.take_vault_events()
        self.assertEqual([e['kind'] for e in events], ['VAULT_RESTORED_FROM_BACKUP'])
        self.assertIn(cc.VAULT_BACKUP, events[0]['text'])
        self.assertIn(kept[0].name, events[0]['text'])
        self.assertEqual(self.names(cc.load_vault(self.data)), ['Alpha'], 'restored once, then read normally')
        self.assertEqual(len(self.damaged_files()), 1)

    def test_zero_filled_vault_is_restored_from_bak(self):
        self.restore_case(b'\x00' * 28182)

    def test_truncated_vault_is_restored_from_bak(self):
        self.restore_case(b'{"schemaVersion": 1, "accounts": [ {"id": "half-wri')

    def test_invalid_or_wrong_shape_vault_is_restored_from_bak(self):
        self.restore_case(b'[1, 2, 3]')

    def test_empty_vault_file_is_restored(self):
        self.restore_case(b'')

    def test_newest_valid_snapshot_wins_when_bak_is_bad(self):
        older = json.dumps({'accounts': [account(A, 101, 'Older', '123456789012')]}).encode()
        newer = json.dumps({'accounts': [account(B, 102, 'Newer', '223456789012')]}).encode()
        self.write_snapshot('20261110-08', older)
        self.write_snapshot('20261110-09', newer)
        self.write_snapshot('20261110-10', b'\x00' * 64)  # newest, but damaged too
        (self.data / cc.VAULT_BACKUP).write_bytes(b'{"accounts": ')
        self.path.write_bytes(b'\x00' * 100)
        vault = cc.load_vault(self.data)
        self.assertEqual(self.names(vault), ['Newer'])
        self.assertEqual(self.path.read_bytes(), newer)
        self.assertIn('accounts-20261110-09.json', cc.take_vault_events()[0]['text'])

    def test_restore_clears_stale_requests(self):
        stamped = account(A, 101, 'Alpha', '123456789012')
        stamped.update(closeRequestedAtMs=1794000000000, launchRequestedAtMs=1794000000001, futureField='kept')
        raw = json.dumps({'accounts': [stamped], 'settings': {'arrangeRequestedAtMs': 1794000000002, 'farmRunning': True}, 'extra': 1}).encode()
        (self.data / cc.VAULT_BACKUP).write_bytes(raw)
        self.path.write_bytes(b'\x00' * 50)
        vault = cc.load_vault(self.data)
        row = vault['accounts'][0]
        self.assertEqual((row['closeRequestedAtMs'], row['launchRequestedAtMs'], vault['settings']['arrangeRequestedAtMs']), (0, 0, 0),
                         'a Close or Launch already carried out is not replayed from an old copy')
        self.assertTrue(vault['settings']['farmRunning'])
        saved = json.loads(self.path.read_bytes())
        self.assertEqual((saved['extra'], saved['accounts'][0]['futureField']), (1, 'kept'), 'unknown fields survive')
        self.assertEqual((self.data / cc.VAULT_BACKUP).read_bytes(), raw, 'the restored copy stays as .bak')

    def test_snapshot_used_when_there_is_no_bak(self):
        snap = json.dumps({'accounts': [account(A, 101, 'Snap', '123456789012')], 'settings': {'farmRunning': True}}).encode()
        self.write_snapshot('20261111-11', snap)
        self.path.write_bytes(b'not json')
        self.assertEqual(self.names(cc.load_vault(self.data)), ['Snap'])
        self.assertTrue(cc.load_vault(self.data)['settings']['farmRunning'])

    # ---- no valid copy ----
    def test_no_valid_copy_refuses_and_start_new_list_keeps_the_damaged_file(self):
        damage = b'\x00' * 300
        self.path.write_bytes(damage)
        (self.data / cc.VAULT_BACKUP).write_bytes(b'\x00' * 10)
        with self.assertRaises(cc.VaultDamagedError):
            cc.load_vault(self.data)
        with self.assertRaises(cc.VaultError):
            cc.update_vault_settings(self.data, {'launchDelaySec': 20})
        self.assertEqual(self.path.read_bytes(), damage, 'nothing overwrites it')
        self.assertEqual(self.damaged_files(), [], 'nothing moved aside without the user')
        # The page shows the damage and the button.
        app = types.SimpleNamespace(data=self.data, heartbeat=None, cookies=types.SimpleNamespace(busy=set()),
                                    login=types.SimpleNamespace(snapshot=lambda: {}, browser=None), drain_vault_events=lambda: None)
        view = cc.App.vault_view(app)
        self.assertTrue(view['damaged'])
        self.assertIn('Start a new account list', view['error'])
        # The token-protected route behind the button.
        self.assertIn('/api/vault/reset', cc.VAULT_ROUTES)
        result = cc.vault_action(types.SimpleNamespace(data=self.data), '/api/vault/reset', {})
        kept = self.damaged_files()
        self.assertEqual([p.name for p in kept], [result['kept']])
        self.assertEqual(kept[0].read_bytes(), damage)
        self.assertEqual(cc.load_vault(self.data)['accounts'], [])
        self.assertEqual([e['kind'] for e in cc.take_vault_events()], ['VAULT_RESET'])
        with self.assertRaises(cc.VaultError):
            cc.reset_vault(self.data)  # Readable now: nothing to replace.
        self.assertEqual(len(self.damaged_files()), 1)

    def test_start_new_list_refused_while_a_valid_backup_exists(self):
        self.path.write_bytes(b'\x00' * 30)
        self.write_snapshot('20261111-11', json.dumps({'accounts': []}).encode())
        with self.assertRaises(cc.VaultError):
            cc.reset_vault(self.data)
        self.assertEqual(self.path.read_bytes(), b'\x00' * 30)

    def test_page_has_the_button_and_route(self):
        page = (ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.html').read_text(encoding='utf-8')
        self.assertIn('id="btnVaultReset"', page)
        self.assertIn("'/api/vault/reset'", page)
        self.assertIn("armed($('btnVaultReset')", page, 'second click within 4 s, no confirm()')

    # ---- durable writes ----
    def test_every_write_is_flushed_before_the_replace(self):
        calls = []
        original_fsync, original_replace = cc.os.fsync, cc.os.replace

        def fsync(fd):
            calls.append(('fsync', ''))
            return original_fsync(fd)

        def replace(src, dst):
            calls.append(('replace', Path(dst).name))
            return original_replace(src, dst)
        cc.os.fsync, cc.os.replace = fsync, replace
        try:
            self.save(account(A, 101, 'Alpha', '123456789012'))
            self.save(account(B, 102, 'Bravo', '223456789012'))
            kinds = [c[0] for c in calls]
            replaced = [c[1] for c in calls if c[0] == 'replace']
            self.assertIn(cc.VAULT_BACKUP, replaced)
            self.assertIn(cc.VAULT_FILE, replaced)
            for i, (kind, _) in enumerate(calls):
                if kind == 'replace':
                    self.assertEqual(kinds[i - 1], 'fsync', 'each replace follows a flush to the disk')
            calls.clear()
            cc.write_json_atomic(self.data / 'config.json', {'a': 1})
            cc.write_json_atomic(self.data / 'control-center.json', {'autopilot': True})
            self.assertEqual([c[0] for c in calls], ['fsync', 'replace', 'fsync', 'replace'])
            calls.clear()
            cc.backup_config(self.data)
            self.assertEqual([c[0] for c in calls], ['fsync', 'replace'], 'config backups are flushed too')
        finally:
            cc.os.fsync, cc.os.replace = original_fsync, original_replace

    # ---- snapshot rotation ----
    def test_rotation_keeps_newest_72_and_one_per_day_for_a_week(self):
        now = dt.datetime(2026, 11, 11, 21, 30, tzinfo=dt.timezone.utc)
        names = [(now - dt.timedelta(hours=h)).strftime('accounts-%Y%m%d-%H.json') for h in range(0, 24 * 12)]
        names += ['accounts-latest.json', 'notes.txt']
        remove = set(cc.vault_snapshots_to_remove(names, now))
        kept = sorted(n for n in names if cc.VAULT_SNAPSHOT_NAME.match(n) and n not in remove)
        self.assertNotIn('accounts-latest.json', remove)
        self.assertNotIn('notes.txt', remove)
        newest = sorted((n for n in names if cc.VAULT_SNAPSHOT_NAME.match(n)), reverse=True)
        self.assertTrue(set(newest[:72]) <= set(kept), 'the newest 72 stay')
        older_days = sorted({n[9:17] for n in kept if n not in newest[:72]})
        # The newest 72 reach back to 8 Nov; 4-7 Nov keep one each; 3 Nov is more than 7 days old.
        self.assertEqual(older_days, ['20261104', '20261105', '20261106', '20261107'], 'one per day back to 7 days ago')
        self.assertEqual(len(kept), 72 + 4)
        for day in older_days:
            self.assertEqual([n for n in kept if n[9:17] == day], [max(n for n in newest if n[9:17] == day)], 'the newest of the day')

    def test_snapshot_writer_prunes_engine_made_files(self):
        folder = self.data / cc.VAULT_SNAPSHOT_DIR
        folder.mkdir()
        now = dt.datetime(2026, 11, 11, 12, 0, tzinfo=dt.timezone.utc)
        for h in range(1, 100):
            (folder / (now - dt.timedelta(hours=h)).strftime('accounts-%Y%m%d-%H.json')).write_bytes(b'{"accounts": []}')
        (folder / 'keep-me.json').write_bytes(b'x')
        self.assertTrue(cc.save_vault_snapshot(self.data, b'{"accounts": []}', now))
        self.assertFalse(cc.save_vault_snapshot(self.data, b'{"accounts": [1]}', now), 'one per hour')
        left = sorted(p.name for p in folder.iterdir())
        self.assertIn('keep-me.json', left)
        self.assertIn(now.strftime('accounts-%Y%m%d-%H.json'), left)
        self.assertEqual(len(left), 72 + 1 + 1, '72 newest (incl. this hour), one older day (7 Nov), plus the foreign file')


if __name__ == '__main__':
    unittest.main()
