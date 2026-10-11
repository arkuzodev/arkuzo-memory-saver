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

The release binary `ArkuzoMemorySaver.exe` (`6b2a7347bb288b11509aebb7cf4cd37e6ef190618cb8bed47a55b72b038f03ef`) was scanned on VirusTotal and verified **0/71 Clean** with zero detections:
- **VirusTotal Scan (Executable):** [https://www.virustotal.com/gui/file/6b2a7347bb288b11509aebb7cf4cd37e6ef190618cb8bed47a55b72b038f03ef](https://www.virustotal.com/gui/file/6b2a7347bb288b11509aebb7cf4cd37e6ef190618cb8bed47a55b72b038f03ef)
- **Updated Runtime Zip:** SHA-256 `c75e9f0b3ffa129e00cc80cbce02585c917a69fea3d15d37efe6c6cab80facc9`. VirusTotal status for this checksum is not yet verified; the previous runtime scan does not apply to these updated bytes.
- **VirusTotal Scan (Release Archive):** [https://www.virustotal.com/gui/file/28518128a18649a4370e814b08aa363561850a5eaf0fe2cf2084f256e646f9c4](https://www.virustotal.com/gui/file/28518128a18649a4370e814b08aa363561850a5eaf0fe2cf2084f256e646f9c4)

The **v1.1.0 Stable Baseline Release** includes a launcher executable with built-in WMI controller takeover, automated stale process cleanup, and persistent process-bound account name caching. The executable and portable archive are unchanged from the original release. The refreshed runtime adds automatic exclusion of disappeared suspended accounts; do not transfer the original runtime's antivirus result to this update.

Checksums and antivirus scans are not signatures or guarantees. Keep Windows Defender, SmartScreen, and Windows Error Reporting enabled.

## Volt integration

The adapter uses the existing Volt window's Windows UI Automation controls. Its database probe is read-only and reports a restricted set of account status fields. The saver does not generate authentication tickets, write Volt's database, or replay Roblox command lines. When identity or launch state is unclear, recovery is blocked.

## Reporting

Do not attach your complete Volt database, cookies, tokens, account credentials, or connection strings to an issue. Logs can contain account names and local paths: review and redact them before sharing. For a sensitive report, contact the repository owner privately; do not put exploit details or credentials in a public issue.
