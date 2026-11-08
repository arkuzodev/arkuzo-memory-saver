"""Arkuzo Control Center: local dashboard and saver supervisor.

Serves a single-page UI on 127.0.0.1 only. It reads the saver heartbeat
(runtime-status.json), tails the diagnostic log, edits config.json with the
same validation the engine applies, and keeps the saver running (autopilot)
with bounded, backed-off restarts. Standard library only.

Its account manager (data/accounts.json) stores Roblox login cookies encrypted
with Windows DPAPI for the current user, checks them with Roblox and can sign
in through a small browser window. Cookies never leave that file in plain text:
no API response, log line or command line carries them. It never writes Volt
state and never touches Roblox processes: launching and closing clients stays
inside the saver engine, which reads the same vault.
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
import urllib.error
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
# After a crash loop, keep trying slowly: an unmanaged farm is worse than a retry.
CRASH_LOOP_RETRY_SEC = 600
# A pause this long in the 2 s supervisor loop means the PC slept or stalled; that is not the saver's silence.
SUSPEND_GAP_SEC = 30
# After the last window closes the Control Center quits; a page reload reconnects well within this.
WINDOW_CLOSE_GRACE_SEC = 8
# Open windows poll every 2 s (a minimized, throttled one about once a minute). A page id
# not seen for this long belongs to a window that is gone, e.g. one reloaded after an update.
PAGE_STALE_SEC = 180

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
        'farm_freeze_enabled': ('bool',), 'farm_freeze_confirm_sec': ('int', 20, 120), 'farm_freeze_min_clients': ('int', 3, 50),
        'farm_freeze_onset_window_sec': ('int', 5, 60), 'farm_freeze_max_cpu_percent': ('int', 1, 10),
        'farm_freeze_spacing_sec': ('int', 10, 60), 'farm_freeze_refreeze_sec': ('int', 0, 86400),
    },
    'recovery': {
        'enabled': ('bool',), 'restore_missing': ('bool',), 'restore_wait_sec': ('int', 90, 900),
        'relaunch_delay_sec': ('int', 30, 120), 'retry_base_sec': ('int', 90, 900), 'retry_max_sec': ('int', 180, 3600),
        'retry_max_per_hour': ('int', 1, 500), 'ready_stable_sec': ('int', 30, 300),
        'abandon_after_retries': ('int', 1, 100), 'abandon_after_sec': ('int', 900, 86400), 'quarantine_sec': ('int', 0, 86400),
    },
    # Who launches and relaunches clients: Arkuzo's own account manager or Volt's.
    # auto = Arkuzo once data/accounts.json has an account, otherwise Volt.
    'accounts': {'provider': ('enum', ('auto', 'arkuzo', 'volt'))},
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
    'RECOVERY_REQUESTED': 'recovery', 'CLIENT_CLOSED_FOR_RECOVERY': 'recovery', 'EXITED_CLIENT_RECOVERY_QUEUED': 'recovery', 'ACCOUNT_RESTORED_VERIFIED': 'recovery',
    'FARM_FREEZE_DETECTED': 'recovery', 'FARM_FREEZE_EPISODE_END': 'recovery',
    'VOLT_MISSING_LAUNCH_REQUEST': 'recovery', 'VOLT_MISSING_LAUNCH_RESULT': 'recovery', 'MISSING_ACCOUNT_DETECTED': 'recovery',
    'RECOVERY_OUTCOME_STATE': 'recovery', 'RECOVERY_QUARANTINED': 'recovery', 'RECOVERY_CANCELLED_BY_POLICY': 'recovery',
    'LAUNCH_REFUSED_DEAD_COOKIE': 'recovery', 'COOKIE_ACCOUNT_SUSPENDED': 'recovery', 'COOKIE_ACCOUNT_RESUMED': 'recovery',
    'WARNING': 'warning', 'CONFIG_RELOADED': 'saver', 'SETTINGS_APPLIED_LIVE': 'saver', 'TRIM_NOW_REQUESTED': 'memory',
    'ORPHAN_CRASH_HANDLER_CLOSED': 'client', 'SYSTEM_RESOURCE_EXHAUSTION': 'error',
    'NATIVE_LAUNCH_REQUEST': 'recovery', 'NATIVE_LAUNCH_RESULT': 'recovery', 'NATIVE_CLIENT_CLOSED': 'client',
    'NATIVE_COOKIE_DEAD': 'recovery', 'ACCOUNT_PROVIDER': 'saver', 'NATIVE_LAUNCH_BLOCKED': 'warning',
}  # Individual trims would flood the feed; the heartbeat carries their count.


# ---------------------------------------------------------------- utilities
def engine_version(script: Path) -> str | None:
    """The runtime version stamped in the engine next to this file, e.g. '2.1.2'."""
    try:
        text = script.read_text(encoding='utf-8-sig', errors='replace')
    except OSError:
        return None
    match = re.search(r"^\$ArkuzoRuntimeVersion\s*=\s*'(\d+(?:\.\d+)*)'", text, re.M)
    return match.group(1) if match else None


def version_key(version) -> tuple | None:
    match = re.fullmatch(r'v?(\d+(?:\.\d+)*)', str(version or '').strip())
    if not match:
        return None
    parts = [int(p) for p in match.group(1).split('.')]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def should_take_over(mine, theirs) -> bool:
    """A newer Control Center replaces a running older one. Those from before
    the handover existed report no version, so they count as older."""
    mine_key = version_key(mine)
    if mine_key is None:
        return False
    theirs_key = version_key(theirs)
    return theirs_key is None or theirs_key < mine_key


RUNTIME_VERSION = engine_version(SAVER_SCRIPT)


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


def read_json(path: Path, retry_missing=False):
    # retry_missing: the file is replaced, never deleted, so a brief absence is a replace in flight.
    for _ in range(3):
        try:
            return json.loads(path.read_text(encoding='utf-8-sig'))
        except FileNotFoundError:
            if not retry_missing:
                return None
            time.sleep(0.05)
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


# ---------------------------------------------------------- account vault
# Arkuzo's own account manager, so farming does not depend on Volt.
#   data/accounts.json holds accounts, private servers and farm settings.
#   Cookies and private-server link codes are encrypted with Windows DPAPI for
#   the current user (entropy VAULT_ENTROPY); the engine decrypts with the same
#   entropy. Nothing here ever returns, logs or prints a cookie.
#   Every write is read-modify-write under the named mutex VAULT_MUTEX, which the
#   engine also takes, and never while a network request is in flight.
VAULT_FILE = 'accounts.json'
VAULT_MUTEX = 'Local\\ArkuzoAccountVault'
VAULT_ENTROPY = b'Arkuzo.AccountVault.v1'
SECRET_PREFIX = 'dpapi:'
COOKIE_NAME = '.ROBLOSECURITY'
ROBLOX_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
TRACKER = re.compile(r'\A[1-9][0-9]{9,15}\Z')
DIGITS = re.compile(r'\A[1-9][0-9]{0,18}\Z')

VAULT_SETTINGS = {
    # name: (rule, default). Rules use the same validate_value as config edits.
    'defaultPlaceId': (('placeid',), ''),
    'launchDelaySec': (('int', 5, 120), 12),
    'relaunchDelaySec': (('int', 0, 600), 8),
    'launchTimeoutSec': (('int', 30, 600), 120),
    'autoRelaunchEnabled': (('bool',), True),
    'farmRunning': (('bool',), False),
    'privateServerMode': (('enum', ('none', 'shared', 'assigned')), 'none'),
    'sharedPrivateServerId': (('serverid',), None),
    'multiInstance': (('bool',), True),
    'launchMethod': (('enum', ('direct', 'protocol')), 'direct'),
    'cookieCheckMinutes': (('int', 0, 1440), 60),
    # Window layout of Arkuzo-launched clients (the engine arranges them).
    'arrangeWindows': (('bool',), True),
    'arrangeLayout': (('enum', ('grid', 'cascade')), 'grid'),
    'arrangePerRow': (('int', 1, 12), 2),
    'arrangeWidth': (('int', 160, 1920), 320),
    'arrangeHeight': (('int', 120, 1440), 240),
    'arrangeGap': (('int', 0, 40), 4),
    'arrangeCorner': (('enum', ('top-left', 'top-right', 'bottom-left', 'bottom-right')), 'top-left'),
    'arrangeMonitor': (('int', 0, 8), 0),
    'arrangeOrder': (('enum', ('fixed', 'name', 'launch')), 'fixed'),
    'arrangeMode': (('enum', ('keep', 'once')), 'keep'),
    'arrangeVisibility': (('enum', ('normal', 'background', 'minimized')), 'normal'),
    'arrangeRequestedAtMs': (('int', 0, 2 ** 53), 0),
}
ACCOUNT_FIELDS = {
    'alias': 40, 'group': 40, 'notes': 500,
}


class VaultError(ValueError):
    pass


class _DataBlob(ctypes.Structure):
    _fields_ = [('cbData', wintypes.DWORD), ('pbData', ctypes.POINTER(ctypes.c_char))]


def _blob(data: bytes):
    buf = ctypes.create_string_buffer(data, len(data))
    return _DataBlob(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), buf


def _dpapi(data: bytes, protect: bool) -> bytes:
    if os.name != 'nt':
        raise VaultError('Encrypted accounts need Windows')
    crypt = ctypes.WinDLL('crypt32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    fn = crypt.CryptProtectData if protect else crypt.CryptUnprotectData
    fn.argtypes = [ctypes.POINTER(_DataBlob), ctypes.c_void_p, ctypes.POINTER(_DataBlob), ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(_DataBlob)]
    fn.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    source, keep1 = _blob(data)
    entropy, keep2 = _blob(VAULT_ENTROPY)
    out = _DataBlob()
    if not fn(ctypes.byref(source), None, ctypes.byref(entropy), None, None, 0x1, ctypes.byref(out)):  # CRYPTPROTECT_UI_FORBIDDEN
        raise VaultError('Windows could not ' + ('encrypt' if protect else 'decrypt') + ' an account secret (different Windows user?)')
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        kernel.LocalFree(out.pbData)


def protect_secret(text: str) -> str:
    import base64
    return SECRET_PREFIX + base64.b64encode(_dpapi(text.encode('utf-8'), True)).decode('ascii')


def unprotect_secret(value: str) -> str:
    import base64
    if not isinstance(value, str) or not value.startswith(SECRET_PREFIX):
        raise VaultError('Account secret is missing')
    return _dpapi(base64.b64decode(value[len(SECRET_PREFIX):]), False).decode('utf-8')


class vault_lock:
    """Cross-process lock shared with the engine (a named Windows mutex)."""

    def __init__(self, timeout_sec=10.0):
        self.timeout_ms = int(timeout_sec * 1000)
        self.handle = None
        self.k = None

    def __enter__(self):
        if os.name != 'nt':
            return self
        k = ctypes.WinDLL('kernel32', use_last_error=True)
        k.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        k.CreateMutexW.restype = wintypes.HANDLE
        k.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        k.WaitForSingleObject.restype = wintypes.DWORD
        k.ReleaseMutex.argtypes = [wintypes.HANDLE]
        k.CloseHandle.argtypes = [wintypes.HANDLE]
        self.k = k
        self.handle = k.CreateMutexW(None, False, VAULT_MUTEX)
        if not self.handle:
            raise VaultError('Account vault lock unavailable')
        result = k.WaitForSingleObject(self.handle, self.timeout_ms)
        if result not in (0, 0x80):  # WAIT_OBJECT_0, WAIT_ABANDONED (a holder died; the file is replaced atomically)
            k.CloseHandle(self.handle)
            self.handle = None
            raise VaultError('Account vault is busy; try again')
        return self

    def __exit__(self, *exc):
        if self.handle:
            self.k.ReleaseMutex(self.handle)
            self.k.CloseHandle(self.handle)
            self.handle = None
        return False


def now_ms() -> int:
    return int(time.time() * 1000)


def new_tracker_id(taken) -> str:
    # Same shape as Roblox's own browser tracker ids; unique per account so every
    # client's command line maps to exactly one account.
    while True:
        value = str(secrets.randbelow(75000) + 100000) + str(secrets.randbelow(800000) + 100000)
        if value not in taken:
            return value


def empty_vault() -> dict:
    return {'schemaVersion': 1, 'settings': {k: v[1] for k, v in VAULT_SETTINGS.items()}, 'accounts': [], 'privateServers': []}


def _validate_setting(name, value, vault):
    rule = VAULT_SETTINGS[name][0]
    if rule[0] == 'placeid':
        value = '' if value in (None, '') else str(value).strip()
        if value and not DIGITS.match(value):
            raise VaultError('Place ID must be a number')
        return value
    if rule[0] == 'serverid':
        if value in (None, ''):
            return None
        if not any(s.get('id') == value for s in vault.get('privateServers') or []):
            raise VaultError('Unknown private server')
        return value
    try:
        return validate_value(rule, value, name)
    except ConfigError as exc:
        raise VaultError(str(exc))


def normalize_vault(raw) -> dict:
    """Fill defaults and drop anything malformed, so one bad row never blocks the farm."""
    vault = empty_vault()
    if not isinstance(raw, dict):
        return vault
    settings = raw.get('settings') if isinstance(raw.get('settings'), dict) else {}
    for name in VAULT_SETTINGS:
        if name in settings:
            try:
                vault['settings'][name] = _validate_setting(name, settings[name], raw)
            except VaultError:
                pass
    seen_ids, seen_trackers, seen_users = set(), set(), set()
    # Rows that can't be used are kept as they are, never dropped: they may hold the only copy of a cookie.
    vault['unreadable'] = [r for r in raw.get('unreadable') or [] if isinstance(r, dict)][:200]
    for s in raw.get('privateServers') or []:
        if isinstance(s, dict) and GUID.match(str(s.get('id') or '')) and DIGITS.match(str(s.get('placeId') or '')) and str(s.get('linkCode') or '').startswith(SECRET_PREFIX):
            vault['privateServers'].append({'id': s['id'], 'name': str(s.get('name') or '')[:60], 'placeId': str(s['placeId']),
                                            'linkCode': s['linkCode'], 'createdAtMs': int(s.get('createdAtMs') or 0)})
    server_ids = {s['id'] for s in vault['privateServers']}
    for a in raw.get('accounts') or []:
        if not isinstance(a, dict):
            continue
        aid, tracker, uid = str(a.get('id') or ''), str(a.get('browserTrackerId') or ''), a.get('userId')
        if not GUID.match(aid) or not TRACKER.match(tracker) or not isinstance(uid, int) or isinstance(uid, bool) or uid <= 0                 or aid.lower() in seen_ids or tracker in seen_trackers or uid in seen_users or not str(a.get('cookie') or '').startswith(SECRET_PREFIX):
            vault['unreadable'].append(a)
            continue
        seen_ids.add(aid.lower()); seen_trackers.add(tracker); seen_users.add(uid)
        status = a.get('cookieStatus') if a.get('cookieStatus') in ('alive', 'dead', 'unknown') else 'unknown'
        entry = {'id': aid, 'userId': uid, 'username': str(a.get('username') or '')[:40], 'displayName': str(a.get('displayName') or '')[:40],
                 'cookie': a['cookie'], 'cookieStatus': status, 'browserTrackerId': tracker,
                 'autoRelaunch': a.get('autoRelaunch') is True, 'privateServerId': a.get('privateServerId') if a.get('privateServerId') in server_ids else None,
                 'placeId': str(a.get('placeId') or '') if DIGITS.match(str(a.get('placeId') or '')) else ''}
        for name, limit in ACCOUNT_FIELDS.items():
            entry[name] = str(a.get(name) or '')[:limit]
        for name in ('lastCheckAtMs', 'lastLaunchAtMs', 'createdAtMs', 'updatedAtMs', 'launchRequestedAtMs', 'closeRequestedAtMs'):
            value = a.get(name)
            entry[name] = int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0 else 0
        if a.get('lastError'):
            entry['lastError'] = str(a['lastError'])[:160]
        vault['accounts'].append(entry)
    if vault['settings']['sharedPrivateServerId'] not in server_ids:
        vault['settings']['sharedPrivateServerId'] = None
    return vault


def load_vault(data: Path) -> dict:
    """A missing vault is empty; a damaged one raises, so nothing ever overwrites it."""
    path = data / VAULT_FILE
    for attempt in range(3):
        try:
            raw = path.read_text(encoding='utf-8-sig')
        except FileNotFoundError:
            return empty_vault()
        except OSError:
            time.sleep(0.05)
            continue
        try:
            parsed = json.loads(raw)
        except ValueError:
            if attempt == 2:
                raise VaultError('data/accounts.json is damaged and was left untouched; restore it from a backup or fix it')
            time.sleep(0.05)
            continue
        if not isinstance(parsed, dict):
            raise VaultError('data/accounts.json is damaged and was left untouched; restore it from a backup or fix it')
        return normalize_vault(parsed)
    raise VaultError('data/accounts.json could not be read')


def update_vault(data: Path, change):
    """Apply change(vault) under the shared lock and save atomically. Returns change's result."""
    with vault_lock():
        vault = load_vault(data)
        result = change(vault)
        write_json_atomic(data / VAULT_FILE, vault)
        return result


def public_account(a: dict) -> dict:
    return {k: v for k, v in a.items() if k != 'cookie'}


def public_vault(vault: dict) -> dict:
    return {'settings': dict(vault['settings']), 'accounts': [public_account(a) for a in vault['accounts']],
            'privateServers': [{k: v for k, v in s.items() if k != 'linkCode'} for s in vault['privateServers']],
            'unreadableCount': len(vault.get('unreadable') or [])}


def find_account(vault: dict, account_id: str) -> dict:
    for a in vault['accounts']:
        if a['id'].lower() == str(account_id or '').lower():
            return a
    raise VaultError('Unknown account')


# ------------------------------------------------------------- roblox web
class RobloxResponse:
    def __init__(self, status: int, headers, body: bytes):
        self.status, self.headers, self.body = status, headers, body

    def json(self):
        try:
            return json.loads(self.body or b'null')
        except ValueError:
            return None

    def rotated_cookie(self):
        """Roblox re-issues the login cookie through Set-Cookie and later rejects the old one."""
        for header in self.headers.get_all('Set-Cookie') or []:
            name, _, rest = header.partition('=')
            if name.strip() == COOKIE_NAME:
                value = rest.split(';', 1)[0].strip()
                if value:
                    return value
        return None


def roblox_request(url: str, cookie: str | None = None, method='GET', body=None, csrf=None, timeout=15.0) -> RobloxResponse:
    """One HTTPS request to a *.roblox.com endpoint. Errors become status 0 (network)."""
    host = urllib.parse.urlparse(url).hostname or ''
    if not (host == 'roblox.com' or host.endswith('.roblox.com')) or not url.startswith('https://'):
        raise VaultError('Only roblox.com endpoints are allowed')
    data = None if body is None else json.dumps(body).encode('utf-8')
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('User-Agent', ROBLOX_UA)
    req.add_header('Accept', 'application/json')
    req.add_header('Referer', 'https://www.roblox.com/')
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    if cookie:
        req.add_header('Cookie', f'{COOKIE_NAME}={cookie}')
    if csrf:
        req.add_header('X-CSRF-TOKEN', csrf)
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler())
    try:
        with opener.open(req, timeout=timeout) as resp:
            return RobloxResponse(resp.status, resp.headers, resp.read(1048576))
    except urllib.error.HTTPError as err:
        return RobloxResponse(err.code, err.headers, err.read(1048576) if err.fp else b'')
    except (OSError, ValueError):
        return RobloxResponse(0, _NoHeaders(), b'')


class _NoHeaders:
    def get(self, *_):
        return None

    def get_all(self, *_):
        return []


HTTP = {'request': roblox_request}  # Tests swap the transport.


def roblox_post(url: str, cookie: str, body) -> tuple[RobloxResponse, str]:
    """POST with Roblox's CSRF handshake (403 + x-csrf-token, then retry). Returns (response, cookie in use)."""
    first = HTTP['request'](url, cookie, 'POST', body)
    cookie = first.rotated_cookie() or cookie
    token = first.headers.get('x-csrf-token')
    if first.status == 403 and token:
        second = HTTP['request'](url, cookie, 'POST', body, csrf=token)
        return second, (second.rotated_cookie() or cookie)
    return first, cookie


def check_cookie(cookie: str) -> dict:
    """alive / dead / unknown (network or Roblox trouble: never treated as dead)."""
    if not isinstance(cookie, str) or len(cookie) < 50 or any(c in cookie for c in '\r\n;'):
        return {'status': 'dead', 'reason': 'Not a Roblox login cookie'}
    resp = HTTP['request']('https://users.roblox.com/v1/users/authenticated', cookie)
    if resp.status == 200:
        info = resp.json() or {}
        uid = info.get('id')
        if isinstance(uid, int) and uid > 0:
            return {'status': 'alive', 'userId': uid, 'username': str(info.get('name') or ''), 'displayName': str(info.get('displayName') or ''),
                    'rotated': resp.rotated_cookie()}
        return {'status': 'unknown', 'reason': 'Unexpected Roblox reply'}
    if resp.status == 401:
        return {'status': 'dead', 'reason': 'Roblox rejected the cookie (signed out or expired)'}
    return {'status': 'unknown', 'reason': 'Roblox unreachable' if resp.status == 0 else f'Roblox answered {resp.status}'}


def clean_cookie(text: str) -> str:
    """Accept a bare cookie or a pasted '.ROBLOSECURITY=...' / cookie header."""
    text = (text or '').strip().strip('"\'')
    match = re.search(r'\.ROBLOSECURITY=([^;\s]+)', text)
    return match.group(1) if match else text


def add_account(data: Path, cookie_text: str) -> dict:
    cookie = clean_cookie(cookie_text)
    result = check_cookie(cookie)
    if result['status'] != 'alive':
        raise VaultError(result.get('reason') or 'Cookie could not be verified')
    cookie = result.get('rotated') or cookie
    secret = protect_secret(cookie)

    def change(vault):
        stamp = now_ms()
        for a in vault['accounts']:
            if a['userId'] == result['userId']:  # Re-adding an account refreshes its cookie.
                a.update(cookie=secret, cookieStatus='alive', lastCheckAtMs=stamp, updatedAtMs=stamp,
                         username=result['username'], displayName=result['displayName'])
                a.pop('lastError', None)
                return dict(public_account(a), updated=True)
        account = {'id': str(__import__('uuid').uuid4()), 'userId': result['userId'], 'username': result['username'],
                   'displayName': result['displayName'], 'alias': '', 'group': '', 'notes': '', 'cookie': secret,
                   'cookieStatus': 'alive', 'lastCheckAtMs': stamp, 'lastLaunchAtMs': 0, 'autoRelaunch': True,
                   'privateServerId': None, 'placeId': '', 'browserTrackerId': new_tracker_id({x['browserTrackerId'] for x in vault['accounts']}),
                   'createdAtMs': stamp, 'updatedAtMs': stamp, 'launchRequestedAtMs': 0, 'closeRequestedAtMs': 0}
        vault['accounts'].append(account)
        return dict(public_account(account), updated=False)
    return update_vault(data, change)


def check_account(data: Path, account_id: str) -> dict:
    """Check one stored cookie. The network call runs outside the vault lock."""
    with vault_lock():
        account = find_account(load_vault(data), account_id)
        secret = account['cookie']
    cookie = unprotect_secret(secret)
    result = check_cookie(cookie)

    def change(vault):
        a = find_account(vault, account_id)
        stamp = now_ms()
        a['lastCheckAtMs'] = stamp
        if result['status'] == 'unknown':
            a['lastError'] = result.get('reason', '')
            return a['cookieStatus']
        a['cookieStatus'] = result['status']
        a.pop('lastError', None)
        if result['status'] == 'alive':
            a.update(username=result['username'] or a['username'], displayName=result['displayName'] or a['displayName'])
            # Store a rotated cookie only if nobody replaced the one we used meanwhile.
            if result.get('rotated') and a['cookie'] == secret:
                a['cookie'] = protect_secret(result['rotated'])
        else:
            a['lastError'] = result.get('reason', '')
        a['updatedAtMs'] = stamp
        return a['cookieStatus']
    return {'id': account_id, 'status': update_vault(data, change), 'reason': result.get('reason')}


def parse_private_server_link(link: str) -> dict:
    link = (link or '').strip()
    parsed = urllib.parse.urlparse(link)
    host = (parsed.hostname or '').lower()
    if parsed.scheme != 'https' or not (host == 'roblox.com' or host.endswith('.roblox.com')):
        raise VaultError('Paste a roblox.com private server link')
    query = urllib.parse.parse_qs(parsed.query)
    code = (query.get('privateServerLinkCode') or [''])[0]
    place = re.search(r'/games/(\d+)', parsed.path)
    if code and place:
        if not re.fullmatch(r'[0-9A-Za-z_-]{6,80}', code):
            raise VaultError('The link code looks wrong')
        return {'kind': 'legacy', 'placeId': place.group(1), 'linkCode': code}
    share = (query.get('code') or [''])[0]
    if parsed.path.rstrip('/').endswith('/share') and share and (query.get('type') or [''])[0].lower() == 'server':
        if not re.fullmatch(r'[0-9A-Za-z_-]{6,80}', share):
            raise VaultError('The share code looks wrong')
        return {'kind': 'share', 'shareCode': share}
    raise VaultError('Not a private server link (expected ...privateServerLinkCode=... or ...share?code=...&type=Server)')


def resolve_private_server(data: Path, link: str) -> dict:
    info = parse_private_server_link(link)
    if info['kind'] == 'legacy':
        return info
    # Share links resolve only for a signed-in account: use any alive one.
    with vault_lock():
        vault = load_vault(data)
        alive = [a for a in vault['accounts'] if a['cookieStatus'] == 'alive']
        secret = alive[0]['cookie'] if alive else None
    if not secret:
        raise VaultError('Add an account first: share links resolve only when signed in')
    resp, _ = roblox_post('https://apis.roblox.com/sharelinks/v1/resolve-link', unprotect_secret(secret),
                          {'linkId': info['shareCode'], 'linkType': 'Server'})
    invite = (resp.json() or {}).get('privateServerInviteData') or {} if resp.status == 200 else {}
    code, place = str(invite.get('linkCode') or ''), str(invite.get('placeId') or '')
    if not code or not DIGITS.match(place):
        raise VaultError('Roblox did not resolve that share link' + (f' ({resp.status})' if resp.status else ' (offline)'))
    return {'kind': 'share', 'placeId': place, 'linkCode': code}


def add_private_server(data: Path, name: str, link: str) -> dict:
    info = resolve_private_server(data, link)
    secret = protect_secret(info['linkCode'])

    def change(vault):
        server = {'id': str(__import__('uuid').uuid4()), 'name': (name or '').strip()[:60] or f"Server {len(vault['privateServers']) + 1}",
                  'placeId': info['placeId'], 'linkCode': secret, 'createdAtMs': now_ms()}
        vault['privateServers'].append(server)
        return {k: v for k, v in server.items() if k != 'linkCode'}
    return update_vault(data, change)


def remove_private_server(data: Path, server_id: str):
    def change(vault):
        before = len(vault['privateServers'])
        vault['privateServers'] = [s for s in vault['privateServers'] if s['id'] != server_id]
        if len(vault['privateServers']) == before:
            raise VaultError('Unknown private server')
        for a in vault['accounts']:
            if a['privateServerId'] == server_id:
                a['privateServerId'] = None
        if vault['settings']['sharedPrivateServerId'] == server_id:
            vault['settings']['sharedPrivateServerId'] = None
    update_vault(data, change)


def update_account(data: Path, account_id: str, fields: dict) -> dict:
    if not isinstance(fields, dict):
        raise VaultError('Invalid change')

    def change(vault):
        a = find_account(vault, account_id)
        for name, value in fields.items():
            if name in ACCOUNT_FIELDS:
                a[name] = str(value or '').strip()[:ACCOUNT_FIELDS[name]]
            elif name == 'autoRelaunch':
                if not isinstance(value, bool):
                    raise VaultError('autoRelaunch must be true or false')
                a[name] = value
            elif name == 'privateServerId':
                if value not in (None, '') and not any(s['id'] == value for s in vault['privateServers']):
                    raise VaultError('Unknown private server')
                a[name] = value or None
            elif name == 'placeId':
                value = str(value or '').strip()
                if value and not DIGITS.match(value):
                    raise VaultError('Place ID must be a number')
                a[name] = value
            else:
                raise VaultError(f'Unknown account field: {name}')
        a['updatedAtMs'] = now_ms()
        return public_account(a)
    return update_vault(data, change)


def request_account_action(data: Path, account_id: str, action: str) -> dict:
    """Launch / close one account. The engine carries it out and clears the request."""
    def change(vault):
        a = find_account(vault, account_id)
        if action == 'launch':
            if a['cookieStatus'] == 'dead':
                raise VaultError('This account\'s cookie is dead: sign in again first')
            a['launchRequestedAtMs'], a['closeRequestedAtMs'] = now_ms(), 0
        elif action == 'close':
            # Closing one account also stops relaunching it until it is switched back on.
            a['closeRequestedAtMs'], a['launchRequestedAtMs'], a['autoRelaunch'] = now_ms(), 0, False
        else:
            raise VaultError('Unknown action')
        return public_account(a)
    return update_vault(data, change)


def remove_account(data: Path, account_id: str):
    def change(vault):
        a = find_account(vault, account_id)
        vault['accounts'].remove(a)
    update_vault(data, change)


def update_vault_settings(data: Path, changes: dict) -> dict:
    if not isinstance(changes, dict):
        raise VaultError('Invalid change')

    def change(vault):
        for name, value in changes.items():
            if name not in VAULT_SETTINGS:
                raise VaultError(f'Unknown setting: {name}')
            vault['settings'][name] = _validate_setting(name, value, vault)
        return dict(vault['settings'])
    return update_vault(data, change)


def set_farm_running(data: Path, running: bool, close_clients=False) -> dict:
    def change(vault):
        vault['settings']['farmRunning'] = bool(running)
        if running and not vault['settings']['defaultPlaceId'] and vault['settings']['privateServerMode'] == 'none' \
                and not any(a['placeId'] or a['privateServerId'] for a in vault['accounts']):
            raise VaultError('Set a default place (game) to farm first')
        if not running and close_clients:
            stamp = now_ms()
            for a in vault['accounts']:
                a['closeRequestedAtMs'], a['launchRequestedAtMs'] = stamp, 0
        return dict(vault['settings'])
    return update_vault(data, change)


# ---------------------------------------------------- browser sign-in window
class _WebSocket:
    """Just enough RFC 6455 for the local DevTools endpoint (text frames, client masking)."""

    def __init__(self, url: str, timeout=10.0):
        import base64
        import socket
        parsed = urllib.parse.urlparse(url)
        if parsed.hostname not in ('127.0.0.1', 'localhost'):
            raise OSError('DevTools must be local')
        self.sock = socket.create_connection((parsed.hostname, parsed.port), timeout=timeout)
        key = base64.b64encode(secrets.token_bytes(16)).decode('ascii')
        # No Origin header: Chromium only checks origins when one is sent.
        request = (f'GET {parsed.path} HTTP/1.1\r\nHost: {parsed.hostname}:{parsed.port}\r\nUpgrade: websocket\r\n'
                   f'Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n')
        self.sock.sendall(request.encode('ascii'))
        head = b''
        while b'\r\n\r\n' not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise OSError('DevTools closed the connection')
            head += chunk
        if b' 101 ' not in head.split(b'\r\n', 1)[0]:
            raise OSError('DevTools refused the connection')
        self.buffer = head.split(b'\r\n\r\n', 1)[1]
        self.next_id = 0

    def _read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise OSError('DevTools closed the connection')
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def send(self, text: str):
        payload = text.encode('utf-8')
        header = bytearray([0x81])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        elif len(payload) < 65536:
            header.append(0x80 | 126); header += len(payload).to_bytes(2, 'big')
        else:
            header.append(0x80 | 127); header += len(payload).to_bytes(8, 'big')
        mask = secrets.token_bytes(4)
        self.sock.sendall(bytes(header) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def recv(self) -> str:
        message = b''
        while True:
            b1, b2 = self._read(2)
            length = b2 & 0x7F
            if length == 126:
                length = int.from_bytes(self._read(2), 'big')
            elif length == 127:
                length = int.from_bytes(self._read(8), 'big')
            if length > 16 * 1048576:
                raise OSError('DevTools message too large')
            mask = self._read(4) if b2 & 0x80 else None
            payload = self._read(length)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            opcode = b1 & 0x0F
            if opcode == 0x8:
                raise OSError('DevTools closed the connection')
            if opcode in (0x9, 0xA):
                continue  # ping/pong
            message += payload
            if b1 & 0x80:
                return message.decode('utf-8', 'replace')

    def call(self, method: str, params=None) -> dict:
        self.next_id += 1
        wanted = self.next_id
        self.send(json.dumps({'id': wanted, 'method': method, 'params': params or {}}))
        while True:
            reply = json.loads(self.recv())
            if reply.get('id') == wanted:
                return reply

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def login_cookie_from(cookies) -> str | None:
    for c in cookies or []:
        if c.get('name') == COOKIE_NAME and str(c.get('domain') or '').lstrip('.').endswith('roblox.com') and c.get('value'):
            return c['value']
    return None


def signed_in_title(title: str) -> bool:
    """Roblox opens its home page after a successful sign-in ("Home - Roblox")."""
    return 'home - roblox' in (title or '').lower()


class _Windows:
    """Top-level window titles of one process, and a polite close (like clicking X)."""

    def __init__(self):
        self.u = None
        if os.name == 'nt':
            u = ctypes.WinDLL('user32', use_last_error=True)
            self.proc_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
            u.EnumWindows.argtypes = [self.proc_type, wintypes.LPARAM]
            u.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
            u.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
            u.IsWindowVisible.argtypes = [wintypes.HWND]
            u.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
            self.u = u

    def windows(self, pid: int) -> list:
        found = []
        if not self.u:
            return found

        def visit(hwnd, _):
            owner = wintypes.DWORD()
            self.u.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
            if owner.value == pid and self.u.IsWindowVisible(hwnd):
                buf = ctypes.create_unicode_buffer(512)
                self.u.GetWindowTextW(hwnd, buf, 512)
                found.append((hwnd, buf.value))
            return True
        self.u.EnumWindows(self.proc_type(visit), 0)
        return found

    def bring_front(self, pid: int) -> bool:
        """Raise the process's window over the Control Center. Windows only lets the foreground
        thread hand focus on, so borrow its input queue for the moment of the switch."""
        if not self.u:
            return False
        # The real browser window carries the page title; Edge briefly shows an "Untitled" one first.
        wins = [h for h, t in self.windows(pid) if t and not t.startswith('Untitled')]
        if not wins:
            return False
        hwnd = wins[0]
        k = ctypes.WinDLL('kernel32')
        u = self.u
        u.GetForegroundWindow.restype = wintypes.HWND
        u.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
        u.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
        u.SetForegroundWindow.argtypes = [wintypes.HWND]
        u.BringWindowToTop.argtypes = [wintypes.HWND]
        foreground = u.GetForegroundWindow()
        mine = k.GetCurrentThreadId()
        theirs = u.GetWindowThreadProcessId(foreground, None) if foreground else 0
        attached = bool(theirs and theirs != mine and u.AttachThreadInput(mine, theirs, True))
        try:
            u.ShowWindow(hwnd, 9)  # SW_RESTORE
            u.BringWindowToTop(hwnd)
            if not u.SetForegroundWindow(hwnd):
                # Windows grants focus after a key event; a lone Alt press/release is the usual way.
                u.keybd_event(0x12, 0, 0, 0)
                u.keybd_event(0x12, 0, 2, 0)
                u.SetForegroundWindow(hwnd)
        finally:
            if attached:
                u.AttachThreadInput(mine, theirs, False)
        return self.focused(pid)

    def focused(self, pid: int) -> bool:
        if not self.u:
            return False
        self.u.GetForegroundWindow.restype = wintypes.HWND
        owner = wintypes.DWORD()
        self.u.GetWindowThreadProcessId(self.u.GetForegroundWindow(), ctypes.byref(owner))
        return owner.value == pid

    def close(self, pid: int):
        for hwnd, _ in self.windows(pid):
            self.u.PostMessageW(hwnd, 0x0010, 0, 0)  # WM_CLOSE: Edge saves the profile (cookies included) as it exits.


WINDOWS = _Windows()


# Edge signs a new profile in with the Windows Microsoft account and then announces
# it is syncing; turn that off for the throwaway profile only (user-level switches,
# invisible to websites, unlike automation flags).
EDGE_QUIET = '--disable-features=msImplicitSignin,msEdgeFirstSyncOnFirstRun,msEdgeSyncConsent'


class BrowserLogin:
    """Sign in with a plain Microsoft Edge window, then read the login cookie.

    While the person signs in, Edge runs exactly as normal: no remote debugging,
    no automation switches, no app mode. It only gets its own throwaway profile.
    When Roblox shows its home page (or the window is closed), Edge is opened
    once more, invisibly, on that profile so Edge itself hands over the stored
    cookie through DevTools; nothing here decrypts browser files. The profile is
    deleted afterwards; the cookie only ever lives in memory and in the vault.
    """
    TIMEOUT_SEC = 900

    def __init__(self, data: Path, browser: Path | None, on_cookie=None, extra_args=(), reader_args=('--headless=new',)):
        self.data, self.browser = data, browser
        self.extra_args, self.reader_args = list(extra_args), list(reader_args)
        self.on_cookie = on_cookie or (lambda cookie: add_account(data, cookie))
        self.state, self.message, self.account = 'idle', '', None
        self.proc = None
        self.profile = None
        self.cancelled = threading.Event()
        self.lock = threading.Lock()

    def snapshot(self) -> dict:
        return {'state': self.state, 'message': self.message, 'account': self.account}

    def start(self) -> dict:
        with self.lock:
            if self.state in ('starting', 'waiting', 'reading'):
                return self.snapshot()
            if not self.browser:
                raise VaultError('Microsoft Edge is needed for browser sign-in; paste the cookie instead')
            self.state, self.message, self.account = 'starting', 'Opening Microsoft Edge', None
            self.cancelled.clear()
            threading.Thread(target=self._run, daemon=True).start()
            return self.snapshot()

    def cancel(self):
        self.cancelled.set()

    def _set(self, state, message='', account=None):
        self.state, self.message = state, message
        if account is not None:
            self.account = account

    def _wait_exit(self, proc, seconds) -> bool:
        try:
            proc.wait(timeout=seconds)
            return True
        except subprocess.TimeoutExpired:
            return False

    def read_cookie(self, profile: Path) -> str | None:
        """Open the profile invisibly with DevTools and ask Edge for its roblox.com login cookie."""
        port_file = profile / 'DevToolsActivePort'
        port_file.unlink(missing_ok=True)
        reader = subprocess.Popen([str(self.browser), f'--user-data-dir={profile}', '--remote-debugging-port=0', '--no-first-run',
                                   '--no-default-browser-check', EDGE_QUIET, '--disable-extensions', '--disable-component-update',
                                   '--disable-background-networking', '--disable-gpu', *self.reader_args, 'about:blank'])
        socket = None
        try:
            deadline = time.time() + 30
            while not port_file.exists():
                if time.time() > deadline or reader.poll() is not None:
                    raise VaultError('Edge could not reopen the sign-in profile')
                time.sleep(0.05)
            port = int(port_file.read_text(encoding='ascii').split()[0])
            info = json.loads(urllib.request.urlopen(f'http://127.0.0.1:{port}/json/version', timeout=5).read())
            socket = _WebSocket(info['webSocketDebuggerUrl'])
            return login_cookie_from((socket.call('Storage.getCookies').get('result') or {}).get('cookies'))
        finally:
            if socket is not None:
                try:
                    socket.call('Browser.close')
                except (OSError, ValueError):
                    pass
                socket.close()
            if not self._wait_exit(reader, 15):
                reader.kill()
                self._wait_exit(reader, 5)

    def _run(self):
        try:
            root = self.data / 'browser-login'
            root.mkdir(exist_ok=True)
            self.profile = root / secrets.token_hex(8)
            self.profile.mkdir()
            # A plain Edge window: only its own profile and the Roblox sign-in page.
            self.proc = subprocess.Popen([str(self.browser), f'--user-data-dir={self.profile}', '--no-first-run', '--no-default-browser-check',
                                          EDGE_QUIET, '--window-size=520,820', *self.extra_args, 'https://www.roblox.com/login'])
            opened = time.time()
            self._set('waiting', 'Sign in to Roblox in the Edge window. It closes by itself on your Roblox home page, or close it when you are signed in.')
            deadline = time.time() + self.TIMEOUT_SEC
            signed_in = False
            while self.proc.poll() is None:
                if self.cancelled.is_set() or time.time() > deadline:
                    WINDOWS.close(self.proc.pid)
                    if not self._wait_exit(self.proc, 15):
                        self.proc.kill()
                    return self._set('cancelled' if self.cancelled.is_set() else 'failed',
                                     'Sign-in cancelled' if self.cancelled.is_set() else 'Sign-in timed out after 15 minutes')
                # Started from the Control Center's window, Edge opens behind it: bring it forward
                # while it settles (it swaps its first window for the real one), then leave focus alone.
                if time.time() - opened < 10 and not WINDOWS.focused(self.proc.pid):
                    WINDOWS.bring_front(self.proc.pid)
                if not signed_in and any(signed_in_title(t) for _, t in WINDOWS.windows(self.proc.pid)):
                    signed_in = True
                    self._set('reading', 'Signed in: reading it from Edge')
                    time.sleep(0.6)  # Roblox sets its cookies before it opens the home page; a moment for the last ones.
                    WINDOWS.close(self.proc.pid)
                time.sleep(0.25)
            self._set('reading', 'Reading the sign-in from Edge')
            cookie = self.read_cookie(self.profile)
            if not cookie:
                return self._set('failed', 'No Roblox sign-in found: sign in completely before closing the window')
            self._set('reading', 'Checking the sign-in with Roblox')
            account = self.on_cookie(cookie)
            return self._set('success', f"Added {account.get('displayName') or account.get('username')}", account)
        except VaultError as exc:
            self._set('failed', str(exc))
        except (OSError, ValueError, KeyError) as exc:
            self._set('failed', f'Sign-in failed ({type(exc).__name__})')
        finally:
            if self.proc is not None and self.proc.poll() is None:
                self.proc.kill()
            if self.profile is not None:
                shutil.rmtree(self.profile, ignore_errors=True)  # The throwaway profile holds the session too.


class CookieChecker:
    """Checks cookies on demand and on the vault's schedule, one at a time."""

    def __init__(self, data: Path):
        self.data = data
        self.busy = set()
        self.lock = threading.Lock()
        self.started = time.time()
        self.last_round = None

    def check(self, ids=None) -> list:
        vault = load_vault(self.data)
        ids = [a['id'] for a in vault['accounts']] if not ids else [str(i) for i in ids]
        with self.lock:
            todo = [i for i in ids if i not in self.busy]
            self.busy.update(todo)
        if todo:
            threading.Thread(target=self._run, args=(todo,), daemon=True).start()
        return todo

    def _run(self, ids):
        for i, account_id in enumerate(ids):
            try:
                check_account(self.data, account_id)
            except (VaultError, OSError):
                pass
            finally:
                with self.lock:
                    self.busy.discard(account_id)
            if i + 1 < len(ids):
                time.sleep(1.0)  # Gentle on Roblox's rate limits.

    def tick(self, now: float):
        try:
            minutes = load_vault(self.data)['settings']['cookieCheckMinutes']
        except (VaultError, OSError):
            return
        # The first scheduled round runs two minutes after start, then every cookieCheckMinutes.
        due = now - self.started >= 120 if self.last_round is None else now - self.last_round >= minutes * 60
        if minutes and due:
            self.last_round = now
            self.check()


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
        if state not in ('STUCK CLIENT', 'LEAK GUARD', 'DISCONNECTED', 'VOLT STARTUP ERROR', 'CRITICAL COMMIT', 'NOT RESPONDING', 'COMMIT PRESSURE', 'FARM FREEZE'):
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
    elif kind == 'EXITED_CLIENT_RECOVERY_QUEUED':
        why = {'IN_GAME_DISCONNECT': 'disconnected', 'UNRESPONSIVE_EXIT': 'frozen', 'SUSTAINED_HANG': 'frozen'}.get(data.get('reason'), 'waiting for recovery')
        level, text = 'warning', f"{who()} closed while {why}; relaunch queued"
    elif kind == 'FARM_FREEZE_DETECTED':
        planned = data.get('planned') if isinstance(data.get('planned'), list) else []
        level, text = 'warning', (f"Farm-wide freeze: {data.get('frozen')} of {data.get('population')} clients stopped together; "
                                  f"recycling {len(planned)}, {data.get('spacingSec')} s apart")
    elif kind == 'FARM_FREEZE_EPISODE_END':
        members = data.get('members') if isinstance(data.get('members'), dict) else {}
        closed = int(members.get('Closed') or 0)
        text = f"Farm-freeze recovery {str(data.get('outcome', '')).lower()}: {closed} closed for relaunch"
    elif kind == 'NATIVE_LAUNCH_REQUEST':
        text = f"Launching {who()}" + (f" (attempt {data.get('attempt')})" if data.get('attempt') else '')
    elif kind == 'NATIVE_LAUNCH_RESULT':
        if data.get('requestAccepted'):
            level, text = 'good', f"{who()} started; waiting until it is in game"
        else:
            level, text = 'warning', f"{who()} not launched: {data.get('reason') or 'unknown reason'}"
    elif kind == 'NATIVE_COOKIE_DEAD':
        level, text = 'critical', f"{who()} is signed out (Roblox rejected its cookie); sign it in again"
    elif kind == 'NATIVE_CLIENT_CLOSED':
        text = f"Closed {who()} from the Control Center"
    elif kind == 'ACCOUNT_PROVIDER':
        text = 'Arkuzo now launches and relaunches clients (Volt not needed)' if data.get('provider') == 'arkuzo' else "Volt's account manager launches clients"
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
        if event.get('kind') == 'SUPERVISOR':
            self._persist(event)

    def _persist(self, event: dict):
        """Supervisor actions (starts, stops, kills) outlive the Control Center for diagnosis."""
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            path = self.directory / 'control-center.log'
            if path.exists() and path.stat().st_size > 1048576:
                path.replace(self.directory / 'control-center.previous.log')
            stamp = time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(event.get('t') or time.time()))
            with open(path, 'a', encoding='utf-8') as out:
                out.write(json.dumps({'time': stamp, 'level': event.get('level'), 'text': event.get('text')}, ensure_ascii=False) + '\n')
        except OSError:
            pass  # Diagnostics never stop supervision.

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
        self.last_beat = None   # updatedUtc of the newest heartbeat from our own saver process.
        self.last_tick = None
        self.resume_grace_until = 0.0
        self.unreadable_since = None  # When the heartbeat file last turned unreadable.
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
            self.last_beat = None
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
            if self.last_tick is not None and now - self.last_tick > SUSPEND_GAP_SEC:
                # After sleep or a stall every heartbeat looks old; give the saver time to write a new one.
                self.resume_grace_until = now + HANG_SEC
            self.last_tick = now
            if heartbeat is None:
                if self.unreadable_since is None:
                    self.unreadable_since = now
            else:
                self.unreadable_since = None
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
                    if hb_pid == self.proc.pid and updated is not None:
                        self.last_beat = updated if self.last_beat is None else max(self.last_beat, updated)
                    # Silence counts from the last heartbeat ever seen, so one unreadable or
                    # replaced-in-flight sample never looks like silence since the saver started.
                    fresh = self.last_beat is not None and now - self.last_beat <= HEARTBEAT_FRESH_SEC
                    silent = now - (self.last_beat if self.last_beat is not None else self.proc_started)
                    if fresh:
                        self.state, self.message = 'running', 'Saver running under autopilot.' if autopilot else 'Saver running.'
                        if now - self.proc_started > STABLE_RESET_SEC:
                            self.failures = 0
                    elif now - self.proc_started > START_GRACE_SEC and silent > HANG_SEC and now >= self.resume_grace_until:
                        phase = self.stall_phase(self.proc.pid)
                        self.proc.kill()
                        self.proc = None
                        self._record_failure(now, f'Saver stopped responding for {int(silent)}s{phase} and was terminated.')
                    elif self.state != 'running':
                        self.state, self.message = 'starting', 'Saver starting...'
                    else:
                        self.message = f'Waiting for saver heartbeat ({int(silent)}s).'
                return self._maybe_restart(now, heartbeat, autopilot)
            if heartbeat is None and self.state in ('running', 'starting', 'external') and now - self.unreadable_since < HANG_SEC:
                return  # Heartbeat briefly unreadable: no verdict on a running saver yet, no restart.
            ext = self.external(heartbeat, now)
            if ext:
                self.initial_start = False
                if ext['age'] is not None and ext['age'] <= HEARTBEAT_FRESH_SEC:
                    self.state, self.message = 'external', 'Saver running (started outside the Control Center).'
                    return
                if ext['age'] is not None and ext['age'] > HANG_SEC and autopilot and not self.operator_stopped and now >= self.resume_grace_until:
                    phase = self.stall_phase(ext['pid'])
                    if WIN32.terminate(ext['pid'], ext['ticks']):
                        self._record_failure(now, f"Saver PID {ext['pid']} stopped responding{phase} and was terminated.")
                    return
                self.state, self.message = 'external', 'Saver is running but its heartbeat is late.'
                return
            if self.state in ('running', 'starting', 'external') and not self.operator_stopped:
                self._record_failure(now, 'Saver is no longer running.')
            elif self.state not in ('restarting', 'crashed'):
                self.state = 'stopped'
                self.message = 'Saver stopped by operator.' if self.operator_stopped else 'Saver is not running.'
            return self._maybe_restart(now, heartbeat, autopilot)

    def stall_phase(self, pid: int) -> str:
        """' while <phase>' from the saver's own stall watchdog, if it wrote one."""
        stall = read_json(self.data / 'saver-stall.json')
        if isinstance(stall, dict) and int(stall.get('pid') or 0) == pid and stall.get('phase'):
            return f" while busy with '{str(stall['phase'])[:80]}'"
        return ''

    def _record_failure(self, now: float, message: str):
        self.failures += 1
        self.crashes.append(now)
        self.next_restart = now + restart_delay(self.failures)
        recent = [t for t in self.crashes if now - t <= CRASH_LOOP_WINDOW_SEC]
        self.crash_loop = len(recent) >= CRASH_LOOP_LIMIT
        if self.crash_loop:
            self.next_restart = now + CRASH_LOOP_RETRY_SEC
        autopilot = bool(self.prefs.get('autopilot', True))
        self.state = 'restarting' if autopilot and not self.crash_loop else 'crashed'
        if self.crash_loop:
            message += ' Repeated failures: retrying every 10 minutes; see the saver log.' if autopilot else ' Repeated failures.'
        elif not autopilot:
            message += ' Autopilot is off.'
        self.message = message
        self.feed.add({'t': now, 'kind': 'SUPERVISOR', 'category': 'error', 'level': 'critical', 'text': self.message})

    def _maybe_restart(self, now, heartbeat, autopilot):
        if self.proc is not None or self.operator_stopped:
            return
        if self.crash_loop:
            if autopilot and now >= self.next_restart and not self.external(heartbeat, now):
                self.start('autopilot')
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
                'restartInSec': max(0, round(self.next_restart - now)) if self.state == 'restarting' or (self.state == 'crashed' and self.crash_loop) else None,
            }


# ------------------------------------------------------------- derived view
def derive_issues(hb, age, supervisor_state) -> list:
    issues = []

    def add(level, title, detail=''):
        issues.append({'level': level, 'title': title, 'detail': detail})

    if supervisor_state.get('crashLoop'):
        add('critical', 'The saver keeps failing', (supervisor_state.get('message') or '') + ' Press Start to retry now.')
    if not isinstance(hb, dict):
        if supervisor_state.get('state') not in ('stopped',):
            add('warning', 'No saver heartbeat yet')
        return issues
    if age is not None and age > HEARTBEAT_FRESH_SEC:
        if supervisor_state.get('state') in ('running', 'external', 'starting'):
            add('warning', f'Saver heartbeat is {int(age)}s old', 'The saver may be busy with Volt or recovery IO.')
        else:
            add('warning', 'Saver is not running: figures below are its last report',
                time.strftime('Last report %H:%M:%S', time.localtime(time.time() - age)) + '. Clients are not being managed or recovered.')
    if hb.get('logFailed'):
        add('critical', 'Saver audit logging failed', 'Destructive recovery is blocked until the saver restarts.')
    if not hb.get('recoveryJournalHealthy'):
        add('critical', 'Recovery journal is not healthy', 'Recovery is blocked; check data/recovery-state.json.')
    if not (hb.get('recovery') or {}).get('enabled'):
        add('warning', 'Account recovery is disabled in settings')
    arkuzo = hb.get('accountProvider') == 'arkuzo'
    if not arkuzo and not hb.get('voltControlAvailable'):  # Only Volt farms need Volt's Account Manager.
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
        until = parse_utc(q.get('untilUtc'))
        if until is not None and until <= time.time():
            continue  # Expired; the engine retries this account normally.
        add('warning', f"{q.get('username') or 'An account'} is quarantined",
            f"{q.get('retryCount')} failed recoveries; retried automatically after the quarantine ends.")
    dead = hb.get('suspendedAccounts') or []
    if dead:
        add('warning', f'{len(dead)} account(s) paused with a dead cookie',
            'Add them again on the Accounts page (cookie or browser sign-in); they resume automatically.' if arkuzo
            else 'Log those accounts in again in Volt; they resume automatically.')
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
        # Open pages poll with their own id and send a beacon when their window closes.
        self.version = RUNTIME_VERSION
        self.instance = secrets.token_hex(6)  # Pages reload when this changes (an update took over).
        self.pages = {}  # page id -> last poll time
        self.close_at = None
        self.close_pending = False  # A window closed while other registrations remained.
        self.pages_lock = threading.Lock()
        self.cookies = CookieChecker(data)
        self.login = BrowserLogin(data, find_edge())
        # A sign-in window cut off by a crash leaves a signed-in throwaway profile behind.
        shutil.rmtree(data / 'browser-login', ignore_errors=True)

    def save_prefs(self):
        write_json_atomic(self.prefs_path, self.prefs)

    def shutdown(self):
        self.stop_event.set()
        if self.server:
            self.server.shutdown()

    def page_seen(self, page: str, now: float | None = None):
        if page:
            with self.pages_lock:
                self.pages[page] = time.time() if now is None else now
                self.close_at = None
                self.close_pending = False  # A live window polled: nothing is closing.

    def page_closed(self, page: str, now: float | None = None):
        now = time.time() if now is None else now
        with self.pages_lock:
            if page not in self.pages:
                return  # Only a window this Control Center served can close it.
            del self.pages[page]
            # Ids left behind by windows that reloaded or vanished must not keep it running.
            for stale in [p for p, seen in self.pages.items() if now - seen > PAGE_STALE_SEC]:
                del self.pages[stale]
            if not self.pages:
                self.close_at = now + WINDOW_CLOSE_GRACE_SEC
            else:
                self.close_pending = True

    def window_close_due(self, now: float) -> bool:
        """The last window closed and none reopened within the grace period. If a window
        closed while other ids stayed registered, it quits once none of them has polled for
        PAGE_STALE_SEC (they were reloaded or vanished). A page that disappears without its
        beacon and with no other window ever closing keeps the Control Center running."""
        with self.pages_lock:
            if self.close_at is not None and not self.pages and now >= self.close_at:
                return True
            return self.close_pending and bool(self.pages) and all(now - seen > PAGE_STALE_SEC for seen in self.pages.values())

    def names(self) -> dict:
        hb = self.heartbeat if isinstance(self.heartbeat, dict) else {}
        return {a.get('accountId'): a.get('username') for a in hb.get('accounts') or [] if a.get('accountId') and a.get('username')}

    def loop(self):
        while not self.stop_event.is_set():
            now = time.time()
            if self.window_close_due(now):
                # Closing the window exits like Stop farm & quit, saver included. Only a window
                # that polls during the stop counts as reopened; stale ids are forgotten here.
                with self.pages_lock:
                    self.pages.clear()
                    self.close_at = None
                    self.close_pending = False
                was_running = self.supervisor.state in ('running', 'starting', 'restarting', 'external')
                self.supervisor.stop()
                with self.pages_lock:
                    reopened = bool(self.pages)
                if not reopened:
                    self.shutdown()
                    return
                if was_running:
                    self.supervisor.start()  # A window came back while the saver stopped: carry on.
            self.heartbeat = read_json(self.data / 'runtime-status.json', retry_missing=True)
            try:
                self.supervisor.tick(self.heartbeat, now)
            except Exception as exc:  # The supervisor must outlive any single failure.
                self.supervisor.message = f'Supervisor error: {type(exc).__name__}'
            self.feed.poll(self.names())
            try:
                self.cookies.tick(now)
            except Exception:  # A cookie check must never stop the supervisor loop.
                pass
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

    def vault_view(self) -> dict:
        """Accounts without secrets, joined with what the saver sees live."""
        error = None
        try:
            vault = load_vault(self.data)
        except (OSError, VaultError) as exc:
            vault, error = empty_vault(), str(exc)
        view = public_vault(vault)
        hb = self.heartbeat if isinstance(self.heartbeat, dict) else {}
        live = {a.get('accountId'): a for a in hb.get('accounts') or [] if isinstance(a, dict)}
        for a in view['accounts']:
            seen = live.get(a['id']) or {}
            a['live'] = {'uiStatus': seen.get('uiStatus'), 'processId': seen.get('processId')}
            a['checking'] = a['id'] in self.cookies.busy
        config = read_json(self.data / 'config.json') or {}
        view.update(monitors=monitor_count(), screen=work_area(), error=error, provider=((config.get('accounts') or {}).get('provider') or 'auto'),
                    activeProvider=hb.get('accountProvider'), providerNotice=hb.get('accountProviderNotice'),
                    login=self.login.snapshot(), browserLogin=self.login.browser is not None)
        return view

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
                'health', 'recovery', 'logFailed', 'updateAvailable', 'accountProvider', 'accountProviderNotice')}
            view['pagefile'] = {k: (hb.get('pagefile') or {}).get(k) for k in ('status', 'reason', 'pendingReboot')}
        return {
            'app': APP_ID, 'version': self.version, 'instance': self.instance, 'windows': sum(1 for seen in list(self.pages.values()) if now - seen <= PAGE_STALE_SEC),
            'now': now, 'dataDirectory': str(self.data), 'supervisor': sup,
            'prefs': dict(self.prefs, startWithWindows=startup_enabled()),
            'heartbeat': view, 'heartbeatAgeSec': age,
            'history': [{k: v for k, v in p.items() if k != 'hb'} for p in self.history if p['t'] > since],
            'events': self.feed.since(events_since), 'issues': derive_issues(hb, age, sup),
        }


def startup_command(data: Path) -> str:
    # Launcher installs run from app/control-center/<version>/: start the
    # launcher instead, so every sign-in updates first and never pins this version.
    launcher = RUNTIME.parent.parent.parent / 'ArkuzoMemorySaver.exe'
    if RUNTIME.parent.name == 'control-center' and launcher.exists():
        return f'"{launcher}"'
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
            return self._send(200, {'app': APP_ID, 'version': self.app.version, 'instance': self.app.instance})
        if url.path == '/api/state':
            # A page still showing a replaced Control Center polls once before it reloads;
            # it must not count as an open window here, or closing the real one never quits.
            if (query.get('inst') or [''])[0] in ('', self.app.instance):
                self.app.page_seen((query.get('page') or [''])[0][:64])
            try:
                since = float((query.get('since') or ['0'])[0])
                events = int((query.get('events') or ['0'])[0])
            except ValueError:
                since, events = 0.0, 0
            return self._send(200, self.app.state(since, events))
        if url.path == '/api/vault':
            return self._send(200, self.app.vault_view())
        if url.path == '/api/avatar':
            uid = (query.get('userId') or [''])[0]
            png = avatar_png(self.app.data, uid) if DIGITS.match(uid) else None
            return self._send(200, png, 'image/png') if png else self._send(404, {'error': 'no avatar'})
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
        if not self._host_ok():
            return self._send(403, {'error': 'forbidden'})
        try:
            body = json.loads(raw or b'{}')
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            body = None
        app, path = self.app, urllib.parse.urlparse(self.path).path
        token = self.headers.get('X-Arkuzo-Token', '')
        if not token and path == '/api/window-closed' and body:
            token = str(body.get('token') or '')  # A closing window can only send a beacon, which has no headers.
        if not secrets.compare_digest(token.encode('utf-8', 'replace'), app.token.encode('ascii')):
            return self._send(403, {'error': 'forbidden'})
        if body is None:
            return self._send(400, {'error': 'Invalid JSON'})
        try:
            if path == '/api/window-closed':
                app.page_closed(str(body.get('page') or '')[:64])
                return self._send(200, {'result': 'noted'})
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
            if path.startswith('/api/vault/') or path.startswith('/api/farm/'):
                return self._send(200, {'result': vault_action(app, path, body)})
            if path == '/api/quit':
                if body.get('stopSaver'):
                    app.supervisor.stop()
                threading.Thread(target=app.shutdown, daemon=True).start()
                return self._send(200, {'result': 'bye'})
        except (ConfigError, VaultError) as exc:
            return self._send(400, {'error': str(exc)})
        except OSError as exc:
            return self._send(500, {'error': f'{type(exc).__name__}: {exc.strerror or exc}'})
        return self._send(404, {'error': 'not found'})


def vault_action(app: App, path: str, body: dict):
    data = app.data
    if path == '/api/vault/add':
        return add_account(data, str(body.get('cookie') or ''))
    if path == '/api/vault/login':
        return app.login.start()
    if path == '/api/vault/login/cancel':
        app.login.cancel()
        return app.login.snapshot()
    if path == '/api/vault/check':
        ids = body.get('ids')
        return {'checking': app.cookies.check(ids if isinstance(ids, list) else None)}
    if path == '/api/vault/update':
        return update_account(data, str(body.get('id') or ''), body.get('fields'))
    if path == '/api/vault/remove':
        remove_account(data, str(body.get('id') or ''))
        return 'removed'
    if path in ('/api/vault/launch', '/api/vault/close'):
        return request_account_action(data, str(body.get('id') or ''), path.rsplit('/', 1)[1])
    if path == '/api/vault/settings':
        return update_vault_settings(data, body.get('changes'))
    if path == '/api/vault/arrange':
        return update_vault_settings(data, {'arrangeRequestedAtMs': now_ms()})
    if path == '/api/vault/servers/add':
        return add_private_server(data, str(body.get('name') or ''), str(body.get('link') or ''))
    if path == '/api/vault/servers/remove':
        remove_private_server(data, str(body.get('id') or ''))
        return 'removed'
    if path == '/api/farm/start':
        settings = set_farm_running(data, True)
        if app.supervisor.state not in ('running', 'starting', 'restarting', 'external'):
            app.supervisor.start()  # The saver does the launching.
        return settings
    if path == '/api/farm/stop':
        return set_farm_running(data, False, close_clients=bool(body.get('closeClients')))
    raise VaultError('Unknown account action')


def work_area() -> list:
    """Main screen size and work area (without the taskbar) in logical pixels, like the layout settings."""
    if os.name != 'nt':
        return [1920, 1080, 1920, 1040]
    try:
        u = ctypes.windll.user32
        rect = wintypes.RECT()
        u.SystemParametersInfoW(0x30, 0, ctypes.byref(rect), 0)  # SPI_GETWORKAREA
        return [u.GetSystemMetrics(0), u.GetSystemMetrics(1), rect.right - rect.left, rect.bottom - rect.top]
    except OSError:
        return [1920, 1080, 1920, 1040]


def monitor_count() -> int:
    if os.name != 'nt':
        return 1
    try:
        return max(1, ctypes.windll.user32.GetSystemMetrics(80))  # SM_CMONITORS
    except OSError:
        return 1


def avatar_png(data: Path, user_id: str) -> bytes | None:
    """Avatar headshots are cached in data/avatars (the page only loads images from itself)."""
    folder = data / 'avatars'
    path = folder / f'{user_id}.png'
    try:
        if path.exists() and time.time() - path.stat().st_mtime < 86400:
            return path.read_bytes()
    except OSError:
        pass
    resp = HTTP['request'](f'https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds={user_id}&size=48x48&format=Png&isCircular=false')
    url = str((((resp.json() or {}).get('data') or [{}])[0] or {}).get('imageUrl') or '') if resp.status == 200 else ''
    host = urllib.parse.urlparse(url).hostname or ''
    if not url.startswith('https://') or not host.endswith('.rbxcdn.com'):
        return None
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': ROBLOX_UA}), timeout=10) as r:
            png = r.read(1048576)
    except (OSError, ValueError):
        return None
    if not png.startswith(b'\x89PNG'):
        return None
    try:
        folder.mkdir(exist_ok=True)
        path.write_bytes(png)
    except OSError:
        pass
    return png


def find_edge():
    """Microsoft Edge only: browser sign-in uses the real Edge, as Windows ships it."""
    for base in (os.environ.get('ProgramFiles(x86)'), os.environ.get('ProgramFiles'), os.environ.get('LOCALAPPDATA')):
        if base and (Path(base) / r'Microsoft\Edge\Application\msedge.exe').exists():
            return Path(base) / r'Microsoft\Edge\Application\msedge.exe'
    return None


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


def _fetch(port: int, path: str, timeout=5.0, body: bytes | None = None, headers=None) -> bytes:
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=body, headers=headers or {}, method='POST' if body is not None else 'GET')
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read()


def running_control_center(port: int) -> dict | None:
    try:
        info = json.loads(_fetch(port, '/api/ping', timeout=1.5))
    except (OSError, ValueError):
        return None
    return info if isinstance(info, dict) and info.get('app') == APP_ID else None


def already_running(port: int) -> bool:
    return running_control_center(port) is not None


def take_over(port: int, data: Path, wait_sec=40.0) -> dict | None:
    """Replaces an older Control Center that serves the same data folder: it is
    asked to quit like Settings > Quit app, stopping its saver, and the port is
    freed. Returns what the new one needs to carry on, or None to leave it be."""
    info = running_control_center(port)
    if not info or not should_take_over(RUNTIME_VERSION, info.get('version')):
        return None
    try:
        state = json.loads(_fetch(port, '/api/state'))
        theirs = str(state.get('dataDirectory') or '')
        if not theirs or os.path.normcase(str(Path(theirs).resolve())) != os.path.normcase(str(data)):
            return None
        sup = state.get('supervisor') or {}
        age = state.get('heartbeatAgeSec')
        saver_running = sup.get('state') in ('running', 'starting', 'restarting', 'external') or (
            isinstance(age, (int, float)) and age <= HEARTBEAT_FRESH_SEC)
        page = _fetch(port, '/').decode('utf-8', 'replace')
        token = re.search(r"const TOKEN = '([A-Za-z0-9_\-]+)'", page)
        if not token:
            return None
        # The old saver runs the old engine, so it stops here and restarts from this version.
        _fetch(port, '/api/quit', timeout=60, body=b'{"stopSaver": true}',
               headers={'Content-Type': 'application/json', 'X-Arkuzo-Token': token.group(1)})
    except (OSError, ValueError, AttributeError):
        return None
    deadline = time.monotonic() + wait_sec
    while already_running(port) and time.monotonic() < deadline:
        time.sleep(0.25)
    if already_running(port):
        return None
    return {'from': info.get('version'), 'saverWasRunning': saver_running, 'windowsOpen': int(state.get('windows') or 0)}


def make_server(app: App) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(('127.0.0.1', app.port), type('BoundHandler', (Handler,), {'app': app}))
    server.daemon_threads = True
    return server


def serve(app: App):
    app.server = make_server(app)
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
    handover = None
    if already_running(args.port):
        handover = take_over(args.port, data)
        if handover is None:  # Same or newer version, or another data folder: just show it.
            if not args.background:
                open_window(url)
            return 0
    app = App(data, args.port)
    if handover:
        # Keep the saver as it was: running stays running (now on this engine), stopped stays stopped.
        app.supervisor.initial_start = handover['saverWasRunning']
        before = f"v{handover['from']}" if handover['from'] else 'an earlier version'
        app.feed.add({'t': time.time(), 'kind': 'SUPERVISOR', 'category': 'saver', 'level': 'info',
                      'text': f'Control Center updated from {before} to v{RUNTIME_VERSION}'})
    # Windows of the replaced Control Center reload onto this one by themselves.
    if not args.background and not (handover and handover['windowsOpen']):
        threading.Timer(0.6, open_window, args=(url,)).start()
    for attempt in range(40):
        try:
            serve(app)
            break
        except OSError as exc:
            if not handover or attempt == 39:  # Right after a handover the port can take a moment to free.
                print(f'Control Center could not listen on 127.0.0.1:{args.port}: {exc}', file=sys.stderr)
                return 1
            time.sleep(0.25)
        except KeyboardInterrupt:
            break
    return 0


if __name__ == '__main__':
    sys.exit(main())
