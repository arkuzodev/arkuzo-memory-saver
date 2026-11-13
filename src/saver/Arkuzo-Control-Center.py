"""Arkuzo Control Center: local dashboard and saver supervisor.

Serves a single-page UI on 127.0.0.1 only. It reads the saver heartbeat
(runtime-status.json), tails the diagnostic log, edits config.json with the
same validation the engine applies, and keeps the saver running (autopilot)
with bounded, backed-off restarts. Standard library only.

Its account manager (data/accounts.json) stores Roblox login cookies encrypted
with Windows DPAPI for the current user, checks them with Roblox and can sign
in through a small browser window. Cookies never leave that file in plain text:
no API response, log line or command line carries them. It never writes Volt
state and never launches a client: launching stays inside the saver engine,
which reads the same vault. The one thing it does to a Roblox process is the
instant Close / Close all / Stop farm (close_live_clients): it ends a client
only when the saver's heartbeat maps it to exactly one Arkuzo account and the
live process has the same PID, start time and image name.
"""
from __future__ import annotations

import argparse
import base64
import collections
import ctypes
import datetime as dt
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
import zipfile
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
# Restarts never back off far: every minute the saver is down is a minute the farm runs
# unmanaged. The first retry waits RESTART_FLOOR_SEC, every later one RESTART_MAX_SEC, so a
# saver that dies at once can never busy-loop. A crash loop (CRASH_LOOP_LIMIT failures in
# CRASH_LOOP_WINDOW_SEC) is only shown as such; it keeps retrying every CRASH_LOOP_RETRY_SEC.
RESTART_FLOOR_SEC = 5
RESTART_MAX_SEC = 10
CRASH_LOOP_RETRY_SEC = 15
# A pause this long in the 2 s supervisor loop means the PC slept or stalled; that is not the saver's silence.
SUSPEND_GAP_SEC = 30
# After the last window closes the Control Center quits; a page reload reconnects well within this.
WINDOW_CLOSE_GRACE_SEC = 8
# Open windows poll every 2 s (a minimized, throttled one about once a minute). A page id
# not seen for this long belongs to a window that is gone, e.g. one reloaded after an update.
PAGE_STALE_SEC = 180

# The heartbeat (data/runtime-status.json) is a contract with the engine: contracts/runtime-status.json.
# An engine from before schemaVersion existed writes none; a newer one is still read, with a notice.
HEARTBEAT_SCHEMA_VERSION = 1
# What /api/state passes on to the page. A new heartbeat key the page needs is added here and in the contract.
HEARTBEAT_VIEW_KEYS = (
    'schemaVersion', 'version', 'pid', 'uptimeSec', 'trims', 'totals', 'settings', 'systemMemory', 'totalPhysicalMB', 'clients',
    'accounts', 'pending', 'quarantined', 'suspendedAccounts', 'alerts', 'voltControlAvailable',
    'recoveryJournalHealthy', 'missingRecoveryBlocked', 'expectedAccounts', 'missingAccounts', 'pendingRecoveries',
    'health', 'recovery', 'logFailed', 'updateAvailable', 'accountProvider', 'accountProviderNotice', 'remoteSession',
    'robloxVersion')

# Config rules, presets and account-vault settings come from contracts/config-schema.json, the one
# source: the blocks below are generated from it, and tests check the engine and the page against it.
# Rules are (kind, min, max) for numbers, ('bool',) and ('enum', values) otherwise; ranges match the
# engine validators so a saved file is never rejected on reload. TOP_LEVEL holds only real preset
# names (the engine's -Mode ValidateSet). RESTART_KEYS need a saver restart; everything else in
# settings/health/recovery is applied by the running saver. accounts.provider: who launches and
# relaunches clients (auto = Arkuzo once data/accounts.json has an account, otherwise Volt).
# BEGIN GENERATED config-schema: written by build/bundle.ps1 from contracts/config-schema.json. Edit the schema, then run build/bundle.ps1.
PRESETS = {
    'normal': {
        'target_ram_mb': 850, 'trim_enabled': True, 'trim_every_sec': 120, 'priority': 'BelowNormal', 'cores_per_instance': 4,
        'hard_limit': False, 'poll_ms': 500, 'minimize_on_launch': False, 'apply_graphics_flags': False, 'memory_priority': 'BelowNormal',
        'adaptive_trim': True, 'pressure_trim_available_percent': 15,
    },
    'agressive': {
        'target_ram_mb': 600, 'trim_enabled': True, 'trim_every_sec': 60, 'priority': 'BelowNormal', 'cores_per_instance': 2,
        'hard_limit': False, 'poll_ms': 350, 'minimize_on_launch': False, 'apply_graphics_flags': False, 'memory_priority': 'Low',
        'adaptive_trim': True, 'pressure_trim_available_percent': 20,
    },
    'extreme': {
        'target_ram_mb': 450, 'trim_enabled': True, 'trim_every_sec': 30, 'priority': 'BelowNormal', 'cores_per_instance': 1,
        'hard_limit': False, 'poll_ms': 250, 'minimize_on_launch': False, 'apply_graphics_flags': False, 'memory_priority': 'VeryLow',
        'adaptive_trim': True, 'pressure_trim_available_percent': 25,
    },
}
SCHEMA = {
    'settings': {
        'target_ram_mb': ('int', 128, 32768),
        'trim_every_sec': ('int', 1, 120),
        'cores_per_instance': ('int', 1, 64),
        'poll_ms': ('int', 250, 10000),
        'pressure_trim_available_percent': ('int', 5, 60),
        'trim_enabled': ('bool',),
        'adaptive_trim': ('bool',),
        'hard_limit': ('bool',),
        'minimize_on_launch': ('bool',),
        'apply_graphics_flags': ('bool',),
        'priority': ('enum', ('Idle', 'BelowNormal', 'Normal')),
        'memory_priority': ('enum', ('VeryLow', 'Low', 'Medium', 'BelowNormal', 'Normal')),
    },
    'health': {
        'enabled': ('bool',),
        'private_limit_mb': ('int', 1024, 16384),
        'hang_timeout_sec': ('int', 60, 900),
        'warmup_sec': ('int', 60, 900),
        'config_grace_sec': ('int', 10, 300),
        'pressure_percent': ('int', 60, 98),
        'pressure_min_private_mb': ('int', 1024, 16384),
        'cooldown_sec': ('int', 30, 300),
        'max_recycles_per_hour': ('int', 1, 60),
        'trim_spacing_sec': ('int', 1, 30),
        'startup_error_timeout_sec': ('int', 0, 300),
        'disconnect_timeout_sec': ('int', 0, 300),
        'private_limit_sustain_sec': ('int', 0, 300),
        'farm_freeze_enabled': ('bool',),
        'farm_freeze_confirm_sec': ('int', 20, 120),
        'farm_freeze_min_clients': ('int', 3, 50),
        'farm_freeze_onset_window_sec': ('int', 5, 60),
        'farm_freeze_max_cpu_percent': ('int', 1, 10),
        'farm_freeze_spacing_sec': ('int', 10, 60),
        'farm_freeze_refreeze_sec': ('int', 0, 86400),
        'farm_freeze_remote_confirm_sec': ('int', 10, 120),
        'farm_freeze_remote_window_sec': ('int', 10, 300),
        'remote_hold_max_sec': ('int', 0, 3600),
        'keep_display_awake': ('bool',),
    },
    'recovery': {
        'enabled': ('bool',),
        'restore_missing': ('bool',),
        'restore_wait_sec': ('int', 90, 900),
        'relaunch_delay_sec': ('int', 30, 120),
        'retry_base_sec': ('int', 90, 900),
        'retry_max_sec': ('int', 180, 3600),
        'retry_max_per_hour': ('int', 1, 500),
        'ready_stable_sec': ('int', 30, 300),
        'abandon_after_retries': ('int', 1, 100),
        'abandon_after_sec': ('int', 900, 86400),
        'quarantine_sec': ('int', 0, 86400),
    },
    'accounts': {
        'provider': ('enum', ('auto', 'arkuzo', 'volt')),
    },
}
TOP_LEVEL = {'selected_preset': ('enum', ('normal', 'agressive', 'extreme')), 'config_lock': ('bool',)}
RESTART_KEYS = {'apply_graphics_flags', 'hard_limit'}
# END GENERATED config-schema

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
    'NATIVE_COOKIE_DEAD': 'recovery', 'NATIVE_ACCOUNT_MODERATED': 'recovery',
    'NATIVE_LAUNCH_STARTED': 'recovery', 'NATIVE_LAUNCH_FAILED': 'recovery', 'NATIVE_LAUNCH_EXITED': 'recovery',
    'LOG_WRITE_RECOVERED': 'saver', 'LOG_RETENTION': 'saver',
    'ROBLOX_SAVED_LOGIN_SET_ASIDE': 'recovery', 'ACCOUNT_PROVIDER': 'saver', 'NATIVE_LAUNCH_BLOCKED': 'warning',
    'REMOTE_SESSION_CHANGED': 'saver', 'KEEP_AWAKE': 'saver',
    'VAULT_READ_FROM_BACKUP': 'error', 'ROBLOX_BUILD_FAILING': 'error', 'ROBLOX_BUILD_GUARD_RESET': 'saver',
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


def write_bytes_durable(path: Path, data: bytes, exclusive: bool = False) -> None:
    """Write data and flush it to the disk before returning. A rename the file system journals
    while the data is still in the cache leaves a zero-filled file after a crash (11 Nov: the
    blue screen during a vault save left accounts.json as 28 KB of NUL)."""
    with open(path, 'xb' if exclusive else 'wb') as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())


def write_bytes_atomic(path: Path, data: bytes, durable: bool = True) -> None:
    """Temp file (flushed to the disk unless durable is False), then an atomic replace."""
    temp = path.with_name(path.name + f'.{os.getpid()}.{threading.get_ident()}.tmp')
    try:
        if durable:
            write_bytes_durable(temp, data)
        else:
            temp.write_bytes(data)
        for attempt in range(5):
            try:
                os.replace(temp, path)
                return
            except PermissionError:
                if attempt == 4:
                    raise
                time.sleep(0.06)
    finally:
        temp.unlink(missing_ok=True)


def write_json_atomic(path: Path, value, durable: bool = True) -> None:
    """Every JSON file the Control Center writes holds user state (vault, config, prefs, the
    Roblox protocol backup), so all of them are flushed to the disk before the replace."""
    write_bytes_atomic(path, json.dumps(value, indent=4, ensure_ascii=False).encode('utf-8'), durable)


def copy_file_durable(source: Path, target: Path) -> None:
    write_bytes_atomic(target, source.read_bytes())


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

    def terminate(self, pid: int, start_ticks: int, images=('powershell.exe', 'pwsh.exe')) -> bool:
        """Terminate only the exact process generation the heartbeat named."""
        ident = self.identity(pid)
        if not ident or not start_ticks or ident[0] != start_ticks or ident[1] not in images:
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
ROBLOX_VERSION = re.compile(r'\Aversion-[0-9a-f]{16}\Z')

# BEGIN GENERATED vault-settings: written by build/bundle.ps1 from contracts/config-schema.json. Edit the schema, then run build/bundle.ps1.
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
    'robloxVersion': (('robloxversion',), 'auto'),
    'robloxVersionFallback': (('bool',), False),
    'robloxVersionsDir': (('folder',), ''),
    'robloxVersionFollow': (('robloxfollow',), ''),
    'robloxFollowRestart': (('bool',), False),
    'robloxProtocol': (('bool',), False),
    'cookieCheckMinutes': (('int', 0, 1440), 60),
    'arrangeWindows': (('bool',), True),
    'arrangeLayout': (('enum', ('auto', 'grid', 'cascade')), 'auto'),
    'arrangeOverflow': (('enum', ('minimize', 'overlap')), 'minimize'),
    'arrangePerRow': (('int', 1, 12), 2),
    'arrangeWidth': (('int', 160, 1920), 800),
    'arrangeHeight': (('int', 120, 1440), 622),
    'arrangeGap': (('int', 0, 40), 4),
    'arrangeCorner': (('enum', ('top-left', 'top-right', 'bottom-left', 'bottom-right')), 'top-left'),
    'arrangeMonitor': (('int', 0, 8), 0),
    'arrangeOrder': (('enum', ('fixed', 'name', 'launch')), 'fixed'),
    'arrangeMode': (('enum', ('keep', 'once')), 'keep'),
    'arrangeVisibility': (('enum', ('normal', 'background', 'minimized')), 'normal'),
    'arrangeRequestedAtMs': (('int', 0, 9007199254740992), 0),
}
# END GENERATED vault-settings
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
    return {'schemaVersion': 1, 'settings': {k: v[1] for k, v in VAULT_SETTINGS.items()}, 'accounts': [], 'privateServers': [], 'trash': []}


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
    if rule[0] == 'robloxversion':
        if value == 'auto' or (isinstance(value, str) and ROBLOX_VERSION.match(value)):
            return value
        raise VaultError('Roblox version must be "auto" or version- followed by 16 hex digits')
    if rule[0] == 'folder':
        return validate_versions_dir(value)
    if rule[0] == 'robloxfollow':
        return validate_follow(value)
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
    # Deleted accounts wait here for UNDO_SEC (encrypted, like every row), then are gone for good.
    vault['trash'] = [t for t in raw.get('trash') or [] if isinstance(t, dict) and isinstance(t.get('account'), dict)
                      and isinstance(t.get('batch'), str) and isinstance(t.get('deletedAtMs'), int)][:500]
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
        status = a.get('cookieStatus') if a.get('cookieStatus') in COOKIE_STATES else 'unknown'
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


# Backups (docs/accounts.md). Every save keeps the content it replaces, when that is a valid
# vault, as accounts.json.bak, and the first save of each UTC hour writes a snapshot
# vault-backups/accounts-YYYYMMDD-HH.json. The newest VAULT_SNAPSHOT_KEEP snapshots are kept, and
# beyond those the newest of each day of the last VAULT_SNAPSHOT_DAYS days. The engine
# (Save-ArkuzoVaultFile) follows the same rules. A damaged accounts.json is restored from the
# .bak, else from the newest valid snapshot; the damaged file is kept next to it.
VAULT_BACKUP = VAULT_FILE + '.bak'
VAULT_SNAPSHOT_DIR = 'vault-backups'
VAULT_SNAPSHOT_NAME = re.compile(r'\Aaccounts-(\d{8})-(\d{2})\.json\Z')
VAULT_SNAPSHOT_KEEP = 72
VAULT_SNAPSHOT_DAYS = 7
VAULT_DAMAGED = ('data/accounts.json is damaged and no valid backup was found, so it was left untouched. '
                 'Start a new account list to set it aside (it is kept as accounts.json.damaged-...), or fix the file.')
_vault_events: list = []  # Restores and resets waiting for the activity feed (App drains them).
_vault_events_lock = threading.Lock()


class VaultDamagedError(VaultError):
    pass


def parse_vault_bytes(raw: bytes):
    """The vault in raw, or None when raw is not one: empty, all NUL (a crash before the data
    reached the disk), truncated, not JSON, or not an object with an accounts list."""
    try:
        text = raw.decode('utf-8-sig')
    except UnicodeDecodeError:
        return None
    if not text.strip('\x00 \t\r\n'):
        return None
    try:
        parsed = json.loads(text)
    except ValueError:
        return None
    if not isinstance(parsed, dict) or not isinstance(parsed.get('accounts'), list):
        return None
    return parsed


def vault_snapshots(data: Path) -> list:
    """Snapshot files, newest first (names sort by time)."""
    folder = data / VAULT_SNAPSHOT_DIR
    try:
        return sorted((p for p in folder.iterdir() if VAULT_SNAPSHOT_NAME.match(p.name)), key=lambda p: p.name, reverse=True)
    except OSError:
        return []


def vault_snapshots_to_remove(names, now_utc: dt.datetime) -> list:
    """Pure: which snapshot names rotation deletes (the engine's Get-ArkuzoVaultSnapshotsToRemove)."""
    valid = sorted((n for n in names if VAULT_SNAPSHOT_NAME.match(n)), reverse=True)
    kept_days, remove = set(), []
    for i, name in enumerate(valid):
        day = name[9:17]
        if i < VAULT_SNAPSHOT_KEEP:
            kept_days.add(day)
            continue
        try:
            recent = (now_utc.date() - dt.datetime.strptime(day, '%Y%m%d').date()).days <= VAULT_SNAPSHOT_DAYS
        except ValueError:
            recent = False
        if recent and day not in kept_days:
            kept_days.add(day)
            continue
        remove.append(name)
    return remove


def save_vault_snapshot(data: Path, raw: bytes, now_utc: dt.datetime | None = None) -> bool:
    now_utc = now_utc or dt.datetime.now(dt.timezone.utc)
    folder = data / VAULT_SNAPSHOT_DIR
    folder.mkdir(exist_ok=True)
    target = folder / ('accounts-' + now_utc.strftime('%Y%m%d-%H') + '.json')
    if target.exists():
        return False
    write_bytes_atomic(target, raw)
    for name in vault_snapshots_to_remove([p.name for p in folder.iterdir()], now_utc):
        try:
            (folder / name).unlink()
        except OSError:
            pass
    return True


def save_vault(data: Path, vault: dict) -> None:
    """Caller holds vault_lock. Keep the content being replaced as .bak (only a valid vault),
    then write the new one; every file is flushed to the disk before its replace."""
    path = data / VAULT_FILE
    try:
        current = path.read_bytes()
        if parse_vault_bytes(current) is not None:
            write_bytes_atomic(data / VAULT_BACKUP, current)
    except OSError:
        pass  # No previous vault, or the backup could not be written: the save itself still happens.
    raw = json.dumps(vault, indent=4, ensure_ascii=False).encode('utf-8')
    write_bytes_atomic(path, raw)
    try:
        save_vault_snapshot(data, raw)
    except OSError:
        pass


def _vault_event(kind: str, level: str, text: str) -> None:
    with _vault_events_lock:
        _vault_events.append({'t': time.time(), 'kind': kind, 'category': 'error' if level == 'critical' else 'saver', 'level': level, 'text': text})
        del _vault_events[:-20]


def take_vault_events() -> list:
    with _vault_events_lock:
        events = list(_vault_events)
        _vault_events.clear()
    return events


def _damaged_name(data: Path) -> Path:
    stamp = time.strftime('%Y%m%d-%H%M%S')
    target = data / f'{VAULT_FILE}.damaged-{stamp}'
    n = 1
    while target.exists():
        n += 1
        target = data / f'{VAULT_FILE}.damaged-{stamp}-{n}'
    return target


def _age_text(seconds: float) -> str:
    minutes = max(0, int(seconds // 60))
    if minutes < 120:
        return f'{minutes} min'
    return f'{minutes // 60} h' if minutes < 2880 else f'{minutes // 1440} days'


def restore_vault(data: Path):
    """Restore a damaged accounts.json from accounts.json.bak, else from the newest valid
    snapshot. The damaged bytes are copied to accounts.json.damaged-<time> first (never
    deleted), then the backup's exact bytes replace the file. Returns the parsed vault, or None
    when the file is fine again or no valid copy exists (VaultDamagedError then)."""
    path = data / VAULT_FILE
    with vault_lock():
        try:
            damaged = path.read_bytes()
        except FileNotFoundError:
            return None
        current = parse_vault_bytes(damaged)
        if current is not None:
            return current  # Someone restored or rewrote it meanwhile.
        for candidate in [data / VAULT_BACKUP] + vault_snapshots(data):
            try:
                raw = candidate.read_bytes()
            except OSError:
                continue
            parsed = parse_vault_bytes(raw)
            if parsed is None:
                continue
            kept = _damaged_name(data)
            write_bytes_durable(kept, damaged, exclusive=True)
            write_bytes_atomic(path, raw)
            try:
                age = _age_text(time.time() - candidate.stat().st_mtime)
            except OSError:
                age = 'unknown age'
            # Requests in the copy (Launch, Close, Arrange now) were carried out or dropped since:
            # cleared in one normal save, which also keeps the restored bytes as the new .bak.
            stale = False
            for a in parsed.get('accounts') or []:
                for name in ('launchRequestedAtMs', 'closeRequestedAtMs'):
                    if isinstance(a, dict) and a.get(name):
                        a[name], stale = 0, True
            settings = parsed.get('settings')
            if isinstance(settings, dict) and settings.get('arrangeRequestedAtMs'):
                settings['arrangeRequestedAtMs'], stale = 0, True
            if stale:
                save_vault(data, parsed)
            _vault_event('VAULT_RESTORED_FROM_BACKUP', 'warning',
                         f'Account list was damaged (probably a crash while saving); restored from {candidate.name} ({age} old). '
                         f'The damaged file is kept as {kept.name}.')
            return parsed
    raise VaultDamagedError(VAULT_DAMAGED)


def load_vault(data: Path) -> dict:
    """A missing vault is empty. A damaged one is restored from its newest valid backup; without
    one it raises, so nothing ever overwrites it."""
    path = data / VAULT_FILE
    for attempt in range(3):
        try:
            raw = path.read_bytes()
        except FileNotFoundError:
            return empty_vault()
        except OSError:
            time.sleep(0.05)
            continue
        parsed = parse_vault_bytes(raw)
        if parsed is not None:
            return normalize_vault(parsed)
        if attempt < 2:
            time.sleep(0.05)  # A replace in flight looks the same for a moment.
            continue
        restored = restore_vault(data)
        if restored is not None:
            return normalize_vault(restored)
        return empty_vault()  # The file vanished while it was being restored.
    raise VaultError('data/accounts.json could not be read')


def reset_vault(data: Path) -> dict:
    """Start a new, empty account list when accounts.json is damaged and no valid backup exists.
    The damaged file is moved aside (accounts.json.damaged-<time>), never deleted."""
    path = data / VAULT_FILE
    with vault_lock():
        try:
            damaged = path.read_bytes()
        except FileNotFoundError:
            raise VaultError('There is no account list to replace')
        if parse_vault_bytes(damaged) is not None:
            raise VaultError('The account list is readable again; nothing to replace')
        if any(parse_vault_bytes(p.read_bytes()) is not None for p in [data / VAULT_BACKUP] + vault_snapshots(data) if p.exists()):
            raise VaultError('A valid backup exists; reload the page to restore it')
        kept = _damaged_name(data)
        write_bytes_durable(kept, damaged, exclusive=True)
        write_json_atomic(path, empty_vault())
        _vault_event('VAULT_RESET', 'warning', f'Started a new, empty account list; the damaged one is kept as {kept.name}.')
        return {'kept': kept.name}


def update_vault(data: Path, change):
    """Apply change(vault) under the shared lock and save atomically. Returns change's result."""
    with vault_lock():
        vault = load_vault(data)
        result = change(vault)
        save_vault(data, vault)
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


COOKIE_STATES = ('alive', 'dead', 'moderated', 'unknown')
MODERATED_REASON = 'Roblox has moderated this account: sign in on roblox.com to see why'


def check_cookie(cookie: str) -> dict:
    """alive / dead / moderated / unknown (network or Roblox trouble: never treated as dead).

    moderated: the cookie is valid but Roblox banned or warned the account, so it
    cannot launch ("User is moderated"). A later check finds it alive again once
    the moderation ends or is acknowledged on roblox.com."""
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
    if resp.status == 403 and b'User is moderated' in (resp.body or b''):
        return {'status': 'moderated', 'reason': MODERATED_REASON, 'rotated': resp.rotated_cookie()}
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
        else:
            a['lastError'] = result.get('reason', '')
        # Store a rotated cookie (moderated accounts get one too) only if nobody replaced the one we used meanwhile.
        if result.get('rotated') and a['cookie'] == secret:
            a['cookie'] = protect_secret(result['rotated'])
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


def close_live_clients(data: Path, account_ids=None) -> int:
    """Close the clients of these accounts (None: every account) right away.

    Only an exact client the saver's heartbeat maps to an Arkuzo account is
    closed: same PID, same start time, RobloxPlayerBeta.exe. The close request
    stamps stay set, so the saver still closes anything missed here (a client
    that started after the last heartbeat)."""
    heartbeat = read_json(data / 'runtime-status.json')
    if not isinstance(heartbeat, dict) or heartbeat.get('accountProvider') != 'arkuzo':
        return 0
    ticks = {}
    for c in heartbeat.get('clients') or []:
        if isinstance(c, dict) and isinstance(c.get('pid'), int) and isinstance(c.get('startTicks'), int):
            ticks[c['pid']] = c['startTicks']
    closed = 0
    for a in heartbeat.get('accounts') or []:
        if not isinstance(a, dict) or (account_ids is not None and a.get('accountId') not in account_ids):
            continue
        pid = a.get('processId')
        if isinstance(pid, int) and pid in ticks and WIN32.terminate(pid, ticks[pid], ('robloxplayerbeta.exe',)):
            closed += 1
    return closed


def _stamp_close(accounts) -> None:
    stamp = now_ms()
    for a in accounts:
        a['closeRequestedAtMs'], a['launchRequestedAtMs'] = stamp, 0


def close_all_clients(data: Path) -> dict:
    """Close every Arkuzo client now. The farm keeps its state: running, it relaunches them."""
    def change(vault):
        _stamp_close(vault['accounts'])
        return dict(vault['settings'])
    return dict(update_vault(data, change), closed=close_live_clients(data))


def request_account_action(data: Path, account_id: str, action: str) -> dict:
    """Launch / close one account. The engine carries it out and clears the request."""
    def change(vault):
        a = find_account(vault, account_id)
        if action == 'launch':
            if a['cookieStatus'] == 'dead':
                raise VaultError('This account\'s cookie is dead: sign in again first')
            if a['cookieStatus'] == 'moderated':
                raise VaultError(MODERATED_REASON + ', then check its cookie again')
            a['launchRequestedAtMs'], a['closeRequestedAtMs'] = now_ms(), 0
        elif action == 'close':
            # Relaunch stays as it is: with the farm running the account is launched again.
            _stamp_close([a])
        else:
            raise VaultError('Unknown action')
        return public_account(a)
    result = update_vault(data, change)
    if action == 'close':
        result['closed'] = close_live_clients(data, {account_id})
    return result


def remove_account(data: Path, account_id: str):
    def change(vault):
        a = find_account(vault, account_id)
        vault['accounts'].remove(a)
    update_vault(data, change)


# ---------------------------------------------------------------- several accounts at once
UNDO_SEC = 10  # A deleted account can be brought back this long (the page's Undo), then it is gone.
BULK_MAX = 1000
BULK_ACTIONS = ('delete', 'restore', 'group', 'relaunch', 'launch', 'close', 'check')


def bulk_ids(vault: dict, ids) -> list:
    """The accounts named by ids, all of them or an error: a bulk action never half-applies."""
    if not isinstance(ids, list) or not ids or len(ids) > BULK_MAX:
        raise VaultError('Select at least one account')
    chosen, seen = [], set()
    for ident in ids:
        if not isinstance(ident, str) or not GUID.match(ident):
            raise VaultError('Invalid account id')
        if ident.lower() in seen:
            continue
        seen.add(ident.lower())
        chosen.append(find_account(vault, ident))
    return chosen


def purge_trash(data: Path, now=None) -> int:
    """Delete for good what waited longer than UNDO_SEC. Returns how many rows went."""
    cutoff = (now if now is not None else now_ms()) - UNDO_SEC * 1000

    def change(vault):
        before = len(vault['trash'])
        vault['trash'] = [t for t in vault['trash'] if t['deletedAtMs'] > cutoff]
        return before - len(vault['trash'])
    try:
        if not (read_json(data / VAULT_FILE) or {}).get('trash'):
            return 0  # Nothing waiting: no write.
    except (OSError, ValueError, AttributeError):
        return 0
    return update_vault(data, change)


def bulk_accounts(data: Path, action: str, ids=None, value=None, batch=None) -> dict:
    """One change to several accounts, in one locked, atomic vault write."""
    if action not in BULK_ACTIONS or action == 'check':
        raise VaultError('Unknown bulk action')
    if action == 'group':
        if not isinstance(value, str) or len(value.strip()) > ACCOUNT_FIELDS['group'] or re.search(r'[\x00-\x1f\x7f]', value):
            raise VaultError(f"A group name is text of at most {ACCOUNT_FIELDS['group']} characters")
        value = value.strip()
    if action == 'relaunch' and not isinstance(value, bool):
        raise VaultError('Relaunch must be true or false')

    def change(vault):
        cutoff = now_ms() - UNDO_SEC * 1000
        vault['trash'] = [t for t in vault['trash'] if t['deletedAtMs'] > cutoff]
        if action == 'restore':
            if not isinstance(batch, str) or not re.match(r'\A[0-9a-f]{16}\Z', batch):
                raise VaultError('Nothing to undo')
            rows = [t for t in vault['trash'] if t['batch'] == batch]
            if not rows:
                raise VaultError('Too late to undo: the accounts are deleted')
            ids_now = {a['id'].lower() for a in vault['accounts']}
            users = {a['userId'] for a in vault['accounts']}
            restored, skipped = 0, 0
            for t in rows:
                a = t['account']
                if str(a.get('id') or '').lower() in ids_now or a.get('userId') in users:
                    skipped += 1  # Added again meanwhile: the newer row stays.
                    continue
                vault['accounts'].append(a)
                restored += 1
            vault['trash'] = [t for t in vault['trash'] if t['batch'] != batch]
            return {'restored': restored, 'skipped': skipped}
        chosen = bulk_ids(vault, ids)
        stamp = now_ms()
        if action == 'delete':
            token = secrets.token_hex(8)
            for a in chosen:
                vault['accounts'].remove(a)
                vault['trash'].append({'batch': token, 'deletedAtMs': stamp, 'account': a})
            return {'batch': token, 'count': len(chosen), 'undoSec': UNDO_SEC}
        skipped = []
        for a in chosen:
            if action == 'group':
                a['group'] = value
            elif action == 'relaunch':
                a['autoRelaunch'] = value
            elif action == 'launch':
                if a['cookieStatus'] in ('dead', 'moderated'):
                    skipped.append(a['id'])  # Never launched: signed out or moderated.
                    continue
                a['launchRequestedAtMs'], a['closeRequestedAtMs'] = stamp, 0
            elif action == 'close':
                _stamp_close([a])
            a['updatedAtMs'] = stamp
        return {'count': len(chosen) - len(skipped), 'skipped': skipped, 'ids': [a['id'] for a in chosen if a['id'] not in skipped]}

    result = update_vault(data, change)
    if action == 'close':
        result['closed'] = close_live_clients(data, set(result['ids']))
    if action == 'delete':
        timer = threading.Timer(UNDO_SEC + 1, lambda: _purge_quietly(data))
        timer.daemon = True
        timer.start()
    return result


def _purge_quietly(data: Path):
    try:
        purge_trash(data)
    except (OSError, VaultError):
        pass  # The next delete, or the next start, purges.


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


def set_farm_running(data: Path, running: bool) -> dict:
    """Start or stop the farm. Stopping also closes every Arkuzo client."""
    def change(vault):
        vault['settings']['farmRunning'] = bool(running)
        if running and not vault['settings']['defaultPlaceId'] and vault['settings']['privateServerMode'] == 'none' \
                and not any(a['placeId'] or a['privateServerId'] for a in vault['accounts']):
            raise VaultError('Set a default place (game) to farm first')
        if not running:
            _stamp_close(vault['accounts'])
        return dict(vault['settings'])
    settings = update_vault(data, change)
    if not running:
        # farmRunning is saved first, so the saver never relaunches what is closed here.
        settings = dict(settings, closed=close_live_clients(data))
    return settings


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
            return None  # Only the ticket was requested; NATIVE_LAUNCH_STARTED / _FAILED follow.
        level, text = 'warning', f"{who()} not launched: {data.get('reason') or 'unknown reason'}"
    elif kind == 'NATIVE_LAUNCH_STARTED':
        level, text = 'good', f"{who()} started; waiting until it is in game"
    elif kind == 'NATIVE_LAUNCH_FAILED':
        level, text = 'warning', f"{who()} not launched: {data.get('reason') or 'unknown reason'}"
    elif kind == 'NATIVE_LAUNCH_EXITED':
        level, text = 'warning', f"{who()} closed before it was in game; relaunching after the relaunch delay"
    elif kind == 'VAULT_READ_FROM_BACKUP':
        text = (f"Account list is damaged: the saver reads {data['backup']} until it is restored; launches wait" if data.get('backup')
                else 'Account list is damaged and has no valid backup: nothing is launched (Accounts page: Start a new account list)')
    elif kind == 'ROBLOX_BUILD_FAILING':
        text = (f"Roblox build {data.get('version') or '?'} keeps closing at start — it may be outdated or refused by Roblox "
                f"({data.get('failures')} clients in a row). "
                + ('Launching another installed build instead.' if data.get('fallback') else 'Launches wait until another build is chosen on the Roblox tab.'))
    elif kind == 'ROBLOX_BUILD_GUARD_RESET':
        builds = ', '.join(str(b) for b in data.get('builds') or []) or 'The Roblox build'
        text = f"{builds}: {data.get('note') or 'launches use it again.'}"
    elif kind == 'LOG_WRITE_RECOVERED':
        text = f"Saver logging works again after {data.get('failures')} failed write(s)"
    elif kind == 'LOG_RETENTION':
        text = f"Removed {data.get('deletedFiles')} old saver log file(s) ({data.get('deletedMB')} MB); kept {data.get('keptSessions')} sessions"
    elif kind == 'NATIVE_COOKIE_DEAD':
        level, text = 'critical', f"{who()} is signed out (Roblox rejected its cookie); sign it in again"
    elif kind == 'ROBLOX_SAVED_LOGIN_SET_ASIDE':
        level, text = 'warning', "Signed the Roblox app out on this PC: its saved login makes launches fail (HTTP 403)"
    elif kind == 'NATIVE_ACCOUNT_MODERATED':
        level, text = 'critical', f"{who()} is moderated by Roblox; it is not launched until a cookie check finds it alive again"
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
    elif kind == 'REMOTE_SESSION_CHANGED':
        level, text = remote_change_summary(data)
    elif kind == 'KEEP_AWAKE':
        text = 'Keeping the display awake while clients run' if data.get('on') else 'Display may sleep again (no clients running)'
    if not text:
        return None
    return {'t': parse_utc(record.get('time')) or time.time(), 'kind': kind, 'category': category, 'level': level, 'text': text[:240]}


PERSISTED_KINDS = {'SUPERVISOR', 'VAULT_RESTORED_FROM_BACKUP', 'VAULT_RESET'}  # Also written to control-center.log.


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
        if event.get('kind') in PERSISTED_KINDS:
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
    return RESTART_FLOOR_SEC if consecutive_failures <= 1 else RESTART_MAX_SEC


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
            message += f' Repeated failures: retrying every {CRASH_LOOP_RETRY_SEC} s; see the saver log.' if autopilot else ' Repeated failures.'
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
    schema = hb.get('schemaVersion')
    if isinstance(schema, int) and not isinstance(schema, bool) and schema > HEARTBEAT_SCHEMA_VERSION:
        add('warning', 'The saver is newer than this Control Center',
            'Some figures may be missing or wrong. Start ArkuzoMemorySaver.exe again so both run the same version.')
    if hb.get('logFailed'):
        add('critical', 'Saver audit logging failed', 'Closures wait until a log write succeeds; the saver retries in a new log file every few seconds.')
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
    for level, title, detail in remote_issues(hb.get('remoteSession'), len(hb.get('clients') or [])):
        add(level, title, detail)
    dead = hb.get('suspendedAccounts') or []
    if dead:
        add('warning', f'{len(dead)} account(s) paused with a dead cookie',
            'Add them again on the Accounts page (cookie or browser sign-in); they resume automatically.' if arkuzo
            else 'Log those accounts in again in Volt; they resume automatically.')
    return issues


# ------------------------------------------------------------- remote sessions
REMOTE_CHANGE_TEXT = {
    'CRD_CONNECTED': 'Chrome Remote Desktop connected', 'CRD_DISCONNECTED': 'Chrome Remote Desktop disconnected',
    'SESSION_DISCONNECTED': 'Remote Desktop session disconnected', 'SESSION_RECONNECTED': 'Remote Desktop session reconnected',
    'SESSION_ON_CONSOLE': 'Session moved to the console', 'SESSION_LEFT_CONSOLE': 'Session left the console',
    'SESSION_LOCKED': 'Windows locked', 'SESSION_UNLOCKED': 'Windows unlocked',
    'INPUT_DESKTOP_CHANGED': 'Input desktop switched', 'DISPLAY_MODE_CHANGED': 'Display mode changed',
    'MONITOR_COUNT_CHANGED': 'Monitor count changed', 'PROTOCOL_CHANGED': 'Session protocol changed',
    'SESSION_STATE_CHANGED': 'Session state changed',
}


def remote_change_summary(data: dict) -> tuple:
    changes = [c for c in data.get('changes') or [] if isinstance(c, str)]
    current = data.get('current') if isinstance(data.get('current'), dict) else {}
    parts = [REMOTE_CHANGE_TEXT.get(c, c.replace('_', ' ').lower()) for c in changes]
    if 'DISPLAY_MODE_CHANGED' in changes and current.get('display'):
        parts[changes.index('DISPLAY_MODE_CHANGED')] += f" to {current['display']}"
    clients = int(data.get('clients') or 0)
    risky = clients > 0 and ('CRD_DISCONNECTED' in changes or 'SESSION_DISCONNECTED' in changes)
    text = '; '.join(parts) or 'Remote session changed'
    if clients:
        text += f' ({clients} clients running)'
    return ('warning' if risky else 'info'), text


def remote_issues(remote, clients: int) -> list:
    """Dashboard notices. Logged so far: every Chrome Remote Desktop disconnect with
    clients running froze all of them; connected periods never did."""
    if not isinstance(remote, dict):
        return []
    out = []
    crd = remote.get('chromeRemoteDesktop') if isinstance(remote.get('chromeRemoteDesktop'), dict) else {}
    if remote.get('hold'):
        left = remote.get('holdLeftSec')
        out.append(('warning', 'Remote Desktop session is disconnected: recovery is paused',
                    'Clients cannot draw in a disconnected session, and relaunched ones could not either. Reconnect, or next time use '
                    '"Leave Remote Desktop safely".' + (f' Recovery resumes by itself in {int(left)} s.' if isinstance(left, (int, float)) else '')))
    if crd.get('connected') and clients > 0:
        out.append(('warning', 'Chrome Remote Desktop is connected: minimise it, do not disconnect',
                    'So far every disconnect froze all clients within seconds (Roblox closes frozen clients about 3 minutes later). '
                    'Minimise the Chrome Remote Desktop tab or window instead. If you do disconnect, the saver restarts the clients one at a time right away.'))
    if remote.get('protocol') == 'rdp' and remote.get('sessionState') == 'active' and clients > 0:
        out.append(('warning', 'You are on Remote Desktop: leave it with "Leave Remote Desktop safely"',
                    'Closing the Remote Desktop window disconnects the session and the clients stop drawing. The button on the Settings page '
                    "moves this session to the PC's own screen first (tscon, needs administrator rights). The PC is then unlocked on its monitor."))
    return out


RDP_PROTOCOL = 2


def own_session() -> dict:
    """This process's Windows session: id, protocol (0 console, 2 RDP) and whether it is on the console."""
    info = {'sessionId': -1, 'protocol': -1, 'onConsole': False}
    if os.name != 'nt':
        return info
    try:
        k32, wts = ctypes.windll.kernel32, ctypes.windll.wtsapi32
        sid = wintypes.DWORD()
        if not k32.ProcessIdToSessionId(os.getpid(), ctypes.byref(sid)):
            return info
        info['sessionId'] = int(sid.value)
        info['onConsole'] = int(sid.value) == int(k32.WTSGetActiveConsoleSessionId())
        buf, size = ctypes.c_void_p(), wintypes.DWORD()
        if wts.WTSQuerySessionInformationW(None, sid, 16, ctypes.byref(buf), ctypes.byref(size)):  # WTSClientProtocolType
            try:
                if size.value >= 2:
                    info['protocol'] = ctypes.c_ushort.from_address(buf.value).value
            finally:
                wts.WTSFreeMemory(buf)
    except (OSError, AttributeError):
        pass
    return info


def tscon_path() -> Path:
    root = Path(os.environ.get('SystemRoot') or r'C:\Windows')
    native = root / 'Sysnative' / 'tscon.exe'  # A 32-bit Python sees the 64-bit System32 here.
    return native if native.exists() else root / 'System32' / 'tscon.exe'


def leave_remote_desktop(session=None, runner=subprocess.run) -> str:
    """Moves this RDP session to the physical console (tscon <id> /dest:console), so the
    Remote Desktop window closes while every client keeps drawing. Only for RDP: Chrome
    Remote Desktop already shows the console session. Runs once, on request; nothing persists."""
    info = own_session() if session is None else session
    if info.get('protocol') != RDP_PROTOCOL or int(info.get('sessionId', -1)) < 0:
        raise ConfigError('This Control Center is not running in a Remote Desktop (RDP) session.')
    sid = int(info['sessionId'])
    command = [str(tscon_path()), str(sid), '/dest:console']
    try:
        result = runner(command, capture_output=True, text=True, timeout=20, creationflags=0x08000000)  # CREATE_NO_WINDOW
    except subprocess.TimeoutExpired:
        raise ConfigError('tscon did not finish in time.') from None
    if result.returncode != 0:
        detail = ((result.stderr or '') + ' ' + (result.stdout or '')).strip()[:200]
        raise ConfigError('tscon failed' + (f': {detail}' if detail else '') + '. It needs administrator rights: run '
                          f'"tscon {sid} /dest:console" in an administrator Command Prompt instead.')
    return 'moved to console'


# ------------------------------------------------------------- Roblox versions
# The Roblox tab (docs/roblox-versions.md). weao.gg is only a data source for version strings and
# exploit status: every version is checked against ROBLOX_VERSION, the links in its rows are dropped
# and nothing it names is downloaded. Roblox builds come only from Roblox's setup CDN, are checked
# against the package manifest's sizes and MD5s, and are installed atomically: extracted into a
# staging folder beside Versions\, completed with AppSettings.xml, then renamed into
# Versions\version-<hash> in one step. A failed or cancelled install never reaches Versions\.
WEAO_API = 'https://weao.gg/api'
WEAO_UA = 'WEAO-3PService'  # weao.gg answers 403 to Python's default user agent.
ROBLOX_CLIENT_VERSION_URL = 'https://clientsettings.roblox.com/v2/client-version/WindowsPlayer'
ROBLOX_SETUP_BASES = ('https://setup.rbxcdn.com/channel/common/', 'https://setup-aws.rbxcdn.com/channel/common/',
                      'https://setup-ak.rbxcdn.com/channel/common/')
WEB_HOSTS = {'weao.gg', 'clientsettings.roblox.com', 'setup.rbxcdn.com', 'setup-aws.rbxcdn.com', 'setup-ak.rbxcdn.com'}
# Bloxstrap's package map for the Windows player (folders relative to the version folder).
ROBLOX_PACKAGE_DIRS = {
    'RobloxApp.zip': '', 'Libraries.zip': '', 'redist.zip': '', 'WebView2.zip': '',
    'shaders.zip': 'shaders', 'ssl.zip': 'ssl',
    'content-avatar.zip': 'content/avatar', 'content-configs.zip': 'content/configs', 'content-fonts.zip': 'content/fonts',
    'content-sky.zip': 'content/sky', 'content-sounds.zip': 'content/sounds', 'content-textures2.zip': 'content/textures',
    'content-models.zip': 'content/models',
    'content-textures3.zip': 'PlatformContent/pc/textures', 'content-terrain.zip': 'PlatformContent/pc/terrain',
    'content-platform-fonts.zip': 'PlatformContent/pc/fonts',
    'content-platform-dictionaries.zip': 'PlatformContent/pc/shared_compression_dictionaries',
    'extracontent-luapackages.zip': 'ExtraContent/LuaPackages', 'extracontent-translations.zip': 'ExtraContent/translations',
    'extracontent-models.zip': 'ExtraContent/models', 'extracontent-textures.zip': 'ExtraContent/textures',
    'extracontent-places.zip': 'ExtraContent/places',
}
# Roblox's own installer and launcher are never put into an Arkuzo folder (nothing there can update the
# build in place); the WebView2 runtime installer only installs WebView2 (Bloxstrap skips it too).
ROBLOX_SKIPPED_PACKAGES = {'WebView2RuntimeInstaller.zip', 'RobloxPlayerInstaller.exe', 'RobloxPlayerLauncher.exe'}
ROBLOX_APP_SETTINGS = ('<?xml version="1.0" encoding="UTF-8"?>\r\n<Settings>\r\n\t<ContentFolder>content</ContentFolder>\r\n'
                       '\t<BaseUrl>http://www.roblox.com</BaseUrl>\r\n</Settings>\r\n')
ROBLOX_INSTALL_MARKER = '.arkuzo-install.json'
ROBLOX_STAGING_STALE_SEC = 1800  # A staging folder untouched this long belongs to an install that died.
WEAO_CACHE_SEC = 300
WEAO_REFRESH_MIN_SEC = 15
EXPLOIT_ID = re.compile(r'\A[0-9A-Za-z_-]{1,64}\Z')
ROBLOX_FOLLOW_SEC = 600  # Follow mode re-checks weao.gg / Roblox every 10 minutes (5 requests; weao.gg allows 120 a minute).
PROTOCOL_SCHEMES = ('roblox-player', 'roblox')
PROTOCOL_BASE = r'Software\Classes'  # HKCU only; HKLM is never written. Tests use another base.
PROTOCOL_BACKUP = 'roblox-protocol-backup.json'
PROTOCOL_MARK = 'ArkuzoManaged'
BUILD_NUMBER = re.compile(r'\A[0-9]{1,6}(?:\.[0-9]{1,9}){1,3}\Z')


class WebError(Exception):
    """A request to weao.gg or Roblox that failed. status: HTTP status, 0 = no answer, -1 = too large."""

    def __init__(self, status: int):
        super().__init__(f'HTTP {status}')
        self.status = status


class InstallCancelled(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # urllib then raises HTTPError for the 30x: a redirect is never followed.


def url_allowed(url: str) -> bool:
    """Only HTTPS to Roblox's setup CDN, Roblox's version service and weao.gg. Tests swap this."""
    parsed = urllib.parse.urlparse(url)
    return parsed.scheme == 'https' and (parsed.hostname or '') in WEB_HOSTS and parsed.port in (None, 443) and not parsed.username


def web_open(url: str, headers=None, timeout=20.0):
    """Open an allowed URL without following redirects; the caller closes the response."""
    if not url_allowed(url):
        raise WebError(0)
    merged = {'User-Agent': ROBLOX_UA, 'Accept': '*/*'}
    merged.update(headers or {})
    request = urllib.request.Request(url, headers=merged)
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        return opener.open(request, timeout=timeout)
    except urllib.error.HTTPError as err:
        err.close()
        raise WebError(err.code)
    except (OSError, ValueError):
        raise WebError(0)


def web_get(url: str, limit: int, headers=None, timeout=20.0) -> bytes:
    response = web_open(url, headers, timeout)
    try:
        body = response.read(limit + 1)
    except (OSError, ValueError):
        raise WebError(0)
    finally:
        response.close()
    if len(body) > limit:
        raise WebError(-1)
    return body


def _text(value, limit: int) -> str:
    """A display string from untrusted data: plain text, no control characters, bounded."""
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        return ''
    return re.sub(r'[\x00-\x1f\x7f]+', ' ', str(value)).strip()[:limit]


def weao_get(path: str):
    return json.loads(web_get(WEAO_API + path, 2097152, {'User-Agent': WEAO_UA, 'Accept': 'application/json'}).decode('utf-8'))


def parse_weao_versions(raw) -> dict:
    """The Windows build of /versions/current, /past or /future, validated; {} when there is none."""
    if not isinstance(raw, dict):
        return {}
    version = raw.get('Windows')
    if not isinstance(version, str) or not ROBLOX_VERSION.match(version):
        return {}
    detail = raw.get('WindowsResponse') if isinstance(raw.get('WindowsResponse'), dict) else {}
    build = detail.get('version')
    return {'version': version, 'date': _text(raw.get('WindowsDate'), 40),
            'build': build if isinstance(build, str) and BUILD_NUMBER.match(build) else None}


def _percent(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 100:
        return None
    return int(value)


def parse_weao_exploits(raw) -> list:
    """weao.gg's exploit list as plain, validated rows. A row is a version source only when it is
    a Windows exploit that names a valid build and is still listed (not hidden)."""
    rows, seen = [], set()
    if not isinstance(raw, list):
        return rows
    for item in raw[:500]:
        if not isinstance(item, dict):
            continue
        ident, title = item.get('_id'), _text(item.get('title'), 60)
        if not isinstance(ident, str) or not EXPLOIT_ID.match(ident) or ident in seen or not title:
            continue
        seen.add(ident)
        platform, listed = _text(item.get('platform'), 20), item.get('rbxversion')
        windows = platform == 'Windows'
        build = listed if windows and isinstance(listed, str) and ROBLOX_VERSION.match(listed) else None
        hidden = item.get('hidden') is True
        reason = '' if build and not hidden else (
            'Not a Windows exploit' if not windows else 'No longer listed on weao.gg' if hidden and build else 'Lists no valid Roblox build')
        rows.append({'id': ident, 'title': title, 'version': _text(item.get('version'), 40), 'updatedDate': _text(item.get('updatedDate'), 60),
                     'platform': platform, 'type': _text(item.get('extype'), 20), 'robloxVersion': build, 'listedVersion': _text(listed, 40),
                     'updated': item.get('updateStatus') is True, 'detected': item.get('detected') is True, 'free': item.get('free') is True,
                     'beta': item.get('beta') is True, 'hidden': hidden, 'multiInstance': item.get('multiInject') is True,
                     'unc': _percent(item.get('uncPercentage')), 'sunc': _percent(item.get('suncPercentage')),
                     'usable': bool(build) and not hidden, 'reason': reason})
    rows.sort(key=lambda r: (not r['usable'], not r['updated'], r['title'].lower(), r['platform']))
    return rows


def exploit_build(exploits: list, ids, current: str | None = None) -> dict:
    """The one Roblox build every selected exploit supports, or why there is none."""
    if not isinstance(ids, list) or not ids or len(ids) > 60:
        raise VaultError('Select at least one exploit')
    by_id = {e['id']: e for e in exploits}
    chosen = []
    for ident in ids:
        row = by_id.get(ident) if isinstance(ident, str) else None
        if row is None:
            raise VaultError('Unknown exploit: refresh the list')
        if row not in chosen:
            chosen.append(row)
    result = {'version': None, 'reason': '', 'conflict': [], 'current': False, 'notes': [], 'exploits': [e['title'] for e in chosen]}
    refused = [e for e in chosen if not e['usable']]
    if refused:
        result['reason'] = '; '.join(f"{e['title']} ({e['platform'] or 'unknown platform'}): {e['reason']}" for e in refused)
        return result
    builds = {}
    for e in chosen:
        builds.setdefault(e['robloxVersion'], []).append(e['title'])
    if len(builds) > 1:
        result['reason'] = 'The selected exploits support different Roblox builds, and a client runs one build. Pick exploits that agree.'
        result['conflict'] = [{'version': v, 'exploits': names} for v, names in builds.items()]
        return result
    version = next(iter(builds))
    result.update(version=version, current=bool(current) and version == current)
    stale = [e['title'] for e in chosen if not e['updated']]
    if current and version != current:
        result['notes'].append(f'This is not Roblox\'s current build ({current}). Roblox can refuse joins from an outdated build at any time.')
    if stale:
        result['notes'].append(', '.join(stale) + (' is' if len(stale) == 1 else ' are') + ' not updated for Roblox\'s current build yet (weao.gg).')
    return result


def parse_package_manifest(text: str) -> list:
    """Roblox's <version>-rbxPkgManifest.txt: "v0", then name, MD5, packed size, size per package."""
    lines = [line.strip() for line in str(text).replace('\r', '').split('\n')]
    while lines and not lines[-1]:
        lines.pop()
    if not lines or lines[0] != 'v0':
        raise VaultError('Roblox sent a package manifest this Arkuzo version does not understand')
    body, packages, seen = lines[1:], [], set()
    if not body or len(body) % 4:
        raise VaultError('Roblox sent a damaged package manifest')
    for i in range(0, len(body), 4):
        name, md5, packed, size = body[i:i + 4]
        if not re.match(r'\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\Z', name) or not re.match(r'\A[0-9a-f]{32}\Z', md5) \
                or not re.match(r'\A[0-9]{1,11}\Z', packed) or not re.match(r'\A[0-9]{1,11}\Z', size) or name in seen:
            raise VaultError('Roblox sent a damaged package manifest')
        seen.add(name)
        packages.append({'name': name, 'md5': md5, 'packed': int(packed), 'size': int(size)})
    return packages


def plan_packages(packages: list) -> list:
    """The packages to install, in manifest order. A package Arkuzo does not know stops the install:
    leaving it out could produce a build that starts and then fails."""
    plan = []
    for package in packages:
        if package['name'] in ROBLOX_SKIPPED_PACKAGES:
            continue
        if package['name'] not in ROBLOX_PACKAGE_DIRS:
            raise VaultError(f"Roblox added a package this Arkuzo version does not know ({package['name']}); update Arkuzo")
        plan.append(dict(package, folder=ROBLOX_PACKAGE_DIRS[package['name']]))
    if not any(p['name'] == 'RobloxApp.zip' for p in plan):
        raise VaultError('This build has no Windows player (RobloxApp.zip)')
    if sum(p['packed'] for p in plan) > 2 << 30 or sum(p['size'] for p in plan) > 4 << 30:
        raise VaultError('Roblox declared an implausibly large build')
    return plan


def parse_file_manifest(text: str) -> dict:
    """<version>-rbxManifest.txt: relative path and MD5 per file. Keys are lower-case with forward slashes."""
    lines = [line.strip() for line in str(text).replace('\r', '').split('\n') if line.strip()]
    files = {}
    for i in range(0, len(lines) - 1, 2):
        if re.match(r'\A[0-9a-f]{32}\Z', lines[i + 1]):
            files[lines[i].replace('\\', '/').lower()] = lines[i + 1]
    return files


def file_md5(path: Path) -> str:
    digest = hashlib.md5()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def extract_package(archive_path: Path, target: Path, limit: int, cancel=None) -> int:
    """Unpack one package into target. Every entry must land inside target, and the package may not
    unpack to more than limit bytes. Returns the bytes written."""
    base = os.path.realpath(str(target))
    os.makedirs(base, exist_ok=True)
    written = 0
    with zipfile.ZipFile(str(archive_path)) as archive:
        for info in archive.infolist():
            name = info.filename.replace('\\', '/')
            if name.endswith('/'):
                continue
            parts = [p for p in name.split('/') if p not in ('', '.')]
            dest = os.path.realpath(os.path.join(base, *parts)) if parts else base
            try:
                inside = os.path.commonpath([base, dest]) == base and dest != base
            except ValueError:
                inside = False
            if not inside or ':' in name:
                raise VaultError('A Roblox package holds a path outside its folder; install stopped')
            written += info.file_size
            if written > limit:
                raise VaultError('A Roblox package unpacks larger than Roblox declared; install stopped')
            if cancel is not None and cancel.is_set():
                raise InstallCancelled()
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with archive.open(info) as source, open(dest, 'wb') as out:
                shutil.copyfileobj(source, out, 1 << 20)
            # Roblox's own file times: the saver's Auto choice ranks builds by the player's file time,
            # so an old build installed today must not look like the newest one.
            try:
                stamp = time.mktime(tuple(info.date_time) + (0, 0, -1))
                os.utime(dest, (stamp, stamp))
            except (OverflowError, ValueError, OSError):
                pass
    return written


def fetch_setup_file(name: str, limit: int) -> bytes:
    """A file from Roblox's setup CDN, trying the mirrors in turn. Roblox answers 403 for a build it does not have."""
    missing = 0
    for base in ROBLOX_SETUP_BASES:
        try:
            return web_get(base + name, limit, timeout=30.0)
        except WebError as err:
            if err.status in (403, 404):
                missing += 1
    if missing == len(ROBLOX_SETUP_BASES):
        raise FileNotFoundError(name)
    raise VaultError('Roblox\'s CDN did not answer; try again later')


def download_package(version: str, package: dict, folder: Path, cancel, on_bytes) -> Path:
    """Download one package, checking its size and MD5; the mirrors are tried in turn."""
    folder.mkdir(parents=True, exist_ok=True)
    path, why = folder / package['name'], 'no answer'
    for base in ROBLOX_SETUP_BASES:
        digest, got = hashlib.md5(), 0
        try:
            response = web_open(base + version + '-' + package['name'], timeout=30.0)
            try:
                with open(path, 'wb') as out:
                    while True:
                        if cancel.is_set():
                            raise InstallCancelled()
                        chunk = response.read(1 << 16)
                        if not chunk:
                            break
                        got += len(chunk)
                        if got > package['packed']:
                            raise WebError(-1)
                        digest.update(chunk)
                        out.write(chunk)
                        on_bytes(got)
            finally:
                response.close()
        except WebError as err:
            why = 'larger than declared' if err.status == -1 else f'HTTP {err.status}' if err.status else 'no answer'
            continue
        except OSError:
            why = 'no answer'
            continue
        if got == package['packed'] and digest.hexdigest() == package['md5']:
            return path
        why = 'checksum mismatch'
    raise VaultError(f"Could not download {package['name']} from Roblox's CDN ({why})")


def _is_reparse(path: Path) -> bool:
    try:
        return bool(getattr(os.lstat(str(path)), 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0x400)) or path.is_symlink()
    except OSError:
        return True


def clean_staging(staging: Path, now: float | None = None) -> None:
    """Delete staging folders of installs that died (untouched for ROBLOX_STAGING_STALE_SEC)."""
    now = time.time() if now is None else now
    try:
        entries = list(staging.iterdir())
    except OSError:
        return
    for entry in entries:
        try:
            touched = max(entry.stat().st_mtime, (entry / '.busy').stat().st_mtime if (entry / '.busy').exists() else 0)
        except OSError:
            continue
        if now - touched > ROBLOX_STAGING_STALE_SEC and entry.is_dir() and not _is_reparse(entry):
            shutil.rmtree(str(entry), ignore_errors=True)


def roblox_build_complete(folder: Path) -> bool:
    return (folder / 'RobloxPlayerBeta.exe').is_file() and (folder / 'AppSettings.xml').is_file()


def install_roblox_build(version: str, root: Path, progress, cancel) -> dict:
    """Download, verify and install one build into root\\Versions\\<version> (docs/roblox-versions.md)."""
    if not isinstance(version, str) or not ROBLOX_VERSION.match(version):
        raise VaultError('Roblox version must be version- followed by 16 hex digits')
    versions, staging = root / 'Versions', root / '.staging'
    final = versions / version
    if roblox_build_complete(final):
        raise VaultError(f'{version} is already installed')
    if final.exists():
        raise VaultError(f'{final} exists but is not a complete build; remove it first')
    progress(phase='Reading the build manifest from Roblox')
    try:
        packages = parse_package_manifest(fetch_setup_file(version + '-rbxPkgManifest.txt', 1048576).decode('utf-8', 'replace'))
    except FileNotFoundError:
        raise VaultError(f'{version} is not on Roblox\'s CDN (unknown or withdrawn build)')
    plan = plan_packages(packages)
    try:
        files = parse_file_manifest(fetch_setup_file(version + '-rbxManifest.txt', 16777216).decode('utf-8', 'replace'))
    except FileNotFoundError:
        files = {}
    versions.mkdir(parents=True, exist_ok=True)
    staging.mkdir(parents=True, exist_ok=True)
    clean_staging(staging)
    packed, unpacked = sum(p['packed'] for p in plan), sum(p['size'] for p in plan)
    free = shutil.disk_usage(str(staging)).free
    if free < packed + unpacked + (128 << 20):
        raise VaultError(f'Not enough free disk space: {(packed + unpacked) >> 20} MB needed, {free >> 20} MB free')
    work = Path(tempfile.mkdtemp(prefix='install-', dir=str(staging)))
    busy, downloads, target = work / '.busy', work / 'downloads', work / 'build'
    try:
        done, written = 0, 0
        for package in plan:
            if cancel.is_set():
                raise InstallCancelled()
            busy.write_text(package['name'], encoding='ascii')
            progress(phase=f"Downloading {package['name']}", done=done, total=packed)
            path = download_package(version, package, downloads, cancel, lambda n, base=done: progress(done=base + n))
            done += package['packed']
            progress(phase=f"Unpacking {package['name']}", done=done)
            written += extract_package(path, target / package['folder'], package['size'] + (package['size'] >> 4) + (1 << 20), cancel)
            path.unlink()
        player = target / 'RobloxPlayerBeta.exe'
        if not player.is_file():
            raise VaultError('The build has no RobloxPlayerBeta.exe; install stopped')
        expected = files.get('robloxplayerbeta.exe')
        if expected and file_md5(player) != expected:
            raise VaultError('RobloxPlayerBeta.exe does not match Roblox\'s file manifest; install stopped')
        if cancel.is_set():
            raise InstallCancelled()
        marker = {'version': version, 'installedUtc': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                  'bytes': written, 'packages': [p['name'] for p in plan], 'source': 'setup.rbxcdn.com'}
        (target / ROBLOX_INSTALL_MARKER).write_text(json.dumps(marker, indent=2), encoding='utf-8')
        # AppSettings.xml last: it is what makes a folder a complete build for the saver.
        (target / 'AppSettings.xml').write_bytes(ROBLOX_APP_SETTINGS.encode('utf-8'))
        progress(phase='Moving the build into place')
        try:
            os.rename(str(target), str(final))  # Same volume: one step, so Versions\ never holds half a build.
        except OSError:
            raise VaultError(f'Could not move the build into {versions} (another install of {version} finished first?)')
        return marker
    finally:
        shutil.rmtree(str(work), ignore_errors=True)


def default_roblox_root() -> Path:
    return Path(os.environ.get('LOCALAPPDATA') or Path.home() / 'AppData' / 'Local') / 'Arkuzo' / 'Roblox'


def _roblox_own_roots() -> list:
    """Install folders of Roblox and of other bootstrappers (never written or cleaned by Arkuzo)."""
    roots = []
    for name in ('LOCALAPPDATA', 'ProgramFiles', 'ProgramFiles(x86)'):
        base = os.environ.get(name)
        if base:
            roots.append(os.path.normcase(os.path.normpath(os.path.join(base, 'Roblox'))))
    local = os.environ.get('LOCALAPPDATA')
    if local:
        roots += [os.path.normcase(os.path.normpath(os.path.join(local, name))) for name in ('Bloxstrap', 'Fishstrap')]
    return roots


def validate_versions_dir(value) -> str:
    """robloxVersionsDir: empty (the default folder) or an absolute local folder outside Roblox's own."""
    if value in (None, ''):
        return ''
    if not isinstance(value, str) or len(value) > 200 or not re.match(r'\A[A-Za-z]:\\', value.strip().replace('/', '\\')):
        raise VaultError('Roblox versions folder must be a full local path such as D:\\Arkuzo\\Roblox')
    raw = value.strip().replace('/', '\\')
    text = os.path.normpath(raw)
    if '..' in raw.split('\\') or re.search(r'[<>"|?*\x00-\x1f]', text[2:]) or len(text) <= 3:
        raise VaultError('Roblox versions folder is not a valid folder')
    folded = os.path.normcase(text)
    for own in _roblox_own_roots():
        if folded == own or folded.startswith(own + os.sep):
            raise VaultError('Roblox versions folder must not be inside Roblox\'s, Bloxstrap\'s or Fishstrap\'s own folder')
    windir = os.path.normcase(os.environ.get('WINDIR') or 'C:\\Windows')
    if folded == windir or folded.startswith(windir + os.sep):
        raise VaultError('Roblox versions folder must not be inside Windows')
    return text


def roblox_root(setting: str) -> Path:
    return Path(setting) if setting else default_roblox_root()


def roblox_process_images():
    """[(pid, image path)] of running RobloxPlayerBeta.exe processes, or None when they cannot be listed."""
    if os.name != 'nt' or not WIN32.k:
        return []
    k = WIN32.k
    try:
        k.K32EnumProcesses.argtypes = [ctypes.POINTER(wintypes.DWORD), wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
        pids, needed = (wintypes.DWORD * 16384)(), wintypes.DWORD()
        if not k.K32EnumProcesses(pids, ctypes.sizeof(pids), ctypes.byref(needed)):
            return None
    except (OSError, AttributeError):
        return None
    found = []
    for pid in list(pids)[:needed.value // ctypes.sizeof(wintypes.DWORD)]:
        if pid <= 4:
            continue
        handle = k.OpenProcess(WIN32.PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
        if not handle:
            continue
        try:
            size, buf = wintypes.DWORD(1024), ctypes.create_unicode_buffer(1024)
            if k.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)) and Path(buf.value).name.lower() == 'robloxplayerbeta.exe':
                found.append((int(pid), buf.value))
        finally:
            k.CloseHandle(handle)
    return found


def _inside(path: str, folder: str) -> bool:
    try:
        a, b = os.path.normcase(os.path.realpath(path)), os.path.normcase(os.path.realpath(folder))
        return os.path.commonpath([a, b]) == b
    except (ValueError, OSError):
        return False


def _folder_bytes(folder: Path) -> int:
    total = 0
    for dirpath, _dirs, names in os.walk(str(folder)):
        for name in names:
            try:
                total += os.path.getsize(os.path.join(dirpath, name))
            except OSError:
                pass
    return total


def roblox_build_sources(root: Path) -> list:
    """(label, Versions folder, managed) for every place a Windows player build can live."""
    sources = [('Arkuzo', root / 'Versions', True)]
    local = os.environ.get('LOCALAPPDATA')
    if local:
        sources += [('Roblox', Path(local) / 'Roblox' / 'Versions', False), ('Bloxstrap', Path(local) / 'Bloxstrap' / 'Versions', False),
                    ('Fishstrap', Path(local) / 'Fishstrap' / 'Versions', False)]
    for name in ('ProgramFiles', 'ProgramFiles(x86)'):
        if os.environ.get(name):
            sources.append(('Roblox (all users)', Path(os.environ[name]) / 'Roblox' / 'Versions', False))
    return sources


class RobloxBuilds:
    """Installed builds in every known folder, with size and the clients using them."""

    def __init__(self):
        self.sizes = {}  # path -> (mtime, bytes)

    def _size(self, folder: Path) -> int | None:
        marker = read_json(folder / ROBLOX_INSTALL_MARKER)
        if isinstance(marker, dict) and isinstance(marker.get('bytes'), int):
            return marker['bytes']
        try:
            mtime = folder.stat().st_mtime
        except OSError:
            return None
        cached = self.sizes.get(str(folder))
        if not cached or cached[0] != mtime:
            cached = (mtime, _folder_bytes(folder))
            self.sizes[str(folder)] = cached
        return cached[1]

    def list(self, root: Path, images) -> list:
        builds, seen = [], set()
        for label, folder, managed in roblox_build_sources(root):
            try:
                children = sorted(folder.iterdir()) if folder.is_dir() else []
            except OSError:
                children = []
            for child in children:
                key = os.path.normcase(str(child))
                if key in seen or not child.is_dir() or not ROBLOX_VERSION.match(child.name) or _is_reparse(child):
                    continue
                exe = child / 'RobloxPlayerBeta.exe'
                if not exe.is_file():
                    continue
                seen.add(key)
                users = [pid for pid, image in (images or []) if _inside(image, str(child))]
                builds.append({'version': child.name, 'source': label, 'managed': managed, 'path': str(child),
                               'complete': roblox_build_complete(child),
                               'bytes': self._size(child) if managed else None, 'clients': len(users)})
        return builds


def remove_roblox_build(root: Path, version: str, pinned: str, images) -> None:
    """Delete an Arkuzo-installed build that no client runs and that is not pinned."""
    if not isinstance(version, str) or not ROBLOX_VERSION.match(version):
        raise VaultError('Roblox version must be version- followed by 16 hex digits')
    if version == pinned:
        raise VaultError('This build is pinned: choose Auto or another build first')
    versions = root / 'Versions'
    folder = versions / version
    if not folder.is_dir() or _is_reparse(folder) or os.path.normcase(os.path.dirname(os.path.realpath(str(folder)))) != os.path.normcase(os.path.realpath(str(versions))):
        raise VaultError('Only builds Arkuzo installed can be removed here')
    if images is None:
        raise VaultError('Could not check which builds running clients use; try again')
    if any(_inside(image, str(folder)) for _pid, image in images):
        raise VaultError('A running client uses this build: close it first')
    staging = root / '.staging'
    staging.mkdir(parents=True, exist_ok=True)
    trash = staging / ('remove-' + secrets.token_hex(4))
    try:
        os.rename(str(folder), str(trash))  # Fails while any process holds a file in it.
    except OSError:
        raise VaultError('The build is in use by a running program; close it first')
    shutil.rmtree(str(trash), ignore_errors=True)


def fetch_roblox_catalog() -> dict:
    """Roblox's current build, weao.gg's current, past and future builds and its exploit list."""
    out = {'fetchedAt': time.time(), 'errors': [], 'roblox': None, 'weao': {}, 'exploits': []}
    try:
        raw = json.loads(web_get(ROBLOX_CLIENT_VERSION_URL, 65536, {'Accept': 'application/json'}).decode('utf-8'))
        version, build = (raw.get('clientVersionUpload'), raw.get('version')) if isinstance(raw, dict) else (None, None)
        if isinstance(version, str) and ROBLOX_VERSION.match(version):
            out['roblox'] = {'version': version, 'build': build if isinstance(build, str) and BUILD_NUMBER.match(build) else None}
        else:
            out['errors'].append('Roblox\'s version service sent an unexpected answer')
    except (WebError, ValueError, UnicodeDecodeError):
        out['errors'].append('Roblox\'s version service did not answer')
    for key in ('current', 'past', 'future'):
        try:
            out['weao'][key] = parse_weao_versions(weao_get('/versions/' + key))
        except (WebError, ValueError, UnicodeDecodeError) as err:
            out['weao'][key] = {}
            if key == 'current':
                out['errors'].append('weao.gg did not answer' + (f' (HTTP {err.status})' if isinstance(err, WebError) and err.status > 0 else ''))
    try:
        out['exploits'] = parse_weao_exploits(weao_get('/status/exploits'))
    except (WebError, ValueError, UnicodeDecodeError):
        out['errors'].append('weao.gg\'s exploit list did not load')
    return out


def validate_follow(value) -> str:
    """robloxVersionFollow: '' (the build chosen by hand), 'latest' (Roblox's current build) or
    'exploit:<weao.gg id>' (the build that exploit supports)."""
    if value in (None, ''):
        return ''
    if value == 'latest':
        return value
    if isinstance(value, str) and value.startswith('exploit:') and EXPLOIT_ID.match(value[8:]):
        return value
    raise VaultError('Follow must be empty, "latest" or "exploit:" followed by a weao.gg exploit id')


def follow_target(catalog, follow: str) -> dict:
    """The build a follow setting wants right now: {'version', 'label', 'reason'}. weao.gg rows were
    validated by parse_weao_exploits; Roblox's own answer wins for 'latest'."""
    if not follow:
        return {'version': None, 'label': '', 'reason': ''}
    if not catalog:
        return {'version': None, 'label': '', 'reason': 'Roblox and weao.gg have not answered yet'}
    if follow == 'latest':
        version = RobloxVersions.current_version(catalog)
        return {'version': version, 'label': 'Roblox\'s current build', 'reason': '' if version else 'Could not find Roblox\'s current build'}
    ident = follow[8:]
    row = next((e for e in catalog.get('exploits') or [] if e.get('id') == ident), None)
    if row is None:
        reason = 'weao.gg\'s exploit list did not load' if not catalog.get('exploits') else 'This exploit is no longer listed on weao.gg'
        return {'version': None, 'label': '', 'reason': reason}
    if not row.get('usable'):
        return {'version': None, 'label': row['title'], 'reason': f"{row['title']}: {row.get('reason') or 'not usable'}"}
    return {'version': row['robloxVersion'], 'label': row['title'], 'reason': ''}


# ------------------------------------------------------------- roblox-player: protocol
# Roblox registers roblox-player: and roblox: in HKCU\Software\Classes; links on roblox.com and the
# Protocol launch method start whatever exe those keys name. Arkuzo can point them at the selected
# build. The keys as they were are saved to the data folder first and restored exactly when this is
# turned off or the pin goes back to Auto. Only HKCU is ever written.
def _winreg():
    import winreg  # Windows only; imported late so the module still loads elsewhere.
    return winreg


def _reg_subkeys(winreg, handle) -> list:
    subs, i = [], 0
    while True:
        try:
            subs.append(winreg.EnumKey(handle, i))
        except OSError:
            return subs
        i += 1


def protocol_snapshot(base: str, scheme: str) -> dict:
    """Every value under HKCU\\<base>\\<scheme> by relative key path: {'exists', 'keys': {path: {name: [type, data]}}}."""
    winreg = _winreg()
    keys = {}

    def walk(path):
        full = base + '\\' + scheme + ('\\' + path if path else '')
        try:
            handle = winreg.OpenKey(winreg.HKEY_CURRENT_USER, full)
        except OSError:
            return False
        with handle:
            values, i = {}, 0
            while True:
                try:
                    name, data, kind = winreg.EnumValue(handle, i)
                except OSError:
                    break
                if kind in (winreg.REG_SZ, winreg.REG_EXPAND_SZ, winreg.REG_DWORD) and len(values) < 50:
                    values[name] = [kind, data]
                i += 1
            keys[path] = values
            subs = _reg_subkeys(winreg, handle)
        for sub in subs[:50]:
            walk((path + '\\' if path else '') + sub)
        return True

    exists = walk('')
    return {'exists': exists, 'keys': keys if exists else {}}


def _protocol_delete(base: str, scheme: str):
    winreg = _winreg()

    def delete(full):
        try:
            handle = winreg.OpenKey(winreg.HKEY_CURRENT_USER, full)
        except OSError:
            return
        with handle:
            subs = _reg_subkeys(winreg, handle)
        for sub in subs:
            delete(full + '\\' + sub)
        try:
            winreg.DeleteKey(winreg.HKEY_CURRENT_USER, full)
        except OSError:
            pass
    delete(base + '\\' + scheme)


def _protocol_write_snapshot(base: str, scheme: str, snap: dict):
    winreg = _winreg()
    _protocol_delete(base, scheme)
    if not snap.get('exists'):
        return
    for path in sorted(snap.get('keys') or {}, key=lambda p: p.count('\\') + 1 if p else 0):
        full = base + '\\' + scheme + ('\\' + path if path else '')
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, full) as handle:
            for name, (kind, data) in (snap['keys'][path] or {}).items():
                winreg.SetValueEx(handle, name, 0, kind, data)


def protocol_command_exe(command) -> str | None:
    """The exe a shell\\open\\command value starts: '"C:\\...\\RobloxPlayerBeta.exe" %1' -> the path."""
    if not isinstance(command, str):
        return None
    match = re.match(r'\A\s*"([^"]+)"', command) or re.match(r'\A\s*(\S+)', command)
    return match.group(1) if match else None


def protocol_state(base: str = PROTOCOL_BASE) -> dict:
    """What roblox-player: starts now (HKCU), and whether Arkuzo wrote it."""
    try:
        snap = protocol_snapshot(base, 'roblox-player')
    except (ImportError, OSError):
        return {'exe': None, 'managed': False}
    command = ((snap['keys'].get('shell\\open\\command') or {}).get('') or [None, None])[1]
    return {'exe': protocol_command_exe(command), 'managed': PROTOCOL_MARK in (snap['keys'].get('') or {})}


def protocol_apply(data: Path, exe: str, base: str = PROTOCOL_BASE) -> dict:
    """Point roblox-player: and roblox: at exe. The keys as they were are saved first. A saved copy is
    replaced only when the keys are no longer Arkuzo's (Roblox's installer rewrote them since)."""
    exe = str(exe)
    if '"' in exe or not exe.lower().endswith('\\robloxplayerbeta.exe') or not re.match(r'\A[A-Za-z]:\\', exe):
        raise VaultError('Not a Roblox player path')
    winreg = _winreg()
    backup_path = data / PROTOCOL_BACKUP
    snaps = {scheme: protocol_snapshot(base, scheme) for scheme in PROTOCOL_SCHEMES}
    ours = all(PROTOCOL_MARK in (snaps[s]['keys'].get('') or {}) for s in PROTOCOL_SCHEMES)
    if not ours:
        write_json_atomic(backup_path, {'savedAt': time.time(), 'base': base, 'schemes': snaps})
    elif not backup_path.exists():
        # Arkuzo's keys but no saved copy (the file was deleted): restoring can only remove them.
        write_json_atomic(backup_path, {'savedAt': time.time(), 'base': base, 'schemes': {s: {'exists': False, 'keys': {}} for s in PROTOCOL_SCHEMES}})
    command = f'"{exe}" %1'
    for scheme in PROTOCOL_SCHEMES:
        root = base + '\\' + scheme
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, root) as handle:
            winreg.SetValueEx(handle, '', 0, winreg.REG_SZ, 'URL: Roblox Protocol')
            winreg.SetValueEx(handle, 'URL Protocol', 0, winreg.REG_SZ, '')
            winreg.SetValueEx(handle, PROTOCOL_MARK, 0, winreg.REG_SZ, '1')
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, root + '\\DefaultIcon') as handle:
            winreg.SetValueEx(handle, '', 0, winreg.REG_SZ, exe)
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, root + '\\shell\\open\\command') as handle:
            winreg.SetValueEx(handle, '', 0, winreg.REG_SZ, command)
    return protocol_state(base)


def protocol_restore(data: Path, base: str = PROTOCOL_BASE) -> bool:
    """Put the keys back exactly as they were before Arkuzo changed them. False when nothing was saved."""
    backup_path = data / PROTOCOL_BACKUP
    backup = read_json(backup_path)
    if not isinstance(backup, dict) or not isinstance(backup.get('schemes'), dict) or backup.get('base', base) != base:
        return False
    for scheme in PROTOCOL_SCHEMES:
        snap = backup['schemes'].get(scheme)
        if isinstance(snap, dict) and PROTOCOL_MARK in (protocol_snapshot(base, scheme)['keys'].get('') or {}):
            _protocol_write_snapshot(base, scheme, snap)  # Only Arkuzo's own keys are replaced.
    try:
        backup_path.unlink()
    except OSError:
        pass
    return True


class RobloxVersions:
    """The Roblox tab: catalog (cached), installed builds, the one install that may run, the pin."""

    def __init__(self, data: Path, feed=None):
        self.data, self.feed = data, feed
        self.builds = RobloxBuilds()
        self.catalog_lock, self.status_lock = threading.Lock(), threading.Lock()
        self.catalog_data, self.catalog_at = None, 0.0
        self.thread, self.cancel_event = None, threading.Event()
        self.status = {'state': 'idle'}
        # Follow mode (robloxVersionFollow) and the roblox-player: protocol.
        self.follow_lock = threading.RLock()
        self.follow_state = {'follow': '', 'state': 'off'}
        self.protocol_base, self.protocol_error = PROTOCOL_BASE, ''
        self.on_switch = None  # Close all (App sets it): "apply now" relaunches the farm's clients on the new build.
        self.restart_on_pin = False
        self.stop_event = threading.Event()

    def settings(self) -> dict:
        try:
            return load_vault(self.data)['settings']
        except (OSError, VaultError):
            return empty_vault()['settings']

    def root(self, settings=None) -> Path:
        return roblox_root((settings or self.settings()).get('robloxVersionsDir') or '')

    def catalog(self, refresh=False, cached_only=False) -> dict | None:
        if cached_only:
            return self.catalog_data  # Never waits for a fetch in flight (install progress polls this).
        # One fetch at a time: concurrent requests wait for it and share its answer.
        with self.catalog_lock:
            age = time.time() - self.catalog_at
            if (self.catalog_data and age < WEAO_CACHE_SEC and not (refresh and age >= WEAO_REFRESH_MIN_SEC)):
                return self.catalog_data
            self.catalog_data, self.catalog_at = fetch_roblox_catalog(), time.time()
            return self.catalog_data

    @staticmethod
    def current_version(catalog) -> str | None:
        if not catalog:
            return None
        return (catalog.get('roblox') or {}).get('version') or ((catalog.get('weao') or {}).get('current') or {}).get('version')

    def progress(self) -> dict:
        with self.status_lock:
            return dict(self.status)

    def _set(self, **changes):
        with self.status_lock:
            self.status.update(changes)

    def view(self, refresh=False, cached_only=False, heartbeat=None) -> dict:
        settings = self.settings()
        root = self.root(settings)
        catalog = self.catalog(refresh, cached_only)
        images = roblox_process_images()
        builds = self.builds.list(root, images)
        current = self.current_version(catalog)
        pinned = settings.get('robloxVersion') or 'auto'
        numbers = {}
        for known in [((catalog or {}).get('weao') or {}).get(k) or {} for k in ('future', 'past', 'current')] + [(catalog or {}).get('roblox') or {}]:
            if known.get('version') and known.get('build'):
                numbers[known['version']] = known['build']
        for build in builds:
            build.update(current=build['version'] == current, pinned=build['version'] == pinned, build=numbers.get(build['version']),
                         removable=build['managed'] and build['version'] != pinned and not build['clients'])
        hb = heartbeat if isinstance(heartbeat, dict) else {}
        follow = settings.get('robloxVersionFollow') or ''
        with self.follow_lock:
            follow_state = dict(self.follow_state)
        if follow_state.get('follow') != follow:
            follow_state = {'follow': follow, 'state': 'checking' if follow else 'off'}
        if follow and catalog:  # What the followed source wants now, from the cached catalog.
            target = follow_target(catalog, follow)
            follow_state.update(wanted=target['version'], label=target['label'], reason=target['reason'])
        protocol = dict(protocol_state(self.protocol_base), enabled=bool(settings.get('robloxProtocol')),
                        saved=(self.data / PROTOCOL_BACKUP).exists(), error=self.protocol_error)
        return {'catalog': catalog, 'current': current, 'builds': builds, 'install': self.progress(), 'root': str(root),
                'defaultRoot': str(default_roblox_root()), 'selection': {'version': pinned, 'fallback': bool(settings.get('robloxVersionFallback')),
                'dir': settings.get('robloxVersionsDir') or '', 'launchMethod': settings.get('launchMethod'), 'follow': follow,
                'followRestart': bool(settings.get('robloxFollowRestart'))},
                'follow': follow_state, 'protocol': protocol,
                'engine': hb.get('robloxVersion'), 'provider': hb.get('accountProvider'), 'clientsListed': images is not None}

    def start_install(self, version) -> dict:
        if version == 'latest':
            version = self.current_version(self.catalog())
            if not version:
                raise VaultError('Could not find Roblox\'s current build; try again later')
        if not isinstance(version, str) or not ROBLOX_VERSION.match(version):
            raise VaultError('Roblox version must be version- followed by 16 hex digits')
        root = self.root()
        with self.status_lock:
            if self.thread is not None and self.thread.is_alive():
                raise VaultError('An install is already running')
            self.cancel_event = threading.Event()
            self.status = {'state': 'running', 'version': version, 'phase': 'Starting', 'done': 0, 'total': 0, 'message': '',
                           'startedAt': time.time(), 'finishedAt': None}
            self.thread = threading.Thread(target=self._run, args=(version, root, self.cancel_event), daemon=True, name='roblox-install')
            self.thread.start()
        return self.progress()

    def cancel(self) -> dict:
        with self.status_lock:
            running = self.thread is not None and self.thread.is_alive()
        if not running:
            raise VaultError('No install is running')
        self.cancel_event.set()
        return self.progress()

    def _note(self, text: str, level: str):
        if self.feed is not None:
            try:
                self.feed.add({'t': time.time(), 'kind': 'SUPERVISOR', 'category': 'saver', 'level': level, 'text': text})
            except Exception:
                pass

    def _run(self, version: str, root: Path, cancel):
        try:
            install_roblox_build(version, root, self._set, cancel)
            self._set(state='done', phase='Installed', message=f'{version} installed', finishedAt=time.time())
            self._note(f'Roblox {version} installed in {root / "Versions"}', 'info')
            if self.settings().get('robloxVersionFollow'):
                self.follow_tick(network=False, from_install=True)  # Following: the new build becomes the pin now.
        except InstallCancelled:
            self._set(state='cancelled', phase='Cancelled', message='Install cancelled; nothing was installed', finishedAt=time.time())
        except VaultError as exc:
            self._set(state='failed', phase='Failed', message=str(exc), finishedAt=time.time())
            self._note(f'Roblox {version} not installed: {exc}', 'warning')
        except Exception as exc:  # Disk full, access denied...: the type only.
            self._set(state='failed', phase='Failed', message=f'Install failed ({type(exc).__name__})', finishedAt=time.time())
            self._note(f'Roblox {version} not installed ({type(exc).__name__})', 'warning')

    def remove(self, version) -> dict:
        settings = self.settings()
        with self.status_lock:
            if self.thread is not None and self.thread.is_alive() and self.status.get('version') == version:
                raise VaultError('This build is being installed')
        remove_roblox_build(self.root(settings), version, settings.get('robloxVersion') or 'auto', roblox_process_images())
        self._note(f'Roblox {version} removed', 'info')
        return {'removed': version}

    def select(self, version, fallback=None, keep_follow=False) -> dict:
        if version != 'auto':
            if not isinstance(version, str) or not ROBLOX_VERSION.match(version):
                raise VaultError('Roblox version must be "auto" or version- followed by 16 hex digits')
            settings = self.settings()
            if not any(b['version'] == version and b['complete'] for b in self.builds.list(self.root(settings), [])):
                raise VaultError(f'{version} is not installed: install it first')
        changes = {'robloxVersion': version}
        if not keep_follow:
            changes['robloxVersionFollow'] = ''  # A build chosen by hand ends following.
        if isinstance(fallback, bool):
            changes['robloxVersionFallback'] = fallback
        result = update_vault_settings(self.data, changes)
        self.sync_protocol(result)
        return result

    def _pinned_exe(self, settings) -> str | None:
        pin = settings.get('robloxVersion') or 'auto'
        if pin == 'auto':
            return None
        for build in self.builds.list(self.root(settings), []):  # Arkuzo's folder first.
            if build['version'] == pin and build['complete']:
                return str(Path(build['path']) / 'RobloxPlayerBeta.exe')
        return None

    def sync_protocol(self, settings=None) -> dict:
        """roblox-player: names the pinned build while robloxProtocol is on and a build is pinned;
        otherwise the keys Arkuzo replaced are put back. Never raises."""
        settings = settings or self.settings()
        try:
            wanted = settings.get('robloxProtocol') and (settings.get('robloxVersion') or 'auto') != 'auto'
            exe = self._pinned_exe(settings) if wanted else None
            if exe:
                now = protocol_state(self.protocol_base)
                if not now['managed'] or os.path.normcase(now['exe'] or '') != os.path.normcase(exe) or not (self.data / PROTOCOL_BACKUP).exists():
                    protocol_apply(self.data, exe, self.protocol_base)
                    self._note(f'roblox-player: links now start Roblox {Path(exe).parent.name}', 'info')
            elif not wanted and protocol_restore(self.data, self.protocol_base):
                self._note('roblox-player: links start Roblox\'s own build again (keys restored)', 'info')
            self.protocol_error = ''
        except (ImportError, OSError, VaultError) as exc:
            self.protocol_error = f'Could not change the roblox-player: link ({type(exc).__name__})'
        return protocol_state(self.protocol_base)

    def set_protocol(self, enabled) -> dict:
        if not isinstance(enabled, bool):
            raise VaultError('enabled must be true or false')
        settings = update_vault_settings(self.data, {'robloxProtocol': enabled})
        state = self.sync_protocol(settings)
        if self.protocol_error:
            raise VaultError(self.protocol_error)
        return state

    def set_mode(self, mode, version=None, apply=None, restart=None) -> dict:
        """One switch for the tab: 'auto', 'pinned' (+ version), 'latest' or 'exploit:<id>' (follow).
        apply 'now' closes the farm's clients so they relaunch on the new build at once (Close all);
        anything else lets them switch as they relaunch. Returns the previous choice for Undo."""
        settings = self.settings()
        previous = {'version': settings.get('robloxVersion') or 'auto', 'follow': settings.get('robloxVersionFollow') or ''}
        now = apply == 'now'
        if mode in ('auto', 'pinned'):
            self.select('auto' if mode == 'auto' else version)
            if isinstance(restart, bool):
                update_vault_settings(self.data, {'robloxFollowRestart': restart})
            after = self.settings().get('robloxVersion') or 'auto'
            closed = self.on_switch() if now and after != previous['version'] and self.on_switch else None
            return {'previous': previous, 'version': after, 'follow': '', 'closed': closed}
        follow = validate_follow(mode)
        if not follow:
            raise VaultError('Unknown mode')
        changes = {'robloxVersionFollow': follow}
        if isinstance(restart, bool):
            changes['robloxFollowRestart'] = restart
        update_vault_settings(self.data, changes)
        with self.follow_lock:
            self.follow_state = {'follow': follow, 'state': 'checking'}
        self.restart_on_pin = now
        threading.Thread(target=self._follow_safe, kwargs={'network': True}, daemon=True, name='roblox-follow-now').start()
        return {'previous': previous, 'version': previous['version'], 'follow': follow, 'closed': None}

    def _follow_safe(self, **kwargs):
        try:
            self.follow_tick(**kwargs)
        except Exception as exc:  # The follower must never die; the type only.
            with self.follow_lock:
                self.follow_state = dict(self.follow_state, state='error', message=f'Check failed ({type(exc).__name__})')

    def follow_tick(self, network=True, from_install=False) -> dict:
        """Follow mode: install the build the followed source wants (from Roblox's CDN) and pin it."""
        # The network fetch happens outside the lock: the page's polling reads follow_state under it.
        catalog = None
        if self.settings().get('robloxVersionFollow'):
            catalog = self.catalog(refresh=True) if network else self.catalog(cached_only=True)
        with self.follow_lock:
            settings = self.settings()
            follow = settings.get('robloxVersionFollow') or ''
            if not follow:
                self.follow_state = {'follow': '', 'state': 'off'}
                self.sync_protocol(settings)
                return dict(self.follow_state)
            target = follow_target(catalog, follow)
            state = {'follow': follow, 'checkedAt': time.time(), 'target': target['version'], 'label': target['label'],
                     'state': 'waiting', 'message': target['reason']}
            version = target['version']
            if version:
                # Only Arkuzo's own folder counts: Roblox's updater deletes the builds in its folders.
                installed = any(b['version'] == version and b['complete'] and b['managed'] for b in self.builds.list(self.root(settings), []))
                progress = self.progress()
                if installed:
                    state['state'] = 'pinned'
                    if (settings.get('robloxVersion') or 'auto') != version:
                        self.select(version, keep_follow=True)
                        state['message'] = f'Switched to {version}'
                        self._note(f'Following {target["label"]}: the saver now launches Roblox {version}', 'info')
                        if (self.restart_on_pin or settings.get('robloxFollowRestart')) and self.on_switch:
                            self.on_switch()
                    self.restart_on_pin = False
                elif progress.get('state') == 'running':
                    mine = progress.get('version') == version
                    state.update(state='installing' if mine else 'waiting', message='' if mine else 'Another install is running')
                elif progress.get('state') == 'failed' and progress.get('version') == version and not from_install \
                        and time.time() - (progress.get('finishedAt') or 0) < ROBLOX_FOLLOW_SEC - 30:
                    state.update(state='error', message=progress.get('message') or 'Install failed; tried again at the next check')
                else:
                    self.start_install(version)
                    state['state'] = 'installing'
                    self._note(f'Following {target["label"]}: installing Roblox {version} from Roblox\'s CDN', 'info')
            self.follow_state = state
            self.sync_protocol()
            return dict(state)

    def start_follower(self):
        """Re-checks every ROBLOX_FOLLOW_SEC while following; puts the protocol keys right at start."""
        def loop():
            self.sync_protocol()
            if self.settings().get('robloxVersionFollow'):
                self._follow_safe(network=True)
            while not self.stop_event.wait(ROBLOX_FOLLOW_SEC):
                if self.settings().get('robloxVersionFollow'):
                    self._follow_safe(network=True)
        threading.Thread(target=loop, daemon=True, name='roblox-follow').start()

    def exploits(self, ids) -> dict:
        catalog = self.catalog()
        if not catalog or not catalog.get('exploits'):
            raise VaultError('weao.gg\'s exploit list is not loaded; refresh')
        return exploit_build(catalog['exploits'], ids, self.current_version(catalog))


# ------------------------------------------------------------- application
class App:
    def __init__(self, data: Path, port: int):
        self.data = data
        self.port = port
        self.token = secrets.token_urlsafe(24)
        self.desktop = DesktopWindows(data / 'desktop-browser', relaunch=desktop_relaunch_command(data, port))
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
        self.roblox = RobloxVersions(data, self.feed)
        self.roblox.on_switch = lambda: close_all_clients(self.data).get('closed')
        _purge_quietly(data)  # Deleted accounts a previous Control Center held for Undo are gone now.
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
        # Nothing in a pass may end this thread: it is the only thing that restarts the saver.
        while not self.stop_event.is_set():
            try:
                now = time.time()
                if self.close_window_pass(now):
                    return
                self.step(now)
            except Exception as exc:
                try:
                    self.supervisor.message = f'Supervisor error: {type(exc).__name__}'
                except Exception:
                    pass
            finally:
                self.stop_event.wait(2.0)

    def close_window_pass(self, now: float) -> bool:
        """True when the last window closed and the Control Center shut down."""
        if not self.window_close_due(now):
            return False
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
            return True
        if was_running:
            self.supervisor.start()  # A window came back while the saver stopped: carry on.
        return False

    def step(self, now: float):
        """One pass of the supervisor loop. No part of it may end the loop: this thread is
        the only thing that restarts the saver, and the page keeps answering without it."""
        try:
            self.heartbeat = read_json(self.data / 'runtime-status.json', retry_missing=True)
        except Exception:
            self.heartbeat = None
        try:
            self.supervisor.tick(self.heartbeat, now)
        except Exception as exc:  # The supervisor must outlive any single failure.
            self.supervisor.message = f'Supervisor error: {type(exc).__name__}'
        # A malformed log line, heartbeat value or vault must not stop supervision either.
        for part in (lambda: self.feed.poll(self.names()), lambda: self.cookies.tick(now), self.drain_vault_events, lambda: self._sample(now)):
            try:
                part()
            except Exception:
                pass

    def drain_vault_events(self):
        """Vault restores and resets (load_vault has no App) reach the activity feed here."""
        for event in take_vault_events():
            self.feed.add(event)

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
        error, damaged = None, False
        try:
            vault = load_vault(self.data)
        except (OSError, VaultError) as exc:
            vault, error, damaged = empty_vault(), str(exc), isinstance(exc, VaultDamagedError)
        self.drain_vault_events()
        view = public_vault(vault)
        hb = self.heartbeat if isinstance(self.heartbeat, dict) else {}
        live = {a.get('accountId'): a for a in hb.get('accounts') or [] if isinstance(a, dict)}
        for a in view['accounts']:
            seen = live.get(a['id']) or {}
            a['live'] = {'uiStatus': seen.get('uiStatus'), 'processId': seen.get('processId')}
            a['checking'] = a['id'] in self.cookies.busy
        config = read_json(self.data / 'config.json') or {}
        view.update(monitors=monitor_count(), screen=work_area(), error=error, damaged=damaged, provider=((config.get('accounts') or {}).get('provider') or 'auto'),
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
            view = {k: hb.get(k) for k in HEARTBEAT_VIEW_KEYS}
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
    copy_file_durable(source, folder / ('config-' + time.strftime('%Y%m%d-%H%M%S') + '.json'))
    for old in sorted(folder.glob('config-*.json'))[:-15]:
        old.unlink(missing_ok=True)


class Handler(BaseHTTPRequestHandler):
    app: App = None  # Set by serve().
    server_version = 'ArkuzoControlCenter'

    def log_message(self, *args):
        pass

    def _send(self, code, body, content_type='application/json; charset=utf-8'):
        raw = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode('utf-8')
        self._responded = True
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

    def _guarded(self, handler):
        """Any unexpected error becomes a JSON 500 instead of a dropped connection. The body and
        the activity feed name the error type only: a message could quote a token or cookie."""
        self._responded = False
        try:
            handler()
        except Exception as exc:
            name = type(exc).__name__
            try:
                path = urllib.parse.urlparse(self.path).path[:80]
                self.app.feed.add({'t': time.time(), 'kind': 'SUPERVISOR', 'category': 'error', 'level': 'warning',
                                   'text': f'Control Center request {path} failed ({name})'})
            except Exception:
                pass
            if not self._responded:
                try:
                    self._send(500, {'error': f'Internal error ({name})'})
                except Exception:
                    pass

    def do_GET(self):
        self._guarded(self._get)

    def do_POST(self):
        self._guarded(self._post)

    # ---- Routes (GET_ROUTES, POST_ROUTES below the class). Every request is checked for a
    # loopback Host first. GET routes need no token: the page itself carries it (GET / writes it
    # in), so the token stops other web origins, not other programs of this Windows user
    # (docs/architecture.md, section 3). POST routes need the X-Arkuzo-Token header; the close
    # beacon may carry it in its body instead, because a closing window can only send a beacon,
    # which has no headers. An unknown POST path is answered 404 only after a valid token.
    AUTH_TOKEN, AUTH_BEACON = 'token', 'beacon'

    def _get(self):
        if not self._host_ok():
            return self._send(403, {'error': 'forbidden'})
        url = urllib.parse.urlparse(self.path)
        route = GET_ROUTES.get(url.path)
        if route is None:
            return self._send(404, {'error': 'not found'})
        return route(self, urllib.parse.parse_qs(url.query))

    def _get_page(self, query):
        try:
            html = UI_FILE.read_text(encoding='utf-8').replace('__ARKUZO_TOKEN__', self.app.token)
        except OSError:
            return self._send(500, b'Arkuzo-Control-Center.html is missing next to the Control Center.', 'text/plain; charset=utf-8')
        return self._send(200, html.encode('utf-8'), 'text/html; charset=utf-8')

    def _get_ping(self, query):
        return self._send(200, {'app': APP_ID, 'version': self.app.version, 'instance': self.app.instance})

    def _get_desktop_window(self, query):
        token = self.headers.get('X-Arkuzo-Token', '')
        if not secrets.compare_digest(token.encode('utf-8', 'replace'), self.app.token.encode('ascii')):
            return self._send(403, {'error': 'forbidden'})
        return self._send(200, self.app.desktop.status((query.get('key') or [''])[0]))

    def _get_state(self, query):
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

    def _get_vault(self, query):
        return self._send(200, self.app.vault_view())

    def _get_avatar(self, query):
        uid = (query.get('userId') or [''])[0]
        png = avatar_png(self.app.data, uid) if DIGITS.match(uid) else None
        return self._send(200, png, 'image/png') if png else self._send(404, {'error': 'no avatar'})

    def _get_roblox(self, query):
        # refresh=1 refetches weao.gg (at most every WEAO_REFRESH_MIN_SEC); cached=1 never goes to the
        # network (the page polls it while an install runs).
        flag = lambda name: (query.get(name) or [''])[0] == '1'  # noqa: E731
        return self._send(200, self.app.roblox.view(refresh=flag('refresh'), cached_only=flag('cached'), heartbeat=self.app.heartbeat))

    def _get_config(self, query):
        config = read_json(self.app.data / 'config.json')
        return self._send(200, {'config': config, 'presets': PRESETS, 'schema': {s: {k: list(v) for k, v in rules.items()} for s, rules in SCHEMA.items()},
                                'restartKeys': sorted(RESTART_KEYS)})

    def _post(self):
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
        handler, auth = post_route(path)
        token = self.headers.get('X-Arkuzo-Token', '')
        if not token and auth == self.AUTH_BEACON and body:
            token = str(body.get('token') or '')
        if not secrets.compare_digest(token.encode('utf-8', 'replace'), app.token.encode('ascii')):
            return self._send(403, {'error': 'forbidden'})
        if body is None:
            return self._send(400, {'error': 'Invalid JSON'})
        if handler is None:
            return self._send(404, {'error': 'not found'})
        try:
            return self._send(200, handler(app, body, path))
        except (ConfigError, VaultError) as exc:
            return self._send(400, {'error': str(exc)})
        except OSError as exc:
            return self._send(500, {'error': f'{type(exc).__name__}: {exc.strerror or exc}'})


# ---------------------------------------------------------------- POST handlers
# Each takes (app, body, path) and returns the JSON reply; ConfigError/VaultError become 400.
def post_window_closed(app, body, path):
    app.page_closed(str(body.get('page') or '')[:64])
    return {'result': 'noted'}


def post_saver_start(app, body, path):
    return {'result': app.supervisor.start()}


def post_saver_stop(app, body, path):
    return {'result': app.supervisor.stop()}


def post_saver_restart(app, body, path):
    app.supervisor.stop()
    return {'result': app.supervisor.start()}


def post_remote_leave(app, body, path):
    return {'result': leave_remote_desktop()}


def post_remote_session(app, body, path):
    return {'result': own_session()}


def post_trim_now(app, body, path):
    (app.data / 'trim-now.signal').write_text('trim', encoding='ascii')
    return {'result': 'requested'}


def post_config(app, body, path):
    config = read_json(app.data / 'config.json')
    if config is None:
        raise ConfigError('data/config.json is missing or invalid; fix it before editing here')
    merged, restart = apply_config_changes(config, body.get('changes') or {})
    backup_config(app.data)
    write_json_atomic(app.data / 'config.json', merged)
    return {'result': 'saved', 'restartRequired': restart, 'config': merged}


def post_account_recovery(app, body, path):
    config = read_json(app.data / 'config.json')
    if config is None:
        raise ConfigError('data/config.json is missing or invalid')
    merged = set_account_recovery(config, str(body.get('accountId') or ''), bool(body.get('enabled')))
    backup_config(app.data)
    write_json_atomic(app.data / 'config.json', merged)
    return {'result': 'saved'}


def post_prefs(app, body, path):
    for key in ('autopilot', 'startSaverOnLaunch'):
        if isinstance(body.get(key), bool):
            app.prefs[key] = body[key]
    if isinstance(body.get('autopilot'), bool) and body['autopilot']:
        app.supervisor.crash_loop = False
        app.supervisor.failures = 0
    app.save_prefs()
    if isinstance(body.get('startWithWindows'), bool):
        set_startup(body['startWithWindows'], app.data)
    return {'result': 'saved', 'prefs': dict(app.prefs, startWithWindows=startup_enabled())}


def post_vault(app, body, path):
    return {'result': vault_action(app, path, body)}


def post_roblox(app, body, path):
    return {'result': ROBLOX_ROUTES[path](app, body)}


def post_quit(app, body, path):
    if body.get('stopSaver'):
        app.supervisor.stop()
    threading.Thread(target=app.shutdown, daemon=True).start()
    return {'result': 'bye'}


# ---------------------------------------------------------------- account and farm actions
def vault_login_cancel(app, body):
    app.login.cancel()
    return app.login.snapshot()


def vault_check(app, body):
    ids = body.get('ids')
    return {'checking': app.cookies.check(ids if isinstance(ids, list) else None)}


def vault_remove(app, body):
    remove_account(app.data, str(body.get('id') or ''))
    return 'removed'


def vault_server_remove(app, body):
    remove_private_server(app.data, str(body.get('id') or ''))
    return 'removed'


def vault_bulk(app, body):
    action = body.get('action')
    if action == 'check':
        chosen = bulk_ids(load_vault(app.data), body.get('ids'))
        return {'checking': app.cookies.check([a['id'] for a in chosen]), 'count': len(chosen)}
    return bulk_accounts(app.data, action, body.get('ids'), body.get('value'), body.get('batch'))


def vault_farm_start(app, body):
    settings = set_farm_running(app.data, True)
    if app.supervisor.state not in ('running', 'starting', 'restarting', 'external'):
        app.supervisor.start()  # The saver does the launching.
    return settings


# path -> action(app, body); post_vault wraps the result as {'result': ...}.
VAULT_ROUTES = {
    '/api/vault/add': lambda app, body: add_account(app.data, str(body.get('cookie') or '')),
    '/api/vault/login': lambda app, body: app.login.start(),
    '/api/vault/login/cancel': vault_login_cancel,
    '/api/vault/check': vault_check,
    '/api/vault/update': lambda app, body: update_account(app.data, str(body.get('id') or ''), body.get('fields')),
    '/api/vault/remove': vault_remove,
    '/api/vault/bulk': vault_bulk,
    '/api/vault/launch': lambda app, body: request_account_action(app.data, str(body.get('id') or ''), 'launch'),
    '/api/vault/close': lambda app, body: request_account_action(app.data, str(body.get('id') or ''), 'close'),
    '/api/vault/settings': lambda app, body: update_vault_settings(app.data, body.get('changes')),
    '/api/vault/arrange': lambda app, body: update_vault_settings(app.data, {'arrangeRequestedAtMs': now_ms()}),
    '/api/vault/servers/add': lambda app, body: add_private_server(app.data, str(body.get('name') or ''), str(body.get('link') or '')),
    '/api/vault/servers/remove': vault_server_remove,
    '/api/vault/reset': lambda app, body: reset_vault(app.data),
    '/api/farm/start': vault_farm_start,
    '/api/farm/stop': lambda app, body: set_farm_running(app.data, False),
    '/api/farm/close-all': lambda app, body: close_all_clients(app.data),
}


def vault_action(app: App, path: str, body: dict):
    action = VAULT_ROUTES.get(path)
    if action is None:
        raise VaultError('Unknown account action')
    return action(app, body)


# ---------------------------------------------------------------- route table
# GET: path -> Handler method, no token. POST: path -> (handler, auth).
GET_ROUTES = {
    '/api/desktop-window': Handler._get_desktop_window,
    '/': Handler._get_page,
    '/index.html': Handler._get_page,
    '/api/ping': Handler._get_ping,
    '/api/state': Handler._get_state,
    '/api/vault': Handler._get_vault,
    '/api/avatar': Handler._get_avatar,
    '/api/config': Handler._get_config,
    '/api/roblox': Handler._get_roblox,
}
# The Roblox tab's actions (docs/roblox-versions.md); post_roblox wraps the result as {'result': ...}.
ROBLOX_ROUTES = {
    '/api/roblox/install': lambda app, body: app.roblox.start_install(body.get('version')),
    '/api/roblox/install/cancel': lambda app, body: app.roblox.cancel(),
    '/api/roblox/remove': lambda app, body: app.roblox.remove(body.get('version')),
    '/api/roblox/select': lambda app, body: app.roblox.select(body.get('version'), body.get('fallback')),
    '/api/roblox/mode': lambda app, body: app.roblox.set_mode(body.get('mode'), body.get('version'), body.get('apply'), body.get('restart')),
    '/api/roblox/protocol': lambda app, body: app.roblox.set_protocol(body.get('enabled')),
    '/api/roblox/exploits': lambda app, body: app.roblox.exploits(body.get('ids')),
}
POST_ROUTES = {
    '/api/desktop-window/open': (lambda app, body, path: desktop_open(app), Handler.AUTH_TOKEN),
    '/api/desktop-window': (lambda app, body, path: app.desktop.action(body.get('key'), body.get('action'), body.get('colors')),
                            Handler.AUTH_TOKEN),
    '/api/window-closed': (post_window_closed, Handler.AUTH_BEACON),
    '/api/saver/start': (post_saver_start, Handler.AUTH_TOKEN),
    '/api/saver/stop': (post_saver_stop, Handler.AUTH_TOKEN),
    '/api/saver/restart': (post_saver_restart, Handler.AUTH_TOKEN),
    '/api/remote/leave': (post_remote_leave, Handler.AUTH_TOKEN),
    '/api/remote/session': (post_remote_session, Handler.AUTH_TOKEN),
    '/api/trim-now': (post_trim_now, Handler.AUTH_TOKEN),
    '/api/config': (post_config, Handler.AUTH_TOKEN),
    '/api/accounts/recovery': (post_account_recovery, Handler.AUTH_TOKEN),
    '/api/prefs': (post_prefs, Handler.AUTH_TOKEN),
    '/api/quit': (post_quit, Handler.AUTH_TOKEN),
}
POST_ROUTES.update({path: (post_vault, Handler.AUTH_TOKEN) for path in VAULT_ROUTES})
POST_ROUTES.update({path: (post_roblox, Handler.AUTH_TOKEN) for path in ROBLOX_ROUTES})


def post_route(path: str):
    """(handler, auth) for a POST path. Unknown paths need the token too, and an unknown path
    under /api/vault/ or /api/farm/ stays a 400 "Unknown account action"."""
    if path in POST_ROUTES:
        return POST_ROUTES[path]
    if path.startswith('/api/vault/') or path.startswith('/api/farm/'):
        return post_vault, Handler.AUTH_TOKEN
    return None, Handler.AUTH_TOKEN


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



# ---------------------------------------------------------------- desktop window
# The desktop Control Center is a native host window with a real title bar strip,
# and an unmodified Edge --app window embedded below the strip. The host answers
# WM_NCHITTEST for the strip (caption, caption buttons, top edge) and keeps the
# standard, invisible left/right/bottom sizing frame, so Windows itself moves,
# snaps, maximizes, resizes and shows the system menu. Nothing about moving or
# sizing a window travels over HTTP: the page only reports its theme colours.
# The host has the Arkuzo icon and its own AppUserModelID, so the taskbar shows
# the Control Center (not Python), and Edge never gets a taskbar button of its own.
DESKTOP_APP_ID = 'Arkuzo.MemorySaver.ControlCenter'
DESKTOP_TITLE = 'Arkuzo Memory Saver'
DESKTOP_THEME_KEYS = ('bar', 'barEnd', 'line', 'text', 'muted', 'hover', 'pressed', 'closeHover')
DESKTOP_THEME_DEFAULT = {'bar': '#101218', 'barEnd': '#16181f', 'line': '#0a0b0f', 'text': '#eef1f6',
                         'muted': '#7e879a', 'hover': '#2a2f3d', 'pressed': '#232733', 'closeHover': '#c42b1c'}
_HEX_COLOR = re.compile(r'\A#[0-9a-fA-F]{6}\Z')
CAPTION_HEIGHT, CAPTION_BUTTON, CAPTION_EDGE = 32, 46, 5  # pixels at 96 DPI
HTCLIENT, HTCAPTION, HTMINBUTTON, HTMAXBUTTON = 1, 2, 8, 9
HTTOP, HTTOPLEFT, HTTOPRIGHT, HTCLOSE = 12, 13, 14, 20
CAPTION_BUTTONS = (HTCLOSE, HTMAXBUTTON, HTMINBUTTON)  # right to left
WM_APP_THEME, WM_APP_CHILD, WM_APP_FOCUS = 0x8001, 0x8002, 0x8003


def desktop_theme(colors) -> dict:
    """The page's title bar colours: exactly DESKTOP_THEME_KEYS, each '#rrggbb'."""
    if not isinstance(colors, dict) or set(colors) != set(DESKTOP_THEME_KEYS):
        raise VaultError('Theme colours must name exactly: ' + ', '.join(DESKTOP_THEME_KEYS))
    for key in DESKTOP_THEME_KEYS:
        if not isinstance(colors[key], str) or not _HEX_COLOR.match(colors[key]):
            raise VaultError('Theme colour ' + key + ' must look like #rrggbb')
    return {key: colors[key].lower() for key in DESKTOP_THEME_KEYS}


def colorref(value: str) -> int:
    """'#rrggbb' -> a Win32 COLORREF (0x00bbggrr)."""
    n = int(value[1:], 16)
    return ((n & 0xFF) << 16) | (n & 0xFF00) | (n >> 16)


def shade(value: str, factor: float) -> str:
    n = int(value[1:], 16)
    return '#' + ''.join('%02x' % max(0, min(255, round(((n >> s) & 255) * factor))) for s in (16, 8, 0))


def caption_metrics(dpi: int) -> tuple:
    """(strip height, caption button width, top resize band) in pixels at this DPI."""
    return tuple(max(1, (n * dpi + 48) // 96) for n in (CAPTION_HEIGHT, CAPTION_BUTTON, CAPTION_EDGE))


def caption_hit_test(x: int, y: int, width: int, dpi: int, maximized: bool) -> int:
    """WM_NCHITTEST code for a point in the host's client area (client pixels). Only the
    strip belongs to the host; the left/right/bottom edges are Windows' own sizing frame."""
    height, button, edge = caption_metrics(dpi)
    if not (0 <= x < width and 0 <= y < height):
        return HTCLIENT
    if not maximized and y < edge:
        return HTTOPLEFT if x < 2 * edge else HTTOPRIGHT if x >= width - 2 * edge else HTTOP
    slot = (width - 1 - x) // button
    return CAPTION_BUTTONS[slot] if slot < len(CAPTION_BUTTONS) else HTCAPTION


def icon_images(data: bytes) -> list:
    """[(size, image bytes)] of an .ico file, smallest first; ValueError when it is not one."""
    if len(data) < 6:
        raise ValueError('not an icon')
    reserved, kind, count = struct.unpack_from('<HHH', data)
    if reserved != 0 or kind != 1 or not 0 < count <= 64 or len(data) < 6 + 16 * count:
        raise ValueError('not an icon')
    images = []
    for index in range(count):
        width, height, _, _, _, _, size, offset = struct.unpack_from('<BBBBHHII', data, 6 + 16 * index)
        if width != height or size == 0 or offset < 6 + 16 * count or offset + size > len(data):
            raise ValueError('broken icon entry')
        images.append((width or 256, data[offset:offset + size]))
    return sorted(images, key=lambda item: item[0])


def icon_image(data: bytes, size: int) -> bytes:
    """The image to scale for a size-pixel icon: the smallest one at least that big, else the largest."""
    images = icon_images(data)
    return next((image for side, image in images if side >= size), images[-1][1])


def app_icon() -> bytes:
    return base64.b64decode(''.join(APP_ICON))


class DesktopWindows:
    """Desktop windows this Control Center opened. HTTP can ask whether one is attached and
    hand it the page's theme colours; it never names an HWND and never moves a window."""
    ACTIONS = ('theme',)

    def __init__(self, profiles=None, relaunch=None):
        self.windows = {}
        self.lock = threading.RLock()
        self.profiles = profiles
        self.relaunch = relaunch  # Command line the taskbar uses for a pinned Control Center.
        self.slots = set()
        self.theme = dict(DESKTOP_THEME_DEFAULT)  # The last colours a page sent; new windows start in them.

    def status(self, key):
        with self.lock:
            host = self.windows.get(key) if isinstance(key, str) else None
            attached = bool(host and host.alive())
            return {'attached': attached, 'maximized': bool(attached and host.u.IsZoomed(host.hwnd))}

    def action(self, key, action, colors=None):
        if action not in self.ACTIONS:
            raise VaultError('Unknown desktop window action')
        with self.lock:
            host = self.windows.get(key) if isinstance(key, str) else None
            if not host or not host.alive():
                raise VaultError('Desktop window is not attached')
            theme = desktop_theme(colors)
            host.theme = self.theme = theme
            # Painted on the host's own thread. No HWND is ever accepted from HTTP,
            # and a destroyed/recycled HWND cannot pass alive().
            host.u.PostMessageW(host.hwnd, WM_APP_THEME, 0, 0)
        return dict(self.status(key), result='applied')

    def icon_file(self):
        """The Arkuzo icon as a file, for the taskbar's pinned-button icon (None without a data folder)."""
        if not self.profiles:
            return None
        path = Path(self.profiles) / 'arkuzo.ico'
        data = app_icon()
        try:
            if not path.is_file() or path.read_bytes() != data:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            return path
        except OSError:
            return None

    def open(self, url, browser):
        key = secrets.token_hex(16)
        host = _DesktopHost(self, key)
        with self.lock:
            slot = 0
            while slot in self.slots:
                slot += 1
            self.slots.add(slot)
        host.slot = slot
        threading.Thread(target=host.run, args=(url, browser), daemon=True, name='desktop-window').start()


_WIN32 = {}


def _desktop_win32():
    """user32/gdi32/... with prototypes for the desktop host (64-bit safe), made once."""
    if _WIN32:
        return _WIN32['api']
    from types import SimpleNamespace
    H, P = wintypes.HANDLE, ctypes.c_void_p
    LRESULT = ctypes.c_ssize_t
    WNDPROC = ctypes.WINFUNCTYPE(LRESULT, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)
    ENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    EVENTPROC = ctypes.WINFUNCTYPE(None, H, wintypes.DWORD, wintypes.HWND, wintypes.LONG, wintypes.LONG, wintypes.DWORD, wintypes.DWORD)

    class WNDCLASSEX(ctypes.Structure):
        _fields_ = [('size', wintypes.UINT), ('style', wintypes.UINT), ('proc', WNDPROC), ('extra', ctypes.c_int),
                    ('window_extra', ctypes.c_int), ('instance', wintypes.HINSTANCE), ('icon', wintypes.HICON),
                    ('cursor', H), ('brush', wintypes.HBRUSH), ('menu', wintypes.LPCWSTR),
                    ('name', wintypes.LPCWSTR), ('small_icon', wintypes.HICON)]

    class PAINTSTRUCT(ctypes.Structure):
        _fields_ = [('hdc', wintypes.HDC), ('erase', wintypes.BOOL), ('paint', wintypes.RECT),
                    ('restore', wintypes.BOOL), ('inc_update', wintypes.BOOL), ('reserved', ctypes.c_byte * 32)]

    class TRACKMOUSEEVENT(ctypes.Structure):
        _fields_ = [('size', wintypes.DWORD), ('flags', wintypes.DWORD), ('hwnd', wintypes.HWND), ('hover', wintypes.DWORD)]

    class TRIVERTEX(ctypes.Structure):
        _fields_ = [('x', wintypes.LONG), ('y', wintypes.LONG), ('red', wintypes.USHORT), ('green', wintypes.USHORT),
                    ('blue', wintypes.USHORT), ('alpha', wintypes.USHORT)]

    class GRADIENT_RECT(ctypes.Structure):
        _fields_ = [('upper_left', wintypes.ULONG), ('lower_right', wintypes.ULONG)]

    class MINMAXINFO(ctypes.Structure):
        _fields_ = [(name, wintypes.POINT) for name in ('reserved', 'size', 'position', 'minimum', 'maximum')]

    class GUID(ctypes.Structure):
        _fields_ = [('data', ctypes.c_byte * 16)]

    class PROPERTYKEY(ctypes.Structure):
        _fields_ = [('fmtid', GUID), ('pid', wintypes.DWORD)]

    class PROPVARIANT(ctypes.Structure):
        _fields_ = [('vt', wintypes.USHORT), ('r1', wintypes.USHORT), ('r2', wintypes.USHORT), ('r3', wintypes.USHORT),
                    ('value', P), ('extra', P)]

    def bind(dll, table):
        for name, (args, result) in table.items():
            fn = getattr(dll, name)
            fn.argtypes, fn.restype = args, result
        return dll

    u = bind(ctypes.WinDLL('user32', use_last_error=True), {
        'DefWindowProcW': ([wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM], LRESULT),
        'CreateWindowExW': ([wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_int, ctypes.c_int,
                             ctypes.c_int, ctypes.c_int, wintypes.HWND, wintypes.HMENU, wintypes.HINSTANCE, P], wintypes.HWND),
        'SetParent': ([wintypes.HWND, wintypes.HWND], wintypes.HWND),
        'GetParent': ([wintypes.HWND], wintypes.HWND),
        'GetWindowLongW': ([wintypes.HWND, ctypes.c_int], ctypes.c_long),
        'SetWindowLongW': ([wintypes.HWND, ctypes.c_int, ctypes.c_long], ctypes.c_long),
        'MoveWindow': ([wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.BOOL], wintypes.BOOL),
        'SetWindowPos': ([wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT], wintypes.BOOL),
        'GetWindowRect': ([wintypes.HWND, ctypes.POINTER(wintypes.RECT)], wintypes.BOOL),
        'GetClientRect': ([wintypes.HWND, ctypes.POINTER(wintypes.RECT)], wintypes.BOOL),
        'ScreenToClient': ([wintypes.HWND, ctypes.POINTER(wintypes.POINT)], wintypes.BOOL),
        'FillRect': ([wintypes.HDC, ctypes.POINTER(wintypes.RECT), wintypes.HBRUSH], ctypes.c_int),
        'SetWindowRgn': ([wintypes.HWND, wintypes.HRGN, wintypes.BOOL], ctypes.c_int),
        'PostMessageW': ([wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM], wintypes.BOOL),
        'SendMessageW': ([wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM], LRESULT),
        'SendMessageTimeoutW': ([wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM, wintypes.UINT, wintypes.UINT,
                                 ctypes.POINTER(ctypes.c_size_t)], LRESULT),
        'ShowWindow': ([wintypes.HWND, ctypes.c_int], wintypes.BOOL),
        'IsWindow': ([wintypes.HWND], wintypes.BOOL),
        'IsZoomed': ([wintypes.HWND], wintypes.BOOL),
        'IsIconic': ([wintypes.HWND], wintypes.BOOL),
        'DestroyWindow': ([wintypes.HWND], wintypes.BOOL),
        'GetClassNameW': ([wintypes.HWND, wintypes.LPWSTR, ctypes.c_int], ctypes.c_int),
        'EnumChildWindows': ([wintypes.HWND, ENUMPROC, wintypes.LPARAM], wintypes.BOOL),
        'RegisterClassExW': ([ctypes.POINTER(WNDCLASSEX)], wintypes.ATOM),
        'UnregisterClassW': ([wintypes.LPCWSTR, wintypes.HINSTANCE], wintypes.BOOL),
        'GetMessageW': ([ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT], ctypes.c_int),
        'TranslateMessage': ([ctypes.POINTER(wintypes.MSG)], wintypes.BOOL),
        'DispatchMessageW': ([ctypes.POINTER(wintypes.MSG)], LRESULT),
        'PostQuitMessage': ([ctypes.c_int], None),
        'GetWindowThreadProcessId': ([wintypes.HWND, ctypes.POINTER(wintypes.DWORD)], wintypes.DWORD),
        'SetFocus': ([wintypes.HWND], wintypes.HWND),
        'SetTimer': ([wintypes.HWND, ctypes.c_size_t, wintypes.UINT, P], ctypes.c_size_t),
        'KillTimer': ([wintypes.HWND, ctypes.c_size_t], wintypes.BOOL),
        'BeginPaint': ([wintypes.HWND, ctypes.POINTER(PAINTSTRUCT)], wintypes.HDC),
        'EndPaint': ([wintypes.HWND, ctypes.POINTER(PAINTSTRUCT)], wintypes.BOOL),
        'InvalidateRect': ([wintypes.HWND, ctypes.POINTER(wintypes.RECT), wintypes.BOOL], wintypes.BOOL),
        'DrawTextW': ([wintypes.HDC, wintypes.LPCWSTR, ctypes.c_int, ctypes.POINTER(wintypes.RECT), wintypes.UINT], ctypes.c_int),
        'DrawIconEx': ([wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.HICON, ctypes.c_int, ctypes.c_int, wintypes.UINT,
                        wintypes.HBRUSH, wintypes.UINT], wintypes.BOOL),
        'CreateIconFromResourceEx': ([P, wintypes.DWORD, wintypes.BOOL, wintypes.DWORD, ctypes.c_int, ctypes.c_int, wintypes.UINT],
                                     wintypes.HICON),
        'DestroyIcon': ([wintypes.HICON], wintypes.BOOL),
        'LoadCursorW': ([wintypes.HINSTANCE, P], H),
        'TrackMouseEvent': ([ctypes.POINTER(TRACKMOUSEEVENT)], wintypes.BOOL),
        'GetDpiForWindow': ([wintypes.HWND], wintypes.UINT),
        'GetDpiForSystem': ([], wintypes.UINT),
        'GetSystemMetricsForDpi': ([ctypes.c_int, wintypes.UINT], ctypes.c_int),
        'SetThreadDpiAwarenessContext': ([P], P),
        'ClientToScreen': ([wintypes.HWND, ctypes.POINTER(wintypes.POINT)], wintypes.BOOL),
        'GetSystemMenu': ([wintypes.HWND, wintypes.BOOL], wintypes.HMENU),
        'EnableMenuItem': ([wintypes.HMENU, wintypes.UINT, wintypes.UINT], wintypes.BOOL),
        'TrackPopupMenu': ([wintypes.HMENU, wintypes.UINT, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.HWND, P], wintypes.BOOL),
        'SetWinEventHook': ([wintypes.DWORD, wintypes.DWORD, wintypes.HMODULE, EVENTPROC, wintypes.DWORD, wintypes.DWORD,
                             wintypes.DWORD], H),
        'UnhookWinEvent': ([H], wintypes.BOOL),
        'GetForegroundWindow': ([], wintypes.HWND),
        'GetAncestor': ([wintypes.HWND, wintypes.UINT], wintypes.HWND),
        'SetForegroundWindow': ([wintypes.HWND], wintypes.BOOL),
        'GetAsyncKeyState': ([ctypes.c_int], ctypes.c_short),
    })
    g = bind(ctypes.WinDLL('gdi32', use_last_error=True), {
        'CreateSolidBrush': ([wintypes.DWORD], wintypes.HBRUSH),
        'DeleteObject': ([H], wintypes.BOOL),
        'CreateRectRgn': ([ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int], wintypes.HRGN),
        'CreateCompatibleDC': ([wintypes.HDC], wintypes.HDC),
        'CreateCompatibleBitmap': ([wintypes.HDC, ctypes.c_int, ctypes.c_int], wintypes.HBITMAP),
        'SelectObject': ([wintypes.HDC, H], H),
        'BitBlt': ([wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.HDC, ctypes.c_int,
                    ctypes.c_int, wintypes.DWORD], wintypes.BOOL),
        'DeleteDC': ([wintypes.HDC], wintypes.BOOL),
        'SetBkMode': ([wintypes.HDC, ctypes.c_int], ctypes.c_int),
        'SetTextColor': ([wintypes.HDC, wintypes.DWORD], wintypes.DWORD),
        'CreateFontW': ([ctypes.c_int] * 5 + [wintypes.DWORD] * 8 + [wintypes.LPCWSTR], wintypes.HFONT),
        'GetTextFaceW': ([wintypes.HDC, ctypes.c_int, wintypes.LPWSTR], ctypes.c_int),
    })
    msimg = bind(ctypes.WinDLL('msimg32'), {
        'GradientFill': ([wintypes.HDC, ctypes.POINTER(TRIVERTEX), wintypes.ULONG, P, wintypes.ULONG, wintypes.ULONG], wintypes.BOOL),
    })
    shell = bind(ctypes.WinDLL('shell32'), {
        'SHGetPropertyStoreForWindow': ([wintypes.HWND, ctypes.POINTER(GUID), ctypes.POINTER(P)], ctypes.c_long),
    })
    ole = bind(ctypes.WinDLL('ole32'), {
        'CoInitializeEx': ([P, wintypes.DWORD], ctypes.c_long),
        'CoUninitialize': ([], None),
    })
    dwm = bind(ctypes.WinDLL('dwmapi'), {
        'DwmSetWindowAttribute': ([wintypes.HWND, wintypes.DWORD, P, wintypes.DWORD], ctypes.c_long),
    })
    kernel = bind(ctypes.WinDLL('kernel32', use_last_error=True), {
        'GetModuleHandleW': ([wintypes.LPCWSTR], wintypes.HMODULE),
    })
    api = SimpleNamespace(u=u, g=g, msimg=msimg, shell=shell, ole=ole, dwm=dwm, kernel=kernel, WNDPROC=WNDPROC,
                          ENUMPROC=ENUMPROC, EVENTPROC=EVENTPROC, WNDCLASSEX=WNDCLASSEX, PAINTSTRUCT=PAINTSTRUCT, TRACKMOUSEEVENT=TRACKMOUSEEVENT,
                          TRIVERTEX=TRIVERTEX, GRADIENT_RECT=GRADIENT_RECT, MINMAXINFO=MINMAXINFO, GUID=GUID,
                          PROPERTYKEY=PROPERTYKEY, PROPVARIANT=PROPVARIANT)
    _WIN32['api'] = api
    return api


def _guid(api, text: str):
    import uuid
    return api.GUID.from_buffer_copy(uuid.UUID(text).bytes_le)


_AUMID_KEYS = '{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}'  # PKEY_AppUserModel_* (propkey.h)
_IID_PROPERTY_STORE = '{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}'


def window_identity(hwnd, values: dict) -> bool:
    """Set (str) or clear (None) PKEY_AppUserModel_<pid> properties of a window:
    5 ID, 2 RelaunchCommand, 3 RelaunchIconResource, 4 RelaunchDisplayNameResource."""
    api = _desktop_win32()
    store = ctypes.c_void_p()
    if api.shell.SHGetPropertyStoreForWindow(hwnd, ctypes.byref(_guid(api, _IID_PROPERTY_STORE)), ctypes.byref(store)) < 0 or not store:
        return False
    table = ctypes.cast(store, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p)))[0]
    set_value = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.POINTER(api.PROPERTYKEY),
                                   ctypes.POINTER(api.PROPVARIANT))(table[6])
    commit = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p)(table[7])
    release = ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)(table[2])
    ok = True
    try:
        for pid, value in values.items():
            variant = api.PROPVARIANT()
            text = ctypes.create_unicode_buffer(value) if value is not None else None
            if text is not None:
                variant.vt, variant.value = 31, ctypes.cast(text, ctypes.c_void_p)  # VT_LPWSTR (copied by SetValue)
            key = api.PROPERTYKEY(_guid(api, _AUMID_KEYS), pid)
            ok = set_value(store, ctypes.byref(key), ctypes.byref(variant)) >= 0 and ok
        ok = commit(store) >= 0 and ok
    finally:
        release(store)
    return ok


class _DesktopHost:
    def __init__(self, manager, key):
        self.manager, self.key = manager, key
        self.hwnd = self.child = 0
        self.attached = False
        self.proc = None
        self.u = None
        self.closing = False
        self.theme = dict(manager.theme)
        self.hover = self.pressed = 0
        self.active = True
        self.tracking = False

    def alive(self):
        if not (self.attached and self.hwnd and self.u.IsWindow(self.hwnd)
                and self.proc.poll() is None and self.u.IsWindow(self.child)):
            return False
        owner = wintypes.DWORD()
        self.u.GetWindowThreadProcessId(self.child, ctypes.byref(owner))
        return owner.value == self.proc.pid

    def run(self, url, browser):
        profile = str(self.manager.profiles / str(self.slot)) if self.manager.profiles else tempfile.mkdtemp(prefix='arkuzo-desktop-')
        dpi_api = None
        previous_dpi = None
        try:
            Path(profile).mkdir(parents=True, exist_ok=True)
            dpi_api = _desktop_win32().u.SetThreadDpiAwarenessContext
            previous_dpi = dpi_api(ctypes.c_void_p(-4))  # PER_MONITOR_AWARE_V2, like Edge.
            if not previous_dpi:
                raise ctypes.WinError(ctypes.get_last_error())
            self._run(url, browser, profile)
        except (OSError, ValueError, AttributeError):
            # Fail open: until attachment succeeds the page is an ordinary app window.
            if self.proc is None:
                webbrowser.open(url)
        finally:
            self.attached = False
            with self.manager.lock:
                self.manager.windows.pop(self.key, None)
            if self.u and self.hwnd and self.u.IsWindow(self.hwnd):
                self.u.DestroyWindow(self.hwnd)
            if previous_dpi:
                dpi_api(previous_dpi)
            # Never terminate a browser: WM_CLOSE lets it flush its profile.
            if self.proc:
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    # A fallback ordinary browser may still be open. Its slot
                    # remains reserved until that exact browser exits.
                    self.proc.wait()
            if not self.manager.profiles:
                shutil.rmtree(profile, ignore_errors=True)
            with self.manager.lock:
                self.manager.slots.discard(self.slot)

    def _run(self, url, browser, profile):
        api = _desktop_win32()
        u, g = self.u, self.g = api.u, api.g
        instance = api.kernel.GetModuleHandleW(None)
        self.offset = None
        resources = {}  # dpi -> fonts and icons, all freed when the window is gone
        icon_data = app_icon()

        def scaled(n, dpi):
            return max(1, (n * dpi + 48) // 96)

        def make_icon(size):
            image = icon_image(icon_data, size)
            buffer = ctypes.create_string_buffer(image, len(image))
            return u.CreateIconFromResourceEx(buffer, len(image), True, 0x00030000, size, size, 0)

        def resources_for(dpi):
            if dpi not in resources:
                small = u.GetSystemMetricsForDpi(49, dpi) or scaled(16, dpi)  # SM_CXSMICON
                big = u.GetSystemMetricsForDpi(11, dpi) or scaled(32, dpi)  # SM_CXICON
                title = g.CreateFontW(-scaled(12, dpi), 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, 'Segoe UI')
                glyphs = None
                probe = g.CreateCompatibleDC(None)
                for face in ('Segoe Fluent Icons', 'Segoe MDL2 Assets'):
                    font = g.CreateFontW(-scaled(10, dpi), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, face)
                    old = g.SelectObject(probe, font)
                    name = ctypes.create_unicode_buffer(64)
                    g.GetTextFaceW(probe, 64, name)
                    g.SelectObject(probe, old)
                    if name.value.lower() == face.lower():
                        glyphs = font
                        break
                    g.DeleteObject(font)
                g.DeleteDC(probe)
                resources[dpi] = {'small': make_icon(small), 'big': make_icon(big), 'small_size': small,
                                  'title': title, 'glyphs': glyphs}
            return resources[dpi]

        def window_dpi():
            return (u.GetDpiForWindow(self.hwnd) if self.hwnd else 0) or 96

        def apply_icons(dpi):
            found = resources_for(dpi)
            u.SendMessageW(self.hwnd, 0x80, 0, found['small'] or 0)  # WM_SETICON, ICON_SMALL
            u.SendMessageW(self.hwnd, 0x80, 1, found['big'] or 0)  # ICON_BIG

        def apply_dark_frame():
            # Windows 11 draws a thin border around the window; dark themes get the dark one.
            n = int(self.theme['bar'][1:], 16)
            dark = ctypes.c_int(int((n >> 16) * 0.299 + ((n >> 8) & 255) * 0.587 + (n & 255) * 0.114 < 128))
            api.dwm.DwmSetWindowAttribute(self.hwnd, 20, ctypes.byref(dark), ctypes.sizeof(dark))  # DWMWA_USE_IMMERSIVE_DARK_MODE

        def measure():
            """Edge's renderer inset inside its own window: (left, top, right, bottom), or None."""
            bounds = []

            def visit(hwnd, _):
                text = ctypes.create_unicode_buffer(128)
                u.GetClassNameW(hwnd, text, len(text))
                if text.value == 'Chrome_RenderWidgetHostHWND':
                    rect = wintypes.RECT()
                    if u.GetWindowRect(hwnd, ctypes.byref(rect)) and rect.right > rect.left:
                        bounds.append(rect)
                return True
            u.EnumChildWindows(self.child, api.ENUMPROC(visit), 0)
            outer = wintypes.RECT()
            if len(bounds) != 1 or not u.GetWindowRect(self.child, ctypes.byref(outer)):
                return None
            page = bounds[0]
            offset = (page.left - outer.left, page.top - outer.top, outer.right - page.right, outer.bottom - page.bottom)
            return offset if min(offset) >= 0 and offset[1] <= 160 else None

        def layout():
            rect = wintypes.RECT()
            if not (self.child and self.offset) or u.IsIconic(self.hwnd) or not u.GetClientRect(self.hwnd, ctypes.byref(rect)):
                return
            top = caption_metrics(window_dpi())[0]
            x, y, right, bottom = self.offset
            width, height = max(1, rect.right), max(1, rect.bottom - top)
            # The page fills the client area below the strip. Edge keeps its own frame
            # and caption; the window region clips them away (Windows owns the region).
            u.MoveWindow(self.child, -x, top - y, width + x + right, height + y + bottom, True)
            region = g.CreateRectRgn(x, y, x + width, y + height)
            if region and not u.SetWindowRgn(self.child, region, True):
                g.DeleteObject(region)
            self.placed = child_place()

        def child_place():
            """Edge's window rect relative to the host's client origin."""
            rect, origin = wintypes.RECT(), wintypes.POINT(0, 0)
            u.GetWindowRect(self.child, ctypes.byref(rect))
            u.ClientToScreen(self.hwnd, ctypes.byref(origin))
            return (rect.left - origin.x, rect.top - origin.y, rect.right - origin.x, rect.bottom - origin.y)

        def keep_child():
            # Edge's own window menu (Alt+Space inside the page) can move, size, minimize or
            # maximize the embedded window. Hand min/max to the host and put Edge back in place.
            if not (self.child and u.IsWindow(self.child)) or self.closing:
                return
            if u.IsZoomed(self.child) or u.IsIconic(self.child):
                command = 0xF030 if u.IsZoomed(self.child) else 0xF020  # SC_MAXIMIZE / SC_MINIMIZE
                u.ShowWindow(self.child, 9)  # SW_RESTORE
                u.PostMessageW(self.hwnd, 0x112, command, 0)
            if child_place() != self.placed:
                layout()

        def focus_page():
            # Edge runs in another process and its window is not WS_CHILD, so SetFocus cannot
            # reach it: hand it the foreground instead, once no mouse button is held.
            if self.closing or not (self.child and u.IsWindow(self.child)) or u.IsIconic(self.hwnd):
                return
            if u.GetForegroundWindow() != self.hwnd:
                return
            if u.GetAsyncKeyState(0x01) < 0 or u.GetAsyncKeyState(0x02) < 0:  # VK_LBUTTON / VK_RBUTTON
                u.SetTimer(self.hwnd, 3, 100, None)
                return
            u.KillTimer(self.hwnd, 3)
            u.SetForegroundWindow(self.child)

        def system_menu(x, y):
            # The window menu for a right-click on the strip, with Windows' own items and rules.
            menu = u.GetSystemMenu(self.hwnd, False)
            if not menu:
                return
            zoomed, iconic = bool(u.IsZoomed(self.hwnd)), bool(u.IsIconic(self.hwnd))
            for command, enabled in ((0xF120, zoomed or iconic), (0xF010, not zoomed), (0xF000, not zoomed),
                                     (0xF020, not iconic), (0xF030, not zoomed), (0xF060, True)):
                u.EnableMenuItem(menu, command, 0 if enabled else 3)  # MF_BYCOMMAND | MF_GRAYED
            command = u.TrackPopupMenu(menu, 0x102, x, y, 0, self.hwnd, None)  # TPM_RETURNCMD | TPM_RIGHTBUTTON
            if command:
                u.PostMessageW(self.hwnd, 0x112, command, 0)

        def invalidate():
            if self.hwnd:
                u.InvalidateRect(self.hwnd, None, False)

        def fill(dc, left, top, right, bottom, color):
            brush = g.CreateSolidBrush(colorref(color))
            u.FillRect(dc, ctypes.byref(wintypes.RECT(left, top, right, bottom)), brush)
            g.DeleteObject(brush)

        def gradient(dc, width, height, start, end):
            a, b = int(start[1:], 16), int(end[1:], 16)
            vertices = (api.TRIVERTEX * 2)(
                api.TRIVERTEX(0, 0, (a >> 16) << 8, ((a >> 8) & 255) << 8, (a & 255) << 8, 0),
                api.TRIVERTEX(width, height, (b >> 16) << 8, ((b >> 8) & 255) << 8, (b & 255) << 8, 0))
            area = api.GRADIENT_RECT(0, 1)
            if not api.msimg.GradientFill(dc, vertices, 2, ctypes.byref(area), 1, 0):  # GRADIENT_FILL_RECT_H
                fill(dc, 0, 0, width, height, start)

        def text_out(dc, text, font, box, color, flags):
            old = g.SelectObject(dc, font) if font else None
            g.SetBkMode(dc, 1)  # TRANSPARENT
            g.SetTextColor(dc, colorref(color))
            u.DrawTextW(dc, text, -1, ctypes.byref(wintypes.RECT(*box)), flags | 0x20 | 0x4 | 0x800)  # SINGLELINE VCENTER NOPREFIX
            if old:
                g.SelectObject(dc, old)

        def paint(hwnd):
            ps = api.PAINTSTRUCT()
            dc = u.BeginPaint(hwnd, ctypes.byref(ps))
            if not dc:
                return
            try:
                rect = wintypes.RECT()
                u.GetClientRect(hwnd, ctypes.byref(rect))
                dpi = window_dpi()
                found = resources_for(dpi)
                height, button, _ = caption_metrics(dpi)
                width, theme = max(1, rect.right), self.theme
                # Active while the host or the page inside it has the foreground.
                self.active = u.GetAncestor(u.GetForegroundWindow(), 2) == hwnd  # GA_ROOT
                memory = g.CreateCompatibleDC(dc)
                bitmap = g.CreateCompatibleBitmap(dc, width, height)
                previous = g.SelectObject(memory, bitmap)
                try:
                    # Drawn off screen, then copied once: no flicker while resizing.
                    gradient(memory, width, height - 1, theme['bar'], theme['barEnd'])
                    fill(memory, 0, height - 1, width, height, theme['line'])
                    maximized = u.IsZoomed(hwnd)
                    glyphs = {HTMINBUTTON: '', HTMAXBUTTON: '' if maximized else '', HTCLOSE: ''}
                    for slot, code in enumerate(CAPTION_BUTTONS):
                        left = width - (slot + 1) * button
                        lit = self.hover == code
                        down = lit and self.pressed == code
                        background = None
                        if code == HTCLOSE and lit:
                            background = shade(theme['closeHover'], 0.85) if down else theme['closeHover']
                        elif lit:
                            background = theme['pressed'] if down else theme['hover']
                        if background:
                            fill(memory, left, 0, left + button, height - 1, background)
                        color = '#ffffff' if code == HTCLOSE and lit else theme['text'] if self.active or lit else theme['muted']
                        if found['glyphs']:
                            text_out(memory, glyphs[code], found['glyphs'], (left, 0, left + button, height - 1), color, 0x1)  # DT_CENTER
                    pad, size = scaled(10, dpi), found['small_size']
                    if found['small']:
                        u.DrawIconEx(memory, pad, (height - size) // 2, found['small'], size, size, 0, None, 3)  # DI_NORMAL
                    left = pad + size + scaled(8, dpi)
                    text_out(memory, DESKTOP_TITLE, found['title'], (left, 0, max(left, width - 3 * button - pad), height - 1),
                             theme['text'] if self.active else theme['muted'], 0x8000)  # DT_END_ELLIPSIS
                    g.BitBlt(dc, 0, 0, width, height, memory, 0, 0, 0x00CC0020)  # SRCCOPY
                finally:
                    g.SelectObject(memory, previous)
                    g.DeleteObject(bitmap)
                    g.DeleteDC(memory)
                if rect.bottom > height:  # Normally under the page; seen only mid-layout.
                    fill(dc, 0, height, width, rect.bottom, theme['barEnd'])
            finally:
                u.EndPaint(hwnd, ctypes.byref(ps))

        def set_hover(code):
            if code != self.hover:
                self.hover = code
                invalidate()

        def press(code):
            command = {HTMINBUTTON: 0xF020, HTCLOSE: 0xF060}.get(code)  # SC_MINIMIZE, SC_CLOSE
            if code == HTMAXBUTTON:
                command = 0xF120 if u.IsZoomed(self.hwnd) else 0xF030  # SC_RESTORE, SC_MAXIMIZE
            if command:
                u.PostMessageW(self.hwnd, 0x112, command, 0)  # WM_SYSCOMMAND: Windows' own animation and rules

        def wndproc(hwnd, msg, wp, lp):
            if msg == 0x83:  # WM_NCCALCSIZE: keep the invisible side/bottom frames, drop the caption.
                before = wintypes.RECT.from_address(lp)
                left, top = before.left, before.top
                u.DefWindowProcW(hwnd, msg, wp, lp)
                after = wintypes.RECT.from_address(lp)
                # Maximized windows hang their frame off the monitor; keep the strip on screen.
                after.top = top + (after.left - left if u.IsZoomed(hwnd) else 0)
                return 0
            if msg == 0x84:  # WM_NCHITTEST
                hit = u.DefWindowProcW(hwnd, msg, wp, lp)
                if hit != HTCLIENT:
                    return hit  # Windows' own sizing frame on the left, right and bottom.
                point = wintypes.POINT(ctypes.c_short(lp & 0xFFFF).value, ctypes.c_short((lp >> 16) & 0xFFFF).value)
                rect = wintypes.RECT()
                u.ScreenToClient(hwnd, ctypes.byref(point))
                u.GetClientRect(hwnd, ctypes.byref(rect))
                return caption_hit_test(point.x, point.y, rect.right, window_dpi(), bool(u.IsZoomed(hwnd)))
            if msg == 0xA0:  # WM_NCMOUSEMOVE
                set_hover(wp if wp in CAPTION_BUTTONS else 0)
                if not self.tracking:
                    track = api.TRACKMOUSEEVENT(ctypes.sizeof(api.TRACKMOUSEEVENT), 0x12, hwnd, 0)  # TME_LEAVE | TME_NONCLIENT
                    self.tracking = bool(u.TrackMouseEvent(ctypes.byref(track)))
            if msg == 0x2A2:  # WM_NCMOUSELEAVE
                self.tracking = False
                self.pressed = 0
                set_hover(0)
                return 0
            if msg in (0xA1, 0xA3):  # WM_NCLBUTTONDOWN / DBLCLK
                if wp in CAPTION_BUTTONS:
                    # Never DefWindowProc: it would track (and draw) classic caption buttons.
                    self.pressed = wp
                    invalidate()
                    return 0
                self.pressed = 0
            if msg == 0xA2:  # WM_NCLBUTTONUP
                pressed, self.pressed = self.pressed, 0
                if wp in CAPTION_BUTTONS:
                    invalidate()
                    if pressed == wp:
                        press(wp)
                    return 0
            if msg in (0xA4, 0xA5, 0xA6) and wp in CAPTION_BUTTONS:  # right button on a caption button
                return 0
            if msg == 0xA5 and wp == HTCAPTION:  # WM_NCRBUTTONUP on the strip: the window menu
                system_menu(ctypes.c_short(lp & 0xFFFF).value, ctypes.c_short((lp >> 16) & 0xFFFF).value)
                return 0
            if msg == WM_APP_CHILD:
                keep_child()
                return 0
            if msg == 0x86:  # WM_NCACTIVATE
                invalidate()
            if msg == 0xF:  # WM_PAINT
                paint(hwnd)
                return 0
            if msg == 0x14:  # WM_ERASEBKGND: WM_PAINT draws everything.
                return 1
            if msg == 0x317:  # WM_PRINT: no classic non-client frame in previews.
                return u.DefWindowProcW(hwnd, msg, wp, lp & ~2)
            if msg == 6 and wp & 0xFFFF == 1:  # WM_ACTIVATE / WA_ACTIVE: opened, taskbar, Alt+Tab
                # Keys go to the page. After a click on the strip (WA_CLICKACTIVE) the host keeps
                # the foreground, so Win+arrow keys and Alt+Space act on the whole window.
                u.PostMessageW(hwnd, WM_APP_FOCUS, 0, 0)
            if msg == WM_APP_FOCUS or (msg == 0x113 and wp == 3):
                focus_page()
                return 0
            if msg == 0x24:  # WM_GETMINMAXINFO: a minimum size; Windows places maximized windows itself.
                limits = ctypes.cast(lp, ctypes.POINTER(api.MINMAXINFO)).contents
                dpi = window_dpi()
                limits.minimum.x, limits.minimum.y = scaled(640, dpi), scaled(420, dpi)
                return 0
            if msg == 0x2E0:  # WM_DPICHANGED: per-monitor v2 windows resize themselves.
                rect = wintypes.RECT.from_address(lp)
                u.SetWindowPos(hwnd, None, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, 0x14)
                apply_icons((wp >> 16) & 0xFFFF)
                self.remeasure = 6
                u.SetTimer(hwnd, 2, 250, None)  # Edge relays out at the new DPI shortly after.
                invalidate()
                return 0
            if msg == 0x113 and wp == 2:  # WM_TIMER: re-measure Edge's insets after a DPI change
                offset = measure()
                if offset and offset != self.offset:
                    self.offset = offset
                    layout()
                self.remeasure -= 1
                if self.remeasure <= 0:
                    u.KillTimer(hwnd, 2)
                return 0
            if msg == 5:  # WM_SIZE
                if wp == 1:  # SIZE_MINIMIZED
                    self.hover = self.pressed = 0
                layout()
                invalidate()
                return 0
            if msg == WM_APP_THEME:
                apply_dark_frame()
                invalidate()
                return 0
            if msg == 0x10:  # WM_CLOSE: close Edge politely; the timer ends the host once it is gone.
                self.attached = False
                self.closing = True
                u.ShowWindow(hwnd, 0)
                if self.child:
                    u.PostMessageW(self.child, 0x10, 0, 0)
                return 0
            if msg == 2:  # WM_DESTROY
                window_identity(hwnd, {2: None, 3: None, 4: None, 5: None})
                u.PostQuitMessage(0)
                return 0
            return u.DefWindowProcW(hwnd, msg, wp, lp)

        def child_moved(hook, event, hwnd, kind, item, thread, when):
            if not self.hwnd:
                return
            if event == 3:  # EVENT_SYSTEM_FOREGROUND: the title dims and lights with the page's focus too
                invalidate()
            elif hwnd == self.child and kind == 0:  # OBJID_WINDOW
                u.PostMessageW(self.hwnd, WM_APP_CHILD, 0, 0)

        self.callback = api.WNDPROC(wndproc)
        self.child_callback = api.EVENTPROC(child_moved)
        self.remeasure = 0
        self.placed = None
        hook = foreground_hook = None
        name = 'ArkuzoDesktop_' + self.key
        initial = resources_for(u.GetDpiForSystem() or 96)
        wc = api.WNDCLASSEX(ctypes.sizeof(api.WNDCLASSEX), 0, self.callback, 0, 0, instance, initial['big'],
                            u.LoadCursorW(None, ctypes.c_void_p(32512)), None, None, name, initial['small'])  # IDC_ARROW
        com = -1
        try:
            if not u.RegisterClassExW(ctypes.byref(wc)):
                raise ctypes.WinError(ctypes.get_last_error())
            com = api.ole.CoInitializeEx(None, 2)  # COINIT_APARTMENTTHREADED, for the window property store
            separator = '&' if '?' in url else '?'
            launch = url + separator + urllib.parse.urlencode({'desktop': self.key})
            self.proc = subprocess.Popen([str(browser), '--user-data-dir=' + profile, '--no-first-run',
                '--no-default-browser-check', EDGE_QUIET, '--app=' + launch, '--window-size=1440,920'])
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and self.proc.poll() is None:
                matches = [h for h, title in WINDOWS.windows(self.proc.pid) if self.key in title]
                if len(matches) == 1:
                    self.child = matches[0]
                    break
                time.sleep(.1)
            if not self.child:
                return
            # Renderer bounds expose the real page origin, including Chromium's
            # custom caption. Measure before reparenting and preserve that inset.
            self.offset = measure()
            if not self.offset:
                return
            outer = wintypes.RECT()
            u.GetWindowRect(self.child, ctypes.byref(outer))
            self.hwnd = u.CreateWindowExW(0, name, DESKTOP_TITLE, 0x02CF0000,  # WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN
                outer.left, outer.top, outer.right - outer.left, outer.bottom - outer.top,
                None, None, instance, None)
            if not self.hwnd:
                raise ctypes.WinError(ctypes.get_last_error())
            u.SetWindowPos(self.hwnd, None, 0, 0, 0, 0, 0x27)  # SWP_FRAMECHANGED|NOZORDER|NOSIZE|NOMOVE: apply WM_NCCALCSIZE
            apply_icons(window_dpi())
            apply_dark_frame()
            # The taskbar groups and labels windows by AppUserModelID: the Arkuzo one, not Python's.
            icon_file = self.manager.icon_file()
            identity = {5: DESKTOP_APP_ID}
            if self.manager.relaunch and icon_file:
                identity.update({2: self.manager.relaunch, 3: str(icon_file) + ',0', 4: DESKTOP_TITLE})
            window_identity(self.hwnd, identity)
            # Keep the browser's styles: converting it to WS_CHILD changes its
            # custom frame metrics. SetParent alone plus clipping preserves them.
            ctypes.set_last_error(0)
            previous = u.SetParent(self.child, self.hwnd)
            if not previous and ctypes.get_last_error():
                raise ctypes.WinError(ctypes.get_last_error())
            extended = u.GetWindowLongW(self.child, -20)  # GWL_EXSTYLE
            if extended & 0x40000:  # WS_EX_APPWINDOW: never a taskbar button of its own
                u.SetWindowLongW(self.child, -20, extended & ~0x40000)
            layout()
            # Out of context: delivered through this thread's message loop.
            hook = u.SetWinEventHook(0x800B, 0x800B, None, self.child_callback, self.proc.pid, 0, 0)  # EVENT_OBJECT_LOCATIONCHANGE
            foreground_hook = u.SetWinEventHook(3, 3, None, self.child_callback, 0, 0, 0)  # EVENT_SYSTEM_FOREGROUND
            u.ShowWindow(self.hwnd, 5)
            self.attached = True
            with self.manager.lock:
                self.manager.windows[self.key] = self
            msg = wintypes.MSG()
            u.SetTimer(self.hwnd, 1, 500, None)
            # Dispatch on this thread, including Windows' move and size loops.
            while u.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
                if msg.message == 0x113 and msg.wParam == 1 and (not u.IsWindow(self.child) or self.proc.poll() is not None):
                    u.DestroyWindow(self.hwnd)
                u.TranslateMessage(ctypes.byref(msg))
                u.DispatchMessageW(ctypes.byref(msg))
        finally:
            for handle in (hook, foreground_hook):
                if handle:
                    u.UnhookWinEvent(handle)
            if self.hwnd and u.IsWindow(self.hwnd):
                u.DestroyWindow(self.hwnd)
            u.UnregisterClassW(name, instance)
            for found in resources.values():
                for handle in (found['small'], found['big']):
                    if handle:
                        u.DestroyIcon(handle)
                for handle in (found['title'], found['glyphs']):
                    if handle:
                        g.DeleteObject(handle)
            if com >= 0:
                api.ole.CoUninitialize()


def desktop_relaunch_command(data: Path, port: int) -> str:
    """How the taskbar starts a pinned Control Center again: this script, this data folder."""
    exe = Path(sys.executable)
    windowless = exe.with_name('pythonw.exe')
    args = [str(windowless if windowless.is_file() else exe), str(Path(__file__).resolve()), '--data', str(data)]
    if port != DEFAULT_PORT:
        args += ['--port', str(port)]
    return subprocess.list2cmdline(args)


def set_process_app_id():
    """Group this process's windows under the Control Center's AppUserModelID, never Python's."""
    if os.name == 'nt':
        try:
            ctypes.WinDLL('shell32').SetCurrentProcessExplicitAppUserModelID(ctypes.c_wchar_p(DESKTOP_APP_ID))
        except (OSError, AttributeError):
            pass


# The Control Center's logo as a multi-size icon (16-256 px) for the desktop window
# and the taskbar; embedded so the Control Center ZIP stays two files.
# BEGIN GENERATED app-icon: written by build/bundle.ps1 from src/saver/assets/arkuzo-logo-512.png. Replace the logo, then run build/bundle.ps1.
APP_ICON = (
    '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'
)
# END GENERATED app-icon


def desktop_open(app):
    open_window(f'http://127.0.0.1:{app.port}/', app.desktop)
    return {'result': 'opening'}


def open_window(url: str, desktop=None):
    browser = find_app_browser()
    if browser and desktop is not None and os.name == 'nt':
        desktop.open(url, browser)
    elif browser:
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
    set_process_app_id()  # Before any window of this process exists.
    data = (args.data or default_data_directory()).resolve()
    data.mkdir(parents=True, exist_ok=True)
    url = f'http://127.0.0.1:{args.port}/'
    handover = None
    if already_running(args.port):
        handover = take_over(args.port, data)
        if handover is None:  # Same or newer version, or another data folder: just show it.
            if not args.background:
                try:
                    page = _fetch(args.port, '/').decode('utf-8', 'replace')
                    token = re.search(r"const TOKEN = '([A-Za-z0-9_\-]+)'", page)
                    if not token:
                        raise ValueError('No desktop token')
                    _fetch(args.port, '/api/desktop-window/open', body=b'{}',
                           headers={'X-Arkuzo-Token': token.group(1), 'Content-Type': 'application/json'})
                except (OSError, ValueError):
                    open_window(url)  # An older backend retains ordinary browser chrome.
            return 0
    app = App(data, args.port)
    app.roblox.start_follower()
    if handover:
        # Keep the saver as it was: running stays running (now on this engine), stopped stays stopped.
        app.supervisor.initial_start = handover['saverWasRunning']
        before = f"v{handover['from']}" if handover['from'] else 'an earlier version'
        app.feed.add({'t': time.time(), 'kind': 'SUPERVISOR', 'category': 'saver', 'level': 'info',
                      'text': f'Control Center updated from {before} to v{RUNTIME_VERSION}'})
    # Windows of the replaced Control Center reload onto this one by themselves.
    if not args.background and not (handover and handover['windowsOpen']):
        threading.Timer(0.6, open_window, args=(url, app.desktop)).start()
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
