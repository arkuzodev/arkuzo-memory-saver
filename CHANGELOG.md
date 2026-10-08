# Changelog

Changes for **Arkuzo Memory Saver with Volt Integration** are recorded here.

## v1.0.6 — Recovery observation continuity and memory policy

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
