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
| `SHA256SUMS.txt` | Checksums for the executable and ZIP downloads |

Never include `data/`, `app/`, a local `config.json`, logs, recovery journals, Volt databases, or credentials in a release. `config/defaults.json` is the public default, not a live user's configuration. Update the engine, launcher, and changelog version together for subsequent releases.

## Publish

Commit the reviewed source, tests, documentation, and root `ArkuzoMemorySaver.exe`, then push `main`. Create a stable GitHub Release for the corresponding commit, with all five assets. The launcher discovers **published stable releases**, not commits or draft/prerelease tags. Asset names for the runtime ZIP and its checksum are part of the updater protocol and must stay stable.

## VirusTotal Scan & Integrity Verification

Before and after publishing each new version:
1. Scan `ArkuzoMemorySaver.exe` and release archives on [VirusTotal](https://www.virustotal.com).
2. Confirm 0 detections across all security vendors.
3. Update `README.md`, `SECURITY.md`, and the GitHub Release notes with the SHA-256 hashes and VirusTotal report links.

## Verify the published assets

1. Download `ArkuzoMemorySaver.exe` from the newly published release into a new writable test directory.
2. Run `ArkuzoMemorySaver.exe --verify-only` to exercise the real GitHub metadata, download, checksum, extraction, configuration initialization, and installed-cache checks without starting Roblox or the saver.
3. Hash `data/config.json`, customize it, run verification again, and confirm that it is byte-identical.
4. Run `ArkuzoMemorySaver.exe --offline --verify-only` to validate the cache without network access.
5. Confirm the release tag points to the intended commit and all uploaded asset digests match the local artifacts.
6. Only start the saver interactively when no other saver controller is running. Existing live clients must not be disturbed by a release smoke test.

The launcher itself is not silently replaced while running. A future launcher-protocol change should ship a new `ArkuzoMemorySaver.exe` and explicitly document any required manual launcher upgrade.
