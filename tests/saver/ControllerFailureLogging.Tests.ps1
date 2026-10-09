#requires -Version 5.1
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver/Arkuzo-Memory-Saver.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$null)
function Assert($ok,$message) { if (-not $ok) { throw $message } }
$f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-ArkuzoFailureDiagnostic'},$false)
Assert ($null -ne $f) 'Failure diagnostics must survive normal log failure without leaking error text'
. ([scriptblock]::Create($f.Extent.Text))
$root=Join-Path $env:TMPDIR ('arkuzo-failure-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $script:LogDirectory=$root; $script:sessionTag='fixture'; $script:controllerStartTicks=123L
    $script:logFailed=$false; $script:events=@()
    function Write-Diagnostic($kind,$data) { $script:events+=@{kind=$kind;data=$data} }
    try { throw ('SECRET_COOKIE='+('x'*20000)) } catch { $failure=$_ }
    Write-ArkuzoFailureDiagnostic 'SAVER_FATAL_ERROR' $failure
    Assert ($events.Count -eq 1 -and $events[0].kind -eq 'SAVER_FATAL_ERROR') 'Normal sink gets one structured fatal record'
    Assert (($events[0].data | ConvertTo-Json -Compress) -notmatch 'SECRET_COOKIE|xxxxx') 'No raw exception message or invocation source'
    Assert ($events[0].data.line -gt 0 -and $events[0].data.exceptionType) 'Record retains actionable source line and exception type'
    $script:logFailed=$true
    Write-ArkuzoFailureDiagnostic 'SAVER_FATAL_ERROR' $failure
    $path=Join-Path $root 'controller-failure.json'
    $text=[IO.File]::ReadAllText($path)
    Assert ($text.Length -lt 4096 -and $text -notmatch 'SECRET_COOKIE|xxxxx') 'Independent fallback is bounded and secret-free'
    $record=$text | ConvertFrom-Json
    Assert ($record.event -eq 'SAVER_FATAL_ERROR' -and $record.data.startTicks -eq 123 -and $record.session -eq 'fixture') 'Fallback binds controller generation and session'
    function Write-Diagnostic($kind,$data) { $script:logFailed=$true }
    $script:logFailed=$false
    Write-ArkuzoFailureDiagnostic 'SAVER_CLEANUP_ERROR' $failure
    $cleanupPath=Join-Path $root 'controller-cleanup-failure.json'
    Assert (Test-Path -LiteralPath $cleanupPath) 'Cleanup fallback must not overwrite the original fatal evidence'
    Assert (([IO.File]::ReadAllText($cleanupPath) | ConvertFrom-Json).event -eq 'SAVER_CLEANUP_ERROR') 'New normal-sink failure triggers fallback in the same call'
    Assert (([IO.File]::ReadAllText($path) | ConvertFrom-Json).event -eq 'SAVER_FATAL_ERROR') 'Original fatal fallback survives later cleanup failure'
    $lock=[IO.File]::Open($path,'Open','ReadWrite','None')
    try { Write-ArkuzoFailureDiagnostic 'SAVER_FATAL_ERROR' $failure } finally { $lock.Dispose() }
    Write-Output 'PASS: normal/failing sink, bounded private fallback, locked fallback never masks original failure'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
# Execute actual production catch/finally around fixture body; no controller startup or live process IO.
$main=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] -and $_.Extent.Text -match 'SESSION_STOP' })[-1]
Assert ($null -ne $main) 'Production lifecycle block found'
$script:logFailed=$false; $script:events=@(); $script:consoleReady=$false
$script:tracked=@{42=@{Watcher=$null}}; $script:trimCount=0
$script:clock=[Diagnostics.Stopwatch]::StartNew(); $script:ownsControllerMutex=$true
$script:released=$false; $script:disposed=$false; $script:writerDisposed=$false
$script:controllerMutex=New-Object psobject
$controllerMutex | Add-Member ScriptMethod ReleaseMutex { $script:released=$true }
$controllerMutex | Add-Member ScriptMethod Dispose { $script:disposed=$true }
$script:logWriter=New-Object psobject
$logWriter | Add-Member ScriptMethod Dispose { $script:writerDisposed=$true }
function Write-Host {}
function Get-Process { $p=New-Object psobject; $p | Add-Member ScriptMethod Dispose { throw 'fixture dispose failure' }; return $p }
function Restore-Client { throw 'fixture restore failure' }
function Write-Warning { throw 'fixture broken console' }
function Clear-VoltRecoveryCapability {}
function Write-ArkuzoFailureDiagnostic($kind,$errorRecord) { $script:events+=@{kind=$kind;data=$errorRecord} }
function Write-Diagnostic($kind,$data) { $script:events+=@{kind=$kind;data=$data} }
$block=[scriptblock]::Create('try { throw "fixture original fatal" } '+(($main.CatchClauses | ForEach-Object {$_.Extent.Text}) -join ' ')+' finally '+$main.Finally.Extent.Text)
try { . $block; throw 'Fatal was swallowed' } catch { Assert ($_.Exception.Message -eq 'fixture original fatal') 'Cleanup must preserve the original terminating error' }
Assert ($released -and $disposed -and $writerDisposed) 'Cleanup failure still releases lock and disposes diagnostic writer'
Assert (@($events | Where-Object kind -eq 'SAVER_CLEANUP_ERROR').Count -eq 1) 'Cleanup failure independently diagnosed'
Assert (@($events | Where-Object kind -eq 'SESSION_STOP').Count -eq 1) 'Cleanup failure does not skip terminal record'
Write-Output 'PASS: production lifecycle preserves fatal error and finalizes diagnostics/mutex despite cleanup failure'
