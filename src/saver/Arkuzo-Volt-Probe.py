"""Read-only, secret-free Volt recovery capability check for ArkuzoSaver."""
import json
from contextlib import closing
import os
from pathlib import Path
import argparse
import re
import math
import sqlite3


_UUID = re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
_GLOBAL_CHECK = object()


def read_recovery_status(path, tracker_id=_GLOBAL_CHECK):
    try:
        with closing(sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True, timeout=0.5)) as db:
            row = db.execute('SELECT value FROM state_documents WHERE name=?', ('accounts',)).fetchone()
            if not row:
                return {'safeToRecycle': False, 'reason': 'No account-manager state'}
            document = json.loads(row[0])
        settings = document.get('settings') or {}
        accounts = document.get('accounts') or []
        seen_trackers = set()
        for account in accounts:
            tracker = account.get('browserTrackerId')
            if tracker is None:
                continue
            if type(tracker) not in (str, int) or re.fullmatch(r'[0-9]+', str(tracker)) is None or str(tracker) in seen_trackers:
                raise ValueError('ambiguous tracker mapping')
            seen_trackers.add(str(tracker))
        # Deliberately do not expose cookies, tokens, names, server links or IDs.
        safe = bool(accounts) and settings.get('autoRelaunchEnabled') is True and any(
            a.get('autoRelaunch') is True and a.get('cookieStatus') == 'alive' for a in accounts
        )
        if tracker_id is not _GLOBAL_CHECK:
            valid = isinstance(tracker_id, str) and re.fullmatch(r'[0-9]+', tracker_id) is not None
            matches = [a for a in accounts if valid and type(a.get('browserTrackerId')) in (str, int)
                       and str(a['browserTrackerId']) == tracker_id]
            target_ready = len(matches) == 1 and matches[0].get('autoRelaunch') is True and matches[0].get('cookieStatus') == 'alive'
            account_id = matches[0].get('id') if len(matches) == 1 else None
            if not isinstance(account_id, str) or not _UUID.fullmatch(account_id):
                account_id = None
            return {'safeToRecycle': safe and target_ready, 'targetReady': target_ready, 'accountId': account_id,
                    'reason': 'Exact target relaunch ready' if safe and target_ready else 'Target mapping or relaunch not ready',
                    'accountCount': len(accounts), 'matchedAccountCount': len(matches)}
        return {'safeToRecycle': safe, 'reason': 'Volt auto-relaunch ready' if safe else 'Auto-relaunch or account session not ready',
                'accountCount': len(accounts), 'relaunchDelayMs': settings.get('relaunchDelayMs')}
    except (OSError, ValueError, sqlite3.Error, TypeError, AttributeError):
        return {'safeToRecycle': False, 'reason': 'Volt state unavailable'}


def read_account_inventory(path):
    """Return only the fields needed to bind an account-aware UI action."""
    try:
        with closing(sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True, timeout=0.5)) as db:
            row = db.execute('SELECT value FROM state_documents WHERE name=?', ('accounts',)).fetchone()
            if not row:
                raise ValueError('missing')
            document = json.loads(row[0])
        settings = document.get('settings') or {}
        accounts = document.get('accounts') or []
        inventory = []
        seen = {key: set() for key in ('id', 'username', 'displayName', 'browserTrackerId')}
        for a in accounts:
            account_id = a.get('id')
            tracker = a.get('browserTrackerId')
            last_launch = a.get('lastLaunchAtMs')
            if last_launch is None:
                last_launch = 0
            if not (isinstance(account_id, str) and _UUID.fullmatch(account_id)
                    and (tracker is None or (type(tracker) in (str, int) and re.fullmatch(r'[0-9]+', str(tracker))))
                    and isinstance(a.get('username'), str) and a['username'].strip()
                    and isinstance(a.get('displayName'), str) and a['displayName'].strip()
                    and type(last_launch) in (int, float) and math.isfinite(last_launch) and last_launch >= 0):
                raise ValueError('invalid inventory')
            for key in seen:
                value = a.get(key)
                if key == 'browserTrackerId' and value is None:
                    continue
                value = str(value).casefold()
                if re.search(r'[\r\n\x00]', value) or value in seen[key]:
                    raise ValueError('ambiguous inventory')
                seen[key].add(value)
            cookie_status = a.get('cookieStatus')
            if cookie_status not in ('alive', 'dead'):
                cookie_status = 'unknown'
            inventory.append({'accountId': account_id, 'username': a['username'],
                              'displayName': a['displayName'], 'trackerId': str(tracker) if tracker is not None else None,
                              'autoRelaunch': a.get('autoRelaunch') is True, 'cookieAlive': cookie_status == 'alive',
                              'cookieStatus': cookie_status, 'lastLaunchAtMs': last_launch})
        ready = bool(accounts) and settings.get('autoRelaunchEnabled') is True and any(
            a['autoRelaunch'] and a['cookieAlive'] and a['trackerId'] is not None and a['lastLaunchAtMs'] > 0 for a in inventory)
        return {'available': True, 'safeToRecycle': ready, 'autoEnabled': settings.get('autoRelaunchEnabled') is True,
                'relaunchDelayMs': settings.get('relaunchDelayMs'), 'accounts': inventory, 'reason': 'Inventory read'}
    except (OSError, ValueError, sqlite3.Error, TypeError, AttributeError):
        return {'available': False, 'safeToRecycle': False, 'autoEnabled': False,
                'relaunchDelayMs': None, 'accounts': [], 'reason': 'Volt inventory unavailable'}


def read_user_id_map(path):
    try:
        with closing(sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True, timeout=0.5)) as db:
            row = db.execute('SELECT value FROM state_documents WHERE name=?', ('accounts',)).fetchone()
            if not row:
                return {}
            document = json.loads(row[0])
        mapping = {}
        for a in document.get('accounts') or []:
            uid = a.get('userId')
            uname = a.get('username')
            if uid and uname:
                mapping[str(uid)] = str(uname)
        return mapping
    except Exception:
        return {}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--tracker-id', default=_GLOBAL_CHECK)
    mode.add_argument('--inventory', action='store_true')
    mode.add_argument('--user-id')
    args = parser.parse_args()
    path = Path(os.environ.get('LOCALAPPDATA', '')) / 'Volt' / 'state.db'
    if args.user_id:
        u_map = read_user_id_map(path)
        uname = u_map.get(str(args.user_id))
        result = {'found': bool(uname), 'username': uname}
    elif args.inventory:
        result = read_account_inventory(path)
    else:
        result = read_recovery_status(path, tracker_id=args.tracker_id)
    print(json.dumps(result, separators=(',', ':'), allow_nan=False))
