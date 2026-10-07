#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($test in Get-ChildItem -LiteralPath (Join-Path $root 'tests/saver') -Filter '*.Tests.ps1') {
    Write-Host ('TEST ' + $test.Name)
    & $test.FullName
}
$python = @('python3.exe', 'python.exe') | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if ($null -eq $python) { throw 'Python 3 is needed for the probe test suite.' }
& $python.Source -B -m unittest discover -s (Join-Path $root 'tests/saver') -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Python regression tests failed.' }
$projects = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests/launcher') -Filter '*.csproj' -Recurse)
if ($projects.Count -eq 0) { throw 'Launcher test harness is missing.' }
foreach ($project in $projects) {
    & dotnet run --project $project.FullName -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Launcher regression tests failed.' }
}
Write-Host 'All release regression tests passed.'
