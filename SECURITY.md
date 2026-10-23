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

The **v1.2.0** release rebuilds the launcher and adds the Control Center add-on. Its VirusTotal results are not yet recorded; earlier scans do not apply to these bytes:
- **`ArkuzoMemorySaver.exe`:** SHA-256 `27edbe616b590bc18c22ef8cef710687e0721e71d8f05404640fecc5ca96367e`
- **`ArkuzoMemorySaver-runtime.zip`:** SHA-256 `e9d457c4b69c7b92f21b5252f449e13f94f07bbb3287ed616b6009c34c5495a5`
- **`ArkuzoMemorySaver-controlcenter.zip`:** SHA-256 `8e016a0534dfd47a72209131c8e9cd68f718a34e30476229cb3d18c3088f90b1`
- **`ArkuzoMemorySaver-v1.2.0-win-x64.zip`:** SHA-256 `df610f72482561a1fdb9bcedd4ea41788fb1214d810a7f54f26174adb9d7d4c1`

The Control Center listens only on `127.0.0.1`, rejects requests whose `Host` is not a loopback name, and requires a per-run token for every change. It never reads cookies, tickets or command lines and does not control Roblox or Volt directly.

Checksums and antivirus scans are not signatures or guarantees. Keep Windows Defender, SmartScreen, and Windows Error Reporting enabled.

## Volt integration

The adapter uses the existing Volt window's Windows UI Automation controls. Its database probe is read-only and reports a restricted set of account status fields. The saver does not generate authentication tickets, write Volt's database, or replay Roblox command lines. When identity or launch state is unclear, recovery is blocked.

## Reporting

Do not attach your complete Volt database, cookies, tokens, account credentials, or connection strings to an issue. Logs can contain account names and local paths: review and redact them before sharing. For a sensitive report, contact the repository owner privately; do not put exploit details or credentials in a public issue.
