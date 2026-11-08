# Farm-wide freeze recovery

A display change (a Chrome Remote Desktop disconnect, a driver reload) can freeze every Roblox client on the host at the same moment. This page records what the saver logs show about those freezes, what Volt needs to relaunch a farm cleanly, how the saver now handles them, and the downtime measured before and after. Settings are in [configuration](configuration.md#health-recovery-candidate-policy) (`health.farm_freeze_*`).

## What the logs show

Four farm-wide freezes are in `data/Arkuzo-Logs` (23 Oct 23:16, 26 Oct 13:19 and 18:10, 27 Oct 07:38), with 6-8 clients each.

- **Every client stops responding within 2-9 s of the others, at 0% CPU** (the average while frozen was under 0.1% on the dashboard scale). None ever answered again.
- **Each client quits by itself 195-201 s after it froze** (exit code 0), whether or not the saver did anything. With `hang_timeout_sec` at 180 s the saver closed one client at about 190 s; the rest quit seconds later.
- **Volt relaunches an account 31-42 s after its client exits.** All the self-exits came within 3 s of each other, so Volt started 5-7 clients within about 10 s.
- **Launches that close together bring up Volt's "Roblox started before Volt could connect" notice.** Across all logs, 18 of the 26 fresh launches that had another launch less than 10 s away got it (15 of 19 under 3 s). None of the 56 launches with 10 s or more to the next one did. Within a burst, the first launch connects and the ones after it fail. The notice was behind 18 of the 21 recoveries during the four freezes.
- **The saver then fixed those one at a time, 43-50 s apart.** The reason is the mapping gate, not the handoff gate: every gap logged `recovery-mapping`, never `recovery-handoff`. While Volt counts down or connects a relaunch, that account's row is neither Connected nor Idle, so the adapter reports the farm as not globally mapped and `Get-ArkuzoControlledAccount` maps no client at all. The next closure came 4-6 s after the previous replacement started.

### Downtime today

Measured per account from the farm's first hang onset until a replacement client of that account is in game (window open, responsive, no notice):

| Incident | Clients | Mean | Last account | Last `ACCOUNT_RESTORED_VERIFIED` | Startup notices |
| --- | --- | --- | --- | --- | --- |
| 23 Oct 23:16 | 8 | 339 s | 480 s | 521 s | 4 |
| 26 Oct 13:19 | 7 | 384 s | 513 s | 549 s | 5 |
| 26 Oct 18:10 | 6 | 330 s | 457 s | 477 s | 4 |
| 27 Oct 07:38 | 6 | 338 s | 436 s | 473 s | 4 |

That is about **5.8 minutes per account and 7.3-8.6 minutes until the whole farm is back.** The verified restore adds `ready_stable_sec` (30 s) and the 10 s outcome cadence on top of being in game.

### How long to confirm

Some correlated hangs do clear. Counting groups of 3 or more clients that froze within 15 s, made up a majority of the farm, and were still frozen a given time after the last one froze:

| Still frozen after | Groups | Groups where a client answered again later |
| --- | --- | --- |
| 15 s | 49 | 5 (latest at 61 s) |
| 20 s | 46 | 2 |
| 30 s | 44 | 0 |
| 40 s | 44 | 0 |

The fast path waits 35 s, and checks each client again right before closing it.

## What changed

**Detection.** After every pass over the clients, the saver looks for at least `farm_freeze_min_clients` (3) clients that froze within `farm_freeze_onset_window_sec` (15 s) of each other. They must also be more than half of the sampled clients and have averaged at most `farm_freeze_max_cpu_percent` (2%) CPU since they froze. When the last of them has been frozen for `farm_freeze_confirm_sec` (35 s), the saver latches an episode (`FARM_FREEZE_DETECTED`). It does so only from one fresh, fully mapped Volt snapshot. Accounts that are already pending, quarantined, excluded, suspended or beyond the hourly budget stay on the normal path.

**Recovery.** Episode members get the health reason `FARM_FREEZE` and go through the unchanged `Invoke-ClientRecovery`: exact Volt account mapping, the recovery journal entry saved before the close, audit logging, the hourly budget, quarantine, the live Volt parent, and a fresh sample showing that the client is still frozen. Only three gates are scoped to the running episode:

- **Cooldown:** members are closed `farm_freeze_spacing_sec` (20 s) apart instead of `cooldown_sec`. While an episode runs, nothing else is recycled.
- **Handoff:** the open handoffs of the episode's other members do not block the next member. Any other reason still needs the normal gate.
- **Mapping:** while Volt relaunches members the episode already closed, their rows may be unmapped, but nothing else. Process ownership must still be exact (`processMappingSafe`), every other row must map, the member's own row must be Connected with its exact socket, and Volt must be the same manager process. The adapter now reports `processMappingSafe`, `unmappedAccountIds` and a per-row `rowReady` for this; `controlReady` and `globalMappingSafe` mean what they did before.

**Ending.** The episode ends when every member is closed, gone or answering again (`FARM_FREEZE_EPISODE_END`). It also ends when it outlasts its plan by 2 minutes, when the fast path is turned off, or when the saver restarts. Members that are left fall back to `hang_timeout_sec`. A farm that freezes again within `farm_freeze_refreeze_sec` (15 min) of a fast recovery also gets the normal hang timeout: if the display is still gone, recycling early does not help.

**Launch pacing.** A missing-account launch (`LaunchMissing`) now waits for a free slot: no farm-freeze episode running, no client started in the last 20 s, and no closed client whose Volt relaunch is still due.

## Measured result

`tests/saver/FarmFreezeReplay.Tests.ps1` replays the four freezes through the production recovery code against a fake Volt fitted to the same logs. The fake Volt models relaunch latency drawn from the 18 measured single exits, unmapped rows while a relaunch counts down or connects (5 s), the burst notice rule above, 12 s from launch to in game, and 5 s of recovery IO per close. Only process, Volt and diagnostics IO are faked. Run it with `-Report` for these tables.

Before the fast path is judged, the same replay with the fast path off must reproduce the logs. For the three incidents recorded by the v2.x engine it does: within 45 s on the mean, 60 s on the last account and one startup notice. The 23 Oct log came from the v1.2.0 engine, and Volt relaunched that burst in two waves 64-90 s after the exits. The model does not capture that, so this incident is replayed but not used to validate the model.

REPLAY_TABLE

**Spacing.** Volt's relaunch latency varies by up to 11 s, so evenly spaced closes do not give evenly spaced launches. Over every ordering of the measured latencies, on the 8- and 7-client incidents:

SWEEP_TABLE

20 s is the default: no launches ever came within 10 s of each other, at almost the same mean as 15 s. It is also the floor under `config_lock`.

### Expected downtime

| | Today (logs) | With the fast path (replay) |
| --- | --- | --- |
| First account back in game | 230-245 s | AFTER_FIRST |
| Mean per account | 330-384 s (about 5.8 min) | AFTER_MEAN |
| Whole farm back in game | 436-513 s (7.3-8.6 min) | AFTER_MAX |
| Volt startup notices | 4-5 per freeze | none |

Add about 40 s to any of these for `ACCOUNT_RESTORED_VERIFIED`.

The floor is Volt itself: 30 s of relaunch delay plus about 12 s to get in game after the 35 s confirmation, and then one launch every 20 s. With 8 clients the last close is due about 180 s after the freeze, before the clients' own quit at 195-201 s. A larger farm runs out of time, and its last clients quit and relaunch together as they do today.
