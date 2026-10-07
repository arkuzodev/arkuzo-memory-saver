"""Verify public release assets and the real compiled updater without starting the saver."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = 'arkuzodev/arkuzo-memory-saver'
VERSION = 'v1.0.0'
NAMES = ['Run.exe', 'ArkuzoMemorySaver-runtime.zip', 'ArkuzoMemorySaver-runtime.sha256', 'ArkuzoMemorySaver-v1.0.0-win-x64.zip', 'SHA256SUMS.txt']

def run(command, expected=0, timeout=120):
    result = subprocess.run(command, capture_output=True, text=True, errors='replace', timeout=timeout)
    print(result.stdout.strip())
    if result.stderr.strip():
        print(result.stderr.strip())
    if result.returncode != expected:
        raise RuntimeError(f'Expected exit {expected}, received {result.returncode}')
    return result.stdout

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    metadata = json.loads(run(['gh', 'api', f'repos/{REPO}/releases/tags/{VERSION}']))
    require(metadata['tag_name'] == VERSION and not metadata['draft'] and not metadata['prerelease'], 'Release must be the requested stable published version')
    require(sorted(a['name'] for a in metadata['assets']) == sorted(NAMES), 'Published assets differ from the required exact set')
    scratch = Path(os.environ.get('TMPDIR') or Path.home() / 'AppData' / 'Local' / 'hermes' / 'cache' / 'scratch')
    with tempfile.TemporaryDirectory(prefix='arkuzo-release-smoke-', dir=scratch) as tmp:
        base = Path(tmp)
        downloads = base / 'downloads'
        downloads.mkdir()
        run(['gh', 'release', 'download', VERSION, '--repo', REPO, '--dir', str(downloads)])
        for asset in metadata['assets']:
            path = downloads / asset['name']
            require(path.stat().st_size == asset['size'], 'Asset size mismatch: ' + asset['name'])
            require(path.read_bytes() == (ROOT / 'dist' / asset['name']).read_bytes(), 'Asset byte mismatch: ' + asset['name'])
            if asset.get('digest'):
                require(asset['digest'] == 'sha256:' + digest(path), 'GitHub asset digest mismatch: ' + asset['name'])
        print('PASS all five published assets match local release bytes and GitHub digests')
        install = base / 'Fresh portable ü folder'
        install.mkdir()
        exe = install / 'Run.exe'
        exe.write_bytes((downloads / 'Run.exe').read_bytes())
        run([str(exe), '--verify-only'])
        config = install / 'data' / 'config.json'
        saved = json.loads(config.read_text(encoding='utf-8-sig'))
        saved['settings']['target_ram_mb'] = 777
        saved['release_verify_keep_me'] = 'unchanged-after-update'
        custom = json.dumps(saved, indent=3).encode('utf-8') + b'\n  '
        config.write_bytes(custom)
        run([str(exe), '--verify-only'])
        require(config.read_bytes() == custom, 'Existing user config was changed')
        run([str(exe), '--offline', '--verify-only'])
        require(config.read_bytes() == custom, 'Existing user config was changed')
        pointer = json.loads((install / 'app' / 'current.json').read_text())
        require(pointer['Version'] == VERSION, 'Updater installed unexpected version')
        engine = install / 'app' / 'versions' / VERSION / 'Arkuzo-Memory-Saver.ps1'
        engine.write_bytes(engine.read_bytes() + b'\n# tamper-detection-test\n')
        run([str(exe), '--offline', '--verify-only'], expected=1)
        require(config.read_bytes() == custom, 'Existing user config was changed')
        print('PASS live first install, repeat online config preservation, offline validation, tamper rejection; saver never launched')

if __name__ == '__main__':
    main()
