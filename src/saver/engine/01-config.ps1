# 1. Load or prompt config.json
# === EMBEDDED Arkuzo-Config.ps1 ===
<#
Arkuzo Config Management
Provides preset profiles (normal, agressive, extreme), JSON persistence,
interactive first-run preset selection, and free-form setting editing.
#>

function Get-ArkuzoPresets {
    return [ordered]@{
        'normal' = [ordered]@{
            target_ram_mb        = 850
            trim_enabled         = $true
            trim_every_sec       = 120
            priority             = 'BelowNormal'
            cores_per_instance   = 4
            hard_limit           = $false
            poll_ms              = 500
            minimize_on_launch   = $false
            apply_graphics_flags = $false
            memory_priority      = 'BelowNormal'
            adaptive_trim        = $true
            pressure_trim_available_percent = 15
            description          = 'Higher advisory target (850 MB soft), trim every 120s, 4 cores. Lag and disconnects remain possible.'
        }
        'agressive' = [ordered]@{
            target_ram_mb        = 600
            trim_enabled         = $true
            trim_every_sec       = 60
            priority             = 'BelowNormal'
            cores_per_instance   = 2
            hard_limit           = $false
            poll_ms              = 350
            minimize_on_launch   = $false
            apply_graphics_flags = $false
            memory_priority      = 'Low'
            adaptive_trim        = $true
            pressure_trim_available_percent = 20
            description          = 'Multi-account profile: 600 MB working-set target, trim every 60s, 2 cores. Trimming does not repair private-memory leaks.'
        }
        'extreme' = [ordered]@{
            target_ram_mb        = 450
            trim_enabled         = $true
            trim_every_sec       = 30
            priority             = 'BelowNormal'
            cores_per_instance   = 1
            hard_limit           = $false
            poll_ms              = 250
            minimize_on_launch   = $false
            apply_graphics_flags = $false
            memory_priority      = 'VeryLow'
            adaptive_trim        = $true
            pressure_trim_available_percent = 25
            description          = 'Maximum instances:Tight advisory target (450 MB soft), trim every 30s, 1 core. Maximum density on 16 GB RAM.'
        }
    }
}

function Save-ArkuzoConfigFile([string]$Path, [string]$Preset = 'normal', $CustomSettings = $null) {
    $presets = Get-ArkuzoPresets
    $cleanPreset = $Preset.ToLowerInvariant().Trim()
    if ($cleanPreset -eq 'aggressive') { $cleanPreset = 'agressive' }
    if (-not $presets.Contains($cleanPreset)) {
        $cleanPreset = 'normal'
    }

    $base = $presets[$cleanPreset]
    $settingsObj = [ordered]@{}
    foreach ($k in $base.Keys) {
        if ($k -eq 'description') { continue }
        $settingsObj[$k] = $base[$k]
    }

    if ($null -ne $CustomSettings) {
        if ($CustomSettings -is [System.Collections.IDictionary]) {
            foreach ($key in $CustomSettings.Keys) { $settingsObj[$key] = $CustomSettings[$key] }
        } elseif ($CustomSettings -is [pscustomobject]) {
            foreach ($prop in $CustomSettings.PSObject.Properties) { $settingsObj[$prop.Name] = $prop.Value }
        }
    }

    $configObj = [ordered]@{
        selected_preset = $cleanPreset
        settings        = $settingsObj
        notes           = 'Freely editable. Deleting this file will reopen the preset selection menu on next launch.'
    }

    $json = $configObj | ConvertTo-Json -Depth 10
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Save-ArkuzoAtomicText $Path $json # Flushed to the disk, then renamed into place.
    return $configObj
}

function Load-ArkuzoConfigFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) {
            return $null
        }
        return $parsed
    } catch {
        return $null
    }
}

function Select-ArkuzoPresetInteractive([string]$Path) {
    # Check if console is interactive
    $isInteractive = $false
    try {
        if (-not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) {
            $isInteractive = $true
        }
    } catch { }

    if (-not $isInteractive) {
        Write-Host "Non-interactive console detected. Creating default configuration ('normal')..." -ForegroundColor Yellow
        return Save-ArkuzoConfigFile -Path $Path -Preset 'normal'
    }

    $oldColor = [Console]::ForegroundColor
    try {
        [Console]::Clear()
        [Console]::ForegroundColor = [ConsoleColor]::Cyan
        Write-Host "    ___     ____    __ __   __  __   _____    ____"
        Write-Host "   /   |   / __ \  / //_/  / / / /  /__  /   / __ \"
        Write-Host "  / /| |  / /_/ / / ,<    / / / /     / /   / / / /"
        Write-Host " / ___ | / _, _/ / /| |  / /_/ /     / /__ / /_/ /"
        Write-Host "/_/  |_|/_/ |_| /_/ |_|  \____/     /____/ \____/"
        [Console]::ForegroundColor = [ConsoleColor]::White
        Write-Host "  ARKUZO // FIRST TIME SETUP - PRESET SELECTION`n"

        [Console]::ForegroundColor = [ConsoleColor]::Gray
        Write-Host "  No config.json found. Please select your startup profile:"
        Write-Host "  (All values can be freely edited later in config.json)`n"

        [Console]::ForegroundColor = [ConsoleColor]::Green
        Write-Host "  [1] NORMAL  (Recommended for maximum stability)"
        [Console]::ForegroundColor = [ConsoleColor]::DarkCyan
        Write-Host "      - Target RAM: 850 MB soft limit | Trim every 120s | 4 cores | BelowNormal"
        Write-Host "      - Ideal for smooth gameplay & long AFK sessions without disconnects.`n"

        [Console]::ForegroundColor = [ConsoleColor]::Yellow
        Write-Host "  [2] AGRESSIVE  (For multi-account farming)"
        [Console]::ForegroundColor = [ConsoleColor]::DarkCyan
        Write-Host "      - Target RAM: 600 MB soft limit | Trim every 60s | 2 cores | BelowNormal"
        Write-Host "      - High account density. Private commit requires the separate health guard.`n"

        [Console]::ForegroundColor = [ConsoleColor]::Magenta
        Write-Host "  [3] EXTREME  (Maximum instances on 16 GB)"
        [Console]::ForegroundColor = [ConsoleColor]::DarkCyan
        Write-Host "      - Target RAM: 450 MB soft limit | Trim every 30s | 1 core | BelowNormal"
        Write-Host "      - Maximum account count. Aggressive background page trimming.`n"

        [Console]::ForegroundColor = [ConsoleColor]::White
        Write-Host "  Select [1], [2], or [3] (Enter = 1 Normal): " -NoNewline

        $chosen = 'normal'
        while ($true) {
            $keyInfo = [Console]::ReadKey($true)
            if ($keyInfo.Key -eq [ConsoleKey]::D1 -or $keyInfo.Key -eq [ConsoleKey]::NumPad1 -or $keyInfo.Key -eq [ConsoleKey]::Enter) {
                $chosen = 'normal'; Write-Host "1 (Normal)`n"; break
            }
            if ($keyInfo.Key -eq [ConsoleKey]::D2 -or $keyInfo.Key -eq [ConsoleKey]::NumPad2) {
                $chosen = 'agressive'; Write-Host "2 (Agressive)`n"; break
            }
            if ($keyInfo.Key -eq [ConsoleKey]::D3 -or $keyInfo.Key -eq [ConsoleKey]::NumPad3) {
                $chosen = 'extreme'; Write-Host "3 (Extreme)`n"; break
            }
        }

        $saved = Save-ArkuzoConfigFile -Path $Path -Preset $chosen
        [Console]::ForegroundColor = [ConsoleColor]::Green
        Write-Host "  [+] Config saved: $Path"
        Write-Host "  [+] Selected profile: $chosen"
        [Console]::ForegroundColor = [ConsoleColor]::Gray
        Write-Host "  Tip: Delete config.json at any time to reopen the preset selector.`n"
        Start-Sleep -Milliseconds 900
        return $saved
    } finally {
        [Console]::ForegroundColor = $oldColor
    }
}

# === END Arkuzo-Config.ps1 ===
