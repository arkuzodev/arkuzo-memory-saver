function Get-ArkuzoExecutorRoots {
    $roots = New-Object System.Collections.Generic.HashSet[string]
    if ($env:LOCALAPPDATA) {
        $roots.Add((Join-Path $env:LOCALAPPDATA 'Volt')) | Out-Null
        $roots.Add((Join-Path $env:LOCALAPPDATA 'Potassium')) | Out-Null
        $roots.Add((Join-Path $env:LOCALAPPDATA 'com.volt.editor')) | Out-Null
        $roots.Add((Join-Path $env:LOCALAPPDATA 'com.pot.potassium-tauri')) | Out-Null
    }
    if ($env:APPDATA) {
        $roots.Add((Join-Path $env:APPDATA 'Volt')) | Out-Null
        $roots.Add((Join-Path $env:APPDATA 'Potassium')) | Out-Null
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    $progFiles = [Environment]::GetFolderPath('ProgramFiles')
    $progFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    foreach ($base in @($desktop, $userProfile, $progFiles, $progFilesX86)) {
        if ($base -and (Test-Path -LiteralPath $base)) {
            foreach ($sub in @('Volt', 'VoltX', 'Potassium', 'Tools & Mods\Volt', 'Tools & Mods\VoltX', 'Tools & Mods\potass', 'Tools & Mods\potae')) {
                $cand = Join-Path $base $sub
                if (Test-Path -LiteralPath $cand) { $roots.Add($cand) | Out-Null }
            }
        }
    }
    $baseDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { [AppDomain]::CurrentDomain.BaseDirectory }
    if ($baseDir) {
        foreach ($cand in @((Join-Path $baseDir 'Volt'), (Join-Path $baseDir 'VoltX'), (Join-Path $baseDir 'Potassium'),
                            (Join-Path (Split-Path -Parent $baseDir) 'Volt'), (Join-Path (Split-Path -Parent $baseDir) 'VoltX'), (Join-Path (Split-Path -Parent $baseDir) 'Potassium'))) {
            if ($cand -and (Test-Path -LiteralPath $cand)) { $roots.Add($cand) | Out-Null }
        }
    }
    try {
        Get-Process | Where-Object { $_.ProcessName -match '(?i)\A(volt|potassium|tauri-app)' } | ForEach-Object {
            try {
                $pPath = $_.Path
                if (-not $pPath -and $_.MainModule) { $pPath = $_.MainModule.FileName }
                if ($pPath) {
                    $pDir = Split-Path -Parent $pPath
                    $roots.Add($pDir) | Out-Null
                    $parentDir = Split-Path -Parent $pDir
                    if ($parentDir) { $roots.Add($parentDir) | Out-Null }
                }
            } catch { }
        }
    } catch { }
    return @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
}

function Get-ArkuzoExecutorSignalDirectories {
    $dirs = New-Object System.Collections.Generic.HashSet[string]
    $roots = Get-ArkuzoExecutorRoots
    foreach ($r in $roots) {
        if ((Split-Path -Leaf $r) -ieq 'workspace') {
            $dirs.Add($r) | Out-Null
        } else {
            $ws = Join-Path $r 'workspace'
            if (Test-Path -LiteralPath $ws) { $dirs.Add($ws) | Out-Null }
        }
    }
    return @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
}

function Read-ArkuzoExecutorSignals {
    $signals = @()
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $workspaces = Get-ArkuzoExecutorSignalDirectories
    foreach ($ws in $workspaces) {
        $candidateFiles = @()
        $sub = Join-Path $ws "arkuzo_signals"
        if (Test-Path $sub) {
            $candidateFiles += @(Get-ChildItem -Path $sub -Filter "*.json" -ErrorAction SilentlyContinue)
        }
        $candidateFiles += @(Get-ChildItem -Path $ws -Filter "arkuzo_signals_*.json" -ErrorAction SilentlyContinue)
        $candidateFiles += @(Get-ChildItem -Path $ws -Filter "arkuzo_signals_latest.json" -ErrorAction SilentlyContinue)
        foreach ($f in $candidateFiles) {
            try {
                $raw = [IO.File]::ReadAllText($f.FullName)
                $sig = $raw | ConvertFrom-Json
                if ($null -ne $sig -and $sig.username) {
                    $sigAge = if ($sig.timestamp) { $now - [long]$sig.timestamp } else { 0 }
                    if ($sigAge -ge -15 -and $sigAge -le 180) {
                        $signals += [pscustomobject]@{
                            Username = [string]$sig.username
                            UserId = [string]$sig.userId
                            Reason = [string]$sig.reason
                            ErrorCode = [int]$sig.errorCode
                            Source = [string]$sig.source
                            FilePath = $f.FullName
                        }
                    }
                }
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            } catch { }
        }
    }
    return $signals
}

$script:ArkuzoAutoexecLuauContent = @'
--[[
    Arkuzo Saver - Autonomous Ingame Kick & Disconnect Signal Transmitter
    Automatically installed into executor autoexec by Arkuzo Saver.
    Catches kicks, bans, error prompts, disconnects, and teleports, writing instant signals to workspace.
]]--

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local fired = false

local function sendSignal(reason, errorCode, source)
    if fired then return end
    fired = true

    local username = "Unknown"
    local userId = 0
    pcall(function()
        if Players.LocalPlayer then
            username = Players.LocalPlayer.Name
            userId = Players.LocalPlayer.UserId
        end
    end)

    local payload = {
        username = username,
        userId = userId,
        placeId = game.PlaceId,
        jobId = game.JobId,
        reason = tostring(reason or "Unknown Kick/Disconnect"),
        errorCode = tonumber(errorCode) or 0,
        source = source or "ArkuzoAutoexecSignal",
        timestamp = os.time()
    }

    local jsonStr = nil
    pcall(function()
        jsonStr = HttpService:JSONEncode(payload)
    end)
    if not jsonStr then return end

    -- Write signal files into executor workspace
    pcall(function()
        if writefile then
            pcall(function()
                if makefolder and not isfolder("arkuzo_signals") then
                    makefolder("arkuzo_signals")
                end
                writefile("arkuzo_signals/" .. tostring(userId) .. ".json", jsonStr)
            end)
            pcall(function()
                writefile("arkuzo_signals_" .. tostring(username) .. ".json", jsonStr)
            end)
            pcall(function()
                writefile("arkuzo_signals_latest.json", jsonStr)
            end)
        end
    end)
end

-- 1. GuiService Error Message Changed (Standard Roblox Disconnect / Kick Code 267, 277, etc.)
pcall(function()
    GuiService.ErrorMessageChanged:Connect(function(errorMessage)
        if errorMessage and errorMessage ~= "" then
            local code = 0
            pcall(function()
                code = GuiService:GetErrorCode().Value
            end)
            sendSignal(errorMessage, code, "GuiService.ErrorMessageChanged")
        end
    end)
end)

-- 2. CoreGui Error Prompt Overlay (Catches custom kick UIs and error modals)
pcall(function()
    local promptGui = CoreGui:WaitForChild("RobloxPromptGui", 5)
    if promptGui then
        local promptOverlay = promptGui:WaitForChild("promptOverlay", 5)
        if promptOverlay then
            promptOverlay.ChildAdded:Connect(function(child)
                if child.Name == "ErrorPrompt" then
                    local code = 0
                    pcall(function() code = GuiService:GetErrorCode().Value end)
                    local msg = ""
                    pcall(function()
                        local msgArea = child:FindFirstChild("MessageArea")
                        if msgArea then
                            local errorFrame = msgArea:FindFirstChild("ErrorFrame")
                            local errorMsg = errorFrame and errorFrame:FindFirstChild("ErrorMessage")
                            if errorMsg and errorMsg:IsA("TextLabel") then
                                msg = errorMsg.Text
                            end
                        end
                    end)
                    sendSignal(msg ~= "" and msg or "ErrorPrompt displayed", code, "RobloxPromptGui.ErrorPrompt")
                end
            end)
        end
    end
end)

-- 3. NetworkClient Disconnection (ClientReplicator dropped)
pcall(function()
    local nc = game:GetService("NetworkClient")
    nc.ChildRemoved:Connect(function(child)
        if child:IsA("ClientReplicator") then
            sendSignal("ClientReplicator disconnected", 277, "NetworkClient.ChildRemoved")
        end
    end)
end)

-- 4. Teleport Init Failed (Teleport Disconnect)
pcall(function()
    TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage)
        sendSignal("TeleportInitFailed: " .. tostring(errorMessage), 279, "TeleportService.TeleportInitFailed")
    end)
end)

-- 5. Fallback periodic check
task.spawn(function()
    while not fired do
        task.wait(1.5)
        pcall(function()
            local code = 0
            pcall(function() code = GuiService:GetErrorCode().Value end)
            if code ~= 0 then
                local msg = ""
                pcall(function() msg = GuiService:GetErrorMessage() end)
                sendSignal(msg ~= "" and msg or ("Error code " .. tostring(code)), code, "PeriodicWatchdog")
            end
        end)
    end
end)
'@

function Sync-ArkuzoAutoexecSignals {
    $scriptContent = $script:ArkuzoAutoexecLuauContent
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
        $scriptSource = Join-Path $PSScriptRoot "00-arkuzo-signal.luau"
        if (Test-Path $scriptSource) {
            try { $scriptContent = [IO.File]::ReadAllText($scriptSource) } catch { }
        }
    }
    # ONLY direct autoexec directories, NEVER subfolders
    $executorRoots = Get-ArkuzoExecutorRoots
    foreach ($root in $executorRoots) {
        $autoexecDir = if ((Split-Path -Leaf $root) -ieq 'autoexec') { $root } else { Join-Path $root 'autoexec' }
        if (-not (Test-Path -LiteralPath $autoexecDir) -and (Split-Path -Leaf $root) -imatch '(?i)\A(Volt|VoltX|Potassium|com\.volt\.editor)\z') {
            try { [IO.Directory]::CreateDirectory($autoexecDir) | Out-Null } catch { }
        }
        if (Test-Path -LiteralPath $autoexecDir) {
            # Clean up any accidental subfolder duplicates
            Get-ChildItem -LiteralPath $autoexecDir -Recurse -Depth 3 -Filter "00-arkuzo-signal.luau" -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.DirectoryName -ne $autoexecDir) {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch { }
                }
            }
            # Write only to the root autoexec folder
            $dest = Join-Path $autoexecDir "00-arkuzo-signal.luau"
            $needWrite = $true
            if (Test-Path -LiteralPath $dest) {
                try {
                    $existing = [IO.File]::ReadAllText($dest)
                    if ($existing.Trim() -eq $scriptContent.Trim()) { $needWrite = $false }
                } catch { }
            }
            if ($needWrite) {
                try {
                    [IO.File]::WriteAllText($dest, $scriptContent, [Text.Encoding]::UTF8)
                    Write-Diagnostic 'AUTOEXEC_SIGNAL_SCRIPT_SYNCED' @{ destination = $dest }
                } catch { }
            }
        }
    }
}

function Process-ArkuzoExecutorSignals {
    try {
        $signals = Read-ArkuzoExecutorSignals
        foreach ($sig in $signals) {
            $matchedPid = $null
            foreach ($kv in $script:tracked.GetEnumerator()) {
                $checkPid = $kv.Key
                $st = $kv.Value
                $name = Resolve-ArkuzoAccountName -ProcessId $checkPid -TrackerId $st.TrackerId -LogPath $st.LogPath
                if ($name -and ($name.TrimStart('@') -ieq $sig.Username -or $name -ieq $sig.Username)) {
                    $matchedPid = $checkPid; break
                }
            }
            # Only an exact account name binds a signal. A signal names its account; one that
            # matches no tracked client is dropped, never attributed by guess (a single tracked
            # client is not proof: the signal may be up to 180 s old and from another account).
            if ($null -ne $matchedPid -and $script:tracked.ContainsKey($matchedPid)) {
                $targetState = $script:tracked[$matchedPid]
                $targetState.isDisconnected = $true
                $targetState.GameReady = $false
                $targetState.DisconnectReason = "Executor Signal: $($sig.Reason) (Code $($sig.ErrorCode))"
                if ($targetState -is [Collections.IDictionary]) { $targetState['DisconnectSource'] = [string]$sig.Source } else { $targetState | Add-Member -NotePropertyName DisconnectSource -NotePropertyValue ([string]$sig.Source) -Force }
                Write-Diagnostic 'EXECUTOR_KICK_SIGNAL_TRIGGERED' @{
                    pid = $matchedPid
                    username = $sig.Username
                    reason = $sig.Reason
                    errorCode = $sig.ErrorCode
                    source = $sig.Source
                }
            }
        }
    } catch { }
}

