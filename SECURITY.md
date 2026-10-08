# Security & privacy

Arkuzo Memory Saver runs locally. The public launcher reads release metadata and downloads runtime assets from **arkuzodev/arkuzo-memory-saver** on GitHub without a user token.

## Trust boundary

- Use only the official repository and its release assets.
- The updater checks the runtime ZIP's SHA-256 checksum, verifies GitHub's asset digest when available, validates the archive contents, and checks the installed files before using a cached version.
- A checksum detects corruption; it does **not** provide protection if the repository or publisher's account is compromised. This release is not Authenticode-signed.
- Updates preserve existing `data/config.json`. They do not reset malformed configuration.
- Local `app/` and `data/` directories must be writable only by users you trust. Do not run the program from a shared, untrusted directory.

## Release integrity and antivirus status

SHA-256 values for each release are published in that release's **`SHA256SUMS.txt`** and **`ArkuzoMemorySaver-runtime.sha256`** assets. The launcher validates runtime bytes and available GitHub asset digests before installation or repair. Use checksums from the exact release you downloaded, not a previous version.

The release binary `ArkuzoMemorySaver.exe` (`96d43820ea2361be00c0c3096fc774484c4bf1a7b56c478abf7e4cbf668a3072`) was scanned on VirusTotal and verified **0/67 Clean** with zero detections:
- **VirusTotal Scan (Executable):** [https://www.virustotal.com/gui/file/96d43820ea2361be00c0c3096fc774484c4bf1a7b56c478abf7e4cbf668a3072](https://www.virustotal.com/gui/file/96d43820ea2361be00c0c3096fc774484c4bf1a7b56c478abf7e4cbf668a3072)
- **VirusTotal Scan (Runtime Zip):** [https://www.virustotal.com/gui/file/7f07c8da696dcb69b3cab1b304d627bbc5f981f7d0b686f1fa9d03dcce89608d](https://www.virustotal.com/gui/file/7f07c8da696dcb69b3cab1b304d627bbc5f981f7d0b686f1fa9d03dcce89608d)
- **VirusTotal Scan (Release Archive):** [https://www.virustotal.com/gui/file/12670c4607fd93bd0ded959c5125efc2316a6b6c438ef9058192ec9fed338e95](https://www.virustotal.com/gui/file/12670c4607fd93bd0ded959c5125efc2316a6b6c438ef9058192ec9fed338e95)

The **v1.1.0 Stable Baseline Release** includes an updated launcher executable with built-in WMI controller takeover, automated stale process cleanup, and persistent process-bound account name caching. All release artifacts were submitted to and verified clean by VirusTotal on October 8, 2026.

Checksums and antivirus scans are not signatures or guarantees. Keep Windows Defender, SmartScreen, and Windows Error Reporting enabled.

## Volt integration

The adapter uses the existing Volt window's Windows UI Automation controls. Its database probe is read-only and reports a restricted set of account status fields. The saver does not generate authentication tickets, write Volt's database, or replay Roblox command lines. When identity or launch state is unclear, recovery is blocked.

## Reporting

Do not attach your complete Volt database, cookies, tokens, account credentials, or connection strings to an issue. Logs can contain account names and local paths: review and redact them before sharing. For a sensitive report, contact the repository owner privately; do not put exploit details or credentials in a public issue.
