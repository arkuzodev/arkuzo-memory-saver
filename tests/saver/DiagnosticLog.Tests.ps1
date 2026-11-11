#requires -Version 5.1
# Diagnostic log: a failed write pauses logging and reopens a new part instead of
# latching for the session. Only temporary folders are used.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
foreach ($name in @('Open-DiagnosticLog', 'Step-ArkuzoDiagnosticLogPart', 'Write-Diagnostic', 'Invoke-ArkuzoLogRetention')) {
    $f = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name }, $false))
    if ($f.Count -ne 1) { throw "$name must exist exactly once" }
    . ([scriptblock]::Create($f[0].Extent.Text))
}
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('arkuzo-log-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    $script:LogDirectory = $scratch; $script:MaxLogMB = 10; $script:sessionTag = '20261110-120000-4242'
    $script:logWriter = $null; $script:logPath = ''; $script:logPart = 0; $script:logFailed = $false
    $script:LogRetrySec = 5; $script:logRetryUtc = $null; $script:logFailureCount = 0
    $script:dashboardIssues = @{}; $script:clock = $null

    Write-Diagnostic 'FIRST' @{ n = 1 }
    Assert (-not $script:logFailed -and (Test-Path -LiteralPath (Join-Path $scratch "Arkuzo-$sessionTag-part0.log"))) 'a normal write lands in part 0'

    # A writer that fails (disk full, file locked by a scanner, handle gone).
    $script:logWriter.Dispose()
    $broken = New-Object psobject
    $broken | Add-Member NoteProperty BaseStream ([pscustomobject]@{ Length = 0 })
    $broken | Add-Member ScriptMethod WriteLine { throw 'disk full' }
    $broken | Add-Member ScriptMethod Dispose { }
    $script:logWriter = $broken
    Write-Diagnostic 'LOST' @{ n = 2 }
    Assert ($script:logFailed -and $null -ne $script:logRetryUtc -and $null -eq $script:logWriter) 'a failed write sets logFailed, schedules a retry and drops the writer'
    Assert ($script:dashboardIssues.ContainsKey('log-write')) 'the failure is shown on the dashboard'

    # Inside the pause nothing is written and logFailed stays set: audited steps (a write,
    # then "if ($logFailed) { throw }") keep refusing.
    Write-Diagnostic 'DURING_PAUSE' @{ n = 3 }
    Assert ($script:logFailed -and @(Get-ChildItem -LiteralPath $scratch -Filter '*.log').Count -eq 1) 'during the pause nothing is written and logFailed stays set'

    # After the pause a new part opens and logging carries on: no latch for the session.
    $script:logRetryUtc = [datetime]::UtcNow.AddSeconds(-1)
    Write-Diagnostic 'AFTER_PAUSE' @{ n = 4 }
    $part1 = Join-Path $scratch "Arkuzo-$sessionTag-part1.log"
    Assert (-not $script:logFailed -and $null -eq $script:logRetryUtc -and (Test-Path -LiteralPath $part1)) 'after the pause logging resumes in a new part and logFailed clears'
    $script:logWriter.Dispose(); $script:logWriter = $null
    $records = @(Get-Content -LiteralPath $part1 | ForEach-Object { $_ | ConvertFrom-Json })
    Assert ($records.Count -eq 2 -and $records[0].event -eq 'LOG_WRITE_RECOVERED' -and $records[0].data.failures -eq 1 -and $records[1].event -eq 'AFTER_PAUSE') 'the new part starts with a LOG_WRITE_RECOVERED record'
    Assert (((Get-Content -LiteralPath $part1) -join "`n") -notmatch 'disk full') 'no error text in the log'

    # logFailed set without a retry time (as some test fixtures do) starts a pause, not a write.
    $script:logFailed = $true; $script:logRetryUtc = $null
    Write-Diagnostic 'NO_RETRY_TIME' @{ }
    Assert ($script:logFailed -and $null -ne $script:logRetryUtc -and $null -eq $script:logWriter) 'logFailed without a retry time starts the pause first'

    # --- Retention across sessions: newest sessions kept within both caps; the current one always.
    $ret = Join-Path $scratch 'retention'
    [IO.Directory]::CreateDirectory($ret) | Out-Null
    function New-LogFile([string]$Name, [int]$KB) { [IO.File]::WriteAllBytes((Join-Path $ret $Name), (New-Object byte[] ($KB * 1024))) }
    $current = '20261101-080000-11'
    New-LogFile "Arkuzo-$current-part0.log" 2048          # current session, oldest stamp and 2 MB: always kept
    New-LogFile 'Arkuzo-20261109-100000-22-part0.log' 1024
    New-LogFile 'Arkuzo-20261109-100000-22-part1.log' 1024
    New-LogFile 'Arkuzo-20261108-100000-33-part0.log' 1024
    New-LogFile 'Arkuzo-20261107-100000-44-part0.log' 512
    New-LogFile 'Arkuzo-20261106-100000-55-part0.log' 10
    New-LogFile 'Arkuzo-Pagefile-Requests.json' 1             # same folder, not a session log
    New-LogFile 'control-center.log' 1
    New-LogFile 'saver-console.log' 1
    New-LogFile 'Arkuzo-20261105-100000-66-part0.log.bak' 1    # not an exact match: left alone
    # Size cap 5 MB: current (2) + newest other (2) = 4 MB; the next (1 MB) still fits = 5 MB; then full.
    $r = Invoke-ArkuzoLogRetention $ret $current 100 5
    $left = @(Get-ChildItem -LiteralPath $ret -File | ForEach-Object { $_.Name } | Sort-Object)
    Assert ($left -contains "Arkuzo-$current-part0.log") 'the current session is never deleted, even when it is the oldest'
    Assert ($left -contains 'Arkuzo-20261109-100000-22-part1.log' -and $left -contains 'Arkuzo-20261108-100000-33-part0.log') 'the newest sessions within the size cap are kept'
    Assert ($left -notcontains 'Arkuzo-20261107-100000-44-part0.log' -and $left -notcontains 'Arkuzo-20261106-100000-55-part0.log') 'once a session does not fit, it and every older one go'
    Assert ($left -contains 'Arkuzo-Pagefile-Requests.json' -and $left -contains 'control-center.log' -and $left -contains 'saver-console.log' -and $left -contains 'Arkuzo-20261105-100000-66-part0.log.bak') 'only exact session part files are touched'
    Assert ($r.deletedFiles -eq 2 -and $r.keptSessions -eq 3 -and $r.keptMB -eq 5) ('result counts files and sizes: ' + ($r | ConvertTo-Json -Compress))
    # Count cap: 2 sessions = the current one and the newest other.
    $r = Invoke-ArkuzoLogRetention $ret $current 2 1000
    $left = @(Get-ChildItem -LiteralPath $ret -File -Filter 'Arkuzo-2026*-part*.log' | ForEach-Object { $_.Name })
    Assert ($left.Count -eq 3 -and $left -notcontains 'Arkuzo-20261108-100000-33-part0.log' -and $r.keptSessions -eq 2) 'the session count cap keeps the current and the newest others'
    # A file that can't be deleted (held open) is skipped, nothing throws.
    $lock = [IO.File]::Open((Join-Path $ret 'Arkuzo-20261109-100000-22-part0.log'), 'Open', 'Read', 'None')
    try { $r = Invoke-ArkuzoLogRetention $ret $current 1 1000 } finally { $lock.Dispose() }
    Assert ($r.failed -eq 1 -and $r.deletedFiles -eq 1) 'an open file is skipped and counted, the rest deleted'
    Assert ((Invoke-ArkuzoLogRetention (Join-Path $scratch 'missing') $current 10 10).deletedFiles -eq 0) 'a missing folder is fine'

    Write-Host "PASS: diagnostic log recovers from a failed write in a new part; retention keeps the newest sessions within both caps ($script:checks checks)"
} finally {
    if ($null -ne $script:logWriter) { try { $script:logWriter.Dispose() } catch { } }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
