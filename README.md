<div align="center">

<img src="docs/images/readme/hero.png" alt="Arkuzo Memory Saver: your Roblox farm, kept in game" width="100%">

<br>

[![Version](https://img.shields.io/badge/version-2.3.0-38bdf8?style=for-the-badge&labelColor=12141b)](CHANGELOG.md)
[![Windows x64](https://img.shields.io/badge/Windows-x64-818cf8?style=for-the-badge&labelColor=12141b)](#requirements)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-a78bfa?style=for-the-badge&labelColor=12141b)](#requirements)
[![Volt optional](https://img.shields.io/badge/Volt-optional-34d399?style=for-the-badge&labelColor=12141b)](docs/accounts.md)

### [**⬇&nbsp; Download ArkuzoMemorySaver.exe**](https://github.com/arkuzodev/arkuzo-memory-saver/releases/latest/download/ArkuzoMemorySaver.exe)

[Releases](https://github.com/arkuzodev/arkuzo-memory-saver/releases/latest) &nbsp;·&nbsp; [Configuration](docs/configuration.md) &nbsp;·&nbsp; [Troubleshooting](docs/troubleshooting.md) &nbsp;·&nbsp; [Accounts without Volt](docs/accounts.md) &nbsp;·&nbsp; [Farm-freeze recovery](docs/farm-freeze-recovery.md) &nbsp;·&nbsp; [Remote desktop](docs/remote-desktop.md) &nbsp;·&nbsp; [Roadmap](#roadmap) &nbsp;·&nbsp; [Changelog](CHANGELOG.md)

</div>

<br>

<img src="docs/images/readme/stats.png" alt="Farm-wide freezes back in game in about 2.5 min on average (replay), 600 MB soft target per client after a 90 s warm-up, one verified relaunch at a time, a four-file checksummed runtime" width="100%">

<sub>The 2.5 min is the average per account when the four logged farm-wide freezes (23–27 Oct) are replayed against v2.1.5; the logs showed 5.8 min. See [farm-freeze recovery](docs/farm-freeze-recovery.md).</sub>

## What it does

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/images/readme/feature-memory.svg" width="44" align="left" hspace="10" alt="">
<b>Memory you can read</b><br>
<sub>Resident working set, private memory and OS commit pressure, tracked separately per client and for the whole farm.</sub>
</td>
<td width="50%" valign="top">
<img src="docs/images/readme/feature-trim.svg" width="44" align="left" hspace="10" alt="">
<b>Careful working-set trimming</b><br>
<sub>600 MB soft target, a 90 s warm-up per client and a 45 s trim interval. Loading, frozen and startup-error clients are skipped.</sub>
</td>
</tr>
<tr>
<td valign="top">
<img src="docs/images/readme/feature-freeze.svg" width="44" align="left" hspace="10" alt="">
<b>Freeze, hang and kick recovery</b><br>
<sub>A farm-wide freeze is confirmed after 35 s (20 s right after a remote-desktop disconnect), and the frozen clients are closed one every 20 s so each account relaunches cleanly. Kicked and frozen clients that quit on their own are queued too.</sub>
</td>
<td valign="top">
<img src="docs/images/readme/feature-relaunch.svg" width="44" align="left" hspace="10" alt="">
<b>Own account manager</b><br>
<sub>Add accounts by cookie or browser sign-in, check whether each is still signed in, start the farm and relaunch every client yourself, with no Volt needed. A relaunch counts once the new client is in game. <b>Close</b>, <b>Close all</b> and <b>Stop farm</b> close clients instantly.</sub>
</td>
</tr>
<tr>
<td valign="top">
<img src="docs/images/readme/feature-cookie.svg" width="44" align="left" hspace="10" alt="">
<b>Dead and moderated accounts set aside</b><br>
<sub>Signed-out cookies and accounts Roblox has moderated are marked in red and never retried, so they don't hold up the healthy accounts. A later cookie check brings them back.</sub>
</td>
<td valign="top">
<img src="docs/images/readme/feature-updates.svg" width="44" align="left" hspace="10" alt="">
<b>Portable, verified updates</b><br>
<sub>Versioned runtime in <code>app/</code>, your config, logs and journal in <code>data/</code>. Every download is SHA-256 checked; cached versions start offline.</sub>
</td>
</tr>
<tr>
<td valign="top">
<img src="docs/images/readme/feature-control.svg" width="44" align="left" hspace="10" alt="">
<b>Arkuzo Control Center</b><br>
<sub>A local dashboard on <code>127.0.0.1</code>: every client, farm memory and system pressure charts, your accounts and farm start, an activity feed and live settings.</sub>
</td>
<td valign="top">
<img src="docs/images/readme/feature-autopilot.svg" width="44" align="left" hspace="10" alt="">
<b>Autopilot</b><br>
<sub>Keeps the saver alive: restarts it with backoff after a crash, exit or hang, and pauses instead of looping if it keeps crashing.</sub>
</td>
</tr>
</table>

> [!NOTE]
> **600 MB is a soft target, not a hard cap.** Trimming lowers resident RAM for a while; it doesn't free private allocations or fix a leak. The 88% OS commit threshold picks recovery candidates; it is not a promise against crashes.

## The Control Center

The launcher opens it for you (it needs Python 3 on `PATH`); in a source checkout, `Arkuzo-Control-Center.cmd` does the same. It follows the Arkuzo Client's look: eight themes, ten accents, card surfaces, keycaps and the boot intro.

<img src="docs/images/control-center-overview.png" alt="Control Center overview: KPI cards, farm memory and system pressure charts, clients and activity" width="100%">

<table>
<tr>
<td width="50%"><img src="docs/images/control-center-clients.png" alt="Clients page"><p align="center"><sub><b>Clients</b></sub></p></td>
<td width="50%"><img src="docs/images/control-center-settings.png" alt="Settings page"><p align="center"><sub><b>Settings</b></sub></p></td>
</tr>
<tr>
<td><img src="docs/images/control-center-midnight.png" alt="Midnight theme with the Violet accent"><p align="center"><sub><b>Midnight · Violet</b></sub></p></td>
<td><img src="docs/images/control-center-frost.png" alt="Frost light theme with the Indigo accent"><p align="center"><sub><b>Frost · Indigo</b></sub></p></td>
</tr>
</table>

<sub>Pictures use a synthetic demo farm, not real accounts or measurements.</sub>

- **Close the window and it exits cleanly:** the saver stops and the Control Center quits, like **Settings → Stop farm & quit**. Your Roblox clients keep running.
- **Updates take over by themselves:** starting the launcher always runs the newest installed version. A newer Control Center replaces an older running one and restarts the saver on the new version if it was running.
- **Start with Windows** is optional. A launcher install opens the window at sign-in; a source checkout starts in the background until you open its window and close it.

## Get started

| | |
| :---: | :--- |
| <kbd>1</kbd> | **Download** [`ArkuzoMemorySaver.exe`](https://github.com/arkuzodev/arkuzo-memory-saver/releases/latest/download/ArkuzoMemorySaver.exe) into its own writable folder, not a temporary download preview. |
| <kbd>2</kbd> | **Run it.** The first start downloads the latest stable runtime, checks its SHA-256 and installs it. |
| <kbd>3</kbd> | **Add your accounts** on the Control Center's Accounts page (cookie or browser sign-in), set the place, and press **Start farm**. Using Volt's account manager instead works too. |
| <kbd>4</kbd> | **Tune** `data/config.json` with the [configuration guide](docs/configuration.md), or use the Control Center's Settings page. |
| <kbd>5</kbd> | **Give each new client its 90-second warm-up** before expecting regular trimming. |

Monitoring and trimming work on their own. Recovery needs something that can bring a client back, Arkuzo's account manager or Volt's; without one it stays off, because the saver never closes a client it can't bring back.

```mermaid
flowchart LR
    A([Launcher start]) --> B{Newer stable<br>release?}
    B -- yes --> C[Download runtime]
    C --> D[Verify SHA-256]
    D --> E[Install to app/versions]
    B -- no --> F[Use cached version]
    E --> G[(data/ kept as is)]
    F --> G
    G --> H([Saver + Control Center])
    classDef accent fill:#0c2a3a,stroke:#38bdf8,color:#e0f2fe
    classDef ok fill:#0b2a20,stroke:#34d399,color:#d1fae5
    class A,H accent
    class G ok
```

> [!IMPORTANT]
> The first start needs internet access. Later starts work offline from a validated cached runtime. **An update never overwrites your configuration;** if `data/config.json` is malformed, the saver refuses to start instead of replacing it with defaults.

## Recovery is deliberately conservative

The launcher is either Arkuzo's own account manager ([accounts without Volt](docs/accounts.md)) or Volt's. Arkuzo keeps the cookies you add encrypted for your Windows user and sends them only to Roblox. With Volt, the saver never writes Volt's database: it reads state and uses verified Account Manager controls. Either way, an accepted launch request is not treated as a restored session.

```mermaid
flowchart LR
    A[Client frozen,<br>kicked or over budget] --> B{Account mapped<br>exactly?}
    B -- no --> X[Blocked, nothing closed]
    B -- yes --> C[Journal entry written]
    C --> D[Close that client]
    D --> E[Arkuzo or Volt relaunches]
    E --> F{New process,<br>socket, window,<br>server joined?}
    F -- yes --> G([Back in game])
    F -- not yet --> H[Retry with backoff<br>and hourly budget]
    classDef bad fill:#3a1418,stroke:#f87171,color:#fee2e2
    classDef ok fill:#0b2a20,stroke:#34d399,color:#d1fae5
    class X bad
    class G ok
```

- **Only opted-in, uniquely mapped accounts.** Unknown mappings, loading screens, unavailable logging or an unhealthy journal block every destructive step. Arkuzo maps each client by the account's own tracker id on its command line; clients it didn't launch are left alone.
- **Arkuzo relaunches by itself** after the relaunch delay (8 s), launches spaced 12 s apart, and retries only a launch that produced no client. An account Roblox has moderated is never retried.
- **You stay in control of the clients:** **Stop farm** stops relaunching and closes every client; **Close all** closes them all and, while the farm runs, brings them back (a quick restart); **Close** on one account closes that client and leaves its relaunch on. The Control Center closes only the exact process the saver reported for the account.
- **With Volt, its relaunch delay stays at 30 s or more;** a larger delay you set is kept. Missing-account retries back off for 90–900 s, with cooldowns and hourly budgets that survive saver restarts.
- **A restore must prove itself:** a new, exactly mapped process, a connected launcher socket, a responsive window without errors and matching server-join evidence, held for a continuous confirmation window.
- **Farm-wide freezes** (in the logs, Chrome Remote Desktop disconnects and display events) are handled as one event, with closes paced so Volt doesn't show its "Roblox started before Volt could connect" notice. Switch it off with `health.farm_freeze_enabled`.
- **Remote desktop:** in the logs, 12 of 14 Chrome Remote Desktop disconnects with clients running froze them. The saver recognises a disconnect and recycles the farm sooner, never hangs on a frozen client's log, warns you in the Control Center while a session is connected (minimise it instead of disconnecting), and has a "Leave Remote Desktop safely" button for RDP. See [remote desktop disconnects](docs/remote-desktop.md).

<details>
<summary><b>Cookie-dead and moderated accounts</b></summary>
<br>

A cookie Roblox rejects (Arkuzo's cookie check, or Volt's red cross) means a dead account session. The saver shows these accounts in red as **`COOKIE DEAD`**. A dead session can come from expiry, revocation, a challenge or another sign-in problem; it is not proof of a ban.

A verified idle dead account is paused and left out of launch requests. Its recovery history is kept separately so it doesn't hold the handoff gate for healthy accounts. If a process, launch or identity is uncertain, the gate stays closed. Sign the account in again yourself, on the Accounts page or in Volt; the saver resumes once it checks out again. Newly imported accounts with no launch history are shown but never activated automatically.

An account Roblox has **moderated** (banned or warned) keeps a valid cookie but cannot launch: Roblox answers "User is moderated". Arkuzo shows it as **Moderated**, doesn't launch or retry it, and drops any relaunch queued for it, so it never holds up the others. Sign in to it on roblox.com to read Roblox's notice. The hourly cookie check (or **Check**) finds it **Alive** again once the moderation ends, and the farm picks it up.

</details>

<details>
<summary><b>What it does not promise</b></summary>
<br>

- No guaranteed RAM ceiling, leak repair, crash-free operation or uninterrupted game session.
- No guaranteed fix for Volt launch guards, seat limits, seat-lease expiry or sign-in failures.
- No assumption that zero CPU, a live process or Volt's "Connected" label alone proves a client is healthy.
- No bypass of account opt-in, singleton protection, identity checks or retry budgets.

The readiness checks above are criteria for counting a restore, not an overnight endurance guarantee.

</details>

## Requirements

| | |
| :--- | :--- |
| **System** | Windows x64 with Windows PowerShell 5.1. No separate .NET install; the launcher is self-contained. |
| **Folder** | A writable folder for `ArkuzoMemorySaver.exe`, `app/` and `data/`. |
| **Network** | Internet for the first runtime download and update checks. |
| **Python** | Python 3.8 or newer on `PATH` for the Control Center, and with it the account manager. Without it the launcher runs the console saver: monitoring and trimming only. |
| **Accounts** | Arkuzo accounts need nothing else (browser sign-in uses Edge or Chrome). With Volt instead: a running Volt with its Account Manager reachable. |

<details>
<summary><b>Upgrading a legacy installation</b></summary>
<br>

If `data/config.json` doesn't exist and a `config.json` sits beside `ArkuzoMemorySaver.exe`, the launcher copies it byte for byte into `data/` and keeps the original. An existing `data/config.json` always wins. Old recovery journals are not migrated. Stop the old saver before switching installations.

</details>

## Roadmap

Arkuzo started as a memory saver bolted onto Volt. The roadmap turns it into a farm runner of its own, in four phases, each built on the same rule as the saver today: nothing is closed unless it can be brought back, verified. **Phase 1 is done**; phase 2 is next.

<img src="docs/images/readme/roadmap.png" alt="Roadmap: 1 Volt becomes optional (done), 2 AI control over MCP (next), 3 headless farming, 4 Arkuzo execution suite" width="100%">

| Phase | Goal | What it means |
| :---: | :--- | :--- |
| <kbd>1</kbd> **Done** | **Volt becomes optional** | Arkuzo's own [account manager](docs/accounts.md) adds accounts, starts the farm and relaunches every client, with the same verified, account-aware recovery. Volt is now just your executor. Still open from this phase: integrations for executors other than Volt. |
| <kbd>2</kbd> **Next** | **AI control over MCP** | An MCP server so AI agents can watch the farm and adjust settings in real time, inside the same safety gates. |
| <kbd>3</kbd> | **Headless farming** | More performance work and fully windowless farming: clients run without windows on screen. |
| <kbd>4</kbd> | **Arkuzo execution suite** | Arkuzo's own execution suite, built in and integrated with the saver from the start. |

<sub>Plans, not promises: order and scope can change. Shipped work lands in the <a href="CHANGELOG.md">changelog</a>.</sub>

## Integrity and antivirus

v2.3.0 ships a rebuilt executable, runtime and Control Center add-on; all 1.x releases are deprecated. VirusTotal results for these files are not recorded yet, so compare the checksums with the release before running anything.

| File | SHA-256 | VirusTotal |
| :--- | :--- | :--- |
| **`ArkuzoMemorySaver.exe`** | `717e84bd7b0399f2c9b03fddc40e22f857d18eef278083832e53ef7da1afa06d` | Not yet scanned |
| **`ArkuzoMemorySaver-runtime.zip`** | `343c710d31c9223295657ea37cf14d6ba2cd72cb927086d70e36ccd7487c1ca4` | Not yet scanned |
| **`ArkuzoMemorySaver-controlcenter.zip`** | `f2c54820a4f33c0cb9eda1c9787410497e5373d1a8571c4c2d5347d638f952e0` | Not yet scanned |
| **`ArkuzoMemorySaver-v2.3.0-win-x64.zip`** | `48e1039b580dc88bc2073dc1693e2ebaaab49e1b7da91069b9151243ba4eb822` | Not yet scanned |

Each release also publishes **`SHA256SUMS.txt`**, plus **`ArkuzoMemorySaver-runtime.sha256`** and **`ArkuzoMemorySaver-controlcenter.sha256`** for the updater. The launcher checks downloaded bytes and GitHub's asset digests. A checksum detects a mismatch; it is not a code signature. See [security and privacy](SECURITY.md).

```powershell
Get-FileHash -Algorithm SHA256 .\ArkuzoMemorySaver.exe
```

> [!WARNING]
> Windows may show a SmartScreen warning for this **unsigned** executable. Check that it came from this repository and follow your organization's policy. **Don't turn off SmartScreen, antivirus or other protections globally.**

<details>
<summary><b>For maintainers</b></summary>
<br>

End users need only the root `ArkuzoMemorySaver.exe`, not a source checkout or a hand-assembled runtime.

| Source | Purpose |
| :--- | :--- |
| `src/launcher/` | Self-contained launcher, update and cache handling. |
| `src/saver/` | Saver engine, Volt control adapter, read-only Python probe and the Control Center. |
| `config/defaults.json` | Packaged defaults for a new user configuration. |
| `tests/` | Regression, safety, updater and portability tests (`build/test.ps1`). |
| `build/` | Launcher build, packaging and release verification. |

The release runtime has **exactly four files**: engine, control adapter, Python probe and `defaults.json`. Mutable user files stay outside it. Never ship live account stores, logs, recovery journals, authenticated command lines or machine-specific paths. See [releasing](docs/releasing.md).

</details>

<br>

<div align="center">
<sub>Report issues through the <a href="https://github.com/arkuzodev/arkuzo-memory-saver/issues">repository</a> with sanitized diagnostics and your installed version, never credentials or account data.</sub>
</div>
