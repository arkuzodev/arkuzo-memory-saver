# Security & privacy

Arkuzo Memory Saver runs locally. The public launcher reads release metadata and downloads runtime assets from **arkuzodev/arkuzo-memory-saver** on GitHub without a user token.

## Trust boundary

- Use only the official repository and its release assets.
- The updater checks the runtime ZIP's SHA-256 checksum, verifies GitHub's asset digest when available, validates the archive contents, and checks the installed files before using a cached version.
- A checksum detects corruption; it does **not** provide protection if the repository or publisher's account is compromised. This release is not Authenticode-signed.
- Updates preserve existing `data/config.json`. They do not reset malformed configuration.
- Local `app/` and `data/` directories must be writable only by users you trust. Do not run the program from a shared, untrusted directory.

## Antivirus & VirusTotal Verification

Every official release artifact is submitted to and scanned by **VirusTotal** across 92 security vendors.

| Release Asset | SHA-256 Checksum | VirusTotal Analysis | Status |
| :--- | :--- | :--- | :--- |
| **`ArkuzoMemorySaver.exe`** | `0fc74a5b3b3e3f0b9138c4839907b61038c33cf876ed1c22226cf2e711d3d74a` | [Report Link](https://www.virustotal.com/gui/file/7140e1b2715f7df0488713835cf6df9e5d5a40623788b3ec0c71c70da8ad7cf1) | **0 / 92 Clean** |
| **`ArkuzoMemorySaver-runtime.zip`** | `8651ea424b1b530a4be8a05b02c5f88acaffbec4c5cdbb03536445950ef29310` | [Report Link](https://www.virustotal.com/gui/file/cad70dbdcca7876fb9257d4a572dcf4ced9f7219665ce5a4eb0e59e354f9660e) | **Clean** |
| **`ArkuzoMemorySaver-v1.0.3-win-x64.zip`** | `857ce02fe889156ddb3ab7e048c8b2f72358a10c06b9bd48afbe01d952f24467` | [Report Link](https://www.virustotal.com/gui/file/66c58470905f49843ba4b2fc35561241240f5d0e28bcd9bcedae9ab7fa4675d2) | **Clean** |

## Volt integration

The adapter uses the existing Volt window's Windows UI Automation controls. Its database probe is read-only and reports a restricted set of account status fields. The saver does not generate authentication tickets, write Volt's database, or replay Roblox command lines. When identity or launch state is unclear, recovery is blocked.

## Reporting

Do not attach your complete Volt database, cookies, tokens, account credentials, or connection strings to an issue. Logs can contain account names and local paths: review and redact them before sharing. For a sensitive report, contact the repository owner privately; do not put exploit details or credentials in a public issue.
