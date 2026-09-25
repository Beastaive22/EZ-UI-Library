-- Game guard: this module only runs in its own game.
-- game.GameId is the universe id (10767575396), so every place in that
-- game matches. Anywhere else (autoexec, a shared hub, a wrong map
-- entry) it exits before touching anything.
if game.GameId ~= 10767575396 then return end

--[[
    Counter Type Autoplay
    Built on EZ-UI-Library (https://github.com/Beastaive22/EZ-UI-Library)
    Executor: Potassium / sUNC

    Counter Type gives every player a random 4-digit code and asks you to
    "delete" enemies by submitting theirs on the Type Pad. The server
    broadcasts the codes you can currently see over Remotes.Vis; this script
    mirrors that broadcast and submits fresh codes through Remotes.SubmitCode.

    Throws go through the game's own input entry point — PlayerGui.CTUI.InputHook,
    a BindableFunction wired to the client's onInput — so the client's charge
    timer, per-slot cooldowns and HUD all stay consistent. The script only
    points the camera and presses/releases; the game does the rest.

    Respawns watch the death card's countdown and fire Remotes.Respawn once it
    reports ready — the same server call the game's own RESPAWN button makes.

    Every feature defaults OFF, so loading the script is inert until you flip a
    toggle. A wrong code costs the game's own 2.4s submission lockout, so the
    script waits that out (plus a margin) before submitting again.

    Toggle UI: RightShift
]]

local game = game
local getgenv = getgenv

print("[CT-AUTOPLAY] starting")
if getgenv().__CT_AUTOPLAY_LOADED then
    pcall(function() getgenv().__CT_AUTOPLAY_DESTROY() end)
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
SaveManager:Bind(EZ, "CounterTypeAutoplayConfigs")
ThemeManager:Bind(EZ, { File = "CounterTypeAutoplay_Theme.txt" })
ThemeManager:LoadSaved() -- apply saved theme before the window builds: no colour flash
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

----------------------------------------------------------------
-- Runtime handles
----------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer
local PlayerGui = lp:WaitForChild("PlayerGui")

local RUNNING = true
local log -- assigned once the Stats tab builds its log console
local Conns = {} -- every connection this script owns, dropped on teardown

local function track(conn)
    Conns[#Conns + 1] = conn
    return conn
end

-- WaitForChild with a timeout: the lobby place and the match map do not share
-- an identical CT tree, and a bare WaitForChild would hang forever in the lobby.
local function find(parent, name, timeout)
    if not parent then return nil end
    local ok, child = pcall(function() return parent:WaitForChild(name, timeout or 8) end)
    if ok and child then return child end
    return parent:FindFirstChild(name)
end

local CT = find(game:GetService("ReplicatedStorage"), "CT", 15)
local Remotes = CT and find(CT, "Remotes", 5)
local State = CT and find(CT, "State", 5)

-- CT.Config carries the game's own tuning (charge time, whiff lockout,
-- per-slot cooldowns). Requiring it keeps this script in step with the game
-- instead of hardcoding numbers that can drift; every read has a fallback.
local Config = nil
pcall(function() Config = require(CT.Config) end)

local CHARGE_TIME = (Config and Config.CHARGE_TIME) or 0.7
local WHIFF_LOCKOUT = 2.4 -- CTClient sets os.clock() + 2.4 on Remotes.Whiff
local SLOT_COOLDOWN = (Config and Config.COOLDOWN) or { Flash = 20, Smoke = 20 }
local SLOT_KEYS = (Config and Config.SLOT_KEYS) or {
    [Enum.KeyCode.One] = "Hands",
    [Enum.KeyCode.Two] = "Flash",
    [Enum.KeyCode.Three] = "Smoke",
}

local function remote(name)
    return Remotes and find(Remotes, name, 5)
end

local VisEvent = remote("Vis")
local WhiffEvent = remote("Whiff")
local PointsEvent = remote("Points")
local CooldownEvent = remote("Cooldown")
local SubmitCode = remote("SubmitCode")
local RespawnEvent = remote("Respawn")

local CTUI = find(PlayerGui, "CTUI", 20)
local InputHook = CTUI and find(CTUI, "InputHook", 5)

----------------------------------------------------------------
-- State
----------------------------------------------------------------
-- Stats is the counters the Stats tab renders; Bot is the "what is it doing
-- right now" registry the Main tab renders.
local Stats = { submitted = 0, deletes = 0, whiffs = 0, throws = 0, respawns = 0, visUpdates = 0, points = 0 }
local Bot = { last = {} }

local function botActivity(key, text)
    Bot.last[key] = { text = text, t = os.clock() }
end

-- VisMap[pidString] = { code, at, used, submittedAt }
-- `at` is refreshed every time the server still reports that code, so a live
-- entry never ages out; `used` latches after a submit so a code is not fired
-- twice off the same visibility.
local VisMap = {}
local Lockout = { untilAt = 0 } -- submissions paused until this clock time
local SlotReady = {} -- [slot] = clock time the game will let us throw again
local VisSeq = 0 -- bumped on every Vis payload; the per-refresh cap keys off it
local Burst = { seq = -1, sent = 0 }

-- RespawnState tracks one death at a time: `firedAt` is when we last asked the
-- server to respawn us, `counted` keeps a death from being counted twice when a
-- retry is needed.
local RespawnState = { firedAt = 0, counted = false }

local function lastSubmitted()
    return Burst.lastCode, Burst.lastPid
end

----------------------------------------------------------------
-- Server signals
----------------------------------------------------------------
if VisEvent then
    track(VisEvent.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        VisSeq = VisSeq + 1
        Stats.visUpdates = Stats.visUpdates + 1
        local now = os.clock()
        for pid, code in pairs(payload) do
            code = tostring(code)
            if code:match("^%d%d%d%d$") then
                local key = tostring(pid)
                local row = VisMap[key]
                if row and row.code == code then
                    row.at = now -- same code still visible: keep its submitted latch
                else
                    VisMap[key] = { code = code, at = now, used = false }
                end
            end
        end
    end))
end

if WhiffEvent then
    track(WhiffEvent.OnClientEvent:Connect(function()
        Stats.whiffs = Stats.whiffs + 1
        local margin = tonumber(EZ.Flags.WhiffMargin) or 0.3
        Lockout.untilAt = os.clock() + WHIFF_LOCKOUT + margin
        local code = lastSubmitted()
        if log then
            log:Warn(string.format("Whiff on %s — submissions paused for %.1fs",
                tostring(code or "?"), WHIFF_LOCKOUT + margin))
        end
        botActivity("delete", string.format("whiffed on %s — pausing %.1fs", tostring(code or "?"), WHIFF_LOCKOUT + margin))
    end))
end

-- The server awards a Points payload per successful action; key "delete" is a
-- delete we caused, so it is a precise counter (the client's own DbgStats
-- "deletes=" field agrees with it).
if PointsEvent then
    track(PointsEvent.OnClientEvent:Connect(function(p)
        if type(p) ~= "table" then return end
        if type(p.points) == "number" then Stats.points = Stats.points + p.points end
        if p.key == "delete" then
            Stats.deletes = Stats.deletes + 1
            local code, pid = lastSubmitted()
            if log then log:Success(string.format("Deleted %s (pid %s)", tostring(code or "?"), tostring(pid or "?"))) end
            botActivity("delete", string.format("deleted %s", tostring(code or "?")))
        end
    end))
end

-- Mirror the game's own per-slot throw cooldowns instead of guessing at them.
if CooldownEvent then
    track(CooldownEvent.OnClientEvent:Connect(function(p)
        if type(p) ~= "table" then return end
        local now = os.clock()
        for slot, duration in pairs(p) do
            SlotReady[tostring(slot)] = now + (tonumber(duration) or 0)
        end
    end))
end

----------------------------------------------------------------
-- Game state readers
----------------------------------------------------------------
local function phase()
    return (State and State:GetAttribute("Phase")) or ""
end

local function inMatch()
    return phase() == "Playing"
end

local function inTutorial()
    return lp:GetAttribute("InTutorial") == true
end

local function myTeam()
    local char = lp.Character
    return (char and char:GetAttribute("Team")) or lp:GetAttribute("Team")
end

local function alive()
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return hum ~= nil and hum.Health > 0
end

-- The death card only exists while you are dead: PlayerGui.CTUI.CTUI_Root.Death
-- gains a Group.Respawn subtree on death and loses it again on respawn, so a
-- missing node means "not dead / nothing to do" rather than "not ready".
--
-- The game's Death surface reveals readiness in `_becomeReady()`:
--     u37.fill.Visible = false; u37.cd.Visible = false; u37.go.Visible = true
-- so Countdown.Visible == false and Go.Visible == true both mean the countdown
-- has finished. Observed live while dead: Countdown=true Go=false Fill=true
-- (N counting 5→1), then Countdown=false Go=true Fill=false once ready.
local function respawnReady()
    local death = PlayerGui:FindFirstChild("CTUI")
    death = death and death:FindFirstChild("CTUI_Root")
    death = death and death:FindFirstChild("Death")
    local group = death and death:FindFirstChild("Group")
    local respawn = group and group:FindFirstChild("Respawn")
    local face = respawn and respawn:FindFirstChild("Face")
    if not face then return false end
    local go = face:FindFirstChild("Go")
    if go then return go.Visible == true end
    local countdown = face:FindFirstChild("Countdown")
    if countdown then return countdown.Visible == false end
    return false
end

-- Master gate every feature runs behind.
local function active(flag)
    return EZ.Flags.MasterEnable == true and EZ.Flags[flag] == true
end

-- Enemies live directly under workspace and (sometimes) under workspace.Bots.
-- A model counts as an enemy when it carries a PID attribute and its Team
-- differs from ours; dead ones are dropped so aiming never targets a corpse.
local function enemies()
    local mine = myTeam()
    local list = {}
    local function scan(root)
        if not root then return end
        for _, model in ipairs(root:GetChildren()) do
            if model:IsA("Model") and model:GetAttribute("PID") ~= nil
                and model:GetAttribute("Team") ~= mine then
                local hum = model:FindFirstChildOfClass("Humanoid")
                local part = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso")
                if hum and hum.Health > 0 and part then
                    list[#list + 1] = { model = model, part = part, pid = tostring(model:GetAttribute("PID")) }
                end
            end
        end
    end
    scan(workspace)
    scan(workspace:FindFirstChild("Bots"))
    return list
end

----------------------------------------------------------------
-- Window
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "Counter Type Autoplay",
    SubTitle = "kizzyskrim",
    ToggleKey = Enum.KeyCode.RightShift,
    Width = 680,
    Height = 480,
})

QuickBar:Bind(EZ, Window)
NotifHistory:Bind(EZ, Window)

local TabMain = Window:AddTab("Main", "crosshair")
local TabDelete = Window:AddTab("Delete", "delete")
local TabThrow = Window:AddTab("Throw", "bomb")
local TabStats = Window:AddTab("Stats", "chart-line")

----------------------------------------------------------------
-- MAIN tab
----------------------------------------------------------------
local secStatus = TabMain:AddSection("Status")
local activityP = secStatus:AddParagraph({ Title = "Currently", Content = "starting up..." })
local stateP = secStatus:AddParagraph({ Title = "Match State", Content = "-" })

local secCtl = TabMain:AddSection("Control")
local masterHandle
masterHandle = secCtl:AddToggle("MasterEnable", {
    Text = "MASTER ENABLE (nothing runs while this is off)",
    Default = false,
    Callback = function(v)
        if log then log:Info("Master " .. (v and "ENABLED" or "disabled")) end
        if not v then
            Lockout.untilAt = 0
        end
    end,
})
secCtl:AddKeybind("KeyMaster", {
    Text = "Master enable",
    Default = Enum.KeyCode.F,
    Mode = "Toggle",
    Callback = function(isActive)
        -- write through the handle so the UI toggle moves too
        masterHandle:Set(isActive)
    end,
})

-- Anti-AFK: the game's own idle handling would drop us from a match we are
-- not touching. Same getconnections approach as the rest of this project.
local idledConnections = {}
local function setAntiAFK(enabled)
    if enabled then
        for _, conn in ipairs(getconnections(lp.Idled)) do
            if conn.Enabled then
                conn:Disable()
                table.insert(idledConnections, conn)
            end
        end
        if log then log:Info("Anti-AFK: idle kick blocked (" .. #idledConnections .. " handler(s))") end
    else
        for _, conn in ipairs(idledConnections) do
            pcall(function() conn:Enable() end)
        end
        idledConnections = {}
        if log then log:Info("Anti-AFK: disabled — Roblox idle kick restored") end
    end
end
secCtl:AddToggle("AntiAFK", {
    Text = "Anti-AFK (never kicked for idling)",
    Default = true,
    Callback = setAntiAFK,
})
if EZ.Flags.AntiAFK then setAntiAFK(true) end

secCtl:AddButton({
    Text = "Panic (kill every feature, keep the window)",
    Callback = function() EZ:SetPanic(true) end,
})
secCtl:AddButton({
    Text = "Unload",
    Callback = function() EZ:Destroy() end,
})

local secRespawn = TabMain:AddSection("Auto-Respawn")
secRespawn:AddToggle("AutoRespawn", {
    Text = "Auto Respawn (press RESPAWN for you)",
    Default = false,
    Tooltip = "Once the death card's countdown finishes it fires Remotes.Respawn — the same server call the game's own RESPAWN button makes. Fires once per death, then waits for you to actually be back before arming again.",
    Callback = function(v)
        if log then log:Info("Auto-Respawn " .. (v and "ON" or "OFF")) end
    end,
})
secRespawn:AddSlider("RespawnRetryGap", {
    Text = "Retry gap if the first call does not take",
    Min = 0.5, Max = 10, Default = 1, Increment = 0.5, Suffix = "s",
    Tooltip = "Safety net only. The normal path fires once per death and then waits for your character to come back, so this gap is not reached unless a request is refused.",
})

----------------------------------------------------------------
-- DELETE tab
----------------------------------------------------------------
local secDel = TabDelete:AddSection("Auto-Delete")
secDel:AddToggle("AutoDelete", {
    Text = "Auto Delete (submit visible codes)",
    Default = false,
    Tooltip = "Mirrors Remotes.Vis — the server's own list of codes you can currently see — and submits them via Remotes.SubmitCode.",
    Callback = function(v)
        if log then log:Info("Auto-Delete " .. (v and "ON" or "OFF")) end
    end,
})

local secDelTune = TabDelete:AddSection("Tuning")
secDelTune:AddSlider("SubmitInterval", {
    Text = "Submit interval",
    Min = 0.1, Max = 2, Default = 0.35, Increment = 0.05, Suffix = "s",
    Tooltip = "Gap between submissions. The server accepts roughly 6 per second (Config.SUBMIT_RATE); 0.35s stays comfortably under that.",
})
secDelTune:AddSlider("CodesPerRefresh", {
    Text = "Max codes per Vis refresh",
    Min = 1, Max = 10, Default = 2, Increment = 1,
    Tooltip = "Hard cap on how many codes are consumed from a single Vis broadcast, so one refresh can never dump your whole list at once.",
})
secDelTune:AddSlider("VisFreshness", {
    Text = "Code freshness",
    Min = 0.5, Max = 20, Default = 5, Increment = 0.5, Suffix = "s",
    Tooltip = "A tracked code is dropped once the server has not re-reported it for this long. Vis fires several times a second, so a live enemy's code stays fresh.",
})
secDelTune:AddSlider("WhiffMargin", {
    Text = "Extra pause after a whiff",
    Min = 0, Max = 3, Default = 0.3, Increment = 0.1, Suffix = "s",
    Tooltip = "Added on top of the game's own 2.4s lockout before submissions resume.",
})
secDelTune:AddSlider("RetryAfter", {
    Text = "Re-submit a used code after",
    Min = 0, Max = 30, Default = 0, Increment = 1, Suffix = "s",
    Tooltip = "0 = never re-submit (safest, matches the game's own one-code-per-plate rule). Raise it to retry codes that did not land, e.g. while a target is still inside the 3s spawn immunity.",
})

local secDelFilters = TabDelete:AddSection("Filters")
secDelFilters:AddToggle("StrictTargets", {
    Text = "Only submit codes for enemies loaded around you",
    Default = true,
    Tooltip = "Skips Vis entries whose PID has no live model in workspace, which is what produces most whiffs. Turn off to trust the server's list verbatim.",
})
secDelFilters:AddToggle("LogSubmits", {
    Text = "Log every submission",
    Default = false,
    Tooltip = "Off by default — at 0.35s intervals this floods the log. Deletes and whiffs are always logged.",
})

----------------------------------------------------------------
-- THROW tab
----------------------------------------------------------------
local secThrow = TabThrow:AddSection("Auto-Throw")
secThrow:AddToggle("AutoThrow", {
    Text = "Auto Throw (aim at nearest enemy and release)",
    Default = false,
    Tooltip = "Points the camera at the nearest live enemy and drives a real charge + release through the game's InputHook, so cooldowns and the HUD stay in sync.",
    Callback = function(v)
        if log then log:Info("Auto-Throw " .. (v and "ON" or "OFF")) end
    end,
})
secThrow:AddDropdown("ThrowSlot", {
    Text = "Item to throw",
    Values = { "Flash", "Smoke" },
    Default = "Flash",
})
secThrow:AddToggle("AutoEquipSlot", {
    Text = "Equip the slot first",
    Default = true,
    Tooltip = "Sends the slot key (2 = Flash, 3 = Smoke) through InputHook. The client refuses to charge while 'Hands' is equipped, so this is what makes the throw actually happen.",
})

local secThrowTune = TabThrow:AddSection("Tuning")
secThrowTune:AddSlider("ThrowCharge", {
    Text = "Charge duration",
    Min = 0.1, Max = 1.5, Default = 0.75, Increment = 0.05, Suffix = "s",
    Tooltip = "How long the mouse is held. The game's own Config.CHARGE_TIME is 0.7s; charging past it does not add power. Longer charge = further throw.",
})
secThrowTune:AddSlider("ThrowRange", {
    Text = "Only throw at enemies within",
    Min = 10, Max = 150, Default = 60, Increment = 5, Suffix = " studs",
})
secThrowTune:AddSlider("ThrowCooldown", {
    Text = "Minimum gap between throws",
    Min = 5, Max = 60, Default = 21, Increment = 1, Suffix = "s",
    Tooltip = "Local floor on top of the game's own cooldown broadcast (Config.COOLDOWN is 20s per slot).",
})

----------------------------------------------------------------
-- STATS tab
----------------------------------------------------------------
local secLog = TabStats:AddSection("Activity")
log = secLog:AddLog({ Height = 120, MaxLines = 60 })
log:Info("Counter Type Autoplay loaded")

local secCounters = TabStats:AddSection("Counters")
local countersP = secCounters:AddParagraph({ Title = "Session", Content = "-" })
local visP = secCounters:AddParagraph({ Title = "Visible Codes", Content = "waiting for a Vis broadcast..." })
local pendingP = secCounters:AddParagraph({ Title = "Submission Gate", Content = "-" })

----------------------------------------------------------------
-- Auto-delete loop
----------------------------------------------------------------
-- One submission per tick: the tick rate is the submit interval, so the
-- server's rate limit can never be tripped by a burst.
task.spawn(function()
    while RUNNING do
        local interval = math.clamp(tonumber(EZ.Flags.SubmitInterval) or 0.35, 0.05, 5)

        if active("AutoDelete") then
            local now = os.clock()
            if not inMatch() then
                botActivity("delete", "not in a live match (Phase = " .. (phase() == "" and "?" or phase()) .. ")")
            elseif inTutorial() then
                botActivity("delete", "paused during the tutorial")
            elseif not alive() then
                botActivity("delete", "waiting to respawn")
            elseif now < Lockout.untilAt then
                botActivity("delete", string.format("lockout — %.1fs left", Lockout.untilAt - now))
            else
                if Burst.seq ~= VisSeq then
                    Burst.seq = VisSeq
                    Burst.sent = 0
                end

                local freshness = math.clamp(tonumber(EZ.Flags.VisFreshness) or 5, 0.5, 60)
                local cap = math.floor(math.clamp(tonumber(EZ.Flags.CodesPerRefresh) or 2, 1, 10))
                local retryAfter = math.clamp(tonumber(EZ.Flags.RetryAfter) or 0, 0, 120)

                -- A model-backed PID set keeps submissions to enemies the
                -- client can actually see; stale Vis entries are the main
                -- source of whiffs.
                local live
                if EZ.Flags.StrictTargets then
                    live = {}
                    for _, enemy in ipairs(enemies()) do live[enemy.pid] = true end
                end

                local stale, candidates = {}, {}
                for pid, row in pairs(VisMap) do
                    if now - row.at > freshness then
                        stale[#stale + 1] = pid
                    else
                        local eligible = not row.used
                            or (retryAfter > 0 and row.submittedAt and now - row.submittedAt >= retryAfter)
                        if eligible and (live == nil or live[pid]) then
                            candidates[#candidates + 1] = { pid = pid, row = row }
                        end
                    end
                end
                for _, pid in ipairs(stale) do VisMap[pid] = nil end
                table.sort(candidates, function(a, b) return a.row.at > b.row.at end) -- newest first

                if Burst.sent >= cap then
                    botActivity("delete", string.format("per-refresh cap reached (%d) — waiting for the next Vis", cap))
                elseif #candidates == 0 then
                    local tracked = 0
                    for _ in pairs(VisMap) do tracked = tracked + 1 end
                    botActivity("delete", string.format("no submit-ready code (%d tracked, %d live enemies)", tracked, #enemies()))
                else
                    local pick = candidates[1]
                    pick.row.used = true
                    pick.row.submittedAt = now
                    Burst.sent = Burst.sent + 1
                    Burst.lastCode, Burst.lastPid = pick.row.code, pick.pid

                    if SubmitCode then
                        pcall(function() SubmitCode:FireServer(pick.row.code) end)
                        Stats.submitted = Stats.submitted + 1
                        if EZ.Flags.LogSubmits and log then
                            log:Info(string.format("Submitted %s (pid %s)", pick.row.code, pick.pid))
                        end
                        botActivity("delete", string.format("submitted %s (pid %s)", pick.row.code, pick.pid))
                    end
                end
            end
        end

        task.wait(interval)
    end
end)

----------------------------------------------------------------
-- Auto-throw loop
----------------------------------------------------------------
local AIM_BIND = "CT_AUTOPLAY_AIM"

-- The game reads the throw direction straight off the camera at release time
-- (releaseThrow -> UseEquipment:FireServer(slot, camera.LookVector, charge)).
-- Binding above the camera's own render priority is what keeps the aim pointed
-- at the target for the whole charge instead of one frame.
local function aimWhile(getPos, fn)
    local bound = pcall(function()
        RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 10, function()
            local cam = workspace.CurrentCamera
            if not cam then return end
            local pos = getPos()
            if pos then cam.CFrame = CFrame.lookAt(cam.CFrame.Position, pos) end
        end)
    end)
    local ok, err = pcall(fn)
    if bound then pcall(function() RunService:UnbindFromRenderStep(AIM_BIND) end) end
    return ok, err
end

local function slotKey(slot)
    for key, name in pairs(SLOT_KEYS) do
        if name == slot then return key end
    end
    return slot == "Smoke" and Enum.KeyCode.Three or Enum.KeyCode.Two
end

local nextThrowAt = 0

task.spawn(function()
    while RUNNING do
        if active("AutoThrow") then
            local now = os.clock()
            local slot = EZ.Flags.ThrowSlot == "Smoke" and "Smoke" or "Flash"

            if not InputHook then
                botActivity("throw", "InputHook not found in PlayerGui.CTUI")
            elseif not inMatch() then
                botActivity("throw", "not in a live match")
            elseif inTutorial() then
                botActivity("throw", "paused during the tutorial")
            elseif not alive() then
                botActivity("throw", "waiting to respawn")
            elseif now < nextThrowAt then
                botActivity("throw", string.format("gap — %.1fs left", nextThrowAt - now))
            elseif now < (SlotReady[slot] or 0) then
                botActivity("throw", string.format("%s on cooldown — %.1fs left", slot, (SlotReady[slot] or 0) - now))
            else
                local maxRange = tonumber(EZ.Flags.ThrowRange) or 60
                local char = lp.Character
                local myRoot = char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso"))
                local target, best = nil, math.huge
                if myRoot then
                    for _, enemy in ipairs(enemies()) do
                        local dist = (enemy.part.Position - myRoot.Position).Magnitude
                        if dist <= maxRange and dist < best then
                            target, best = enemy, dist
                        end
                    end
                end

                if not target then
                    botActivity("throw", string.format("no live enemy within %d studs", maxRange))
                else
                    if EZ.Flags.AutoEquipSlot then
                        pcall(function() InputHook:Invoke(Enum.UserInputType.Keyboard, slotKey(slot), false) end)
                        task.wait(0.15)
                    end

                    local charge = math.clamp(tonumber(EZ.Flags.ThrowCharge) or CHARGE_TIME, 0.05, 2)
                    local fired = aimWhile(function()
                        return target.part.Position
                    end, function()
                        InputHook:Invoke(Enum.UserInputType.MouseButton1, nil, false)
                        task.wait(charge)
                        InputHook:Invoke(Enum.UserInputType.MouseButton1, nil, false, true)
                    end)

                    Stats.throws = Stats.throws + 1
                    -- Local floor so a silent refusal can never turn into a spam
                    -- loop; the server's own Cooldown broadcast raises this to
                    -- the real per-slot cooldown when it arrives.
                    nextThrowAt = os.clock() + math.clamp(tonumber(EZ.Flags.ThrowCooldown) or 21, 1, 120)
                    SlotReady[slot] = math.max(SlotReady[slot] or 0, nextThrowAt)

                    if log then
                        log:Info(string.format("Threw %s at %s (%.0f studs, charge %.2fs)%s",
                            slot, target.model.Name, best, charge, fired and "" or " — call errored"))
                    end
                    botActivity("throw", string.format("threw %s at %s (%.0f studs)", slot, target.model.Name, best))
                    task.wait(1)
                end
            end
        end
        task.wait(0.5)
    end
end)

----------------------------------------------------------------
-- Auto-respawn loop
----------------------------------------------------------------
-- Fire-once-then-wait: a request goes out the moment the death card reports
-- ready, and nothing else is sent until the character is actually alive again.
-- The retry gap only matters if the server ignored the first request.
task.spawn(function()
    while RUNNING do
        if active("AutoRespawn") then
            if alive() then
                if RespawnState.firedAt > 0 and log then
                    log:Success("Respawned — back in the round")
                end
                RespawnState.firedAt = 0
                RespawnState.counted = false
                botActivity("respawn", "alive")
            elseif not inMatch() then
                botActivity("respawn", "dead outside a live match (Phase = " .. (phase() == "" and "?" or phase()) .. ")")
            elseif inTutorial() then
                botActivity("respawn", "paused during the tutorial")
            elseif not respawnReady() then
                botActivity("respawn", "dead — waiting for the countdown")
            else
                local gap = math.clamp(tonumber(EZ.Flags.RespawnRetryGap) or 1, 0.5, 60)
                local first = RespawnState.firedAt == 0
                if first or (os.clock() - RespawnState.firedAt >= gap) then
                    RespawnState.firedAt = os.clock()
                    if RespawnEvent then
                        pcall(function() RespawnEvent:FireServer() end)
                        if not RespawnState.counted then
                            RespawnState.counted = true
                            Stats.respawns = Stats.respawns + 1
                        end
                        if log then
                            if first then
                                log:Info("Dead — countdown finished, fired Respawn")
                            else
                                log:Warn(string.format("Respawn not taken after %.1fs — retrying", gap))
                            end
                        end
                        botActivity("respawn", first and "fired Respawn (countdown finished)" or "retrying Respawn")
                    else
                        botActivity("respawn", "Remotes.Respawn not found")
                    end
                end
            end
        end
        task.wait(0.25)
    end
end)

----------------------------------------------------------------
-- Live renderers
----------------------------------------------------------------
task.spawn(function()
    while RUNNING do
        pcall(function()
            local best, bestT, bestKey = nil, 0, nil
            for key, entry in pairs(Bot.last) do
                if entry.t > bestT then best, bestT, bestKey = entry, entry.t, key end
            end
            if best then
                activityP:Set(best.text .. "\n(" .. math.max(0, math.floor(os.clock() - best.t)) .. "s ago — " .. bestKey .. ")")
            else
                activityP:Set("idle — nothing enabled")
            end

            local tracked = 0
            for _ in pairs(VisMap) do tracked = tracked + 1 end
            local lockLeft = math.max(0, Lockout.untilAt - os.clock())
            stateP:Set(string.format(
                "Phase: %s   Time left: %s\nYour team: %s   Alive: %s   In tutorial: %s\nLive enemies nearby: %d\nTracked codes: %d   Vis updates: %d   Last Vis: %s\nSubmission gate: %s",
                phase() == "" and "?" or phase(),
                tostring(State and State:GetAttribute("TimeLeft") or "?"),
                tostring(myTeam() or "?"), tostring(alive()), tostring(inTutorial()),
                #enemies(), tracked, Stats.visUpdates,
                Stats.visUpdates > 0 and "seen" or "never",
                lockLeft > 0 and string.format("LOCKED OUT %.1fs (whiff)", lockLeft)
                    or (active("AutoDelete") and "open" or "master/feature off")
            ))

            countersP:Set(string.format(
                "Submitted: %d\nDeletes: %d\nWhiffs: %d\nThrows: %d\nRespawns: %d\nPoints from deletes: %d",
                Stats.submitted, Stats.deletes, Stats.whiffs, Stats.throws, Stats.respawns, Stats.points))

            local rows = {}
            for pid, row in pairs(VisMap) do
                rows[#rows + 1] = { pid = pid, row = row }
            end
            table.sort(rows, function(a, b) return a.row.at > b.row.at end)
            if #rows == 0 then
                visP:Set("no codes tracked")
            else
                local lines = {}
                for i = 1, math.min(#rows, 8) do
                    local entry = rows[i]
                    lines[#lines + 1] = string.format("%s  pid %s  %s  %.1fs ago",
                        entry.row.code, entry.pid,
                        entry.row.used and "submitted" or "pending",
                        os.clock() - entry.row.at)
                end
                if #rows > 8 then lines[#lines + 1] = string.format("...and %d more", #rows - 8) end
                visP:Set(table.concat(lines, "\n"))
            end

            pendingP:Set(string.format(
                "Vis refresh #%d — %d/%d submitted this refresh\nMaster: %s   Auto-Delete: %s   Auto-Throw: %s   Auto-Respawn: %s",
                VisSeq, Burst.sent, math.floor(tonumber(EZ.Flags.CodesPerRefresh) or 2),
                tostring(EZ.Flags.MasterEnable == true), tostring(EZ.Flags.AutoDelete == true),
                tostring(EZ.Flags.AutoThrow == true), tostring(EZ.Flags.AutoRespawn == true)))
        end)
        task.wait(0.5)
    end
end)

----------------------------------------------------------------
-- Final wiring (AFTER every element exists)
----------------------------------------------------------------
pcall(function()
    QuickBar:Pin("MasterEnable", { Icon = "power" })
    QuickBar:Pin("AutoDelete", { Icon = "delete" })
    QuickBar:Pin("AutoThrow", { Icon = "bomb" })
    QuickBar:Pin("AutoRespawn", { Icon = "rotate-ccw" })
    QuickBar:PinButton("Panic Off", { Icon = "octagon-x", Callback = function()
        EZ:SetPanic(false)
    end })
end)

pcall(function() SaveManager:LoadAutoloadConfig() end)

if log then
    log:Info(string.format("Remotes: %s | InputHook: %s | Config: %s",
        Remotes and "ok" or "MISSING", InputHook and "ok" or "MISSING", Config and "ok" or "defaults"))
end
if not Remotes then
    EZ:Notify({ Title = "Counter Type Autoplay", Content = "ReplicatedStorage.CT.Remotes not found — are you in Counter Type?", Duration = 8, Type = "warning" })
end

----------------------------------------------------------------
-- Shutdown
----------------------------------------------------------------
local function destroy()
    RUNNING = false
    for _, conn in ipairs(Conns) do
        pcall(function() conn:Disconnect() end)
    end
    Conns = {}
    pcall(function() RunService:UnbindFromRenderStep(AIM_BIND) end)
    setAntiAFK(false)
end

EZ:OnDestroy(function()
    destroy()
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHistory:Destroy() end)
end)

getgenv().__CT_AUTOPLAY_LOADED = true
getgenv().__CT_AUTOPLAY_EZ = EZ
getgenv().__CT_AUTOPLAY_DESTROY = function() pcall(function() EZ:Destroy() end) end
-- live handles for inspection from another script/console
getgenv().__CT_AUTOPLAY_STATE = {
    Stats = Stats,
    VisMap = VisMap,
    Lockout = Lockout,
    SlotReady = SlotReady,
    RespawnState = RespawnState,
    enemies = enemies,
    phase = phase,
    alive = alive,
    respawnReady = respawnReady,
}
