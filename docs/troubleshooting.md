# Troubleshooting

[← README](../README.md) · [Configuration](configuration.md)

## Start with the safe checks

- Note the installed version, the visible warning, and when it occurred.
- Confirm you started the official root `Run.exe` from a writable folder.
- Inspect local logs under `data/`, but sanitize them before sharing.
- Keep one saver controller running. Do not erase configuration or the recovery journal to bypass an error.
- Distinguish working-set RAM, private memory, and OS commit utilization. A smaller RAM reading after trimming does not prove the underlying allocation pressure is gone.

## Startup and updates

### First start fails without internet

The first start needs access to the official stable release's runtime ZIP and checksum. There is no installed runtime to fall back to yet. Restore connectivity and try again; do not substitute an unverified archive from another source.

For an already initialized installation, offline startup requires a previously installed, validated cached runtime under `app/versions/`. A corrupted or incomplete cache is not a usable offline fallback. Preserve `data/` while addressing a runtime download or cache problem.

### A runtime checksum does not match

The launcher must reject that runtime. Check connectivity, proxy interference, and whether you obtained `Run.exe` from the [official release page](https://github.com/arkuzodev/arkuzo-memory-saver/releases/latest). Retry the official download when online. Never edit the checksum or bypass hash verification to make an archive install.

SHA-256 verifies agreement with the published checksum; it does not make an unsigned executable signed or establish trust independently of the release source.

### The saver refuses to start because configuration is invalid

Your existing `data/config.json` is intentionally preserved. Stop the saver, back up the file, and correct malformed JSON or invalid values, or restore your own known-good backup. JSON cannot contain comments or trailing commas. See [configuration](configuration.md).

The updater leaves your file untouched; the saver refuses malformed JSON rather than silently resetting your policy. Do not delete the file merely to get past validation, and do not confuse source `config/defaults.json` with your installed user configuration.

### SmartScreen or security software warns about Run.exe

An unsigned executable may trigger a reputation warning. Verify the official download source, review the warning, and follow your device or organization's policy. If protection blocks the binary, retain that protection and investigate the reported detection. **Do not globally disable SmartScreen or antivirus, and do not add blanket folder exclusions.**

### The folder cannot be written

Keep `Run.exe` in a folder where your user can create `app/` and `data/`. A read-only location or organization-managed restriction may prevent installation or audit writes. Choose an appropriate writable location; do not assume running everything as administrator is the solution.

## Monitoring and trimming

### RAM is above 600 MB

That is not itself a failure. **600 MB is a soft working-set target, not an enforced hard cap**, and `hard_limit` is disabled by default. Active clients can fault pages back into RAM after a trim. Private allocations are not released by working-set trimming.

### No trim occurs after 45 seconds

The 45-second interval applies only to eligible clients. Check:

1. The **client's** age, not how long the dashboard has been open. A newly launched client has its own five-minute warmup.
2. Whether trimming is enabled and resident working set is above the target.
3. Whether the client has a present, responsive window and no recognized startup-error dialog.
4. Global spacing and other eligible clients. Trims are staggered rather than all performed simultaneously.

A displayed countdown reaching zero is not proof that every other gate has passed. Do not shorten startup grace just to force a trim while the game is loading.

### Private memory exceeds 6,000 MB, but there is no immediate restart

The ordinary private-memory policy requires **60 seconds of continuous observation** above the threshold, with startup grace and recovery safety gates. Observation gaps reset sustained-fault timers. System commit pressure has separate selection paths, but it still does not waive account verification, logging, journal, or budget requirements.

The **82% OS commit threshold** selects candidates; it is not a hard ceiling, a physical-RAM percentage, or a guarantee that a safe candidate can be recovered in time.

### A client has zero CPU

Zero CPU alone is not evidence of a failed game. The saver does not use it as sufficient reason to restart a responsive client. Review window responsiveness and correctly bound error/disconnect evidence instead.

## Volt integration

### “Volt account control unavailable” or an unmapped client

This is a safety status, not proof that Volt is stopped. During loading, UI changes, or an incomplete inventory refresh, control may be temporarily unavailable.

- Confirm Python 3 is on `PATH`. In a new terminal, run the read-only checks below; at least one command should identify Python 3 rather than an unavailable app alias.
- Start Volt and keep **Account Manager accessible**, with its account rows and controls available to UI Automation.
- Confirm intended accounts have valid sessions, auto-relaunch opt-in, and a previous launch.
- Allow loading to finish and observe a fresh status. Check for duplicate or ambiguous account/process mappings.

```powershell
python3 --version
python --version
```

Without Python or Volt, basic monitoring and eligible trimming remain available. Destructive recovery is refused when account control cannot be proven. Do not modify Volt's database or bypass mapping checks to clear a warning.

### “Another ArkuzoSaver controller is already running”

Singleton protection applies across saver copies. Find the existing saver console and any supervising process, then stop the existing controller normally before switching versions or folders. Do not remove the mutex, kill unrelated processes, or run a second controller against the same clients.

### “Recovery blocked” or accounts remain missing

Possible causes include cooldown/hourly budgets, an unresolved handoff, invalid recovery state, unavailable audit logging, or an account that cannot be uniquely restored. Review the reason before changing policy.

Default recovery attempts are spaced by a **240-second cooldown**, with **10 per hour**. Missing-account launch retries have a separate **six-per-hour** budget and persistent **90–900 second backoff**. Saver restarts do not reset journaled budgets or unresolved state.

When one account is unresolved, the saver avoids collateral closures of other accounts. Do not erase the journal or restart the whole healthy launcher to force one account through. Confirm the missing account is opted in, previously launched, valid, uniquely mapped, and demonstrably idle—not still connecting or counting down.

### The native relaunch delay stays larger than 30 seconds

That is intentional. The integration requests a minimum of 30 seconds and preserves a larger existing user delay. It verifies UI and persisted readback rather than assuming a change succeeded. A larger delay can legitimately postpone idle-state eligibility.

### A launch is requested, but restoration is not confirmed

A request is not a result. The saver separately observes the exact account's new process generation, connected socket, responsive non-error window, and correctly bound server-acceptance evidence for a continuous readiness interval (30 seconds by default).

A live process or Volt's “Connected” label may coexist with a startup notice or a game that never loaded. Check the actual window and error state. Do not label an accepted request or a brief connection an endurance test.

### Seat limits, seat expiry, authentication rejection, or launch guards

Arkuzo Memory Saver does **not** guarantee a fix for these conditions. A seat-limit message indicates a rejection; it does not establish a universal seat-release delay. The 30-second minimum native delay and bounded backoff are conservative policies, not proof that a lease has expired or a launch guard is disabled.

Review Volt's own visible error and supported account/session controls. Never replay authenticated launch commands, extract credentials, or write to its database. Leave ambiguous clients untouched rather than trying to force a return path.

## Logs and recovery state

### Audit writes fail or the recovery journal is invalid

Destructive recovery must remain blocked. Check available disk space and access to `data/`, and preserve the affected files for local diagnosis. Stop the saver before restoring a known-good backup or moving the installation. Do not truncate the journal to clear an unresolved handoff or reset retry limits.

### Reporting an issue safely

Use the [issue tracker](https://github.com/arkuzodev/arkuzo-memory-saver/issues). Include:

- Installed version, Windows architecture, and whether Python 3 is available.
- Whether Volt Account Manager was accessible and the client was loading.
- The sanitized warning/event type, relative timing, and relevant policy values.
- What you expected and what actually happened, distinguishing a request, a confirmed exit, a replacement process, and readiness confirmation.

Review every attachment. Remove account names/IDs, cookies, tokens, authentication tickets, server links, raw launch command lines, and personal machine paths. Do not upload Volt's database, live account screenshots, or an unreviewed `data/` folder. Prefer a small redacted text excerpt or a clearly labeled illustrative example.
