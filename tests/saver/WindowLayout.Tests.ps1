#requires -Version 5.1
# The engine's window layout planner against the shared golden vectors in
# contracts/window-layout.json. tests/saver/test_window_layout.py runs the page's
# copy (layoutSlots) against the same file, so the two planners cannot drift apart.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $root 'src/saver/Arkuzo-Memory-Saver.ps1'
$t = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$t, [ref]$e)
if ($e.Count) { throw 'Production parse failed' }
$wanted = @('Get-ArkuzoVaultSetting', 'Get-ArkuzoArrangeSettings', 'Get-ArkuzoRobloxMinWindow', 'Get-ArkuzoWindowSlots', 'Test-ArkuzoSlotsOverlap')
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($wanted -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}
$script:arrangeMinWindow = @{}
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }

$vectors = [IO.File]::ReadAllText((Join-Path $root 'contracts/window-layout.json')) | ConvertFrom-Json
Assert (@($vectors.cases).Count -ge 10) 'the vectors file holds the cases'
foreach ($case in @($vectors.cases)) {
    # The page's inputs are the vault settings; the engine reads them the same way.
    $settings = Get-ArkuzoArrangeSettings ([pscustomobject]@{ settings = $case.settings })
    # The planner returns its list with the unary comma, so it is not unrolled here.
    $slots = Get-ArkuzoWindowSlots ([int]$case.count) @(0, 0, [int]$case.screen[0], [int]$case.screen[1], 96) $settings
    $got = (@(foreach ($slot in $slots) { '[' + ((@($slot) | ForEach-Object { [int]$_ }) -join ',') + ']' }) -join ' ')
    $want = (@($case.expected | ForEach-Object { '[' + ((@($_) | ForEach-Object { [int]$_ }) -join ',') + ']' }) -join ' ')
    Assert ($got -ceq $want) ($case.name + ': engine slots ' + $got + ', expected ' + $want)
    Assert ([bool](Test-ArkuzoSlotsOverlap $slots) -eq [bool]$case.overlap) ($case.name + ': overlap')
}

Write-Output "PASS: $script:checks window layout checks (engine matches contracts/window-layout.json)"
