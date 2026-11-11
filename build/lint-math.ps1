#requires -Version 5.1
<#
Flags [Math]::Min / [Math]::Max calls that PowerShell may bind to the wrong overload.

  [Math]::Max(0, 7.4)  ->  7     the Int32 overload wins when the first argument is an
  [Math]::Min(1, 0.4)  ->  0     integer and nothing is cast, and the fraction is rounded away

A call passes when one of these holds:
  - an argument is cast to [double] (PowerShell then picks the Double overload),
  - the first argument is known to be a double,
  - every argument is known to be an integer (literal, [int]/[long] cast, or +, -, * of those).
Anything else is reported: cast the arguments to [double], or to [int] when whole numbers are meant.

  build/lint-math.ps1                 checks src/saver/*.ps1 and build/*.ps1; exit 1 on a finding
  build/lint-math.ps1 -Path a.ps1     checks the given files
#>
[CmdletBinding()]
param([string[]]$Path = @())
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Path.Count -eq 0) {
    $Path = @(Get-ChildItem -LiteralPath (Join-Path $root 'src/saver') -Filter '*.ps1' -File | ForEach-Object { $_.FullName }) +
            @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
}

$doubleTypes = @('double', 'single', 'float', 'decimal', 'system.double', 'system.single', 'system.decimal')
$intTypes = @('int', 'int32', 'int64', 'long', 'uint32', 'uint64', 'int16', 'uint16', 'byte', 'system.int32', 'system.int64')
$doubleMath = @('round', 'ceiling', 'floor', 'pow', 'sqrt', 'abs', 'truncate', 'log', 'log10', 'exp')

function Test-MathCall($Ast, [string[]]$Names) {
    return ($Ast -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $Ast.Static -and
        $Ast.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
        $Ast.Expression.TypeName.FullName -in @('math', 'system.math') -and
        $Ast.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $Names -contains $Ast.Member.Value.ToLowerInvariant())
}
function Test-ExplicitDouble($Ast) {
    while ($Ast -is [Management.Automation.Language.ParenExpressionAst] -and $Ast.Pipeline.PipelineElements.Count -eq 1 -and
        $Ast.Pipeline.PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst]) { $Ast = $Ast.Pipeline.PipelineElements[0].Expression }
    return ($Ast -is [Management.Automation.Language.ConvertExpressionAst] -and $doubleTypes -contains $Ast.Type.TypeName.FullName.ToLowerInvariant())
}
function Get-NumberKind($Ast) {
    # 'double', 'int' or 'unknown': what the argument is known to be when the call runs.
    if ($null -eq $Ast) { return 'unknown' }
    if ($Ast -is [Management.Automation.Language.ParenExpressionAst]) {
        $elements = $Ast.Pipeline.PipelineElements
        if ($elements.Count -eq 1 -and $elements[0] -is [Management.Automation.Language.CommandExpressionAst]) { return (Get-NumberKind $elements[0].Expression) }
        return 'unknown'
    }
    if ($Ast -is [Management.Automation.Language.ConvertExpressionAst]) {
        $name = $Ast.Type.TypeName.FullName.ToLowerInvariant()
        if ($doubleTypes -contains $name) { return 'double' }
        if ($intTypes -contains $name) { return 'int' }
        return 'unknown'
    }
    if ($Ast -is [Management.Automation.Language.StringConstantExpressionAst]) { return 'unknown' }
    if ($Ast -is [Management.Automation.Language.ConstantExpressionAst]) {
        if ($Ast.Value -is [double] -or $Ast.Value -is [single] -or $Ast.Value -is [decimal]) { return 'double' }
        if ($Ast.Value -is [int] -or $Ast.Value -is [long]) { return 'int' }
        return 'unknown'
    }
    if ($Ast -is [Management.Automation.Language.BinaryExpressionAst]) {
        $left = Get-NumberKind $Ast.Left; $right = Get-NumberKind $Ast.Right
        $operator = [string]$Ast.Operator
        if ($operator -in @('Plus', 'Minus', 'Multiply', 'Divide')) {
            if ($left -eq 'double' -or $right -eq 'double') { return 'double' }
            if ($operator -ne 'Divide' -and $left -eq 'int' -and $right -eq 'int') { return 'int' }
        }
        return 'unknown'
    }
    if (Test-MathCall $Ast $doubleMath) { return 'double' }
    if (Test-MathCall $Ast @('min', 'max')) {
        $kinds = @($Ast.Arguments | ForEach-Object { Get-NumberKind $_ })
        if (@($Ast.Arguments | Where-Object { Test-ExplicitDouble $_ }).Count -gt 0 -or $kinds[0] -eq 'double') { return 'double' }
        if (@($kinds | Where-Object { $_ -ne 'int' }).Count -eq 0) { return 'int' }
    }
    return 'unknown'
}

$findings = @()
$calls = 0
foreach ($file in $Path) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ('Parse failed: ' + $file + ': ' + $errors[0].Message) }
    foreach ($call in $ast.FindAll({ param($n) Test-MathCall $n @('min', 'max') }, $true)) {
        $calls++
        if ($call.Arguments.Count -ne 2) { continue }
        $kinds = @($call.Arguments | ForEach-Object { Get-NumberKind $_ })
        $explicit = @($call.Arguments | Where-Object { Test-ExplicitDouble $_ }).Count -gt 0
        $allInt = @($kinds | Where-Object { $_ -ne 'int' }).Count -eq 0
        if ($explicit -or $kinds[0] -eq 'double' -or $allInt) { continue }
        $findings += [pscustomobject]@{ File = $file; Line = $call.Extent.StartLineNumber; Text = $call.Extent.Text; Kinds = ($kinds -join ', ') }
    }
}
foreach ($f in $findings) {
    $relative = $f.File
    if ($relative.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $relative = $relative.Substring($root.Length).TrimStart('\', '/') }
    $text = ($f.Text -replace '\s+', ' ')
    if ($text.Length -gt 110) { $text = $text.Substring(0, 107) + '...' }
    Write-Host ('{0}:{1}: {2}  [{3}]' -f $relative, $f.Line, $text, $f.Kinds)
}
if ($findings.Count -gt 0) {
    Write-Host ('FAIL: ' + $findings.Count + ' of ' + $calls + ' [Math]::Min/Max calls can bind the wrong overload. Cast the arguments to [double] (or to [int] for whole numbers).')
    exit 1
}
Write-Host ('PASS: ' + $calls + ' [Math]::Min/Max calls have unambiguous argument types')
exit 0
