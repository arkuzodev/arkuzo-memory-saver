#requires -Version 5.1
# The shipped single files are generated from modules by build/bundle.ps1 and checked in.
# These checks fail when a generated file is out of date with its modules, when a module
# is missing from the bundle list, and when the bundle is not a plain concatenation.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bundler = Join-Path $root 'build/bundle.ps1'
$powershell = Join-Path $PSHOME 'powershell.exe'
$version = ([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim()
$script:checks = 0
function Assert([bool]$ok, [string]$msg) { $script:checks++; if (-not $ok) { throw "FAIL: $msg" } }
function Get-Comparable([string]$Path) { return [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)).Replace("`r`n", "`n") }
function Test-Bom([string]$Path) { $b = [IO.File]::ReadAllBytes($Path); return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) }

$generated = @(
    @{ Output = 'src/saver/Arkuzo-Memory-Saver.ps1'; Folder = 'src/saver/engine'; Filter = '*.ps1'; Notice = '# GENERATED FILE:' },
    @{ Output = 'src/saver/Arkuzo-Control-Center.html'; Folder = 'src/saver/control-center'; Filter = '*'; Notice = '<!-- GENERATED FILE:' }
)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('arkuzo-bundle-' + [guid]::NewGuid().ToString('N'))
try {
    # 1. The checked-in files equal a fresh bundle of their modules.
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bundler -OutDirectory (Join-Path $temp 'out') | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'the bundler runs'
    foreach ($g in $generated) {
        $name = Split-Path -Leaf $g.Output
        $fresh = Join-Path (Join-Path $temp 'out') $name
        $checkedIn = Join-Path $root $g.Output
        Assert ((Get-Comparable $fresh) -ceq (Get-Comparable $checkedIn)) ($g.Output + ' is up to date with ' + $g.Folder + ' (run build/bundle.ps1)')
        # 2. Plain concatenation: dropping the notice line leaves exactly the modules, in order.
        $text = Get-Comparable $checkedIn
        $lines = $text.Split("`n")
        Assert ($lines[1].StartsWith($g.Notice)) ($g.Output + ' says on its second line that it is generated')
        $withoutNotice = (@($lines[0]) + @($lines | Select-Object -Skip 2)) -join "`n"
        Assert ($withoutNotice.Length -lt $text.Length -and $withoutNotice.IndexOf($g.Notice) -lt 0) 'the notice appears once'
        $modules = @(Get-ChildItem -LiteralPath (Join-Path $root $g.Folder) -Filter $g.Filter -File)
        Assert ($modules.Count -gt 0) ($g.Folder + ' holds the modules')
        foreach ($m in $modules) {
            $body = (Get-Comparable $m.FullName).TrimStart([char]0xFEFF).Replace('__ARKUZO_VERSION__', $version)
            Assert ($withoutNotice.Contains($body)) ($m.Name + ' appears unchanged in ' + $name)
        }
        if ($name -like '*.html') {
            Assert (([regex]::Matches($text, [regex]::Escape("const TOKEN = '__ARKUZO_TOKEN__';"))).Count -eq 1 -and ([regex]::Matches($text, '__ARKUZO_TOKEN__')).Count -eq 1) 'the page keeps exactly one token line for the Control Center to fill in'
            Assert (([regex]::Matches($text, '<script>')).Count -eq 1 -and ([regex]::Matches($text, '<style>')).Count -eq 1) 'styles and script are inlined once (the CSP allows nothing else)'
        }
        if ($name -like '*.ps1') {
            Assert (Test-Bom $checkedIn) ($name + ' starts with a UTF-8 byte order mark (PowerShell 5.1 needs it)')
            foreach ($m in $modules) { Assert (Test-Bom $m.FullName) ($m.Name + ' is saved with a byte order mark') }
            $t = $null; $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($checkedIn, [ref]$t, [ref]$e)
            Assert ($e.Count -eq 0) ($name + ' parses')
        }
    }

    # Generated blocks (contracts/config-schema.json -> the Control Center's tables).
    $py = 'src/saver/Arkuzo-Control-Center.py'
    Assert ((Get-Comparable (Join-Path (Join-Path $temp 'out') (Split-Path -Leaf $py))) -ceq (Get-Comparable (Join-Path $root $py))) ($py + ': generated blocks are up to date with contracts/config-schema.json')

    # 3. A stale or unlisted module is caught, in a scratch copy of the bundler and its inputs.
    $copy = Join-Path $temp 'copy'
    [IO.Directory]::CreateDirectory((Join-Path $copy 'build')) | Out-Null
    Copy-Item -LiteralPath $bundler -Destination (Join-Path $copy 'build/bundle.ps1')
    foreach ($g in $generated) {
        $folder = Join-Path $copy $g.Folder
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        Copy-Item -Path (Join-Path (Join-Path $root $g.Folder) '*') -Destination $folder -Recurse
        Copy-Item -LiteralPath (Join-Path $root $g.Output) -Destination (Join-Path $copy $g.Output)
    }
    Copy-Item -LiteralPath (Join-Path $root $py) -Destination (Join-Path $copy $py)
    Copy-Item -LiteralPath (Join-Path $root 'VERSION') -Destination (Join-Path $copy 'VERSION')
    Copy-Item -LiteralPath (Join-Path $root 'contracts') -Destination (Join-Path $copy 'contracts') -Recurse
    $copyBundler = Join-Path $copy 'build/bundle.ps1'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copyBundler -Check | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'a faithful copy is up to date'
    $module = Get-ChildItem -LiteralPath (Join-Path $copy 'src/saver/engine') -Filter '*.ps1' | Sort-Object Name | Select-Object -Last 1
    [IO.File]::AppendAllText($module.FullName, "# edited`n")
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copyBundler -Check | Out-Null
    Assert ($LASTEXITCODE -eq 1) 'an edited module makes -Check fail'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copyBundler | Out-Null
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copyBundler -Check | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'rebuilding brings it up to date'
    Assert ((Get-Comparable (Join-Path $copy 'src/saver/Arkuzo-Memory-Saver.ps1')).EndsWith("# edited`n")) 'the rebuilt file carries the edit'
    [IO.File]::WriteAllText((Join-Path $copy 'src/saver/engine/99-unlisted.ps1'), "# not in the list`n")
    $failed = $false
    try { & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copyBundler -Check 2>&1 | Out-Null; $failed = ($LASTEXITCODE -ne 0) } catch { $failed = $true }
    Assert $failed 'a module missing from the bundle list is an error, not silently dropped'
    Remove-Item -LiteralPath (Join-Path $copy 'src/saver/engine/99-unlisted.ps1')
    # A schema change makes the generated block stale until the bundler runs.
    $schemaPath = Join-Path $copy 'contracts/config-schema.json'
    [IO.File]::WriteAllText($schemaPath, [IO.File]::ReadAllText($schemaPath).Replace('"launchDelaySec": {', '"launchDelaySec": {"rule": ["int", 5, 99], "default": 7}, "x": {'))
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copyBundler -Check | Out-Null
    Assert ($LASTEXITCODE -eq 1) 'a schema change makes -Check fail'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copyBundler | Out-Null
    Assert ((Get-Comparable (Join-Path $copy $py)).Contains("'launchDelaySec': (('int', 5, 99), 7),")) 'the bundler writes the schema into the Control Center'
    # The version comes from VERSION: a new version is stamped into the bundle.
    [IO.File]::WriteAllText((Join-Path $copy 'VERSION'), "9.8.7`n")
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copyBundler | Out-Null
    $stamped = Get-Comparable (Join-Path $copy 'src/saver/Arkuzo-Memory-Saver.ps1')
    Assert ($stamped -match "(?m)^\`$ArkuzoRuntimeVersion = '9\.8\.7'`$" -and $stamped.IndexOf('__ARKUZO_VERSION__') -lt 0) 'the VERSION file is stamped into the engine'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

Write-Output "PASS: $script:checks bundle checks (generated files up to date with their modules)"
