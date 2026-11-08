"""Arkuzo's own account manager: vault, cookie checks, private servers, sign-in window.

Roblox is never contacted: the HTTP transport is replaced with a fake. Every
cookie here is synthetic and carries Roblox's warning prefix, so a leak of any
of them into a view, file or log is easy to detect.
"""
import importlib.util
import json
import shutil
import tempfile
import unittest
from email.message import Message
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('control_center_vault', ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.py')
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)

PREFIX = '_|WARNING:-DO-NOT-SHARE-THIS.--Sharing-this-will-allow-someone-to-log-in-as-you-and-to-steal-your-ROBUX-and-items.|_'


def fake_cookie(tag: str) -> str:
    return PREFIX + 'FAKE' + tag * 40


def headers(**values):
    msg = Message()
    for name, value in values.items():
        for v in value if isinstance(value, list) else [value]:
            msg[name.replace('_', '-')] = v
    return msg


class FakeRoblox:
    """users/authenticated, the CSRF handshake and share-link resolution."""

    def __init__(self):
        self.users = {}       # cookie -> (id, name, displayName)
        self.rotate = {}      # cookie -> replacement issued via Set-Cookie
        self.calls = []
        self.offline = False

    def __call__(self, url, cookie=None, method='GET', body=None, csrf=None, timeout=15.0):
        self.calls.append((url, method, csrf))
        if self.offline:
            return cc.RobloxResponse(0, cc._NoHeaders(), b'')
        extra = {}
        if cookie in self.rotate:
            extra['Set_Cookie'] = f'.ROBLOSECURITY={self.rotate[cookie]}; domain=.roblox.com; path=/; secure; HttpOnly'
        if url.endswith('/v1/users/authenticated'):
            if cookie in self.users:
                uid, name, display = self.users[cookie]
                return cc.RobloxResponse(200, headers(**extra), json.dumps({'id': uid, 'name': name, 'displayName': display}).encode())
            return cc.RobloxResponse(401, headers(), b'{}')
        if url.endswith('/sharelinks/v1/resolve-link'):
            if not csrf:
                return cc.RobloxResponse(403, headers(x_csrf_token='tok123', **extra), b'{}')
            if body.get('linkId') == 'abcDEF123':
                return cc.RobloxResponse(200, headers(**extra), json.dumps({'privateServerInviteData': {'linkCode': 'LINK-CODE-1', 'placeId': 4242}}).encode())
            return cc.RobloxResponse(404, headers(), b'{}')
        return cc.RobloxResponse(404, headers(), b'{}')


class VaultTests(unittest.TestCase):
    def setUp(self):
        self.data = Path(tempfile.mkdtemp())
        self.roblox = FakeRoblox()
        self.saved = cc.HTTP['request']
        cc.HTTP['request'] = self.roblox

    def tearDown(self):
        cc.HTTP['request'] = self.saved
        shutil.rmtree(self.data)

    def assert_no_secrets(self):
        text = (self.data / cc.VAULT_FILE).read_text(encoding='utf-8') if (self.data / cc.VAULT_FILE).exists() else ''
        self.assertNotIn('WARNING:-DO-NOT-SHARE', text, 'vault file stores cookies encrypted only')
        self.assertNotIn('LINK-CODE', text, 'link codes are encrypted too')
        view = json.dumps(cc.public_vault(cc.load_vault(self.data)))
        self.assertNotIn('WARNING:-DO-NOT-SHARE', view)
        self.assertNotIn('dpapi:', view, 'views carry no secret, not even encrypted')

    def test_dpapi_round_trip(self):
        secret = cc.protect_secret(fake_cookie('a'))
        self.assertTrue(secret.startswith('dpapi:'))
        self.assertEqual(cc.unprotect_secret(secret), fake_cookie('a'))

    def test_add_check_rotate_and_dead(self):
        c1 = fake_cookie('b')
        self.roblox.users[c1] = (101, 'FarmBravo', 'Bravo')
        added = cc.add_account(self.data, '.ROBLOSECURITY=' + c1 + '; path=/')
        self.assertEqual((added['userId'], added['username'], added['updated']), (101, 'FarmBravo', False))
        self.assertNotIn('cookie', added)
        vault = cc.load_vault(self.data)
        account = vault['accounts'][0]
        self.assertRegex(account['browserTrackerId'], r'^\d{12}$')
        self.assertTrue(account['autoRelaunch'])
        self.assertEqual(cc.unprotect_secret(account['cookie']), c1)
        self.assert_no_secrets()

        # Roblox re-issues the cookie on a check: the vault keeps the new one.
        c2 = fake_cookie('c')
        self.roblox.rotate[c1] = c2
        self.roblox.users[c2] = self.roblox.users[c1]
        self.assertEqual(cc.check_account(self.data, account['id'])['status'], 'alive')
        self.assertEqual(cc.unprotect_secret(cc.load_vault(self.data)['accounts'][0]['cookie']), c2)

        # Offline is never "dead".
        self.roblox.offline = True
        self.assertEqual(cc.check_account(self.data, account['id'])['status'], 'alive')
        self.assertIn('unreachable', cc.load_vault(self.data)['accounts'][0]['lastError'])
        self.roblox.offline = False

        # Signed out: dead.
        del self.roblox.users[c2]
        result = cc.check_account(self.data, account['id'])
        self.assertEqual(result['status'], 'dead')
        self.assertEqual(cc.load_vault(self.data)['accounts'][0]['cookieStatus'], 'dead')
        with self.assertRaises(cc.VaultError):
            cc.request_account_action(self.data, account['id'], 'launch')

        # Adding the same user again refreshes its cookie instead of duplicating it.
        c3 = fake_cookie('d')
        self.roblox.users[c3] = (101, 'FarmBravo', 'Bravo')
        again = cc.add_account(self.data, c3)
        self.assertTrue(again['updated'])
        vault = cc.load_vault(self.data)
        self.assertEqual(len(vault['accounts']), 1)
        self.assertEqual(vault['accounts'][0]['cookieStatus'], 'alive')
        self.assert_no_secrets()

    def test_dead_or_malformed_cookie_is_refused(self):
        with self.assertRaises(cc.VaultError):
            cc.add_account(self.data, fake_cookie('e'))  # Roblox says 401.
        with self.assertRaises(cc.VaultError):
            cc.add_account(self.data, 'hello')
        self.assertEqual(cc.load_vault(self.data)['accounts'], [])

    def test_unique_trackers_fields_settings_and_actions(self):
        for i, tag in enumerate('fghij'):
            self.roblox.users[fake_cookie(tag)] = (200 + i, f'Farm{i}', f'F{i}')
            cc.add_account(self.data, fake_cookie(tag))
        vault = cc.load_vault(self.data)
        trackers = [a['browserTrackerId'] for a in vault['accounts']]
        self.assertEqual(len(set(trackers)), 5)
        aid = vault['accounts'][0]['id']
        with self.assertRaises(cc.VaultError):
            cc.set_farm_running(self.data, True)  # No place to farm yet.
        updated = cc.update_account(self.data, aid, {'alias': '  Main  ', 'group': 'A', 'autoRelaunch': False, 'placeId': '1234'})
        self.assertEqual((updated['alias'], updated['autoRelaunch'], updated['placeId']), ('Main', False, '1234'))
        for bad in ({'autoRelaunch': 'yes'}, {'placeId': 'abc'}, {'cookie': 'x'}, {'privateServerId': 'nope'}):
            with self.assertRaises(cc.VaultError):
                cc.update_account(self.data, aid, bad)
        with self.assertRaises(cc.VaultError):
            cc.update_vault_settings(self.data, {'launchDelaySec': 1})
        settings = cc.update_vault_settings(self.data, {'defaultPlaceId': '920587237', 'launchDelaySec': 15})
        self.assertEqual(settings['launchDelaySec'], 15)
        self.assertTrue(cc.set_farm_running(self.data, True)['farmRunning'])
        cc.request_account_action(self.data, aid, 'launch')
        self.assertGreater(cc.load_vault(self.data)['accounts'][0]['launchRequestedAtMs'], 0)
        stopped = cc.set_farm_running(self.data, False, close_clients=True)
        self.assertFalse(stopped['farmRunning'])
        self.assertTrue(all(a['closeRequestedAtMs'] > 0 and a['launchRequestedAtMs'] == 0 for a in cc.load_vault(self.data)['accounts']))
        cc.remove_account(self.data, aid)
        self.assertEqual(len(cc.load_vault(self.data)['accounts']), 4)
        self.assert_no_secrets()

    def test_private_server_links(self):
        legacy = cc.parse_private_server_link('https://www.roblox.com/games/920587237/Adopt-Me?privateServerLinkCode=12345678901234567890')
        self.assertEqual((legacy['placeId'], legacy['linkCode']), ('920587237', '12345678901234567890'))
        for bad in ('http://www.roblox.com/games/1?privateServerLinkCode=123456', 'https://evil.example/games/1?privateServerLinkCode=123456',
                    'https://www.roblox.com/games/1/x', 'https://www.roblox.com/share?code=abc&type=ExperienceInvite'):
            with self.assertRaises(cc.VaultError):
                cc.parse_private_server_link(bad)
        with self.assertRaises(cc.VaultError):
            cc.add_private_server(self.data, 'x', 'https://www.roblox.com/share?code=abcDEF123&type=Server')  # No account to resolve with.
        self.roblox.users[fake_cookie('k')] = (300, 'Farm', 'F')
        account = cc.add_account(self.data, fake_cookie('k'))
        server = cc.add_private_server(self.data, 'Main VIP', 'https://www.roblox.com/share?code=abcDEF123&type=Server')
        self.assertEqual(server['placeId'], '4242')
        self.assertIn(('https://apis.roblox.com/sharelinks/v1/resolve-link', 'POST', 'tok123'), self.roblox.calls, 'CSRF handshake used')
        vault = cc.load_vault(self.data)
        self.assertEqual(cc.unprotect_secret(vault['privateServers'][0]['linkCode']), 'LINK-CODE-1')
        cc.update_account(self.data, account['id'], {'privateServerId': server['id']})
        cc.update_vault_settings(self.data, {'privateServerMode': 'shared', 'sharedPrivateServerId': server['id']})
        self.assert_no_secrets()
        cc.remove_private_server(self.data, server['id'])
        vault = cc.load_vault(self.data)
        self.assertIsNone(vault['accounts'][0]['privateServerId'])
        self.assertIsNone(vault['settings']['sharedPrivateServerId'])

    def test_malformed_rows_are_kept_not_fatal(self):
        good = cc.protect_secret(fake_cookie('m'))
        (self.data / cc.VAULT_FILE).write_text(json.dumps({'accounts': [
            {'id': '11111111-1111-4111-8111-111111111111', 'userId': 5, 'browserTrackerId': '123456789012', 'cookie': good},
            {'id': '22222222-2222-4222-8222-222222222222', 'userId': 6, 'browserTrackerId': '123456789012', 'cookie': good},  # Duplicate tracker.
            {'id': 'nope', 'userId': 7, 'browserTrackerId': '223456789012', 'cookie': good},
            {'id': '33333333-3333-4333-8333-333333333333', 'userId': 8, 'browserTrackerId': '323456789012', 'cookie': 'plain-text'},
        ], 'settings': {'launchDelaySec': 'fast', 'farmRunning': True}}), encoding='utf-8')
        vault = cc.load_vault(self.data)
        self.assertEqual([a['userId'] for a in vault['accounts']], [5])
        self.assertEqual(vault['settings']['launchDelaySec'], 12)
        self.assertTrue(vault['settings']['farmRunning'])
        # Unusable rows are kept untouched (they may hold the only copy of a cookie), across writes.
        self.assertEqual(len(vault['unreadable']), 3)
        cc.update_vault_settings(self.data, {'launchDelaySec': 20})
        saved = json.loads((self.data / cc.VAULT_FILE).read_text(encoding='utf-8'))
        self.assertEqual(len(saved['unreadable']), 3)
        self.assertEqual(len(cc.load_vault(self.data)['unreadable']), 3, 'not duplicated by a reload')
        self.assertEqual(cc.public_vault(cc.load_vault(self.data))['unreadableCount'], 3)

    def test_damaged_vault_is_never_overwritten(self):
        path = self.data / cc.VAULT_FILE
        path.write_text('{"accounts": [ {"id": "half-written', encoding='utf-8')
        with self.assertRaises(cc.VaultError):
            cc.load_vault(self.data)
        self.roblox.users[fake_cookie('n')] = (400, 'Farm', 'F')
        with self.assertRaises(cc.VaultError):
            cc.add_account(self.data, fake_cookie('n'))
        with self.assertRaises(cc.VaultError):
            cc.update_vault_settings(self.data, {'launchDelaySec': 20})
        self.assertEqual(path.read_text(encoding='utf-8'), '{"accounts": [ {"id": "half-written', 'damaged file left untouched')

    def test_login_cookie_selection(self):
        cookies = [{'name': 'RBXEventTrackerV2', 'domain': '.roblox.com', 'value': 'x'},
                   {'name': '.ROBLOSECURITY', 'domain': '.evil.com', 'value': 'nope'},
                   {'name': '.ROBLOSECURITY', 'domain': '.roblox.com', 'value': 'yes'}]
        self.assertEqual(cc.login_cookie_from(cookies), 'yes')
        self.assertIsNone(cc.login_cookie_from(cookies[:2]))


class BrowserLoginTests(unittest.TestCase):
    """The real sign-in window (headless here): a planted fake login cookie is picked up only
    once Roblox (faked) accepts it, then the window closes and its throwaway profile is deleted."""

    def test_sign_in_window_hands_over_the_cookie_and_cleans_up(self):
        browser = cc.find_app_browser()
        if browser is None:
            self.skipTest('Edge or Chrome not installed')
        data = Path(tempfile.mkdtemp())
        accepted = fake_cookie('z')
        seen = []

        def on_cookie(cookie):
            seen.append(cookie)
            if cookie != accepted:
                raise cc.VaultError('not signed in yet')
            return {'displayName': 'Zulu', 'username': 'FarmZulu'}
        login = cc.BrowserLogin(data, browser, on_cookie, extra_args=['--headless=new'])
        try:
            login.start()
            deadline = __import__('time').time() + 40
            while login.state != 'waiting' and __import__('time').time() < deadline:
                __import__('time').sleep(0.2)
            self.assertEqual(login.state, 'waiting', login.message)
            port = int((login.profile / 'DevToolsActivePort').read_text().split()[0])
            info = json.loads(__import__('urllib.request').request.urlopen(f'http://127.0.0.1:{port}/json/version', timeout=5).read())
            ws = cc._WebSocket(info['webSocketDebuggerUrl'])
            try:
                for value in (fake_cookie('w'), accepted):  # A rejected cookie first, then the real sign-in.
                    ws.call('Storage.setCookies', {'cookies': [{'name': '.ROBLOSECURITY', 'value': value, 'domain': '.roblox.com', 'path': '/', 'secure': True, 'httpOnly': True}]})
                    __import__('time').sleep(2.5)
            finally:
                ws.close()
            deadline = __import__('time').time() + 30
            while login.state == 'waiting' and __import__('time').time() < deadline:
                __import__('time').sleep(0.2)
            self.assertEqual(login.state, 'success', login.message)
            self.assertEqual(seen[-1], accepted)
            self.assertIn(fake_cookie('w'), seen)
            deadline = __import__('time').time() + 20
            while login.profile.exists() and __import__('time').time() < deadline:
                __import__('time').sleep(0.2)
            self.assertFalse(login.profile.exists(), 'throwaway browser profile deleted')
            self.assertIsNotNone(login.proc.poll(), 'sign-in window closed')
            self.assertNotIn('WARNING', json.dumps(login.snapshot()))
        finally:
            login.cancel()
            if login.proc and login.proc.poll() is None:
                login.proc.kill()
            shutil.rmtree(data, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
