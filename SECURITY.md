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

The **v2.1.5** release rebuilds the launcher and ships the Control Center add-on in the Arkuzo Client style. All 1.x releases are deprecated. Its VirusTotal results are not yet recorded; earlier scans do not apply to these bytes:
- **`ArkuzoMemorySaver.exe`:** SHA-256 `daa38b0e83788c9519fac2de6fd440737c3f3fdead07f5f504640b58c0b7f4a1`
- **`ArkuzoMemorySaver-runtime.zip`:** SHA-256 `5ae228a1bbd7b38943b6745f29c11f73dd2b2ec1c0cfce204a81b98501c10f30`
- **`ArkuzoMemorySaver-controlcenter.zip`:** SHA-256 `f3bb2f3874a3220492ab2766835071d600005da8ba3f95b28a1eae1c587d9d47`
- **`ArkuzoMemorySaver-v2.1.5-win-x64.zip`:** SHA-256 `7f32df4793312cb886bbe4bb421bf4f33a0265efaad4114acc58defe199b5fa3`

The Control Center listens only on `127.0.0.1`, rejects requests whose `Host` is not a loopback name, and requires a per-run token for every change.

## Arkuzo accounts

Accounts you add in the Control Center (see [accounts without Volt](docs/accounts.md)) are stored in `data/accounts.json`. Their cookies and private-server link codes are encrypted with Windows DPAPI for the current Windows user. The Control Center and the engine decrypt them only in memory to talk to Roblox (`*.roblox.com` over HTTPS) or to start a client. No API response, page, log line, heartbeat, error message or Arkuzo command line contains a cookie. The launch ticket Roblox issues per launch is passed to that client like any Roblox launcher does, and is never logged. Browser sign-in uses a throwaway browser profile that is deleted when the window closes. Removing an account deletes its stored cookie.

Checksums and antivirus scans are not signatures or guarantees. Keep Windows Defender, SmartScreen, and Windows Error Reporting enabled.

## Volt integration

With Volt as the launcher, the adapter uses the existing Volt window's Windows UI Automation controls. Its database probe is read-only and reports a restricted set of account status fields; it never reads Volt's stored cookies. The saver never writes Volt's database or replays Roblox command lines. When identity or launch state is unclear, recovery is blocked.

## Reporting

Do not attach your complete Volt database, cookies, tokens, account credentials, or connection strings to an issue. Logs can contain account names and local paths: review and redact them before sharing. For a sensitive report, contact the repository owner privately; do not put exploit details or credentials in a public issue.
