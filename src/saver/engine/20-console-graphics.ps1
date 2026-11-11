function Get-ArkuzoConsoleInputModeMask([int]$CurrentMode) {
    # Clear ENABLE_QUICK_EDIT_MODE (0x0040) and ENABLE_INSERT_MODE (0x0020)
    # Set ENABLE_EXTENDED_FLAGS (0x0080) so changes take effect
    $mode = ($CurrentMode -band (-bnot 0x0040)) -band (-bnot 0x0020)
    $mode = $mode -bor 0x0080
    return [int]$mode
}

function Set-ArkuzoConsoleQuickEditDisabled {
    if ($Headless) { return }
    try {
        if ('Arkuzo.MemorySaverNativeV1' -as [type]) {
            $current = [Arkuzo.MemorySaverNativeV1]::ReadConsoleInputMode()
            if ($null -ne $current) {
                $masked = Get-ArkuzoConsoleInputModeMask ([int]$current)
                if ($masked -ne [int]$current) {
                    [Arkuzo.MemorySaverNativeV1]::SetConsoleInputMode([uint32]$masked) | Out-Null
                }
            }
        }
    } catch { }
}

# Only optional local graphics flags; merge rather than erase other settings.
function Get-ArkuzoGraphicsInstallDirectories {
    [CmdletBinding()]
    param([string[]]$SearchRoots=@(), [string[]]$ProcessImagePaths=@())
    $candidates = New-Object 'Collections.Generic.List[string]'
    foreach ($imagePath in $ProcessImagePaths) {
        if ([string]::IsNullOrWhiteSpace($imagePath)) { continue }
        try {
            if ([IO.Path]::GetFileName($imagePath) -ieq 'RobloxPlayerBeta.exe') {
                [void]$candidates.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($imagePath)))
            }
        } catch { continue }
    }
    foreach ($root in $SearchRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try {
            if (-not [IO.Directory]::Exists($root)) { continue }
            [void]$candidates.Add([IO.Path]::GetFullPath($root))
            foreach ($child in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)) {
                [void]$candidates.Add($child.FullName)
            }
        } catch { continue }
    }
    $directories = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if ([IO.File]::Exists([IO.Path]::Combine($candidate, 'RobloxPlayerBeta.exe'))) { [void]$directories.Add($candidate) }
    }
    return @($directories | Sort-Object)
}
function Merge-ArkuzoGraphicsFlags {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SettingsFile)
    $SettingsFile = [IO.Path]::GetFullPath($SettingsFile)
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $settings = [ordered]@{}
    $originalBytes = $null
    $existed = [IO.File]::Exists($SettingsFile)
    if ($existed) {
        try {
            $originalBytes = [IO.File]::ReadAllBytes($SettingsFile)
            $text = $encoding.GetString($originalBytes).TrimStart([char]0xFEFF)
            # ConvertFrom-Json unwraps a one-element array in PS 5.1; check the root token too.
            if ([string]::IsNullOrWhiteSpace($text) -or -not $text.TrimStart().StartsWith('{')) { throw 'Not an object' }
            $parsed = $text | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) { throw 'Not an object' }
        } catch { throw 'ClientAppSettings.json must contain a valid UTF-8 JSON object and be readable. File left unchanged.' }
        foreach ($property in $parsed.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    }
    $settings['DFFlagTextureQualityOverrideEnabled'] = 'True'
    $settings['DFIntTextureQualityOverride'] = '0'
    $settings['FIntDebugForceMSAASamples'] = '1'
    $settings['DFIntTaskSchedulerTargetFps'] = [int]15
    $json = $settings | ConvertTo-Json -Depth 100 -ErrorAction Stop
    $directory = [IO.Path]::GetDirectoryName($SettingsFile)
    [void][IO.Directory]::CreateDirectory($directory)
    $uniqueTag = [guid]::NewGuid().ToString('N')
    $temporaryFile = $SettingsFile + '.arkuzo-' + $uniqueTag + '.tmp'
    $backupPath = $null
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($temporaryFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bytes = $encoding.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose(); $stream = $null
        if ($existed) {
            # Refuse an observed concurrent edit instead of clobbering newly added user settings.
            if (-not [IO.File]::Exists($SettingsFile) -or
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($SettingsFile)) -cne [Convert]::ToBase64String($originalBytes)) {
                throw 'ClientAppSettings.json changed during the merge. No replacement performed.'
            }
            $backupPath = $SettingsFile + '.arkuzo-' + $uniqueTag + '.bak'
            # Same-directory atomic replacement creates an exact-byte backup. Never fall back to truncation.
            [IO.File]::Replace($temporaryFile, $SettingsFile, $backupPath)
        } else {
            # Move refuses to overwrite a file created by another writer after discovery.
            [IO.File]::Move($temporaryFile, $SettingsFile)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($temporaryFile)) { [IO.File]::Delete($temporaryFile) }
    }
    return [pscustomobject]@{ SettingsFile=$SettingsFile; BackupPath=$backupPath; Changed=$true; RequestedFps=15; FpsStatus='REQUESTED_ONLY' }
}
function Invoke-ArkuzoGraphicsSettings {
    [CmdletBinding()]
    param([string[]]$InstallDirectories=@(), [switch]$ApplyGraphicsFlags, [switch]$MonitorOnly)
    if ($MonitorOnly) { return [pscustomobject]@{ Status='SKIPPED_MONITOR_ONLY'; Files=@(); Message='Graphics settings skipped: monitor-only.' } }
    if (-not $ApplyGraphicsFlags) { return [pscustomobject]@{ Status='SKIPPED_DISABLED'; Files=@(); Message='Graphics settings disabled.' } }
    if ($InstallDirectories.Count -eq 0) {
        return [pscustomobject]@{ Status='SKIPPED_NO_INSTALLATIONS'; Files=@(); Message='Roblox installation not found; graphics settings skipped.' }
    }
    $files = @()
    foreach ($directory in @($InstallDirectories | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($directory) -or -not [IO.File]::Exists([IO.Path]::Combine($directory, 'RobloxPlayerBeta.exe'))) {
            throw 'Roblox Player installation changed or is unavailable; graphics settings refused.'
        }
        $settingsFile = Join-Path (Join-Path $directory 'ClientSettings') 'ClientAppSettings.json'
        $files += Merge-ArkuzoGraphicsFlags -SettingsFile $settingsFile
    }
    return [pscustomobject]@{
        Status='REQUESTED'; Files=@($files)
        Message='Graphics flags REQUESTED (texture quality 0 / MSAA 1 / 15 FPS). DFIntTaskSchedulerTargetFps is not on the Roblox Player allowlist and is ignored there; actual FPS and rendering are not verified. Restart compatible clients to read requested settings.'
    }
}
function Initialize-ArkuzoGraphicsSettings {
    if ($MonitorOnly -or -not $ownsControllerMutex -or -not $ApplyGraphicsFlags) { return }
    try {
    $graphicsRoots = @()
    foreach ($graphicsBase in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($graphicsBase)) { continue }
        $graphicsRoots += Join-Path $graphicsBase 'Roblox/Versions'
        $graphicsRoots += Join-Path $graphicsBase 'Roblox'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $graphicsRoots += Join-Path $env:ProgramData 'roblox/roblox'
        $graphicsRoots += Join-Path $env:ProgramData 'Roblox/Versions'
    }
    # Builds the Control Center's Roblox tab installed (docs/roblox-versions.md). The vault may not be
    # read yet at start-up, so it is read here for robloxVersionsDir.
    $managedVault = $script:nativeVault
    if ($null -eq $managedVault) { try { $managedVault = Invoke-ArkuzoVaultLocked { Read-ArkuzoVaultFile } } catch { $managedVault = $null } }
    $managedRoot = Get-ArkuzoManagedVersionsRoot $managedVault
    if ($managedRoot) { $graphicsRoots += $managedRoot }
    $graphicsImagePaths = @()
    foreach ($graphicsProcess in @(Get-Process -Name RobloxPlayerBeta -ErrorAction SilentlyContinue)) {
        try { if ($graphicsProcess.Path) { $graphicsImagePaths += $graphicsProcess.Path } }
        catch {} finally { $graphicsProcess.Dispose() }
    }
    $graphicsDirectories = @(Get-ArkuzoGraphicsInstallDirectories -SearchRoots $graphicsRoots -ProcessImagePaths $graphicsImagePaths)
    $graphicsReport = Invoke-ArkuzoGraphicsSettings -InstallDirectories $graphicsDirectories -ApplyGraphicsFlags:$ApplyGraphicsFlags -MonitorOnly:$MonitorOnly
    $script:graphicsStatus=$graphicsReport
    $script:graphicsAppliedDirectories = @{}
    foreach ($graphicsDirectory in $graphicsDirectories) { $script:graphicsAppliedDirectories[([string]$graphicsDirectory).ToLowerInvariant()] = $true }
    Write-Diagnostic 'GRAPHICS_STATUS' $graphicsReport
    if ($graphicsReport.Status -cne 'REQUESTED') { Warn-Throttled 'graphics-settings' $graphicsReport.Message }
    } catch {
        $script:graphicsStatus=[pscustomobject]@{Status='FAILED';Files=@();Message=('Graphics settings failed: '+$_.Exception.Message)}
        Write-Diagnostic 'GRAPHICS_STATUS' $script:graphicsStatus
        Warn-Throttled 'graphics-settings' $script:graphicsStatus.Message
    }
}
function Update-ArkuzoGraphicsForInstall([string]$Directory) {
    # A build installed after start-up (the Roblox tab) gets the same flags before its first launch.
    # Once per folder per engine run; a failure is reported and never blocks the launch.
    if ($MonitorOnly -or -not $ownsControllerMutex -or -not $ApplyGraphicsFlags -or [string]::IsNullOrWhiteSpace($Directory)) { return }
    if ($null -eq $script:graphicsAppliedDirectories) { $script:graphicsAppliedDirectories = @{} }
    $key = $Directory.ToLowerInvariant()
    if ($script:graphicsAppliedDirectories.ContainsKey($key)) { return }
    $script:graphicsAppliedDirectories[$key] = $true
    try {
        $report = Invoke-ArkuzoGraphicsSettings -InstallDirectories @($Directory) -ApplyGraphicsFlags:$true
        Write-Diagnostic 'GRAPHICS_STATUS' @{ Status = $report.Status; Files = $report.Files; Message = $report.Message; directory = $Directory; note = 'Applied before the first launch of a build installed after the saver started.' }
    } catch {
        Write-Diagnostic 'GRAPHICS_STATUS' @{ Status = 'FAILED'; Files = @(); Message = ('Graphics settings failed: ' + $_.Exception.Message); directory = $Directory }
        Warn-Throttled 'graphics-settings' ('Graphics settings failed for ' + $Directory + ': ' + $_.Exception.Message)
    }
}

