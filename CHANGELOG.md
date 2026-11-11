# Changelog

Changes for **Arkuzo Memory Saver with Volt Integration** are recorded here.

## Unreleased

- **Window layout: no more overlapping windows.** Roblox's windows can't be made smaller than 800 × 600, so on a 1920 × 1080 screen only 2 fit side by side, and 11 farm clients overlapped. Forcing smaller windows was tried on a real Roblox window on 11 Nov (the app's home screen; not in a game): every normal way (`SetWindowPos`, `MoveWindow`, removing the resize frame) is clamped to 800 × 600 by Roblox, and bypassing the clamp (`SWP_NOSENDCHANGING`) makes Roblox resize itself to 65,535 pixels high and crash within 3 seconds, every time. So the new default, **More than fit: Minimize the rest**, tiles as many windows as fit without overlap, as large as they fit, and minimizes the others. Minimized is the same window state as the existing *Minimized* option (a minimized Roblox window stayed responsive to the saver's health probe and kept running; not yet tested in a game), and the window you are using is never minimized while it has the focus. A minimized window restored from the taskbar stays up until the layout changes or **Arrange now**. **Overlap evenly** keeps the old behaviour. The preview shows minimized windows as a strip and says how many are tiled and minimized.

- **Roblox tab: choose your exploit, follow its build.** The **Build** switch is now *Auto*, *Newest*, *Exploit* or *Pinned*. *Exploit* is a dropdown of weao.gg's Windows exploits with their status (updated or not, detected, version, the build each supports); choosing one installs that build from Roblox's CDN if needed (in the background, with progress) and uses it. While following, the Control Center checks again every 10 minutes: when the exploit moves to a new build, that build is installed and used automatically. *Newest* does the same for Roblox's current public build. *Pinned* shows the installed builds as one-click buttons (**Use** in the build list too). **Switch clients** decides whether a change restarts the farm's clients right away (like Close all) or as they relaunch, and every switch has **Undo**. Exploits are never downloaded; weao.gg only chooses the build.

- **Roblox links use the selected build.** A new switch on the Roblox tab points Windows' `roblox-player:` and `roblox:` links (HKCU only) at the selected build, so roblox.com links and the *Protocol* launch method start it too; with it on, a pinned build launches by protocol instead of being forced to Direct. The previous keys are saved to the data folder and restored exactly when the switch is turned off or the build goes back to Auto. (On the development PC the keys pointed at a Roblox build folder that Roblox's updater had emptied.)

- **Accounts: search, filters, selection and bulk actions.** The account list has a sticky toolbar with search (`/`), status filters with counts, a group filter and sorting, and compact rows with checkboxes (shift-click for a range, select all respects the filters). Selected accounts can be launched, closed, switched to relaunch on or off, cookie-checked, assigned to a group (new or existing), removed from a group or deleted. Groups can be used to launch or close a whole group.

- **No more confirmation popups.** Every "Are you sure?" dialog is gone. Deleting accounts happens at once with **Undo** for 10 seconds (everything, cookies included, comes back); removing a private server or a Roblox build waits 8 seconds with **Undo**; stopping the saver offers **Start again**; the two actions that end a session (moving Remote Desktop to the console, stop and quit) take a second click instead. Unsaved settings are kept when you leave the Settings page.

- **New Roblox tab: install Roblox builds and choose the one the saver launches.** The Control Center has a sixth tab (key 6) that shows Roblox's current Windows build, the previous and upcoming builds from weao.gg, and every installed build with its size and the clients using it. *Install latest* or any build by its `version-…` name downloads it from Roblox's own servers (never from anywhere else), checks every package against Roblox's checksums and moves it into `%LOCALAPPDATA%\Arkuzo\Roblox\Versions` only when it is complete; a failed or cancelled install leaves nothing behind. *Roblox build* is *Auto* (the newest installed build, as before) or a pinned build: clients Arkuzo launches then start exactly that build, always directly (Roblox's own launcher would update it). A pinned build that is missing is never swapped for another silently: launches wait and the Activity feed and the tab say why, unless *Fall back if missing* is on. The tab warns when the pinned build is not Roblox's current one, because Roblox can refuse joins from outdated builds. Graphics flags are applied to these builds too (also to any build folder that appears after the saver started, before its first launch); multi-instance, window layout, the saved-login fix and the executor signal do not depend on the build's folder. A new pin applies to clients as they are launched; *Close all* switches running ones at once. See [Roblox versions](docs/roblox-versions.md).

- **Pick your exploits, get the build they support.** The tab lists weao.gg's exploit status (updated or not, the Roblox build each supports, platform, detection and multi-instance flags). Select the ones you use: the tab offers the one build they all support, warns when it is outdated or not updated yet, and explains a conflict when they need different builds. weao.gg is only read for this information; Arkuzo never downloads or installs exploits.

- **Window layout reworked: every window on screen, nothing fighting itself.** Roblox never makes its window smaller than 800 × 600, but the layout planned smaller cells. On 9 Nov *Auto* gave 10 clients 384 px cells: Roblox kept them at 800 × 622, so they piled up and the right-hand column ran 400 px off the screen. Because no window was ever "in place", the saver resized all of them again on every pass (about every 3 s). Clients also stayed flagged as maximized. Now every layout plans with Roblox's real minimum (learned per screen if a window turns out larger) and keeps every window fully on screen. When the windows don't fit side by side, they overlap evenly: 10 windows go 5 across and 2 down, each with a 280 × 410 corner in view, later windows on top. Maximized windows are un-maximized without taking focus. A window that is in place is left alone, and the stacking order is only set when something moved. The preview on the Accounts page uses the same rules and says when windows overlap; the default size for *Grid* and *Cascade* is now 800 × 622.

- **Launches no longer fail with HTTP 403 after someone signs in to the Roblox app.** When the Roblox desktop app itself has a saved login on this PC, every client launched with a ticket loads that login and its web login answers 403 ("WebLogin HTTP error, statusCode: 403"), so it closes before joining. On 9 Nov every launch failed this way from 21:48, on every account, although each account and its ticket were fine. Before each launch the saver now moves Roblox's `RobloxCookies.dat` aside when it holds a saved login (kept as `RobloxCookies.dat.arkuzo-saved-login` in the same folder) and says so in the Activity feed. Clients Arkuzo launches never save a login, so the file is left alone otherwise.

- **CPU and RAM figures keep their decimals.** A PowerShell quirk rounded several numbers before they were used: each client's CPU % was a whole number (0.4 % showed as 0), the console's RAM meter was either empty or full, and adaptive trimming compared a rounded free-RAM percentage (19.6 % counted as 20 and missed a 20 % threshold). All of these now use the exact value, and a check in the test run keeps the mistake from coming back.

- **The launcher starts the installed version when the newest release can't be used.** If the latest GitHub release was incomplete or malformed (for example while its files were still uploading), the launcher stopped with an error even though a working version was installed. It now starts the installed version, as it already did without a network connection. This needs the next `ArkuzoMemorySaver.exe`; the one you have keeps the old behaviour.

- **A stray file in a version folder no longer blocks starting.** The launcher's repair rewrote the program files but left files that don't belong, so the folder failed its check on every start. The repair now removes them. Also in the next `ArkuzoMemorySaver.exe`.

- **The Control Center keeps supervising the saver after bad input.** An unexpected value in the saver's status file or log could end the background loop that restarts the saver, while the page carried on showing old figures. Every part of that loop is now guarded.

- **Docs corrected.** `restore_missing` defaults to `false` and `retry_max_per_hour` is shared by all accounts ([configuration](docs/configuration.md)); the README and `Arkuzo-Control-Center.cmd` now say what closing the window and a crash loop really do.

- **Launches are really `Launch spacing` apart.** The launch step only ran every 10 s, so 12 s spacing was really 20 s and a 20-account farm took about 6.7 minutes to start. It now runs on every pass while accounts wait: a 20-account start takes about 4 minutes. The launch ticket is requested in the background, so the saver keeps watching the farm while Roblox answers (it could block for up to 60 s).

- **No more parked accounts (Arkuzo launcher).** An account whose launches keep failing is no longer quarantined for 30 minutes after 8 attempts, and there is no hourly launch limit any more: after a Roblox outage every account launches again at the normal spacing. Launches go in a fair order (the account tried least recently first), so a failing account never takes the others' turns. A launch Roblox refuses, or whose client closes before it is in game, is retried after the relaunch delay (8 s) instead of the full launch timeout (120 s). Moderated and signed-out accounts are still never retried. Volt keeps its quarantine and limits.

- **Kicked clients are relaunched at once, all of them.** A client verified kicked or disconnected used to wait for every other account's relaunch to finish, for the 90 s cooldown and for the hourly recycle budget, one per pass: a mass kick of 10 clients took well over 10 minutes. Now they are all closed in the same pass, 5 s after the kick is seen, are not counted against the budget, and relaunch 12 s apart: the tenth is back about 2 minutes after the kick. Clients that are still running (frozen, over the memory limit) keep the cooldown and budget; its default is now 60 per hour (was 20; an existing `config.json` keeps its value). A failing account no longer blocks other accounts' recoveries.

- **Close and Stop farm can't miss a client that is still starting.** Pressing *Close* (or *Stop farm*) while a launch was in flight cleared the request too early, so the client that appeared a moment later kept running unmanaged. The request now stays until the account has no client and no launch in flight, a launch waiting for its ticket is cancelled, and the account isn't relaunched until the close is done.

- **A kick signal is never pinned on the wrong client.** With only one client tracked, an executor kick signal naming another account (up to 3 minutes old) marked that client disconnected and it was closed 5 s later. Only an exact account name counts now.

- **One failed log write no longer stops recovery until a restart.** It used to block every closure for the rest of the session while the heartbeat stayed fresh. Logging now pauses for 5 s and continues in a new log file; closures still need a successful log write.

- **Old logs are cleaned up.** At each start the saver deletes older sessions' logs beyond the newest 200 sessions or 300 MB in all (the live folder had grown to 536 MB). A long farm session writes about 25–45 MB a day, so that keeps about a week of a busy farm; the current session is never touched.

- **The Control Center restarts a crashed saver within 5–10 s, always.** The wait used to grow to 2 minutes, and to 10 minutes in a crash loop; now it is 5 s, then 10 s, and 15 s in a crash loop, each crash still logged. An unexpected error in a request is answered with an error message instead of a dropped connection, and no error can stop the supervisor loop any more.

- **A faster pass with frozen clients.** Each frozen client is probed once per pass instead of up to three times (100 ms each), and the Roblox log folder is listed once per pass instead of once per client. The diagnostic log's `RESOURCE_SAMPLE` now records how long each part of the loop takes.

- **Roll back a bad update.** The launcher now keeps the version you had before the last update (older ones are removed, so `app` no longer grows with every release). If a new version misbehaves, quit the Control Center and run `ArkuzoMemorySaver.exe --rollback`: it goes back to the previous version and skips the one you left until a newer release is out. See [troubleshooting](docs/troubleshooting.md). Needs the next `ArkuzoMemorySaver.exe`.

- **The launcher never stops another copy's saver.** When it had to stop a stuck saver, the launcher closed every PowerShell window titled "Memory Saver" and every PowerShell running any `Arkuzo-Memory-Saver` script, including a second install or a copy run from source. It now stops only saver processes started from its own `app` folder, and only its own launcher. Also in the next `ArkuzoMemorySaver.exe`.

- **Settings that only apply to Volt say so.** Quarantine, the retry delays, the hourly launch budget and *Relaunch missing accounts* on the Settings page are now marked *Volt only*: with Arkuzo's own account manager accounts are never quarantined and relaunch at the normal spacing, so changing these has no effect there.

- **For maintainers:** `build/test.ps1` runs each test file in its own process, carries on after a failure, prints a summary and takes `-Filter`; tests no longer need fixed ports; a GitHub Actions workflow runs the suite on Windows. The saver's status file (`runtime-status.json`) now carries a `schemaVersion` and has a checked-in key list (`contracts/runtime-status.json`) that tests hold the engine, the Control Center, the page and the launcher to; every client row has the same keys. `build/lint.ps1` adds `ruff`, a report-only PSScriptAnalyzer run and the overload check. See [architecture](docs/architecture.md).

- **Also for maintainers:** new tests `NativeTicket` (the real background ticket request against a local endpoint), `NativeRecoveryGates`, `DiagnosticLog` and `LoopCost`; `NativeAccounts` covers the two-step launch, refused and early-exit retries, fair order, the close race and the cleared quarantine.

## v2.3.0 — Instant close, Close all and moderated accounts

- **Stop farm closes every client.** Stopping the farm now also closes every Arkuzo client, so the separate *Stop & close clients* button is gone.
- **Close is instant and keeps relaunch on.** *Close* on an account closes its client at once: the Control Center closes the exact process the saver reported (same process ID and start time), instead of waiting for the saver's next pass. It no longer switches the account's relaunch off, so while the farm runs the account is launched again after the relaunch delay.
- **Close all** on the Accounts page closes every client at once; a running farm launches them again.
- **Moderated accounts are shown and no longer retried.** When Roblox moderates (bans or warns) an account, it answers "User is moderated". The cookie check used to keep such an account *Alive*, and the saver retried its launch as if the refusal were temporary. On 9 Nov that meant 93 refused launches for 10 moderated accounts, and the recovery queue was held for almost 2 hours. Both now mark the account *Moderated*: it is not launched, any queued relaunch is dropped, and the Accounts page and Activity feed say so. A later cookie check finds it *Alive* again once the moderation ends, and the farm picks it up.

## v2.2.1 — Recovery on a slow, paging farm (hotfix)

- **Frozen clients and leaking clients are recovered again on a slow, paging farm.** The hang (180 s) and memory-limit (60 s) timers restarted whenever two checks of a client were more than 5 s apart. With 11 clients deep in the pagefile a pass takes 2-8 s, so neither timer could run out: on 9 Nov two clients stayed frozen for 55 and 37 minutes and one sat over the memory limit, none recovered. Only a gap over 30 s (or a clock jump back) restarts them now.
- **A launch that never opens its window is retried.** A client Arkuzo launched that still has no window after the launch timeout (120 s) is closed and the account launched again. One such client had waited 14 minutes at 0% CPU, holding up every other recovery behind it.
- **Clients adopted after a saver restart are matched to their logs again.** Since v2.2.0 the first-lines read of a log larger than 128 KB returned its end instead, so after a restart no older client was matched: they showed as not in game, and a kick written to their log went unnoticed.

## v2.2.0 — Account manager integration

- **Arkuzo has its own account manager.** The Accounts page keeps your Roblox accounts: add one by pasting its cookie or with **Sign in with browser**: a plain Microsoft Edge window with a throwaway profile (no automation, no sync prompt), brought to the front and closed by itself once you are signed in. Each cookie is checked with Roblox (Alive, Dead or Unchecked, with a check button per account, Check all, and a check every 60 minutes), and Roblox's re-issued cookies replace the stored ones, so accounts stay signed in. Cookies and private-server link codes are stored encrypted with Windows DPAPI for your Windows user and never appear in a page, log or command line.
- **Start farm, and relaunching, without Volt.** The saver now launches clients itself: Start farm launches every account with Relaunch on, 12 s apart, and keeps them in game. A client that closes, crashes, is kicked or freezes is relaunched 8 s later, with no growing backoff; only a launch that produces no client is retried (after 120 s). The recovery core is the same one Volt used (journal, exact mapping, in-game verification, budgets, farm-freeze handling), now fed by Arkuzo's account list; each client is mapped by its account's own tracker id. Launch / Close per account, Stop farm and Stop & close clients.
- **Multiple clients without Volt:** the saver holds Roblox's single-instance lock (on by default, "Multiple clients").
- **Places and private servers:** a farm-wide place, a per-account place, and private servers from share links or `privateServerLinkCode` links, one for all or per account.
- **Who launches clients** (`accounts.provider`): *auto* uses Arkuzo once an account is added, unless Volt is running a farm of its own clients with auto-relaunch on; *volt* keeps the previous behaviour exactly. Volt can stay open as your executor. Accounts Volt is running a client for are left to Volt, because two launchers on one account kick each other. Guide: [docs/accounts.md](docs/accounts.md).
- **Window layout:** Arkuzo clients are arranged in small windows. *Auto* (the default) fits every window on screen as large as possible and re-fits as accounts come and go; *Grid* uses your size and windows per row; *Cascade* stacks them. Start corner, screen, gap, a fixed spot per account or by name or launch order, keep in place or place once, and normal, behind other windows or minimized. Moves never steal focus. **Arrange now** and a live preview on the Accounts page, where the place to farm now sits at the top and the setting cards fold.
- **Remote desktop disconnects.** In the logs, 12 of the 14 Chrome Remote Desktop disconnects with clients running froze all of the clients, or all but one, within seconds, 70 clients in all; none came back, and Roblox's own watchdog closed them about 200 s later. Connecting never froze anything. The saver now recognises a Chrome Remote Desktop disconnect from the host's own events, and an RDP disconnect from its session state. A farm freeze that starts right after a disconnect is recycled after 20 s instead of 35 s (`farm_freeze_remote_confirm_sec`). A freeze from a new disconnect is not slowed down by the 15-minute refreeze fallback. While an RDP session is disconnected, recovery and launches wait for it, for at most 10 minutes (`remote_hold_max_sec`). Every change in remote session, lock state, input desktop, display mode or monitor count is logged (`REMOTE_SESSION_CHANGED`), so the next disconnect shows what Windows changed.
- **The saver no longer hangs on a frozen client's log.** On 8 Nov a client frozen by a disconnect blocked every open of its Roblox log. Every saver start hung on it within 2 s, and the farm went unmanaged for 53 minutes. Roblox log reads now give up after 2 s and skip that file until it opens again.
- **Display kept awake while clients run** (`keep_display_awake`), a process-scoped request that leaves the power plan alone.
- **Control Center:** a notice while Chrome Remote Desktop is connected ("minimise it, do not disconnect"), a Remote desktop card in Settings with the session state, and a "Leave Remote Desktop safely" button for RDP. The button moves the session to the PC's screen with `tscon` and needs administrator rights. Guide: [docs/remote-desktop.md](docs/remote-desktop.md).

## v2.1.5 — Farm freezes recover in about 2.5 minutes

- **A farm-wide freeze is over in about 2.5 minutes instead of 6.** When most clients freeze together at 0% CPU (Chrome Remote Desktop disconnects and display events in the logs), the saver no longer waits the full hang timeout. After 35 s it recycles the frozen clients one every 20 s, so Volt relaunches them one at a time instead of all at once, and doesn't bring up its "Roblox started before Volt could connect" notice (behind 18 of the 21 recoveries during the four logged freezes, 23-27 Oct). Every recycle keeps the exact Volt account mapping, the journal entry written first, the hourly budget and quarantine. Replaying those four freezes, each account is back in game after 150 s on average (348 s in the logs), and the whole farm after 210 s (436-513 s in the logs). Turn it off with `health.farm_freeze_enabled`. Details: [docs/farm-freeze-recovery.md](docs/farm-freeze-recovery.md).
- **Clients that freeze together while still starting are caught too.** On 8 Nov, 3 of the first 4 clients froze 18-43 s after launch, while Volt was still starting the farm. The 90 s warm-up hid them, so they quit by themselves about 3 minutes later, Volt relaunched them all at once, and they were out for 5.5-7.5 minutes. Starting clients that already answered once now count, the majority is judged among the clients running when the freeze began, and recycling waits until Volt has launched nothing for 30 s. Replayed, those accounts are back after about 3 minutes instead of 5.5-7.5. Average CPU allowed while frozen goes from 2% to 5%: one of those clients sat at 3.7%, and hangs that recovered by themselves also stayed under 3%.
- **Missing-account launches wait for a free launch slot,** at least 20 s away from any other client start or pending Volt relaunch.

## v2.1.4 — No false saver kills, frozen clients come back

- **The Control Center no longer kills a healthy saver.** One unreadable heartbeat (the saver replaces the file every 2 s) made the supervisor measure silence from the saver's start, so after 150 s any bad read killed it as "stopped responding for <session age>" (217 s, 836 s and 12,849 s on 24 Oct; the two unexplained saver restarts on 26 Oct with the farm running fit the same pattern). Silence now counts from the last heartbeat seen, a briefly missing file is retried, waking from sleep gives the saver time to write again, and a briefly unreadable heartbeat is no verdict on a saver started elsewhere (after 2 minutes the normal check applies again).
- **Supervisor actions are logged** to `data/Arkuzo-Logs/control-center.log`, so a stop, restart or kill can be explained afterwards.
- **Clients that quit while frozen are relaunched.** When every client freezes at once (in the logs, each Chrome Remote Desktop disconnect while clients were running was followed by such a freeze), they quit after about three minutes while still in hang grace. Those exits are now queued for the same bounded, verified Volt relaunch as kicked clients, even with `restore_missing` off.
- **Closing the window quits after an update too.** A page left from the replaced Control Center polled once before reloading and stayed registered as an open window, so closing the real window never quit. Only pages of the current Control Center register now, and registrations from older pages expire after 3 minutes without a poll.

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
