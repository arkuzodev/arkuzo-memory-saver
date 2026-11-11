"""The page's window layout preview against the shared golden vectors.

contracts/window-layout.json holds inputs and expected slots; WindowLayout.Tests.ps1
checks the engine's Get-ArkuzoWindowSlots with the same file. Here the page's own
layoutSlots / slotsOverlap are cut out of the shipped Arkuzo-Control-Center.html and run
with Node.js, so the preview cannot drift from what the engine does.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PAGE = ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.html'
VECTORS = ROOT / 'contracts' / 'window-layout.json'


def cut_function(script, name):
    """The source of `function name(...) { ... }`, by brace matching."""
    start = script.index('function ' + name + '(')
    depth = 0
    for i in range(script.index('{', start), len(script)):
        if script[i] == '{':
            depth += 1
        elif script[i] == '}':
            depth -= 1
            if depth == 0:
                return script[start:i + 1]
    raise ValueError(name + ' is not closed')


class WindowLayoutVectorTests(unittest.TestCase):
    def test_vectors_are_well_formed(self):
        cases = json.loads(VECTORS.read_text(encoding='utf-8'))['cases']
        self.assertGreaterEqual(len(cases), 10)
        for case in cases:
            self.assertEqual(len(case['expected']), case['count'], case['name'])
            for x, y, w, h in case['expected']:
                self.assertTrue(0 <= x and 0 <= y and x + w <= case['screen'][0] and y + h <= case['screen'][1], case['name'] + ': every window stays on screen')
                self.assertTrue(w >= 800 and h >= 622, case['name'] + ': never below the Roblox minimum')

    def test_page_preview_matches_the_vectors(self):
        node = shutil.which('node')
        if not node:
            self.skipTest('Node.js not installed')
        html = PAGE.read_text(encoding='utf-8')
        script = html[html.rindex('<script>') + 8:html.rindex('</script>')]
        constant = re.search(r'^const ROBLOX_MIN_W = \d+, ROBLOX_MIN_H = \d+;$', script, re.M)
        self.assertIsNotNone(constant, 'the page defines the Roblox minimum window')
        program = '\n'.join([
            constant.group(0), cut_function(script, 'layoutSlots'), cut_function(script, 'slotsOverlap'),
            'const cases = ' + VECTORS.read_text(encoding='utf-8') + '.cases;',
            'const out = cases.map((c) => { const s = layoutSlots(c.count, c.settings, c.screen[0], c.screen[1]); return { name: c.name, slots: s, overlap: slotsOverlap(s) }; });',
            'process.stdout.write(JSON.stringify(out));',
        ])
        folder = Path(tempfile.mkdtemp())
        try:
            (folder / 'layout.js').write_text(program, encoding='utf-8')
            result = subprocess.run([node, str(folder / 'layout.js')], capture_output=True, text=True, timeout=60)
        finally:
            shutil.rmtree(folder)
        self.assertEqual(result.returncode, 0, result.stderr[:500])
        cases = json.loads(VECTORS.read_text(encoding='utf-8'))['cases']
        for case, got in zip(cases, json.loads(result.stdout), strict=True):
            self.assertEqual(got['slots'], case['expected'], case['name'])
            self.assertEqual(got['overlap'], case['overlap'], case['name'] + ': overlap')


if __name__ == '__main__':
    unittest.main()
