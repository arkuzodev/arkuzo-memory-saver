#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'),[ref]$t,[ref]$e)
foreach($f in $a.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Assert([bool]$ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('log-test-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($scratch)|Out-Null
try{
 $time=[datetime]::SpecifyKind([datetime]'2026-10-07T12:00:00',[DateTimeKind]::Utc)
 $file=Join-Path $scratch '0.1_20261007T120000Z_Player_TEST_last.log'
 [IO.File]::WriteAllText($file,'websiteBTId is 123456789')
 Assert (-not (Find-RobloxProcessLog -TargetProcessId 77 -TrackerId '' -StartTimeUtc $time -LogsDir $scratch)) 'No timestamp-only fallback may bind an unrelated client disconnect log'
 Assert ((Find-RobloxProcessLog -TargetProcessId 77 -TrackerId '123456789' -StartTimeUtc $time -LogsDir $scratch) -eq $file) 'Exact tracker and generation time must bind the proper log'
 Assert (-not (Find-RobloxProcessLog -TargetProcessId 77 -TrackerId '123456789' -StartTimeUtc $time.AddHours(1) -LogsDir $scratch)) 'A stale log for a reused tracker must not authorize recovery'
 Write-Output 'PASS: exact log identity; no timestamp inference or stale generation'
}finally{[IO.Directory]::Delete($scratch,$true)}
