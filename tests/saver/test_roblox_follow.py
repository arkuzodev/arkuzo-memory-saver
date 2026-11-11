"""The Roblox tab's follow modes, one-click switching and the roblox-player: protocol
(docs/roblox-versions.md): following an exploit or Roblox's newest build installs the build from the
(fake) CDN and pins it, a new build is picked up at the next check, a build chosen by hand ends
following, "apply now" closes the farm's clients once, and the protocol keys are saved, pointed at
the pin and restored exactly. Registry code runs only against HKCU\\Software\\ArkuzoTest\\..., never
Roblox's own keys; fake weao.gg / Roblox / CDN servers run on ephemeral ports."""
import json
import os
import shutil
import tempfile
import time
import unittest
import uuid
from pathlib import Path

from test_roblox_versions import V1, V2, WebTestCase, cc, exploit

WINDOWS = os.name == 'nt'


def real_protocol():
    return {s: cc.protocol_snapshot(cc.PROTOCOL_BASE, s) for s in cc.PROTOCOL_SCHEMES} if WINDOWS else None


def wait_for(check, seconds=30):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if check():
            return True
        time.sleep(0.05)
    return False


class FollowRuleTests(unittest.TestCase):
    def test_follow_setting_validates(self):
        for good in ('', None, 'latest', 'exploit:662ae7576238b7f2082f253b'):
            self.assertEqual(cc.validate_follow(good), good or '')
        for bad in ('newest', 'exploit:', 'exploit:../x', 'exploit:a b', 5, ['latest'], 'exploit:' + 'a' * 65):
            with self.assertRaises(cc.VaultError, msg=repr(bad)):
                cc.validate_follow(bad)
        self.assertEqual(cc.VAULT_SETTINGS['robloxVersionFollow'][1], '')
        self.assertIs(cc.VAULT_SETTINGS['robloxProtocol'][1], False)

    def test_follow_target(self):
        catalog = {'roblox': {'version': V1}, 'weao': {}, 'exploits': cc.parse_weao_exploits(
            [exploit('v', 'Volt', V2), exploit('m', 'MacOne', V2, platform='Mac'), exploit('h', 'Gone', V2, hidden=True)])}
        self.assertEqual(cc.follow_target(catalog, 'latest')['version'], V1)
        self.assertEqual(cc.follow_target(catalog, 'exploit:v')['version'], V2)
        for ident, why in (('m', 'Not a Windows'), ('h', 'No longer listed'), ('zz', 'no longer listed')):
            target = cc.follow_target(catalog, 'exploit:' + ident)
            self.assertIsNone(target['version'], ident)
            self.assertIn(why, target['reason'], ident)
        self.assertIn('not answered', cc.follow_target(None, 'latest')['reason'])


class FollowTests(WebTestCase):
    def setUp(self):
        super().setUp()
        self.data = Path(tempfile.mkdtemp())
        cc.update_vault_settings(self.data, {'robloxVersionsDir': str(self.root)})
        self.manager = cc.RobloxVersions(self.data)
        self.manager.protocol_base = r'Software\ArkuzoTest' + '\\' + uuid.uuid4().hex + r'\Classes'
        self.closed = []
        self.manager.on_switch = lambda: self.closed.append(time.time()) or 3
        self.publish_build(V1)
        self.publish_build(V2)
        self.weao(volt=V2)

    def tearDown(self):
        self.manager.stop_event.set()
        if self.manager.thread is not None:
            self.manager.thread.join(30)
        shutil.rmtree(self.data, ignore_errors=True)
        super().tearDown()

    def weao(self, volt):
        self.web.routes['/weao/versions/current'] = (200, json.dumps({'Windows': V1}).encode())
        self.web.routes['/weao/versions/past'] = (200, json.dumps({'Windows': V2}).encode())
        self.web.routes['/weao/versions/future'] = (200, b'{}')
        self.web.routes['/weao/status/exploits'] = (200, json.dumps([exploit('v', 'Volt', volt), exploit('x', 'Xeno', V1)]).encode())
        self.web.routes['/roblox/client-version'] = (200, json.dumps({'version': '0.747.0.7471481', 'clientVersionUpload': V1}).encode())

    def pin(self):
        return cc.load_vault(self.data)['settings']['robloxVersion']

    def test_follow_an_exploit_installs_pins_and_moves_with_it(self):
        result = self.manager.set_mode('exploit:v', restart=True)
        self.assertEqual(result['previous'], {'version': 'auto', 'follow': ''})
        self.assertTrue(wait_for(lambda: self.pin() == V2), self.manager.follow_state)
        self.assertTrue((self.root / 'Versions' / V2 / 'AppSettings.xml').is_file(), 'installed from the CDN into Arkuzo\'s folder')
        self.assertEqual(cc.load_vault(self.data)['settings']['robloxVersionFollow'], 'exploit:v', 'still following')
        self.assertEqual(len(self.closed), 1, 'restart on: the clients relaunch on the new build')
        self.assertTrue(wait_for(lambda: self.manager.follow_state.get('state') == 'pinned'))
        # The exploit is updated for Roblox's current build: the next check installs and pins it.
        self.weao(volt=V1)
        self.manager.catalog_at = 0
        self.manager.follow_tick(network=True)
        self.assertTrue(wait_for(lambda: self.pin() == V1), self.manager.follow_state)
        self.assertEqual(len(self.closed), 2)
        # A check with nothing new changes nothing and closes nothing.
        self.manager.follow_tick(network=False)
        self.assertEqual((self.pin(), len(self.closed)), (V1, 2))
        view = self.manager.view(cached_only=True)
        self.assertEqual((view['selection']['follow'], view['follow']['wanted'], view['follow']['label']), ('exploit:v', V1, 'Volt'))

    def test_newest_follows_roblox_and_a_hand_pick_ends_following(self):
        self.manager.set_mode('latest')
        self.assertTrue(wait_for(lambda: self.pin() == V1), self.manager.follow_state)
        self.assertEqual(self.closed, [], 'apply as clients relaunch: nothing is closed')
        self.manager.start_install(V2)
        self.manager.thread.join(30)
        self.assertEqual(self.pin(), V1, 'installing another build while following does not switch')
        result = self.manager.set_mode('pinned', V2, apply='now')
        self.assertEqual(result['previous'], {'version': V1, 'follow': 'latest'})
        self.assertEqual((self.pin(), cc.load_vault(self.data)['settings']['robloxVersionFollow'], len(self.closed)), (V2, '', 1))
        # Undo puts the previous choice back.
        self.manager.set_mode(result['previous']['follow'])
        self.assertTrue(wait_for(lambda: self.pin() == V1))
        self.assertEqual(self.manager.set_mode('auto')['version'], 'auto')
        self.assertEqual(len(self.closed), 1, 'apply now only when asked')
        with self.assertRaises(cc.VaultError):
            self.manager.set_mode('pinned', 'version-0000000000000000')
        with self.assertRaises(cc.VaultError):
            self.manager.set_mode('everything')

    def test_an_unusable_source_never_changes_the_pin(self):
        self.manager.start_install(V2)
        self.manager.thread.join(30)
        self.manager.select(V2)
        self.web.routes['/weao/status/exploits'] = (200, json.dumps([exploit('v', 'Volt', 'version-nothexnothexnoth')]).encode())
        cc.update_vault_settings(self.data, {'robloxVersionFollow': 'exploit:v'})
        state = self.manager.follow_tick(network=True)
        self.assertEqual((state['state'], self.pin()), ('waiting', V2))
        self.assertIn('valid Roblox build', state['message'])
        cc.update_vault_settings(self.data, {'robloxVersionFollow': 'exploit:gone'})
        self.assertIn('no longer listed', self.manager.follow_tick(network=False)['message'])
        self.assertEqual(self.pin(), V2)

    def test_checks_respect_weaos_limits(self):
        cc.update_vault_settings(self.data, {'robloxVersionFollow': 'exploit:x'})
        for _ in range(5):
            self.manager.follow_tick(network=True)
        hits = [p for p, _ in self.web.seen if p == '/weao/status/exploits']
        self.assertEqual(len(hits), 1, 'checks in quick succession share one fetch')
        self.assertGreaterEqual(cc.ROBLOX_FOLLOW_SEC, 300)


@unittest.skipUnless(WINDOWS, 'Windows registry')
class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.base = r'Software\ArkuzoTest' + '\\' + uuid.uuid4().hex + r'\Classes'
        self.data = Path(tempfile.mkdtemp())
        self.real_before = real_protocol()
        import winreg
        self.winreg = winreg
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, self.base + r'\roblox-player') as k:
            winreg.SetValueEx(k, '', 0, winreg.REG_SZ, 'URL: Roblox Protocol')
            winreg.SetValueEx(k, 'URL Protocol', 0, winreg.REG_SZ, '')
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, self.base + r'\roblox-player\shell\open\command') as k:
            winreg.SetValueEx(k, '', 0, winreg.REG_SZ, '"C:\\Gutted\\version-f0ea5da9412f4e35\\RobloxPlayerBeta.exe" %1')
            winreg.SetValueEx(k, 'version', 0, winreg.REG_SZ, 'version-f0ea5da9412f4e35')
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, self.base + r'\roblox-player\DefaultIcon') as k:
            winreg.SetValueEx(k, '', 0, winreg.REG_SZ, 'C:\\Gutted\\RobloxPlayerBeta.exe')
        self.original = {s: cc.protocol_snapshot(self.base, s) for s in cc.PROTOCOL_SCHEMES}

    def tearDown(self):
        top = self.base.rsplit('\\', 1)[0]
        cc._protocol_delete(top.rsplit('\\', 1)[0], top.rsplit('\\', 1)[1])
        shutil.rmtree(self.data, ignore_errors=True)
        self.assertEqual(real_protocol(), self.real_before, 'Roblox\'s real protocol keys were never touched')

    def test_apply_backs_up_and_restore_is_exact(self):
        self.assertFalse(self.original['roblox']['exists'])
        exe_a = 'C:\\Arkuzo\\Versions\\' + V1 + '\\RobloxPlayerBeta.exe'
        exe_b = 'C:\\Arkuzo\\Versions\\' + V2 + '\\RobloxPlayerBeta.exe'
        state = cc.protocol_apply(self.data, exe_a, self.base)
        self.assertEqual(state, {'exe': exe_a, 'managed': True})
        for scheme in cc.PROTOCOL_SCHEMES:
            keys = cc.protocol_snapshot(self.base, scheme)['keys']
            self.assertEqual(keys['shell\\open\\command'][''][1], f'"{exe_a}" %1')
        saved = json.loads((self.data / cc.PROTOCOL_BACKUP).read_text(encoding='utf-8'))
        self.assertEqual(saved['schemes'], json.loads(json.dumps(self.original)))
        cc.protocol_apply(self.data, exe_b, self.base)
        again = json.loads((self.data / cc.PROTOCOL_BACKUP).read_text(encoding='utf-8'))
        self.assertEqual(again['schemes'], saved['schemes'], 're-pointing keeps the original copy')
        self.assertTrue(cc.protocol_restore(self.data, self.base))
        self.assertEqual({s: cc.protocol_snapshot(self.base, s) for s in cc.PROTOCOL_SCHEMES}, self.original)
        self.assertFalse((self.data / cc.PROTOCOL_BACKUP).exists())
        self.assertFalse(cc.protocol_restore(self.data, self.base), 'nothing left to restore')

    def test_roblox_rewriting_the_keys_replaces_the_copy_and_restore_leaves_others_alone(self):
        exe = 'C:\\Arkuzo\\Versions\\' + V1 + '\\RobloxPlayerBeta.exe'
        cc.protocol_apply(self.data, exe, self.base)
        winreg = self.winreg
        # Roblox's installer writes its own keys again (without Arkuzo's mark).
        for scheme in cc.PROTOCOL_SCHEMES:
            cc._protocol_delete(self.base, scheme)
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, self.base + '\\' + scheme + r'\shell\open\command') as k:
                winreg.SetValueEx(k, '', 0, winreg.REG_SZ, '"C:\\Roblox\\version-new\\RobloxPlayerBeta.exe" %1')
        rewritten = {s: cc.protocol_snapshot(self.base, s) for s in cc.PROTOCOL_SCHEMES}
        self.assertFalse(cc.protocol_state(self.base)['managed'])
        cc.protocol_restore(self.data, self.base)
        self.assertEqual({s: cc.protocol_snapshot(self.base, s) for s in cc.PROTOCOL_SCHEMES}, rewritten, 'keys that are not Arkuzo\'s are never overwritten')
        cc.protocol_apply(self.data, exe, self.base)
        saved = json.loads((self.data / cc.PROTOCOL_BACKUP).read_text(encoding='utf-8'))
        self.assertEqual(saved['schemes'], json.loads(json.dumps(rewritten)), 'the copy is Roblox\'s newest keys')
        cc.protocol_restore(self.data, self.base)
        self.assertEqual({s: cc.protocol_snapshot(self.base, s) for s in cc.PROTOCOL_SCHEMES}, rewritten)

    def test_bad_paths_are_refused(self):
        for bad in ('C:\\x\\RobloxPlayerBeta.exe" --evil "', 'C:\\x\\calc.exe', 'relative\\RobloxPlayerBeta.exe', '\\\\server\\share\\RobloxPlayerBeta.exe'):
            with self.assertRaises(cc.VaultError, msg=bad):
                cc.protocol_apply(self.data, bad, self.base)
        self.assertEqual({s: cc.protocol_snapshot(self.base, s) for s in cc.PROTOCOL_SCHEMES}, self.original)

    def test_manager_follows_the_pin_and_restores_on_auto_or_off(self):
        root = Path(tempfile.mkdtemp())
        try:
            for version in (V1, V2):
                build = root / 'Versions' / version
                build.mkdir(parents=True)
                (build / 'RobloxPlayerBeta.exe').write_bytes(b'MZ')
                (build / 'AppSettings.xml').write_text('x')
            cc.update_vault_settings(self.data, {'robloxVersionsDir': str(root)})
            manager = cc.RobloxVersions(self.data)
            manager.protocol_base = self.base
            manager.select(V1)
            self.assertFalse(cc.protocol_state(self.base)['managed'], 'off by default')
            state = manager.set_protocol(True)
            self.assertEqual(os.path.normcase(state['exe']), os.path.normcase(str(root / 'Versions' / V1 / 'RobloxPlayerBeta.exe')))
            manager.select(V2)
            self.assertIn(V2, cc.protocol_state(self.base)['exe'], 'switching the pin re-points the links')
            manager.select('auto')
            self.assertEqual({s: cc.protocol_snapshot(self.base, s) for s in cc.PROTOCOL_SCHEMES}, self.original, 'Auto restores')
            manager.select(V2)
            self.assertTrue(cc.protocol_state(self.base)['managed'], 'still on: the next pin points the links again')
            manager.set_protocol(False)
            self.assertEqual({s: cc.protocol_snapshot(self.base, s) for s in cc.PROTOCOL_SCHEMES}, self.original, 'off restores')
            view = manager.view(cached_only=True)
            self.assertEqual((view['protocol']['enabled'], view['protocol']['saved']), (False, False))
            with self.assertRaises(cc.VaultError):
                manager.set_protocol('yes')
        finally:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
