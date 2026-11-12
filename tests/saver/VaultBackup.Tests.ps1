#requires -Version 5.1
# The engine's side of the crash-safe vault (docs/accounts.md):
#  - every durable JSON write goes through a FileStream flushed with Flush($true) before the
#    replace; only the heartbeat is written -Volatile;
#  - a save keeps the validated previous content as accounts.json.bak and one snapshot per hour,
#    rotated by the same rule as the Control Center;
#  - a damaged accounts.json is never written by the engine and is read, read-only, from the
#    newest valid backup (logged once); launches wait until the Control Center restores it;
#  - the Control Center restores from a .bak the engine wrote.
# Temp folders and a test-only mutex name only; cookies are opaque placeholders, never decrypted.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
$script:events = New-Object Collections.ArrayList
function Write-Diagnostic($kind, $data) { [void]$script:events.Add(@{ kind = $kind; data = $data }) }
function Warn-Throttled($key, $message) { }
$script:NativeVaultMutexName = 'Local\ArkuzoAccountVault-Test-' + [guid]::NewGuid().ToString('N')
$script:VaultSnapshotKeep = 72; $script:VaultSnapshotDays = 7; $script:vaultFallbackSource = $null
$DataDirectory = Join-Path ([IO.Path]::GetTempPath()) ('arkuzo-vault-backup-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
$vaultPath = Join-Path $DataDirectory 'accounts.json'
$A = '11111111-1111-4111-8111-111111111111'
function New-TestVault([string]$Name) {
    return [pscustomobject]@{ schemaVersion = 1; settings = [pscustomobject]@{ farmRunning = $true }
        accounts = @([pscustomobject]@{ id = $A; userId = 101; username = $Name; cookie = 'dpapi:UExBQ0VIT0xERVI='; cookieStatus = 'alive'; browserTrackerId = '123456789012'; lastError = $null }) }
}
function Snapshots { @(Get-ChildItem -LiteralPath (Join-Path $DataDirectory 'vault-backups') -Filter 'accounts-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending) }
$python = Get-Command python3.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $python) { $python = Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
$cc = Join-Path $root 'src/saver/Arkuzo-Control-Center.py'
function Invoke-Py([string]$Code) {
    $script = "import importlib.util,sys`nspec=importlib.util.spec_from_file_location('cc',r'$cc')`ncc=importlib.util.module_from_spec(spec);spec.loader.exec_module(cc)`ncc.VAULT_MUTEX=r'$($script:NativeVaultMutexName)'`n" + $Code
    $out = $script | & $python.Source -B -
    if ($LASTEXITCODE -ne 0) { throw 'python failed' }
    return ($out -join "`n").Trim()
}

try {
    # ---- durable writes ----
    $durable = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-ArkuzoDurableBytes' }, $true) | Select-Object -First 1
    Assert ($durable.Extent.Text -match 'Flush\(\$true\)' -and $durable.Extent.Text -match 'WriteThrough') 'durable writes flush to the disk (FlushFileBuffers)'
    $engineText = [IO.File]::ReadAllText($source)
    $volatileCalls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -ceq 'Volatile' -and $null -eq $n.Argument }, $true))
    $functionOf = { param($n) $p = $n; while ($null -ne $p -and -not ($p -is [Management.Automation.Language.FunctionDefinitionAst])) { $p = $p.Parent }; $p.Name }
    Assert ($volatileCalls.Count -eq 1 -and (& $functionOf $volatileCalls[0]) -ceq 'Write-ArkuzoRuntimeStatus') 'only the heartbeat is written without a flush'
    Assert ($engineText -notmatch "WriteAllText\(\`$Path, \`$json") 'config.json is no longer written in place'
    # Record every write's flush mode while the real writer runs.
    $script:writes = New-Object Collections.ArrayList
    $realWriter = ${function:Write-ArkuzoDurableBytes}
    function Write-ArkuzoDurableBytes([string]$Path, [byte[]]$Bytes, [switch]$Volatile, [switch]$CreateNew) {
        [void]$script:writes.Add(@{ name = [IO.Path]::GetFileName($Path); volatile = [bool]$Volatile })
        & $realWriter -Path $Path -Bytes $Bytes -Volatile:$Volatile -CreateNew:$CreateNew
    }

    # ---- saves keep a validated .bak and an hourly snapshot ----
    Save-ArkuzoVaultFile (New-TestVault 'First')
    $first = [IO.File]::ReadAllBytes($vaultPath)
    Assert (-not (Test-Path -LiteralPath ($vaultPath + '.bak'))) 'no .bak before there was a vault'
    Assert ((Snapshots).Count -eq 1) 'first save writes the hour''s snapshot'
    Assert (@($script:writes | Where-Object { $_.volatile }).Count -eq 0 -and $script:writes.Count -eq 2) 'vault and snapshot writes are flushed'
    Save-ArkuzoVaultFile (New-TestVault 'Second')
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($vaultPath + '.bak')) -ceq [Convert]::ToBase64String($first)) '.bak holds the exact previous content'
    Assert ((Snapshots).Count -eq 1) 'at most one snapshot per hour'
    Assert ((Read-ArkuzoVaultFile).accounts[0].username -ceq 'Second') 'the new vault is saved'
    $script:writes.Clear()
    Assert (Invoke-ArkuzoVaultLocked { [bool](Update-ArkuzoVaultAccount $A @{ lastError = 'x' }) }) 'account update saves'
    Assert ((Read-ArkuzoVaultFile).accounts[0].lastError -ceq 'x') 'account update content'
    Assert (@($script:writes | Where-Object { $_.name -ceq 'accounts.json.bak.' + $PID + '.tmp' }).Count -eq 1 -and @($script:writes | Where-Object { $_.volatile }).Count -eq 0) 'update writes a flushed .bak first'
    $script:recoveryStatePath = Join-Path $DataDirectory 'recovery-state.json'; $script:ownsControllerMutex = $true; $script:recoveryJournalCorrupt = $false
    $script:recoveryAttempts = @(); $script:launchAttempts = @(); $script:recoveryPending = @{}; $script:quarantinedAccounts = @{}
    $script:writes.Clear(); Save-ArkuzoRecoveryJournal
    Assert ($script:writes.Count -eq 1 -and -not $script:writes[0].volatile) 'the recovery journal is flushed'
    $script:writes.Clear(); Save-ArkuzoAtomicJson (Join-Path $DataDirectory 'hb.json') @{ a = 1 } -Volatile
    Assert ($script:writes.Count -eq 1 -and $script:writes[0].volatile) '-Volatile reaches the writer'

    # ---- a damaged vault: never written, read from the newest valid backup ----
    $good = [IO.File]::ReadAllBytes($vaultPath)
    $bakBefore = [IO.File]::ReadAllBytes($vaultPath + '.bak')
    [IO.File]::WriteAllBytes($vaultPath, (New-Object byte[] 28182))
    $threw = $false; try { Invoke-ArkuzoVaultLocked { Update-ArkuzoVaultAccount $A @{ lastError = 'y' } } | Out-Null } catch { $threw = $true }
    Assert $threw 'a write on a damaged vault fails'
    Assert (@([IO.File]::ReadAllBytes($vaultPath) | Where-Object { $_ -ne 0 }).Count -eq 0) 'the damaged file is left as it is'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($vaultPath + '.bak')) -ceq [Convert]::ToBase64String($bakBefore)) 'the .bak is not touched'
    $threw = $false; try { Read-ArkuzoVaultFile -Strict | Out-Null } catch { $threw = $true }
    Assert $threw '-Strict never falls back'
    $script:events.Clear()
    $fallback = Read-ArkuzoVaultFile
    Assert ($fallback.accounts[0].username -ceq 'Second') 'reads accounts.json.bak'
    Assert ($script:vaultFallbackSource -ceq ($vaultPath + '.bak')) 'fallback recorded'
    [void](Read-ArkuzoVaultFile); [void](Read-ArkuzoVaultFile)
    $logged = @($script:events | Where-Object { $_.kind -ceq 'VAULT_READ_FROM_BACKUP' })
    Assert ($logged.Count -eq 1 -and $logged[0].data.backup -ceq 'accounts.json.bak') 'logged once'
    # Launches wait while the vault is read from a backup.
    $script:MonitorOnly = $false
    $r = Invoke-ArkuzoNativeLaunch $A '123456789012'
    Assert (-not $r.requestAccepted -and $r.reason -match 'damaged') 'no launch from a backup'
    # Requests in a backup are never carried out: a stale Close must not close a live client.
    $script:accountProvider = 'arkuzo'
    $script:killed = 0
    $watcher = [pscustomobject]@{ Id = 4242 }; $watcher | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:killed++ }
    $script:tracked = @{ 4242 = @{ TrackerId = '123456789012'; Watcher = $watcher; StartTicks = 1 } }
    function Test-ArkuzoClientIdentity($Watcher, $ClientId, $StartTicks) { return $true }
    $script:voltControlStatus = [pscustomobject]@{ available = $true; accounts = @([pscustomobject]@{ accountId = $A; username = 'Second'; trackerId = '123456789012'; closeRequestedAtMs = 1794000000000; launchRequestedAtMs = 0; processId = 4242; uiStatus = 'Connected' }) }
    Invoke-ArkuzoNativeRequests
    Assert ($script:killed -eq 0) 'no Close request is carried out from a backup'
    $script:vaultFallbackSource = $null; Invoke-ArkuzoNativeRequests
    Assert ($script:killed -eq 1) '(the same request is carried out from the real vault)'
    $script:vaultFallbackSource = $vaultPath + '.bak'; $script:tracked = @{}
    # A bad .bak: the newest valid snapshot wins.
    [IO.File]::WriteAllText($vaultPath + '.bak', '{"accounts": [')
    $dir = Join-Path $DataDirectory 'vault-backups'
    Get-ChildItem -LiteralPath $dir | Remove-Item -Force
    $older = (New-TestVault 'Older') | ConvertTo-Json -Depth 6; $newer = (New-TestVault 'Newer') | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $dir 'accounts-20261110-08.json'), $older)
    [IO.File]::WriteAllText((Join-Path $dir 'accounts-20261110-09.json'), $newer)
    [IO.File]::WriteAllText((Join-Path $dir 'accounts-20261110-10.json'), '[]')
    $script:events.Clear()
    Assert ((Read-ArkuzoVaultFile).accounts[0].username -ceq 'Newer') 'newest valid snapshot'
    Assert (@($script:events | Where-Object { $_.data.backup -ceq 'accounts-20261110-09.json' }).Count -eq 1) 'the new source is logged'
    # No valid copy at all: refuse, never crash the caller's loop beyond a throw it already catches.
    Get-ChildItem -LiteralPath $dir | Remove-Item -Force
    Remove-Item -LiteralPath ($vaultPath + '.bak')
    $threw = $false; try { Read-ArkuzoVaultFile | Out-Null } catch { $threw = $true }
    Assert $threw 'no valid copy: the read fails'
    $status = Get-ArkuzoNativeStatus @()
    Assert (-not $status.available) 'the account status is unavailable, the loop goes on'
    Assert (@([IO.File]::ReadAllBytes($vaultPath) | Where-Object { $_ -ne 0 }).Count -eq 0) 'still untouched'

    # ---- the Control Center restores from the engine's .bak ----
    [IO.File]::WriteAllBytes($vaultPath, $good)
    Save-ArkuzoVaultFile (New-TestVault 'Third')
    [IO.File]::WriteAllBytes($vaultPath, (New-Object byte[] 4096))
    $names = Invoke-Py "from pathlib import Path`nv=cc.load_vault(Path(r'$DataDirectory'))`nprint(','.join(a['username'] for a in v['accounts']))"
    Assert ($names -ceq 'Second') 'Control Center restores the engine-written .bak'
    Assert ((Read-ArkuzoVaultFile).accounts[0].username -ceq 'Second' -and (Read-ArkuzoVaultFile -Strict).accounts[0].username -ceq 'Second') 'engine reads the restored file normally'
    Assert ($null -eq $script:vaultFallbackSource) 'fallback cleared'
    Assert (@(Get-ChildItem -LiteralPath $DataDirectory -Filter 'accounts.json.damaged-*').Count -eq 1) 'damaged copy kept'

    # ---- rotation: the same rule on both sides ----
    $now = [datetime]::new(2026, 11, 11, 21, 30, 0, [DateTimeKind]::Utc)
    $all = @(0..287 | ForEach-Object { 'accounts-' + $now.AddHours(-$_).ToString('yyyyMMdd-HH') + '.json' }) + @('accounts-latest.json')
    $removeEngine = @((Get-ArkuzoVaultSnapshotsToRemove $all $now) | Sort-Object)
    $pyList = ($all | ForEach-Object { "'" + $_ + "'" }) -join ','
    $removePython = @((Invoke-Py "import datetime as dt`nnow=dt.datetime(2026,11,11,21,30,tzinfo=dt.timezone.utc)`nprint('\n'.join(sorted(cc.vault_snapshots_to_remove([$pyList], now))))") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Assert ($removeEngine.Count -eq 288 - 76) 'engine keeps 72 + 4 days'
    Assert ((@($removeEngine) -join ',') -ceq (@($removePython) -join ',')) 'engine and Control Center rotate identically'
    Assert ($removeEngine -notcontains 'accounts-latest.json') 'foreign names are never removed'
    Get-ChildItem -LiteralPath $dir | Remove-Item -Force
    foreach ($h in 1..99) { [IO.File]::WriteAllText((Join-Path $dir ('accounts-' + $now.AddHours(-$h).ToString('yyyyMMdd-HH') + '.json')), '{"accounts":[]}') }
    Assert (Save-ArkuzoVaultSnapshot ([Text.Encoding]::UTF8.GetBytes('{"accounts":[]}')) $now) 'snapshot written'
    Assert (-not (Save-ArkuzoVaultSnapshot ([Text.Encoding]::UTF8.GetBytes('{"accounts":[1]}')) $now)) 'one per hour'
    Assert ((Snapshots).Count -eq 73) 'pruned to 72 + one older day'
    Write-Host "VaultBackup: $script:checks checks passed"
} finally {
    Remove-Item -LiteralPath $DataDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
