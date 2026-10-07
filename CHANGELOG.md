# Changelog

Changes for **Arkuzo Memory Saver with Volt Integration** are recorded here.

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
