#requires -Version 5.1
<#
Runs the regression tests: every test file in its own process, all of them even
after a failure, with a summary at the end. Exit code 0 only when all passed.

  build/test.ps1                       everything
  build/test.ps1 -Filter FarmFreeze    only test files whose name matches (wildcards allowed)
  build/test.ps1 -Filter vault,Journal several patterns
  build/test.ps1 -List                 show what would run
  build/test.ps1 -Lint                 also run the report-only linters (build/lint.ps1)

In a git checkout only tracked (or staged) test files run, so a local, untracked
experiment in tests/ is never picked up. Outside git (a copied tree) every test
file in tests/ runs.
#>
[CmdletBinding()]
param(
    [string[]]$Filter = @(),
    [switch]$List,
    [switch]$Lint,
    [switch]$SkipLauncher
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
# powershell -File passes 'a,b' as one string.
$Filter = @($Filter | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# Several suites build fixtures under TMPDIR, which only Git Bash sets.
if (-not $env:TMPDIR) { $env:TMPDIR = [IO.Path]::GetTempPath() }

function Get-TestFiles([string]$Folder, [string]$Pattern) {
    # Tracked or staged files in a git checkout; every matching file elsewhere.
    $directory = Join-Path $root $Folder
    $names = $null
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $git -and (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        $listed = @(& $git.Source -C $root ls-files -- "$Folder/$Pattern" 2>$null)
        if ($LASTEXITCODE -eq 0) { $names = @($listed | ForEach-Object { Split-Path -Leaf $_ }) }
    }
    $files = @(Get-ChildItem -LiteralPath $directory -Filter $Pattern -File | Sort-Object Name)
    if ($null -ne $names) { $files = @($files | Where-Object { $names -contains $_.Name }) }
    return $files
}
function Test-Selected([string]$Name) {
    if ($Filter.Count -eq 0) { return $true }
    foreach ($pattern in $Filter) {
        if ($Name -like $pattern -or $Name -like ('*' + $pattern + '*')) { return $true }
    }
    return $false
}

$python = @('python3.exe', 'python.exe') | ForEach-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } | Select-Object -First 1
$powershell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) { $powershell = (Get-Process -Id $PID).Path }

$plan = New-Object 'System.Collections.Generic.List[object]'
foreach ($file in @(Get-TestFiles 'tests/saver' '*.Tests.ps1')) {
    if (Test-Selected $file.Name) { $plan.Add(@{ Name = $file.Name; Kind = 'powershell'; Path = $file.FullName }) }
}
foreach ($file in @(Get-TestFiles 'tests/saver' 'test_*.py')) {
    if (Test-Selected $file.Name) { $plan.Add(@{ Name = $file.Name; Kind = 'python'; Path = $file.FullName }) }
}
if (-not $SkipLauncher) {
    foreach ($project in @(Get-ChildItem -LiteralPath (Join-Path $root 'tests/launcher') -Filter '*.csproj' -File)) {
        if (Test-Selected $project.Name) { $plan.Add(@{ Name = $project.Name; Kind = 'launcher'; Path = $project.FullName }) }
    }
}
# The overload check is fast and guards a mistake that silently rounds numbers (see build/lint-math.ps1).
if (Test-Selected 'lint-math.ps1') { $plan.Add(@{ Name = 'lint-math.ps1'; Kind = 'powershell'; Path = (Join-Path $PSScriptRoot 'lint-math.ps1') }) }

if ($List) { $plan | ForEach-Object { '{0,-11} {1}' -f $_.Kind, $_.Name }; return }
if ($plan.Count -eq 0) { throw ('No test file matches: ' + ($Filter -join ', ')) }
if ($Filter.Count -eq 0) {
    if (@($plan | Where-Object { $_.Kind -eq 'python' }).Count -eq 0) { throw 'Python test files are missing.' }
    if (-not $SkipLauncher -and @($plan | Where-Object { $_.Kind -eq 'launcher' }).Count -eq 0) { throw 'Launcher test harness is missing.' }
}

$results = New-Object 'System.Collections.Generic.List[object]'
$total = [Diagnostics.Stopwatch]::StartNew()
foreach ($item in $plan) {
    Write-Host ('TEST ' + $item.Name)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $code = 1; $note = ''
    try {
        switch ($item.Kind) {
            'powershell' {
                & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $item.Path | Out-Host
                $code = $LASTEXITCODE
            }
            'python' {
                if ($null -eq $python) { $note = 'Python 3 not found'; break }
                & $python.Source -B -m unittest discover -s (Split-Path -Parent $item.Path) -p $item.Name -v | Out-Host
                $code = $LASTEXITCODE
            }
            'launcher' {
                & dotnet run --project $item.Path -c Release | Out-Host
                $code = $LASTEXITCODE
            }
        }
    } catch { $code = 1; $note = $_.Exception.Message }
    $watch.Stop()
    if ($null -eq $code) { $code = 1 }
    $results.Add([pscustomobject]@{ Name = $item.Name; Passed = ($code -eq 0); ExitCode = $code; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1); Note = $note })
    if ($code -ne 0) { Write-Host ('FAILED ' + $item.Name + ' (exit ' + $code + ')' + $(if ($note) { ': ' + $note } else { '' })) -ForegroundColor Red }
}
$total.Stop()

if ($Lint) {
    Write-Host 'LINT (report only)'
    try { & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'lint.ps1') | Out-Host }
    catch { Write-Host ('Lint could not run: ' + $_.Exception.Message) -ForegroundColor Yellow }
}

$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ''
Write-Host '---- Summary ----'
foreach ($r in $results) {
    Write-Host ('{0}  {1,-44} {2,7:N1}s' -f $(if ($r.Passed) { 'PASS' } else { 'FAIL' }), $r.Name, $r.Seconds) -ForegroundColor $(if ($r.Passed) { 'Gray' } else { 'Red' })
}
Write-Host ('{0} passed, {1} failed, {2} files, {3:N0}s' -f ($results.Count - $failed.Count), $failed.Count, $results.Count, $total.Elapsed.TotalSeconds)
if ($failed.Count -gt 0) {
    Write-Host ('Failed: ' + (($failed | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host 'All release regression tests passed.'
exit 0
