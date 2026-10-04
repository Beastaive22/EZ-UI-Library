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
-- Shield — anti-cheat canary + hit-report suppression
----------------------------------------------------------------
-- Two things live here, both by shadowing one method on one networker
-- instance (a raw field beats the metatable's __index, so nothing global is
-- touched and a game update cannot leave a dangling hook):
--
--   * AntiCheat.ReportViolation — the client half of the game's anti-cheat
--     reports the movement properties it clamps (walkSpeed, jumpHeight,
--     hipHeight, jumpPower, platformStand, humanoidState, bodyMover). Those
--     reports are counted locally and NOT sent. The counter is the canary:
--     if it moves, this module's movement is too hot and must be tuned.
--
--   * EnemyService.ReportImpact / CharacterService.RequestEnemyAttack — the
--     game asks the client whether an enemy attack landed. While suppression
--     says so, those calls for our own character are dropped, which is what
--     keeps a low-HP swarm from ever resolving a lethal hit.
local Shield = { active = false }
local shadowed = {}
local impactHandlers = {}
local notedViolation = {}

local function shadowFire(clientObj, methodName, onCall)
    if not clientObj then return false end
    local original = clientObj.fire
    if type(original) ~= "function" then return false end
    clientObj.fire = function(self, name, ...)
        if name == methodName then
            local handled, forward = onCall(self, name, ...)
            if handled and not forward then return nil end
        end
        return original(self, name, ...)
    end
    table.insert(shadowed, { obj = clientObj, original = original })
    return true
end

local function hpPercent()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.MaxHealth <= 0 then return 100 end
    return (humanoid.Health / humanoid.MaxHealth) * 100
end

local function suppressionActive()
    local mode = flag("FinalSwarmSuppressHits", "Below HP%")
    if mode == "Off" then return false end
    if mode == "Always" then return true end
    local threshold = tonumber(flag("FinalSwarmSuppressHpPercent", 65)) or 65
    return hpPercent() <= threshold
end

local function recordViolation(key)
    stats.acViolations = stats.acViolations + 1
    S.lastViolation = tostring(key)
    if not notedViolation[key] then
        notedViolation[key] = true
        note("anti-cheat would have reported '" .. tostring(key) .. "' — swallowed; movement is too hot", "Warn")
    end
end

-- The game's own modules hold the networker objects they report through, and
-- shadowing a client object this module created would be blind — the reporter
-- calls its own table. So the shield reaches the live objects via
-- require(<module>)._networker, which both the anti-cheat and the enemy
-- service expose (verified live 2026-10-03; CharacterService keeps its own in
-- a local and cannot be shadowed from outside).
local function gameNetworker(serviceName, moduleName)
    local shared = find(ReplicatedStorage, "Shared", 5)
    local services = shared and shared:FindFirstChild("Services")
    local folder = services and services:FindFirstChild(serviceName)
    local mod = folder and folder:FindFirstChild(moduleName)
    if not mod then return nil end
    local ok, modTable = pcall(require, mod)
    if not ok or type(modTable) ~= "table" then return nil end
    return modTable._networker
end

function Shield.ensure()
    if Shield.active then return true end
    if os.clock() - (Shield.lastTry or 0) < 2 then return false end
    Shield.lastTry = os.clock()

    local ac = gameNetworker("AntiCheatService", "AntiCheatServiceClient")
    if not ac then return false end -- not in a round yet (or renamed): retry later
    Shield.active = true

    shadowFire(ac, "ReportViolation", function(_, _, key)
        recordViolation(key)
        return true, false -- handled, never forwarded
    end)

    local enemy = gameNetworker("EnemyService", "EnemyServiceClient")
    if enemy then
        shadowFire(enemy, "ReportImpact", function(_, _, enemyId, position, predicted)
            if suppressionActive() then
                stats.suppressed = stats.suppressed + 1
                local info = { enemyId = enemyId, position = position, predicted = predicted, heldBack = true }
                for _, fn in ipairs(impactHandlers) do
                    pcall(fn, info)
                end
                return true, false
            end
            return false, true
        end)
    else
        note("EnemyService networker not exposed — hit suppression unavailable in this build", "Warn")
    end

    note("shield armed: anti-cheat canary" .. (enemy and " + hit suppression" or ""))
    return true
end

function Shield.stats()
    return {
        acViolations = stats.acViolations,
        suppressed = stats.suppressed,
        active = Shield.active,
        lastViolation = S.lastViolation,
        suppressionActive = suppressionActive(),
    }
end

function Shield.disarm()
    for _, entry in ipairs(shadowed) do
        pcall(function()
            if entry.obj then entry.obj.fire = nil end
        end)
    end
    shadowed = {}
    Shield.active = false
end

function Shield.onImpactReport(fn)
    if type(fn) == "function" then table.insert(impactHandlers, fn) end
end

----------------------------------------------------------------
-- SafeMove — CFrame movement, fly, noclip
----------------------------------------------------------------
-- The in-round anti-cheat watches humanoid properties and states, so this
-- moves the HumanoidRootPart directly: velocity zeroed, CFrame stepped at a
-- speed budget, position updates rate-limited (the same shape the Survivor
-- module uses, which runs for hours without a report). Fly is the same step
-- with a vertical component — the humanoid is never put into the Flying
-- state — and noclip just clears CanCollide on the character's parts, a
-- property nothing in the anti-cheat's list touches.
local SafeMove = {
    target = nil,
    accum = 0,
    progressAt = 0,
    lastDistance = nil,
    sideFlip = 1,
    fly = false,
}
local collideOriginals = {}
local noclipOn = false

local function rayParams()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    local character = LocalPlayer.Character
    if character then table.insert(ignore, character) end
    params.FilterDescendantsInstances = ignore
    return params
end

local function groundY(x, z, fromY)
    local origin = Vector3.new(x, fromY, z)
    local hit = workspace:Raycast(origin, Vector3.new(0, -600, 0), rayParams())
    return hit and hit.Position.Y or nil
end

function SafeMove.setNoclip(on)
    local character = LocalPlayer.Character
    noclipOn = on and true or false
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            if noclipOn then
                if collideOriginals[part] == nil then
                    collideOriginals[part] = part.CanCollide
                end
                part.CanCollide = false
            elseif collideOriginals[part] ~= nil then
                pcall(function() part.CanCollide = collideOriginals[part] end)
                collideOriginals[part] = nil
            end
        end
    end
end

local function restoreNoclip()
    SafeMove.setNoclip(false)
end

function SafeMove.stop()
    SafeMove.target = nil
    SafeMove.accum = 0
    SafeMove.lastDistance = nil
    restoreNoclip()
    -- Never leave the character floating: if it is airborne and fly is off,
    -- walk it down to the ground with the same stepper.
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not (root and humanoid) then return end
    local y = groundY(root.Position.X, root.Position.Z, root.Position.Y)
    if y and root.Position.Y - y > 3 then
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = CFrame.new(Vector3.new(root.Position.X, y + 3, root.Position.Z)) * (root.CFrame - root.CFrame.Position)
    end
end

function SafeMove.moveTo(target)
    if typeof(target) ~= "Vector3" then return false end
    SafeMove.target = target
    SafeMove.lastDistance = nil
    SafeMove.progressAt = os.clock()
    return true
end

function SafeMove.isFlyActive() return SafeMove.fly end

local function stepOnce(dt)
    local target = SafeMove.target
    if not target then return end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not (root and humanoid) then return end

    local flyFlag = flag("FinalSwarmFly", false) == true
    SafeMove.fly = flyFlag
    if flag("FinalSwarmNoclip", false) == true then
        if not SafeMove.warnedNoclip then
            SafeMove.warnedNoclip = true
            note("noclip is detected: watchRigCollision restores CanCollide on rig parts and reports 'canCollide' (the shield swallows it). CFrame travel does not need noclip.", "Warn")
        end
        noclipOn = true
        -- Re-applied every tick: something in this game rewrites CanCollide on
        -- character parts within ~0.6 s (observed live; the reverter is not
        -- identified). CFrame travel does not need collisions cleared, so this
        -- is insurance, not a load-bearing mode.
        for _, part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") then
                if collideOriginals[part] == nil then
                    collideOriginals[part] = part.CanCollide
                end
                part.CanCollide = false
            end
        end
    elseif noclipOn then
        restoreNoclip()
    end

    local position = root.Position
    local delta = Vector3.new(target.X - position.X, 0, target.Z - position.Z)
    if flyFlag then
        delta = Vector3.new(target.X - position.X, target.Y - position.Y, target.Z - position.Z)
    end
    local distance = delta.Magnitude
    local speed = math.clamp(tonumber(flag("FinalSwarmSpeed", 45)) or 45, 5, 120)
    local stepLength = math.min(distance, speed * dt)

    -- Stuck detection: fly and noclip aside, a wall between here and there
    -- looks exactly like standing still, so side-step when progress stops.
    if SafeMove.lastDistance and distance > 4 and SafeMove.lastDistance - distance < 0.5 then
        if os.clock() - SafeMove.progressAt > 1.5 then
            SafeMove.sideFlip = -SafeMove.sideFlip
            local side = Vector3.new(-delta.Z, 0, delta.X).Unit * (6 * SafeMove.sideFlip)
            SafeMove.target = target + side
            SafeMove.progressAt = os.clock()
        end
    else
        SafeMove.progressAt = os.clock()
    end
    SafeMove.lastDistance = distance

    if stepLength > 0.01 then
        local direction = delta.Unit
        local newPosition = position + direction * stepLength
        if not flyFlag then
            -- Horizontal travel only; if there is nothing under us, descend
            -- toward the target instead of hovering.
            local y = groundY(newPosition.X, newPosition.Z, position.Y + 4)
            if y then
                newPosition = Vector3.new(newPosition.X, math.max(y + 3, position.Y - 8), newPosition.Z)
            elseif humanoid:GetState() == Enum.HumanoidStateType.Freefall then
                newPosition = Vector3.new(newPosition.X, position.Y - math.min(stepLength, 4), newPosition.Z)
            end
        end
        root.AssemblyLinearVelocity = Vector3.zero
        -- Keep the character's own facing: the weapons aim themselves, and
        -- spinning the body would fight the camera.
        root.CFrame = CFrame.new(newPosition) * (root.CFrame - root.CFrame.Position)
    end
end

function SafeMove.tick(dt)
    local rate = math.clamp(tonumber(flag("FinalSwarmPositionRate", 30)) or 30, 5, 60)
    SafeMove.accum = SafeMove.accum + dt
    local interval = 1 / rate
    if SafeMove.accum < interval then return end
    local elapsed = SafeMove.accum
    SafeMove.accum = 0
    stepOnce(elapsed)
end

function SafeMove.debug()
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local target = SafeMove.target
    return string.format(
        "fly=%s noclip=%s pos=%s target=%s dist=%s",
        tostring(SafeMove.fly), tostring(noclipOn),
        root and string.format("%.0f,%.0f,%.0f", root.Position.X, root.Position.Y, root.Position.Z) or "nil",
        target and string.format("%.0f,%.0f,%.0f", target.X, target.Y, target.Z) or "nil",
        (target and root) and string.format("%.0f", (target - root.Position).Magnitude) or "-"
    )
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
    local now = os.clock()
    local dt = now - (S.lastTick or now)
    if dt <= 0 or dt > 1 then dt = 0.05 end

    Shield.ensure()
    SafeMove.tick(dt)

    S.lastTick = now
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
    pcall(function() SafeMove.stop() end)
    pcall(function() Shield.disarm() end)
    local g = getgenv and getgenv()
    if g and g.__FINALSWARM_FARM then
        g.__FINALSWARM_FARM = nil
    end
end

local handle = {
    status = function() return S.status, S.armed end,
    moveTo = function(x, y, z) return SafeMove.moveTo(Vector3.new(x, y, z)) end,
    safe = SafeMove.debug,
    flags = function()
        return {
            fly = flag("FinalSwarmFly", false),
            noclip = flag("FinalSwarmNoclip", false),
            speed = flag("FinalSwarmSpeed", 45),
            rate = flag("FinalSwarmPositionRate", 30),
        }
    end,
    -- Test hook, deliberately named: flags that have no UI element yet cannot
    -- be driven through a handle. T9 adds the real elements — use those
    -- (or QuickBar) once they exist, never EZ.Flags writes.
    setFlagTest = function(id, value) EZ.Flags[id] = value end,
    net = function(tag) return net(tag) ~= nil end,
    netDebug = netDebug,
    placeKind = function() return S.placeKind end,
    shield = function() return Shield.stats() end,
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
