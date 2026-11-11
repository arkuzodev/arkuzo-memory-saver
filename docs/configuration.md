# Configuration

[← README](../README.md) · [Troubleshooting](troubleshooting.md)

## Persistent configuration

The launcher initializes **`data/config.json`** from packaged defaults only when creating a new configuration. Existing user configuration is never overwritten by an update. Runtime versions are installed under **`app/versions/`**; configuration, logs, and the recovery journal remain in **`data/`**, outside those version directories.

`config/defaults.json` in the source repository supplies release defaults. It is not the configuration of an already installed user instance. Do not edit files under `app/versions/` to customize behavior: those are versioned runtime files.

### Safe editing

1. Stop the saver normally. Keep a backup of `data/config.json`.
2. Edit the existing JSON file, retaining the surrounding structure and unrelated keys.
3. Use JSON booleans (`true`/`false`) and numbers, with no comments or trailing commas.
4. Restart through `ArkuzoMemorySaver.exe` and check startup diagnostics before relying on the changed policy.

**Malformed existing JSON makes the saver refuse to start; the updater preserves it even if the runtime update completes.** It is not silently reset. Restore your own known-good backup or correct the reported error. Do not delete the configuration to make an error disappear: doing so loses your selected policy and exclusions.

### Example excerpt — not a complete configuration

Merge these keys into the matching sections of an existing valid configuration. This illustrative excerpt is not a replacement for the full file.

```json
{
  "settings": {
    "target_ram_mb": 600,
    "trim_enabled": true,
    "trim_every_sec": 45,
    "hard_limit": false
  },
  "health": {
    "warmup_sec": 90,
    "private_limit_mb": 6500,
    "private_limit_sustain_sec": 60,
    "pressure_percent": 88
  },
  "recovery": {
    "relaunch_delay_sec": 30,
    "retry_base_sec": 90,
    "retry_max_sec": 900,
    "ready_stable_sec": 30
  }
}
```

The tables below describe the current repository defaults in `config/defaults.json`; packaged releases and existing installations may use older values. Memory values use the engine's MB convention: bytes divided by 1,048,576. Timings are seconds unless the key explicitly uses milliseconds.

## `settings`: ordinary resource management

| Key | Default | Meaning |
| --- | --- | --- |
| `target_ram_mb` | `600` | Soft resident-working-set target for eligible trimming; not a total-memory ceiling. |
| `trim_enabled` | `true` | Enables working-set trim attempts. |
| `trim_every_sec` | `45` | Per-client trim eligibility interval; not a promise of an action exactly every 45 seconds. |
| `hard_limit` | `false` | Default policy does not impose an enforced hard working-set cap. Leave disabled unless you understand and test the impact. |
| `priority` | `"BelowNormal"` | Requested process scheduling priority. |
| `cores_per_instance` | `2` | Requested per-instance logical-CPU affinity allocation, subject to available hardware. |
| `poll_ms` | `350` | Main polling interval in milliseconds; some observations run less frequently. |
| `minimize_on_launch` | `false` | Whether the saver requests client-window minimization. |
| `apply_graphics_flags` | `true` | Requests graphics-flag application; writing a requested flag does not prove that Roblox honors it. |
| `memory_priority` | `"Low"` | Windows memory priority for clients (`VeryLow`, `Low`, `Medium`, `BelowNormal`, `Normal`). Lower values are evicted first under pressure. Restored on exit. |
| `adaptive_trim` | `true` | Trims three times as often (never below 15 s) while free physical RAM is scarce. |
| `pressure_trim_available_percent` | `20` | Free physical RAM percentage below which adaptive trimming applies. |

Everything in `settings` except `hard_limit` and `apply_graphics_flags` is applied to a running saver within about 10 seconds of saving. A configuration that predates `memory_priority` or `adaptive_trim` inherits them from its `selected_preset`.

Trimming waits for the **individual client's** warmup, checks its current resident memory against the soft target, and requires a present, responsive window without a detected startup-error dialog. Global spacing staggers eligible clients. A trim can cause subsequent page faults as needed pages return to RAM. It does not decommit private allocations or repair the cause of memory growth.

## `health`: recovery-candidate policy

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Enables health evaluation; destructive recovery still requires verified recovery capability. |
| `private_limit_mb` | `6500` | Private-memory recovery-candidate threshold (6500 MiB); not an enforced allocation limit. |
| `private_limit_sustain_sec` | `60` | Continuous observation required for an ordinary private-limit violation. |
| `pressure_percent` | `88` | OS **commit** utilization threshold for pressure-based candidate selection, not physical-RAM usage. |
| `pressure_min_private_mb` | `4000` | Minimum private footprint for the pressure-selection path. |
| `warmup_sec` | `90` | Startup grace in seconds for ordinary trimming and routine health evaluation. |
| `hang_timeout_sec` | `120` | Continuous unresponsive-window observation before a hang becomes a candidate. |
| `startup_error_timeout_sec` | `5` | Separate continuous observation grace for a recognized startup-error dialog. |
| `disconnect_timeout_sec` | `5` | Grace after a detected, correctly bound in-game disconnect or kick. |
| `cooldown_sec` | `90` | Spacing between budgeted recovery attempts. With Arkuzo as the launcher, a client verified kicked or disconnected is closed without it. |
| `max_recycles_per_hour` | `60` | Hourly budget for closing clients that are still running (hung, over the memory limit, commit pressure, startup error, farm freeze); restarting the monitor does not reset persisted accounting. Clients that already exited are never counted. With Arkuzo as the launcher, a client verified kicked or disconnected is neither counted nor held back. The default was 20 before this version; an existing `config.json` keeps its value (at least 20 with `config_lock`). |
| `trim_spacing_sec` | `2` | Minimum global spacing between successful trim attempts. |
| `farm_freeze_enabled` | `true` | Farm-wide freeze fast path (below). `false` leaves every hang to `hang_timeout_sec`. |
| `farm_freeze_confirm_sec` | `35` | How long a farm-wide freeze must last, after its last client froze, before recycling starts. 20-120; at least 30 with `config_lock`. |
| `farm_freeze_min_clients` | `3` | Minimum number of clients that must freeze together. They must also be more than half of the clients that were already running when they froze. |
| `farm_freeze_onset_window_sec` | `15` | Clients count as freezing together when their freezes start within this window. |
| `farm_freeze_max_cpu_percent` | `5` | Highest average CPU (dashboard scale, share of all logical CPUs) since the freeze began. Most logged frozen clients averaged under 0.1%; one that froze while starting kept 3.7%. |
| `farm_freeze_spacing_sec` | `20` | Gap between one recycled client's exit and the next recycle, and so between Volt's relaunches. 10-60; at least 15 with `config_lock`. With 9-10 clients, 16 fits every recycle in before the clients quit by themselves. |
| `farm_freeze_refreeze_sec` | `900` | A farm that freezes again within this time after a fast recovery gets the normal `hang_timeout_sec` instead. `0` turns that fallback off. A freeze caused by a new remote-desktop disconnect is exempt. |
| `farm_freeze_remote_confirm_sec` | `20` | Confirmation for a farm-wide freeze that began right after a remote-desktop disconnect (no such freeze ever cleared by itself). Never longer than `farm_freeze_confirm_sec`. 10-120; at least 15 with `config_lock`. |
| `farm_freeze_remote_window_sec` | `60` | A freeze counts as caused by a disconnect when its first client froze between 10 s before and this long after it. |
| `remote_hold_max_sec` | `600` | While the saver's own session is a disconnected Remote Desktop (RDP) session, hang recovery, the fast path and missing-account launches wait for it to reconnect, for at most this long. Commit pressure still recycles. `0` turns the hold off. |
| `keep_display_awake` | `true` | While clients run, ask Windows to keep the display and the PC on (process-scoped; the power plan is not changed). |

Warmup is not an unconditional ban on all recovery paths. Recognized startup errors and disconnects use their own observation timers. Current OS commit pressure is evaluated separately; the engine also has a critical-pressure path at 90% commit utilization that can bypass ordinary startup grace. Every destructive action still needs valid identity, launcher readiness, audit logging, journal state, and budget checks.

**Farm-wide freezes.** A display change (a Chrome Remote Desktop disconnect, a driver reload) can freeze every client at the same moment at 0% CPU. None comes back by itself; each quits after about 3 minutes and Volt then relaunches all of them at once, which brings up its "Roblox started before Volt could connect" notice on most of them. When at least `farm_freeze_min_clients` clients, and a majority of the farm, freeze within `farm_freeze_onset_window_sec` and stay frozen at near-zero CPU for `farm_freeze_confirm_sec`, the saver recycles them early, one every `farm_freeze_spacing_sec`, so Volt relaunches them one at a time. Clients that freeze together while still starting count too, once they have answered at least once; the saver then waits until Volt has started no client for 30 s. Each recycle still needs the exact Volt account mapping, a journal entry written before the close, the hourly budget and an account that isn't quarantined; monitor-only mode never recycles. See [farm-freeze recovery](farm-freeze-recovery.md) for the measurements behind these defaults, and [remote desktop disconnects](remote-desktop.md) for the remote-session settings.

The **88% threshold is a candidate-selection policy, not a guarantee**. OS commit is distinct from physical RAM: a low resident working set does not demonstrate safe commit headroom. Sample gaps longer than 30 s or a clock reversal break continuous-observation timers rather than counting unobserved time as proof of a sustained fault.

## `recovery`: Volt handoff and restoration

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Enables guarded account recovery. Disabling it blocks destructive recovery. |
| `restore_missing` | `false` | With Volt as the launcher: allows verified launch requests for eligible missing accounts that were launched before. With Arkuzo as the launcher this setting is not used: a running farm launches every opted-in account. |
| `restore_wait_sec` | `90` | Native-launcher grace before a missing-account request can be considered. |
| `relaunch_delay_sec` | `30` | Minimum requested native Volt relaunch delay. A larger existing user delay is preserved. |
| `retry_base_sec` | `90` | Initial bounded retry delay. |
| `retry_max_sec` | `900` | Default upper bound of increasing retry backoff. |
| `retry_max_per_hour` | `6` | Launch-request budget per hour, shared by all accounts and separate from the client-termination budget. Not used with Arkuzo as the launcher: there the launch spacing is the only limit, so an outage never parks the farm for the rest of the hour. |
| `ready_stable_sec` | `30` | Continuous restoration-readiness confirmation interval. |
| `excluded_account_ids` | `[]` | Account identifiers excluded from restoration eligibility. Keep real identifiers private. The Control Center's per-account toggle edits this list. |
| `abandon_after_retries` | `8` | Volt only: failed recovery attempts after which an account is quarantined and stops blocking other accounts. With Arkuzo as the launcher no account is ever quarantined (see below). |
| `abandon_after_sec` | `5400` | Volt only: unresolved recovery age after which the same quarantine applies. |
| `quarantine_sec` | `1800` | Volt only: how long a quarantined account is left untouched before normal recovery resumes. `0` releases it without a quarantine. |

## `accounts`: who launches clients

| Key | Values | Meaning |
| :--- | :--- | :--- |
| `provider` | `auto` (default), `arkuzo`, `volt` | `arkuzo`: the saver launches and relaunches the accounts in `data/accounts.json` itself. `volt`: Volt's account manager does, as before. `auto`: Arkuzo once `data/accounts.json` holds an account, unless Volt runs with auto-relaunch on; otherwise Volt. An active Arkuzo farm stays on Arkuzo if Volt starts later. |

Arkuzo's account list, farm settings (place, launch spacing, relaunch delay, launch timeout) and private servers live in `data/accounts.json`, managed on the Control Center's Accounts page; see [accounts without Volt](accounts.md). The Roblox build Arkuzo launches is in the same file, set on the Roblox tab ([Roblox versions](roblox-versions.md)):

| Setting (`accounts.json` → `settings`) | Values | Meaning |
| :--- | :--- | :--- |
| `robloxVersion` | `auto` (default) or `version-<16 hex>` | `auto`: the build running clients use, otherwise the newest complete installed build. A version: exactly that build, launched directly unless `robloxProtocol` points `roblox-player:` at it (never through Roblox's own launcher). |
| `robloxVersionFollow` | empty (default), `latest`, `exploit:<weao.gg id>` | Follow Roblox's newest build or the build an exploit supports: the Control Center installs it into Arkuzo's folder and sets `robloxVersion` to it (checked every 10 minutes). A build chosen by hand clears it. |
| `robloxFollowRestart` | `false` (default), `true` | `true`: when the build changes, the farm's clients are closed (like Close all) so they relaunch on it right away. `false`: they switch as they relaunch. |
| `robloxProtocol` | `false` (default), `true` | `true`: `roblox-player:` and `roblox:` (HKCU only) start the pinned build; the previous keys are saved to `data/roblox-protocol-backup.json` and restored when this is off or the build is Auto. |
| `robloxVersionFallback` | `false` (default), `true` | When the pinned build is missing: `false` holds launches (and says why), `true` launches the Auto choice instead. |
| `robloxVersionsDir` | empty (default) or an absolute folder | Where the Roblox tab installs builds (`<folder>\Versions`); empty is `%LOCALAPPDATA%\Arkuzo\Roblox`. Never inside Roblox's own install folders. |
| `arrangeOverflow` | `minimize` (default), `overlap` | Window layout with more clients than fit side by side: `minimize` tiles as many as fit without overlap and minimizes the rest; `overlap` keeps all on screen, overlapping evenly ([accounts](accounts.md#window-layout)). | With `arkuzo`, the `recovery` section's journal and readiness settings still apply. Its Volt-specific waits (`restore_wait_sec`, `relaunch_delay_sec`, `retry_base_sec`) are replaced by the account list's relaunch delay, launch spacing and launch timeout.

**Built-in limits with `arkuzo`** (the goal is the most time in game per account: relaunches never back off):

- **No quarantine.** An account whose launches keep failing is retried at the normal spacing, forever. Launches go in a fair order (the account tried least recently first), so a failing account never takes the others' turns. `abandon_after_*` and `quarantine_sec` apply to Volt only; quarantines saved by an earlier version are cleared for vault accounts.
- **No hourly launch cap.** The launch spacing (12 s by default) is the only limit; `retry_max_per_hour` is not used.
- **Refused launches retry quickly.** When Roblox refuses the ticket (or doesn't answer), or the client closes before it is in game, the account is launched again after the relaunch delay (8 s). Only a launch that produces nothing at all waits the launch timeout (120 s). Moderated and signed-out accounts are never retried.
- **Kicked clients don't wait.** A client verified kicked or disconnected (from its log or the executor signal) is closed without the cooldown or the hourly budget and is not counted against them; all such clients are closed in the same pass. Clients that already exited go straight to the relaunch queue.
- **No serial handoff.** A client that maps exactly to one account (its own tracker, same process ID and start time) can be recovered while other accounts wait for their relaunch. Clients that are still running (hung, over the memory limit) keep `cooldown_sec` and `max_recycles_per_hour`, one closure per pass. Volt keeps the serial handoff gate and all of the limits above.
- **Launch timing.** The launch step runs on every pass while accounts wait, so `launchDelaySec` is the real gap between launch requests (it used to be up to 10 s more); each client starts when Roblox answers its ticket request, usually within a second. The ticket request runs in the background, one at a time, and the saver keeps watching the farm meanwhile.
- **Kicked means verified.** A disconnect counts as a kick for the fast path when the Roblox log reports it (a client-initiated leave, code 285, never does) or the executor signal reports an error message or prompt. A signal that only says the connection object went away (which an ordinary teleport can also cause) keeps the cooldown and budget.

## `pagefile`: guarded virtual memory scaling (bounded)

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `enabled` | `true` | Enabled in production defaults; administrator, ownership, disk-reserve, audit, and per-boot gates still apply. Missing policy remains disabled. |
| `growth_step_mb` | `4096` | Size to add per growth operation (4 GiB). |
| `max_file_mb` | `163840` | Maximum managed size for an individual pagefile (160 GiB), including single-volume hosts. |
| `max_total_mb` | `163840` | Maximum cumulative managed pagefile allocation (160 GiB). |
| `reserve_free_bytes` | `16106127360` | Minimum free disk space reserve on the pagefile volume (15 GiB). Growth is refused if remaining disk space would drop below this. |
| `reserve_free_percent` | `10` | Minimum free disk percentage reserve required. |
| `trigger_percent` | `80` | OS commit utilization trigger percentage evaluated before candidate recycling. |
| `cooldown_sec` | `3600` | Cooldown period between pagefile modification requests. |
| `max_requests_per_boot` | `1` | Bounded per-boot growth request limit to prevent runaway expansions. |
| `max_boot_growth_mb` | `4096` | Maximum total growth permitted within a single Windows boot session. |

The **160 GiB setting is a pagefile ceiling, not an exact OS commit-limit target or an immediate 160-GiB allocation**. OS commit capacity also depends on physical RAM. The existing 4-GiB-per-boot budget and cooldown remain unchanged. Windows-managed pagefiles and pagefiles already larger than the configured ceiling are never reduced or taken over. Disk growth must preserve the greater of 15 GiB and 10% of the target volume. Configuration-only growth is reported as `PendingReboot`; the saver does not reboot Windows.

Existing `data/config.json` files are preserved. To adopt these values, use an engine revision that accepts a 163840-MB per-file ceiling, back up the existing configuration, and merge `health.private_limit_mb: 6500` plus `pagefile.enabled: true`, `pagefile.max_file_mb: 163840`, and `pagefile.max_total_mb: 163840`. A source push alone does not replace a published runtime or an installed user configuration.


A larger Volt delay can extend the time before an account becomes provably idle. The adapter verifies the delay using both accessible UI controls and read-only persisted state. **Thirty seconds is not proof that a seat lease has expired or that a launch guard cannot trigger.**

Retries and unresolved handoffs are persisted in the recovery journal. Do not delete that journal to reset a cooldown or budget. While an account restoration is unresolved, other accounts are protected from collateral closures; a confirmed unhealthy replacement of that same account can be considered through the existing safety gates and backoff.

## Account eligibility and readiness

Keep **Volt Account Manager accessible** and Python 3 available on `PATH`. Recovery requires auto-relaunch opt-in, a valid session state, and exact account/process mapping. Missing-account restoration additionally requires a previous launch and a uniquely verified idle account with no conflicting live process. Invalid or ambiguous inventory can block recovery even if one account appears eligible.

Arkuzo Memory Saver reads Volt's account state through a read-only probe and uses verified Account Manager controls. It does not replay credentials or authentication tickets and does not directly modify Volt's database.

Restoration confirmation requires all of the following for the exact account:

- A replacement process generation, tracked by PID **and start time**, rather than merely a reused PID.
- A connected launcher socket bound to that process.
- A present, responsive window without a detected startup error or disconnect.
- Correctly bound server-acceptance evidence from the client's log.
- Continuous successful observation over `ready_stable_sec`.

A launch-button invocation, process creation, or “Connected” label alone does not satisfy these checks. Passing them confirms the observed readiness interval—not long-term stability, useful gameplay, or an endurance test.

## Command-line logging options

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-MaxLogMB` | `10` | Size of one diagnostic log part; each session keeps its newest five parts. |
| `-MaxLogSessions` | `200` | At start, older sessions' logs in `Arkuzo-Logs` are deleted beyond the newest 200 sessions... |
| `-MaxLogTotalMB` | `300` | ...or beyond 300 MB in all, whichever comes first. The current session is never deleted. A long farm session writes about 25–45 MB a day, so the defaults keep roughly a week of a busy farm (several days at the least); many short sessions (restarts) are small and mostly limited by the size cap. Only `Arkuzo-<session>-part<N>.log` files are touched. |

A log write that fails (disk full, the file locked) pauses logging for 5 s and then continues in a new part. While a write is failing, closures wait: every closure still needs a successful audit write.

## Changes and troubleshooting

Change one policy at a time and observe both private memory and OS commit. Lower thresholds can increase churn; shorter delays can increase repeated failures. No threshold repairs a game leak, a driver fault, an authentication rejection, or Volt's internal launch behavior.

For invalid JSON, blocked recovery, offline startup, or missing dependencies, use the [troubleshooting guide](troubleshooting.md). Do not work around a failed safety check by deleting state, changing identity rules, or running a second controller.
