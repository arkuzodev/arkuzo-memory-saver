#requires -Version 5.1
# A new client is left alone during startup (10-11 Nov: three blue screens, each while a client the
# saver had started seconds earlier was dying at start and was being worked on from outside):
#  - no priority, affinity, memory priority or limit is read or set before health.config_grace_sec
#    and a window (or an answer); the decision latches;
#  - every native step is skipped for a client that has exited or that the saver is closing;
#  - restoring on exit does nothing for a client that was never configured;
#  - the main loop reaches the native calls only through these functions.
# No real process is touched: the client is a stand-in object and the native calls are recorded.
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
# Stand-ins for the native calls: record, never touch a process.
$script:native = New-Object Collections.ArrayList
function Read-ArkuzoClientLimits($Client) { [void]$script:native.Add('ReadLimits'); return [uint64[]]@(1, 2, 0) }
function Read-ArkuzoClientMemoryPriority($Client) { [void]$script:native.Add('ReadMemoryPriority'); return [uint32]5 }
function Set-ArkuzoClientMemoryPriority($Client, [uint32]$Value) { [void]$script:native.Add("SetMemoryPriority:$Value") }
function Set-ArkuzoClientLimits($Client, [uint64]$Min, [uint64]$Max, [uint32]$Flags) { [void]$script:native.Add("SetLimits:$Flags") }
function Get-ArkuzoClientAffinityMask($Original, [int]$Slot, [int]$Cores) { [void]$script:native.Add('Affinity'); return [IntPtr]3 }
function Invoke-ArkuzoClientTrim($Client) { [void]$script:native.Add('Trim') }
$Priority = 'BelowNormal'; $MemoryPriority = 'Low'; $CoresPerInstance = 2; $SoftLimit = $false; $maxBytes = [int64]850MB; $limitFlags = [uint32]5; $MaxRamMB = 850; $MonitorOnly = $false
$healthPolicy = Get-ArkuzoHealthPolicy @{ enabled = $true }

function New-FakeClient([int]$ExitAfterRefreshes = -1) {
    $c = [pscustomobject]@{ Id = 4242; PriorityClass = 'Normal'; ProcessorAffinity = [IntPtr]255; HasExited = $false; Refreshes = 0; ExitAfter = $ExitAfterRefreshes
        StartTime = [datetime]::Now.AddSeconds(-60); MainWindowHandle = [IntPtr]::Zero; Handle = [IntPtr]1 }
    $c | Add-Member -MemberType ScriptMethod -Name Refresh -Value { $this.Refreshes++; if ($this.ExitAfter -ge 0 -and $this.Refreshes -gt $this.ExitAfter) { $this.HasExited = $true } }
    return $c
}
function New-State { return @{ StartTicks = 1; Slot = 0; Priority = $null; Affinity = $null; Limits = $null; MemoryPriority = $null; MemoryPriorityChanged = $false; LimitsChanged = $false
        Configured = $false; ConfigReady = $false; Closing = $false; RecoveryRequested = $false; EverResponded = $false; LastConfig = -1e6; MinimizedByUs = $false } }

# ---- the setting ----
Assert ($healthPolicy.config_grace_sec -eq 20) 'config_grace_sec defaults to 20 s'
$threw = $false; try { Get-ArkuzoHealthPolicy @{ config_grace_sec = 5 } | Out-Null } catch { $threw = $true }
Assert $threw 'config_grace_sec below 10 s is refused'
Assert ((Get-ArkuzoHealthPolicy @{ config_grace_sec = 45 }).config_grace_sec -eq 45) 'config_grace_sec is configurable'

# ---- readiness ----
$s = New-State
Assert (-not (Test-ArkuzoClientConfigReady $s 3 $true 20)) 'a 3 s old client with a window is not configured'
Assert (-not (Test-ArkuzoClientConfigReady $s 19.9 $true 20)) 'not before the grace'
Assert (-not (Test-ArkuzoClientConfigReady $s 60 $false 20)) 'old enough but no window and never answered: not yet'
Assert ((Test-ArkuzoClientConfigReady $s 20 $true 20) -and $s.ConfigReady) 'grace reached with a window'
Assert (Test-ArkuzoClientConfigReady $s 25 $false 20) 'latched: a window that goes away later does not undo it'
$s = New-State; $s.EverResponded = $true
Assert (Test-ArkuzoClientConfigReady $s 21 $false 20) 'a client that answered once counts like a window'
$s = New-State; $s.RecoveryRequested = $true
Assert (-not (Test-ArkuzoClientConfigReady $s 600 $true 20)) 'never a client the saver is closing'
$s = New-State; $s.ConfigReady = $true; $s.Closing = $true
Assert (-not (Test-ArkuzoClientConfigReady $s 600 $true 20)) 'closing wins over the latch'

# ---- configuration ----
$c = New-FakeClient; $s = New-State; $s.ConfigReady = $true
$script:native.Clear(); $script:events.Clear()
Assert (Invoke-ArkuzoClientConfiguration $c $s 100) 'configured'
Assert ($s.Configured -and [string]$s.Priority -ceq 'Normal' -and [int64]$s.Affinity -eq 255 -and $s.MemoryPriority -eq 5) 'originals captured at the first configuration'
Assert ((@($script:native) -join ',') -ceq 'ReadLimits,ReadMemoryPriority,Affinity,SetMemoryPriority:2,SetLimits:5') ('native calls in order: ' + (@($script:native) -join ','))
Assert ([string]$c.PriorityClass -ceq 'BelowNormal' -and [int64]$c.ProcessorAffinity -eq 3) 'priority and affinity applied'
Assert (@($script:events | Where-Object { $_.kind -ceq 'RESOURCE_CONFIGURATION_REQUESTED' -and $_.data.originalPriority -ceq 'Normal' -and $_.data.graceSec -eq 20 }).Count -eq 1) 'logged once with the originals'
$script:native.Clear(); $c.PriorityClass = 'Normal'
[void](Invoke-ArkuzoClientConfiguration $c $s 110)
Assert ((@($script:native) -join ',') -ceq 'Affinity,SetMemoryPriority:2,SetLimits:5' -and [string]$s.Priority -ceq 'Normal') 'reapplied without reading the originals again'
# Exited: nothing at all.
$c = New-FakeClient 0; $s = New-State; $s.ConfigReady = $true; $script:native.Clear()
Assert (-not (Invoke-ArkuzoClientConfiguration $c $s 100)) 'an exited client is skipped'
Assert ($script:native.Count -eq 0 -and [string]$c.PriorityClass -ceq 'Normal' -and -not $s.Configured) 'no native call on an exited client'
# Exits part-way: the remaining steps are skipped.
$c = New-FakeClient 2; $s = New-State; $s.ConfigReady = $true; $script:native.Clear()
[void](Invoke-ArkuzoClientConfiguration $c $s 100)
Assert ((@($script:native) -join ',') -ceq 'ReadLimits,ReadMemoryPriority') ('a client that exits stops the configuration at once: ' + (@($script:native) -join ','))
# Being closed: nothing.
$c = New-FakeClient; $s = New-State; $s.ConfigReady = $true; $s.Closing = $true; $script:native.Clear()
Assert (-not (Invoke-ArkuzoClientConfiguration $c $s 100) -and $script:native.Count -eq 0) 'a client the saver is closing is never touched'
# Soft limit: no hard limit; no memory priority read = none set.
$c = New-FakeClient; $s = New-State; $s.ConfigReady = $true; $script:native.Clear(); $SoftLimit = $true
function Read-ArkuzoClientMemoryPriority($Client) { throw 'access denied' }
[void](Invoke-ArkuzoClientConfiguration $c $s 100)
Assert ((@($script:native) -join ',') -ceq 'ReadLimits,Affinity' -and -not $s.MemoryPriorityChanged -and -not $s.LimitsChanged) 'only what can be restored is changed'
$SoftLimit = $false
function Read-ArkuzoClientMemoryPriority($Client) { [void]$script:native.Add('ReadMemoryPriority'); return [uint32]5 }

# ---- restore on exit ----
$c = New-FakeClient; $c | Add-Member -Force -NotePropertyName StartTime -NotePropertyValue ([datetime]::new(1, [DateTimeKind]::Utc).AddTicks(1)); $s = New-State
$s.StartTicks = $c.StartTime.ToUniversalTime().Ticks
$script:native.Clear(); $script:events.Clear()
Restore-Client $c $s
Assert ($script:native.Count -eq 0 -and [string]$c.PriorityClass -ceq 'Normal' -and $script:events.Count -eq 0) 'a client that was never configured is not touched on exit'
$s.ConfigReady = $true; [void](Invoke-ArkuzoClientConfiguration $c $s 1)
$script:native.Clear(); $script:events.Clear()
Restore-Client $c $s
Assert ([string]$c.PriorityClass -ceq 'Normal' -and [int64]$c.ProcessorAffinity -eq 255) 'configured: priority and affinity put back'
Assert ((@($script:native) -join ',') -ceq 'SetMemoryPriority:5,SetLimits:10') ('configured: memory priority and limits put back: ' + (@($script:native) -join ','))
$c.HasExited = $true; $script:native.Clear()
Restore-Client $c $s
Assert ($script:native.Count -eq 0) 'nothing is restored on a client that has exited'

# ---- the main loop only reaches native calls through these functions ----
$allowed = @{ ReadLimits = 'Read-ArkuzoClientLimits'; ReadMemoryPriority = 'Read-ArkuzoClientMemoryPriority'; SetMemoryPriority = 'Set-ArkuzoClientMemoryPriority'
    SetLimits = 'Set-ArkuzoClientLimits'; Affinity = 'Get-ArkuzoClientAffinityMask'; Trim = 'Invoke-ArkuzoClientTrim' }
foreach ($member in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -ceq '[Arkuzo.MemorySaverNativeV1]' -and $allowed.ContainsKey($n.Member.Extent.Text) }, $true)) {
    $p = $member; while ($null -ne $p -and -not ($p -is [Management.Automation.Language.FunctionDefinitionAst])) { $p = $p.Parent }
    Assert ($null -ne $p -and $p.Name -ceq $allowed[$member.Member.Extent.Text]) ('native ' + $member.Member.Extent.Text + ' only inside its wrapper (found at line ' + $member.Extent.StartLineNumber + ')')
}
$engineText = [IO.File]::ReadAllText($source)
$firstContact = $engineText.Substring($engineText.IndexOf("Mark('client ' + `$id + ': first contact')"), 2500)
Assert ($firstContact -notmatch '\$client\.(PriorityClass|ProcessorAffinity|Handle)\b' -and $firstContact -notmatch 'ReadLimits|ReadMemoryPriority') 'first contact reads nothing from the process'
Assert ($engineText -match '(?s)Test-ArkuzoClientConfigReady \$state .{0,200}\$healthPolicy\.config_grace_sec.{0,40}\)\)\) \{\s+\[void\]\(Invoke-ArkuzoClientConfiguration \$client \$state \$now\)') 'the loop configures only through the readiness gate'
Assert ($engineText -match 'Test-ArkuzoClientLive \$client\)\) \{\s+try \{\s+\$beforeMB = \$client\.WorkingSet64 / 1MB\s+Invoke-ArkuzoClientTrim') 'a trim checks the client is still there'
Write-Host "ClientConfigGrace: $script:checks checks passed"
