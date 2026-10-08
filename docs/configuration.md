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
| `cooldown_sec` | `90` | Spacing between budgeted recovery attempts. |
| `max_recycles_per_hour` | `20` | Hourly recovery-attempt budget; restarting the monitor does not reset persisted accounting. |
| `trim_spacing_sec` | `2` | Minimum global spacing between successful trim attempts. |

Warmup is not an unconditional ban on all recovery paths. Recognized startup errors and disconnects use their own observation timers. Current OS commit pressure is evaluated separately; the engine also has a critical-pressure path at 90% commit utilization that can bypass ordinary startup grace. Every destructive action still needs valid identity, launcher readiness, audit logging, journal state, and budget checks.

The **88% threshold is a candidate-selection policy, not a guarantee**. OS commit is distinct from physical RAM: a low resident working set does not demonstrate safe commit headroom. Sample gaps or a clock reversal break continuous-observation timers rather than counting unobserved time as proof of a sustained fault.

## `recovery`: Volt handoff and restoration

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Enables guarded account recovery. Disabling it blocks destructive recovery. |
| `restore_missing` | `true` | Allows verified launch requests for eligible missing accounts. |
| `restore_wait_sec` | `90` | Native-launcher grace before a missing-account request can be considered. |
| `relaunch_delay_sec` | `30` | Minimum requested native Volt relaunch delay. A larger existing user delay is preserved. |
| `retry_base_sec` | `90` | Initial bounded retry delay. |
| `retry_max_sec` | `900` | Default upper bound of increasing retry backoff. |
| `retry_max_per_hour` | `6` | Per-account launch-retry budget, separate from client-termination budgets. |
| `ready_stable_sec` | `30` | Continuous restoration-readiness confirmation interval. |
| `excluded_account_ids` | `[]` | Account identifiers excluded from restoration eligibility. Keep real identifiers private. |

## `pagefile`: guarded virtual memory scaling (bounded)

<<<<<<< HEAD
| Key | Default | Notes |
| :--- | :--- | :--- |
| `enabled` | `true` | Enabled by default with strict 15 GiB disk headroom safeguards and audit logging. |
=======
| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Enabled in production defaults; administrator, ownership, disk-reserve, audit, and per-boot gates still apply. Missing policy remains disabled. |
>>>>>>> origin/main
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

## Changes and troubleshooting

Change one policy at a time and observe both private memory and OS commit. Lower thresholds can increase churn; shorter delays can increase repeated failures. No threshold repairs a game leak, a driver fault, an authentication rejection, or Volt's internal launch behavior.

For invalid JSON, blocked recovery, offline startup, or missing dependencies, use the [troubleshooting guide](troubleshooting.md). Do not work around a failed safety check by deleting state, changing identity rules, or running a second controller.
