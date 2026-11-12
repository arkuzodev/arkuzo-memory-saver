# Roblox versions

The Control Center's **Roblox** tab installs Roblox Windows player builds into a folder Arkuzo manages, and lets the saver launch a chosen build ("pin") instead of whatever Roblox installed last. It reads which builds exist, and which build each exploit currently supports, from weao.gg. This page records what was researched (10 Nov 2026) and how the feature uses it.

Contents: [weao.gg](#weaogg-api) · [Roblox's CDN](#roblox-cdn) · [Install](#how-arkuzo-installs-a-build) · [Which build the saver launches](#which-build-the-saver-launches) · [Follow an exploit or the newest build](#follow-an-exploit-or-the-newest-build) · [Roblox links (protocol)](#roblox-links-roblox-player-protocol) · [Outdated builds](#outdated-builds) · [Other features](#other-features) · [Settings and routes](#settings-and-routes)

## weao.gg API

weao.gg ("WhatExploitsAreOnline") is a community site. Arkuzo uses it **only as a data source** for version strings and exploit status. Nothing weao.gg returns is executed, downloaded or opened: every version string is checked against `^version-[0-9a-f]{16}$` before it is used, links in its rows (websites, Discord, purchase links, logos) are dropped, and Roblox binaries come only from Roblox's own CDN.

| | |
| --- | --- |
| Base URL | `https://weao.gg/api` (the same API answers on `https://weao.xyz/api`) |
| User-Agent | **Required, and not Python's default.** A request with `User-Agent: Python-urllib/3.x` gets **403** (Cloudflare). Community clients send `WEAO-3PService`; that, curl's and browser user agents get 200. Arkuzo sends `WEAO-3PService`. |
| Rate limit | Headers `x-ratelimit-limit: 120`, `x-ratelimit-remaining`, `x-ratelimit-reset` (epoch milliseconds, minute-aligned), so about 120 requests per minute. Responses carry `Cache-Control: max-age=14400` and come through Cloudflare's cache. Arkuzo caches each answer for 5 minutes and merges concurrent fetches into one. |
| Errors | Unknown exploit: 404 `{"error":"No valid exploit with this name"}`. Health: `GET /api/health` → `{"status":"ok", ...}`. |

### `GET /api/versions/current`, `/api/versions/past`, `/api/versions/future`

Current, previous and upcoming (deployed but not yet released) builds per platform. Trimmed:

```json
{"Windows":"version-4ea8e85481e34f46","WindowsDate":"11/10/2026, 5:01:13 PM UTC",
 "WindowsResponse":{"version":"0.747.0.7471481","clientVersionUpload":"version-4ea8e85481e34f46","bootstrapperVersion":"","timestamp":1794330073,"type":"new"},
 "Mac":"version-8001f8762ae44efe","MacDate":"...","MacResponse":{...},
 "Android":"2.744.1081","AndroidDate":"...","iOS":"2.746.1264","iOSDate":"..."}
```

`past` and `future` have the same shape (Windows and Mac only). `past` holds exactly one build, the one before `current`. A `future` build may never be released; the page labels it as such. Only the `Windows` value is used.

### `GET /api/status/exploits` (and `/api/status/exploits/<name>`)

A list of exploits (31 rows on 10 Nov 2026). Each row, trimmed to the fields Arkuzo reads:

```json
{"_id":"662ae7576238b7f2082f253b","title":"Wave","version":"NEW-1.6.1","updatedDate":"11/06/2026 at 4:13 AM UTC",
 "updateStatus":false,"rbxversion":"version-f0ea5da9412f4e35","platform":"Windows","extype":"wexecutor",
 "detected":true,"free":false,"beta":false,"hidden":false,"multiInject":true,"uncPercentage":99,"suncPercentage":100}
```

| Field | Meaning |
| --- | --- |
| `_id` | Stable id. Titles are **not** unique ("Delta" is listed for Android and for iOS), so Arkuzo keys rows by `_id`. |
| `title`, `version`, `updatedDate` | Name, the exploit's own version, when it was last updated (text). |
| `rbxversion` | The Roblox build the exploit currently works with. For Windows rows a `version-<16 hex>`; Mac rows also use that shape (a **Mac** build hash, useless on Windows); Android and iOS rows use app versions such as `2.729.840`. |
| `updateStatus` | `true` when the exploit is updated for the current Roblox build. |
| `platform`, `extype` | `Windows`, `Mac`, `Android`, `iOS`; `wexecutor` (injector), `wexternal` (external), `mexecutor`, `aexecutor`, `iexecutor`. |
| `detected`, `free`, `beta`, `hidden`, `multiInject`, `uncPercentage`, `suncPercentage` | Flags shown as information. `hidden: true` rows are no longer listed on the site; Arkuzo shows them as inactive. Several fields are missing on some rows. |

Arkuzo keeps only rows with `platform == "Windows"` and a valid `rbxversion` as version sources; other platforms are shown as "not for Windows". Example on 10 Nov 2026: Roblox's current build was `version-4ea8e85481e34f46`; 11 exploits were updated for it, while e.g. Volt, Wave and Synapse Z still supported the previous build `version-f0ea5da9412f4e35` (`updateStatus: false`).

### Choosing a build for several exploits

With one or more exploits selected, the tab offers the build they **all** support: if every selected row names the same `rbxversion`, that build; otherwise it lists which exploit wants which build and offers none (a client runs one build). Rows that are not Windows, or whose `rbxversion` is not a valid build, are refused with a reason.

## Roblox CDN

Builds are downloaded from Roblox's setup CDN, the way open-source bootstrappers (Bloxstrap, Fishstrap) do it:

| | |
| --- | --- |
| Current build | `https://clientsettings.roblox.com/v2/client-version/WindowsPlayer` → `{"version":"0.747.0.7471481","clientVersionUpload":"version-4ea8e85481e34f46","bootstrapperVersion":""}`. Arkuzo trusts this over weao.gg when the two disagree. |
| Hosts | `https://setup.rbxcdn.com`, mirrors `https://setup-aws.rbxcdn.com`, `https://setup-ak.rbxcdn.com` (all Roblox's). Bloxstrap uses the path prefix `/channel/common/`; both forms answer. Arkuzo downloads only from these three hosts, refuses redirects, and uses `https://setup.rbxcdn.com/channel/common/` with the mirrors as fallback. |
| Package manifest | `<host>/channel/common/<version>-rbxPkgManifest.txt`: the line `v0`, then four lines per package: name, MD5, packed size, unpacked size. A version that does not exist answers **403** (not 404). Old builds stay available: builds from May 2026 and December 2025 still answered on 10 Nov 2026. |
| Packages | `<host>/channel/common/<version>-<package>`, e.g. `version-4ea8e85481e34f46-RobloxApp.zip`. The ETag is the MD5. |
| File manifest | `<version>-rbxManifest.txt`: two lines per file, relative path and MD5 (about 2,850 files). Arkuzo checks `RobloxPlayerBeta.exe` against it. |
| Deploy history | `https://setup.rbxcdn.com/DeployHistory.txt` now shows `version-hidden` for new builds, so it cannot list past hashes. |

The manifest for `version-4ea8e85481e34f46` (trimmed):

```
v0
RobloxApp.zip
a765b9d75aceaab21a6446e2782f52c6
140583122
177377323
content-avatar.zip
...
WebView2RuntimeInstaller.zip
3fa357010ec47034fb409f3b4d8e7652
1531906
1636320
RobloxPlayerInstaller.exe
e3902320b144a76e915ea3f748c0751c
13768656
13768656
```

About 230 MB to download and 380 MB on disk. Target folders (Bloxstrap's package map, which matches the current manifests):

| Package | Folder |
| --- | --- |
| `RobloxApp.zip`, `Libraries.zip`, `redist.zip`, `WebView2.zip` | the version folder itself |
| `shaders.zip`, `ssl.zip` | `shaders\`, `ssl\` |
| `content-avatar/configs/fonts/sky/sounds/models.zip` | `content\avatar\` … `content\models\` |
| `content-textures2.zip` | `content\textures\` |
| `content-textures3.zip`, `content-terrain.zip`, `content-platform-fonts.zip`, `content-platform-dictionaries.zip` | `PlatformContent\pc\textures\`, `…\terrain\`, `…\fonts\`, `…\shared_compression_dictionaries\` |
| `extracontent-luapackages/translations/models/textures/places.zip` | `ExtraContent\LuaPackages\`, `…\translations\`, `…\models\`, `…\textures\`, `…\places\` |
| `WebView2RuntimeInstaller.zip` | skipped (Bloxstrap only extracts it to install WebView2) |
| `RobloxPlayerInstaller.exe`, `RobloxPlayerLauncher.exe` | skipped: Roblox's own installer is never put into an Arkuzo folder |

A package that is not in this map stops the install with its name ("Roblox added a package this Arkuzo version does not know"), so an incomplete build is never offered.

After extraction a bootstrapper writes `AppSettings.xml` next to the player:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Settings>
	<ContentFolder>content</ContentFolder>
	<BaseUrl>http://www.roblox.com</BaseUrl>
</Settings>
```

## How Arkuzo installs a build

The Control Center does the install in a background thread (one at a time, cancellable, progress polled by the page):

1. Validate the version string; fetch the package manifest (403 = "not on Roblox's CDN") and the file manifest.
2. Check free disk space (packed + unpacked sizes plus a margin).
3. Download each package into `<root>\.staging\<random>\` (outside `Versions\`, on the same drive), refusing redirects and stopping a stream that goes past the declared size; check size and MD5.
4. Extract each package into its folder; every entry's resolved path must stay inside the target (a hostile ZIP is refused). Check `RobloxPlayerBeta.exe` against `rbxManifest.txt`.
5. Write `AppSettings.xml` last, plus `.arkuzo-install.json` (version, time, size).
6. Rename the staging folder to `<root>\Versions\version-<hash>` in one step. A failure or cancel deletes the staging folder; a half-installed build is never in `Versions\` and never selectable. A staging folder left by a Control Center that died mid-install is deleted by the next install once it is 30 minutes old.

Extracted files keep the time stamps stored in Roblox's packages (see Auto below).

End-to-end check (10 Nov 2026, from the dev Control Center into a scratch folder, nothing launched): `version-4ea8e85481e34f46` (Roblox's current build, 217 MB download, 345 MB installed, about 20 s) and `version-f0ea5da9412f4e35` (the previous build, the one Volt, Wave and Synapse Z supported that day). For both, every file in Roblox's `rbxManifest.txt` matched its MD5 (2,856 of 2,857 and 2,852 of 2,853 files) except `MicrosoftEdgeWebview2Setup.exe`, which lives in the skipped `WebView2RuntimeInstaller.zip`; `AppSettings.xml` was in place, no installer was in the folder and the staging folder was empty. Removing the previous build from the tab worked.

`<root>` is `%LOCALAPPDATA%\Arkuzo\Roblox` unless `robloxVersionsDir` names another folder (the versions then live in `<that folder>\Versions`, staging in `<that folder>\.staging`).

Removing a build is refused while a running client's image lies inside it, while it is the pinned build, and for anything that is not a `version-<hash>` folder directly in Arkuzo's `Versions` folder. The folder is renamed first (which fails while a client holds the exe) and then deleted. Roblox's own installs in `%LOCALAPPDATA%\Roblox` and `Program Files\Roblox` are never touched.

## Which build the saver launches

Vault setting `robloxVersion` (accounts.json → settings), set on the Roblox tab:

- **Auto** (`auto`, the default): as before, the build running clients use, otherwise the newest complete installed build (complete = `AppSettings.xml` next to the exe; newest = the newest `RobloxPlayerBeta.exe` file time). Arkuzo's `Versions` folder is searched next to Roblox's, Bloxstrap's and Fishstrap's; in Arkuzo's folder only `version-<hash>` folders count.
  - The exe's version resource cannot rank builds: Roblox's 0.747.0.7471481 player still reports `0, 746, 0, 7461267` (and the fixed version fields truncate the last part to 16 bits). So the installer keeps Roblox's own file times from the packages: an old build installed today keeps its old time (on 10 Nov the 0.746 player kept 3 Nov, the 0.747 player 7 Nov) and does not look newest.
  - Limitation: a build Roblox's own installer wrote gets the install time, which can be later than a newer build's package time (for example a build deployed days before its release). Pin a build when it matters which one starts.
- **Pinned** (`version-<16 hex>`): that build, found by folder name in Arkuzo's folder first, then in Roblox's, Bloxstrap's and Fishstrap's. Running clients of another build do not change it.
  - If the pinned build is missing or incomplete, the launch is refused **before** a ticket is requested (event `ROBLOX_VERSION_PIN_MISSING`, a dashboard warning, the Roblox tab and the account's last error say why), unless `robloxVersionFallback` is on: then the Auto choice is used and the event says so.
  - With `launchMethod` `protocol`, a pin launches by protocol **only while `roblox-player:` starts exactly the pinned build's `RobloxPlayerBeta.exe`** (the engine reads `HKEY_CLASSES_ROOT\roblox-player\shell\open\command`; see [Roblox links](#roblox-links-roblox-player-protocol)). Otherwise it launches directly, because the handler would be Roblox's own launcher, which updates Roblox and starts its own newest build, ignoring the pin; the engine then logs `ROBLOX_VERSION_PROTOCOL_OVERRIDDEN` once per engine run.

**A build that keeps closing at start (dead-build guard).** Clients launched on one build sometimes close before they reach the game. On 10 and 11 Nov this happened with a gutted install, with test-channel `version-93c5b49b03b84a46`, and with an older build Roblox refused; each ran 16 or more failed launches in a row, and three of those exits were followed by blue screens. When it happens 4 times in a row within 5 minutes, on any accounts, the build is marked failing (`ROBLOX_BUILD_FAILING`). The heartbeat's `robloxVersion.problem`, the Roblox tab and the Activity feed then say "Roblox build version-… keeps closing at start — it may be outdated or refused by Roblox".

- **Pinned:** with `robloxVersionFallback` on, launches use the Auto choice without the failing build. Otherwise they are refused before a ticket is requested, like a missing pin.
- **Auto:** launches skip the failing build and start the newest other installed build, or wait if there is none.

What counts:

- **Counted:** an exit of a client the engine launched directly (or a pinned build launched by protocol), before it was in game.
- **Not counted:** clients the engine closed itself (a stalled launch) and clients that reached the game.
- **Not covered:** in Auto mode, protocol launches go through Roblox's own launcher, which picks the build, so the guard cannot steer them.

The mark lifts when a client of that build reaches the game, or when another pinned build (or Auto) is chosen (`ROBLOX_BUILD_GUARD_RESET`). It is kept in memory, so an engine restart starts counting again. It is not a per-account back-off: other builds and accounts relaunch at once.

The heartbeat's `robloxVersion` block (`mode`, `pinned`, `fallback`, `selectedPath`, `selectedVersion`, `method`, `problem`, `managedRoot`, `checkedUtc`; refreshed every 30 s and at each launch, `null` until the first check) tells the page what the saver chose; `NATIVE_LAUNCH_STARTED` names the build (`robloxVersion`, `pinned`).

Pinning a build in Roblox's own folder works, but Roblox's updater deletes its old version folders when it updates (that is how the gutted `version-f0ea…` folder on this PC came about), so the tab offers to install the build into Arkuzo's folder as well.

The pin applies only when Arkuzo launches clients (account provider `arkuzo`). With Volt as the launcher, Volt starts Roblox itself.

## Follow an exploit or the newest build

The tab's **Build** switch has four positions:

| Position | Settings | What happens |
| --- | --- | --- |
| **Auto** | `robloxVersion` `auto`, `robloxVersionFollow` empty | As above. |
| **Newest** | `robloxVersionFollow` `latest` | Follows Roblox's current public build (Roblox's version service, weao.gg when Roblox does not answer). A new build is installed into Arkuzo's folder from Roblox's CDN and then pinned. |
| **Exploit** | `robloxVersionFollow` `exploit:<weao.gg _id>` | A dropdown of weao.gg's Windows exploits, each with its status (updated or not, detected, its version, the build it supports). The build the chosen exploit supports is installed if missing (in the background, with progress) and then pinned. When the exploit moves to another build, that build is installed and pinned. |
| **Pinned** | `robloxVersion` `version-<hash>`, `robloxVersionFollow` empty | One installed build. The installed builds are a row of buttons: one click switches. |

While following, `robloxVersion` holds the build the source wants once it is installed, so the engine is unchanged: it launches the pin. A build chosen by hand (Pinned, or **Use** in the build list) ends following.

- **When the source is checked:** when the mode is chosen, every 10 minutes after that (`ROBLOX_FOLLOW_SEC`; one check is 5 requests: Roblox's version service and four weao.gg calls, against weao.gg's 120 a minute; checks in quick succession share one fetch), and right after a followed install finishes.
- **What is never done:** a source that names no valid build, an exploit that is not for Windows or no longer listed, or a weao.gg row that changes to garbage never changes the pin; the tab says why. An install that failed is tried again at the next check, not in a loop. Exploits are never downloaded; weao.gg only chooses the build.
- **Switch clients** (`robloxFollowRestart`): *As they relaunch* (default) leaves running clients on their build until they are launched again. *Right away* closes the farm's clients when the build changes, by hand or by following, exactly like **Close all**: only exactly mapped clients, and the running farm launches them again on the new build. There is no confirmation dialog; the toast that reports a switch has **Undo**, which switches back (clients already closed are launched again on the restored build).

## Roblox links (`roblox-player:` protocol)

**Roblox links use this build** (`robloxProtocol`, off by default) points the Windows `roblox-player:` and `roblox:` URL protocols at the selected build, so links on roblox.com and the Protocol launch method start it too.

- Only `HKEY_CURRENT_USER\Software\Classes\roblox-player` and `...\roblox` are written (they win over Roblox's all-users keys in `HKEY_LOCAL_MACHINE`, which are never touched): `(Default)` `URL: Roblox Protocol`, `URL Protocol`, `DefaultIcon`, `shell\open\command` = `"<build>\RobloxPlayerBeta.exe" %1`, plus a marker value `ArkuzoManaged`.
- Before the first change, both keys as they were (every value of every subkey, or "did not exist") are saved to `roblox-protocol-backup.json` in the data folder. Turning the switch off, or choosing Auto, restores them exactly and deletes the file. Re-pointing to another build keeps the saved copy. If Roblox's installer rewrites the keys in between (they lose the marker), restoring leaves Roblox's keys alone, and the next re-point saves Roblox's new keys as the copy.
- It applies while a build is pinned (by hand or by following) and that build is complete; it follows the pin when it changes. The Control Center puts the keys right when it starts.
- Why this matters: on 11 Nov the keys on the development PC pointed at `%LOCALAPPDATA%\Roblox\Versions\version-f0ea5da9412f4e35`, a folder Roblox's updater had emptied, so every roblox.com link failed.
- **Not verified:** whether a player started by protocol from an Arkuzo folder starts Roblox's updater on its own (Arkuzo's folders hold no installer or launcher). If clients fail to start by protocol, use the Direct method.

## Outdated builds

- Reported, not verified here: Roblox accepts the previous build for a while after an update (exploits that are "not updated" keep working on it), but it can refuse joins from an outdated build at any moment, with an "out of date" error (community reports name error 280). The tab warns whenever the pinned build is not Roblox's current build.
- Expected (from how Bloxstrap-style installs work; not verified by a launch): a directly launched player does not run Roblox's updater; updating is the bootstrapper's or Roblox launcher's job. Arkuzo's folders hold no `RobloxPlayerInstaller.exe` or `RobloxPlayerLauncher.exe`, and Roblox's installer, when it runs (protocol launch, or someone opening Roblox normally), installs into its own folder (`%LOCALAPPDATA%\Roblox\Versions` or `Program Files\Roblox\Versions`), never over an Arkuzo folder.
- **Not verified** (it needs a client launch, which was not done): whether a player started directly from an old build still tries to start an update itself, and exactly how and when Roblox refuses its joins. If a pinned client fails to join, the launch is retried like any failed launch; switch back to Auto or install the current build.

## Other features

By code review (no client was launched from Arkuzo's folder; only the graphics part has unit tests):

| Feature | With builds in Arkuzo's folder |
| --- | --- |
| Graphics flags | The search roots include Arkuzo's `Versions` folder. A build installed after the saver started gets the flags just before its first launch (`ClientSettings\ClientAppSettings.json`, merged as before). |
| Multi-instance lock | Named objects (`ROBLOX_singletonMutex`, `ROBLOX_singletonEvent`), independent of the folder. |
| Saved Roblox login | `%LOCALAPPDATA%\Roblox\LocalStorage\RobloxCookies.dat` is shared by every build folder; cleared the same way. |
| Roblox logs, health, trim | By process and `%LOCALAPPDATA%\Roblox\logs`, independent of the folder. |
| Window arrangement, instant close | By process id, start time and image name `RobloxPlayerBeta.exe`, not path. |
| Executor signal (`00-arkuzo-signal.luau`), Volt | Written to the executors' `autoexec` folders; independent of the Roblox folder. The executor must support the build (that is what the exploit picker is for). |
| Orphaned crash handlers | `RobloxCrashHandler.exe` from Arkuzo's folder is trusted like Roblox's own (it must still be signed by Roblox). |

## Settings and routes

Vault settings (`contracts/config-schema.json` → `vault`):

| Setting | Rule | Default |
| --- | --- | --- |
| `robloxVersion` | `auto` or `version-<16 hex>` | `auto` |
| `robloxVersionFallback` | bool | `false` |
| `robloxVersionsDir` | empty, or an absolute local folder | empty = `%LOCALAPPDATA%\Arkuzo\Roblox` |
| `robloxVersionFollow` | empty, `latest` or `exploit:<weao.gg _id>` | empty (follow nothing) |
| `robloxFollowRestart` | bool: a build change restarts the farm's clients right away | `false` |
| `robloxProtocol` | bool: `roblox-player:` starts the pinned build | `false` |

GET `/api/roblox` also returns `selection.follow`, `selection.followRestart`, `follow` (`state`: `off`, `checking`, `installing`, `pinned`, `waiting`, `error`; `wanted`, `label`, `reason`, `message`, `checkedAt`) and `protocol` (`exe`, `managed`, `enabled`, `saved`, `error`).

Control Center routes:

| Route | Token | |
| --- | --- | --- |
| GET `/api/roblox` | no | Current build (Roblox and weao.gg), past and future builds, exploit list, installed builds with size and the clients using them, the selection, install progress. Answers are cached 5 minutes; `?refresh=1` refetches (at most every 15 s), `?cached=1` never goes to the network (the page polls it). |
| POST `/api/roblox/install` | yes | `{version}` (`version-<16 hex>` or `latest`) → starts the install. |
| POST `/api/roblox/install/cancel` | yes | Cancels the running install. |
| POST `/api/roblox/remove` | yes | `{version}` → removes an Arkuzo-installed build. |
| POST `/api/roblox/select` | yes | `{version, fallback?}` → sets the pin (`auto` or an installed build) and ends following. |
| POST `/api/roblox/mode` | yes | `{mode, version?, apply?, restart?}`: `mode` `auto`, `pinned` (+ `version`), `latest` or `exploit:<id>`; `apply` `now` closes the farm's clients after a change (Close all). Answers `{previous: {version, follow}, version, follow, closed}`; the page's Undo sends `previous` back. |
| POST `/api/roblox/protocol` | yes | `{enabled}` → turns **Roblox links use this build** on or off and applies or restores the keys at once. |
| POST `/api/roblox/exploits` | yes | `{ids}` → the build the selected exploits all support, or the conflict. |

`robloxVersionsDir` is set through `/api/vault/settings`.
