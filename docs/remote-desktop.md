# Remote desktop disconnects

Closing a Chrome Remote Desktop session while clients run freezes every Roblox client on the PC. This page records what the logs on the farm PC show, what is still unknown, what the saver now does about it, and what to do when you leave a remote session. Settings are in [configuration](configuration.md#health-recovery-candidate-policy).

## What to do

- **Chrome Remote Desktop: minimise it, don't disconnect.** Leave the session connected and minimise the tab or window. No client froze while a session was connected. If you do disconnect, the saver restarts the clients one at a time straight away (see below), which costs each account about 2-3 minutes.
- **Remote Desktop (RDP): use "Leave Remote Desktop safely"** (Control Center, Settings, Remote desktop). It runs `tscon <your session> /dest:console`, which moves your session to the PC's own screen and closes the RDP window without disconnecting the session, so the clients keep drawing. It needs administrator rights; without them the Control Center shows the command to run in an administrator Command Prompt. Afterwards the PC is signed in and **unlocked on its monitor** until you lock it there.
- **Parsec, AnyDesk, TeamViewer, RustDesk** show the console session like Chrome Remote Desktop does. The saver doesn't recognise their disconnects yet. If one freezes the farm, the normal farm-freeze fast path still recovers it (35 s confirmation instead of 20 s).

## What the logs show

All logs on the farm PC from 21 Oct to 8 Nov: the saver's `data/Arkuzo-Logs`, the Chrome Remote Desktop host's own events (Application log, source `chromoting`: 1 = viewer connected, 2 = viewer disconnected), and the Roblox client logs.

| Chrome Remote Desktop disconnect | Clients running | Froze within 13 s | Answered again | Quit by themselves after |
| --- | --- | --- | --- | --- |
| 21 Oct 13:55 | 11 | 10 | 0 | 196-215 s |
| 21 Oct 14:38 | 4 | 4 | 0 | 205 s |
| 21 Oct 23:32 | 2 | 1 | 0 | 196 s |
| 22 Oct 00:11 | 8 | 7 | 0 | 254-262 s |
| 23 Oct 23:15 | 8 | 8 | 0 | 195-204 s |
| 23 Oct 23:36 | 8 | 8 | 0 | (log ends 28 s later) |
| 26 Oct 15:29 | 1 | 1 | 0 | 191 s |
| 26 Oct 18:10 | 6 | 6 | 0 | 202-204 s |
| 8 Nov 16:06 | 2 | 2 | 0 | 201-205 s |
| 8 Nov 16:19 | 11 | 11 | 0 | 200-205 s |
| 8 Nov 16:24 | 3 | 3 | 0 | 199 s |
| 8 Nov 16:27 | 9 | 9 | 0 | (log ends 35 s later) |

- **12 of the 14 disconnects with clients running froze them, 70 clients in all.** The other two had one client each: on 21 Oct 00:23 it stalled and answered again 20 s later, on 21 Oct 10:08 it froze 63 s after the disconnect.
- **None of the 53 frozen clients with a complete log ever answered again.** All of them sat at 0-2% CPU and quit 191-262 s later.
- **Connecting never froze anything.** The rows for connects in the raw correlation only show hangs because the session was closed again within 90 s.
- **No connected period froze the farm,** however long it lasted.
- **The 3-minute exit is Roblox's own watchdog.** The client logs stop at the disconnect, apart from a "Websocket closed" line from another thread 30 s later. Each ends with Roblox's crash-report line "Terminated due it was hanging past timeout" about 200 s later (exit code 0).
- **The 0-13 s spread is measurement, not the freeze itself.** The saver sees a hang once Windows has marked the window as not responding (5 s) and checks the clients one after another.

## The mechanism: known and unknown

Chrome Remote Desktop on Windows streams the **console session** (session 1 here); it doesn't create a session of its own. When the viewer leaves, Windows records nothing about the session: no disconnect, no lock, no display reset, no GPU timeout (TDR) in the System, LocalSessionManager or DxgKrnl logs. The only event is the host's own "Client disconnected".

What changes at that moment is still open:

- **Lock screen:** locking is not audited on this PC (Other Logon/Logoff auditing is off), so a lock would leave no trace. No lock policy, screen saver or curtain mode is configured.
- **Display mode:** a resolution change leaves no event either. The PC has one monitor (1920×1080 at 144 Hz, HDMI) and a Meta Quest virtual display adapter that fails to load at every boot. The Roblox logs record a swap-chain resize at startup but none at the disconnect.
- **Volt:** every logged freeze happened with Volt injected into every client, so the logs can't separate Roblox from Volt. The saver itself, the Control Center and other windows kept running through every disconnect, so the freeze is specific to the clients.

To answer this, the saver now logs a `REMOTE_SESSION_CHANGED` event whenever anything below changes: the Chrome Remote Desktop state, this session's connect state and protocol, whether it is on the console, the lock state (`WTSSessionInfoEx`), the input desktop (`Default`, or `Winlogon` on the lock screen), the primary display mode, and the monitor count. The event also counts the clients running and answering at that moment. The next disconnect shows in the log which of these moved.

## What the saver does now

**Recognises remote sessions.** About every 2 s it reads the newest connect or disconnect event of the Chrome Remote Desktop host (about 10 ms; the event text, which names the viewer's Google account, is never read or logged) and its own session's state through the WTS API. Its starting state is logged once as `REMOTE_SESSION_STATE`. All of this is read-only.

**Acts on a freeze right after a disconnect sooner.** A farm-wide freeze whose first client froze between 10 s before and `farm_freeze_remote_window_sec` (60 s) after a remote disconnect is confirmed after `farm_freeze_remote_confirm_sec` (20 s) instead of `farm_freeze_confirm_sec` (35 s). `FARM_FREEZE_DETECTED` then says `cause: remote-disconnect`. Every other gate of the [farm-freeze fast path](farm-freeze-recovery.md) is unchanged: exact account mapping, the journal entry before each close, the hourly budget, the 30 s quiet period after Volt's own launches, and one close every `farm_freeze_spacing_sec`. 20 s is safe here because none of the clients frozen by a disconnect came back (above). Generic correlated hangs, in contrast, sometimes cleared within 30 s ([farm-freeze recovery](farm-freeze-recovery.md#how-long-to-confirm)). With `config_lock` the floor is 15 s.

**A new disconnect is a new freeze.** A farm that freezes again within `farm_freeze_refreeze_sec` of a fast recovery normally gets the slow hang timeout, because the display may still be gone. A freeze caused by a disconnect that came *after* the last episode started is recycled fast again. On 8 Nov the user disconnected at 16:19, 16:24 and 16:27, and the replacement clients ran fine until each next disconnect.

**Holds recovery while an RDP session is disconnected.** While the saver's own session is disconnected (Windows state `WTSDisconnected`, i.e. RDP), clients can't draw and relaunched ones couldn't either. Hang recovery, the farm-freeze fast path and missing-account launches wait until the session reconnects or is moved to the console, for at most `remote_hold_max_sec` (10 min; 0 turns it off). Critical commit pressure still recycles. Volt's own relaunches are outside the saver's control. Chrome Remote Desktop never triggers the hold: its session stays connected, and its frozen clients never come back, so waiting would only cost time.

**Keeps the display awake.** While clients run, the saver asks Windows to keep the display and the PC on (`SetThreadExecutionState` with `ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED`) and releases the request when no client is left or the saver stops. The power plan is not changed. On this PC display-off and sleep are already set to never on AC power, so this only guards against a later power-plan change or a laptop on battery. It doesn't stop a screen saver, and it doesn't lock or unlock anything. Turn it off with `keep_display_awake`.

**Tells you in the Control Center.** The Overview shows a notice while Chrome Remote Desktop is connected with clients running ("minimise it, do not disconnect"), while you're on RDP ("Leave Remote Desktop safely"), and while an RDP hold is active. Settings has a Remote desktop card with the current state (session, lock, display mode, keep-awake, hold) and the RDP button. Disconnects and the other changes appear in the activity feed.

### Expected effect

At 16:19 on 8 Nov, the 11 clients froze 5-13 s after the disconnect. With the 20 s confirmation the episode starts about 33 s after the disconnect instead of about 48 s. Closes then follow every 20 s, so the first nine clients are recycled before Roblox's watchdog would close them at about 200 s. The last two quit by themselves and relaunch together as before. To fit all 11 in, lower `farm_freeze_spacing_sec` to 15. Volt's startup notice made 20 s the default; with Arkuzo launching the clients, its own launch spacing (12 s) is what matters. This has not been replayed or measured on a real disconnect yet.

## Not automated, on purpose

- **Chrome Remote Desktop curtain mode.** It needs machine policies and RDP turned on, and it moves the remote user into a separate RDP session. That session is *disconnected* when the viewer leaves, which is worse for the clients.
- **Dummy displays (HDMI dummy plug, IddCx virtual display drivers).** They need hardware or a driver install. They would only help if the display mode turns out to change at a disconnect, which the new log events will show.
- **Lock, screen-saver and power-plan settings** are persistent system configuration and stay the user's choice. The saver only makes the process-scoped keep-awake request above.
- **tscon on its own.** Moving a session to the console leaves the PC unlocked on its monitor, so it only runs when you press the button and confirm.

## Live tests still needed

1. **Disconnect Chrome Remote Desktop with the farm running.** Check the log for `REMOTE_SESSION_CHANGED` with `CRD_DISCONNECTED` and whatever else changed (`SESSION_LOCKED`, `INPUT_DESKTOP_CHANGED`, `DISPLAY_MODE_CHANGED`). Then check for `FARM_FREEZE_DETECTED` with `cause: remote-disconnect` about 20 s after the last client froze, and closes 20 s apart.
2. **Volt or Roblox?** Disconnect while one client runs without Volt injected (Arkuzo launches it; leave Volt closed or don't attach). Another Direct3D game window open at the same time helps too. If that client keeps running, Volt is the cause.
3. **Minimised instead of disconnected:** minimise the Chrome Remote Desktop tab for an hour with the farm running. Nothing should freeze.
4. **RDP, if you use it:** press "Leave Remote Desktop safely" once from an administrator Control Center and once from a normal one (the error should show the tscon command).
