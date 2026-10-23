<div align="center">

# Arkuzo Memory Saver
### Volt Integration · v1.2.0 (Control Center & Autopilot)

A portable Windows memory monitor with guarded, account-aware recovery through Volt.

[![Version](https://img.shields.io/badge/version-1.2.0-6366f1)](CHANGELOG.md)
![Windows x64](https://img.shields.io/badge/platform-Windows_x64-0078D4)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![Volt integration](https://img.shields.io/badge/Volt-integration-22c55e)

**[Download ArkuzoMemorySaver.exe](https://github.com/arkuzodev/arkuzo-memory-saver/releases/latest/download/ArkuzoMemorySaver.exe)** · **[Releases](https://github.com/arkuzodev/arkuzo-memory-saver/releases/latest)** · **[Configuration](docs/configuration.md)** · **[Troubleshooting](docs/troubleshooting.md)**

</div>

---

## One download. Separate runtime and data.

Download **only `ArkuzoMemorySaver.exe`**, put it in a writable folder, and launch it. On first start, the launcher retrieves the **latest stable official release's runtime ZIP and checksum**, verifies its SHA-256 hash, installs the version, and starts the saver. Prereleases are not selected automatically.

Subsequent starts check for stable runtime updates. Versioned files live in `app/versions/`; your configuration, logs, and recovery journal live separately in `data/`. **An update never overwrites an existing user configuration.** If the JSON is malformed, the saver refuses to start instead of silently replacing it with defaults. The runtime update itself can still complete; your configuration is preserved.

```mermaid
flowchart LR
    A[Check stable update] --> B[Verify SHA-256]
    B --> C[Install version]
    C --> D[Preserve user data]
    D --> E[Launch saver]
```

> First start requires internet access. Offline starts require an already installed, validated cached runtime. A checksum detects a mismatch; it is not a code signature or a substitute for trusting the download source.

## What it does

| Feature | Behavior and boundary |
| --- | --- |
| Memory visibility | Tracks resident working set, private memory, and OS commit pressure separately. |
| Eligible working-set trimming | Uses a 600 MB soft target, a five-minute per-client warmup, and a 45-second trim interval. Skips loading, unresponsive, and startup-error clients. |
| Sustained-memory guard | A 6,000 MB private-memory threshold sustained for 60 seconds can make a client a recovery candidate. Current system pressure has separate checks. |
| Volt account recovery | Acts only when account identity, process generation, launcher control, relaunch eligibility, and audit state can be verified. |
| Bounded restoration | Serializes recovery, preserves unresolved handoffs, and persists retry backoff and budgets across saver restarts. |
| Cookie-dead isolation | Shows invalid sessions in a separate red `COOKIE DEAD` section; pauses only that account when safe idle/no-process evidence is verified. |
| Portable updates | Keeps versioned runtime files separate from persistent user data; validated cached versions support offline startup. |

**The 600 MB value is not an enforced hard cap.** Trimming may reduce resident RAM temporarily, but it does not free private allocations or fix a memory leak. The 82% OS commit threshold is a policy for selecting recovery candidates—not a promise of crash prevention.

### Illustrative status — not a live screenshot

This hand-written example shows the kinds of states you may encounter. It is **not actual application output, a benchmark, or account data**.

```text
Arkuzo Memory Saver · Volt Integration
Client A   WARMUP          waiting for this client's startup grace
Client B   MONITORING      eligible trimming depends on current health
Recovery   WAITING         exact account restoration still unconfirmed
Policy     600 MB soft target · hard cap disabled
```

## Control Center and autopilot

The launcher (`ArkuzoMemorySaver.exe` v1.2.0 or newer, with Python 3 on `PATH`) opens the Control Center automatically; in a source checkout, `Arkuzo-Control-Center.cmd` does the same. It is a local dashboard (served only on `127.0.0.1`) that runs the saver for you:

- **Live view** of every client: account, status, resident memory against the target, private memory, CPU, next trim and uptime; farm-memory and system-pressure charts; Volt accounts; an activity feed.
- **Autopilot** keeps the saver alive: restarts with backoff after a crash, exit or hang, and pauses instead of looping if it keeps crashing.
- **Settings** for presets, memory, CPU, health and recovery, validated and backed up before saving; most apply live. Per-account auto-recover toggles, **Trim now**, and optional **Start with Windows**.

Closing the window leaves the Control Center and saver running in the background; use **Settings → Quit app** to close it. It needs Python 3 on `PATH`, like the Volt probe.

## Requirements

- **Windows x64** with **Windows PowerShell 5.1**.
- A writable folder for `ArkuzoMemorySaver.exe`, `app/`, and `data/`.
- Internet access for the first runtime download and online update checks.
- **No separate .NET installation** for the self-contained launcher.
- For Volt integration: **Python 3 available on `PATH`** and a running Volt installation with its **Account Manager accessible**. The probe uses Python's standard library.

**Basic monitoring and eligible trimming work without Python or Volt.** Missing dependencies or unavailable account control block destructive recovery; they do not justify terminating clients without a verified return path.

## Get started

1. Download `ArkuzoMemorySaver.exe` from the [official latest stable release](https://github.com/arkuzodev/arkuzo-memory-saver/releases/latest). Keep it in a dedicated writable folder rather than opening it from a temporary download preview.
2. Run it and allow the first runtime download and checksum validation to complete.
3. For recovery, install Python 3 on `PATH`, start Volt, and keep Account Manager accessible. Enable Volt's auto-relaunch only for accounts you intend to manage, with valid sessions and a previous launch.
4. Review `data/config.json` and the [configuration guide](docs/configuration.md). Restart the saver after intentional configuration changes.
5. Allow each newly launched client its own five-minute warmup before expecting ordinary trimming.

**Upgrading a legacy installation:** if `data/config.json` does not exist and `config.json` is beside `ArkuzoMemorySaver.exe`, the launcher copies that legacy configuration byte-for-byte into `data/` and retains the original. An existing `data/config.json` always wins. Old recovery journals are not automatically migrated. Stop the old saver before switching installations.

Windows may show SmartScreen warnings for an **unsigned binary**. Check that the file came from the official repository and review the warning and your organization's policy before proceeding. **Do not disable SmartScreen, antivirus, or other protections globally.**

## Antivirus & Integrity Verification

v1.2.0 ships a rebuilt executable and new archives. Their VirusTotal results are not yet recorded; compare the checksums below with the release before running anything.

| File | SHA-256 Checksum | VirusTotal Result |
| :--- | :--- | :--- |
| **`ArkuzoMemorySaver.exe`** | `27edbe616b590bc18c22ef8cef710687e0721e71d8f05404640fecc5ca96367e` | Not yet scanned |
| **`ArkuzoMemorySaver-runtime.zip`** | `e9d457c4b69c7b92f21b5252f449e13f94f07bbb3287ed616b6009c34c5495a5` | Not yet scanned |
| **`ArkuzoMemorySaver-controlcenter.zip`** | `8e016a0534dfd47a72209131c8e9cd68f718a34e30476229cb3d18c3088f90b1` | Not yet scanned |
| **`ArkuzoMemorySaver-v1.2.0-win-x64.zip`** | `df610f72482561a1fdb9bcedd4ea41788fb1214d810a7f54f26174adb9d7d4c1` | Not yet scanned |

The exact release publishes **`SHA256SUMS.txt`** for its executable and archives, plus **`ArkuzoMemorySaver-runtime.sha256`** and **`ArkuzoMemorySaver-controlcenter.sha256`** for updater validation. The launcher verifies downloaded bytes and available GitHub asset digests. See [security and privacy](SECURITY.md).

You can independently verify checksums locally using PowerShell:
```powershell
Get-FileHash -Algorithm SHA256 .\ArkuzoMemorySaver.exe
```

## Recovery is deliberately conservative

Volt remains the account-aware launcher. Arkuzo Memory Saver does not collect credentials, replay authentication tickets, or write directly to Volt's database. It uses read-only state inspection and verified Account Manager controls; an accepted launch request is not treated as a restored session.

Recovery covers opted-in, previously launched, uniquely mapped accounts. Missing accounts must be demonstrably idle before a launch request. Unknown mappings, loading/transient UI states, unavailable logging, or invalid recovery state block destructive actions. A temporary “Volt account control unavailable” state is not proof that Volt has stopped.

The native relaunch delay is kept at **at least 30 seconds**; an already larger user delay is preserved. Missing-account retries use persistent **90–900 second backoff**, with cooldowns and hourly budgets. An unresolved account handoff protects other accounts from collateral closures.

A restored account must have a new, exactly mapped process generation, connected launcher socket, responsive non-error window, and correctly bound server-acceptance evidence over a continuous confirmation interval. **Those observations are readiness criteria, not an overnight endurance guarantee.**

### Cookie-dead accounts

Volt's red cross corresponds to a dead account session. The saver displays these accounts separately in red as **`COOKIE DEAD`**. A dead session can result from expiration, revocation, a challenge, or another authentication problem; it is not proof of a permanent ban.

A verified idle dead account is paused and excluded from automated launch requests. Its recovery history is retained separately so it does not indefinitely hold the handoff gate for healthy accounts. If a process, launch, or identity remains uncertain, the safety gate stays closed. Restore the account session in Volt manually; the saver only resumes after verifying it is eligible again. Newly imported accounts without a launch history are displayed but never automatically activated.

### What it does not promise

- No guaranteed RAM ceiling, leak repair, crash-free operation, or uninterrupted game session.
- No guaranteed fix for Volt launch guards, seat limits, seat-lease expiry, or authentication failures.
- No assumption that zero CPU, a live process, or Volt's “Connected” label alone proves health.
- No bypass of account opt-in, singleton protection, identity checks, or retry budgets.

## For maintainers

End users need the root `ArkuzoMemorySaver.exe`, not a source checkout or manually assembled runtime.

| Source location | Purpose |
| --- | --- |
| `src/launcher/` | Self-contained launcher and update/cache handling. |
| `src/saver/` | Saver engine, Volt control adapter, and read-only Python probe. |
| `config/defaults.json` | Packaged defaults used to initialize a new user configuration. |
| `tests/` | Regression, safety, updater, and portability tests. |
| Build scripts | Build the launcher and package the runtime ZIP and checksum. |

The release runtime has **four files**: engine, control adapter, Python probe, and `defaults.json`. Mutable user files belong outside the runtime. Do not ship live account stores, logs, recovery journals, authenticated command lines, or machine-specific paths.

Consult [configuration](docs/configuration.md), [troubleshooting](docs/troubleshooting.md), and the [changelog](CHANGELOG.md). Report issues through the [repository](https://github.com/arkuzodev/arkuzo-memory-saver/issues), with sanitized diagnostics and the installed version—not credentials or account data.
