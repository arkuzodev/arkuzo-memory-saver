"""The release version lives in one place, the VERSION file; everything else takes it from there.

build/bundle.ps1 stamps it into the engine, src/launcher/Directory.Build.props into the
launcher, and build/package.ps1 and build/verify-release.py read it. These checks fail
when a copy has its own number again.
"""
from pathlib import Path
import re
import runpy
import unittest

ROOT = Path(__file__).resolve().parents[2]
VERSION = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()


def read(relative):
    return (ROOT / relative).read_text(encoding='utf-8-sig')


class VersionTests(unittest.TestCase):
    def test_version_file_is_a_plain_semantic_version(self):
        self.assertRegex(VERSION, r'^\d+\.\d+\.\d+$')

    def test_engine_is_stamped_from_version(self):
        engine = read('src/saver/Arkuzo-Memory-Saver.ps1')
        stamped = re.findall(r"^\$ArkuzoRuntimeVersion\s*=\s*'([^']*)'", engine, re.M)
        self.assertEqual(stamped, [VERSION], 'run build/bundle.ps1 after changing VERSION')
        header = read('src/saver/engine/00-header.ps1')
        self.assertIn("$ArkuzoRuntimeVersion = '__ARKUZO_VERSION__'", header, 'the module carries the token, not a number')

    def test_launcher_takes_version_from_the_file(self):
        props = read('src/launcher/Directory.Build.props')
        self.assertIn("../../VERSION", props)
        self.assertIn('<Version>$(ArkuzoVersion)</Version>', props)
        build = read('build/launcher-build.ps1')
        self.assertNotRegex(build, r'-p:(Assembly|File)?Version=', 'launcher-build.ps1 must not pass its own version')
        update = read('src/launcher/Core/Update.cs')
        self.assertNotRegex(update, r'Launcher/\d', 'the user agent takes the assembly version')

    def test_build_scripts_read_the_file(self):
        verifier = runpy.run_path(str(ROOT / 'build' / 'verify-release.py'))
        self.assertEqual(verifier['VERSION'], 'v' + VERSION)
        package = read('build/package.ps1')
        self.assertNotRegex(package, r"\$Version\s*=\s*'v\d", 'package.ps1 has no default version of its own')
        self.assertIn("'VERSION'", package)

    def test_no_stray_version_numbers_in_sources(self):
        # Old numbers that used to linger in comments and defaults.
        for relative in ('build/package.ps1', 'build/launcher-build.ps1', 'src/launcher/Core/Update.cs'):
            self.assertNotIn('1.0.2', read(relative), relative)

    def test_readme_badge_matches(self):
        badge = re.search(r'badge/version-(\d+\.\d+\.\d+)-', read('README.md'))
        self.assertIsNotNone(badge)
        self.assertEqual(badge.group(1), VERSION, 'update the README badge with VERSION')


if __name__ == '__main__':
    unittest.main()
