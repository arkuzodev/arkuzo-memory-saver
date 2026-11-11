$configFilePath = Join-Path $DataDirectory 'config.json'
$loadedConfig = Load-ArkuzoConfigFile -Path $configFilePath
if ($null -eq $loadedConfig) {
    if (Test-Path -LiteralPath $configFilePath) { throw "Existing config.json is invalid. Fix it or restore your backup; it will not be overwritten." }
    $loadedConfig = Select-ArkuzoPresetInteractive -Path $configFilePath
}

if ($null -ne $loadedConfig -and $null -ne $loadedConfig.settings) {
    $cfg = $loadedConfig.settings
    if (-not $PSBoundParameters.ContainsKey('Mode') -and $loadedConfig.selected_preset) {
        $Mode = $loadedConfig.selected_preset
    }
    if (-not $PSBoundParameters.ContainsKey('MaxRamMB') -and $cfg.target_ram_mb) {
        $MaxRamMB = [int]$cfg.target_ram_mb
    }
    if (-not $PSBoundParameters.ContainsKey('TrimEverySec') -and $cfg.trim_every_sec) {
        $TrimEverySec = [int]$cfg.trim_every_sec
    }
    if (-not $PSBoundParameters.ContainsKey('Priority') -and $cfg.priority) {
        $Priority = [string]$cfg.priority
    }
    if (-not $PSBoundParameters.ContainsKey('CoresPerInstance') -and $cfg.cores_per_instance) {
        $CoresPerInstance = [int]$cfg.cores_per_instance
    }
    if (-not $PSBoundParameters.ContainsKey('PollMs') -and $cfg.poll_ms) {
        $PollMs = [int]$cfg.poll_ms
    }
    if (-not $PSBoundParameters.ContainsKey('EnableTrimming') -and $null -ne $cfg.trim_enabled) {
        $EnableTrimming = [bool]$cfg.trim_enabled
    }
    if (-not $PSBoundParameters.ContainsKey('HardLimit') -and -not $PSBoundParameters.ContainsKey('SoftLimit') -and $null -ne $cfg.hard_limit) {
        $HardLimit = [bool]$cfg.hard_limit
        $SoftLimit = -not $HardLimit
    }
    if (-not $PSBoundParameters.ContainsKey('Minimize') -and $null -ne $cfg.minimize_on_launch) {
        $Minimize = [bool]$cfg.minimize_on_launch
    }
    if (-not $PSBoundParameters.ContainsKey('ApplyGraphicsFlags') -and $null -ne $cfg.apply_graphics_flags) {
        $ApplyGraphicsFlags = [bool]$cfg.apply_graphics_flags
    }
}
# Keys added after a configuration was written fall back to its preset, not to
# a no-op, so existing installations gain memory priority and adaptive trimming.
$presetName = ([string]$loadedConfig.selected_preset).ToLowerInvariant()
if ($presetName -eq 'aggressive') { $presetName = 'agressive' }
$presetDefaults = (Get-ArkuzoPresets)[$(if ((Get-ArkuzoPresets).Contains($presetName)) { $presetName } else { 'normal' })]
$AdaptiveTrim = [bool]$presetDefaults.adaptive_trim
$PressureTrimAvailablePercent = [int]$presetDefaults.pressure_trim_available_percent
if (-not $PSBoundParameters.ContainsKey('MemoryPriority')) { $MemoryPriority = [string]$presetDefaults.memory_priority }
$startupSettingsError = $null
try {
    $startupSettings = Get-ArkuzoLiveResourceSettings $loadedConfig.settings @{ MemoryPriority=$MemoryPriority; AdaptiveTrim=$AdaptiveTrim; PressureTrimAvailablePercent=$PressureTrimAvailablePercent }
    if (-not $PSBoundParameters.ContainsKey('MemoryPriority')) { $MemoryPriority = $startupSettings.MemoryPriority }
    $AdaptiveTrim = [bool]$startupSettings.AdaptiveTrim
    $PressureTrimAvailablePercent = [int]$startupSettings.PressureTrimAvailablePercent
} catch { $startupSettingsError = $_.Exception.Message } # Reported once logging is ready; preset values stay.

$healthPolicy = Get-ArkuzoHealthPolicy $loadedConfig.health
$restorePolicy = Get-ArkuzoRestorePolicy $loadedConfig.recovery
$script:accountProviderSetting = Get-ArkuzoProviderSetting $loadedConfig
$isConfigLocked = ($null -ne $loadedConfig.config_lock -and [bool]$loadedConfig.config_lock)
if ($isConfigLocked) {
    $ApplyGraphicsFlags = $true
    Set-ArkuzoConfigLockLimits $healthPolicy
}
$lastConfigText = [IO.File]::ReadAllText($configFilePath)
$pagefilePolicy = Get-ArkuzoPagefilePolicy -Input $loadedConfig.pagefile -PressurePercent $healthPolicy.pressure_percent
if ($HardLimit) { $SoftLimit = $false }
if ($HardLimit -and $PSBoundParameters.ContainsKey('SoftLimit') -and $PSBoundParameters['SoftLimit']) {
    throw 'Use either -HardLimit or -SoftLimit, not both.'
}

# 2. Preset rules when Mode is explicitly specified on CLI without granular flags
if ($PSBoundParameters.ContainsKey('Mode')) {
    $cleanMode = $Mode.ToLowerInvariant()
    if ($cleanMode -eq 'aggressive') { $cleanMode = 'agressive' }
    if ($cleanMode -eq 'normal' -or $cleanMode -eq 'balanced') {
        if (-not $PSBoundParameters.ContainsKey('MaxRamMB')) { $MaxRamMB = 850 }
        if (-not $PSBoundParameters.ContainsKey('TrimEverySec')) { $TrimEverySec = 120 }
        if (-not $PSBoundParameters.ContainsKey('CoresPerInstance')) { $CoresPerInstance = 4 }
        if (-not $PSBoundParameters.ContainsKey('Priority')) { $Priority = 'BelowNormal' }
        if (-not $PSBoundParameters.ContainsKey('SoftLimit') -and -not $HardLimit) { $SoftLimit = $true }
    }
    if ($cleanMode -eq 'agressive') {
        if (-not $PSBoundParameters.ContainsKey('MaxRamMB')) { $MaxRamMB = 600 }
        if (-not $PSBoundParameters.ContainsKey('TrimEverySec')) { $TrimEverySec = 60 }
        if (-not $PSBoundParameters.ContainsKey('CoresPerInstance')) { $CoresPerInstance = 2 }
        if (-not $PSBoundParameters.ContainsKey('Priority')) { $Priority = 'BelowNormal' }
        if (-not $PSBoundParameters.ContainsKey('SoftLimit') -and -not $HardLimit) { $SoftLimit = $true }
    }
    if ($cleanMode -eq 'extreme') {
        if (-not $PSBoundParameters.ContainsKey('MaxRamMB')) { $MaxRamMB = 450 }
        if (-not $PSBoundParameters.ContainsKey('TrimEverySec')) { $TrimEverySec = 30 }
        if (-not $PSBoundParameters.ContainsKey('CoresPerInstance')) { $CoresPerInstance = 1 }
        if (-not $PSBoundParameters.ContainsKey('Priority')) { $Priority = 'BelowNormal' }
        if (-not $PSBoundParameters.ContainsKey('PollMs')) { $PollMs = 250 }
        if (-not $PSBoundParameters.ContainsKey('SoftLimit') -and -not $HardLimit) { $SoftLimit = $true }
    }
}

