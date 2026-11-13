"""Exercise the page's desktop-window code in Node, with a small fake browser API.

The desktop window's title bar is native (the host answers WM_NCHITTEST), so the page
must never start a move, resize or window command itself: it only finds its host and
reports its theme colours."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP_JS = ROOT / 'src/saver/control-center/03-app.js'


def desktop_section():
    source = APP_JS.read_text(encoding='utf-8-sig')
    start = source.index('// ---------- desktop window ----------')
    return source[start:source.index('// ---------- themes', start)]


class DesktopWindowPageTests(unittest.TestCase):
    def run_page(self, query, scenario):
        if not shutil.which('node'):
            self.skipTest('Node.js is needed for the page code')
        harness = r"""
const assert = require('node:assert/strict');
const TOKEN = 'fixture-token';
const params = new URLSearchParams(QUERY);
const calls = [], timers = [], listeners = {};
const document = {title: 'Arkuzo Memory Saver', documentElement: {}};
const window = {addEventListener: (k, f) => {listeners[k] = f;}};
const setTimeout = f => {timers.push(f);};
const vars = {'side-top': ' #101218', 'bg-top': '#16181F ', 'side-bottom': '#0a0b0f', text: '#eef1f6', muted: '#7e879a',
  'surface-hover': '#2a2f3d', 'surface-2': '#232733'};
const getComputedStyle = () => ({getPropertyValue: name => vars[name.slice(2)] || ''});
let nativeState = {attached: true, maximized: false};
const fetch = async (url, options) => {assert.equal(options.headers['X-Arkuzo-Token'], TOKEN); calls.push({get: url}); return {ok: true, json: async () => nativeState};};
const post = async (url, body) => {calls.push({post: url, body}); return {attached: true};};
const settle = () => new Promise(resolve => setImmediate(resolve));
""".replace('QUERY', json.dumps(query))
        script = harness + desktop_section() + '\n(async () => {\n' + scenario + '\n})().catch(e => {console.error(e); process.exitCode = 1;});'
        result = subprocess.run(['node', '-e', script], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_browser_tab_is_left_alone(self):
        self.run_page('', """
await initDesktopWindow(); await settle();
sendDesktopTheme(); await settle();
assert.equal(calls.length, 0);
assert.equal(document.title, 'Arkuzo Memory Saver');
""")

    def test_malformed_key_is_ignored(self):
        self.run_page('desktop=../../etc', """
await initDesktopWindow(); await settle();
assert.equal(calls.length, 0);
assert.equal(document.title, 'Arkuzo Memory Saver');
""")

    def test_attached_window_reports_only_its_theme(self):
        self.run_page('desktop=' + 'a' * 32, """
const running = initDesktopWindow();
assert.equal(document.title, 'Arkuzo Memory Saver · ' + 'a'.repeat(32));  // how the host finds this window
await running; await settle();
assert.equal(document.title, 'Arkuzo Memory Saver');
const posts = calls.filter(c => c.post);
assert.equal(posts.length, 1);
assert.equal(posts[0].post, '/api/desktop-window');
assert.deepEqual(posts[0].body, {key: 'a'.repeat(32), action: 'theme', colors: {
  bar: '#101218', barEnd: '#16181f', line: '#0a0b0f', text: '#eef1f6', muted: '#7e879a',
  hover: '#2a2f3d', pressed: '#232733', closeHover: '#c42b1c'}});
for (const value of Object.values(posts[0].body.colors)) assert.match(value, /^#[0-9a-f]{6}$/);
vars['side-top'] = '#edf0f5';
sendDesktopTheme(); await settle();
assert.equal(calls.filter(c => c.post).at(-1).body.colors.bar, '#edf0f5');
""")

    def test_unattached_window_waits_then_stops_on_pagehide(self):
        self.run_page('desktop=' + 'c' * 32, """
nativeState = {attached: false};
const running = initDesktopWindow(); await settle(); await settle();
assert.equal(timers.length, 1);
sendDesktopTheme(); await settle();
assert.equal(calls.filter(c => c.post).length, 0);  // nothing to colour until the host attached
listeners.pagehide();
timers.shift()(); await running; await settle();
assert.equal(document.title, 'Arkuzo Memory Saver');
assert.equal(calls.filter(c => c.post).length, 0);
""")

    def test_theme_changes_reach_the_host(self):
        source = APP_JS.read_text(encoding='utf-8-sig')
        body = source[source.index('function applyTheme(id) {'):]
        body = body[:body.index('\n}\n')]
        self.assertIn('sendDesktopTheme();', body)
        self.assertEqual(source.count('initDesktopWindow();'), 1)

    def test_page_never_moves_or_sizes_the_window(self):
        # Windows handles caption, buttons and edges natively; none of it may go over HTTP.
        source = APP_JS.read_text(encoding='utf-8-sig')
        self.assertIsNone(re.search(r"action: *'(drag|minimize|maximize|close|resize[\w-]*)'", source))
        self.assertNotIn('initDesktopChrome', source)
        for name in ('02-body.html', '01-styles.css'):
            markup = (ROOT / 'src/saver/control-center' / name).read_text(encoding='utf-8-sig')
            self.assertNotIn('data-window-resize', markup)
            self.assertNotIn('desktop-chrome', markup)
            self.assertNotIn('desktopCaption', markup)


if __name__ == '__main__':
    unittest.main()
