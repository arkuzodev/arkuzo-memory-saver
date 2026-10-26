# Security & privacy

Arkuzo Memory Saver runs locally. The public launcher reads release metadata and downloads runtime assets from **arkuzodev/arkuzo-memory-saver** on GitHub without a user token.

## Trust boundary

- Use only the official repository and its release assets.
- The updater checks the runtime ZIP's SHA-256 checksum, verifies GitHub's asset digest when available, validates the archive contents, and checks the installed files before using a cached version.
- A checksum detects corruption; it does **not** provide protection if the repository or publisher's account is compromised. This release is not Authenticode-signed.
- Updates preserve existing `data/config.json`. They do not reset malformed configuration.
- Local `app/` and `data/` directories must be writable only by users you trust. Do not run the program from a shared, untrusted directory.

## Release integrity and antivirus status

SHA-256 values for each release are published in that release's **`SHA256SUMS.txt`**, **`ArkuzoMemorySaver-runtime.sha256`** and **`ArkuzoMemorySaver-controlcenter.sha256`** assets. The launcher validates runtime bytes and available GitHub asset digests before installation or repair. Use checksums from the exact release you downloaded, not a previous version.

The **v2.1.3** release rebuilds the launcher and ships the Control Center add-on in the Arkuzo Client style. All 1.x releases are deprecated. Its VirusTotal results are not yet recorded; earlier scans do not apply to these bytes:
- **`ArkuzoMemorySaver.exe`:** SHA-256 `4f121c15b1d905cbc37b714647530c6bafe1c740c1be46e98aed391d2bd3841f`
- **`ArkuzoMemorySaver-runtime.zip`:** SHA-256 `ed89889d3a67d2719838fe9f1fa8c19db4557aeca57725c66c03061c3a611a69`
- **`ArkuzoMemorySaver-controlcenter.zip`:** SHA-256 `060ebe5e65b662b7a9909e34c6a6a859f34db741a68ab3a6eb2dcb23bfcedcc1`
- **`ArkuzoMemorySaver-v2.1.3-win-x64.zip`:** SHA-256 `aae7d64bd8ee69dc3c1d6e34b7949b492256ef07a0508cac14d243d9934f6d15`

The Control Center listens only on `127.0.0.1`, rejects requests whose `Host` is not a loopback name, and requires a per-run token for every change. It never reads cookies, tickets or command lines and does not control Roblox or Volt directly.

Checksums and antivirus scans are not signatures or guarantees. Keep Windows Defender, SmartScreen, and Windows Error Reporting enabled.

## Volt integration

The adapter uses the existing Volt window's Windows UI Automation controls. Its database probe is read-only and reports a restricted set of account status fields. The saver does not generate authentication tickets, write Volt's database, or replay Roblox command lines. When identity or launch state is unclear, recovery is blocked.

## Reporting

Do not attach your complete Volt database, cookies, tokens, account credentials, or connection strings to an issue. Logs can contain account names and local paths: review and redact them before sharing. For a sensitive report, contact the repository owner privately; do not put exploit details or credentials in a public issue.
