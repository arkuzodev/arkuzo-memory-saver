#requires -Version 5.1
<#
Builds the shipped single-file sources from their modules:

  src/saver/engine/*.ps1  ->  src/saver/Arkuzo-Memory-Saver.ps1
  src/saver/control-center/*  ->  src/saver/Arkuzo-Control-Center.html (markup, styles.css, app.js)
  contracts/config-schema.json  ->  the GENERATED blocks in src/saver/Arkuzo-Control-Center.py

The outputs are checked in as generated files, so tests, Arkuzo-Control-Center.cmd,
packaging and the launcher keep using the same paths and file names. Edit the
modules, never the generated file, then run this script.

  build/bundle.ps1                     rebuild the generated files in place
  build/bundle.ps1 -Check              exit 1 when a generated file is out of date (nothing is written)
  build/bundle.ps1 -OutDirectory <dir> write the bundles to <dir> instead (same file names)

Bundling is plain concatenation in the order listed below: no line is rewritten,
reordered or re-encoded. Each module's own UTF-8 byte order mark is dropped and the
output gets one (Windows PowerShell 5.1 needs it for the non-ASCII characters). A
one-line "generated" notice goes after the output's first line, and the version
from the VERSION file replaces the __ARKUZO_VERSION__ token (which must occur once). Line endings are
copied as they are; the up-to-date check ignores CRLF vs LF, because a checkout's
line endings depend on git settings (.gitattributes).
#>
[CmdletBinding()]
param([switch]$Check, [string]$OutDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
# The release version lives in one place: the VERSION file at the repository root.
$version = ([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw ('VERSION must hold a version like 2.3.0, not: ' + $version) }

# Order matters: the engine is one script whose top-level code runs top to bottom.
$targets = @(
    [pscustomobject]@{
        Output = 'src/saver/Arkuzo-Memory-Saver.ps1'
        Folder = 'src/saver/engine'
        Parts = @(
            '00-header.ps1', '01-config.ps1', '02-health-native.ps1', '03-process.ps1', '04-roblox-logs.ps1',
            '05-executor-signal.ps1', '06-health-observation.ps1', '07-policy-journal.ps1', '08-native-accounts.ps1',
            '09-windows.ps1', '10-volt-control.ps1', '11-farm-freeze.ps1', '12-remote-session.ps1',
            '13-recovery-outcomes.ps1', '14-status.ps1', '15-recovery-closure.ps1', '16-pagefile.ps1',
            '17-version-check.ps1', '18-startup-config.ps1', '19-native-types.ps1', '20-console-graphics.ps1',
            '21-state.ps1', '22-logging.ps1', '23-privileges.ps1', '24-ui.ps1', '25-dashboard.ps1', '26-main-loop.ps1'
        )
        Notice = '# GENERATED FILE: built by build/bundle.ps1 from src/saver/engine/*.ps1. Edit the modules, then run build/bundle.ps1.'
        Bom = $true
        Stamps = @{ '__ARKUZO_VERSION__' = $version }
    },
    # The page stays one file: its CSP only allows inline styles and script from itself, and the
    # Control Center ZIP must keep exactly two files. app.js keeps the line const TOKEN = '__ARKUZO_TOKEN__';
    # the Control Center substitutes it when it serves the page.
    [pscustomobject]@{
        Output = 'src/saver/Arkuzo-Control-Center.html'
        Folder = 'src/saver/control-center'
        Parts = @('00-head.html', '01-styles.css', '02-body.html', '03-app.js', '04-end.html')
        Notice = '<!-- GENERATED FILE: built by build/bundle.ps1 from src/saver/control-center/. Edit those files, then run build/bundle.ps1. -->'
        Bom = $false
        Stamps = @{}
    }
)

$utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)

function Remove-Bom([byte[]]$Bytes) {
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $copy = New-Object byte[] ($Bytes.Length - 3)
        [Array]::Copy($Bytes, 3, $copy, 0, $copy.Length)
        return ,$copy
    }
    return ,$Bytes
}

function Get-BundleBytes($Target) {
    # Every module in the folder must be listed exactly once: a forgotten module would silently vanish.
    $folder = Join-Path $root $Target.Folder
    $present = @(Get-ChildItem -LiteralPath $folder -File | ForEach-Object { $_.Name } | Sort-Object)
    $listed = @($Target.Parts | Sort-Object)
    if (@($Target.Parts | Select-Object -Unique).Count -ne $Target.Parts.Count) { throw ($Target.Output + ': a module is listed twice.') }
    $difference = @(Compare-Object -ReferenceObject $listed -DifferenceObject $present)
    if ($difference.Count -gt 0) {
        throw ($Target.Output + ': modules and list differ: ' + (($difference | ForEach-Object { $_.SideIndicator + ' ' + $_.InputObject }) -join ', '))
    }
    $stream = New-Object IO.MemoryStream
    try {
        if ($Target.Bom) { $stream.Write($utf8Bom, 0, 3) }
        $first = $true
        foreach ($part in $Target.Parts) {
            $bytes = Remove-Bom ([IO.File]::ReadAllBytes((Join-Path $folder $part)))
            if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 0x0A -and $part -ne $Target.Parts[-1]) {
                throw ($Target.Folder + '/' + $part + ' must end with a line break.')
            }
            if ($first) {
                # The notice goes after the first line, using that line's own line ending.
                $lineEnd = [Array]::IndexOf($bytes, [byte]0x0A)
                if ($lineEnd -lt 0) { throw ($Target.Folder + '/' + $part + ' has no line break.') }
                $eol = if ($lineEnd -gt 0 -and $bytes[$lineEnd - 1] -eq 0x0D) { "`r`n" } else { "`n" }
                $stream.Write($bytes, 0, $lineEnd + 1)
                $notice = [Text.Encoding]::UTF8.GetBytes($Target.Notice + $eol)
                $stream.Write($notice, 0, $notice.Length)
                $stream.Write($bytes, $lineEnd + 1, $bytes.Length - $lineEnd - 1)
                $first = $false
            } else {
                $stream.Write($bytes, 0, $bytes.Length)
            }
        }
        $body = $stream.ToArray()
    } finally { $stream.Dispose() }
    if ($Target.Stamps.Count -gt 0) {
        $text = [Text.Encoding]::UTF8.GetString($body)
        foreach ($token in $Target.Stamps.Keys) {
            $count = ([regex]::Matches($text, [regex]::Escape($token))).Count
            if ($count -ne 1) { throw ($Target.Output + ': ' + $token + ' must occur exactly once in the modules, found ' + $count + '.') }
            $text = $text.Replace($token, [string]$Target.Stamps[$token])
        }
        $body = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
    }
    return ,$body
}

function ConvertTo-ComparableText([byte[]]$Bytes) {
    # Line endings depend on the checkout, everything else must match exactly.
    return [Text.Encoding]::UTF8.GetString($Bytes).Replace("`r`n", "`n")
}

# ---- Generated blocks: a region between "# BEGIN GENERATED <name>" and "# END GENERATED <name>"
# lines in a hand-written file, rewritten from a contract. Everything outside the markers is left alone.
function ConvertTo-PyLiteral($Value) {
    if ($null -eq $Value) { return 'None' }
    if ($Value -is [bool]) { if ($Value) { return 'True' } else { return 'False' } }
    if ($Value -is [string]) { return "'" + $Value.Replace('\', '\\').Replace("'", "\'") + "'" }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal]) { return ([decimal]$Value).ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [Array]) {
        $items = @($Value | ForEach-Object { ConvertTo-PyLiteral $_ })
        if ($items.Count -eq 1) { return '(' + $items[0] + ',)' }
        return '(' + ($items -join ', ') + ')'
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        return '{' + ((@($Value.PSObject.Properties) | ForEach-Object { (ConvertTo-PyLiteral $_.Name) + ': ' + (ConvertTo-PyLiteral $_.Value) }) -join ', ') + '}'
    }
    throw ('No Python literal for ' + $Value.GetType().FullName)
}
function Format-PyItems([string[]]$Items, [string]$Indent) {
    # key: value pairs, wrapped below 140 characters.
    $lines = @(); $line = ''
    foreach ($item in $Items) {
        if ($line -and ($Indent.Length + $line.Length + $item.Length + 2) -gt 140) { $lines += ($Indent + $line + ','); $line = '' }
        $line = if ($line) { $line + ', ' + $item } else { $item }
    }
    if ($line) { $lines += ($Indent + $line + ',') }
    return $lines
}
function Get-ConfigSchemaBlocks {
    $schema = [IO.File]::ReadAllText((Join-Path $root 'contracts/config-schema.json')) | ConvertFrom-Json
    $config = @('PRESETS = {')
    foreach ($preset in $schema.presets.PSObject.Properties) {
        $config += ('    ' + (ConvertTo-PyLiteral $preset.Name) + ': {')
        $config += Format-PyItems @($preset.Value.PSObject.Properties | ForEach-Object { (ConvertTo-PyLiteral $_.Name) + ': ' + (ConvertTo-PyLiteral $_.Value) }) '        '
        $config += '    },'
    }
    $config += '}'
    $config += 'SCHEMA = {'
    foreach ($section in $schema.config.PSObject.Properties) {
        $config += ('    ' + (ConvertTo-PyLiteral $section.Name) + ': {')
        foreach ($rule in $section.Value.PSObject.Properties) { $config += ('        ' + (ConvertTo-PyLiteral $rule.Name) + ': ' + (ConvertTo-PyLiteral $rule.Value) + ',') }
        $config += '    },'
    }
    $config += '}'
    $config += ('TOP_LEVEL = {' + ((@($schema.topLevel.PSObject.Properties) | ForEach-Object { (ConvertTo-PyLiteral $_.Name) + ': ' + (ConvertTo-PyLiteral $_.Value) }) -join ', ') + '}')
    $config += ('RESTART_KEYS = {' + ((@($schema.restartKeys) | ForEach-Object { ConvertTo-PyLiteral $_ }) -join ', ') + '}')
    $vault = @('VAULT_SETTINGS = {', '    # name: (rule, default). Rules use the same validate_value as config edits.')
    foreach ($setting in $schema.vault.PSObject.Properties) {
        $vault += ('    ' + (ConvertTo-PyLiteral $setting.Name) + ': (' + (ConvertTo-PyLiteral $setting.Value.rule) + ', ' + (ConvertTo-PyLiteral $setting.Value.default) + '),')
    }
    $vault += '}'
    return @{ 'config-schema' = $config; 'vault-settings' = $vault }
}
$blockFiles = @(
    [pscustomobject]@{ File = 'src/saver/Arkuzo-Control-Center.py'; Blocks = (Get-ConfigSchemaBlocks) }
)
function Get-FileWithBlocks([string]$Text, [hashtable]$Blocks, [string]$File) {
    $eol = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $Text.Replace("`r`n", "`n").Split("`n")
    foreach ($name in $Blocks.Keys) {
        $begin = @(0..($lines.Count - 1) | Where-Object { $lines[$_].StartsWith('# BEGIN GENERATED ' + $name + ':') -or $lines[$_] -ceq ('# BEGIN GENERATED ' + $name) })
        $end = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -ceq ('# END GENERATED ' + $name) })
        if ($begin.Count -ne 1 -or $end.Count -ne 1 -or $end[0] -le $begin[0]) { throw ($File + ': needs exactly one "# BEGIN GENERATED ' + $name + '" and one "# END GENERATED ' + $name + '" line.') }
        $lines = @($lines[0..$begin[0]]) + @($Blocks[$name]) + @($lines[$end[0]..($lines.Count - 1)])
    }
    return ($lines -join "`n").Replace("`n", $eol)
}

$stale = New-Object 'System.Collections.Generic.List[string]'
foreach ($item in $blockFiles) {
    $path = Join-Path $root $item.File
    $text = [IO.File]::ReadAllText($path)
    $next = Get-FileWithBlocks $text $item.Blocks $item.File
    $upToDate = ($text.Replace("`r`n", "`n") -ceq $next.Replace("`r`n", "`n"))
    if ($Check) { if (-not $upToDate) { $stale.Add($item.File) }; continue }
    if ($OutDirectory) {
        [IO.Directory]::CreateDirectory($OutDirectory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $OutDirectory (Split-Path -Leaf $item.File)), $next, (New-Object Text.UTF8Encoding($false)))
    } elseif (-not $upToDate) {
        [IO.File]::WriteAllText($path, $next, (New-Object Text.UTF8Encoding($false)))
        Write-Host ('Rebuilt the generated blocks in ' + $item.File)
    } else {
        Write-Host ('Up to date: ' + $item.File)
    }
}
foreach ($target in $targets) {
    $bundle = Get-BundleBytes $target
    $current = Join-Path $root $target.Output
    $upToDate = (Test-Path -LiteralPath $current -PathType Leaf) -and
        ((ConvertTo-ComparableText ([IO.File]::ReadAllBytes($current))) -ceq (ConvertTo-ComparableText $bundle))
    if ($Check) {
        if (-not $upToDate) { $stale.Add($target.Output) }
        continue
    }
    if ($OutDirectory) {
        [IO.Directory]::CreateDirectory($OutDirectory) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $OutDirectory (Split-Path -Leaf $target.Output)), $bundle)
    } elseif (-not $upToDate) {
        [IO.File]::WriteAllBytes($current, $bundle)
        Write-Host ('Rebuilt ' + $target.Output)
    } else {
        Write-Host ('Up to date: ' + $target.Output)
    }
}
if ($Check) {
    if ($stale.Count -gt 0) {
        Write-Host ('Out of date (run build/bundle.ps1): ' + ($stale -join ', ')) -ForegroundColor Red
        exit 1
    }
    Write-Host 'Generated files are up to date.'
}
exit 0
