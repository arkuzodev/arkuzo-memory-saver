#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/saver'
$t = $null; $e = $null; $a = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Arkuzo-Memory-Saver.ps1'), [ref]$t, [ref]$e)
foreach ($f in $a.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }

function Assert([bool]$ok, [string]$msg) { if (-not $ok) { throw "FAIL: $msg" } }

# Test 1: Function exists
Assert ([bool](Get-Command Get-ArkuzoConsoleInputModeMask -ErrorAction SilentlyContinue)) "Get-ArkuzoConsoleInputModeMask must be defined"

# Test 2: QuickEdit and Insert mode are stripped, ExtendedFlags is set
$inputMode = 0x0040 -bor 0x0020 -bor 0x0001 -bor 0x0002 # QuickEdit, Insert, ProcessedInput, LineInput
$masked = Get-ArkuzoConsoleInputModeMask $inputMode

Assert (($masked -band 0x0040) -eq 0) "ENABLE_QUICK_EDIT_MODE (0x0040) must be cleared"
Assert (($masked -band 0x0020) -eq 0) "ENABLE_INSERT_MODE (0x0020) must be cleared"
Assert (($masked -band 0x0080) -eq 0x0080) "ENABLE_EXTENDED_FLAGS (0x0080) must be set"
Assert (($masked -band 0x0001) -eq 0x0001) "Other flags (0x0001) must be preserved"
Assert (($masked -band 0x0002) -eq 0x0002) "Other flags (0x0002) must be preserved"

# Test 3: Mode with no flags still receives ExtendedFlags
$maskedZero = Get-ArkuzoConsoleInputModeMask 0
Assert (($maskedZero -band 0x0080) -eq 0x0080) "ExtendedFlags must be set even when input is 0"
Assert (($maskedZero -band 0x0040) -eq 0) "QuickEdit remains 0"

Write-Output "CONSOLE_MODE_TESTS_PASS"
