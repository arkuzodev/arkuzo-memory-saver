# Changelog

Changes for **Arkuzo Memory Saver with Volt Integration** are recorded here.

## v2.1.3 — Kicked clients come back

- **Kicked clients that close themselves are relaunched:** when a server kicks the whole farm at once, the saver recovers clients one at a time, and most kicked clients close themselves before their turn. Those exits used to leave the accounts missing for good unless `restore_missing` was on. Now each one is queued for the same bounded, verified Volt relaunch as any other recovery. On 26 Oct this left 6 of 7 accounts offline after one kick.

## v2.1.2 — Updates take over, clean exit

- **Updates take effect without quitting first:** starting the launcher always runs the newest version. A newer Control Center takes over from an older one that is still running, restarts the saver on the new version if it was running, and open windows reload onto it. Before, the old Control Center kept running until you quit it from Settings.
- **Closing the window exits cleanly:** clicking the window's X stops the saver gracefully and quits the Control Center, like **Stop farm & quit**. Reloading the page or minimizing the window doesn't. A Control Center running without a window (a source checkout started with Windows) keeps running until one is opened and closed.

## v2.1.1 — Control Center fixes

- **No more black bars:** the Control Center fills its app window edge to edge. It used to stop at 1560px wide and keep 22px of padding on every side.
- **One logo, not two:** the ARKUZO banner had the logo mark built in, so it repeated the logo tile beside it in the sidebar and on the intro. The banner is now the lettering only.

## v2.1.0 — Arkuzo Client style

- **Control Center in the Arkuzo Client's own style:** rebuilt from the client's theme values: eight themes (Graphite, Midnight, Obsidian, Nord, Ember, Forest, Plum, Frost) with its ten accents, beveled cards with accent glow and film grain, keycaps, the client's vector icons and its boot intro.
- **The window stays on screen:** long pages scroll inside the window instead of pushing it past the bottom edge.
- **Data folder shows your profile as `~`,** so shared screenshots don't carry your Windows user name.
- `?theme=`, `?accent=`, `?page=` and `?intro=0` open a specific view; the README now has pictures of each page.

## v2.0.0 — Arkuzo Control Center

The Control Center becomes the main way to run the saver. **All 1.x releases are deprecated**; existing launchers update to 2.0.0 automatically on their next start. Download the new `ArkuzoMemorySaver.exe` to get the Control Center.

- **Saver no longer freezes on a stalled WMI query:** every `Win32_Process`/`Win32_ComputerSystem` query now times out after 5 s. On 23 Oct, a freeze while all clients were unresponsive left the farm unmanaged overnight.
- **Stall watchdog:** a background timer records which step the saver is blocked in (`data/saver-stall.json`). The Control Center names that step when it restarts a hung saver, and the saver logs `SAVER_STALL_RECOVERED` when a long step ends.
- **Autopilot never gives up for good:** after repeated failures it retries every 10 minutes instead of pausing until someone presses Start.
- **Stale data is marked:** when the saver isn't reporting, the dashboard dims the figures and says they're its last report, instead of showing them as live.
- **Control Center redesigned in the Arkuzo Client look:** graphite glass panels, the Arkuzo logo and wordmark, a FARM/TOOLS sidebar with live counts, Ctrl+F search across clients, accounts and activity, client-style performance cards, a clients list with a detail pane, a console-style activity log, stacked toasts, a Live/Paused switch, keyboard page switching (1–5) and the client's ten accent colours.

## v1.2.0 — Control Center & Autopilot

### Control Center (new)
- **Visual dashboard** (`Arkuzo-Control-Center.cmd`): live fleet table with per-client status, resident memory against the target, private memory, CPU, trim countdown and uptime; KPI tiles; one-hour farm-memory and system-pressure charts with crosshair tooltips and table views; Volt account list; filtered activity feed; light and dark themes.
- **Autopilot supervisor:** starts the saver, restarts it with 5–120 s backoff when it exits, crashes or stops writing its heartbeat for two minutes, and pauses after eight crashes in 30 minutes instead of looping. It never starts a second controller next to a live one.
- **Settings without JSON editing:** presets and every resource, health and recovery value, validated with the engine's own ranges, written atomically with a timestamped backup (`data/config-backups/`).
- **Per-account auto-recover toggles** (edit `recovery.excluded_account_ids`), **Trim now**, Start/Stop/Restart, and optional **Start with Windows** (per-user `Run` entry, off by default).
- Local only: binds to `127.0.0.1`, rejects foreign `Host` headers, and requires a per-run token for every change. Standard-library Python; no new dependency.

### Memory
- **Memory priority:** clients run at a lower Windows memory priority (`Low` for Aggressive, `VeryLow` for Extreme), so Windows repurposes their pages first under pressure. The original priority is restored on exit.
- **Adaptive trimming:** while free physical RAM is below `pressure_trim_available_percent`, the trim interval drops to a third (never below 15 s). Target, warmup, responsiveness and spacing checks are unchanged.

### Autonomy
- **Stuck-recovery quarantine:** a recovery that fails `abandon_after_retries` times or stays unresolved for `abandon_after_sec` is released from the shared handoff gate, so one bad account no longer blocks recovery for the whole farm or burns the shared hourly budget. The account is left untouched for `quarantine_sec` (critical commit pressure excepted), then retried; quarantine persists across restarts.
- **Live settings:** target RAM, trim interval and switches, cores, CPU priority, memory priority, minimize and poll interval now apply to the running saver within 10 s. Only `hard_limit` and graphics flags still need a restart. Explicit command-line values keep precedence.
- Richer 2-second heartbeat (`runtime-status.json`): effective settings, totals, trims, uptime, alerts, quarantine and per-client account/slot/trim data.
- Configurations written before these keys existed inherit them from their preset.

### Launcher and updates
- **Existing launchers update automatically** to the v1.2.0 engine: `ArkuzoMemorySaver-runtime.zip` keeps its four-file layout.
- **Download the new `ArkuzoMemorySaver.exe` to get the Control Center.** It ships as a separate add-on (`ArkuzoMemorySaver-controlcenter.zip` + `.sha256`) that only the new launcher fetches and verifies. With Python 3 (`pythonw.exe`) on `PATH`, the new launcher opens the Control Center, which runs the saver; otherwise, or with `--console`, it runs the console saver as before.
- **Start with Windows** registers the launcher itself in launcher installs, so every sign-in checks for updates first.

## v1.1.0 — Stable Baseline Release

Official stable baseline release for the Arkuzo Memory Saver (AMS) architecture with complete Volt integration.

### Core Improvements & Stability
- **Launcher Auto-Takeover & Process Autoclose:** Automatically detects and terminates existing launcher and headless saver controller instances (`Local\ArkuzoSaver-ProcessController`) via WMI process tree matching to allow seamless restarts without mutex contention.
- **Clean Restart & Ghost Account Elimination:** Suspended and "COOKIE DEAD" accounts are no longer persisted across restarts (`suspendedAccounts = @()`), completely preventing ghost rows and unauthorized launch triggers on reboot.
- **Persistent Account Name Caching:** Caches discovered Roblox account names across Volt polling cycles and observation pauses, eliminating intermittent "Unknown account" table flicker.
- **Clean Dashboard UI:**
  - Ambiguous `(!)` indicators replaced with clean `[INFO]` and `[ERROR]` alert badges.
  - Eliminated initial transient warning messages (`volt-control unavailable`, `Volt account recovery bridge is not available`) on clean startup.
- **Strict Launch Guards:** Strict four-layer launch blocking preventing any attempt to launch accounts with dead cookies, missing credentials, or unobserved sessions.
- **Volt State DB Safety & Universal Discovery:** Strictly read-only Volt SQLite state access, universal PC directory discovery for autoexec and state.db across drives and installations, and disabled automatic missing account relaunching to safeguard active client seats.
- **Account Data Formatting:** Preserves SQLite BLOB account typing matching native Volt schema, and updates cookie status display to `[DEAD/INVALID COOKIE] Username`.
- **Verified Clean:** 0/71 clean scan verified on VirusTotal for the release executable (`6b2a7347bb288b11509aebb7cf4cd37e6ef190618cb8bed47a55b72b038f03ef`) and release archives.

## v1.0.7 — QuickEdit Freeze Fix, Launcher Auto-Takeover & Extended Retry Limits

- Keep real, generation-bound health observations flowing during slow Volt probe waits and between clients; preserve the strict greater-than-five-second observation-gap reset.
- Prevent oversized-memory grace from masking an independently sustained hang; retain confirmed memory/OS-pressure priority.
- Recheck completed child probes before observation work and at expired deadlines to avoid false timeout refusals.
- Bind the original recovery reason through revalidation; preserve identity, audit, budget, journal rollback and serialized account-handoff gates.
- Add fixture-only recovery-timing, healthy-rebound, true-gap, changed-generation and probe-exit regression coverage. No destructive live-client tests were used.
- Keep the byte-identical v1.0.5 launcher (SHA-256 `68acb79a8f075e308cbed528c724556152897fe151e5b21393d1c2595cd6f855`); only the separately versioned runtime advances. The live notifier advertises the new stable release without restarting or installing into a running controller.

### Previously committed memory-policy changes included in this release

- Set the production private-memory recovery-candidate threshold to 6500 MB.
- Enable bounded pagefile management in production defaults and raise both per-file and total ceilings to 163840 MB (160 GiB).
- Accept the 160-GiB per-file policy in validation while retaining disk reserves, administrator checks, Windows-managed preservation, no-shrink behavior, and the 4-GiB-per-boot growth budget.
- Add safe initial provisioning path (`Get-ArkuzoPagefileProvisioningDecision`, `Invoke-ArkuzoPagefileProvisioning`) enabling transition from Windows-managed to a fixed 160-GiB pagefile with disk reserve safeguards, atomic registry/WMI rollback, and pending-reboot verification.
- Add regression coverage for production loading, provisioning decisions, and large-file ceiling boundaries. Existing installed configurations and published release assets are not overwritten.

## v1.0.5 — Visible Singleton Launcher, Native Privileges & VoltX Engine Optimizations

- **Visible Singleton Launcher:** When another launcher or running controller is detected, the window displays an informative `[ALREADY RUNNING]` alert and remains open until a key is pressed (in interactive mode), preventing immediate window disappearance.
- **Native Token Privileges (`AdjustTokenPrivileges`):** Enables `SeDebugPrivilege` and `SeIncreaseWorkingSetPrivilege` with strict `ERROR_NOT_ALL_ASSIGNED` verification and rich Win32 error formatting (including Access Denied 5 guidance) for diagnostic transparency.
- **Fail-Closed RobloxCrashHandler Cleanup:** Safely cleans orphaned `RobloxCrashHandler.exe` processes by checking parent process status, startup ticks, image paths, and Roblox publisher signatures. System-wide `WerFault` is preserved to ensure Windows error reporting remains intact.
- **Bounded Pagefile Management:** Introduces opt-in dynamic pagefile growth before commit limits are breached. Gated behind administrator checks, a minimum 15 GiB free disk reserve, atomic backups, and pending-reboot verification without suppressing recovery.
- **15-FPS Engine Flag Request:** Safely merges `DFIntTaskSchedulerTargetFps: 15` into `ClientAppSettings.json` with automatic backup and atomic replacement, accurately logging the status as `REQUESTED_ONLY` based on the official Roblox Player allowlist.
- **Atomic Hot Reload:** Pagefile configuration changes participate in runtime hot reload with atomic validation, retaining previous valid policies if any section is invalid.

## v1.0.4 — Animated Startup, Rich Alert Dashboard & Account Fallback Detection

- **Launcher Startup Animations:** Sleek ASCII art banner, graduated color transitions, and animated phase indicators (`INIT`, `SYNC`, `VERIFY`, `READY`, `PROGRESS`) on startup.
- **Enhanced Dashboard Multi-Alert System:** Prominent colored alert cards (Red for critical errors like `DISCONNECTED`, `VOLT_STARTUP_ERROR`, `COMMIT PRESSURE`; Yellow for warnings), displaying up to 2 simultaneous system issues.
- **Multi-Tier Account Fallback Detection:** Eliminates "Unmapped" instances by cascading through Volt control status, TrackerId matching, Roblox client log file analysis (`userid:<id>`), and Volt SQLite document database queries (`Arkuzo-Volt-Probe.py --user-id`).
- **CommandLine Parser Robustness:** Handles duplicate `browsertrackerid` parameters in modern Roblox launch commands.

## v1.0.3 — Production Multi-Instance Stability & Self-Healing Launcher

- **Config Lock:** Hard enforcement of calibrated multi-instance thresholds (`apply_graphics_flags: true`, `pressure_percent: 88`, `pressure_min_private_mb: 4000`, `startup_error_timeout_sec: 5`, `disconnect_timeout_sec: 5`, `cooldown_sec: 90`, `max_recycles_per_hour: 20`) to prevent degradation and false recycling loops on 8+ clients.
- **Visual Dashboard Lock Indicator:** Display `[CONFIG LOCKED]` prominently in the console header.
- **Dynamic Roblox Path Detection:** Discover active Roblox installations (including `C:\ProgramData\roblox\roblox`) dynamically and automatically merge low-graphics texture/MSAA flags.
- **Recovery Budget Rollback:** Atomic rollback of hourly recovery budget counters when recovery is refused or targets are unmapped, preventing budget exhaustion lockouts.
- **Self-Healing Launcher:** Launcher automatically repairs cached runtime assets directly from verified release downloads if local files differ or suffer hash mismatches.

## v1.0.2 — Executable branding and embedded application icon

- Rename single-file launcher executable to `ArkuzoMemorySaver.exe`.
- Embed high-resolution application icon (16px to 256px) generated from the official emblem.
- Remove legacy `Run.exe` executable artifacts.
- Update release packaging and verification suites.

## v1.0.1 — Cookie-dead account isolation

- Add a separate red `COOKIE DEAD` account section, including accounts without a running client.
- Read Volt's explicit dead-session status without inferring a permanent ban or attempting captcha bypass.
- Keep dead accounts paused with retained recovery history; release their handoff only after verified idle/no-process safety checks.
- Avoid letting an unrelated dead session disable recovery for otherwise eligible accounts.
- Accept valid newly imported accounts without tracker/launch history while keeping them ineligible for automatic launch.
- Preserve configuration and account retry accounting across runtime updates.

## v1.0.0 — Initial release

### Distribution and updates

- Root `Run.exe` provides the end-user entry point with a self-contained Windows x64 launcher; no separate .NET installation is required.
- First-start runtime installation retrieves the latest stable official release's runtime ZIP and checksum and verifies SHA-256 before installation.
- Versioned runtime files are cached under `app/versions/`; user configuration, logs, and recovery state remain separately under `data/`.
- Existing user configuration is never overwritten by updates. Malformed JSON prevents saver startup rather than silently resetting defaults; downloading a new runtime does not replace the invalid user file.
- Legacy `config.json` beside `Run.exe` is copied into `data/` only when no persistent configuration already exists; the original file is retained.
- Offline startup uses an already installed, validated cached runtime; first initialization requires internet access.

### Monitoring and memory policy

- Distinct resident-working-set, private-memory, and OS commit observations.
- Eligible working-set trimming with a 600 MB soft target, 45-second per-client interval, five-minute per-client warmup, and staggered trim spacing.
- Hard-cap enforcement disabled by default; loading, unresponsive, and recognized startup-error clients are skipped for ordinary trimming.
- Sustained private-memory candidate policy at 6,000 MB for 60 seconds, with separate OS commit-pressure selection at 82% and a critical-pressure path.
- Separate observation timers for startup errors, unresponsive windows, and correctly bound disconnect evidence.

### Volt integration and safety

- Read-only Python 3 state probe and verified Account Manager controls; basic monitoring and eligible trimming remain available without Python or Volt.
- Exact account/process-generation mapping and fresh readiness checks before destructive recovery.
- Recovery restricted to verified eligible accounts; missing-account restoration requires opt-in, a previous launch, unique identity, and a confirmed idle state.
- Minimum 30-second native relaunch delay with preservation of a larger user delay.
- Serialized account handoffs, persistent cooldown/hourly budgets, and bounded 90–900 second default retry backoff.
- Separate observations for closure, replacement process creation, and continuous game-readiness confirmation.
- Singleton protection and fail-closed recovery when control, mapping, audit logging, or recovery state cannot be verified.
- No credential collection, authentication-ticket replay, or direct writes to Volt's database.

### Documentation

- End-user setup, configuration reference, conservative troubleshooting, and privacy-safe issue-reporting guidance.
- A clearly labeled illustrative status example in place of live account screenshots.

### Limits

Working-set trimming does not repair leaks or release private allocations. Policy thresholds do not guarantee a RAM ceiling or crash prevention. Readiness confirmation is not an endurance guarantee. Volt launch guards, seat expiry, authentication failures, and third-party faults remain outside any promised fix.
