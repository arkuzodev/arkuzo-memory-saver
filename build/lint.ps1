#requires -Version 5.1
<#
Linters for the saver sources.

  math   build/lint-math.ps1: ambiguous [Math]::Min/Max calls.            Blocking.
  ruff   Python (ruff.toml): syntax errors, undefined names and the like.  Blocking.
         A wider rule set is printed as a report and never fails.
  pssa   PSScriptAnalyzer (build/PSScriptAnalyzerSettings.psd1).           Report only.

  build/lint.ps1               all three
  build/lint.ps1 -Only pssa    one or more of: math, ruff, pssa

A linter that is not installed is skipped with a note (pip install ruff;
Install-Module PSScriptAnalyzer -Scope CurrentUser). Exit code 1 only when a
blocking check fails.
#>
[CmdletBinding()]
param([string[]]$Only = @())
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
foreach ($name in $Only) { if ($name -notin @('math', 'ruff', 'pssa')) { throw "Unknown linter: $name (use math, ruff or pssa)" } }
function Test-Wanted([string]$Name) { return ($Only.Count -eq 0 -or $Only -contains $Name) }
$failed = @()
$powershell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) { $powershell = (Get-Process -Id $PID).Path }

if (Test-Wanted 'math') {
    Write-Host '== [Math]::Min/Max overloads (blocking)'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'lint-math.ps1') | Out-Host
    if ($LASTEXITCODE -ne 0) { $failed += 'math' }
}

if (Test-Wanted 'ruff') {
    Write-Host '== ruff (blocking: the rules in ruff.toml)'
    $paths = @('src/saver', 'tests/saver', 'build')
    $ruff = Get-Command ruff.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $python = @('python3.exe', 'python.exe') | ForEach-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } | Select-Object -First 1
    $prefix = $null
    if ($null -ne $ruff) { $prefix = @($ruff.Source) }
    elseif ($null -ne $python) {
        & $python.Source -m ruff --version *> $null
        if ($LASTEXITCODE -eq 0) { $prefix = @($python.Source, '-m', 'ruff') }
    }
    if ($null -eq $prefix) { Write-Host 'ruff is not installed: skipped (pip install ruff).' }
    else {
        Push-Location $root
        try {
            $command = $prefix[0]; $first = @($prefix | Select-Object -Skip 1)
            & $command @first check @paths | Out-Host
            if ($LASTEXITCODE -ne 0) { $failed += 'ruff' }
            Write-Host '-- ruff, wider rule set (report only)'
            & $command @first check @paths --select 'E,F,W,B' --ignore 'E501,E701,E702,E731' --exit-zero --statistics | Out-Host
        } finally { Pop-Location }
    }
}

if (Test-Wanted 'pssa') {
    Write-Host '== PSScriptAnalyzer (report only)'
    if ($null -eq (Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1)) {
        Write-Host 'PSScriptAnalyzer is not installed: skipped (Install-Module PSScriptAnalyzer -Scope CurrentUser).'
    } else {
        try {
            Import-Module PSScriptAnalyzer -ErrorAction Stop
            $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
            $records = @()
            foreach ($folder in @('src/saver', 'build')) {
                $records += @(Invoke-ScriptAnalyzer -Path (Join-Path $root $folder) -Settings $settings -ErrorAction Continue)
            }
            if ($records.Count -eq 0) { Write-Host 'No findings.' }
            else {
                $records | Group-Object RuleName | Sort-Object Count -Descending | ForEach-Object { Write-Host ('{0,5}  {1}' -f $_.Count, $_.Name) }
                Write-Host ''
                foreach ($r in @($records | Where-Object { $_.Severity -eq 'Error' } | Select-Object -First 40)) {
                    Write-Host ('{0}:{1}: {2}: {3}' -f $r.ScriptName, $r.Line, $r.RuleName, $r.Message)
                }
                Write-Host ($records.Count.ToString() + ' findings (report only; they do not fail the run).')
            }
        } catch { Write-Host ('PSScriptAnalyzer could not run: ' + $_.Exception.Message) }
    }
}

if ($failed.Count -gt 0) { Write-Host ('LINT FAILED: ' + ($failed -join ', ')); exit 1 }
Write-Host 'Lint finished: no blocking findings.'
exit 0
