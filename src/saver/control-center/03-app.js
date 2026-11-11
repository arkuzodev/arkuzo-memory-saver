'use strict';
const TOKEN = '__ARKUZO_TOKEN__';
const $ = (id) => document.getElementById(id);

// ---------- vector icons: the Arkuzo Client's own VectorIcons path set ----------
const ICON_SPECS = {
  search: 'c 11 11 7; p M20.5 20.5 L16 16', x: 'p M18 6 L6 18; p M6 6 L18 18', check: 'p M20 6 L9 17 L4 12', plus: 'p M12 5 V19; p M5 12 H19',
  trash: 'p M4 7 H20; p M9 7 V4.5 H15 V7; f M6 7 L7 20 H17 L18 7', pencil: 'f M4 20 L5 15.5 L15.5 5 Q17 3.5 18.5 5 L19 5.5 Q20.5 7 19 8.5 L8.5 19 Z; p M13.5 7 L17 10.5',
  refresh: 'a 12 12 8 30 300; p M20 4 V9 H15',
  'chevron-right': 'p M9 6 L15 12 L9 18', play: 'f M7 4.5 L19 12 L7 19.5 Z', power: 'a 12 13 8 120 300; p M12 3 V11',
  enter: 'p M9 10 L4 15 L9 20; p M20 4 V11 Q20 15 16 15 H4', info: 'c 12 12 10; p M12 16 V11.5; d 12 8',
  warning: 'f M10.3 3.9 L1.9 18 Q1.2 20.5 3.8 20.5 H20.2 Q22.8 20.5 22.1 18 L13.7 3.9 Q12 1.4 10.3 3.9 Z; p M12 9 V13; d 12 16.8',
  sparkles: 'f M12 3 L13.8 9.2 L20 11 L13.8 12.8 L12 19 L10.2 12.8 L4 11 L10.2 9.2 Z; p M19 3 V7; p M17 5 H21',
  palette: 'c 12 12 9.5; cs 8 9.5 1.4; cs 12 7 1.4; cs 16 9.5 1.4; cs 9 14.5 1.4', performance: 'p M22 12 H18 L15 21 L9 3 L6 12 H2',
  hud: 'r 2 3 20 14 2.5; p M8 21 H16; p M12 17 V21; p M6 7 H10; p M6 10 H8.5',
  friends: 'cf 9 7 4; p M2 21 V19 C2 16.8 3.8 15 6 15 H12 C14.2 15 16 16.8 16 19 V21; p M16 3.2 C17.7 3.7 19 5.2 19 7 C19 8.8 17.7 10.3 16 10.8; p M22 21 V19 C22 17.2 20.8 15.6 19 15.2',
  'status-overlay': 'p M4 6 H16; p M4 12 H20; p M4 18 H11; d 20 6; d 15 18',
  interface: 'p M4 21 V14; p M4 10 V3; p M12 21 V12; p M12 8 V3; p M20 21 V16; p M20 12 V3; p M1.5 14 H6.5; p M9.5 8 H14.5; p M17.5 16 H22.5',
  'auto-tool': 'p M3 21 L15.5 8.5; p M8 4 Q19 5 20 16', 'perf-monitor': 'rf 2 3 20 14 2.5; p M5 11 H8 L10 7.5 L13 13.5 L15 10 H19; p M8 21 H16; p M12 17 V21',
  containers: 'rf 3 6 18 14 2.5; p M3 11 H21; p M8 6 V3.5 H16 V6; r 10 9 4 4.5 1; c 18.5 17.5 2.2; p M20.2 19.2 L21.8 20.8',
  'coordinate-leak-protection': 'f M12 22 C12 22 20 18 20 12 V5 L12 2 L4 5 V12 C4 18 12 22 12 22 Z; p M9 12 L11 14 L15 10',
  'fast-break': 'f M13 2 L3 14 H12 L11 22 L21 10 H12 Z', gear: 'c 12 12 3; c 12 12 7; p M12 2 V5; p M12 19 V22; p M2 12 H5; p M19 12 H22; p M4.9 4.9 L7 7; p M17 17 L19.1 19.1; p M4.9 19.1 L7 17; p M17 7 L19.1 4.9',
  profiles: 'f M12 2 L22 7 L12 12 L2 7 Z; p M2 17 L12 22 L22 17; p M2 12 L12 17 L22 12',
  'death-coordinates': 'f M12 2 C7 2 4 5.5 4 10 C4 12.5 5 14.4 6.5 15.6 V19 Q6.5 21 8.5 21 H15.5 Q17.5 21 17.5 19 V15.6 C19 14.4 20 12.5 20 10 C20 5.5 17 2 12 2 Z; cs 9 11 1.7; cs 15 11 1.7; p M10 21 V18; p M14 21 V18',
};
function iconSvg(name) {
  const spec = ICON_SPECS[name]; if (!spec) return '';
  const pt = (cx, cy, r, deg) => [cx + r * Math.cos(deg * Math.PI / 180), cy - r * Math.sin(deg * Math.PI / 180)];
  let out = '';
  for (const part of spec.split(';')) {
    const tok = part.trim().split(/[\s,]+/), k = tok[0], n = tok.slice(1).map(Number), d = tok.slice(1).join(' ');
    if (k === 'p') out += `<path d="${d}"/>`;
    else if (k === 'f') out += `<path d="${d}" fill="currentColor" fill-opacity=".22"/>`;
    else if (k === 's') out += `<path d="${d}" fill="currentColor" stroke="none"/>`;
    else if (k === 'c') out += `<circle cx="${n[0]}" cy="${n[1]}" r="${n[2]}"/>`;
    else if (k === 'cf') out += `<circle cx="${n[0]}" cy="${n[1]}" r="${n[2]}" fill="currentColor" fill-opacity=".22"/>`;
    else if (k === 'cs') out += `<circle cx="${n[0]}" cy="${n[1]}" r="${n[2]}" fill="currentColor" stroke="none"/>`;
    else if (k === 'r') out += `<rect x="${n[0]}" y="${n[1]}" width="${n[2]}" height="${n[3]}" rx="${n[4] || 0}"/>`;
    else if (k === 'rf') out += `<rect x="${n[0]}" y="${n[1]}" width="${n[2]}" height="${n[3]}" rx="${n[4] || 0}" fill="currentColor" fill-opacity=".22"/>`;
    else if (k === 'd') out += `<circle cx="${n[0]}" cy="${n[1]}" r="1.25" fill="currentColor" stroke="none"/>`;
    else if (k === 'a') { const [cx, cy, r, a0, sw] = n, [x0, y0] = pt(cx, cy, r, a0), [x1, y1] = pt(cx, cy, r, a0 + sw);
      out += `<path d="M${x0.toFixed(2)} ${y0.toFixed(2)} A${r} ${r} 0 ${Math.abs(sw) > 180 ? 1 : 0} 0 ${x1.toFixed(2)} ${y1.toFixed(2)}"/>`; }
  }
  return `<svg class="i" viewBox="0 0 24 24" aria-hidden="true">${out}</svg>`;
}
function icon(name) { const t = document.createElement('template'); t.innerHTML = iconSvg(name); return t.content.firstChild || document.createTextNode(''); }
document.querySelectorAll('[data-icon]').forEach((n) => { const svg = icon(n.dataset.icon); if (n.classList.contains('ck')) n.append(svg); else n.replaceWith(svg); });
const LEVEL = { good: ['#34d399', 'check'], warning: ['#fbbf24', 'warning'], critical: ['#f87171', 'warning'], serious: ['#fb923c', 'warning'], info: ['var(--accent)', 'info'], neutral: ['#7e879a', 'info'] };

// ---------- helpers ----------
function el(tag, props, ...kids) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) if (kid != null) node.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  return node;
}
const fmtMB = (mb) => mb == null || isNaN(mb) ? '–' : (mb >= 1024 ? (mb / 1024).toFixed(mb >= 10240 ? 1 : 2) + ' GB' : Math.round(mb) + ' MB');
const fmtGBparts = (mb) => mb >= 1024 ? [(mb / 1024).toFixed(1), 'GB'] : [String(Math.round(mb || 0)), 'MB'];
const fmtPct = (v) => v == null || isNaN(v) ? '–' : (Math.round(v * 10) / 10).toFixed(v < 10 ? 1 : 0) + '%';
function fmtDur(sec) {
  if (sec == null || isNaN(sec)) return '–';
  sec = Math.max(0, Math.round(sec));
  const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : m ? `${m}m` : `${sec}s`;
}
const fmtTime = (t) => new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
const fmtClock = (t) => new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
const initials = (name) => (String(name || '?').replace(/[^\p{L}\p{N}]/gu, '').slice(0, 2) || '?').toUpperCase();
const store = { get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* unavailable */ } } };
const tile = (iconName, color, size) => el('span', { class: 'tile' + (size ? ' ' + size : ''), style: `--c:${color}` }, icon(iconName));
function pill(level, label, small) { const [c, ic] = LEVEL[level] || LEVEL.neutral; return el('span', { class: 'pill' + (small ? ' sm' : ''), style: `--c:${c}` }, icon(ic), label); }
function toast(text, level) {
  const [c, ic] = LEVEL[level || 'info'];
  const t = el('div', { class: 'toast' }, tile(ic, c, 'sm'), el('span', { text }));
  $('toasts').append(t);
  while ($('toasts').children.length > 4) $('toasts').firstChild.remove();
  setTimeout(() => { t.classList.add('out'); setTimeout(() => t.remove(), 260); }, 3200);
}
async function post(path, body) {
  const r = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Arkuzo-Token': TOKEN }, body: JSON.stringify(body || {}) });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || ('HTTP ' + r.status));
  return data;
}

// ---------- themes & accents (UiTheme.ALL, ArkuzoGuiConfig accents) ----------
const THEMES = {
  graphite: ['Graphite', 0, '16181f 0e1015 101218 0a0b0f 1a1d26 232733 2a2f3d 0b0d12 2c313e 1e222c 2a2f3b eef1f6 b8bfcc 7e879a 555d6f', 0xAA, 0x0A, 0x16],
  midnight: ['Midnight', 0, '151b30 0b1022 0f1528 080c1a 18203a 202a4a 283459 070a16 2d3a62 1c2542 26315a eaf0ff b6c1de 7a87ae 505c82', 0xB9, 0x0A, 0x18],
  obsidian: ['Obsidian', 0, '0d0d10 050506 09090b 030304 131316 1b1b1f 222227 000000 26262c 17171a 24242a f5f5f7 bcbcc4 7c7c87 4f4f58', 0xD2, 0x08, 0x12],
  nord: ['Nord', 0, '2f3541 262b35 272c36 1f232c 353c49 3d4454 454e60 1e222a 4c566a 3b4252 4c566a eceff4 d8dee9 9aa3b5 6b7487', 0x96, 0x08, 0x1A],
  ember: ['Ember', 0, '1d1715 120e0c 17110f 0d0a08 251d1a 2e2521 372c27 0b0807 3d302a 2a211d 392c26 f7efea cfbfb6 938177 655750', 0xB4, 0x0C, 0x16],
  forest: ['Forest', 0, '141b18 0c110f 101613 090d0b 19221e 202c27 283630 070a09 2c3a34 1d2823 283630 edf5f1 b7c9c0 7d9389 54685f', 0xAF, 0x0A, 0x16],
  plum: ['Plum', 0, '1e1622 130d17 18111c 0e0912 231a28 2c2132 35293c 0b070d 3b2e42 271e2c 372a3e f5eef8 cdbed4 927f9b 64546c', 0xB4, 0x0A, 0x16],
  frost: ['Frost', 1, 'fafbfd eef1f6 edf0f5 e2e7ef ffffff f4f6fa e9edf4 e4e8ef cdd3de e0e5ed cfd5e0 151922 3b4251 6a7282 9aa1af', 0x5A, 0x06, 0x3C],
};
const THEME_VARS = ['bg-top', 'bg-bottom', 'side-top', 'side-bottom', 'surface', 'surface-2', 'surface-hover', 'well', 'border', 'border-soft', 'track', 'text', 'text-2', 'muted', 'dim'];
const ACCENTS = { Cyan: '#38bdf8', Violet: '#a78bfa', Emerald: '#34d399', Rose: '#fb7185', Amber: '#fbbf24', Silver: '#cbd5e1', Indigo: '#818cf8', Teal: '#2dd4bf', Coral: '#fb923c', Lime: '#a3e635' };
function applyTheme(id) {
  if (!THEMES[id]) id = 'graphite';
  const [, light, cols, shadow, grain, sheen] = THEMES[id], root = document.documentElement.style;
  cols.split(' ').forEach((c, i) => root.setProperty('--' + THEME_VARS[i], '#' + c));
  root.setProperty('--ov', light ? '0, 0, 0' : '255, 255, 255');
  root.setProperty('--shadow-a', (shadow / 255).toFixed(3)); root.setProperty('--grain-a', (grain / 255).toFixed(3)); root.setProperty('--sheen-a', (sheen / 255 * (light ? 0.35 : 1)).toFixed(3));
  root.setProperty('--edge-a', light ? '0.08' : '0.33');
  root.setProperty('--s1', light ? '#2a78d6' : '#3987e5'); root.setProperty('--s2', light ? '#eb6834' : '#d95926');
  root.colorScheme = light ? 'light' : 'dark';
  document.body.classList.toggle('light', !!light);
  document.querySelectorAll('.th').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.id === id)));
  if (typeof redrawCharts === 'function' && S) redrawCharts();
}
function applyAccent(name) {
  if (!ACCENTS[name]) name = 'Cyan';
  const hex = ACCENTS[name], n = parseInt(hex.slice(1), 16), root = document.documentElement.style;
  root.setProperty('--accent', hex); root.setProperty('--a', `${n >> 16}, ${(n >> 8) & 255}, ${n & 255}`);
  document.querySelectorAll('.acc').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.name === name)));
}

// ---------- state & pages ----------
var S = { state: null, history: [], events: [], lastEvent: 0, seenEvents: 0, range: 900, filter: 'all', query: '', page: 'overview', live: true, selectedPid: null,
  config: null, presets: {}, schema: {}, restartKeys: [], edits: {} };
for (const [id, [name, , cols]] of Object.entries(THEMES)) {
  const c = cols.split(' ');
  $('themes').append(el('button', { type: 'button', class: 'th', 'data-id': id, onclick: () => { applyTheme(id); store.set('arkuzo-theme', id); } },
    el('div', { class: 'sw2', style: `background:linear-gradient(180deg,#${c[0]},#${c[1]});--sd:linear-gradient(180deg,#${c[2]},#${c[3]})` }), name));
}
for (const [name, hex] of Object.entries(ACCENTS)) {
  $('accents').append(el('button', { type: 'button', class: 'acc', 'data-name': name, title: name, 'aria-label': name + ' accent', style: `--c:${hex}`, onclick: () => { applyAccent(name); store.set('arkuzo-accent', name); } }, icon('check')));
}
const PAGES = {
  overview: ['Overview', 'Farm health at a glance'], clients: ['Clients', 'Every Roblox client the saver manages'],
  accounts: ['Accounts', 'Your Roblox accounts, farm start and relaunch'], activity: ['Activity', 'What the saver and autopilot did'], settings: ['Settings', 'Look, memory, CPU, health and recovery'],
  roblox: ['Roblox', 'Roblox builds, the build the saver launches, and which build your exploits support'],
};
function showPage(page) {
  if (!PAGES[page]) return;
  if (S.page === 'settings' && page !== 'settings') {
    if (Object.keys(S.edits).length && !confirm('Discard unsaved settings?')) return;
    S.edits = {}; updateSaveBar();
  }
  S.page = page;
  document.querySelectorAll('.page').forEach((p) => { p.hidden = p.dataset.page !== page; });
  document.querySelectorAll('.nav-i').forEach((b) => { if (b.dataset.page === page) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current'); });
  $('pageTitle').textContent = PAGES[page][0]; $('pageSub').textContent = PAGES[page][1];
  $('pages').scrollTop = 0;
  if (page === 'settings') loadSettings();
  if (page === 'activity') S.seenEvents = S.events.length;
  if (page === 'roblox') loadRoblox();
  renderAll();
  store.set('arkuzo-page', page);
}
document.querySelectorAll('.nav-i').forEach((b) => b.addEventListener('click', () => showPage(b.dataset.page)));
document.querySelectorAll('[data-goto]').forEach((b) => b.addEventListener('click', () => showPage(b.dataset.goto)));
$('search').addEventListener('input', () => { S.query = $('search').value.trim().toLowerCase(); renderAll(); });
document.addEventListener('keydown', (e) => {
  if (!$('intro').classList.contains('done')) { finishIntro(); return; }
  const typing = /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName);
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); $('search').focus(); $('search').select(); return; }
  if (e.key === 'Escape' && document.activeElement === $('search')) { $('search').value = ''; S.query = ''; $('search').blur(); renderAll(); return; }
  if (!typing && !e.ctrlKey && !e.altKey && !e.metaKey && /^[1-6]$/.test(e.key)) showPage(Object.keys(PAGES)[Number(e.key) - 1]);
});
$('btnLive').onclick = () => {
  S.live = !S.live;
  $('btnLive').replaceChildren(el('span', { class: 'dot ' + (S.live ? 'good' : 'warn') }), el('span', { text: S.live ? 'Live' : 'Paused' }));
  $('btnLive').title = S.live ? 'Pause live updates' : 'Resume live updates';
  if (S.live) renderAll();
};
const matches = (...fields) => !S.query || fields.some((f) => String(f ?? '').toLowerCase().includes(S.query));

// ---------- status ----------
const CRIT = new Set(['NOT RESPONDING', 'STUCK CLIENT', 'LEAK GUARD', 'COMMIT PRESSURE', 'CRITICAL COMMIT', 'VOLT STARTUP ERROR', 'DISCONNECTED', 'FARM FREEZE']);
const WARN = new Set(['MEMORY GRACE', 'HANG GRACE', 'NO CPU >10s', 'CHECK NOTICE']);
function clientStatus(c, stale) {
  if (stale) return { level: 'neutral', label: 'No live data' };
  const s = c.state || '';
  if (CRIT.has(s)) return { level: 'critical', label: s === 'VOLT STARTUP ERROR' ? 'Startup error' : s.charAt(0) + s.slice(1).toLowerCase() };
  if (WARN.has(s)) return { level: 'warning', label: s === 'NO CPU >10s' ? 'Idle CPU' : s.charAt(0) + s.slice(1).toLowerCase() };
  if (s === 'LOADING') return { level: 'neutral', label: 'Loading' };
  if (String(c.nextTrim || '').startsWith('WARMUP')) return { level: 'neutral', label: 'Warming up' };
  return { level: 'good', label: c.gameReady ? 'In game' : (s === 'MINIMIZED' ? 'Minimized' : 'Running') };
}
const isStale = (st) => !st || !st.heartbeat || st.heartbeatAgeSec == null || st.heartbeatAgeSec > 15;
const SAVER = { running: ['good', 'Saver running'], external: ['good', 'Saver running'], starting: ['info', 'Starting…'], restarting: ['warn', 'Restarting'], crashed: ['bad', 'Saver failing'], stopped: ['', 'Saver stopped'] };
function renderSaver(st) {
  const sup = st.supervisor, hb = st.heartbeat, [level, label] = SAVER[sup.state] || ['', sup.state];
  $('saverDot').className = 'dot ' + level;
  $('saverLabel').textContent = label + (sup.state === 'external' ? ' (external)' : '');
  $('saverLabel').title = sup.message || '';
  let meta = sup.message || '';
  if ((sup.state === 'running' || sup.state === 'external') && hb) meta = `up ${fmtDur(hb.uptimeSec)} · v${hb.version}`;
  else if ((sup.state === 'restarting' || sup.state === 'crashed') && sup.restartInSec != null) meta = 'retry in ' + fmtDur(sup.restartInSec);
  $('saverMeta').textContent = meta;
  const live = ['running', 'external', 'starting'].includes(sup.state);
  $('btnStart').hidden = live; $('btnStop').hidden = !live; $('btnRestart').hidden = !live;
  $('btnTrim').disabled = !live || isStale(st);
  if (document.activeElement !== $('autopilot')) $('autopilot').checked = !!sup.autopilot;
  $('footVersion').textContent = hb ? `Saver v${hb.version} · PID ${hb.pid}` : 'Saver offline';
  $('footUpdate').textContent = hb && hb.updateAvailable && hb.updateAvailable.available ? `Update ${hb.updateAvailable.latestVersion}` : '';
  // The profile folder shows as ~ so shared screenshots don't carry the Windows user name.
  $('footData').textContent = st.dataDirectory.replace(/^[a-z]:\\users\\[^\\]+(?=\\|$)/i, '~'); $('footData').title = st.dataDirectory;
}

// ---------- issues ----------
function renderIssues(st) {
  const box = $('issues'); box.replaceChildren();
  const issues = [...st.issues], seen = new Set(issues.map((i) => i.title));
  for (const a of ((st.heartbeat && st.heartbeat.alerts) || []).slice(0, 3)) {
    if (!a.message || seen.has(a.message) || a.ageSec > 60) continue;
    issues.push({ level: /fail|blocked|error|dead|critical/i.test(a.message) ? 'critical' : 'warning', title: a.message, detail: '' });
  }
  if (!issues.length && st.heartbeat && ['running', 'external'].includes(st.supervisor.state)) issues.push({ level: 'good', title: 'Farm healthy', detail: 'Every client is monitored; memory and recovery policies are active.' });
  for (const i of issues.slice(0, 5)) {
    const [c, ic] = LEVEL[i.level] || LEVEL.warning;
    box.append(el('div', { class: 'card issue' }, tile(ic, c), el('div', {}, el('div', { class: 't', text: i.title }), i.detail ? el('div', { class: 'd', text: i.detail }) : null)));
  }
}

// ---------- KPI cards (PerfCardsRow style) ----------
const GRADE = { ok: ['#34d399', 'OK'], warn: ['#fbbf24', 'HIGH'], bad: ['#f87171', 'CRITICAL'] };
function kpi(label, iconName, color, valueParts, sub, meter) {
  const node = el('div', { class: 'card pc', style: `--c:${color}` },
    el('div', { class: 'lbl' }, icon(iconName), el('span', { class: 'cap', text: label })),
    el('div', { class: 'val num' }, valueParts[0], valueParts[1] ? el('small', { text: valueParts[1] }) : null),
    el('div', { class: 'sub', text: sub }));
  if (meter) {
    const [g, word] = GRADE[meter.grade];
    node.style.setProperty('--g', g);
    node.append(el('span', { class: 'grade', text: word }), el('div', { class: 'meter well', role: 'img', 'aria-label': meter.label }, el('i', { style: `width:${Math.max(2, Math.min(100, meter.pct)).toFixed(1)}%` })));
  }
  return node;
}
function renderKpis(st) {
  const hb = st.heartbeat, box = $('kpis');
  if (!hb) { box.replaceChildren(kpi('Saver', 'power', '#7e879a', ['Offline'], st.supervisor.message || 'Waiting for the saver heartbeat.')); return; }
  const clients = hb.clients || [], totals = hb.totals || {}, mem = hb.systemMemory || {}, set = hb.settings || {};
  const resident = totals.residentMB ?? clients.reduce((a, c) => a + (c.residentMB || 0), 0);
  const priv = totals.privateMB ?? clients.reduce((a, c) => a + (c.privateMB || 0), 0);
  const totalPhys = hb.totalPhysicalMB || 0, avail = mem.availablePhysicalMB, freePct = totalPhys && avail != null ? 100 * avail / totalPhys : null;
  const commit = mem.commitPercent, pressureAt = (hb.health || {}).pressure_percent || 88;
  const healthy = clients.filter((c) => clientStatus(c).level === 'good').length, expected = hb.expectedAccounts || 0;
  box.replaceChildren(
    kpi('Clients', 'hud', '#34d399', [String(clients.length), expected ? `/ ${expected}` : ''], `${healthy} healthy · ${hb.missingAccounts || 0} missing`),
    kpi('Farm RAM', 'containers', '#38bdf8', fmtGBparts(resident), `target ${set.targetMB || '–'} MB · ${clients.length ? fmtMB(resident / clients.length) : '–'} avg`),
    kpi('Private', 'profiles', '#a78bfa', fmtGBparts(priv), clients.length ? `${fmtMB(priv / clients.length)} per client` : 'no clients'),
    kpi('RAM free', 'perf-monitor', '#22d3ee', avail != null ? fmtGBparts(avail) : ['–'], (freePct != null ? fmtPct(freePct) + ' free · ' : '') + `trim ${set.effectiveTrimSec || set.trimEverySec || '–'}s`,
      freePct != null ? { pct: 100 - freePct, grade: set.trimPressure ? 'warn' : freePct < 8 ? 'bad' : 'ok', label: fmtPct(100 - freePct) + ' of physical RAM used' } : null),
    kpi('OS commit', 'fast-break', '#fbbf24', [commit != null ? String(Math.round(commit)) : '–', '%'], mem.commitLimitMB ? `${fmtMB(mem.commitUsedMB)} of ${fmtMB(mem.commitLimitMB)}` : '',
      commit != null ? { pct: commit, grade: commit >= pressureAt ? 'bad' : commit >= pressureAt - 8 ? 'warn' : 'ok', label: fmtPct(commit) + ' commit used' } : null),
    kpi('Recovery', 'coordinate-leak-protection', '#f472b6', [String(hb.pendingRecoveries || 0), 'pending'], `${(hb.quarantined || []).length} quarantined · ${(hb.suspendedAccounts || []).length} dead cookie`),
    kpi('Trims', 'auto-tool', '#2dd4bf', [Number(hb.trims || 0).toLocaleString()], `uptime ${fmtDur(hb.uptimeSec)}`),
  );
}

// ---------- charts ----------
const CHARTS = {
  chartMem: { table: 'tableMem', series: [{ key: 'resident', label: 'Resident', color: '--s1' }, { key: 'private', label: 'Private', color: '--s2' }], fmt: fmtMB, axisFmt: (v) => v === 0 ? '0' : v >= 1024 ? (v / 1024).toFixed(v >= 10240 ? 0 : 1) + ' GB' : Math.round(v) + ' MB' },
  chartPressure: { table: 'tablePressure', series: [{ key: 'commit', label: 'OS commit', color: '--s1' }, { key: 'ramUsed', label: 'Physical RAM', color: '--s2' }], fmt: fmtPct, axisFmt: (v) => v + '%', yMax: 100 },
};
function niceMax(v) { if (v <= 0) return 1; const p = Math.pow(10, Math.floor(Math.log10(v))), n = v / p; return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p; }
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
function drawChart(id) {
  const host = $(id), cfg = CHARTS[id];
  if (!host.offsetParent) return;
  const W = Math.max(300, host.clientWidth), H = host.clientHeight || 214, m = { l: 52, r: 88, t: 12, b: 26 };
  const now = (S.state && S.state.now) || Date.now() / 1000, x0 = now - S.range, pts = S.history.filter((p) => p.t >= x0);
  cfg.view = { pts, W, H, m, x0, x1: now };
  if (pts.length < 2) { host.replaceChildren(el('div', { class: 'empty', text: S.state && !isStale(S.state) ? 'Collecting samples…' : 'No live data while the saver is not reporting' })); return; }
  let max = cfg.yMax;
  if (!max) { max = 0; for (const p of pts) for (const s of cfg.series) if (p[s.key] != null) max = Math.max(max, p[s.key]); max *= 1.08; max = max > 1024 ? niceMax(max / 1024 / 4) * 4 * 1024 : niceMax(max / 4) * 4; }
  const X = (t) => m.l + (t - x0) / (now - x0) * (W - m.l - m.r), Y = (v) => m.t + (1 - v / max) * (H - m.t - m.b);
  Object.assign(cfg.view, { max, X, Y });
  const ov = css('--ov'), grid = `rgba(${ov},0.06)`, axis = `rgba(${ov},0.16)`, dim = css('--dim'), ink2 = css('--text-2'), surface = css('--surface');
  let svg = `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-hidden="true"><defs>`;
  for (const s of cfg.series) svg += `<linearGradient id="g-${id}-${s.key}" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="${css(s.color)}" stop-opacity=".16"/><stop offset="1" stop-color="${css(s.color)}" stop-opacity="0"/></linearGradient>`;
  svg += '</defs>';
  for (let i = 0; i <= 4; i++) { const v = max * i / 4, y = Y(v).toFixed(1);
    svg += `<line x1="${m.l}" x2="${W - m.r}" y1="${y}" y2="${y}" stroke="${i ? grid : axis}"/><text x="${m.l - 8}" y="${y}" dy="0.32em" text-anchor="end" font-size="11" fill="${dim}" style="font-variant-numeric:tabular-nums">${cfg.axisFmt(Math.round(v * 10) / 10)}</text>`; }
  const step = S.range <= 900 ? 300 : 900;
  for (let t = Math.ceil(x0 / step) * step; t <= now; t += step) svg += `<text x="${X(t).toFixed(1)}" y="${H - 6}" text-anchor="middle" font-size="11" fill="${dim}">${fmtClock(t)}</text>`;
  if (id === 'chartPressure' && S.state && S.state.heartbeat) {
    const at = (S.state.heartbeat.health || {}).pressure_percent || 88, y = Y(at).toFixed(1);
    svg += `<line x1="${m.l}" x2="${W - m.r}" y1="${y}" y2="${y}" stroke="#f87171" stroke-opacity=".55" stroke-dasharray="4 4"/><text x="${m.l + 6}" y="${y}" dy="-0.45em" font-size="11" fill="${dim}">recycle at ${at}%</text>`;
  }
  const labels = [], base = Y(0).toFixed(1);
  for (const s of cfg.series) {
    let d = '', area = '', prev = null;
    for (const p of pts) {
      const v = p[s.key]; if (v == null) continue;
      const x = X(p.t).toFixed(1), y = Y(v).toFixed(1), cont = prev && p.t - prev.t <= 12; // A missed heartbeat is a gap.
      if (!cont) { if (prev) area += `L${X(prev.t).toFixed(1)} ${base}Z`; area += `M${x} ${base}L${x} ${y}`; } else area += `L${x} ${y}`;
      d += (cont ? 'L' : 'M') + x + ' ' + y; prev = p;
    }
    if (prev) area += `L${X(prev.t).toFixed(1)} ${base}Z`;
    svg += `<path d="${area}" fill="url(#g-${id}-${s.key})" stroke="none"/><path d="${d}" fill="none" stroke="${css(s.color)}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`;
    const last = [...pts].reverse().find((p) => p[s.key] != null);
    if (last) labels.push({ y: Y(last[s.key]), text: cfg.fmt(last[s.key]), color: css(s.color), x: X(last.t) });
  }
  labels.sort((a, b) => a.y - b.y);
  for (let i = 1; i < labels.length; i++) if (labels[i].y - labels[i - 1].y < 15) labels[i].y = labels[i - 1].y + 15;
  for (const l of labels) svg += `<circle cx="${l.x.toFixed(1)}" cy="${l.y.toFixed(1)}" r="4" fill="${l.color}" stroke="${surface}" stroke-width="2"/><line x1="${(W - m.r + 8).toFixed(1)}" x2="${(W - m.r + 18).toFixed(1)}" y1="${l.y.toFixed(1)}" y2="${l.y.toFixed(1)}" stroke="${l.color}" stroke-width="2" stroke-linecap="round"/><text x="${W - m.r + 23}" y="${l.y.toFixed(1)}" dy="0.32em" font-size="12" font-weight="650" fill="${ink2}" style="font-variant-numeric:tabular-nums">${l.text}</text>`;
  svg += `<line class="xhair" x1="0" x2="0" y1="${m.t}" y2="${H - m.b}" stroke="${dim}" visibility="hidden"/>`;
  for (const s of cfg.series) svg += `<circle class="hdot" data-key="${s.key}" r="4" fill="${css(s.color)}" stroke="${surface}" stroke-width="2" visibility="hidden"/>`;
  host.innerHTML = svg + '</svg>';
  host.append(el('div', { class: 'tip', hidden: true }));
  if (cfg.hover != null) showHover(id, cfg.hover);
  renderTable(id);
}
function showHover(id, index) {
  const host = $(id), cfg = CHARTS[id], v = cfg.view;
  if (!v || !v.pts || v.pts.length < 2) return;
  index = Math.max(0, Math.min(v.pts.length - 1, index)); cfg.hover = index;
  const p = v.pts[index], x = v.X(p.t), svg = host.querySelector('svg'), tip = host.querySelector('.tip');
  if (!svg || !tip) return;
  const xh = svg.querySelector('.xhair'); xh.setAttribute('x1', x); xh.setAttribute('x2', x); xh.setAttribute('visibility', 'visible');
  tip.replaceChildren(el('div', { class: 'tt', text: `${fmtTime(p.t)} · ${p.clients} clients` }));
  for (const s of cfg.series) {
    const dot = svg.querySelector(`.hdot[data-key="${s.key}"]`);
    if (p[s.key] == null) { dot.setAttribute('visibility', 'hidden'); continue; }
    dot.setAttribute('cx', x); dot.setAttribute('cy', v.Y(p[s.key])); dot.setAttribute('visibility', 'visible');
    tip.append(el('div', { class: 'row' }, el('i', { style: `background:var(${s.color})` }), el('b', { text: cfg.fmt(p[s.key]) }), el('span', { text: s.label })));
  }
  tip.hidden = false;
  tip.style.left = Math.max(0, x + 14 + 170 > v.W ? x - 14 - tip.offsetWidth : x + 14) + 'px'; tip.style.top = '8px';
}
function hideHover(id) {
  const host = $(id); CHARTS[id].hover = null;
  const svg = host.querySelector('svg'), tip = host.querySelector('.tip');
  if (tip) tip.hidden = true;
  if (svg) svg.querySelectorAll('.xhair,.hdot').forEach((n) => n.setAttribute('visibility', 'hidden'));
}
for (const id of Object.keys(CHARTS)) {
  const host = $(id);
  host.addEventListener('pointermove', (e) => {
    const v = CHARTS[id].view; if (!v || !v.pts || v.pts.length < 2) return;
    const rect = host.getBoundingClientRect(), px = (e.clientX - rect.left) * (v.W / rect.width), t = v.x0 + (px - v.m.l) / (v.W - v.m.l - v.m.r) * (v.x1 - v.x0);
    let best = 0; for (let i = 1; i < v.pts.length; i++) if (Math.abs(v.pts[i].t - t) < Math.abs(v.pts[best].t - t)) best = i;
    showHover(id, best);
  });
  host.addEventListener('pointerleave', () => hideHover(id));
  host.addEventListener('blur', () => hideHover(id));
  host.addEventListener('keydown', (e) => {
    const v = CHARTS[id].view; if (!v || !v.pts || !v.pts.length) return;
    const cur = CHARTS[id].hover ?? v.pts.length - 1;
    if (e.key === 'ArrowLeft') { showHover(id, cur - 1); e.preventDefault(); } else if (e.key === 'ArrowRight') { showHover(id, cur + 1); e.preventDefault(); } else if (e.key === 'Escape') hideHover(id);
  });
}
function renderTable(id) {
  const cfg = CHARTS[id], box = $(cfg.table);
  if (!box.closest('details').open) return;
  const pts = (cfg.view && cfg.view.pts) || [], rows = []; let lastMinute = null;
  for (let i = pts.length - 1; i >= 0 && rows.length < 30; i--) { const minute = Math.floor(pts[i].t / 60); if (minute === lastMinute) continue; lastMinute = minute; rows.push(pts[i]); }
  const td = (text, right) => el('td', { text, style: `padding:4px 8px;${right ? 'text-align:right;' : ''}font-variant-numeric:tabular-nums;color:var(--text-2)` });
  box.replaceChildren(el('table', { style: 'width:100%;border-collapse:collapse;font-size:12px;margin-top:6px' },
    el('thead', {}, el('tr', { style: 'color:var(--dim);text-align:left' }, el('th', { text: 'Time' }), el('th', { text: 'Clients', style: 'text-align:right' }), cfg.series.map((s) => el('th', { text: s.label, style: 'text-align:right' })))),
    el('tbody', {}, rows.map((p) => el('tr', {}, td(fmtTime(p.t)), td(String(p.clients), true), cfg.series.map((s) => td(cfg.fmt(p[s.key]), true)))))));
}
document.querySelectorAll('details.tv').forEach((d) => d.addEventListener('toggle', () => redrawCharts()));
function redrawCharts() { for (const id of Object.keys(CHARTS)) drawChart(id); }
document.querySelectorAll('.seg button').forEach((b) => b.addEventListener('click', () => {
  S.range = Number(b.dataset.range);
  document.querySelectorAll('.seg button').forEach((x) => x.setAttribute('aria-pressed', String(Number(x.dataset.range) === S.range)));
  redrawCharts();
}));
new ResizeObserver(() => redrawCharts()).observe(document.querySelector('.charts'));
// ?theme=, ?accent=, ?page= and ?intro=0|hold open a specific view (docs screenshots, shortcuts).
const params = new URLSearchParams(location.search);
applyTheme(params.get('theme') || store.get('arkuzo-theme') || 'graphite');
applyAccent(params.get('accent') || store.get('arkuzo-accent') || 'Cyan');

// ---------- clients (ModuleItemRow style) ----------
const sortedClients = (st) => ((st.heartbeat && st.heartbeat.clients) || []).slice().sort((a, b) => (a.slot ?? 99) - (b.slot ?? 99) || a.pid - b.pid);
const clientName = (c) => c.account && c.account !== 'Unknown account' ? c.account : 'Unmapped client';
function memCell(c, target, scale) {
  const res = c.residentMB || 0;
  return el('span', { class: 'memcell' }, el('span', { class: 'mem well', role: 'img', 'aria-label': `${Math.round(res)} MB of ${target} MB target` },
    el('i', { style: `width:${(100 * res / scale).toFixed(1)}%` }), el('b', { style: `left:${(100 * target / scale).toFixed(1)}%` })), el('span', { class: 'v', style: 'min-width:56px', text: fmtMB(res) }));
}
function clientRow(c, stale, target, scale, compact) {
  const s = clientStatus(c, stale), [color] = LEVEL[s.level];
  const kids = [tile('hud', color, 'sm'),
    el('div', { style: 'min-width:0' }, el('div', { class: 'nm', text: clientName(c), title: clientName(c) }), el('div', { class: 'sb num', text: `Slot ${c.slot != null ? c.slot + 1 : '–'} · PID ${c.pid} · up ${fmtDur(c.ageSec)}` })),
    el('span', { title: c.disconnectReason || null }, pill(s.level, s.label, true)), memCell(c, target, scale)];
  if (!compact) kids.push(el('span', { class: 'v hide-sm t2', text: fmtMB(c.privateMB) }), el('span', { class: 'v hide-sm t2', text: c.cpuPercent != null ? c.cpuPercent.toFixed(1) + '%' : '–' }),
    el('span', { class: 'v hide-sm' }, String(c.nextTrim || '').startsWith('WARMUP') ? el('span', { class: 'kc amber', text: String(c.nextTrim).replace('WARMUP ', '') }) : el('span', { class: 'kc', text: c.nextTrim || '–' })));
  return el('div', { class: 'mrow crow' + (compact ? ' compact' : ''), role: 'button', tabindex: '0', 'aria-selected': String(!compact && c.pid === S.selectedPid) }, kids);
}
function renderClients(st) {
  const stale = isStale(st), hb = st.heartbeat, all = sortedClients(st), shown = all.filter((c) => matches(clientName(c), c.pid, c.state));
  const target = (hb && hb.settings && hb.settings.targetMB) || 600, scale = Math.max(target * 1.6, ...all.map((c) => c.residentMB || 0));
  $('navClients').textContent = String(all.length);
  $('navClients').className = 'badge num ' + (!stale && all.some((c) => clientStatus(c).level === 'critical') ? 'alert' : all.length ? '' : 'quiet');
  $('ovClientsEmpty').hidden = all.length > 0;
  $('ovClientsSub').textContent = stale && hb ? 'last report, not live' : (all.length ? `${all.length} running` : '');
  $('ovClients').replaceChildren(...shown.slice(0, 8).map((c) => { const r = clientRow(c, stale, target, scale, true); r.onclick = () => { S.selectedPid = c.pid; showPage('clients'); }; return r; }));
  $('clientsEmpty').hidden = all.length > 0;
  $('colhead').hidden = all.length === 0;
  $('clientsSub').textContent = stale && hb ? 'last report, not live' : (all.length ? `${all.length} running${hb.settings && hb.settings.memoryPriority ? ' · ' + hb.settings.memoryPriority + ' memory priority' : ''}` : '');
  if (S.selectedPid != null && !all.some((c) => c.pid === S.selectedPid)) S.selectedPid = null;
  if (S.selectedPid == null && all.length) S.selectedPid = all[0].pid;
  $('clients').replaceChildren(...shown.map((c) => {
    const r = clientRow(c, stale, target, scale, false);
    r.onclick = () => { S.selectedPid = c.pid; renderClients(S.state); };
    r.onkeydown = (e) => { if (e.key === 'Enter') r.click(); };
    return r;
  }));
  renderClientDetail(all.find((c) => c.pid === S.selectedPid), stale, target);
}
function renderClientDetail(c, stale, target) {
  const box = $('clientDetail');
  if (!c) { box.replaceChildren(el('div', { class: 'empty-state', text: 'Select a client to see its details.' })); return; }
  const s = clientStatus(c, stale), [color] = LEVEL[s.level];
  const rows = [['Slot', c.slot != null ? String(c.slot + 1) : '–'], ['PID', String(c.pid)], ['Resident', `${fmtMB(c.residentMB)} / ${target} MB`], ['Private', fmtMB(c.privateMB)],
    ['CPU', c.cpuPercent != null ? c.cpuPercent.toFixed(1) + '%' : '–'], ['Next trim', c.nextTrim || '–'], ['Uptime', fmtDur(c.ageSec)], ['In game', c.gameReady ? 'Yes' : 'Not yet'],
    ['Responding', c.responding === false ? 'No' : 'Yes'], ['Memory priority', c.memoryPriority || 'Unchanged'], ['Recovery eligible', c.eligible ? 'Yes' : 'No']];
  if (c.disconnectReason) rows.push(['Last disconnect', c.disconnectReason]);
  const dl = el('dl', { class: 'kv' }); for (const [k, v] of rows) dl.append(el('dt', { text: k }), el('dd', { text: v }));
  box.replaceChildren(el('div', { class: 'pane-h' }, tile('hud', color, 'lg'), el('div', { style: 'min-width:0;flex:1' }, el('div', { class: 'ttl', text: clientName(c) }), el('div', { class: 'st' }, pill(s.level, s.label, true)))),
    el('div', { class: 'divider' }), dl);
}

// ---------- accounts ----------
function renderAccounts(st) {
  const hb = st.heartbeat, list = $('accounts'), all = ((hb && hb.accounts) || []).slice().sort((a, b) => String(a.username).localeCompare(String(b.username)));
  $('navAccounts').textContent = String(all.length);
  $('navAccounts').className = 'badge num' + (all.length ? '' : ' quiet');
  $('acctEmpty').hidden = all.length > 0;
  if (!all.length) { list.replaceChildren(); $('acctSub').textContent = ''; return; }
  const excluded = new Set(((hb.recovery || {}).excluded_account_ids || []).map((x) => x.toLowerCase()));
  const pending = new Set((hb.pending || []).map((p) => p.accountId)), quarantined = new Map((hb.quarantined || []).map((q) => [q.accountId, q]));
  $('acctSub').textContent = `${all.filter((a) => a.uiStatus === 'Connected').length} of ${all.length} connected`;
  list.replaceChildren(...all.filter((a) => matches(a.username, a.uiStatus, a.cookieStatus)).map((a) => {
    const sub = el('div', { class: 'sb', style: 'display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-top:3px' });
    if (a.cookieStatus === 'dead') sub.append(pill('critical', 'Cookie dead', true));
    else if (a.uiStatus === 'Connected') sub.append(pill('good', 'Connected', true));
    else sub.append(pill('neutral', a.uiStatus || 'Unknown', true));
    const q = quarantined.get(a.accountId), until = q && Date.parse(q.untilUtc);
    if (q && (!until || until > Date.now())) sub.append(pill('serious', 'Quarantined' + (until ? ' · ' + fmtDur((until - Date.now()) / 1000) : ''), true));
    else if (pending.has(a.accountId)) sub.append(pill('warning', 'Recovering', true));
    if (!a.autoRelaunch) sub.append(el('span', { text: 'Volt auto-relaunch off' }));
    const input = el('input', { type: 'checkbox', 'aria-label': `Auto-recover ${a.username}` });
    input.checked = !excluded.has(String(a.accountId).toLowerCase());
    input.addEventListener('change', async () => {
      input.disabled = true;
      try { await post('/api/accounts/recovery', { accountId: a.accountId, enabled: input.checked }); toast(`${a.username}: auto-recover ${input.checked ? 'on' : 'off'}`, input.checked ? 'good' : 'neutral'); }
      catch (e) { input.checked = !input.checked; toast(e.message, 'critical'); }
      finally { input.disabled = false; }
    });
    return el('div', { class: 'mrow arow' }, el('span', { class: 'tile sm', style: 'font-size:10px;font-weight:800;--c:#a78bfa', text: initials(a.username) }),
      el('div', { style: 'min-width:0' }, el('div', { class: 'nm', text: a.username || 'Unknown account' }), sub),
      el('label', { class: 'sw', title: 'Auto-recover this account' }, el('span', { class: 'sb', text: 'Auto-recover' }), input, el('span', { class: 'track' })));
  }));
}

// ---------- Arkuzo accounts ----------
const agoMs = (ms) => ms ? fmtDur((Date.now() - ms) / 1000) + ' ago' : 'never';
const acctName = (a) => a.alias || a.displayName || a.username || 'Account';
function avatarFor(a) {
  const img = el('img', { class: 'avatar', alt: '', loading: 'lazy', src: `/api/avatar?userId=${a.userId}` });
  img.addEventListener('error', () => img.replaceWith(el('span', { class: 'avatar', text: initials(acctName(a)) })), { once: true });
  return img;
}
async function loadVault() {
  try { S.vault = await fetch('/api/vault', { cache: 'no-store' }).then((r) => r.json()); S.vaultAt = Date.now(); renderVault(); }
  catch (e) { /* the state poll shows offline */ }
}
async function vaultAct(path, body, done, level) {
  try { const r = await post(path, body); if (done) toast(done, level || 'good'); await loadVault(); return r.result; }
  catch (e) { toast(e.message, 'critical'); await loadVault(); return null; }
}
function accountStatus(a, hb, farmRunning) {
  if (a.cookieStatus === 'dead') return ['critical', 'Signed out'];
  const live = a.live || {}, pid = live.processId;
  if (a.cookieStatus === 'moderated' && !pid) return ['critical', 'Moderated'];
  const q = ((hb && hb.quarantined) || []).find((x) => x.accountId === a.id), until = q && Date.parse(q.untilUtc);
  if (q && (!until || until > Date.now())) return ['serious', 'Quarantined'];
  if (pid) {
    const c = ((hb && hb.clients) || []).find((x) => x.pid === pid);
    if (!c) return ['good', 'Running'];
    const s = clientStatus(c, false);
    return [s.level, s.label];
  }
  if (live.uiStatus === 'Launching') return ['info', 'Launching'];
  if (((hb && hb.pending) || []).some((p) => p.accountId === a.id)) return ['warning', 'Relaunching'];
  if (farmRunning && a.autoRelaunch) return ['neutral', 'Queued'];
  return ['neutral', 'Offline'];
}
function renderVault() {
  const v = S.vault; if (!v) return;
  const st = S.state || {}, hb = st.heartbeat, active = v.activeProvider || (hb && hb.accountProvider), native = active === 'arkuzo';
  const accounts = (v.accounts || []).slice().sort((a, b) => acctName(a).localeCompare(acctName(b)));
  const farm = !!v.settings.farmRunning, inGame = accounts.filter((a) => (a.live || {}).processId).length;
  const relaunch = accounts.filter((a) => a.autoRelaunch && a.cookieStatus !== 'dead' && a.cookieStatus !== 'moderated').length, dead = accounts.filter((a) => a.cookieStatus === 'dead').length;
  const moderated = accounts.filter((a) => a.cookieStatus === 'moderated').length;
  $('navAccounts').textContent = String(accounts.length || ((hb && hb.accounts) || []).length);
  $('navAccounts').className = 'badge num' + (dead || moderated ? ' alert' : accounts.length ? '' : ' quiet');
  // Farm card.
  $('farmTile').style.setProperty('--c', farm ? '#34d399' : '#7e879a');
  $('farmTitle').textContent = !native && accounts.length ? 'Volt is launching clients' : farm ? 'Farm running' : 'Farm stopped';
  $('farmSub').textContent = !native && accounts.length ? 'Switch "Who launches clients" below to Arkuzo to farm without Volt.'
    : farm ? `Keeping ${relaunch} account${relaunch === 1 ? '' : 's'} in game; relaunching ${v.settings.relaunchDelaySec}s after a close, launches ${v.settings.launchDelaySec}s apart.`
    : 'Start the farm to launch every account that has relaunch on.';
  $('farmStats').replaceChildren(...[['In game', `${inGame}/${accounts.length}`], ['Relaunch on', relaunch], ['Signed out', dead], ...(moderated ? [['Moderated', moderated]] : [])].map(([k, n]) => el('div', {}, el('b', { text: String(n) }), el('span', { text: k }))));
  $('btnFarmStart').hidden = farm; $('btnFarmStop').hidden = !farm; $('btnCloseAll').disabled = !inGame || !native;
  $('btnFarmStart').disabled = !accounts.length;
  const notice = v.error || v.providerNotice || (hb && hb.accountProviderNotice) ||
    (v.unreadableCount ? `${v.unreadableCount} account row${v.unreadableCount === 1 ? '' : 's'} in data/accounts.json could not be read and ${v.unreadableCount === 1 ? 'is' : 'are'} kept untouched there.` : '');
  $('farmNotice').hidden = !notice; $('farmNotice').textContent = notice || '';
  // Sign-in line.
  const login = v.login || {};
  const busy = ['starting', 'waiting', 'reading'].includes(login.state);
  $('btnSignIn').disabled = !v.browserLogin || busy;
  if (!v.browserLogin) $('btnSignIn').title = 'Microsoft Edge is needed for browser sign-in';
  $('loginLine').hidden = !busy;
  if (busy) $('loginLine').replaceChildren(el('span', { class: 'spin' }), el('span', { text: login.message || 'Waiting for sign-in' }), el('div', { class: 'spacer' }),
    el('button', { class: 'btn ghost sm', onclick: () => vaultAct('/api/vault/login/cancel', {}, 'Sign-in cancelled', 'neutral') }, 'Cancel'));
  if (S.loginState && S.loginState !== login.state && (login.state === 'success' || login.state === 'failed')) toast(login.message, login.state === 'success' ? 'good' : 'critical');
  S.loginState = login.state;
  // Rows.
  $('vaultSub').textContent = accounts.length ? `${accounts.length} account${accounts.length === 1 ? '' : 's'} · cookies encrypted on this PC` : '';
  const editing = document.querySelector('#vaultRows .editor');
  if (editing && editing.contains(document.activeElement)) { renderFarmSettings(v); renderServers(v); return; } // Never redraw under the cursor.
  $('vaultEmpty').hidden = accounts.length > 0;
  const servers = v.privateServers || [];
  const rows = [];
  for (const a of accounts.filter((x) => matches(acctName(x), x.username, x.group, x.notes))) {
    const [level, label] = accountStatus(a, hb, farm);
    const sw = el('input', { type: 'checkbox', 'aria-label': `Relaunch ${acctName(a)}` });
    sw.checked = !!a.autoRelaunch;
    sw.addEventListener('change', () => vaultAct('/api/vault/update', { id: a.id, fields: { autoRelaunch: sw.checked } }, `${acctName(a)}: relaunch ${sw.checked ? 'on' : 'off'}`, sw.checked ? 'good' : 'neutral'));
    const ck = a.checking ? pill('info', 'Checking…', true) : a.cookieStatus === 'alive' ? pill('good', 'Alive', true) : a.cookieStatus === 'dead' ? pill('critical', 'Dead', true) : a.cookieStatus === 'moderated' ? pill('critical', 'Moderated', true) : pill('neutral', 'Unchecked', true);
    const live = !!(a.live || {}).processId || (a.live || {}).uiStatus === 'Launching';
    const sub = el('div', { class: 'sb', style: 'display:flex;gap:6px;align-items:center' }, el('span', { text: '@' + a.username }), a.group ? el('span', { class: 'grp', text: a.group }) : null,
      a.lastError && a.cookieStatus !== 'alive' ? el('span', { title: a.lastError, text: '· ' + a.lastError }) : null);
    rows.push(el('div', { class: 'mrow vrow', 'aria-selected': String(S.vaultEdit === a.id) },
      avatarFor(a),
      el('div', { style: 'min-width:0' }, el('div', { class: 'nm', text: acctName(a) }), sub),
      pill(level, label, true),
      el('div', { class: 'ck-cell hide-sm' }, ck, el('span', { class: 'sb', text: a.lastCheckAtMs ? agoMs(a.lastCheckAtMs) : '' }),
        el('button', { class: 'btn ghost sm icon', title: 'Check this cookie with Roblox', disabled: a.checking, onclick: () => vaultAct('/api/vault/check', { ids: [a.id] }, `Checking ${acctName(a)}…`, 'info') }, icon('refresh'))),
      el('label', { class: 'sw hide-sm', title: 'Keep this account in game while the farm runs' }, sw, el('span', { class: 'track' })),
      el('div', { class: 'row-actions' },
        live ? el('button', { class: 'btn sm', title: 'Close this client now. While the farm runs and relaunch is on, it is launched again.', onclick: () => vaultAct('/api/vault/close', { id: a.id }, `${acctName(a)} closed${S.vault && S.vault.settings.farmRunning && a.autoRelaunch ? '; relaunching' : ''}`, 'neutral') }, icon('x'), 'Close')
             : el('button', { class: 'btn sm', disabled: a.cookieStatus === 'dead' || a.cookieStatus === 'moderated' || !native, title: a.cookieStatus === 'moderated' ? 'Roblox has moderated this account: sign in on roblox.com to see why, then check its cookie again' : native ? 'Launch this account now' : 'Arkuzo launches only when it is the launcher (Farm settings)',
                 onclick: () => vaultAct('/api/vault/launch', { id: a.id }, `Launching ${acctName(a)}…`, 'info') }, icon('play'), 'Launch'),
        el('button', { class: 'btn ghost sm icon', title: 'Edit', 'aria-expanded': String(S.vaultEdit === a.id), onclick: () => { S.vaultEdit = S.vaultEdit === a.id ? null : a.id; renderVault(); } }, icon('pencil')))));
    if (S.vaultEdit === a.id) rows.push(accountEditor(a, servers, v.settings));
  }
  $('vaultRows').replaceChildren(...rows);
  renderFarmSettings(v);
  renderServers(v);
  $('accountsCard').hidden = native || !((hb && hb.accounts) || []).length;
}
function accountEditor(a, servers, settings) {
  const f = {};
  const field = (key, label, value, extra) => { f[key] = el('input', Object.assign({ class: 'inp', value: value || '', maxlength: key === 'notes' ? 500 : 40 }, extra || {})); return el('label', { class: key === 'notes' ? 'wide' : '' }, label, f[key]); };
  const serverSel = el('select', {}, el('option', { value: '', text: 'Public server' }), ...servers.map((sv) => el('option', { value: sv.id, text: `${sv.name} · ${sv.placeId}` })));
  serverSel.value = a.privateServerId || '';
  const save = async () => {
    const fields = { alias: f.alias.value, group: f.group.value, notes: f.notes.value, placeId: f.placeId.value.trim(), privateServerId: serverSel.value || null };
    const r = await vaultAct('/api/vault/update', { id: a.id, fields }, `${f.alias.value || a.username} saved`);
    if (r) { S.vaultEdit = null; renderVault(); }
  };
  return el('form', { class: 'editor well', onsubmit: (e) => { e.preventDefault(); save(); } },
    field('alias', 'Name shown here', a.alias, { placeholder: a.displayName }), field('group', 'Group', a.group),
    field('placeId', 'Place (overrides the farm default)', a.placeId, { inputmode: 'numeric', placeholder: settings.defaultPlaceId || 'Farm default' }),
    el('label', {}, settings.privateServerMode === 'assigned' ? 'Private server' : 'Private server (needs mode "Per account")', serverSel),
    field('notes', 'Notes', a.notes),
    el('div', { class: 'bar' },
      el('span', { class: 'sb', style: 'margin-right:auto;color:var(--dim);font-size:11.5px', text: `User ${a.userId} · tracker ${a.browserTrackerId} · added ${agoMs(a.createdAtMs)} · launched ${agoMs(a.lastLaunchAtMs)}` }),
      el('button', { class: 'btn danger sm', type: 'button', onclick: () => { if (confirm(`Remove ${acctName(a)} and its stored cookie from this PC? A running client keeps running.`)) vaultAct('/api/vault/remove', { id: a.id }, `${acctName(a)} removed`, 'neutral'); } }, icon('trash'), 'Remove'),
      el('button', { class: 'btn ghost sm', type: 'button', onclick: () => { S.vaultEdit = null; renderVault(); } }, 'Cancel'),
      el('button', { class: 'btn accent sm', type: 'submit' }, icon('check'), 'Save')));
}
const FARM_FIELDS = [
  ['provider', 'Who launches clients', 'Arkuzo uses the accounts above; Volt uses its own account manager. Auto picks Arkuzo once you add an account, unless Volt’s auto-relaunch is on.', ['enum', ['auto', 'arkuzo', 'volt']]],
  ['launchDelaySec', 'Launch spacing', 'Seconds between two launches. Roblox and executors cope better with some space.', ['int', 5, 120, 's']],
  ['relaunchDelaySec', 'Relaunch delay', 'Wait after a client closed before launching it again.', ['int', 0, 600, 's']],
  ['launchTimeoutSec', 'Launch timeout', 'If no client appears in this time, the launch is retried.', ['int', 30, 600, 's']],
  ['autoRelaunchEnabled', 'Relaunch accounts', 'Master switch for every account\'s relaunch toggle.', ['bool']],
  ['multiInstance', 'Multiple clients', 'Hold Roblox\'s single-instance lock so many clients run side by side.', ['bool']],
  ['launchMethod', 'Launch method', 'Direct starts RobloxPlayerBeta; Protocol goes through Roblox\'s launcher (updates Roblox first). A build pinned on the Roblox tab always starts directly.', ['enum', ['direct', 'protocol']]],
  ['cookieCheckMinutes', 'Cookie check', 'Ask Roblox whether every cookie is still signed in this often (0 = only by hand).', ['int', 0, 1440, 'min']],
];
const LAYOUT_FIELDS = [
  ['arrangeWindows', 'Arrange windows', 'Keep every client window in an orderly layout on screen.', ['bool']],
  ['arrangeLayout', 'Layout', 'Auto: every window on screen, side by side and as large as fits; with more windows than fit, they overlap evenly so each keeps its corner in view. Grid: your size and windows per row. Cascade: stacked diagonally. Roblox windows are never smaller than 800 × 600.', ['enum', ['auto', 'grid', 'cascade'], { auto: 'Auto (fit screen)', grid: 'Grid', cascade: 'Cascade' }]],
  ['arrangePerRow', 'Windows per row', 'Rows that don\'t fit the screen overlap, so every window stays on screen.', ['int', 1, 12, ''], (st) => st.arrangeLayout === 'grid'],
  ['arrangeWidth', 'Window width', 'At least 800: Roblox ignores anything smaller.', ['int', 160, 1920, 'px'], (st) => st.arrangeLayout !== 'auto'],
  ['arrangeHeight', 'Window height', 'At least 622 (600 plus the title bar).', ['int', 120, 1440, 'px'], (st) => st.arrangeLayout !== 'auto'],
  ['arrangeGap', 'Gap', 'Space between windows.', ['int', 0, 40, 'px']],
  ['arrangeCorner', 'Start corner', 'Where the first window goes.', ['enum', ['top-left', 'top-right', 'bottom-left', 'bottom-right'], { 'top-left': 'Top left', 'top-right': 'Top right', 'bottom-left': 'Bottom left', 'bottom-right': 'Bottom right' }]],
  ['arrangeMonitor', 'Screen', 'Which monitor the clients go to.', ['monitor']],
  ['arrangeOrder', 'Order', 'Fixed: every account keeps its own spot, even while another is relaunching. By name or by launch: no gaps.', ['enum', ['fixed', 'name', 'launch'], { fixed: 'Fixed per account', name: 'By name', launch: 'By launch time' }]],
  ['arrangeMode', 'Hold position', 'Keep: windows moved away snap back. Place once: new windows are placed, then you can move them freely.', ['enum', ['keep', 'once'], { keep: 'Keep in place', once: 'Place once' }]],
  ['arrangeVisibility', 'Windows', 'Normal: they stay where Windows puts them. Behind: kept under your other windows, never stealing focus. Minimized: in the taskbar (renders least).', ['enum', ['normal', 'background', 'minimized'], { normal: 'Normal', background: 'Behind other windows', minimized: 'Minimized' }]],
];
function renderFields(box, fields, v) {
  if (box.contains(document.activeElement)) return; // Do not redraw under the cursor.
  box.replaceChildren(...fields.filter((f) => !f[4] || f[4](v.settings)).map(([key, name, hint, rule]) => {
    const value = key === 'provider' ? v.provider : v.settings[key];
    let ctl;
    const save = (val) => key === 'provider'
      ? post('/api/config', { changes: { accounts: { provider: val } } }).then(() => { toast(`Launcher: ${val}`, 'good'); loadVault(); }).catch((e) => { toast(e.message, 'critical'); loadVault(); })
      : vaultAct('/api/vault/settings', { changes: { [key]: val } }, `${name} saved`);
    if (rule[0] === 'bool') {
      const input = el('input', { type: 'checkbox' }); input.checked = !!value;
      input.addEventListener('change', () => save(input.checked));
      ctl = el('label', { class: 'sw' }, input, el('span', { class: 'track' }));
    } else if (rule[0] === 'enum') {
      ctl = el('select', {}, ...rule[1].map((o) => el('option', { value: o, text: (rule[2] || {})[o] || o.charAt(0).toUpperCase() + o.slice(1) })));
      ctl.value = value; ctl.addEventListener('change', () => save(ctl.value));
    } else if (rule[0] === 'monitor') {
      const n = Math.max(1, v.monitors || 1);
      ctl = el('select', {}, el('option', { value: '0', text: 'Main screen' }), ...Array.from({ length: n }, (_, i) => el('option', { value: String(i + 1), text: `Screen ${i + 1}` })));
      ctl.value = String(value || 0); ctl.addEventListener('change', () => save(Number(ctl.value)));
    } else if (rule[0] === 'text') {
      ctl = el('input', { class: 'inp', value: value || '', inputmode: 'numeric', placeholder: 'e.g. 920587237' });
      ctl.addEventListener('change', () => save(ctl.value.trim()));
    } else {
      ctl = el('input', { type: 'number', min: rule[1], max: rule[2], value });
      ctl.addEventListener('change', () => save(Number(ctl.value)));
    }
    const hintEl = el('span', { class: 'hint2' }); hintEl.innerHTML = hint.replace(/</g, '&lt;').replace(/&lt;b>/g, '<b>').replace(/&lt;\/b>/g, '</b>');
    return el('div', { class: 'field' }, el('span', { class: 'name', text: name }), hintEl, el('div', { class: 'ctl' }, ctl, rule[3] ? el('span', { class: 'unit', text: rule[3] }) : null));
  }));
}
function renderFarmSettings(v) {
  renderFields($('farmSettings'), FARM_FIELDS, v);
  renderFields($('layoutSettings'), LAYOUT_FIELDS, v);
  const st = v.settings;
  $('sumFarm').textContent = `${st.launchDelaySec}s apart · relaunch after ${st.relaunchDelaySec}s`;
  $('sumLayout').textContent = !st.arrangeWindows ? 'Off' : st.arrangeLayout === 'auto' ? 'Auto · fit screen' : st.arrangeLayout === 'cascade' ? `Cascade · ${Math.max(st.arrangeWidth, ROBLOX_MIN_W)}×${Math.max(st.arrangeHeight, ROBLOX_MIN_H)}` : `${st.arrangePerRow} per row · ${Math.max(st.arrangeWidth, ROBLOX_MIN_W)}×${Math.max(st.arrangeHeight, ROBLOX_MIN_H)}`;
  const servers = v.privateServers || [];
  $('sumServers').textContent = st.privateServerMode === 'none' ? (servers.length ? `Off · ${servers.length} saved` : 'Off') : st.privateServerMode === 'shared' ? 'One for all' : 'Per account';
  const place = $('placeInput');
  if (document.activeElement !== place) place.value = st.defaultPlaceId || '';
  $('serverPill').replaceChildren(st.privateServerMode === 'none' ? '' : pill('info', st.privateServerMode === 'shared' ? 'Private server for all' : 'Private server per account', true));
  renderLayoutPreview(v);
}
// Roblox never lets its window get smaller than this (800 x 600 plus the title bar).
const ROBLOX_MIN_W = 800, ROBLOX_MIN_H = 622;
// Mirrors Get-ArkuzoWindowSlots in the engine, on the screen this window is on.
// A preview of the layout's shape: logical pixels, no DPI scaling, no monitor offset and no learned larger
// minimum (the engine applies those). contracts/window-layout.json holds both planners to the same results.
// Every window stays on screen; when they can't all fit side by side they overlap evenly.
function layoutSlots(count, st, W, H) {
  const gap = st.arrangeGap, right = st.arrangeCorner.endsWith('right'), bottom = st.arrangeCorner.startsWith('bottom'), out = [];
  if (count <= 0) return out;
  const minW = ROBLOX_MIN_W, minH = ROBLOX_MIN_H;
  const stride = (size, space, n) => n <= 1 ? 0 : Math.floor(Math.max(0, Math.min(size + gap, (space - size) / (n - 1))));
  const place = (dx, dy, w, h) => out.push([right ? W - dx - w : dx, bottom ? H - dy - h : dy, w, h]);
  let w, h, cols;
  if (st.arrangeLayout === 'cascade') {
    w = Math.max(st.arrangeWidth, minW); h = Math.max(st.arrangeHeight, minH);
    const step = 32, fit = Math.max(1, Math.floor(Math.max(0, Math.min(W - w, H - h)) / step) + 1);
    for (let i = 0; i < count; i++) { const d = (i % fit) * step; place(d, d, w, h); }
    return out;
  }
  if (st.arrangeLayout === 'auto') {
    const aspect = minW / minH; let best = 0; cols = 1;
    for (let c = 1; c <= count; c++) { const r = Math.ceil(count / c), fit = Math.min((W - gap * (c - 1)) / c, ((H - gap * (r - 1)) / r) * aspect); if (fit > best) { best = fit; cols = c; } }
    if (best >= minW) { w = Math.floor(best); h = Math.floor(w / aspect); }
    else {
      w = minW; h = minH; let bestScore = -1, bestArea = -1;
      for (let c = 1; c <= count; c++) {
        const r = Math.ceil(count / c), visX = c > 1 ? Math.min(w, stride(w, W, c)) : w, visY = r > 1 ? Math.min(h, stride(h, H, r)) : h;
        const score = Math.min(visX, visY * aspect);
        if (score > bestScore || (score === bestScore && visX * visY > bestArea)) { bestScore = score; bestArea = visX * visY; cols = c; }
      }
    }
  } else { w = Math.max(st.arrangeWidth, minW); h = Math.max(st.arrangeHeight, minH); cols = Math.max(1, Math.min(st.arrangePerRow, count)); }
  const sx = stride(w, W, cols), sy = stride(h, H, Math.ceil(count / cols));
  for (let i = 0; i < count; i++) place((i % cols) * sx, Math.floor(i / cols) * sy, w, h);
  return out;
}
function slotsOverlap(slots) {
  for (let i = 0; i < slots.length; i++) for (let j = i + 1; j < slots.length; j++) {
    const [ax, ay, aw, ah] = slots[i], [bx, by, bw, bh] = slots[j];
    if (ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah) return true;
  }
  return false;
}
function renderLayoutPreview(v) {
  const st = v.settings, box = $('layoutPreview');
  const [SW, SH, W, H] = v.screen || [1920, 1080, 1920, 1040];
  box.style.aspectRatio = `${W} / ${H}`;
  const accounts = (v.accounts || []).slice().sort((a, b) => acctName(a).toLowerCase().localeCompare(acctName(b).toLowerCase()));
  const shown = accounts.filter((a) => (a.live || {}).processId || (st.autoRelaunchEnabled && a.autoRelaunch && a.cookieStatus === 'alive'));
  const list = shown.length ? shown : [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }];
  const slots = layoutSlots(list.length, st, W, H);
  const overlap = slotsOverlap(slots);
  box.replaceChildren(...list.map((a, i) => {
    const [x, y, w, h] = slots[i], live = !!(a.live || {}).processId;
    return el('div', { class: 'win' + (shown.length && !live ? ' off' : '') + (st.arrangeVisibility === 'background' ? ' bg' : ''), title: a.username ? acctName(a) : '',
      style: `left:${x / W * 100}%;top:${y / H * 100}%;width:${w / W * 100}%;height:${h / H * 100}%`, text: a.username ? initials(acctName(a)) : '' });
  }));
  box.style.opacity = st.arrangeWindows ? '1' : '0.45';
  $('previewCap').textContent = !st.arrangeWindows ? 'Arranging is off'
    : `${list.length} window${list.length === 1 ? '' : 's'}${shown.length ? '' : ' (example)'}` + (overlap ? ' · overlapping: Roblox windows can\'t be smaller than 800 × 600, so each keeps its corner in view' : '') + (st.arrangeVisibility === 'minimized' ? ' · minimized' : '');
}
for (const id of ['foldLayout', 'foldFarm', 'foldServers']) {
  const d = $(id), saved = store.get('arkuzo-' + id);
  d.open = saved == null ? id === 'foldLayout' : saved === '1';
  d.addEventListener('toggle', () => store.set('arkuzo-' + id, d.open ? '1' : '0'));
}
$('placeInput').addEventListener('change', () => vaultAct('/api/vault/settings', { changes: { defaultPlaceId: $('placeInput').value.trim() } }, 'Place saved'));
$('placeInput').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('placeInput').blur(); });
$('btnArrange').onclick = () => vaultAct('/api/vault/arrange', {}, 'Arranging client windows', 'good');
function renderServers(v) {
  const box = $('serverBox');
  if (box.contains(document.activeElement)) return;
  const servers = v.privateServers || [], used = (id) => (v.accounts || []).filter((a) => a.privateServerId === id).length;
  const mode = el('select', { style: 'width:180px' }, ...[['none', 'Off (public servers)'], ['shared', 'One server for all'], ['assigned', 'Per account']].map(([k, t]) => el('option', { value: k, text: t })));
  mode.value = v.settings.privateServerMode;
  mode.addEventListener('change', () => vaultAct('/api/vault/settings', { changes: { privateServerMode: mode.value } }, 'Private server mode saved'));
  const shared = el('select', { style: 'width:180px' }, el('option', { value: '', text: 'Choose a server' }), ...servers.map((sv) => el('option', { value: sv.id, text: sv.name })));
  shared.value = v.settings.sharedPrivateServerId || '';
  shared.addEventListener('change', () => vaultAct('/api/vault/settings', { changes: { sharedPrivateServerId: shared.value || null } }, 'Shared server saved'));
  const name = el('input', { class: 'inp', placeholder: 'Name', maxlength: 60 }), link = el('input', { class: 'inp', placeholder: 'Private server link (share or privateServerLinkCode link)' });
  const add = el('button', { class: 'btn accent sm', type: 'submit' }, icon('plus'), 'Add');
  box.replaceChildren(
    el('div', { class: 'field' }, el('span', { class: 'name', text: 'Mode' }), el('span', { class: 'hint2', text: 'Per account: pick the server in each account\'s editor.' }), el('div', { class: 'ctl' }, mode)),
    v.settings.privateServerMode === 'shared' ? el('div', { class: 'field' }, el('span', { class: 'name', text: 'Server' }), el('span', { class: 'hint2', text: 'Every account joins this one.' }), el('div', { class: 'ctl' }, shared)) : '',
    ...(servers.length ? servers.map((sv) => el('div', { class: 'srv-row' }, el('div', { style: 'min-width:0' }, el('div', { class: 'nm', style: 'font-weight:650', text: sv.name }), el('div', { class: 'sb', style: 'color:var(--muted);font-size:11.5px', text: `Place ${sv.placeId} · ${used(sv.id)} account${used(sv.id) === 1 ? '' : 's'}` })),
      el('span'), el('button', { class: 'btn ghost sm icon', title: 'Remove', onclick: () => { if (confirm(`Remove ${sv.name}?`)) vaultAct('/api/vault/servers/remove', { id: sv.id }, `${sv.name} removed`, 'neutral'); } }, icon('trash'))))
      : [el('div', { class: 'sb', style: 'color:var(--muted);font-size:12px;padding:8px 2px', text: 'No private servers yet. The link code is stored encrypted like the cookies.' })]),
    el('form', { class: 'srv-add', onsubmit: async (e) => { e.preventDefault(); add.disabled = true; const r = await vaultAct('/api/vault/servers/add', { name: name.value, link: link.value }, 'Private server added'); add.disabled = false; if (r) { name.value = ''; link.value = ''; } } }, name, link, add));
}
$('btnAddCookie').onclick = () => { $('addPanel').hidden = !$('addPanel').hidden; if (!$('addPanel').hidden) $('cookieInput').focus(); };
$('btnAddCancel').onclick = () => { $('cookieInput').value = ''; $('addPanel').hidden = true; };
$('addPanel').addEventListener('submit', async (e) => {
  e.preventDefault();
  const cookie = $('cookieInput').value; $('cookieInput').value = '';
  if (!cookie.trim()) return;
  const r = await vaultAct('/api/vault/add', { cookie }, null);
  if (r) { toast(r.updated ? `${r.displayName}: cookie refreshed` : `Added ${r.displayName} (@${r.username})`, 'good'); $('addPanel').hidden = true; }
});
$('btnSignIn').onclick = () => vaultAct('/api/vault/login', {}, 'Sign in to Roblox in the Edge window that opened', 'info');
$('btnCheckAll').onclick = () => vaultAct('/api/vault/check', {}, 'Checking every cookie with Roblox…', 'info');
$('btnFarmStart').onclick = () => vaultAct('/api/farm/start', {}, 'Farm started: launching accounts one by one', 'good');
$('btnFarmStop').onclick = () => vaultAct('/api/farm/stop', {}, 'Farm stopped: every client closed, nothing is relaunched', 'warning');
$('btnCloseAll').onclick = () => {
  const farm = !!(S.vault && S.vault.settings.farmRunning);
  if (confirm(farm ? 'Close every client? The farm keeps running and launches them again.' : 'Close every client?'))
    vaultAct('/api/farm/close-all', {}, farm ? 'Closing every client; the farm launches them again' : 'Closing every client', 'warning');
};

// ---------- Roblox builds (docs/roblox-versions.md) ----------
// weao.gg's data is untrusted: every string from it is shown as text (el(..., { text })), never as HTML or a link.
const RBX_VERSION = /^version-[0-9a-f]{16}$/;
const EXTYPE = { wexecutor: 'Executor', wexternal: 'External', mexecutor: 'Mac executor', aexecutor: 'Android executor', iexecutor: 'iOS executor' };
Object.assign(S, { rbx: null, rbxAt: 0, rbxPick: [], rbxPlan: null, rbxFilter: 'windows', rbxLastState: null });
const shortBuild = (ver) => ver ? String(ver).replace(/^version-/, '') : '–';
const maskHome = (path) => String(path || '').replace(/^[a-z]:\\users\\[^\\]+(?=\\|$)/i, '~');
async function loadRoblox(mode) {
  try {
    const r = await fetch('/api/roblox' + (mode === 'refresh' ? '?refresh=1' : mode === 'cached' ? '?cached=1' : ''), { cache: 'no-store' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    S.rbx = await r.json(); S.rbxAt = Date.now();
    const install = S.rbx.install || {};
    if (S.rbxLastState === 'running' && install.state && install.state !== 'running') toast(install.message || install.state, install.state === 'done' ? 'good' : install.state === 'cancelled' ? 'neutral' : 'critical');
    S.rbxLastState = install.state;
    renderRoblox();
    if (S.rbxPick.length && mode === 'refresh') planExploits();
  } catch (e) { if (mode !== 'cached') toast('Could not load Roblox builds: ' + e.message, 'critical'); }
}
async function rbxAct(path, body, done, level) {
  try { const r = await post(path, body); if (done) toast(done, level || 'good'); await loadRoblox('cached'); return r.result; }
  catch (e) { toast(e.message, 'critical'); await loadRoblox('cached'); return null; }
}
async function rbxInstall(version) {
  if (version !== 'latest' && !RBX_VERSION.test(version)) { toast('A Roblox build looks like version- followed by 16 hex digits (0-9, a-f)', 'warning'); return; }
  await rbxAct('/api/roblox/install', { version }, `Downloading ${version === 'latest' ? 'Roblox\'s current build' : version} from Roblox's CDN…`, 'info');
}
function renderRoblox() {
  const v = S.rbx; if (!v) return;
  // Redraw only when something changed: a redraw under the pointer would swallow a click.
  const sig = JSON.stringify([v, S.rbxFilter, S.query, S.rbxPick, S.rbxPlan]);
  if (sig === S.rbxSig) return;
  S.rbxSig = sig;
  const cat = v.catalog || {}, sel = v.selection || {}, eng = v.engine || {}, current = v.current;
  const pinned = sel.version && sel.version !== 'auto' ? sel.version : null;
  const complete = (v.builds || []).filter((b) => b.complete), has = (ver) => complete.some((b) => b.version === ver);
  const kept = (ver) => complete.some((b) => b.managed && b.version === ver); // In Arkuzo's folder, where Roblox's updater never deletes it.
  $('rbxTitle').textContent = pinned ? `Pinned: ${pinned}` : 'Auto: newest installed build';
  $('rbxTile').style.setProperty('--c', pinned ? (pinned === current ? '#34d399' : '#fbbf24') : '#38bdf8');
  const last = eng.selectedVersion ? ` Last launch choice: ${eng.selectedVersion}${eng.fallback ? ' (fallback)' : ''}.` : '';
  $('rbxSub').textContent = (pinned ? (has(pinned) ? 'Clients Arkuzo launches start this build, directly.' : 'This build is not installed: launches wait until it is.')
    : 'Clients start the build running clients use, otherwise the newest complete installed build.') + last;
  const windows = (cat.exploits || []).filter((x) => x.platform === 'Windows' && x.usable), updated = windows.filter((x) => x.updated).length;
  $('rbxStats').replaceChildren(...[['Roblox now', current ? shortBuild(current).slice(0, 8) : '–', current], ['Installed', String(complete.length), ''], ['Exploits updated', windows.length ? `${updated}/${windows.length}` : '–', '']]
    .map(([k, n, t]) => el('div', { title: t || null }, el('b', { class: k === 'Roblox now' ? 'mono' : 'num', text: n }), el('span', { text: k }))));
  const notes = [...(cat.errors || [])];
  if (!v.catalog) notes.push('Roblox and weao.gg have not been asked yet: press Refresh.');
  if (pinned && current && pinned !== current) notes.push(`The pinned build is not Roblox's current build (${current}). Roblox can refuse joins from an outdated build at any time ("out of date" errors); then install the current build or choose Auto.`);
  if (eng.problem) notes.push(eng.problem);
  const elsewhere = pinned ? (v.builds || []).filter((b) => b.version !== pinned).reduce((n, b) => n + (b.clients || 0), 0) : 0;
  if (elsewhere) notes.push(`${elsewhere} running client${elsewhere === 1 ? ' still uses' : 's still use'} another build. Each switches to the pinned build when it is launched again; Close all on the Accounts page switches them now.`);
  if (pinned && sel.launchMethod === 'protocol') notes.push('Launch method is Protocol: a pinned build still launches directly, because Roblox\'s launcher would update Roblox and ignore the pin.');
  if (pinned && v.provider && v.provider !== 'arkuzo') notes.push('Volt launches clients now: the pin applies when Arkuzo launches them (Accounts, Farm settings, Who launches clients).');
  $('rbxNotice').hidden = !notes.length;
  $('rbxNotice').replaceChildren(...notes.map((n, i) => el('div', { text: n, style: i ? 'margin-top:4px' : null })));
  $('navRoblox').hidden = !eng.problem;
  renderRobloxProgress(v.install || {});
  const running = (v.install || {}).state === 'running';
  $('btnRbxLatest').disabled = running || (!!current && kept(current));
  $('btnRbxLatest').title = current && kept(current) ? `Roblox's current build ${current} is in Arkuzo's folder` : 'Download Roblox\'s current Windows build from Roblox\'s CDN into Arkuzo\'s folder';
  renderRobloxBuilds(v, current, pinned);
  renderRobloxSettings(v, current, complete, running, kept);
  renderRobloxExploits(v, current, has);
  renderRobloxPick();
}
function renderRobloxProgress(p) {
  const box = $('rbxProgress'), recent = p.finishedAt && Date.now() / 1000 - p.finishedAt < 900;
  box.hidden = !(p.state === 'running' || (recent && p.state && p.state !== 'idle'));
  if (box.hidden) return;
  const pct = p.total ? Math.min(100, 100 * p.done / p.total) : 0;
  const level = p.state === 'done' ? 'good' : p.state === 'cancelled' ? 'neutral' : 'critical';
  box.replaceChildren(...[
    el('div', { class: 'bar' }, p.state === 'running' ? el('span', { class: 'spin' }) : pill(level, p.state === 'done' ? 'Installed' : p.state === 'cancelled' ? 'Cancelled' : 'Failed', true),
      el('b', { class: 'mono', text: p.version || '' }), el('span', { class: 't2', text: p.state === 'running' ? (p.phase || '') : (p.message || '') }), el('div', { class: 'spacer' }),
      p.total ? el('span', { class: 'num dim', text: `${fmtMB(p.done / 1048576)} of ${fmtMB(p.total / 1048576)}` }) : null,
      p.state === 'running' ? el('button', { class: 'btn ghost sm', onclick: () => rbxAct('/api/roblox/install/cancel', {}, 'Cancelling the install…', 'neutral') }, icon('x'), 'Cancel') : null),
    p.state === 'running' ? el('div', { class: 'meter well', role: 'img', 'aria-label': `${Math.round(pct)}% downloaded` }, el('i', { style: `width:${Math.max(2, pct).toFixed(1)}%` })) : null].filter(Boolean));
}
function renderRobloxBuilds(v, current, pinned) {
  const builds = (v.builds || []).slice().sort((a, b) => (Number(b.managed) - Number(a.managed)) || String(b.build || '').localeCompare(String(a.build || ''), undefined, { numeric: true }));
  $('rbxBuildsEmpty').hidden = builds.length > 0;
  $('rbxBuildsSub').textContent = 'Arkuzo\'s folder: ' + maskHome(v.root) + '\\Versions';
  $('rbxBuilds').replaceChildren(...builds.filter((b) => matches(b.version, b.source, b.build)).map((b) => {
    const tags = el('div', { class: 'tags' }, pill(b.managed ? 'info' : 'neutral', b.managed ? 'Arkuzo' : b.source, true));
    if (b.version === current) tags.append(pill('good', 'Roblox\'s current build', true));
    if (b.version === pinned && b.complete) tags.append(pill('warning', 'Pinned', true));
    if (!b.complete) tags.append(pill('critical', 'Incomplete', true));
    if (b.clients) tags.append(pill('good', `${b.clients} client${b.clients === 1 ? '' : 's'}`, true));
    const facts = [b.build, b.bytes != null ? fmtMB(b.bytes / 1048576) : null, b.managed ? null : 'not managed by Arkuzo'].filter(Boolean).join(' · ');
    const acts = el('div', { class: 'acts' });
    if (b.complete && b.version !== pinned) acts.append(el('button', { class: 'btn sm', title: b.managed ? 'The saver launches this build from now on' : 'Roblox deletes its own build folders when it updates: install the build into Arkuzo\'s folder to keep it', onclick: () => rbxAct('/api/roblox/select', { version: b.version }, `Pinned ${b.version}`) }, icon('check'), 'Pin'));
    if (b.managed) acts.append(el('button', { class: 'btn ghost sm icon', 'aria-label': 'Remove ' + b.version, disabled: !b.removable,
      title: b.removable ? 'Remove this build from Arkuzo\'s folder' : b.version === pinned ? 'Pinned: choose Auto or another build first' : 'A running client uses this build',
      onclick: () => { if (confirm(`Remove ${b.version} from Arkuzo's folder? Roblox's own installs are never touched.`)) rbxAct('/api/roblox/remove', { version: b.version }, `${b.version} removed`, 'neutral'); } }, icon('trash')));
    return el('div', { class: 'mrow brow' }, el('div', { style: 'min-width:0' }, el('div', { class: 'nm mono', text: b.version, title: maskHome(b.path) }), el('div', { class: 'sb', text: facts }), tags), acts);
  }));
}
function renderRobloxSettings(v, current, complete, running, kept) {
  const box = $('rbxSettings');
  if (box.contains(document.activeElement)) return; // Never redraw under the cursor.
  const sel = v.selection || {}, weao = (v.catalog || {}).weao || {};
  const versions = [...new Set(complete.map((b) => b.version))];
  const pick = el('select', {}, el('option', { value: 'auto', text: 'Auto (newest installed)' }), ...versions.map((ver) => el('option', { value: ver, text: ver + (ver === current ? ' · current' : '') })));
  if (sel.version && sel.version !== 'auto' && !versions.includes(sel.version)) pick.append(el('option', { value: sel.version, text: sel.version + ' · missing' }));
  pick.value = sel.version || 'auto';
  pick.addEventListener('change', () => rbxAct('/api/roblox/select', { version: pick.value }, pick.value === 'auto' ? 'Auto: the newest installed build' : `Pinned ${pick.value}`));
  const fallback = el('input', { type: 'checkbox' }); fallback.checked = !!sel.fallback;
  fallback.addEventListener('change', () => rbxAct('/api/vault/settings', { changes: { robloxVersionFallback: fallback.checked } }, fallback.checked ? 'A missing pin falls back to the newest build' : 'A missing pin stops launches'));
  const dir = el('input', { class: 'inp rbx-wide', value: sel.dir || '', placeholder: maskHome(v.defaultRoot), spellcheck: 'false', 'aria-label': 'Arkuzo\'s Roblox folder' });
  dir.addEventListener('change', () => rbxAct('/api/vault/settings', { changes: { robloxVersionsDir: dir.value.trim() } }, 'Folder saved'));
  const custom = el('input', { class: 'inp mono rbx-wide', placeholder: 'version-0123456789abcdef', spellcheck: 'false', maxlength: 24, 'aria-label': 'Roblox build to install' });
  const known = [['Current', current], ['Previous', (weao.past || {}).version], ['Upcoming, may never be released', (weao.future || {}).version]].filter(([, ver]) => ver && RBX_VERSION.test(ver));
  const row = (name, hint, ctl) => el('div', { class: 'field' }, el('span', { class: 'name', text: name }), el('span', { class: 'hint2', text: hint }), el('div', { class: 'ctl' }, ctl));
  const wide = (name, hint, ...kids) => el('div', { class: 'field', style: 'grid-template-columns:1fr' }, el('span', { class: 'name', text: name }), el('span', { class: 'hint2', text: hint }), ...kids);
  box.replaceChildren(
    row('Roblox build', 'A pinned build always launches directly: Roblox\'s launcher would update it.', pick),
    row('Fall back if missing', 'Off: launches wait while the pinned build is missing. On: the newest installed build starts instead.', el('label', { class: 'sw' }, fallback, el('span', { class: 'track' }))),
    wide('Install a build', 'Any Windows build Roblox still hosts, e.g. one an exploit needs. Downloaded from Roblox\'s CDN and checked against Roblox\'s checksums.',
      el('form', { class: 'rbx-custom', onsubmit: (e) => { e.preventDefault(); const val = custom.value.trim().toLowerCase(); rbxInstall(val.startsWith('version-') ? val : 'version-' + val); } },
        custom, el('button', { class: 'btn accent sm', type: 'submit', disabled: running }, icon('plus'), 'Install')),
      known.length ? el('div', { class: 'tags' }, ...known.map(([label, ver]) => el('button', { class: 'btn ghost sm', type: 'button', title: ver, disabled: running || kept(ver), onclick: () => rbxInstall(ver) },
        icon('plus'), `${label} · ${shortBuild(ver).slice(0, 8)}`))) : null),
    wide('Arkuzo\'s Roblox folder', `Builds go to <folder>\\Versions. Empty: ${maskHome(v.defaultRoot)}. Never inside Roblox's own folders.`, dir));
}
function renderRobloxExploits(v, current, has) {
  const cat = v.catalog || {}, all = cat.exploits || [], past = ((cat.weao || {}).past || {}).version;
  const list = all.filter((x) => (S.rbxFilter === 'all' || (x.platform === 'Windows' && (S.rbxFilter !== 'updated' || x.updated))) && matches(x.title, x.platform, x.type, x.robloxVersion, x.version));
  $('rbxExploitsEmpty').hidden = all.length > 0;
  $('rbxExploitSub').textContent = all.length ? `${all.length} listed on weao.gg${cat.fetchedAt ? ' · checked ' + fmtClock(cat.fetchedAt) : ''} · select the ones you use` : 'from weao.gg';
  S.rbxPick = S.rbxPick.filter((id) => all.some((x) => x.id === id && x.usable));
  $('rbxExploits').replaceChildren(...list.map((x) => {
    const tick = el('input', { type: 'checkbox', 'aria-label': 'Select ' + x.title, disabled: !x.usable });
    tick.checked = S.rbxPick.includes(x.id);
    tick.addEventListener('change', () => { S.rbxPick = tick.checked ? [...S.rbxPick, x.id] : S.rbxPick.filter((id) => id !== x.id); planExploits(); });
    const status = el('div', { class: 'tags' }, x.usable ? pill(x.updated ? 'good' : 'warning', x.updated ? 'Updated' : 'Not updated', true) : pill('neutral', x.reason || 'Not usable', true));
    if (x.detected) status.append(pill('serious', 'Detected', true));
    const where = x.robloxVersion === current ? 'Roblox\'s current build' : x.robloxVersion === past ? 'The previous build' : 'An older build';
    const build = x.robloxVersion
      ? el('div', { class: 'hide-sm', style: 'min-width:0' }, el('div', { class: 'mono', text: x.robloxVersion }), el('div', { class: 'sb', text: where + (has(x.robloxVersion) ? ' · installed' : '') }))
      : el('div', { class: 'hide-sm sb', text: x.listedVersion || '–' });
    const details = [EXTYPE[x.type] || x.type, x.free ? 'Free' : 'Paid', x.multiInstance ? 'Multi-instance' : null, x.unc != null ? `UNC ${x.unc}%` : null, x.sunc != null ? `sUNC ${x.sunc}%` : null, x.beta ? 'Beta' : null].filter(Boolean).join(' · ');
    return el('label', { class: 'mrow xrow' + (x.usable ? '' : ' off') }, tick, el('div', { style: 'min-width:0' }, el('div', { class: 'nm', text: x.title }), el('div', { class: 'sb', text: `${x.platform || '?'}${x.version ? ' · ' + x.version : ''}` })),
      status, build, el('div', { class: 'hide-sm', style: 'min-width:0' }, el('div', { class: 'sb', text: details }), el('div', { class: 'sb', text: x.updatedDate ? 'Updated ' + x.updatedDate : '' })));
  }));
}
let rbxPlanSeq = 0;
async function planExploits() {
  const seq = ++rbxPlanSeq;
  if (!S.rbxPick.length) { S.rbxPlan = null; renderRobloxPick(); return; }
  try { const r = await post('/api/roblox/exploits', { ids: S.rbxPick }); if (seq === rbxPlanSeq) S.rbxPlan = r.result; }
  catch (e) { if (seq === rbxPlanSeq) S.rbxPlan = { error: e.message }; }
  if (seq === rbxPlanSeq) renderRobloxPick();
}
function renderRobloxPick() {
  const box = $('rbxPick'), plan = S.rbxPlan, v = S.rbx || {};
  box.hidden = !plan || !S.rbxPick.length;
  if (box.hidden) return;
  if (plan.error) { box.replaceChildren(el('div', { text: plan.error })); return; }
  const installed = (v.builds || []).some((b) => b.version === plan.version && b.complete), pinnedNow = (v.selection || {}).version === plan.version;
  const kept = (v.builds || []).some((b) => b.version === plan.version && b.complete && b.managed);
  const names = plan.exploits || [];
  const rows = [plan.version
    ? el('div', { class: 'bar' }, tile('check', '#34d399', 'sm'), el('span', { text: `${names.join(', ')} ${names.length === 1 ? 'supports' : 'all support'}` }), el('b', { class: 'mono', text: plan.version }),
      plan.current ? pill('good', 'Roblox\'s current build', true) : pill('warning', 'Not Roblox\'s current build', true))
    : el('div', { class: 'bar' }, tile('warning', '#fbbf24', 'sm'), el('span', { text: plan.reason }))];
  for (const k of plan.conflict || []) rows.push(el('div', { class: 't2' }, el('span', { class: 'mono', text: k.version }), el('span', { text: ': ' + k.exploits.join(', ') })));
  for (const n of plan.notes || []) rows.push(el('div', { class: 't2', text: n }));
  if (plan.version) {
    rows.push(el('div', { class: 'bar' },
      kept ? null : el('button', { class: installed ? 'btn sm' : 'btn accent sm', disabled: (v.install || {}).state === 'running', onclick: () => rbxInstall(plan.version) }, icon('plus'), installed ? 'Install into Arkuzo\'s folder' : 'Install this build'),
      installed && !pinnedNow ? el('button', { class: 'btn accent sm', onclick: () => rbxAct('/api/roblox/select', { version: plan.version }, `Pinned ${plan.version}`) }, icon('check'), 'Launch this build') : null,
      el('span', { class: 't2', text: installed ? (pinnedNow ? 'Installed and pinned: the saver launches it.' : 'Installed. Pin it so the saver launches it.') : 'Then pin it so the saver launches it.' })));
  }
  box.replaceChildren(...rows);
}
document.querySelectorAll('.chip[data-rbx-filter]').forEach((b) => b.addEventListener('click', () => {
  S.rbxFilter = b.dataset.rbxFilter;
  document.querySelectorAll('.chip[data-rbx-filter]').forEach((y) => y.setAttribute('aria-pressed', String(y === b)));
  renderRoblox();
}));
$('btnRbxRefresh').onclick = () => loadRoblox('refresh');
$('btnRbxLatest').onclick = () => rbxInstall('latest');

// ---------- activity ----------
function feedItems(filter) {
  return S.events.filter((e) => (filter === 'all' || (filter === 'recovery' && e.category === 'recovery') ||
    (filter === 'problems' && (e.level === 'warning' || e.level === 'critical')) || (filter === 'saver' && (e.category === 'saver' || e.category === 'error'))) && matches(e.text));
}
function feedRow(e) { const [c, ic] = LEVEL[e.level === 'info' ? 'neutral' : e.level] || LEVEL.neutral; const svg = icon(ic); svg.style.color = c; return el('li', { class: e.level }, el('time', { class: 'num', text: fmtTime(e.t) }), svg, el('span', { class: 'txt', text: e.text })); }
function renderFeed() {
  const items = feedItems(S.filter).slice(-300).reverse();
  $('feedEmpty').hidden = items.length > 0;
  $('feed').hidden = items.length === 0;
  $('feed').replaceChildren(...items.map(feedRow));
  const recent = feedItems('all').slice(-10).reverse();
  $('ovFeed').replaceChildren(...(recent.length ? recent.map(feedRow) : [el('li', {}, el('span'), el('span'), el('span', { class: 'txt', text: 'No activity yet.' }))]));
  if (S.page === 'activity') S.seenEvents = S.events.length;
  const unseen = S.events.slice(S.seenEvents).filter((e) => e.level === 'critical').length;
  $('navActivity').hidden = !unseen; $('navActivity').textContent = String(unseen);
}
document.querySelectorAll('.chip[data-filter]').forEach((c) => c.addEventListener('click', () => {
  S.filter = c.dataset.filter;
  document.querySelectorAll('.chip[data-filter]').forEach((x) => x.setAttribute('aria-pressed', String(x === c)));
  renderFeed();
}));

// ---------- render & poll ----------
function renderAll() {
  const st = S.state; if (!st) return;
  renderSaver(st); renderIssues(st); renderRemote(st); renderKpis(st); renderClients(st); renderAccounts(st); renderFeed(); redrawCharts(); syncPrefs(st.prefs);
  const stale = isStale(st);
  for (const id of ['kpis', 'ovClientsCard', 'clientsCard', 'accountsCard']) $(id).classList.toggle('stale', stale);
  renderVault();
  if (S.page === 'roblox') renderRoblox();
}
// Each open window registers with its id; closing the last one quits the Control Center cleanly.
const PAGE_ID = Math.random().toString(36).slice(2, 12);
addEventListener('pagehide', () => {
  try { navigator.sendBeacon('/api/window-closed', new Blob([JSON.stringify({ page: PAGE_ID, token: TOKEN })], { type: 'text/plain' })); } catch (e) { /* best effort */ }
});
async function poll() {
  try {
    const since = S.history.length ? S.history[S.history.length - 1].t : 0;
    const r = await fetch(`/api/state?since=${since}&events=${S.lastEvent}&page=${PAGE_ID}&inst=${S.instance || ''}`, { cache: 'no-store' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const st = await r.json();
    $('offline').hidden = true;
    // A newer Control Center took over (update): load its page and token.
    if (S.instance && st.instance && st.instance !== S.instance) { location.reload(); return; }
    S.instance = st.instance;
    S.state = st;
    if (st.history.length) { S.history.push(...st.history); const cut = st.now - 3700; while (S.history.length && S.history[0].t < cut) S.history.shift(); }
    if (st.events.length) { S.events.push(...st.events); S.lastEvent = st.events[st.events.length - 1].id;
      if (S.events.length > 500) { const drop = S.events.length - 500; S.events.splice(0, drop); S.seenEvents = Math.max(0, S.seenEvents - drop); } }
    if (S.live) renderAll(); else renderSaver(st);
    if (S.page === 'accounts' || !S.vaultAt || Date.now() - S.vaultAt > 15000 || ['starting', 'waiting', 'reading'].includes(S.loginState)) loadVault();
    // The Roblox tab: local state only (no weao.gg request); also on other tabs while an install runs.
    if (S.rbxLastState === 'running' || (S.page === 'roblox' && Date.now() - S.rbxAt > 6000)) loadRoblox('cached');
    introProgress(st);
  } catch (e) { $('offline').hidden = false; }
  finally { setTimeout(poll, 2000); }
}

// ---------- intro (IntroAnimation) ----------
const introStart = Date.now();
let introClosing = false;
function finishIntro() { if (introClosing) return; introClosing = true; $('intro').classList.add('done'); store.set('arkuzo-intro', String(Date.now())); setTimeout(redrawCharts, 60); }
function introProgress(st) {
  if (introClosing) return;
  const hb = st.heartbeat, clients = (hb && hb.clients) || [], ok = hb && !isStale(st);
  $('stepCc').classList.add('ok'); $('introBar').style.width = '45%';
  $('stepSaver').classList.toggle('ok', !!ok); $('stepSaverR').textContent = ok ? `v${hb.version}` : (st.supervisor.state === 'stopped' ? 'stopped' : 'waiting');
  $('stepClients').classList.add('ok'); $('stepClientsR').textContent = `${clients.length} online`;
  $('introWelcome').replaceChildren('Welcome back', el('b', { text: clients.length ? ` · ${clients.length} clients online` : '' }));
  setTimeout(() => { $('introBar').style.width = '100%'; }, 250);
  if (!introHold) setTimeout(finishIntro, Math.max(700, 1800 - (Date.now() - introStart)));
}
const introHold = params.get('intro') === 'hold';
$('intro').addEventListener('click', finishIntro);
if (!introHold) {
  const last = Number(store.get('arkuzo-intro') || 0);
  if (params.get('intro') === '0' || Date.now() - last < 60000 || matchMedia('(prefers-reduced-motion: reduce)').matches) finishIntro();
  setTimeout(finishIntro, 4000);
}

// ---------- actions ----------
async function act(path, done, body, level) {
  try { const r = await post(path, body); toast(done || r.result, level || 'info'); setTimeout(poll, 300); }
  catch (e) { toast(e.message, 'critical'); }
}
$('btnStart').onclick = () => act('/api/saver/start', 'Saver starting…');
$('btnStop').onclick = () => { if (confirm('Stop the saver? Clients keep running but are no longer managed or recovered.')) act('/api/saver/stop', 'Saver stopped', undefined, 'warning'); };
$('btnRestart').onclick = () => act('/api/saver/restart', 'Saver restarting…');
$('btnTrim').onclick = () => act('/api/trim-now', 'Trim requested for every eligible client', undefined, 'good');
$('autopilot').onchange = (e) => act('/api/prefs', e.target.checked ? 'Autopilot on' : 'Autopilot off', { autopilot: e.target.checked }, e.target.checked ? 'good' : 'warning');

// ---------- settings ----------
const FIELDS = [
  ['Memory', 'containers', '#38bdf8', [
    ['settings', 'target_ram_mb', 'Working-set target', 'MB', 'Clients above this are trimmed. Advisory, not a cap.'],
    ['settings', 'trim_enabled', 'Trim working sets', '', 'Page out idle client memory periodically.'],
    ['settings', 'trim_every_sec', 'Trim interval', 's', 'Per client, staggered across the farm.'],
    ['settings', 'adaptive_trim', 'Adaptive trimming', '', 'Trim three times as often while physical RAM is scarce.'],
    ['settings', 'pressure_trim_available_percent', 'Low-RAM threshold', '% free', 'Below this much free RAM, adaptive trimming kicks in.'],
    ['settings', 'memory_priority', 'Memory priority', '', 'Lower values make Windows evict client pages first.'],
    ['settings', 'hard_limit', 'Hard working-set cap', 'restart', 'Enforces the target. Can cause stutter; off is recommended.'],
  ]],
  ['CPU', 'gear', '#22d3ee', [
    ['settings', 'priority', 'Process priority', '', 'Scheduling priority for every client.'],
    ['settings', 'cores_per_instance', 'Cores per client', '', 'Logical CPUs each client may use.'],
    ['settings', 'minimize_on_launch', 'Minimize clients', '', 'Minimized windows render less.'],
    ['settings', 'poll_ms', 'Poll interval', 'ms', 'How often the saver samples every client.'],
  ]],
  ['Health guard', 'coordinate-leak-protection', '#34d399', [
    ['health', 'enabled', 'Health guard', '', 'Recycle stuck, leaking or disconnected clients through Volt.'],
    ['health', 'private_limit_mb', 'Leak limit', 'MB', 'Private memory that marks a client as leaking.'],
    ['health', 'private_limit_sustain_sec', 'Leak confirmation', 's', 'How long the limit must hold before recycling.'],
    ['health', 'hang_timeout_sec', 'Hang timeout', 's', 'Unresponsive window time before recycling.'],
    ['health', 'farm_freeze_enabled', 'Farm freeze fast path', '', 'When most clients freeze together, recycle them early, one at a time.'],
    ['health', 'farm_freeze_confirm_sec', 'Farm freeze confirmation', 's', 'How long a farm-wide freeze must last before recycling.'],
    ['health', 'farm_freeze_spacing_sec', 'Farm freeze spacing', 's', 'Gap between recycles, so Volt relaunches one at a time.'],
    ['health', 'farm_freeze_remote_confirm_sec', 'Remote disconnect confirmation', 's', 'Shorter wait when the freeze began right after a remote-desktop disconnect.'],
    ['health', 'keep_display_awake', 'Keep display awake', '', 'Stops the display and PC from sleeping while clients run. The power plan is not changed.'],
    ['health', 'remote_hold_max_sec', 'RDP disconnect hold', 's', 'While an RDP session is disconnected, pause recovery this long at most. 0 turns it off.'],
    ['health', 'disconnect_timeout_sec', 'Disconnect grace', 's', 'Wait after a kick or disconnect.'],
    ['health', 'warmup_sec', 'Warmup', 's', 'Startup grace for each new client.'],
    ['health', 'pressure_percent', 'Commit pressure', '%', 'OS commit level that recycles the largest clients.'],
    ['health', 'cooldown_sec', 'Recycle cooldown', 's', 'Minimum spacing between recycles.'],
    ['health', 'max_recycles_per_hour', 'Recycles per hour', '', 'Farm-wide budget; prevents restart storms.'],
  ]],
  ['Recovery', 'death-coordinates', '#f472b6', [
    ['recovery', 'enabled', 'Account recovery', '', 'Verified Volt relaunch for recycled clients.'],
    ['recovery', 'restore_missing', 'Relaunch missing accounts', '', 'Volt only. Launch opted-in accounts that went idle in Volt (Arkuzo always relaunches them while the farm runs).'],
    ['recovery', 'ready_stable_sec', 'Readiness check', 's', 'Healthy time required before a restore counts.'],
    ['recovery', 'retry_base_sec', 'First retry after', 's', 'Volt only. Doubles with each failed attempt.'],
    ['recovery', 'retry_max_sec', 'Longest retry delay', 's', 'Volt only.'],
    ['recovery', 'retry_max_per_hour', 'Launches per hour', '', 'Volt only. Missing-account launch budget.'],
    ['recovery', 'abandon_after_retries', 'Quarantine after', 'tries', 'Volt only: Arkuzo never quarantines. A failing account stops blocking the others.'],
    ['recovery', 'abandon_after_sec', 'Quarantine after', 's', 'Volt only. Or after this long without a verified restore.'],
    ['recovery', 'quarantine_sec', 'Quarantine length', 's', 'Volt only. Then the account is retried automatically.'],
    ['settings', 'apply_graphics_flags', 'Low-graphics flags', 'restart', 'Minimum textures and MSAA for new clients.'],
    ['', 'config_lock', 'Config lock', '', 'Forces production guard values on load.'],
  ]],
];
const PRESET_INFO = { normal: ['Normal', 'Stable · 850 MB · 4 cores'], agressive: ['Aggressive', 'Farming · 600 MB · 2 cores'], extreme: ['Extreme', 'Density · 450 MB · 1 core'] };
function currentValue(section, key) {
  const cfg = S.config || {};
  if (!section) return cfg[key];
  const v = (cfg[section] || {})[key];
  if (v !== undefined) return v;
  if (section === 'settings') return ((S.presets[cfg.selected_preset] || S.presets.normal) || {})[key];
  const hb = S.state && S.state.heartbeat;
  return hb && hb[section] ? hb[section][key] : undefined;
}
function editedValue(section, key) { const k = section + '.' + key; return k in S.edits ? S.edits[k] : currentValue(section, key); }
async function loadSettings() {
  try {
    const r = await fetch('/api/config', { cache: 'no-store' }).then((x) => x.json());
    S.config = r.config; S.presets = r.presets; S.schema = r.schema; S.restartKeys = r.restartKeys; S.edits = {};
  } catch (e) { toast('Could not load settings', 'critical'); return; }
  if (!S.config) { toast('data/config.json is missing or invalid', 'critical'); return; }
  buildForm(); updateSaveBar();
}
function buildForm() {
  const presets = $('presets'); presets.replaceChildren();
  const selected = S.edits['.selected_preset'] ?? (S.config || {}).selected_preset;
  for (const [name, [title, sub]] of Object.entries(PRESET_INFO)) presets.append(el('button', { type: 'button', class: 'preset', 'aria-pressed': String(selected === name), onclick: () => applyPreset(name) }, el('b', { text: title }), el('span', { text: sub })));
  const form = $('settingsForm'); form.replaceChildren();
  for (const [title, iconName, color, fields] of FIELDS) {
    const body = el('div', { class: 'card-b' });
    for (const [section, key, label, unit, hint] of fields) {
      const rule = section ? (S.schema[section] || {})[key] : (key === 'config_lock' ? ['bool'] : null);
      if (!rule) continue;
      const id = `f-${section}-${key}`, value = editedValue(section, key);
      let ctl;
      if (rule[0] === 'bool') {
        const input = el('input', { type: 'checkbox', id }); input.checked = !!value;
        input.addEventListener('change', () => edit(section, key, input.checked, input));
        ctl = el('label', { class: 'sw' }, input, el('span', { class: 'track' }));
      } else if (rule[0] === 'enum') {
        const select = el('select', { id }, rule[1].map((o) => el('option', { value: o, text: o.replace(/([a-z])([A-Z])/g, '$1 $2') })));
        select.value = value ?? rule[1][0];
        select.addEventListener('change', () => edit(section, key, select.value, select));
        ctl = select;
      } else {
        const input = el('input', { type: 'number', id, min: rule[1], max: rule[2], step: 1, inputmode: 'numeric' });
        input.value = value ?? '';
        input.addEventListener('input', () => {
          const n = Number(input.value), ok = input.value !== '' && Number.isInteger(n) && n >= rule[1] && n <= rule[2];
          input.closest('.field').classList.toggle('invalid', !ok);
          if (ok) edit(section, key, n, input); else { $('formError').textContent = `${label}: ${rule[1]}–${rule[2]}`; updateSaveBar(); }
        });
        ctl = input;
      }
      body.append(el('div', { class: 'field' + ((section + '.' + key) in S.edits ? ' dirty' : '') },
        el('label', { class: 'name', for: id, text: label }), el('span', { class: 'hint2', text: hint || '' }), el('div', { class: 'ctl' }, ctl, el('span', { class: 'unit', text: unit || '' }))));
    }
    form.append(el('article', { class: 'card' }, el('div', { class: 'pane-h' }, tile(iconName, color, 'lg'), el('div', {}, el('div', { class: 'ttl', text: title }), el('div', { class: 'st', text: `${fields.length} settings` }))), el('div', { class: 'divider' }), body));
  }
}
function edit(section, key, value, input) {
  const k = section + '.' + key;
  if (JSON.stringify(value) === JSON.stringify(currentValue(section, key))) delete S.edits[k]; else S.edits[k] = value;
  if (input) input.closest('.field').classList.toggle('dirty', k in S.edits);
  updateSaveBar();
}
function updateSaveBar() {
  const n = Object.keys(S.edits).length, invalid = !!document.querySelector('.field.invalid');
  $('savebar').hidden = !n && !invalid;
  $('dirtyCount').textContent = n ? `${n} unsaved change${n === 1 ? '' : 's'}` : '';
  if (!invalid) $('formError').textContent = '';
  $('btnSave').disabled = !n || invalid;
}
function applyPreset(name) { for (const [key, value] of Object.entries(S.presets[name] || {})) edit('settings', key, value); edit('', 'selected_preset', name); buildForm(); updateSaveBar(); }
$('btnDiscard').onclick = () => { S.edits = {}; buildForm(); updateSaveBar(); };
$('btnSave').onclick = async () => {
  const changes = {};
  for (const [k, v] of Object.entries(S.edits)) { const [section, key] = k.split('.'); if (!section) changes[key] = v; else (changes[section] = changes[section] || {})[key] = v; }
  $('btnSave').disabled = true;
  try {
    const r = await post('/api/config', { changes });
    S.config = r.config; S.edits = {}; buildForm(); updateSaveBar();
    toast(r.restartRequired && r.restartRequired.length ? 'Saved. Restart the saver to apply: ' + r.restartRequired.join(', ') : 'Saved. Applying to the running saver…', 'good');
  } catch (e) { $('formError').textContent = e.message; $('btnSave').disabled = false; }
};
function syncPrefs(p) { if (!p) return; for (const [id, key] of [['pAutopilot', 'autopilot'], ['pLaunch', 'startSaverOnLaunch'], ['pWindows', 'startWithWindows']]) if (document.activeElement !== $(id)) $(id).checked = !!p[key]; }
for (const [id, key] of [['pAutopilot', 'autopilot'], ['pLaunch', 'startSaverOnLaunch'], ['pWindows', 'startWithWindows']]) $(id).addEventListener('change', () => act('/api/prefs', 'Saved', { [key]: $(id).checked }, 'good'));
function renderRemote(st) {
  const r = st.heartbeat && st.heartbeat.remoteSession;
  if (!r) return;
  const crd = r.chromeRemoteDesktop, parts = [];
  if (crd) parts.push(crd.connected ? 'Chrome Remote Desktop connected' : 'Chrome Remote Desktop not connected');
  parts.push(r.protocol === 'rdp' ? `RDP session ${r.sessionState}` : r.onConsole ? 'console session' : `session ${r.sessionState}`);
  if (r.locked) parts.push('locked');
  if (r.display) parts.push(r.display.split('x').slice(0, 2).join('×') + (r.display.split('x')[2] ? ` @ ${r.display.split('x')[2]} Hz` : ''));
  if (r.keepAwake) parts.push('display kept awake');
  if (r.hold) parts.push('recovery paused');
  $('remoteState').textContent = parts.join(' · ');
  $('btnLeaveRdp').disabled = !(r.protocol === 'rdp' && r.sessionState === 'active');
}
$('btnLeaveRdp').onclick = () => {
  if (!confirm('Move this Remote Desktop session to the PC’s own screen? The Remote Desktop window closes and the PC stays signed in and unlocked on its monitor until you lock it there.')) return;
  act('/api/remote/leave', 'Session moved to the console', {}, 'good');
};
const goodbye = (text) => document.body.replaceChildren(el('div', { style: 'height:100vh;display:grid;place-items:center;color:#7e879a;font-weight:600', text }));
$('btnQuit').onclick = async () => { await post('/api/quit', {}).catch(() => {}); goodbye('Control Center closed. The saver keeps running; you can close this window.'); };
$('btnQuitAll').onclick = async () => { if (!confirm('Stop the saver and quit? Clients keep running but are no longer managed.')) return; await post('/api/quit', { stopSaver: true }).catch(() => {}); goodbye('Saver stopped and Control Center closed. You can close this window.'); };

showPage(PAGES[params.get('page')] ? params.get('page') : PAGES[store.get('arkuzo-page')] ? store.get('arkuzo-page') : 'overview');
poll();
