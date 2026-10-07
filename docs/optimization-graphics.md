# Graphics optimization: requests, not verified runtime effects

## Player Fast Flag status

Checked against Roblox's official announcement on **October 7, 2026**. The announcement was published September 29, 2025; its first post was last edited October 16, 2025. Its live `.json` endpoint was read directly, including the `Roblox` first-post author and the complete allowlist.[1]

Roblox says Player only recognizes locally configured flags on its allowlist; unlisted `ClientAppSettings.json` flags are ignored. The list can change. Studio is explicitly exempt from this Player restriction.[1]

| Setting merged by ArkuzoSaver | JSON value | Official Player allowlist at review |
| --- | --- | --- |
| `DFFlagTextureQualityOverrideEnabled` | `"True"` | Listed |
| `DFIntTextureQualityOverride` | `"0"` | Listed |
| `FIntDebugForceMSAASamples` | `"1"` | Listed |
| `DFIntTaskSchedulerTargetFps` | **`15` (number)** | **Not listed; ignored in standard Player** |

Allowlist membership above is from the official first post, not community replies.[1] The FPS entry is retained only as the explicitly requested configuration for a compatible environment; ArkuzoSaver does not unlock flags or bypass Player restrictions. Writing it is not evidence of an active 15-FPS cap. Texture/MSAA effects also need independent runtime measurement; this change does not claim a percentage saving or any per-client memory benchmark.

## What the merger does

The existing graphics opt-in remains authoritative. Disabled graphics and `-MonitorOnly` perform no settings writes or installation discovery in the startup block.

- Discover Player installations from the available `LOCALAPPDATA`, `ProgramData`, `ProgramFiles` and `ProgramFiles(x86)` roots and observed `RobloxPlayerBeta.exe` image paths. No fixed drive letter is assumed. A target must contain `RobloxPlayerBeta.exe`; Studio-only directories are excluded.
- Merge the four entries above while retaining other JSON properties, including supported nested objects, arrays, booleans, null, Unicode and 64-bit integers.
- Reject unreadable/non-object/malformed/non-UTF-8 settings before replacement. PowerShell 5.1's unsupported deep JSON is refused rather than silently truncated. Existing rejected files remain byte-for-byte unchanged.
- For an existing file, write and flush a unique same-directory temporary file, recheck the observed original bytes, then use `File.Replace` with a unique `.arkuzo-<guid>.bak` path. The backup retains the exact preimage, including original formatting and BOM. There is no fallback that truncates the destination.
- For a new file, use same-directory `File.Move`; a file appearing before the move is not overwritten. Temporary files are removed on normal failure. A locked destination fails closed. The pre-replacement byte check detects observed edits, not a transaction with arbitrary non-cooperating writers; avoid simultaneous manual edits.

Successful startup prints **`Graphics flags REQUESTED`**, explicitly states that Player ignores the FPS flag, and does not claim actual FPS or rendering. The configuration persists after the controller exits and is intended for subsequent client launches, not live modification of existing clients.

To undo a changed existing settings file, stop affected clients, review the particular backup path, and restore that exact file to `ClientSettings/ClientAppSettings.json`. Do not choose a random/old backup or overwrite changes made later. If ArkuzoSaver created a new file, remove only that file after checking it contains no subsequent user settings. The controller does not automatically revert persistent graphics configuration.

## Conditional 3D render stop: automatic execution blocked

`RunService:Set3dRenderingEnabled` is **not documented** in the current public RunService reference or Roblox's maintained API source. This is not proof that every nonstandard environment lacks a similarly named function, but it does not establish a supported ordinary Player/LocalScript API.[2][4]

Read-only inspection found that this checkout's `Arkuzo-Volt-Control.ps1` supports **Status, Configure and LaunchMissing**, not script submission. The read-only Status call returned `available: false` with `Volt manager must be exactly one verified executable`. An already-active authorized Luau/injection context was therefore **not established**. No authenticated command lines, cookies, account databases or raw UI content were exported for this investigation.

Volt's official documentation describes `LuaStateProxy:Execute` as an **in-environment Lua-state** facility. That description is not a verified external PowerShell-to-Volt execution interface, proof of a bound active client, or documentation for this RunService method. The indexed official text was retrieved; direct documentation extraction returned HTTP 403.[5]

**Result:** no rendering-control integration, invented IPC, injector, security bypass, auto-executor-folder write or execution was added. No actual rendering change has been observed. A verified supported script interface, bound active authorized context, callable method and restoration behavior would all need validation before integrating this request.

### Guarded developer-only compatibility probe (not auto-executed)

This is documentation only, **not** a standard Roblox LocalScript recommendation or a tested rendering feature. Leave the gate false unless a developer has independently verified an authorized, already-active script context and documented callable implementation. The Boolean below does not detect or prove injection. Do not launch an injector or install a transport to use it.

The probe refuses missing/non-callable members, wraps both requests in `pcall`, schedules a five-second `true` restoration **before** requesting `false`, and also restores after a failed stop request. A successful `pcall` proves only that the call returned without error, not that rendering stopped. Restoration cannot be guaranteed if the process or scheduler terminates.

```luau
local VERIFIED_AUTHORIZED_ALREADY_ACTIVE_CONTEXT = false -- intentionally blocked
if not VERIFIED_AUTHORIZED_ALREADY_ACTIVE_CONTEXT then
    warn("3D render-stop blocked: an existing supported context is not verified")
    return
end

local RunService = game:GetService("RunService")
if not RunService:IsClient() then
    warn("3D render-stop blocked: not a client context")
    return
end

local accessible, setter = pcall(function()
    return RunService.Set3dRenderingEnabled
end)
if not accessible or typeof(setter) ~= "function" then
    warn("3D render-stop blocked: the requested method is unavailable")
    return
end

local function restore3D()
    local ok, reason = pcall(function()
        setter(RunService, true) -- reversible true restore request
    end)
    if not ok then
        warn("3D restoration request failed; restart the client: " .. tostring(reason))
    end
    return ok
end

local timerReady = pcall(function()
    task.delay(5, restore3D) -- schedule restoration before the stop request
end)
if not timerReady then
    warn("3D render-stop blocked: restoration timer could not be scheduled")
    return
end

local requested, reason = pcall(function()
    setter(RunService, false) -- request only; no measured effect asserted
end)
if not requested then
    restore3D()
    warn("3D stop request failed: " .. tostring(reason))
end
-- In this same verified context, restore3D() also requests true immediately.
```

## Fixture verification

`tests/saver/GraphicsFlags.Tests.ps1` loads only graphics function ASTs. It never executes the controller, discovers actual installations, changes native process settings, or accesses real Roblox settings. All writes use a GUID-named temporary fixture, removed in `finally`. `-FixtureRoot` allows routing it to the caller's scratch directory.

Executed with Windows PowerShell **5.1.22621.7376**, using the Hermes scratch directory. Real red/green results:

- Initial RED, exit 1: `FAIL: 15-FPS settings merger is missing`.
- Subsequent REDs, each exit 1: invalid array not refused; missing original-file backup; missing dynamic discovery helper; missing guarded startup helper.
- Final GREEN, exit 0: **8 fixture cases passed; real Roblox settings were not accessed.** Coverage includes numeric FPS/unknown properties, invalid roots, unique exact-byte backups, dynamic paths, disabled/monitor-only startup, failed atomic replacement, BOM/Unicode/large-integer preservation and invalid UTF-8, and deep-JSON refusal.

Run from the checkout:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\saver\GraphicsFlags.Tests.ps1
```

The Luau probe was not executed or runtime-validated. No live FPS/rendering/memory benefit is claimed. Existing deployed/legacy controllers were not changed, restarted or published.

## Sources

[1] https://devforum.roblox.com/t/allowlist-for-local-client-configuration-via-fast-flags/3966569 — Roblox official Fast Flag allowlist
[2] https://create.roblox.com/docs/reference/engine/classes/RunService — Roblox RunService reference
[4] https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/classes/RunService.yaml — Roblox maintained RunService API source
[5] https://docs.voltbz.net/docs/luastateproxy — Volt official LuaStateProxy documentation (retrieved indexed text)
