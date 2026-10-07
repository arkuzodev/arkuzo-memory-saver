#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'),[ref]$t,[ref]$e)
foreach($f in $a.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('journal-test-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($scratch)|Out-Null
try{
 $script:ownsControllerMutex=$true;$script:recoveryStatePath=Join-Path $scratch 'state.json';$script:recoveryPending=@{}
 $entry=@{accountId='11111111-1111-4111-8111-111111111111';oldPid=100;oldStartTicks=400;oldTrackerId='111';createdUtc=[datetime]::UtcNow.ToString('o');retryCount=2;nextRetryUtc=[datetime]::UtcNow.AddSeconds(360).ToString('o')}
 [IO.File]::WriteAllText($recoveryStatePath,(@{attempts=@();pending=@($entry);launchAttempts=@([datetime]::UtcNow.ToString('o'))}|ConvertTo-Json -Depth 6))
 Initialize-ArkuzoRecoveryJournal
 Assert ($script:recoveryPending.Count -eq 1) 'Controller restart must retain unresolved account restoration and retry backoff'
 Assert ($recoveryJournalHealthy) 'Valid pending journal must load'
 Assert ($script:recoveryPending[$entry.accountId].retryCount -eq 2) 'Retry history must survive'
 Save-ArkuzoRecoveryJournal
 $saved=[IO.File]::ReadAllText($recoveryStatePath)|ConvertFrom-Json
 Assert (@($saved.pending).Count -eq 1) 'Budget save must not drop unresolved accounts'
 [IO.File]::WriteAllText($recoveryStatePath,'{invalid')
 Initialize-ArkuzoRecoveryJournal
 Assert (-not $recoveryJournalHealthy) 'Corrupt journal must block kills, not reset limits'
 Write-Output 'PASS: persistent pending, retry history, atomic journal, fail-closed corruption'
}finally{[IO.Directory]::Delete($scratch,$true)}
