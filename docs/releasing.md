# Maintainer release checklist

Use Windows x64 with PowerShell 5.1, the .NET 10 SDK, Python 3, Git, and authenticated GitHub CLI. End users do not need the .NET SDK.

## Validate and package

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build/test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File build/package.ps1 -Version v1.0.1
```

The package script rebuilds the self-contained launcher and creates, under ignored `dist/`:

| Asset | Purpose |
| --- | --- |
| `ArkuzoMemorySaver.exe` | Single-file Windows x64 launcher |
| `ArkuzoMemorySaver-v1.0.2-win-x64.zip` | End-user archive containing only `ArkuzoMemorySaver.exe` |
| `ArkuzoMemorySaver-runtime.zip` | Exactly three runtime programs and `defaults.json` |
| `ArkuzoMemorySaver-runtime.sha256` | Updater checksum for the runtime ZIP |
| `ArkuzoMemorySaver-controlcenter.zip` | Control Center add-on: exactly `Arkuzo-Control-Center.py` and `Arkuzo-Control-Center.html` |
| `ArkuzoMemorySaver-controlcenter.sha256` | Updater checksum for the Control Center ZIP |
| `SHA256SUMS.txt` | Checksums for the executable and ZIP downloads |

### Control Center add-on and launcher compatibility

Launchers already in the field accept a runtime ZIP only when it holds exactly the four files listed in `RuntimePackage.Files`, and they ignore release assets they do not know. So:

- **Never add files to `ArkuzoMemorySaver-runtime.zip`.** A fifth file makes every existing install fail its update. `package.ps1` refuses to build one.
- The Control Center ships as its own pair, `ArkuzoMemorySaver-controlcenter.zip` + `.sha256`. Launchers that predate it never request it and keep running the console saver; newer launchers download it, verify its checksum and GitHub digest, and apply the same strict-ZIP rules (exact names, no traversal, no extras, no symlinks, 16 MB limit).
- Publish both add-on assets or neither. A release with only one of them is rejected, and a corrupt add-on blocks the whole update before anything is written. A release without them still installs; the launcher then uses the console saver.
- The add-on installs to `app/control-center/<version>/` with its own pointer, `app/control-center.json`. That folder holds the two add-on files plus verified copies of the four engine files, because the Control Center starts the engine that sits next to it. `app/current.json` and `app/versions/<version>/` keep the old four-file layout, so an older launcher pointed at the same folder still validates. An add-on recorded for another version is ignored, so it never runs with a newer engine.
- On startup a new launcher starts `pythonw.exe -I app/control-center/<version>/Arkuzo-Control-Center.py --data <root>/data` and exits. It uses the first `pythonw.exe` on `PATH` that reports Python 3.8 or newer. With no add-on, no usable Python, or `--console`, it runs the console saver as before. Existing takeover rules still apply to console savers. A Control Center already answering on `127.0.0.1:48650` is reopened, and the saver it supervises is never taken over. `--console` refuses to start next to it.
- The new launcher only reaches users when they download the new `ArkuzoMemorySaver.exe` from the release; the running launcher never replaces itself. Mention this in the release notes.

Never include `data/`, `app/`, a local `config.json`, logs, recovery journals, Volt databases, or credentials in a release. `config/defaults.json` is the public default, not a live user's configuration. Update the engine, launcher, and changelog version together for subsequent releases.

## Publish

Commit the reviewed source, tests, documentation, and root `ArkuzoMemorySaver.exe`, then push `main`. Create a stable GitHub Release for the corresponding commit, with all seven assets. The launcher discovers **published stable releases**, not commits or draft/prerelease tags. Asset names for the runtime ZIP, the Control Center ZIP, and their checksums are part of the updater protocol and must stay stable.

## VirusTotal Scan & Integrity Verification

Before and after publishing each new version:
1. Scan `ArkuzoMemorySaver.exe` and release archives on [VirusTotal](https://www.virustotal.com).
2. Confirm 0 detections across all security vendors.
3. Update `README.md`, `SECURITY.md`, and the GitHub Release notes with the SHA-256 hashes and VirusTotal report links.

## Verify the published assets

1. Download `ArkuzoMemorySaver.exe` from the newly published release into a new writable test directory.
2. Run `ArkuzoMemorySaver.exe --verify-only` to exercise the real GitHub metadata, download, checksum, extraction, configuration initialization, and installed-cache checks without starting Roblox or the saver. The output must include `Verified Control Center <version>`. `build/verify-release.py` checks the same: update its `VERSION` first.
3. Hash `data/config.json`, customize it, run verification again, and confirm that it is byte-identical.
4. Run `ArkuzoMemorySaver.exe --offline --verify-only` to validate the cache without network access.
5. Confirm the release tag points to the intended commit and all uploaded asset digests match the local artifacts.
6. Only start the saver interactively when no other saver controller is running. Existing live clients must not be disturbed by a release smoke test.

The launcher itself is not silently replaced while running. A future launcher-protocol change should ship a new `ArkuzoMemorySaver.exe` and explicitly document any required manual launcher upgrade.
