# Arkuzo accounts: farming without Volt

The Control Center has its own account manager. It keeps your Roblox accounts, checks whether each one is still signed in, starts the farm and relaunches every client that closes, freezes or gets kicked. Volt's account manager is no longer needed for any of that.

## Add accounts

Open **Accounts** in the Control Center.

- **Add cookie:** paste an account's `.ROBLOSECURITY` cookie (the bare value, `.ROBLOSECURITY=…` or a whole cookie header all work). Roblox is asked once whether the cookie is signed in; only then is the account added, with its name, display name and avatar.
- **Sign in with browser:** a small Edge (or Chrome) window opens on the Roblox sign-in page. Sign in as usual, including captchas and 2-step verification. As soon as Roblox accepts the sign-in, the window closes and the account appears in the list. The window uses a throwaway browser profile that is deleted afterwards; it never touches your normal browser.

Adding an account that is already in the list refreshes its cookie instead of duplicating it. This is how you bring a signed-out account back.

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
| A client closes, crashes, is kicked or freezes | The saver closes it if needed and relaunches the account after the **Relaunch delay** (8 s). |
| Several accounts need launching | Launches are spaced by **Launch spacing** (12 s). There is no growing backoff between normal relaunches. |
| A launch produces no client | It is retried after the **Launch timeout** (120 s). After 8 launches in a row without a client, the account is quarantined so it doesn't block the others; the quarantine ends by itself. |
| A cookie is dead | The account is paused (shown as *Signed out*) until you add it again. |
| Roblox has moderated the account (banned or warned) | Roblox refuses to launch it ("User is moderated"). The account is shown as *Moderated* and is not launched or retried, so it never holds up the other accounts' relaunches. Sign in to it on roblox.com to see Roblox's notice. The cookie check (every 60 minutes, or **Check**) finds it *Alive* again once the moderation ends, and the farm launches it again. |

The usual safety rules still apply. The saver only closes a client it can map to exactly one account. A relaunch only counts once the new client is in game. The recovery journal, budgets and farm-freeze handling work exactly as before.

- **Stop farm:** nothing is relaunched any more, and every client of these accounts is closed.
- **Close all:** closes every client of these accounts right away. The farm keeps its state: while it runs, the accounts are launched again (a quick way to restart them all).
- **Launch** / **Close** on a row act on that one account right away. *Close* leaves its relaunch on, so while the farm runs the account is launched again after the relaunch delay; switch *Relaunch* off to keep it closed.

The Control Center closes a client itself, at once, but only the exact process the saver reported for that account (same process ID and start time, `RobloxPlayerBeta.exe`). The saver also handles the request on its next pass, so a client that started in between is closed too.

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
| Launch method | Direct | *Direct* starts the installed `RobloxPlayerBeta.exe`. *Protocol* goes through Roblox's own launcher, which updates Roblox first. Switch to Protocol if a Roblox update leaves clients failing to start. |
| Cookie check | 60 min | How often every cookie is checked. |

## Moving over from Volt

1. Add your accounts (cookie or browser sign-in). Volt's encrypted cookies are not imported.
2. In Volt, **turn auto-relaunch off** (or close Volt). Two launchers on one account kick each other in a loop ("signed in elsewhere"). While Volt runs with auto-relaunch on for an account that is also in your Arkuzo list, Arkuzo refuses to launch it and shows a warning.
3. Make sure your executor attaches to clients it did not launch itself (its auto-attach or auto-inject option), so your autoexec scripts still run.
4. Set the place, then **Start farm**.

To go back, set **Who launches clients** to *Volt*.

## Security

- Cookies and private-server link codes are stored in `data/accounts.json`, encrypted with Windows DPAPI for your Windows user. Copying the file to another PC or user doesn't reveal them.
- No page, API response, log line, heartbeat or command line written by Arkuzo contains a cookie. The only place a cookie is sent is Roblox itself (`*.roblox.com`).
- The launch ticket that Roblox issues for each launch goes on that client's command line, as with every Roblox launcher. It is short-lived and never logged.
- **Anyone with a cookie can use the account.** Never paste a cookie someone else gives you, and never give yours away.
