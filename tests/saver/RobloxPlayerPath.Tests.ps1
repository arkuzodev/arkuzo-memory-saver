$ErrorActionPreference = 'Stop'
# Which RobloxPlayerBeta.exe a launch starts (docs/roblox-versions.md):
#  - Auto: finds Program Files installs and Arkuzo's own Versions folder, prefers a complete version
#    folder over a newer one that only kept its locked files, then the newest player file.
#  - Pinned (vault robloxVersion): that build or nothing (unless robloxVersionFallback), never the
#    running build of another version, and a direct launch unless roblox-player: starts exactly
#    that build (registry read from a test key under HKCU\Software\ArkuzoTest, never Roblox's own).
$engine = Join-Path $PSScriptRoot '..\..\src\saver\Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $engine), [ref]$t, [ref]$e)
foreach ($name in @('Get-ArkuzoVaultSetting', 'Get-ArkuzoManagedVersionsRoot', 'Test-ArkuzoRobloxBuildComplete', 'Select-ArkuzoNewestRobloxBuild',
        'Get-ArkuzoRobloxInstalls', 'Get-ArkuzoRobloxPlayerPath', 'Get-ArkuzoProtocolPlayerPath', 'Resolve-ArkuzoRobloxPlayer', 'Update-ArkuzoRobloxVersionStatus', 'Get-ArkuzoRobloxVersionPreflight', 'Start-ArkuzoRobloxClient')) {
    $fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "$name not found" }
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:events = @()
function Write-Diagnostic($Kind, $Data) { $script:events += @(@{ kind = $Kind; data = $Data }) }

$failures = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name"; $script:failures++ } }

$root = Join-Path ([IO.Path]::GetTempPath()) ('arkuzo-playerpath-' + [guid]::NewGuid().ToString('N'))
$saved = @{ L = $env:LOCALAPPDATA; P = $env:ProgramFiles; X = ${env:ProgramFiles(x86)} }
function New-Install([string]$Base, [string]$Name, [bool]$Complete, [datetime]$When, [string]$CopyFrom = '') {
    $dir = Join-Path $Base $Name; New-Item -ItemType Directory -Force $dir | Out-Null
    $exe = Join-Path $dir 'RobloxPlayerBeta.exe'
    if ($CopyFrom) { Copy-Item -LiteralPath $CopyFrom -Destination $exe } else { Set-Content -LiteralPath $exe -Value 'x' }
    if ($Complete) { Set-Content -LiteralPath (Join-Path $dir 'AppSettings.xml') -Value '<Settings/>' }
    (Get-Item -LiteralPath $exe).LastWriteTimeUtc = $When
    return $exe
}
function New-Vault([hashtable]$Settings) { return [pscustomobject]@{ settings = [pscustomobject]$Settings; accounts = @() } }
try {
    $env:LOCALAPPDATA = Join-Path $root 'local'
    $env:ProgramFiles = Join-Path $root 'pf'
    ${env:ProgramFiles(x86)} = Join-Path $root 'pf86'
    $now = [datetime]::UtcNow

    # ---- Auto (the behaviour before pinning, unchanged) ----
    $pf = New-Install (Join-Path $env:ProgramFiles 'Roblox\Versions') 'version-new' $true $now.AddHours(-2)
    Check 'finds an install under Program Files' ((Get-ArkuzoRobloxPlayerPath @()) -eq $pf)
    $gutted = New-Install (Join-Path $env:LOCALAPPDATA 'Roblox\Versions') 'version-old' $false $now
    Check 'prefers a complete install over a newer gutted one' ((Get-ArkuzoRobloxPlayerPath @()) -eq $pf)
    $newest = New-Install (Join-Path $env:LOCALAPPDATA 'Roblox\Versions') 'version-newest' $true $now.AddMinutes(-1)
    Check 'newest complete install wins' ((Get-ArkuzoRobloxPlayerPath @()) -eq $newest)
    $running = @([pscustomobject]@{ path = $gutted }, [pscustomobject]@{ path = $pf })
    Check 'running builds: complete one preferred' ((Get-ArkuzoRobloxPlayerPath $running) -eq $pf)
    Check 'running build used when it is the only one' ((Get-ArkuzoRobloxPlayerPath @([pscustomobject]@{ path = $pf })) -eq $pf)
    Remove-Item -LiteralPath (Join-Path $env:ProgramFiles 'Roblox') -Recurse -Force
    Remove-Item -LiteralPath (Split-Path -Parent $newest) -Recurse -Force
    Check 'falls back to an incomplete install when nothing else exists' ((Get-ArkuzoRobloxPlayerPath @()) -eq $gutted)
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'Roblox') -Recurse -Force
    Check 'no install gives null' ($null -eq (Get-ArkuzoRobloxPlayerPath @()))

    # ---- Arkuzo's own Versions folder ----
    $managed = Join-Path $env:LOCALAPPDATA 'Arkuzo\Roblox\Versions'
    Check 'default managed folder' ((Get-ArkuzoManagedVersionsRoot $null) -eq $managed)
    Check 'robloxVersionsDir moves it' ((Get-ArkuzoManagedVersionsRoot (New-Vault @{ robloxVersionsDir = 'D:\Farm\Roblox' })) -eq 'D:\Farm\Roblox\Versions')
    Check 'a bad robloxVersionsDir is ignored' ((Get-ArkuzoManagedVersionsRoot (New-Vault @{ robloxVersionsDir = 'D:\a\..\..\b' })) -eq $managed)
    $staging = New-Install $managed 'not-a-version' $true $now.AddMinutes(5)
    $mine = New-Install $managed 'version-0123456789abcdef' $true $now.AddHours(-1)
    Check 'Auto finds builds in Arkuzo''s folder, and only version-<hash> folders there' ((Get-ArkuzoRobloxPlayerPath @()) -eq $mine)

    # ---- Pinned ----
    $other = New-Install (Join-Path $env:LOCALAPPDATA 'Roblox\Versions') 'version-1111111111111111' $true $now
    $running = @([pscustomobject]@{ path = $other })
    $pinVault = New-Vault @{ robloxVersion = 'version-0123456789abcdef' }
    $r = Resolve-ArkuzoRobloxPlayer $running $pinVault 'direct'
    Check 'pinned build is used, not the running build of another version' ($r.path -eq $mine -and $r.mode -ceq 'pinned' -and -not $r.problem)
    $noKey = 'HKCU:\Software\ArkuzoTest\' + [guid]::NewGuid().ToString('N') + '\roblox-player\shell\open\command'
    $r = Resolve-ArkuzoRobloxPlayer $running $pinVault 'protocol' $noKey
    Check 'a pin launches directly while roblox-player: starts another build' ($r.method -ceq 'direct' -and $r.path -eq $mine)
    $script:events = @(); Update-ArkuzoRobloxVersionStatus $r 'protocol'; Update-ArkuzoRobloxVersionStatus $r 'protocol'
    Check 'the protocol override is logged once' (@($script:events | Where-Object { $_.kind -ceq 'ROBLOX_VERSION_PROTOCOL_OVERRIDDEN' }).Count -eq 1)
    Check 'heartbeat block names the build' ($script:robloxVersionStatus.selectedVersion -ceq 'version-0123456789abcdef' -and $script:robloxVersionStatus.mode -ceq 'pinned')
    # roblox-player: pointed at the pinned build (the Roblox tab's protocol switch): Protocol is honoured.
    $testRoot = 'HKCU:\Software\ArkuzoTest\' + [guid]::NewGuid().ToString('N')
    $key = Join-Path $testRoot 'roblox-player\shell\open\command'
    try {
        New-Item -Path $key -Force | Out-Null
        Set-Item -LiteralPath $key -Value ('"' + $mine + '" %1')
        Check 'the protocol handler path is read from the command' ((Get-ArkuzoProtocolPlayerPath $key) -eq $mine)
        $r = Resolve-ArkuzoRobloxPlayer $running $pinVault 'protocol' $key
        Check 'a pin launches by protocol when roblox-player: starts exactly that build' ($r.method -ceq 'protocol' -and $r.path -eq $mine -and -not $r.problem)
        $script:robloxProtocolOverrideLogged = $false; $script:events = @(); Update-ArkuzoRobloxVersionStatus $r 'protocol'
        Check 'no override is logged when the protocol honours the pin' (@($script:events | Where-Object { $_.kind -ceq 'ROBLOX_VERSION_PROTOCOL_OVERRIDDEN' }).Count -eq 0 -and $script:robloxVersionStatus.method -ceq 'protocol')
        Set-Item -LiteralPath $key -Value ('"' + $other + '" %1')
        Check 'a handler pointing at another build means a direct launch' ((Resolve-ArkuzoRobloxPlayer $running $pinVault 'protocol' $key).method -ceq 'direct')
        Check 'direct stays direct whatever the handler' ((Resolve-ArkuzoRobloxPlayer $running $pinVault 'direct' $key).method -ceq 'direct')
    } finally { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $pinOther = New-Vault @{ robloxVersion = 'version-1111111111111111' }
    Check 'a pinned build is also found in Roblox''s own folder' ((Resolve-ArkuzoRobloxPlayer @() $pinOther 'direct').path -eq $other)

    Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $mine) 'AppSettings.xml') -Force
    $r = Resolve-ArkuzoRobloxPlayer $running $pinVault 'direct'
    Check 'an incomplete pinned build is not launched, nothing else either' ($null -eq $r.path -and $r.problem -match 'not installed')
    $script:events = @(); Update-ArkuzoRobloxVersionStatus $r 'direct'; Update-ArkuzoRobloxVersionStatus $r 'direct'
    Check 'a missing pin is logged once per change' (@($script:events | Where-Object { $_.kind -ceq 'ROBLOX_VERSION_PIN_MISSING' }).Count -eq 1 -and $script:robloxVersionStatus.problem)
    Check 'step 1 refuses before a ticket is requested' ((Get-ArkuzoRobloxVersionPreflight $pinVault) -match 'not installed')
    Check 'Auto needs no preflight' ((Get-ArkuzoRobloxVersionPreflight (New-Vault @{ robloxVersion = 'auto' })) -eq '')
    $threw = $false; try { [void](Start-ArkuzoRobloxClient 't' 'https://x' '1234567890' 'direct' @() $r) } catch { $threw = $_.Exception.Message -match 'Pinned' }
    Check 'the client start refuses a missing pin instead of using Roblox''s launcher' $threw
    $fallbackVault = New-Vault @{ robloxVersion = 'version-0123456789abcdef'; robloxVersionFallback = $true }
    $r = Resolve-ArkuzoRobloxPlayer $running $fallbackVault 'direct'
    Check 'with fall back on, the Auto choice is used and reported' ($r.path -eq $other -and $r.fallback -and $r.problem)
    Check 'with fall back on, step 1 lets the launch go ahead' ((Get-ArkuzoRobloxVersionPreflight $fallbackVault) -eq '')

    # ---- Auto with the protocol method keeps Roblox's launcher ----
    $r = Resolve-ArkuzoRobloxPlayer $running (New-Vault @{ robloxVersion = 'auto' }) 'protocol'
    Check 'Auto + protocol: Roblox''s launcher chooses' ($r.method -ceq 'protocol' -and $null -eq $r.path)
    $r = Resolve-ArkuzoRobloxPlayer $running (New-Vault @{ robloxVersion = 'version-XYZ' }) 'direct'
    Check 'a malformed pin counts as Auto' ($r.mode -ceq 'auto' -and $r.path -eq $other)
} finally {
    $env:LOCALAPPDATA = $saved.L; $env:ProgramFiles = $saved.P; ${env:ProgramFiles(x86)} = $saved.X
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
if ($failures -gt 0) { throw "$failures RobloxPlayerPath check(s) failed" }
Write-Host 'All RobloxPlayerPath checks passed.'
