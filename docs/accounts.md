# Arkuzo accounts: farming without Volt

The Control Center has its own account manager. It keeps your Roblox accounts, checks whether each one is still signed in, starts the farm and relaunches every client that closes, freezes or gets kicked. Volt's account manager is no longer needed for any of that.

## Add accounts

Open **Accounts** in the Control Center.

- **Add cookie:** paste an account's `.ROBLOSECURITY` cookie (the bare value, `.ROBLOSECURITY=…` or a whole cookie header all work). Roblox is asked once whether the cookie is signed in; only then is the account added, with its name, display name and avatar.
- **Sign in with browser:** a small Edge (or Chrome) window opens on the Roblox sign-in page. Sign in as usual, including captchas and 2-step verification. As soon as Roblox accepts the sign-in, the window closes and the account appears in the list. The window uses a throwaway browser profile that is deleted afterwards; it never touches your normal browser.

Adding an account that is already in the list refreshes its cookie instead of duplicating it. This is how you bring a signed-out account back.

## Find and manage many accounts

The account list has a toolbar that stays on top while you scroll:

- **Search** (press `/`): name, `@username`, group or notes. `Esc` clears it.
- **Status**: All, In game, Launching, Idle, Signed out, Moderated, each with its count.
- **Group**: every group with its count, or *No group*.
- **Sort**: name, status, group or last launched.

Rows are compact and have a checkbox. Shift-click selects a range; the checkbox in the header selects every account the filters show. With accounts selected, a bar offers:

| Action | What happens |
| :--- | :--- |
| Launch | Launches them now. Signed-out and moderated accounts are skipped (the toast says how many). |
| Close | Closes their clients now (only the exact clients the saver reports). With relaunch on and the farm running, they come back. |
| Relaunch on / off | Sets their **Relaunch** switch. |
| Check cookie | Asks Roblox whether their cookies are still signed in. |
| Assign group | Type a new group or pick an existing one (Enter works). |
| Remove from group | Clears their group. |
| Delete | Removes them and their stored cookies. Running clients keep running. |

`Esc` clears the selection. A group is a label of up to 40 characters on each account (also in the account's editor, ✎); it is not secret and is stored with the account in `data/accounts.json`. Filter by a group, select all, and **Launch** or **Close** to start or stop one group.

**No confirmation popups.** Nothing in the Control Center asks "Are you sure?" any more. Deleting accounts happens at once and the toast offers **Undo** for 10 seconds: the accounts are held in `accounts.json` (cookies still encrypted, never shown or launched) and Undo puts everything back, cookie, group, notes and settings included. After 10 seconds they are gone for good. Removing a private server or a Roblox build waits 8 seconds with **Undo** before it happens. **Stop** (saver) acts at once and offers **Start again**. **Close all** just acts. Moving a Remote Desktop session to the console and **Stop saver and quit** take a second click within 4 seconds instead of a popup. Unsaved changes on the Settings page are kept when you leave it (the toast offers **Discard**).

## Cookie health

Each row shows whether the cookie is **Alive**, **Dead** (Roblox rejected it: signed out, expired or changed password) or **Unchecked**, and when it was last checked.

- The ↻ button checks one account; **Check all** checks every account, one second apart.
- Cookies are checked automatically every 60 minutes (Farm → **Cookie check**; 0 turns it off).
- A launch that Roblox refuses with "unauthorized" marks the account dead too.
- If Roblox can't be reached, the status stays as it was. A network hiccup never marks an account dead.

Roblox re-issues login cookies from time to time and later stops accepting the old one. Whenever a check or launch returns a new cookie, the stored one is replaced, so accounts stay signed in.

## Farm

**Start farm** launches every account whose **Relaunch** switch is on and whose cookie is alive, one at a time. While the farm runs, the saver keeps those accounts in game:

| Event | What happens |
| :--- | :--- |
| A client closes, crashes, is kicked or freezes | The saver closes it if needed and relaunches the account after the **Relaunch delay** (8 s). A kicked or disconnected client is closed right away (5 s after the kick is seen), all of them in the same pass, without waiting for other accounts' relaunches or the recovery budget. A frozen client still waits for the hang timeout and the recovery cooldown. |
| Several accounts need launching | Launches are spaced by **Launch spacing** (12 s), and that is the real gap: a 20-account farm is fully launched in about 4 minutes. There is no growing backoff and no hourly launch limit. The account tried least recently goes first, so one that keeps failing never takes the others' turns. |
| A launch fails | Roblox refuses the launch ticket or doesn't answer, or the client closes before it is in game: the account is launched again after the **Relaunch delay** (8 s). A launch that produces nothing at all (no client, or a client that never opens its window) is retried after the **Launch timeout** (120 s). An account is never quarantined or parked: it is retried for as long as the farm runs, at the normal spacing, so a Roblox outage ends with every account launching again. |
| A cookie is dead | The account is paused (shown as *Signed out*) until you add it again. |
| The Roblox app has a saved login on this PC | Ticket launches would fail with HTTP 403 on every account. Before each launch the saver moves Roblox's `RobloxCookies.dat` aside when it holds a saved login, which signs the Roblox app out. Use roblox.com in a browser to sign in to an account yourself. |
| Roblox has moderated the account (banned or warned) | Roblox refuses to launch it ("User is moderated"). The account is shown as *Moderated* and is not launched or retried, so it never holds up the other accounts' relaunches. Sign in to it on roblox.com to see Roblox's notice. The cookie check (every 60 minutes, or **Check**) finds it *Alive* again once the moderation ends, and the farm launches it again. |

The usual safety rules still apply. The saver only closes a client it can map to exactly one account (its own tracker, the same process ID and start time). A relaunch only counts once the new client is in game. The recovery journal and farm-freeze handling work as before; the cooldown and hourly budget apply to closing clients that are still running. While the saver waits for Roblox to hand out a launch ticket it keeps watching the farm.

- **Stop farm:** nothing is relaunched any more, and every client of these accounts is closed.
- **Close all:** closes every client of these accounts right away. The farm keeps its state: while it runs, the accounts are launched again (a quick way to restart them all).
- **Launch** / **Close** on a row act on that one account right away. *Close* leaves its relaunch on, so while the farm runs the account is launched again after the relaunch delay; switch *Relaunch* off to keep it closed.

The Control Center closes a client itself, at once, but only the exact process the saver reported for that account (same process ID and start time, `RobloxPlayerBeta.exe`). The saver also handles the request on its next passes and keeps it open until the account has no client and no launch in flight: a launch that was waiting for its ticket is cancelled, and a client that started in between is closed too. The account is not launched again until that is done.

### Where accounts join

Under **Farm**, set **Place to farm** (the number in the game's link, `roblox.com/games/<ID>/…`). An account can override it in its editor (✎).

**Private servers:** add a server with its link. Both kinds work:

- share links: `https://www.roblox.com/share?code=…&type=Server`;
- older links: `https://www.roblox.com/games/<ID>/…?privateServerLinkCode=…`.

Then choose a mode: *One server for all*, or *Per account* (pick the server in each account's editor). Share links are resolved with one of your signed-in accounts when you add them.

### Settings

| Setting | Default | Meaning |
| :--- | :--- | :--- |
| Who launches clients | Auto | *Arkuzo* uses these accounts, *Volt* uses Volt's account manager. *Auto* picks Arkuzo once you have added an account, unless Volt is open with auto-relaunch on (then Volt is still the launcher, so a Volt farm is never left without recovery). Volt open only as your executor is fine. |
| Launch spacing | 12 s | Minimum gap between two launches. |
| Relaunch delay | 8 s | Wait after a client closed before launching it again. |
| Launch timeout | 120 s | Time for a launched client to appear before the launch is retried. |
| Relaunch accounts | On | Master switch for every account's Relaunch switch. |
| Multiple clients | On | Hold Roblox's single-instance lock so several clients run side by side, like Volt's multi-instance option. |
| Launch method | Direct | *Direct* starts the installed `RobloxPlayerBeta.exe` (the build chosen on the Roblox tab). *Protocol* goes through Roblox's own launcher, which updates Roblox first. Switch to Protocol if a Roblox update leaves clients failing to start. A build pinned on the Roblox tab launches directly, unless **Roblox links use this build** is on there (then Protocol starts the pinned build). |
| Cookie check | 60 min | How often every cookie is checked. |

Which Roblox build these clients start is chosen on the **Roblox** tab: *Auto* (the newest installed build), *Newest* (follows Roblox's current build), *Exploit* (follows the build your exploit supports, from a dropdown) or a *Pinned* build. See [Roblox versions](roblox-versions.md).

### Window layout

Under **Window layout** the saver keeps every client's window in place on the chosen screen, without ever taking focus. Roblox never makes its window smaller than 800 × 600 (800 × 622 with the title bar at 100% scaling), so every layout works with at least that size and keeps each window fully on screen. **More than fit** decides what happens when the windows can't all fit side by side:

- **Minimize the rest** (the default): windows never overlap. As many as fit are tiled, as large as fits (on a 1920 × 1080 screen: 2 windows of 958 × 744); the others are minimized. A minimized Roblox window is the same state as the existing **Windows: Minimized** option: on 11 Nov a Roblox app window (not in a game) stayed responsive to the saver's health probe, kept its main window and kept using CPU for the 30 s it was watched. The saver's freeze detection needs an unresponsive window, not just low CPU, so a quiet minimized client is not treated as frozen. Not tested: a minimized client in a game, and the executor with it. Each minimized window is placed on a tile first, so restoring one from the taskbar shows it there; a window you restore stays up until the layout changes or you press **Arrange now**. The window you are using is never minimized while it has the focus (that would move the focus); it is minimized after you switch away.
- **Overlap evenly**: every window stays on screen. With more windows than fit, they overlap evenly: 10 windows go 5 across and 2 down, each keeping a 280 × 410 corner in view. Later windows sit on top, so every window's corner stays visible.

Layouts:

- **Auto** (the default) puts the windows side by side, as large as fits, in Roblox's shape.
- **Grid** uses your windows per row and size (raised to the minimum). With *Minimize the rest*, no more columns or rows than fit the screen; with *Overlap evenly*, rows or columns that don't fit overlap evenly instead of running off the screen.
- **Cascade** stacks the windows diagonally (always overlapping) and starts over before reaching the edge.

**Why not smaller windows?** On 11 Nov every way of forcing a Roblox window below 800 × 600 was tried on a real Roblox window (the Roblox app's home screen, started without an account ticket; a game could not be joined for the test): `SetWindowPos`, `MoveWindow`, and removing the resize frame are clamped by Roblox to 800 × 600; `SetWindowPos` with `SWP_NOSENDCHANGING` gets past the clamp, but Roblox then resizes its own window to 65,535 pixels high, its Direct3D swap chain fails (`ResizeBuffers failed hr=0x80070057` in the Roblox log) and the client crashes within 3 seconds, every time (5 of 5 tries, borderless and framed, width or height alone below the minimum). Whether a client in a game behaves the same was not tested. The only other way, changing Roblox's window procedure, means loading code into the Roblox process, which Arkuzo never does. So the saver tiles what fits and minimizes the rest.

A maximized window is un-maximized first. A window that is already in place is left alone, and the stacking order is only set when a window was actually moved, so a client you bring forward stays in front until the layout changes. **Arrange now** puts every window back at once. The preview shows the same layout, the minimized windows as a strip at the bottom, and says how many are tiled, minimized or overlapping.

## Moving over from Volt

1. Add your accounts (cookie or browser sign-in). Volt's encrypted cookies are not imported.
2. In Volt, **turn auto-relaunch off** (or close Volt). Two launchers on one account kick each other in a loop ("signed in elsewhere"). While Volt runs with auto-relaunch on for an account that is also in your Arkuzo list, Arkuzo refuses to launch it and shows a warning.
3. Make sure your executor attaches to clients it did not launch itself (its auto-attach or auto-inject option), so your autoexec scripts still run.
4. Set the place, then **Start farm**.

To go back, set **Who launches clients** to *Volt*.

## Backups and recovery

Every save writes the list to the disk before it replaces the old file, so a crash leaves either the old list or the new one, never an empty file. On 11 Nov a crash during a save without this flush left 28 KB of zeros and lost every account. Copies are kept next to it:

| File | What it holds |
| --- | --- |
| `data/accounts.json.bak` | The list as it was before the latest save. It is only replaced when that version reads correctly. |
| `data/vault-backups/accounts-YYYYMMDD-HH.json` | The first save of each hour (UTC). The newest 72 are kept, plus one per day going back 7 days; older ones are deleted. |
| `data/accounts.json.damaged-<time>` | A damaged list that was set aside. These are never deleted automatically. |

The saver and the Control Center both keep these copies, by the same rules, under the same lock (`Local\ArkuzoAccountVault`).

When `accounts.json` can't be read (all zeros, cut off, not JSON, or not a list of accounts):

- The Control Center restores `.bak`, or else the newest good hourly copy, byte for byte. It keeps the damaged file and reports the restore in the Activity feed with the copy's age.
- A restored copy can hold a sign-in that Roblox has since replaced; that account then shows as signed out. Sign it in again.
- Launch, Close and Arrange requests saved in the copy are cleared, so an old request is not carried out again.
- Until the restore, the saver reads the copy without changing anything: it launches nothing and ignores the copy's requests.
- If no good copy exists, nothing is overwritten. The Accounts page offers **Start a new account list** (click twice within 4 seconds), which sets the damaged file aside and starts empty.

The copies hold the same DPAPI-encrypted secrets as the list itself.

## Security

- Cookies and private-server link codes are stored in `data/accounts.json` (and its backups, above), encrypted with Windows DPAPI for your Windows user. Copying the files to another PC or user doesn't reveal them.
- No page, API response, log line, heartbeat or command line written by Arkuzo contains a cookie. The only place a cookie is sent is Roblox itself (`*.roblox.com`).
- The launch ticket that Roblox issues for each launch goes on that client's command line, as with every Roblox launcher. It is short-lived and never logged.
- **Anyone with a cookie can use the account.** Never paste a cookie someone else gives you, and never give yours away.
