# Removes the executor kick-signal script that saver versions up to 2.4.1 installed into
# executor autoexec folders (00-arkuzo-signal.luau), and the signal files it wrote into the
# executor workspace. Kicks and disconnects are detected from the Roblox client logs; the
# saver no longer puts any script into an executor. Only files the saver itself wrote are
# touched, and no folder is ever created.

$script:ArkuzoLegacySignalScriptName = '00-arkuzo-signal.luau'

function Get-ArkuzoExecutorRoots {
    $roots = New-Object System.Collections.Generic.HashSet[string]
    foreach ($base in @($env:LOCALAPPDATA, $env:APPDATA)) {
        if (-not $base) { continue }
        foreach ($sub in @('Volt', 'Potassium', 'com.volt.editor', 'com.pot.potassium-tauri')) {
            $roots.Add((Join-Path $base $sub)) | Out-Null
        }
    }
    foreach ($base in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('UserProfile'),
                        [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'))) {
        if (-not $base) { continue }
        foreach ($sub in @('Volt', 'VoltX', 'Potassium', 'Tools & Mods\Volt', 'Tools & Mods\VoltX', 'Tools & Mods\potass', 'Tools & Mods\potae')) {
            $roots.Add((Join-Path $base $sub)) | Out-Null
        }
    }
    $baseDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $null }
    if ($baseDir) {
        foreach ($dir in @($baseDir, (Split-Path -Parent $baseDir))) {
            if (-not $dir) { continue }
            foreach ($sub in @('Volt', 'VoltX', 'Potassium')) { $roots.Add((Join-Path $dir $sub)) | Out-Null }
        }
    }
    try {
        Get-Process | Where-Object { $_.ProcessName -match '(?i)\A(volt|potassium|tauri-app)' } | ForEach-Object {
            try {
                $exe = $_.Path
                if ($exe) {
                    $dir = Split-Path -Parent $exe
                    $roots.Add($dir) | Out-Null
                    $parent = Split-Path -Parent $dir
                    if ($parent) { $roots.Add($parent) | Out-Null }
                }
            } catch { }
        }
    } catch { }
    return @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })
}

function Remove-ArkuzoLegacyAutoexecSignal {
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($root in @(Get-ArkuzoExecutorRoots)) {
        $leaf = Split-Path -Leaf $root
        $autoexec = if ($leaf -ieq 'autoexec') { $root } else { Join-Path $root 'autoexec' }
        if (Test-Path -LiteralPath $autoexec -PathType Container) {
            Get-ChildItem -LiteralPath $autoexec -Recurse -Depth 3 -File -Filter $script:ArkuzoLegacySignalScriptName -ErrorAction SilentlyContinue | ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $removed.Add($_.FullName) } catch { }
            }
        }
        $workspace = if ($leaf -ieq 'workspace') { $root } else { Join-Path $root 'workspace' }
        if (Test-Path -LiteralPath $workspace -PathType Container) {
            $signalDir = Join-Path $workspace 'arkuzo_signals'
            if (Test-Path -LiteralPath $signalDir -PathType Container) {
                try { Remove-Item -LiteralPath $signalDir -Recurse -Force -ErrorAction Stop; $removed.Add($signalDir) } catch { }
            }
            Get-ChildItem -LiteralPath $workspace -File -Filter 'arkuzo_signals_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $removed.Add($_.FullName) } catch { }
            }
        }
    }
    if ($removed.Count -gt 0) { Write-Diagnostic 'AUTOEXEC_SIGNAL_SCRIPT_REMOVED' @{ paths = @($removed) } }
    return $removed.Count
}
