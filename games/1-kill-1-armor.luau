-- Game guard: this module only runs in "1 Kill = 1 Armor!" (universe 8798246146).
if game.GameId ~= 8798246146 then return end

--!nocheck
--[[
    1 Kill = 1 Armor — TP-behind kill farm
    Built on EZ-UI-Library (https://github.com/Beastaive22/EZ-UI-Library)
    Executor: Potassium / sUNC. Control surface: getgenv().KillOneArmor

    HOW THE GAME FIGHTS (from decompiled Client.Controllers.Gameplay.Game
    .CombatController — corpus dump in mcp_dumps/132547252102193/src/):
      - Damage is client-reported: CombatService:ApplyDamage(target, charge)
      - The game's own swing = SwingSword + combo animation, then after 0.1s a
        6x6x6.5-stud box in FRONT of the HRP (camera-facing) collects humanoid
        chars and calls ApplyDamage on each. Client gate: 0.7s between swings.
      - Anti-cheat: server pings RequestWalkSpeed, client answers its
        WalkSpeed. We never touch WalkSpeed. AntiCheatExploit and
        AntiCheatService.ReportWalkSpeed are NEVER fired by this script.

    WHAT THIS SCRIPT DOES:
      - picks the nearest alive player inside Range
      - teleports BEHIND them (their sword box points forward 6.5 studs, ours
        points at their back) right before each swing
      - swings through the game's OWN CombatController:Attack (authentic
        facing, animation, SwingSword timing and ApplyDamage ordering) —
        falls back to direct SpeedService/CombatService calls if the runtime
        controller is unavailable
      - skips "dry" targets (4 swings, zero damage confirms) for 4s
      - everything OFF by default; toggling Enable arms it

    Toggle UI: RightShift. Enable keybind default: F (Mode=Toggle).
]]

if getgenv().__K1A_DESTROY then
    pcall(getgenv().__K1A_DESTROY)
end

----------------------------------------------------------------
-- Library (canonical EZ-UI-Library setup)
----------------------------------------------------------------
local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local EZ = loadstring(game:HttpGet(repo .. "Library.lua"))()
local Icons = loadstring(game:HttpGet(repo .. "addons/Icons.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local QuickBar = loadstring(game:HttpGet(repo .. "addons/QuickBar.lua"))()
local NotifHistory = loadstring(game:HttpGet(repo .. "addons/NotificationHistory.lua"))()

EZ:SetIcons(Icons)
SaveManager:Bind(EZ, "KillOneArmorConfigs")
ThemeManager:Bind(EZ, { File = "KillOneArmor_Theme.txt" })
ThemeManager:LoadSaved() -- apply saved theme before the window builds: no colour flash
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

----------------------------------------------------------------
-- Runtime
----------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer

local Conns = {}
local function track(conn)
    Conns[#Conns + 1] = conn
    return conn
end

local Knit = nil
pcall(function()
    Knit = require(RS:WaitForChild("Packages", 10):WaitForChild("Knit", 5))
end)

local WeaponTypeInfo = nil
pcall(function()
    WeaponTypeInfo = require(RS:WaitForChild("GameInfo", 10)
        :WaitForChild("Game", 5):WaitForChild("WeaponTypeInfo", 5))
end)

-- RAW remotes only. Knit's service PROXY degrades the calling thread's
-- identity (verified live: after Svc:Connect / proxy method calls, CoreGui
-- parenting from this thread loses Plugin capability). RF/RE folders under
-- Packages.Knit.Services.<Name>Service are plain instances — safe to use.
local Remote = {}
pcall(function()
    local services = RS:WaitForChild("Packages", 10):WaitForChild("Knit", 5):WaitForChild("Services", 10)
    local function get(service, kind, name)
        local svc = services:FindFirstChild(service)
        return svc and svc:FindFirstChild(kind) and svc[kind]:FindFirstChild(name)
    end
    Remote.ApplyDamage = get("CombatService", "RF", "ApplyDamage")
    Remote.SwingSword = get("SpeedService", "RF", "SwingSword")
    Remote.OnDamageDealt = get("CombatService", "RE", "OnDamageDealt")
end)

-- The game's own runtime CombatController (requiring the runtime instance
-- returns the same table Knit injected services into, so :Attack() is the
-- authentic full swing: facing, animation, SwingSword, hitbox, ApplyDamage).
local CombatCtl = nil
pcall(function()
    local ps = lp:WaitForChild("PlayerScripts", 15)
    local ctl = ps:WaitForChild("Client", 10)
        :WaitForChild("Controllers", 10)
        :WaitForChild("Gameplay", 10)
        :WaitForChild("Game", 10)
        :WaitForChild("CombatController", 10)
    CombatCtl = require(ctl)
end)

----------------------------------------------------------------
-- Config / stats
----------------------------------------------------------------
local cfg = {
    enabled = false,
    range = 96,           -- target pick radius (planar studs)
    tpDist = 4.5,         -- studs behind the target (their front box is 6.5)
    follow = false,       -- continuous re-TP between swings (loud but sticky)
    skipDry = true,       -- bench targets that absorb swings without confirms
    mode = "Authentic",   -- Authentic (game's own Attack) | Direct (SwingSword+ApplyDamage)
}
local stats = {
    swings = 0,
    confirms = 0,
    benched = 0,
    lastTarget = "-",
    lastSwingAt = 0,
}
local statusText = "idle"
local RUNNING = true

-- current weapon type -> {Damage, Cooldown, Range} multipliers
local function combatStats()
    local t = "Swords"
    if WeaponTypeInfo and WeaponTypeInfo.Types then
        local char = lp.Character
        if char then
            for name, info in pairs(WeaponTypeInfo.Types) do
                if info.EquipmentFolder and char:FindFirstChild(info.EquipmentFolder) then
                    t = name
                    break
                end
            end
        end
    end
    if WeaponTypeInfo and WeaponTypeInfo.GetCombatStats then
        local got = WeaponTypeInfo:GetCombatStats(t)
        if got then return t, got end
    end
    return t, { DamageMultiplier = 1, CooldownMultiplier = 1, RangeMultiplier = 1 }
end

----------------------------------------------------------------
-- Target selection + dry bench
----------------------------------------------------------------
local dryInfo = {} -- [player] = { swings, confirms, benchUntil }

local function markConfirm(targetChar)
    stats.confirms = stats.confirms + 1
    local info = dryInfo[targetChar]
    if info then info.confirms = info.confirms + 1 end
    statusText = "hit confirmed"
end

pcall(function()
    track(Remote.OnDamageDealt.OnClientEvent:Connect(function(targetChar)
        if typeof(targetChar) == "Instance" then
            markConfirm(targetChar)
        end
    end))
end)

local function benchCheck(plr)
    if not cfg.skipDry then return true end
    local info = dryInfo[plr]
    if not info then return true end
    return info.benchUntil <= os.clock()
end

local function pickTarget()
    local char = lp.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not (char and hrp) then return nil end
    local best, bestDist = nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= lp and benchCheck(plr) then
            local tchar = plr.Character
            local thum = tchar and tchar:FindFirstChildOfClass("Humanoid")
            local thrp = tchar and tchar:FindFirstChild("HumanoidRootPart")
            if tchar and thum and thrp and thum.Health > 0 then
                local d = thrp.Position - hrp.Position
                local planar = math.sqrt(d.X * d.X + d.Z * d.Z)
                if planar <= cfg.range and planar < bestDist then
                    best, bestDist = plr, planar
                end
            end
        end
    end
    return best
end

----------------------------------------------------------------
-- Swing path
----------------------------------------------------------------
local gateBase = 0.7 -- the game's own client gate (CombatController u9)

local function swingDirect(targetChar)
    if not (Remote.SwingSword and Remote.ApplyDamage) then return false end
    Remote.SwingSword:InvokeServer()
    Remote.ApplyDamage:InvokeServer(targetChar, nil)
    return true
end

local function swingAuthentic()
    if CombatCtl and CombatCtl.CombatService and CombatCtl.Attack then
        -- the controller makes Knit-proxy calls internally; run it on a spawned
        -- thread so its identity changes never touch our Heartbeat thread
        task.spawn(function()
            pcall(function() CombatCtl:Attack(nil) end)
        end)
        return true
    end
    return false
end

local function registerSwing(plr)
    stats.swings = stats.swings + 1
    stats.lastSwingAt = os.clock()
    stats.lastTarget = plr.Name
    local info = dryInfo[plr]
    if not info then
        info = { swings = 0, confirms = 0, benchUntil = 0 }
        dryInfo[plr] = info
    end
    info.swings = info.swings + 1
    if cfg.skipDry and info.swings >= 4 and info.confirms == 0 then
        info.benchUntil = os.clock() + 4
        info.swings = 0
        info.confirms = 0
        stats.benched = stats.benched + 1
        statusText = "benched dry target: " .. plr.Name
    end
end

----------------------------------------------------------------
-- Main loop (aim every frame, swing on the gate)
----------------------------------------------------------------
local loopConn

loopConn = RunService.Heartbeat:Connect(function()
    stats.heartbeats = (stats.heartbeats or 0) + 1
    if not (RUNNING and cfg.enabled) then return end
    local ok, err = pcall(function()
        local now = os.clock()
        local target = pickTarget()
        if not target then
            statusText = "no target in range"
            return
        end
        statusText = "engaged: " .. target.Name
        local char = lp.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local tchar = target.Character
        local thrp = tchar and tchar:FindFirstChild("HumanoidRootPart")
        if not (hrp and thrp) then return end
        -- aim the camera at the target head (the swing hitbox is camera-facing)
        local cam = workspace.CurrentCamera
        if cam then
            local head = thrp.Position + Vector3.new(0, 1.2, 0)
            cam.CFrame = CFrame.lookAt(cam.CFrame.Position, head)
        end
        if cfg.follow then
            local back = thrp.CFrame * CFrame.new(0, 0, cfg.tpDist)
            hrp.CFrame = CFrame.lookAt(back.Position,
                Vector3.new(thrp.Position.X, back.Position.Y, thrp.Position.Z))
        end
        -- swing on the weapon-aware gate; TP right behind before the swing
        local _, mult = combatStats()
        if now - stats.lastSwingAt < (gateBase / (mult.CooldownMultiplier or 1)) + 0.08 then return end
        local back = thrp.CFrame * CFrame.new(0, 0, cfg.tpDist)
        hrp.CFrame = CFrame.lookAt(back.Position,
            Vector3.new(thrp.Position.X, back.Position.Y, thrp.Position.Z))
        local ok2
        if cfg.mode == "Direct" then
            ok2 = swingDirect(tchar)
        else
            ok2 = swingAuthentic() or swingDirect(tchar)
        end
        if ok2 then
            registerSwing(target)
        else
            statusText = "no swing path available"
        end
    end)
    if not ok then
        statusText = "loop error: " .. tostring(err):sub(1, 80)
    end
end)

----------------------------------------------------------------
-- UI
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "1 Kill = 1 Armor",
    ToggleKey = Enum.KeyCode.RightShift,
    ToggleIcon = "swords",
})
QuickBar:Bind(EZ, Window)
NotifHistory:Bind(EZ, Window)

local MainTab = Window:AddTab("Main", "swords")
local RefTab = Window:AddTab("Reference", "shield")

local farmGB = MainTab:AddLeftGroupbox("Kill Farm")
local liveGB = MainTab:AddRightGroupbox("Live Status")
local refGB = RefTab:AddSection("Safety notes")

local masterHandle
masterHandle = farmGB:AddToggle("K1AEnable", {
    Text = "Enable kill farm",
    Default = cfg.enabled,
    Tooltip = "TPs behind the nearest player and swings through the game's own combat path",
    Callback = function(v)
        cfg.enabled = v
        statusText = v and "armed" or "disabled"
    end,
})

farmGB:AddKeybind("K1AEnableKey", {
    Text = "Kill farm keybind",
    Default = Enum.KeyCode.F,
    Mode = "Toggle",
    Callback = function(isActive)
        masterHandle:Set(isActive) -- write through the handle so the UI moves too
    end,
})

farmGB:AddSlider("K1ARange", {
    Text = "Target range",
    Default = cfg.range, Min = 8, Max = 256, Rounding = 0,
    Tooltip = "Planar studs — how far it looks for players",
    Callback = function(v) cfg.range = v end,
})

farmGB:AddSlider("K1ATpDist", {
    Text = "TP distance (behind)",
    Default = cfg.tpDist, Min = 3.5, Max = 6, Rounding = 1,
    Tooltip = "Their sword box reaches 6.5 studs forward — stay inside ours, outside theirs",
    Callback = function(v) cfg.tpDist = v end,
})

farmGB:AddDropdown("K1AMode", {
    Values = { "Authentic", "Direct" },
    Default = cfg.mode,
    Tooltip = "Authentic = the game's own CombatController:Attack. Direct = SwingSword + ApplyDamage only",
    Callback = function(v) cfg.mode = v end,
})

farmGB:AddToggle("K1AFollow", {
    Text = "Continuous follow",
    Default = cfg.follow,
    Tooltip = "Re-TP every frame while engaged (louder on position checks, stickier on runners)",
    Callback = function(v) cfg.follow = v end,
})

farmGB:AddToggle("K1ASkipDry", {
    Text = "Skip dry targets",
    Default = cfg.skipDry,
    Tooltip = "Bench players for 4s after 4 swings with zero damage confirms",
    Callback = function(v) cfg.skipDry = v end,
})

local uiStatus = liveGB:AddLabel("Status: idle")
local uiTarget = liveGB:AddLabel("Target: -")
local uiSwings = liveGB:AddLabel("Swings: 0")
local uiConfirms = liveGB:AddLabel("Confirms: 0")
local uiWeapon = liveGB:AddLabel("Weapon: -")

refGB:AddLabel({ Text = "Damage is client-reported (CombatService:ApplyDamage); the swing path mirrors the game's own ordering: SwingSword then damage.", DoesWrap = true })
refGB:AddLabel({ Text = "NEVER fires AntiCheatExploit or ReportWalkSpeed (honeypots). WalkSpeed is never modified, so the server's RequestWalkSpeed poll always reads normal.", DoesWrap = true })
refGB:AddLabel({ Text = "Safe zones are server-enforced; if a swing is denied the target simply takes no damage and gets benched as dry.", DoesWrap = true })
refGB:AddLabel({ Text = "If swings stop landing mid-session, rejoin the server before blaming the script.", DoesWrap = true })

task.spawn(function()
    while RUNNING do
        task.wait(0.5)
        local _, mult = combatStats()
        pcall(function()
            uiStatus:Set("Status: " .. statusText)
            uiTarget:Set("Target: " .. stats.lastTarget)
            uiSwings:Set("Swings: " .. stats.swings)
            uiConfirms:Set("Confirms: " .. stats.confirms .. "  (benched " .. stats.benched .. ")")
            uiWeapon:Set(string.format("Weapon cooldown x%.2f  range x%.2f",
                mult.CooldownMultiplier or 1, mult.RangeMultiplier or 1))
        end)
    end
end)

QuickBar:Pin("K1AEnable", { Icon = "crosshair" })
pcall(function() SaveManager:LoadAutoloadConfig() end)

local function destroy()
    RUNNING = false
    cfg.enabled = false
    if loopConn then pcall(function() loopConn:Disconnect() end) end
    for _, c in ipairs(Conns) do pcall(function() c:Disconnect() end) end
    table.clear(Conns)
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHistory:Destroy() end)
    getgenv().__K1A_DESTROY = nil
    getgenv().KillOneArmor = nil
end

EZ:OnDestroy(destroy)
getgenv().__K1A_DESTROY = destroy

getgenv().KillOneArmor = {
    State = function()
        local w, mult = combatStats()
        return {
            enabled = cfg.enabled, status = statusText, target = stats.lastTarget,
            swings = stats.swings, confirms = stats.confirms, benched = stats.benched,
            weapon = w, cooldownMult = mult.CooldownMultiplier, rangeMult = mult.RangeMultiplier,
            heartbeats = stats.heartbeats,
        }
    end,
    Set = function(key, value) cfg[key] = value end,
    Stop = destroy,
    Unload = function()
        destroy()
        EZ:Destroy()
    end,
}

EZ:Notify({ Title = "1 Kill = 1 Armor", Text = "Loaded — Enable in the Main tab. RightShift toggles the UI.", Type = "info", Icon = "swords" })
