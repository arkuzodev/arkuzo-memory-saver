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
