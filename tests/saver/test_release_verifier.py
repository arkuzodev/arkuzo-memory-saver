"""The release acceptance checks must remain active under Python optimization."""
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'build' / 'verify-release.py'

class ReleaseVerifierTests(unittest.TestCase):
    def test_failed_acceptance_check_is_enforced_with_optimization(self):
        code = 'import runpy; m=runpy.run_path(' + repr(str(SCRIPT)) + "); m['require'](False, 'verification-check')"
        result = subprocess.run([sys.executable, '-O', '-c', code], capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('RuntimeError: verification-check', result.stderr)

if __name__ == '__main__':
    unittest.main()
