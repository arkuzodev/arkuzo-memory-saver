"""Several accounts at once (docs/accounts.md): delete with Undo (held UNDO_SEC, then gone),
assign / remove a group, relaunch on/off, launch, close and check, all validated, token-protected
and atomic in the vault; plus the page has no confirm/alert/prompt popup left. Roblox is never
contacted: cookies are synthetic and only their encrypted form is stored."""
import json
import re
import shutil
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from test_account_vault import FakeRoblox, cc, fake_cookie

ROOT = Path(__file__).resolve().parents[2]


class BulkTests(unittest.TestCase):
    def setUp(self):
        self.data = Path(tempfile.mkdtemp())
        self.roblox = FakeRoblox()
        self.saved = cc.HTTP['request']
        cc.HTTP['request'] = self.roblox
        self.ids = []
        for i, tag in enumerate('abcde'):
            cookie = fake_cookie(tag)
            self.roblox.users[cookie] = (500 + i, f'Farm{tag.upper()}', f'Farm {tag}')
            self.ids.append(cc.add_account(self.data, cookie)['id'])

    def tearDown(self):
        cc.HTTP['request'] = self.saved
        shutil.rmtree(self.data, ignore_errors=True)

    def accounts(self):
        return {a['id']: a for a in cc.load_vault(self.data)['accounts']}

    def test_group_relaunch_launch_close(self):
        r = cc.bulk_accounts(self.data, 'group', self.ids[:3], '  Farm A ')
        self.assertEqual(r['count'], 3)
        self.assertEqual([self.accounts()[i]['group'] for i in self.ids], ['Farm A', 'Farm A', 'Farm A', '', ''])
        cc.bulk_accounts(self.data, 'group', self.ids[1:2], '')
        self.assertEqual(self.accounts()[self.ids[1]]['group'], '', 'remove from group')
        cc.bulk_accounts(self.data, 'relaunch', self.ids, False)
        self.assertFalse(any(a['autoRelaunch'] for a in self.accounts().values()))
        # A dead account is skipped, never launched.
        cc.update_vault(self.data, lambda v: v['accounts'][0].update(cookieStatus='dead'))
        dead = cc.load_vault(self.data)['accounts'][0]['id']
        r = cc.bulk_accounts(self.data, 'launch', self.ids, None)
        self.assertEqual((r['count'], r['skipped']), (4, [dead]))
        self.assertEqual(self.accounts()[dead]['launchRequestedAtMs'], 0)
        r = cc.bulk_accounts(self.data, 'close', self.ids[:2], None)
        self.assertEqual(r['closed'], 0, 'no heartbeat: nothing closed from here; the saver handles the stamps')
        self.assertTrue(all(self.accounts()[i]['closeRequestedAtMs'] > 0 for i in self.ids[:2]))
        # Groups are kept by normalize_vault and shown in the view (not secret).
        view = cc.public_vault(cc.load_vault(self.data))
        self.assertEqual(sorted({a['group'] for a in view['accounts']}), ['', 'Farm A'])

    def test_validation_is_all_or_nothing(self):
        before = (self.data / cc.VAULT_FILE).read_bytes()
        for args in (('group', self.ids + [str(uuid.uuid4())], 'x'), ('group', self.ids, 'x' * 41), ('group', self.ids, 'bad\nname'),
                     ('group', self.ids, 5), ('relaunch', self.ids, 'yes'), ('delete', [], None), ('delete', 'all', None),
                     ('delete', ['../x'], None), ('explode', self.ids, None), ('check', self.ids, None),
                     ('delete', [str(uuid.uuid4())] * 1001, None)):
            with self.assertRaises(cc.VaultError, msg=repr(args[:1])):
                cc.bulk_accounts(self.data, *args)
        self.assertEqual((self.data / cc.VAULT_FILE).read_bytes(), before, 'a refused bulk action writes nothing')

    def test_delete_undo_and_commit(self):
        r = cc.bulk_accounts(self.data, 'delete', self.ids[:2] + [self.ids[0].upper()], None)
        self.assertEqual((r['count'], r['undoSec']), (2, cc.UNDO_SEC))
        self.assertRegex(r['batch'], r'^[0-9a-f]{16}$')
        self.assertEqual(set(self.accounts()), set(self.ids[2:]))
        text = (self.data / cc.VAULT_FILE).read_text(encoding='utf-8')
        self.assertNotIn('WARNING:-DO-NOT-SHARE', text, 'held rows stay encrypted')
        self.assertNotIn('trash', json.dumps(cc.public_vault(cc.load_vault(self.data))), 'the bin never reaches a view')
        # Undo brings back everything, including the encrypted cookie and settings.
        cc.update_account(self.data, self.ids[2], {'notes': 'unchanged'})
        before = {i: dict(a) for i, a in self.accounts().items()}
        r = cc.bulk_accounts(self.data, 'restore', batch=r['batch'])
        self.assertEqual(r, {'restored': 2, 'skipped': 0})
        after = self.accounts()
        self.assertEqual(set(after), set(self.ids))
        self.assertEqual(cc.unprotect_secret(after[self.ids[0]]['cookie']), fake_cookie('a'))
        self.assertEqual({i: after[i] for i in before}, before)
        with self.assertRaises(cc.VaultError):
            cc.bulk_accounts(self.data, 'restore', batch=r.get('batch') or '0' * 16)
        # Committed after UNDO_SEC: purge removes the held rows for good; undo is then refused.
        r = cc.bulk_accounts(self.data, 'delete', self.ids[:1], None)
        self.assertEqual(cc.purge_trash(self.data), 0, 'too early')
        self.assertEqual(cc.purge_trash(self.data, now=cc.now_ms() + cc.UNDO_SEC * 1000 + 1), 1)
        self.assertEqual(cc.load_vault(self.data)['trash'], [])
        with self.assertRaisesRegex(cc.VaultError, 'Too late'):
            cc.bulk_accounts(self.data, 'restore', batch=r['batch'])
        self.assertNotIn(self.ids[0], self.accounts())

    def test_undo_skips_an_account_added_again(self):
        r = cc.bulk_accounts(self.data, 'delete', self.ids[:1], None)
        cc.add_account(self.data, fake_cookie('a'))  # The same Roblox user, added again meanwhile.
        self.assertEqual(cc.bulk_accounts(self.data, 'restore', batch=r['batch']), {'restored': 0, 'skipped': 1})
        self.assertEqual(len([a for a in self.accounts().values() if a['userId'] == 500]), 1)

    def test_the_engine_keeps_the_bin_and_ignores_it(self):
        cc.bulk_accounts(self.data, 'delete', self.ids[:1], None)
        raw = json.loads((self.data / cc.VAULT_FILE).read_text(encoding='utf-8'))
        self.assertEqual(len(raw['trash']), 1)
        self.assertEqual(len(raw['accounts']), 4, 'the engine reads accounts only: a held row is never launched')


class BulkRouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = Path(tempfile.mkdtemp())
        cls.app = cc.App(cls.data, 0)
        cls.app.supervisor.initial_start = False
        cc.Handler.app = cls.app
        cls.server = cc.ThreadingHTTPServer(('127.0.0.1', 0), cc.Handler)
        cls.port = cls.app.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        shutil.rmtree(cls.data, ignore_errors=True)

    def request(self, path, body, token=None):
        req = urllib.request.Request(f'http://127.0.0.1:{self.port}' + path, data=json.dumps(body).encode(), method='POST')
        if token:
            req.add_header('X-Arkuzo-Token', token)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_bulk_needs_the_token_and_validates(self):
        self.assertEqual(cc.POST_ROUTES['/api/vault/bulk'][1], cc.Handler.AUTH_TOKEN)
        self.assertEqual(self.request('/api/vault/bulk', {'action': 'delete', 'ids': []})[0], 403)
        self.assertEqual(self.request('/api/vault/bulk', {'action': 'delete', 'ids': []}, token='wrong')[0], 403)
        status, body = self.request('/api/vault/bulk', {'action': 'delete', 'ids': []}, token=self.app.token)
        self.assertEqual(status, 400)
        status, body = self.request('/api/vault/bulk', {'action': 'check', 'ids': [str(uuid.uuid4())]}, token=self.app.token)
        self.assertEqual(status, 400, body)


class NoPopupTests(unittest.TestCase):
    def test_page_has_no_confirm_alert_or_prompt(self):
        for path in [ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.html', *sorted((ROOT / 'src' / 'saver' / 'control-center').glob('*'))]:
            text = path.read_text(encoding='utf-8')
            found = re.findall(r'(?<![\w.$])(?:window\.)?(confirm|alert|prompt)\s*\(', text)
            self.assertEqual(found, [], f'{path.name}: popups are replaced by Undo toasts or inline state')


if __name__ == '__main__':
    unittest.main()
