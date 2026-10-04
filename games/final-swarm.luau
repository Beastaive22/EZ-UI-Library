-- Final Swarm autofarm — EZ Hub game module (see loader.lua).
-- Game guard first: game.GameId is the universe id (9551044479), so every
-- place in Final Swarm matches — the lobby (99521272836282 "Final Swarm
-- [Atlantis]") and the round place (79787558257549 "Game", reached through
-- the queue). Anywhere else this exits before touching anything, even if
-- someone runs the file directly.
if game.GameId ~= 9551044479 then return end

--[[
    Final Swarm Autofarm
    Built on EZ-UI-Library (https://github.com/Beastaive22/EZ-UI-Library)
    Executor: Potassium / sUNC

    Runs the whole loop unattended: pick a world and difficulty (or the best
    one the account can enter), queue through the game's own WorldSelection
    networker, survive the run, answer every upgrade offer with a
    synergy-aware pick (damage and attack speed first), claim the reward at
    the round-end screen and queue again. A place change destroys the script,
    so arming queues the hub loader via queue_on_teleport and a small intent
    file carries the on/off state across the hop.

    Everything goes through the game's own client surfaces, verified live
    before this module was written (full recon in the Final Swarm note):

      queue        Networker.client.new("WorldSelection") then
                   fire SetRunMode/SetWorld/SetDifficulty/SetChallenges and
                   fetch("EnterQueue") — the exact calls the world-select
                   frame makes when Play is pressed.
      upgrades     PlayerGui.Frames.Upgrades.Holder.Selection1..5; the card
                   handler is bound to MouseButton1Up, and the underlying
                   call is GameServiceClient:UpgradeSelected(index, count).
      waves        HUD.Top.SkipWave -> EnemyService fire("RequestSkipVote");
                   FinalSwarmData.Skip caps them (5 waves, 5 s cooldown).
      boss         workspace.Map.BossPortal["PortalPrompt"] (ProximityPrompt).
      end of run   PlayerGui.Frames.RoundEnd.Buttons.ClaimReward.
      run stats    require(Shared.Modules.Core.PlayerRunData):get(LocalPlayer).

    Movement is deliberately dull: the in-round anti-cheat watches humanoid
    properties and states (WalkSpeed, JumpPower, JumpHeight, HipHeight,
    PlatformStand, Physics/Flying states, body movers) and self-reports them.
    This module never writes any of those. It moves the HumanoidRootPart by
    CFrame at a configurable speed budget, with optional fly and noclip, and
    it shadows the anti-cheat networker's own fire method so a violation
    would be counted locally instead of sent — that counter is the tuning
    canary: if it moves, the movement is too hot.

    While the master toggle is off the script builds the window and idles.
    getgenv().FinalSwarmRearm overrides the queued re-arm code so an edited
    file can be tested before it is pushed.

    Toggle UI: RightShift
]]

local getgenv = getgenv

print("[FINALSWARM] starting")

-- A previous injection in this place owns connections, a window and possibly
-- a patched networker. Stop it, but keep the intent file untouched: this
-- instance is about to read it.
local function previousInstance()
    local g = getgenv and getgenv()
    for _ = 1, 64 do
        if not (g and g.__FINALSWARM_FARM_DESTROY) then break end
        local kill = g.__FINALSWARM_FARM_DESTROY
        g.__FINALSWARM_FARM_DESTROY = nil
        g.__FINALSWARM_FARM = nil
        pcall(kill, true)
    end
end
previousInstance()

-- Singleton guard: queue_on_teleport entries accumulate across hops, so a
-- place change can run this module more than once. Each start takes a
-- generation number and any run that is no longer the newest stops itself.
local MY_GEN
do
    local g = getgenv and getgenv()
    if g then
        MY_GEN = (tonumber(g.__FINALSWARM_GEN) or 0) + 1
        g.__FINALSWARM_GEN = MY_GEN
    end
end

local function superseded()
    local g = getgenv and getgenv()
    return g ~= nil and MY_GEN ~= nil and tonumber(g.__FINALSWARM_GEN) ~= MY_GEN
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
SaveManager:Bind(EZ, "FinalSwarmConfigs")
ThemeManager:Bind(EZ, { File = "FinalSwarm_Theme.txt" })
ThemeManager:LoadSaved()
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

-- Another copy took a newer generation while this one was fetching the
-- library: it owns the farm now, so this one steps aside first.
if superseded() then
    pcall(function() EZ:Destroy() end)
    return
end

----------------------------------------------------------------
-- Runtime
----------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- queue_on_teleport runs this code the moment the next place loads, which is
-- before the player object exists. Wait for LocalPlayer, bounded.
local LocalPlayer
for _ = 1, 100 do
    LocalPlayer = Players.LocalPlayer
    if LocalPlayer then break end
    task.wait(0.1)
end
if not LocalPlayer then
    warn("[FINALSWARM] LocalPlayer never appeared — aborting")
    pcall(function() EZ:Destroy() end)
    return
end

local RUNNING = true
local Conns = {}

local function track(conn)
    if conn then table.insert(Conns, conn) end
    return conn
end

-- WaitForChild-first lookup that never blocks forever: a renamed instance
-- must degrade to nil, not hang the module.
local function find(parent, name, timeout)
    if not parent then return nil end
    local direct = parent:FindFirstChild(name)
    if direct then return direct end
    local ok, child = pcall(function() return parent:WaitForChild(name, timeout or 5) end)
    if ok then return child end
    return nil
end

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local S = {
    armed = false,
    status = "Idle",
    placeKind = nil,       -- "lobby" | "round" | nil (not decided yet)
    lastTick = 0,
}

local stats = {
    loops = 0,
    claims = 0,
    skips = 0,
    picks = 0,
    acViolations = 0,
    suppressed = 0,
    lastPick = "-",
}

-- Forward declarations: closures created before a function is assigned still
-- capture the local, which keeps declaration order honest for the CI check.
local masterToggle, statusLabel, statsPara, logConsole
local setArmed

local function flag(id, default)
    local value = EZ and EZ.Flags and EZ.Flags[id]
    if value == nil then return default end
    return value
end

local function note(message, level)
    local text = tostring(message)
    if logConsole then
        pcall(function() logConsole:AddText(text, level) end)
    end
    print("[FINALSWARM] " .. text)
end

local function setStatus(text)
    S.status = tostring(text)
    if statusLabel then
        pcall(function() statusLabel:Set(S.status) end)
    end
end

----------------------------------------------------------------
-- Network layer
----------------------------------------------------------------
-- The game ships leifstout's networker as a Wally package, and it ships it
-- more than once (0.2.1 for DataService, 0.3.0 in the round place, 0.3.1 in
-- the lobby). A tag only exists in the version that owns it, so the module
-- indexes every version it can find and asks each one for the tag before
-- building a client from it.
--
-- NetworkerClient.new waits on WaitForChild for the tag's folder, which would
-- hang forever on a renamed tag. The folder is therefore checked first, with
-- a short timeout, and a missing tag returns nil so a game update degrades to
-- safe mode instead of freezing the loop.
local netCache = {}
local netPackages = nil
local warnedTags = {}

local function collectNetPackages()
    local out = {}
    local packages = find(ReplicatedStorage, "Packages", 5)
    if not packages then return out end
    local index = packages:FindFirstChild("_Index")
    if not index then return out end
    for _, child in ipairs(index:GetChildren()) do
        if child.Name:match("^leifstout_networker@") then
            local pkg = child:FindFirstChild("networker")
            local remotes = pkg and pkg:FindFirstChild("_remotes")
            if remotes then
                local ok, mod = pcall(require, pkg)
                if ok and type(mod) == "table" and mod.client then
                    table.insert(out, { module = mod, remotes = remotes })
                end
            end
        end
    end
    return out
end

local function net(tag)
    if type(tag) ~= "string" or tag == "" then return nil end
    if netCache[tag] then return netCache[tag] end
    if not netPackages then netPackages = collectNetPackages() end

    for _, entry in ipairs(netPackages) do
        local folder = entry.remotes:FindFirstChild(tag)
        if not folder then
            local okWait, waited = pcall(function() return entry.remotes:WaitForChild(tag, 0.5) end)
            if okWait then folder = waited end
        end
        if folder then
            -- Permissive handler: server->client events the module does not
            -- care about must not assert.
            local handler = setmetatable({}, { __index = function() return function() end end })
            local ok, client = pcall(function() return entry.module.client.new(tag, handler) end)
            if ok and client then
                netCache[tag] = client
                return client
            end
        end
    end

    if not warnedTags[tag] then
        warnedTags[tag] = true
        note("networker tag unavailable: " .. tag, "Warn")
    end
    return nil
end

local function netRemotesExists(tag)
    if not netPackages then netPackages = collectNetPackages() end
    for _, entry in ipairs(netPackages) do
        if entry.remotes:FindFirstChild(tag) then return true end
    end
    return false
end

-- Which tags mean which kind of place. The round place has WeaponService and
-- FinalSwarmService; the lobby has WorldSelection and QueueService.
local TAGS_LOBBY = { "WorldSelection", "QueueService", "Settings", "CodesService", "Store", "Quests" }
local TAGS_ROUND = { "GameService", "EnemyService", "WeaponService", "AntiCheat", "FinalSwarmService", "RoundService" }

local function netDebug()
    local count, names = 0, {}
    for tag in pairs(netCache) do
        count = count + 1
        table.insert(names, tag)
    end
    table.sort(names)
    return string.format("netPkgs=%d netTags=%d[%s]", netPackages and #netPackages or 0, count, table.concat(names, ","))
end

----------------------------------------------------------------
-- Surviving a teleport
----------------------------------------------------------------
local REARM_CODE = [[loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/loader.lua"))()]]

local function rearmAfterTeleport()
    local code = REARM_CODE
    local g = getgenv and getgenv()
    local override = g and g.FinalSwarmRearm
    if type(override) == "string" and #override > 0 then code = override end

    local fn
    if type(queue_on_teleport) == "function" then
        fn = queue_on_teleport
    elseif type(queueonteleport) == "function" then
        fn = queueonteleport
    end
    if not fn then return false end
    return (pcall(fn, code))
end

-- `ok` separates "the file says off" from "the file could not be read": with
-- both reading as false, one transient failure would look like a real "off"
-- and the loop would not resume after a teleport.
local INTENT_FILE = "final-swarm-intent.txt"

local function readIntent()
    local out = { enabled = false, world = nil, difficulty = nil, ok = false }
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return out end

    local okCall, exists = pcall(isfile, INTENT_FILE)
    if not okCall then return out end
    if not exists then
        out.ok = true -- no file at all is a real answer: never armed
        return out
    end

    local okRead, text = pcall(readfile, INTENT_FILE)
    if not okRead or type(text) ~= "string" then return out end
    out.ok = true
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key == "enabled" then
            out.enabled = value == "1" or value == "true"
        elseif key == "world" and value ~= "" then
            out.world = value
        elseif key == "difficulty" and value ~= "" then
            out.difficulty = value
        end
    end
    return out
end

local function writeIntent(enabled, world, difficulty)
    if type(writefile) ~= "function" then return false end
    local text = string.format(
        "enabled=%d\nworld=%s\ndifficulty=%s\n",
        enabled and 1 or 0, tostring(world or ""), tostring(difficulty or "")
    )
    return (pcall(writefile, INTENT_FILE, text))
end

----------------------------------------------------------------
-- UI
----------------------------------------------------------------
if superseded() then
    pcall(function() EZ:Destroy() end)
    return
end

local Window = EZ:CreateWindow({
    Title = "Final Swarm",
    SubTitle = "autofarm",
    ToggleKey = Enum.KeyCode.RightShift,
    ToggleIcon = "waves",
})

QuickBar:Bind(EZ, Window)
NotifHistory:Bind(EZ, Window)

local mainTab = Window:AddTab("Farm", "waves")
local masterBox = mainTab:AddLeftGroupbox("Master", "power")
local infoBox = mainTab:AddRightGroupbox("Status", "activity")

masterToggle = masterBox:AddToggle("FinalSwarmMaster", {
    Text = "Enable Auto Farm",
    Description = "Queues into a run, farms it, claims and requeues.",
    Default = false,
    Callback = function(value) setArmed(value) end,
})

statusLabel = masterBox:AddLabel("Idle")
masterBox:AddDivider("Session")
statsPara = masterBox:AddParagraph({ Title = "Counters", Content = "loops 0  |  claims 0  |  picks 0" })

infoBox:AddLabel("RightShift toggles the window.")
infoBox:AddLabel("Progress lines appear in the log below.")

local diagBox = mainTab:AddLeftGroupbox("Log", "terminal")
logConsole = diagBox:AddLog({ MaxLines = 120, Height = 200 })

local infoTab = Window:AddTab("Info", "info")
local aboutBox = infoTab:AddLeftGroupbox("How it works", "book-open")
aboutBox:AddParagraph({
    Title = "Final Swarm autofarm",
    Content = "Runs the game's own client calls: queue, upgrades, skip vote, boss portal, "
        .. "reward claim. Movement never touches the humanoid properties the in-round "
        .. "anti-cheat watches; the module counts violations it would have reported as "
        .. "a tuning canary. Arm it and it keeps the loop going across place changes.",
})

QuickBar:Pin("FinalSwarmMaster", { Icon = "waves" })
SaveManager:LoadAutoloadConfig()
EZ:SetAntiAFK(true)

----------------------------------------------------------------
-- Arm / disarm
----------------------------------------------------------------
setArmed = function(value)
    local wanted = value and true or false
    if wanted == S.armed then return end
    S.armed = wanted
    if wanted then
        writeIntent(true, nil, nil)
        if not rearmAfterTeleport() then
            note("no queue_on_teleport in this executor — the farm will stop at the next place change", "Warn")
        end
        setStatus("Armed — waiting for a place decision")
    else
        writeIntent(false, nil, nil)
        setStatus("Idle")
    end
end

----------------------------------------------------------------
-- Loop
----------------------------------------------------------------
local function stepFarm()
    -- Task 1 keeps this empty: components land in later tasks.
    S.lastTick = os.clock()
end

local function mainLoop()
    local lastStatsAt = 0
    while RUNNING do
        if superseded() then
            RUNNING = false
            S.armed = false
            for _, conn in ipairs(Conns) do
                pcall(function() conn:Disconnect() end)
            end
            Conns = {}
            pcall(function() EZ:Destroy() end)
            return
        end

        task.wait(0.05) -- 20 Hz

        if S.armed then
            local ok, err = pcall(stepFarm)
            if not ok then note("step: " .. tostring(err), "Error") end
        end

        if os.clock() - lastStatsAt > 1 and statsPara then
            lastStatsAt = os.clock()
            pcall(function()
                statsPara:Set(string.format(
                    "loops %d  |  claims %d  |  picks %d\nskips %d  |  ac %d  |  suppressed %d  |  last pick: %s",
                    stats.loops, stats.claims, stats.picks,
                    stats.skips, stats.acViolations, stats.suppressed, stats.lastPick
                ))
            end)
        end
    end
end

----------------------------------------------------------------
-- Diagnostics + teardown
----------------------------------------------------------------
local function destroy(keepIntent)
    if not RUNNING then return end
    RUNNING = false
    if S.armed then
        S.armed = false
        if not keepIntent then
            writeIntent(false, nil, nil)
        end
    end
    for _, conn in ipairs(Conns) do
        pcall(function() conn:Disconnect() end)
    end
    Conns = {}
    local g = getgenv and getgenv()
    if g and g.__FINALSWARM_FARM then
        g.__FINALSWARM_FARM = nil
    end
end

local handle = {
    status = function() return S.status, S.armed end,
    net = function(tag) return net(tag) ~= nil end,
    netDebug = netDebug,
    placeKind = function() return S.placeKind end,
    debug = function()
        return string.format(
            "status=%s armed=%s place=%s loops=%d claims=%d picks=%d skips=%d ac=%d suppressed=%d lastPick=%s",
            tostring(S.status), tostring(S.armed), tostring(S.placeKind),
            stats.loops, stats.claims, stats.picks, stats.skips,
            stats.acViolations, stats.suppressed, stats.lastPick
        )
    end,
    arm = function(value) masterToggle:Set(value and true or false) end,
    stop = function() destroy(false) end,
}

do
    local g = getgenv and getgenv()
    if g then
        g.__FINALSWARM_FARM = handle
        g.__FINALSWARM_FARM_DESTROY = destroy
    end
end

EZ:OnDestroy(function()
    -- keepIntent: a teardown is often external (another script loading the
    -- library, the loader's catalog fallback) and must not flip the farm to
    -- "off". Only the toggle and handle.stop() do that.
    pcall(destroy, true)
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHistory:Destroy() end)
end)

-- Resume across a teleport when the intent file says the farm was running.
do
    local intent = readIntent()
    if intent.ok and intent.enabled then
        note("intent file says the farm was armed — resuming")
        masterToggle:Set(true)
    else
        note("Ready - flip the master toggle to start")
    end
end

task.spawn(mainLoop)
