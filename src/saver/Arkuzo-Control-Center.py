"""Arkuzo Control Center: local dashboard and saver supervisor.

Serves a single-page UI on 127.0.0.1 only. It reads the saver heartbeat
(runtime-status.json), tails the diagnostic log, edits config.json with the
same validation the engine applies, and keeps the saver running (autopilot)
with bounded, backed-off restarts. Standard library only.

It never reads cookies, tickets or command lines, never writes Volt state and
never touches Roblox processes: process control stays inside the saver engine.
"""
from __future__ import annotations

import argparse
import collections
import ctypes
import datetime as dt
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from ctypes import wintypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP_ID = 'arkuzo-control-center'
DEFAULT_PORT = 48650
RUNTIME = Path(__file__).resolve().parent
SAVER_SCRIPT = RUNTIME / 'Arkuzo-Memory-Saver.ps1'
UI_FILE = RUNTIME / 'Arkuzo-Control-Center.html'
GUID = re.compile(r'\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z')
RUN_KEY = r'Software\Microsoft\Windows\CurrentVersion\Run'
RUN_VALUE = 'ArkuzoControlCenter'

# Heartbeat is written every 2s; recovery IO can block the loop for tens of
# seconds, so only a long silence from a live, verified saver counts as a hang.
HEARTBEAT_FRESH_SEC = 15
HANG_SEC = 120
START_GRACE_SEC = 150
STABLE_RESET_SEC = 600
CRASH_LOOP_WINDOW_SEC = 1800
CRASH_LOOP_LIMIT = 8

# Mirrors Get-ArkuzoPresets in the engine; tests cross-check the two.
PRESETS = {
    'normal': {'target_ram_mb': 850, 'trim_enabled': True, 'trim_every_sec': 120, 'priority': 'BelowNormal', 'cores_per_instance': 4,
               'hard_limit': False, 'poll_ms': 500, 'minimize_on_launch': False, 'apply_graphics_flags': False,
               'memory_priority': 'BelowNormal', 'adaptive_trim': True, 'pressure_trim_available_percent': 15},
    'agressive': {'target_ram_mb': 600, 'trim_enabled': True, 'trim_every_sec': 60, 'priority': 'BelowNormal', 'cores_per_instance': 2,
                  'hard_limit': False, 'poll_ms': 350, 'minimize_on_launch': False, 'apply_graphics_flags': False,
                  'memory_priority': 'Low', 'adaptive_trim': True, 'pressure_trim_available_percent': 20},
    'extreme': {'target_ram_mb': 450, 'trim_enabled': True, 'trim_every_sec': 30, 'priority': 'BelowNormal', 'cores_per_instance': 1,
                'hard_limit': False, 'poll_ms': 250, 'minimize_on_launch': False, 'apply_graphics_flags': False,
                'memory_priority': 'VeryLow', 'adaptive_trim': True, 'pressure_trim_available_percent': 25},
}

# (kind, min, max) for numbers; ('bool',) and ('enum', values) otherwise. Ranges
# mirror the engine validators so a saved file is never rejected on reload.
SCHEMA = {
    'settings': {
        'target_ram_mb': ('int', 128, 32768), 'trim_every_sec': ('int', 1, 120), 'cores_per_instance': ('int', 1, 64),
        'poll_ms': ('int', 250, 10000), 'pressure_trim_available_percent': ('int', 5, 60),
        'trim_enabled': ('bool',), 'adaptive_trim': ('bool',), 'hard_limit': ('bool',), 'minimize_on_launch': ('bool',),
        'apply_graphics_flags': ('bool',),
        'priority': ('enum', ('Idle', 'BelowNormal', 'Normal')),
        'memory_priority': ('enum', ('VeryLow', 'Low', 'Medium', 'BelowNormal', 'Normal')),
    },
    'health': {
        'enabled': ('bool',), 'private_limit_mb': ('int', 1024, 16384), 'hang_timeout_sec': ('int', 60, 900),
        'warmup_sec': ('int', 60, 900), 'pressure_percent': ('int', 60, 98), 'pressure_min_private_mb': ('int', 1024, 16384),
        'cooldown_sec': ('int', 30, 300), 'max_recycles_per_hour': ('int', 1, 60), 'trim_spacing_sec': ('int', 1, 30),
        'startup_error_timeout_sec': ('int', 0, 300), 'disconnect_timeout_sec': ('int', 0, 300),
        'private_limit_sustain_sec': ('int', 0, 300),
    },
    'recovery': {
        'enabled': ('bool',), 'restore_missing': ('bool',), 'restore_wait_sec': ('int', 90, 900),
        'relaunch_delay_sec': ('int', 30, 120), 'retry_base_sec': ('int', 90, 900), 'retry_max_sec': ('int', 180, 3600),
        'retry_max_per_hour': ('int', 1, 500), 'ready_stable_sec': ('int', 30, 300),
        'abandon_after_retries': ('int', 1, 100), 'abandon_after_sec': ('int', 900, 86400), 'quarantine_sec': ('int', 0, 86400),
    },
}
# The engine's -Mode ValidateSet only accepts real preset names.
TOP_LEVEL = {'selected_preset': ('enum', ('normal', 'agressive', 'extreme')), 'config_lock': ('bool',)}
# Everything else in settings/health/recovery is applied by the running saver.
RESTART_KEYS = {'hard_limit', 'apply_graphics_flags'}

# Diagnostic events worth showing, with their feed category.
EVENT_KINDS = {
    'SESSION_START': 'saver', 'SESSION_STOP': 'saver', 'SAVER_FATAL_ERROR': 'error',
    'CLIENT_START': 'client', 'CLIENT_EXIT': 'client', 'CLIENT_STATE_CHANGED': 'client',
    'CLIENT_LOG_DISCONNECT_DETECTED': 'recovery', 'EXECUTOR_KICK_SIGNAL_TRIGGERED': 'recovery',
    'RECOVERY_REQUESTED': 'recovery', 'CLIENT_CLOSED_FOR_RECOVERY': 'recovery', 'ACCOUNT_RESTORED_VERIFIED': 'recovery',
    'VOLT_MISSING_LAUNCH_REQUEST': 'recovery', 'VOLT_MISSING_LAUNCH_RESULT': 'recovery', 'MISSING_ACCOUNT_DETECTED': 'recovery',
    'RECOVERY_OUTCOME_STATE': 'recovery', 'RECOVERY_QUARANTINED': 'recovery', 'RECOVERY_CANCELLED_BY_POLICY': 'recovery',
    'LAUNCH_REFUSED_DEAD_COOKIE': 'recovery', 'COOKIE_ACCOUNT_SUSPENDED': 'recovery', 'COOKIE_ACCOUNT_RESUMED': 'recovery',
    'WARNING': 'warning', 'CONFIG_RELOADED': 'saver', 'SETTINGS_APPLIED_LIVE': 'saver', 'TRIM_NOW_REQUESTED': 'memory',
    'ORPHAN_CRASH_HANDLER_CLOSED': 'client', 'SYSTEM_RESOURCE_EXHAUSTION': 'error',
}  # Individual trims would flood the feed; the heartbeat carries their count.


# ---------------------------------------------------------------- utilities
def parse_utc(value) -> float | None:
    """Parse .NET round-trip timestamps (7 fractional digits) to epoch seconds."""
    if not isinstance(value, str):
        return None
    m = re.match(r'\A(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)?\Z', value.strip())
    if not m:
        return None
    base = dt.datetime.fromisoformat(m.group(1))
    frac = float('0.' + m.group(2)) if m.group(2) else 0.0
    zone = m.group(3) or 'Z'
    if zone == 'Z':
        tz = dt.timezone.utc
    else:
        sign = 1 if zone[0] == '+' else -1
        tz = dt.timezone(sign * dt.timedelta(hours=int(zone[1:3]), minutes=int(zone[4:6])))
    return base.replace(tzinfo=tz).timestamp() + frac


def read_json(path: Path):
    for _ in range(3):
        try:
            return json.loads(path.read_text(encoding='utf-8-sig'))
        except FileNotFoundError:
            return None
        except (OSError, ValueError):
            time.sleep(0.05)  # Atomic replace in progress or a transient lock.
    return None


def write_json_atomic(path: Path, value) -> None:
    temp = path.with_name(path.name + f'.{os.getpid()}.tmp')
    temp.write_text(json.dumps(value, indent=4, ensure_ascii=False), encoding='utf-8')
    for attempt in range(5):
        try:
            os.replace(temp, path)
            return
        except PermissionError:
            if attempt == 4:
                temp.unlink(missing_ok=True)
                raise
            time.sleep(0.06)


# ------------------------------------------------------------ process probes
class _Win32:
    """Minimal kernel32 helpers. No-ops off Windows so tests can import this."""

    PROCESS_TERMINATE = 0x0001
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    STILL_ACTIVE = 259

    def __init__(self):
        self.k = None
        if os.name == 'nt':
            k = ctypes.WinDLL('kernel32', use_last_error=True)
            k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            k.OpenProcess.restype = wintypes.HANDLE
            k.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
            k.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
            k.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
            k.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
            k.CloseHandle.argtypes = [wintypes.HANDLE]
            self.k = k

    def identity(self, pid: int):
        """Return (start .NET ticks, image name) for a live process, else None."""
        if not self.k or pid <= 0:
            return None
        h = self.k.OpenProcess(self.PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
        if not h:
            return None
        try:
            code = wintypes.DWORD()
            if not self.k.GetExitCodeProcess(h, ctypes.byref(code)) or code.value != self.STILL_ACTIVE:
                return None
            times = [wintypes.FILETIME() for _ in range(4)]
            if not self.k.GetProcessTimes(h, *(ctypes.byref(x) for x in times)):
                return None
            ticks = (times[0].dwHighDateTime << 32) + times[0].dwLowDateTime + 504911232000000000
            size = wintypes.DWORD(1024)
            buf = ctypes.create_unicode_buffer(1024)
            name = Path(buf.value).name.lower() if self.k.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)) else ''
            return ticks, name
        finally:
            self.k.CloseHandle(h)

    def terminate(self, pid: int, start_ticks: int) -> bool:
        """Terminate only the exact process generation the heartbeat named."""
        ident = self.identity(pid)
        if not ident or ident[0] != start_ticks or ident[1] not in ('powershell.exe', 'pwsh.exe'):
            return False
        h = self.k.OpenProcess(self.PROCESS_TERMINATE, False, int(pid))
        if not h:
            return False
        try:
            return bool(self.k.TerminateProcess(h, 1))
        finally:
            self.k.CloseHandle(h)


WIN32 = _Win32()


# ------------------------------------------------------------- config edits
class ConfigError(ValueError):
    pass


def validate_value(rule, value, name):
    kind = rule[0]
    if kind == 'bool':
        if not isinstance(value, bool):
            raise ConfigError(f'{name} must be true or false')
    elif kind == 'int':
        if isinstance(value, bool) or not isinstance(value, (int, float)) or float(value) != int(value):
            raise ConfigError(f'{name} must be a whole number')
        if not rule[1] <= value <= rule[2]:
            raise ConfigError(f'{name} must be between {rule[1]} and {rule[2]}')
        value = int(value)
    elif kind == 'enum':
        if value not in rule[1]:
            raise ConfigError(f'{name} must be one of: ' + ', '.join(rule[1]))
    return value


def apply_config_changes(config: dict, changes: dict) -> tuple[dict, list[str]]:
    """Merge validated changes into a copy of config; unknown keys are refused.

    Returns the new config and the changed keys that need a saver restart.
    """
    if not isinstance(config, dict) or not isinstance(changes, dict):
        raise ConfigError('Configuration must be a JSON object')
    merged = json.loads(json.dumps(config))
    restart = []
    for key, value in changes.items():
        if key in TOP_LEVEL:
            merged[key] = validate_value(TOP_LEVEL[key], value, key)
            continue
        if key not in SCHEMA or not isinstance(value, dict):
            raise ConfigError(f'Unknown configuration section: {key}')
        section = merged.setdefault(key, {})
        if not isinstance(section, dict):
            raise ConfigError(f'{key} must be an object')
        for name, item in value.items():
            if name not in SCHEMA[key]:
                raise ConfigError(f'Unknown setting: {key}.{name}')
            item = validate_value(SCHEMA[key][name], item, f'{key}.{name}')
            if section.get(name) != item and name in RESTART_KEYS:
                restart.append(name)
            section[name] = item
    recovery = merged.get('recovery') or {}
    base, top = recovery.get('retry_base_sec', 90), recovery.get('retry_max_sec', 900)
    if isinstance(base, int) and isinstance(top, int) and top < base:
        raise ConfigError('recovery.retry_max_sec must be at least retry_base_sec')
    ids = recovery.get('excluded_account_ids', [])
    if not isinstance(ids, list) or any(not isinstance(i, str) or not GUID.match(i) for i in ids):
        raise ConfigError('recovery.excluded_account_ids must be account GUIDs')
    return merged, restart


def set_account_recovery(config: dict, account_id: str, enabled: bool) -> dict:
    if not GUID.match(account_id or ''):
        raise ConfigError('Invalid account identifier')
    merged = json.loads(json.dumps(config))
    recovery = merged.setdefault('recovery', {})
    ids = [i for i in recovery.get('excluded_account_ids') or [] if i.lower() != account_id.lower()]
    if not enabled:
        ids.append(account_id)
    recovery['excluded_account_ids'] = ids
    return merged


# ------------------------------------------------------------- log feed
def summarize_event(record: dict, names: dict) -> dict | None:
    kind = record.get('event')
    category = EVENT_KINDS.get(kind)
    if not category:
        return None
    data = record.get('data') if isinstance(record.get('data'), dict) else {}

    def who():
        account = data.get('accountId')
        if account and account in names:
            return names[account]
        if data.get('username'):
            return str(data['username'])
        if data.get('pid'):
            return f"PID {data['pid']}"
        return 'an account'

    level = {'error': 'critical', 'warning': 'warning'}.get(category, 'info')
    text = None
    if kind == 'SESSION_START':
        text = f"Saver {data.get('version', '')} started ({data.get('mode', '')} profile)"
    elif kind == 'SESSION_STOP':
        text = f"Saver stopped after {round(float(data.get('uptimeSeconds') or 0) / 60)} min, {data.get('trims', 0)} trims"
    elif kind == 'SAVER_FATAL_ERROR':
        text = f"Saver crashed ({data.get('exceptionType', 'error')} at line {data.get('line', '?')})"
    elif kind == 'CLIENT_START':
        text = f"Client PID {data.get('pid')} joined slot {int(data.get('slot') or 0) + 1}"
    elif kind == 'CLIENT_EXIT':
        text = f"Client PID {data.get('pid')} exited" + (' (closed for recovery)' if data.get('recoveryRequested') else '')
    elif kind == 'CLIENT_STATE_CHANGED':
        sample = data.get('sample') if isinstance(data.get('sample'), dict) else {}
        state = sample.get('state')
        if state not in ('STUCK CLIENT', 'LEAK GUARD', 'DISCONNECTED', 'VOLT STARTUP ERROR', 'CRITICAL COMMIT', 'NOT RESPONDING', 'COMMIT PRESSURE'):
            return None  # Ordinary transitions would drown the feed.
        level = 'warning'
        text = f"{sample.get('account') or 'PID ' + str(sample.get('pid'))}: {state.lower()}"
    elif kind == 'CLIENT_LOG_DISCONNECT_DETECTED':
        level, text = 'warning', f"PID {data.get('pid')} disconnected: {data.get('reason', '')}"
    elif kind == 'EXECUTOR_KICK_SIGNAL_TRIGGERED':
        level, text = 'warning', f"{who()} kicked: {data.get('reason', '')}"
    elif kind == 'RECOVERY_REQUESTED':
        level, text = 'warning', f"Recovering {who()} ({str(data.get('reason', '')).replace('_', ' ').lower()})"
    elif kind == 'CLIENT_CLOSED_FOR_RECOVERY':
        text = f"Closed {who()} for Volt to relaunch"
    elif kind == 'ACCOUNT_RESTORED_VERIFIED':
        level, text = 'good', f"{who()} restored and back in game"
    elif kind == 'MISSING_ACCOUNT_DETECTED':
        level, text = 'warning', f"{who()} is missing; relaunch queued"
    elif kind == 'VOLT_MISSING_LAUNCH_REQUEST':
        text = f"Asked Volt to launch {who()} (attempt {data.get('attempt')})"
    elif kind == 'VOLT_MISSING_LAUNCH_RESULT':
        if data.get('requestAccepted'):
            return None
        level, text = 'warning', f"Volt refused the launch of {who()}"
    elif kind == 'RECOVERY_OUTCOME_STATE':
        if data.get('status') not in ('Blocked',):
            return None
        level, text = 'warning', f"Recovery of {who()} is blocked"
    elif kind == 'RECOVERY_QUARANTINED':
        level, text = 'critical', f"{who()} quarantined after {data.get('retryCount')} failed recoveries"
    elif kind == 'RECOVERY_CANCELLED_BY_POLICY':
        text = f"Recovery of {who()} cancelled: {data.get('note', '')}"
    elif kind == 'LAUNCH_REFUSED_DEAD_COOKIE':
        level, text = 'warning', f"{who()} not launched: dead cookie"
    elif kind == 'COOKIE_ACCOUNT_SUSPENDED':
        level, text = 'critical', f"{who()} paused: cookie dead"
    elif kind == 'COOKIE_ACCOUNT_RESUMED':
        level, text = 'good', f"{who()} cookie valid again; resumed"
    elif kind == 'WARNING':
        text = str(data.get('message', ''))
        if not text:
            return None
    elif kind == 'CONFIG_RELOADED':
        text = 'Configuration reloaded'
    elif kind == 'SETTINGS_APPLIED_LIVE':
        text = 'Applied live: ' + ', '.join(str(x) for x in data.get('changed') or [])
    elif kind == 'TRIM_NOW_REQUESTED':
        text = f"Trim requested for {data.get('clients', 0)} clients"
    elif kind == 'ORPHAN_CRASH_HANDLER_CLOSED':
        text = f"Closed orphaned crash handler PID {data.get('pid')}"
    elif kind == 'SYSTEM_RESOURCE_EXHAUSTION':
        text = 'Windows reported resource exhaustion (event 2004)'
    if not text:
        return None
    return {'t': parse_utc(record.get('time')) or time.time(), 'kind': kind, 'category': category, 'level': level, 'text': text[:240]}


class LogTail:
    """Follows the newest diagnostic log; survives rotation and new sessions."""

    def __init__(self, directory: Path, limit: int = 300):
        self.directory = directory
        self.events = collections.deque(maxlen=limit)
        self.path = None
        self.offset = 0
        self.seq = 0
        self.lock = threading.Lock()

    def add(self, event: dict):
        with self.lock:
            self.seq += 1
            event['id'] = self.seq
            self.events.append(event)

    def poll(self, names: dict):
        try:
            logs = sorted(self.directory.glob('Arkuzo-*.log'), key=lambda p: p.stat().st_mtime)
        except OSError:
            return
        if not logs:
            return
        newest = logs[-1]
        if newest != self.path:
            self.path = newest
            try:
                self.offset = max(0, newest.stat().st_size - 262144)  # Recent history only.
            except OSError:
                return
        try:
            with open(self.path, 'rb') as f:
                size = os.fstat(f.fileno()).st_size
                if size < self.offset:
                    self.offset = 0
                f.seek(self.offset)
                chunk = f.read(min(size - self.offset, 1048576))
        except OSError:
            return
        end = chunk.rfind(b'\n')
        if end < 0:
            return
        self.offset += end + 1
        for line in chunk[:end].split(b'\n'):
            try:
                record = json.loads(line.decode('utf-8', 'replace'))
            except ValueError:
                continue
            event = summarize_event(record, names) if isinstance(record, dict) else None
            if event:
                self.add(event)

    def since(self, seq: int) -> list:
        with self.lock:
            return [e for e in self.events if e['id'] > seq]


# ------------------------------------------------------------- supervisor
def restart_delay(consecutive_failures: int) -> int:
    return int(min(120, 5 * 2 ** max(0, consecutive_failures - 1)))


class Supervisor:
    """Keeps exactly one saver alive. The saver's own mutex stays authoritative."""

    def __init__(self, data: Path, prefs: dict, feed: LogTail, launcher=None):
        self.data = data
        self.prefs = prefs
        self.feed = feed
        self.launcher = launcher or self._launch
        self.proc = None
        self.proc_started = 0.0
        self.state = 'stopped'
        self.message = 'Saver is not running.'
        self.operator_stopped = False
        self.initial_start = bool(prefs.get('startSaverOnLaunch', True))
        self.failures = 0
        self.crashes = collections.deque(maxlen=CRASH_LOOP_LIMIT)
        self.next_restart = 0.0
        self.crash_loop = False
        self.last_exit = None
        self.lock = threading.RLock()

    # -- launching
    def _launch(self):
        log_dir = self.data / 'Arkuzo-Logs'
        log_dir.mkdir(parents=True, exist_ok=True)
        console = log_dir / 'saver-console.log'
        if console.exists():
            shutil.copyfile(console, log_dir / 'saver-console.previous.log')
        out = open(console, 'wb')
        flags = 0x08000000 | 0x00000200  # CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP
        try:
            return subprocess.Popen(
                ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(SAVER_SCRIPT),
                 '-Headless', '-DataDirectory', str(self.data)],
                stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, creationflags=flags if os.name == 'nt' else 0)
        finally:
            out.close()

    def _clear_stop_signals(self):
        for name in ('controller.stop', 'stop.signal'):
            try:
                (self.data / name).unlink()
            except FileNotFoundError:
                pass

    def external(self, heartbeat, now: float):
        """A fresh heartbeat from a live saver this supervisor did not start."""
        if not isinstance(heartbeat, dict):
            return None
        pid, ticks = int(heartbeat.get('pid') or 0), int(heartbeat.get('startTicks') or 0)
        if self.proc and pid == self.proc.pid:
            return None
        ident = WIN32.identity(pid)
        if not ident or ident[0] != ticks:
            return None
        updated = parse_utc(heartbeat.get('updatedUtc'))
        return {'pid': pid, 'ticks': ticks, 'age': (now - updated) if updated else None}

    def start(self, reason='operator'):
        with self.lock:
            self.operator_stopped = False
            self.crash_loop = False
            if self.proc and self.proc.poll() is None:
                return 'already running'
            # A second saver would only fail on the controller mutex and look like a crash.
            if self.external(read_json(self.data / 'runtime-status.json'), time.time()):
                return 'already running'
            self._clear_stop_signals()
            self.proc = self.launcher()
            self.proc_started = time.time()
            self.state = 'starting'
            self.message = 'Saver starting...'
            text = {'autopilot': 'Autopilot restarted the saver', 'launch': 'Saver started with the Control Center'}.get(reason, 'Saver started from the Control Center')
            self.feed.add({'t': time.time(), 'kind': 'SUPERVISOR', 'category': 'saver', 'level': 'info', 'text': text})
            return 'started'

    def stop(self, wait_sec=25.0):
        with self.lock:
            self.operator_stopped = True
            try:
                (self.data / 'controller.stop').write_text('operator stop', encoding='ascii')
            except OSError:
                pass
            proc = self.proc
        heartbeat = read_json(self.data / 'runtime-status.json')
        deadline = time.time() + wait_sec
        while time.time() < deadline:
            own_alive = proc is not None and proc.poll() is None
            ext = self.external(heartbeat, time.time())
            if not own_alive and not ext:
                break
            time.sleep(0.25)
        with self.lock:
            if proc is not None and proc.poll() is None:
                proc.kill()  # Cleanup skipped: the next saver start re-applies settings.
            self.state = 'stopped'
            self.message = 'Saver stopped by operator.'
            self.feed.add({'t': time.time(), 'kind': 'SUPERVISOR', 'category': 'saver', 'level': 'info', 'text': 'Saver stopped from the Control Center'})
        return 'stopped'

    # -- the watch loop
    def tick(self, heartbeat, now: float | None = None):
        now = time.time() if now is None else now
        with self.lock:
            autopilot = bool(self.prefs.get('autopilot', True))
            if self.proc is not None:
                code = self.proc.poll()
                if code is not None:
                    self.last_exit = {'code': code, 't': now, 'uptimeSec': round(now - self.proc_started)}
                    self.proc = None
                    if self.operator_stopped:
                        self.state, self.message = 'stopped', 'Saver stopped by operator.'
                    else:
                        self._record_failure(now, f'Saver exited with code {code}.')
                else:
                    hb_pid = int(heartbeat.get('pid') or 0) if isinstance(heartbeat, dict) else 0
                    updated = parse_utc(heartbeat.get('updatedUtc')) if isinstance(heartbeat, dict) else None
                    fresh = hb_pid == self.proc.pid and updated is not None and now - updated <= HEARTBEAT_FRESH_SEC
                    silent = now - (updated if hb_pid == self.proc.pid and updated else self.proc_started)
                    if fresh:
                        self.state, self.message = 'running', 'Saver running under autopilot.' if autopilot else 'Saver running.'
                        if now - self.proc_started > STABLE_RESET_SEC:
                            self.failures = 0
                    elif now - self.proc_started > START_GRACE_SEC and silent > HANG_SEC:
                        self.proc.kill()
                        self.proc = None
                        self._record_failure(now, f'Saver stopped responding for {int(silent)}s and was terminated.')
                    elif self.state != 'running':
                        self.state, self.message = 'starting', 'Saver starting...'
                    else:
                        self.message = f'Waiting for saver heartbeat ({int(silent)}s).'
                return self._maybe_restart(now, heartbeat, autopilot)
            ext = self.external(heartbeat, now)
            if ext:
                self.initial_start = False
                if ext['age'] is not None and ext['age'] <= HEARTBEAT_FRESH_SEC:
                    self.state, self.message = 'external', 'Saver running (started outside the Control Center).'
                    return
                if ext['age'] is not None and ext['age'] > HANG_SEC and autopilot and not self.operator_stopped:
                    if WIN32.terminate(ext['pid'], ext['ticks']):
                        self._record_failure(now, f"Saver PID {ext['pid']} stopped responding and was terminated.")
                    return
                self.state, self.message = 'external', 'Saver is running but its heartbeat is late.'
                return
            if self.state in ('running', 'starting', 'external') and not self.operator_stopped:
                self._record_failure(now, 'Saver is no longer running.')
            elif self.state not in ('restarting', 'crashed'):
                self.state = 'stopped'
                self.message = 'Saver stopped by operator.' if self.operator_stopped else 'Saver is not running.'
            return self._maybe_restart(now, heartbeat, autopilot)

    def _record_failure(self, now: float, message: str):
        self.failures += 1
        self.crashes.append(now)
        self.next_restart = now + restart_delay(self.failures)
        recent = [t for t in self.crashes if now - t <= CRASH_LOOP_WINDOW_SEC]
        self.crash_loop = len(recent) >= CRASH_LOOP_LIMIT
        autopilot = bool(self.prefs.get('autopilot', True))
        self.state = 'restarting' if autopilot and not self.crash_loop else 'crashed'
        if self.crash_loop:
            message += ' Autopilot paused: too many crashes, check the saver log.'
        elif not autopilot:
            message += ' Autopilot is off.'
        self.message = message
        self.feed.add({'t': now, 'kind': 'SUPERVISOR', 'category': 'error', 'level': 'critical', 'text': self.message})

    def _maybe_restart(self, now, heartbeat, autopilot):
        if self.proc is not None or self.operator_stopped or self.crash_loop:
            return
        if self.initial_start:
            self.initial_start = False
            return self.start('launch')
        if not autopilot:
            return
        if self.state == 'stopped':
            return self.start('autopilot')  # Autopilot keeps a stopped farm running.
        if now >= self.next_restart and not self.external(heartbeat, now):
            self.start('autopilot')

    def snapshot(self, now: float):
        with self.lock:
            return {
                'state': self.state, 'message': self.message, 'pid': self.proc.pid if self.proc else None,
                'autopilot': bool(self.prefs.get('autopilot', True)), 'operatorStopped': self.operator_stopped,
                'failures': self.failures, 'crashLoop': self.crash_loop, 'lastExit': self.last_exit,
                'restartInSec': max(0, round(self.next_restart - now)) if self.state == 'restarting' else None,
            }


# ------------------------------------------------------------- derived view
def derive_issues(hb, age, supervisor_state) -> list:
    issues = []

    def add(level, title, detail=''):
        issues.append({'level': level, 'title': title, 'detail': detail})

    if supervisor_state.get('crashLoop'):
        add('critical', 'Autopilot paused after repeated saver crashes', 'Check data/Arkuzo-Logs/saver-console.log, then press Start.')
    if not isinstance(hb, dict):
        if supervisor_state.get('state') not in ('stopped',):
            add('warning', 'No saver heartbeat yet')
        return issues
    if age is not None and age > HEARTBEAT_FRESH_SEC and supervisor_state.get('state') != 'stopped':
        add('warning', f'Saver heartbeat is {int(age)}s old', 'The saver may be busy with Volt or recovery IO.')
    if hb.get('logFailed'):
        add('critical', 'Saver audit logging failed', 'Destructive recovery is blocked until the saver restarts.')
    if not hb.get('recoveryJournalHealthy'):
        add('critical', 'Recovery journal is not healthy', 'Recovery is blocked; check data/recovery-state.json.')
    if not (hb.get('recovery') or {}).get('enabled'):
        add('warning', 'Account recovery is disabled in settings')
    if not hb.get('voltControlAvailable'):
        add('warning', 'Volt Account Manager is not reachable', 'Keep Volt open with the Account Manager accessible so clients can be recovered.')
    memory = hb.get('systemMemory') or {}
    commit = float(memory.get('commitPercent') or 0)
    if commit >= 88:
        add('critical', f'OS commit at {commit:.0f}%', 'Close clients or grow the pagefile; the saver recycles the largest clients first.')
    elif commit >= 80:
        add('warning', f'OS commit at {commit:.0f}%')
    if (hb.get('settings') or {}).get('trimPressure'):
        add('warning', 'Low physical RAM: trimming every {}s'.format((hb.get('settings') or {}).get('effectiveTrimSec')))
    for q in hb.get('quarantined') or []:
        add('warning', f"{q.get('username') or 'An account'} is quarantined",
            f"{q.get('retryCount')} failed recoveries; retried automatically after the quarantine ends.")
    dead = hb.get('suspendedAccounts') or []
    if dead:
        add('warning', f'{len(dead)} account(s) paused with a dead cookie', 'Log those accounts in again in Volt; they resume automatically.')
    return issues


# ------------------------------------------------------------- application
class App:
    def __init__(self, data: Path, port: int):
        self.data = data
        self.port = port
        self.token = secrets.token_urlsafe(24)
        self.prefs_path = data / 'control-center.json'
        self.prefs = {'autopilot': True, 'startSaverOnLaunch': True}
        self.prefs.update(read_json(self.prefs_path) or {})
        self.feed = LogTail(data / 'Arkuzo-Logs')
        self.supervisor = Supervisor(data, self.prefs, self.feed)
        self.history = collections.deque(maxlen=1800)  # One hour at two seconds.
        self.heartbeat = None
        self.stop_event = threading.Event()
        self.server = None

    def save_prefs(self):
        write_json_atomic(self.prefs_path, self.prefs)

    def shutdown(self):
        self.stop_event.set()
        if self.server:
            self.server.shutdown()

    def names(self) -> dict:
        hb = self.heartbeat if isinstance(self.heartbeat, dict) else {}
        return {a.get('accountId'): a.get('username') for a in hb.get('accounts') or [] if a.get('accountId') and a.get('username')}

    def loop(self):
        while not self.stop_event.is_set():
            now = time.time()
            self.heartbeat = read_json(self.data / 'runtime-status.json')
            try:
                self.supervisor.tick(self.heartbeat, now)
            except Exception as exc:  # The supervisor must outlive any single failure.
                self.supervisor.message = f'Supervisor error: {type(exc).__name__}'
            self.feed.poll(self.names())
            self._sample(now)
            self.stop_event.wait(2.0)

    def _sample(self, now):
        hb = self.heartbeat
        if not isinstance(hb, dict):
            return
        updated = parse_utc(hb.get('updatedUtc'))
        if updated is None or now - updated > HEARTBEAT_FRESH_SEC:
            return
        if self.history and self.history[-1]['hb'] == hb.get('updatedUtc'):
            return
        clients = hb.get('clients') or []
        totals = hb.get('totals') or {}
        memory = hb.get('systemMemory') or {}
        total_physical = float(hb.get('totalPhysicalMB') or 0)
        available = memory.get('availablePhysicalMB')
        self.history.append({
            't': round(updated, 1), 'hb': hb.get('updatedUtc'),
            'resident': totals.get('residentMB', round(sum(float(c.get('residentMB') or 0) for c in clients), 1)),
            'private': totals.get('privateMB', round(sum(float(c.get('privateMB') or 0) for c in clients), 1)),
            'commit': memory.get('commitPercent'),
            'ramUsed': round(100 - 100 * float(available) / total_physical, 1) if total_physical > 0 and available is not None else None,
            'clients': len(clients),
        })

    def state(self, since: float, events_since: int) -> dict:
        now = time.time()
        hb = self.heartbeat if isinstance(self.heartbeat, dict) else None
        updated = parse_utc(hb.get('updatedUtc')) if hb else None
        age = round(now - updated, 1) if updated else None
        sup = self.supervisor.snapshot(now)
        view = None
        if hb:
            view = {k: hb.get(k) for k in (
                'version', 'pid', 'uptimeSec', 'trims', 'totals', 'settings', 'systemMemory', 'totalPhysicalMB', 'clients',
                'accounts', 'pending', 'quarantined', 'suspendedAccounts', 'alerts', 'voltControlAvailable',
                'recoveryJournalHealthy', 'missingRecoveryBlocked', 'expectedAccounts', 'missingAccounts', 'pendingRecoveries',
                'health', 'recovery', 'logFailed', 'updateAvailable')}
            view['pagefile'] = {k: (hb.get('pagefile') or {}).get(k) for k in ('status', 'reason', 'pendingReboot')}
        return {
            'app': APP_ID, 'now': now, 'dataDirectory': str(self.data), 'supervisor': sup,
            'prefs': dict(self.prefs, startWithWindows=startup_enabled()),
            'heartbeat': view, 'heartbeatAgeSec': age,
            'history': [{k: v for k, v in p.items() if k != 'hb'} for p in self.history if p['t'] > since],
            'events': self.feed.since(events_since), 'issues': derive_issues(hb, age, sup),
        }


def startup_command(data: Path) -> str:
    exe = Path(sys.executable)
    windowless = exe.with_name('pythonw.exe')
    runner = windowless if windowless.exists() else exe
    return f'"{runner}" "{Path(__file__).resolve()}" --data "{data}" --background'


def startup_enabled() -> bool:
    if os.name != 'nt':
        return False
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            winreg.QueryValueEx(key, RUN_VALUE)
            return True
    except OSError:
        return False


def set_startup(enabled: bool, data: Path):
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
        if enabled:
            winreg.SetValueEx(key, RUN_VALUE, 0, winreg.REG_SZ, startup_command(data))
        else:
            try:
                winreg.DeleteValue(key, RUN_VALUE)
            except FileNotFoundError:
                pass


def backup_config(data: Path):
    source = data / 'config.json'
    if not source.exists():
        return
    folder = data / 'config-backups'
    folder.mkdir(exist_ok=True)
    shutil.copyfile(source, folder / ('config-' + time.strftime('%Y%m%d-%H%M%S') + '.json'))
    for old in sorted(folder.glob('config-*.json'))[:-15]:
        old.unlink(missing_ok=True)


class Handler(BaseHTTPRequestHandler):
    app: App = None  # Set by serve().
    server_version = 'ArkuzoControlCenter'

    def log_message(self, *args):
        pass

    def _send(self, code, body, content_type='application/json; charset=utf-8'):
        raw = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(raw)

    def _host_ok(self):
        # Rejects DNS-rebinding: only loopback host names reach the API.
        host = (self.headers.get('Host') or '').lower()
        return host in (f'127.0.0.1:{self.app.port}', f'localhost:{self.app.port}')

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, {'error': 'forbidden'})
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path in ('/', '/index.html'):
            try:
                html = UI_FILE.read_text(encoding='utf-8').replace('__ARKUZO_TOKEN__', self.app.token)
            except OSError:
                return self._send(500, b'Arkuzo-Control-Center.html is missing next to the Control Center.', 'text/plain; charset=utf-8')
            return self._send(200, html.encode('utf-8'), 'text/html; charset=utf-8')
        if url.path == '/api/ping':
            return self._send(200, {'app': APP_ID})
        if url.path == '/api/state':
            try:
                since = float((query.get('since') or ['0'])[0])
                events = int((query.get('events') or ['0'])[0])
            except ValueError:
                since, events = 0.0, 0
            return self._send(200, self.app.state(since, events))
        if url.path == '/api/config':
            config = read_json(self.app.data / 'config.json')
            return self._send(200, {'config': config, 'presets': PRESETS, 'schema': {s: {k: list(v) for k, v in rules.items()} for s, rules in SCHEMA.items()},
                                    'restartKeys': sorted(RESTART_KEYS)})
        return self._send(404, {'error': 'not found'})

    def do_POST(self):
        try:
            length = int(self.headers.get('Content-Length') or 0)
        except ValueError:
            length = 0
        if length > 262144:
            return self._send(413, {'error': 'Request too large'})
        raw = self.rfile.read(length) if length else b''  # Drain before any reply.
        if not self._host_ok() or not secrets.compare_digest(self.headers.get('X-Arkuzo-Token', ''), self.app.token):
            return self._send(403, {'error': 'forbidden'})
        try:
            body = json.loads(raw or b'{}')
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            return self._send(400, {'error': 'Invalid JSON'})
        app, path = self.app, urllib.parse.urlparse(self.path).path
        try:
            if path == '/api/saver/start':
                return self._send(200, {'result': app.supervisor.start()})
            if path == '/api/saver/stop':
                return self._send(200, {'result': app.supervisor.stop()})
            if path == '/api/saver/restart':
                app.supervisor.stop()
                return self._send(200, {'result': app.supervisor.start()})
            if path == '/api/trim-now':
                (app.data / 'trim-now.signal').write_text('trim', encoding='ascii')
                return self._send(200, {'result': 'requested'})
            if path == '/api/config':
                config = read_json(app.data / 'config.json')
                if config is None:
                    raise ConfigError('data/config.json is missing or invalid; fix it before editing here')
                merged, restart = apply_config_changes(config, body.get('changes') or {})
                backup_config(app.data)
                write_json_atomic(app.data / 'config.json', merged)
                return self._send(200, {'result': 'saved', 'restartRequired': restart, 'config': merged})
            if path == '/api/accounts/recovery':
                config = read_json(app.data / 'config.json')
                if config is None:
                    raise ConfigError('data/config.json is missing or invalid')
                merged = set_account_recovery(config, str(body.get('accountId') or ''), bool(body.get('enabled')))
                backup_config(app.data)
                write_json_atomic(app.data / 'config.json', merged)
                return self._send(200, {'result': 'saved'})
            if path == '/api/prefs':
                for key in ('autopilot', 'startSaverOnLaunch'):
                    if isinstance(body.get(key), bool):
                        app.prefs[key] = body[key]
                if isinstance(body.get('autopilot'), bool) and body['autopilot']:
                    app.supervisor.crash_loop = False
                    app.supervisor.failures = 0
                app.save_prefs()
                if isinstance(body.get('startWithWindows'), bool):
                    set_startup(body['startWithWindows'], app.data)
                return self._send(200, {'result': 'saved', 'prefs': dict(app.prefs, startWithWindows=startup_enabled())})
            if path == '/api/quit':
                if body.get('stopSaver'):
                    app.supervisor.stop()
                threading.Thread(target=app.shutdown, daemon=True).start()
                return self._send(200, {'result': 'bye'})
        except ConfigError as exc:
            return self._send(400, {'error': str(exc)})
        except OSError as exc:
            return self._send(500, {'error': f'{type(exc).__name__}: {exc.strerror or exc}'})
        return self._send(404, {'error': 'not found'})


def find_app_browser():
    for base in (os.environ.get('ProgramFiles(x86)'), os.environ.get('ProgramFiles'), os.environ.get('LOCALAPPDATA')):
        if not base:
            continue
        for rel in (r'Microsoft\Edge\Application\msedge.exe', r'Google\Chrome\Application\chrome.exe'):
            path = Path(base) / rel
            if path.exists():
                return path
    return None


def open_window(url: str):
    browser = find_app_browser()
    if browser:
        subprocess.Popen([str(browser), f'--app={url}', '--window-size=1440,920'], creationflags=0x00000008 if os.name == 'nt' else 0)
    else:
        webbrowser.open(url)


def default_data_directory() -> Path:
    # Repository layout: src/saver -> data. Release layout: app/versions/vX -> data.
    for candidate in (RUNTIME.parent.parent / 'data', RUNTIME.parent.parent.parent / 'data'):
        if (candidate / 'config.json').exists():
            return candidate
    return RUNTIME.parent.parent / 'data'


def already_running(port: int) -> bool:
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/ping', timeout=1.5) as response:
            return json.loads(response.read()).get('app') == APP_ID
    except (OSError, ValueError):
        return False


def serve(app: App):
    Handler.app = app
    app.server = ThreadingHTTPServer(('127.0.0.1', app.port), Handler)
    app.server.daemon_threads = True
    threading.Thread(target=app.loop, daemon=True).start()
    app.server.serve_forever(poll_interval=0.5)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Arkuzo Control Center')
    parser.add_argument('--data', type=Path, default=None, help='Saver data directory (config.json, logs, heartbeat).')
    parser.add_argument('--port', type=int, default=DEFAULT_PORT)
    parser.add_argument('--background', action='store_true', help='Do not open a window (autostart).')
    args = parser.parse_args(argv)
    data = (args.data or default_data_directory()).resolve()
    data.mkdir(parents=True, exist_ok=True)
    url = f'http://127.0.0.1:{args.port}/'
    if already_running(args.port):
        if not args.background:
            open_window(url)
        return 0
    app = App(data, args.port)
    if not args.background:
        threading.Timer(0.6, open_window, args=(url,)).start()
    try:
        serve(app)
    except OSError as exc:
        print(f'Control Center could not listen on 127.0.0.1:{args.port}: {exc}', file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
