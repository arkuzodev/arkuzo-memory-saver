"""Real, read-only PowerShell startup checks for persistent user data."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'src' / 'saver' / 'Arkuzo-Memory-Saver.ps1'

class DataDirectoryTests(unittest.TestCase):
    def test_invalid_existing_config_is_rejected_without_replacing_it(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as temp:
            data = Path(temp)
            config = data / 'config.json'
            original = b'{not valid json'
            config.write_bytes(original)
            result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(SCRIPT), '-DataDirectory', str(data), '-MonitorOnly', '-Headless', '-RunForSec', '1'], capture_output=True, text=True, errors='replace', timeout=30)
            self.assertNotEqual(result.returncode, 0, 'Malformed existing config must not silently use defaults')
            self.assertEqual(config.read_bytes(), original)

    def test_config_and_logs_are_outside_versioned_runtime(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as temp:
            base = Path(temp)
            data = base / 'User data ü'
            data.mkdir()
            config = data / 'config.json'
            original = (ROOT / 'config' / 'defaults.json').read_bytes() + b'\n '
            config.write_bytes(original)
            other_profile = base / 'Other Profile'
            other_profile.mkdir()
            result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(SCRIPT), '-DataDirectory', str(data), '-MonitorOnly', '-Headless', '-RunForSec', '3'], env=dict(os.environ, LOCALAPPDATA=str(other_profile)), capture_output=True, text=True, errors='replace', timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(config.read_bytes(), original, 'Config must be byte-preserved')
            logs = list((data / 'Arkuzo-Logs').glob('*.log'))
            self.assertTrue(logs, 'Logs must stay in persistent data directory')
            rows = [json.loads(line) for p in logs for line in p.read_text(encoding='utf-8-sig').splitlines()]
            self.assertTrue(any(x['event'] == 'SESSION_STOP' for x in rows))
            self.assertFalse(any(x['event'] in ('SAVER_FATAL_ERROR', 'RECOVERY_REQUESTED', 'WORKING_SET_TRIM') for x in rows))
            self.assertFalse((SCRIPT.parent / 'config.json').exists())
            self.assertFalse((other_profile / 'Volt' / 'state.db').exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
