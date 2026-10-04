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

-- Non-yielding sibling of find() for tick-path lookups: the 20 Hz loop must
-- never sit inside a WaitForChild, so cold paths use find() and everything
-- called from the loop uses this.
local function peek(parent, name)
    if not parent then return nil end
    return parent:FindFirstChild(name)
end

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local S = {
    armed = false,
    status = "Idle",
    placeKind = nil,       -- "lobby" | "round" | nil (not decided yet)
    placeLast = nil,       -- previous tick's place kind (transition detection)
    lastTick = 0,
}

local stats = {
    loops = 0,
    claims = 0,
    skips = 0,
    picks = 0,
    revives = 0,
    queues = 0,            -- EnterQueue attempts (0 proves an adopted run)
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
-- Threat — enemy and projectile tracking, dodge solver
----------------------------------------------------------------
-- Enemies use the shape verified live: workspace.Enemies holds Models with
-- an EnemyGuid attribute and a Humanoid. Projectiles were the spec's open
-- question (workspace clones vs client-module state) and this build could
-- not run the live probe before being written, so the detector covers the
-- workspace side — candidate containers scanned every tick, velocities
-- estimated from consecutive samples — and Threat.debug() dumps what it saw
-- (containers, tracked movers, velocities, plus the ProjectileServiceClient
-- export names) so a live session can confirm the representation and narrow
-- CONTAINER_HINTS without re-deriving it.

-- Requires a module out of ReplicatedStorage.Shared, pcall'd and cached.
-- A renamed module degrades to nil (safe mode) and is retried on a slow
-- clock, so a game update can never throw out of the tick or spam the log.
local sharedCache = {}
local sharedNoted = {}
local sharedFailedAt = {}

local function requireShared(...)
    local parts = { ... }
    local key = table.concat(parts, ".")
    local cached = sharedCache[key]
    if cached ~= nil then
        if cached ~= false then return cached end
        if os.clock() - (sharedFailedAt[key] or 0) < 10 then return nil end
    end
    local node = peek(ReplicatedStorage, "Shared")
    for index = 1, #parts do
        node = node and peek(node, parts[index]) or nil
    end
    local loaded = nil
    if node then
        local ok, value = pcall(require, node)
        if ok and type(value) == "table" then loaded = value end
    end
    if loaded then
        sharedCache[key] = loaded
        return loaded
    end
    if not sharedNoted[key] then
        sharedNoted[key] = true
        note("game module unavailable: Shared." .. key, "Warn")
    end
    sharedCache[key] = false
    sharedFailedAt[key] = os.clock()
    return nil
end

local Threat = {
    lastTickAt = 0,
    enemies = {},
    nearest = nil,
    boss = false,
    tracked = {},        -- projectiles seen this tick (array; accessor below)
    inbound = {},
    closestDistance = nil,
    dodge = nil,
    samples = {},
    box = nil,
    boxChecked = false,
}

-- Workspace children whose name contains one of these fragments are scanned
-- for projectile movers each tick.
local CONTAINER_HINTS = { "Projectile", "Bullets", "VFX" }
local TRACK_RADIUS = 250      -- studs: how far away an enemy still counts
local HORIZON = 1.2           -- seconds: projectile impact horizon
local MISS_RADIUS = 10        -- studs: how close a pass must be to matter

local projectileNames = nil
local projectileNamesAt = 0

local function projectileNameSet()
    if projectileNames and os.clock() - projectileNamesAt < 30 then return projectileNames end
    local assets = peek(ReplicatedStorage, "Assets")
    local folder = assets and peek(assets, "Projectiles")
    if folder then
        local set = {}
        for _, child in ipairs(folder:GetChildren()) do
            set[child.Name] = true
        end
        projectileNames = set
        projectileNamesAt = os.clock()
        return set
    end
    return projectileNames or {}
end

local function projectileContainers()
    local out = {}
    for _, child in ipairs(workspace:GetChildren()) do
        local name = child.Name
        for _, hint in ipairs(CONTAINER_HINTS) do
            if name:find(hint, 1, true) then
                table.insert(out, child)
                break
            end
        end
    end
    return out
end

function Threat.readEnemies(position)
    local list = {}
    Threat.nearest = nil
    local folder = peek(workspace, "Enemies")
    if folder and position then
        local data = requireShared("Modules", "Data", "EnemyData")
        for _, model in ipairs(folder:GetChildren()) do
            if model:IsA("Model") and model:GetAttribute("EnemyGuid") then
                local humanoid = model:FindFirstChildOfClass("Humanoid")
                if humanoid and humanoid.Health > 0 then
                    local enemyPosition = model:GetPivot().Position
                    local distance = (enemyPosition - position).Magnitude
                    if distance <= TRACK_RADIUS then
                        local entry = {
                            model = model,
                            position = enemyPosition,
                            distance = distance,
                            walker = true,
                            band = 10,
                        }
                        -- EnemyData is keyed by enemy name (Zombie, Sniper, ...);
                        -- a miss keeps the walker default instead of guessing at
                        -- renamed keys.
                        local info
                        if type(data) == "table" then
                            info = rawget(data, model.Name)
                            if type(info) ~= "table" then
                                local sub = rawget(data, "Enemies")
                                if type(sub) == "table" then info = rawget(sub, model.Name) end
                            end
                        end
                        if type(info) == "table" then
                            entry.walker = info.type ~= "Shoot"
                            local band = tonumber(info.preferredRange)
                            if band then entry.band = band end
                        end
                        table.insert(list, entry)
                        if not Threat.nearest or distance < Threat.nearest.distance then
                            Threat.nearest = entry
                        end
                    end
                end
            end
        end
    end
    Threat.enemies = list
end

function Threat.readProjectiles(position, dt)
    local tracked = {}
    local inbound = {}
    Threat.closestDistance = nil
    local now = os.clock()
    local nameSet = projectileNameSet()

    -- Drop samples for instances that vanished; PartCache recycles parts, so
    -- a respawn must not be read as a projectile streak.
    for key, sample in pairs(Threat.samples) do
        if now - sample.at > 1.5 then
            Threat.samples[key] = nil
        end
    end

    for _, container in ipairs(projectileContainers()) do
        for _, inst in ipairs(container:GetChildren()) do
            local isPart = inst:IsA("BasePart")
            local isModel = not isPart and inst:IsA("Model")
            if isPart or isModel then
                local point = isPart and inst.Position or inst:GetPivot().Position
                local sample = Threat.samples[inst]
                local velocity = nil
                if sample and now - sample.at <= 0.5 then
                    velocity = (point - sample.position) / math.max(dt, 0.01)
                    if velocity.Magnitude > 400 then velocity = nil end
                end
                Threat.samples[inst] = { position = point, at = now }
                if nameSet[inst.Name] or (velocity and velocity.Magnitude >= 6) then
                    local entry = {
                        object = inst,
                        position = point,
                        velocity = velocity or Vector3.zero,
                        named = nameSet[inst.Name] == true,
                    }
                    table.insert(tracked, entry)
                    if position then
                        local distance = (point - position).Magnitude
                        if not Threat.closestDistance or distance < Threat.closestDistance then
                            Threat.closestDistance = distance
                        end
                        -- Inbound test: closest point of approach to the character.
                        if velocity and velocity.Magnitude >= 6 then
                            local rel = point - position
                            local closing = -rel:Dot(velocity) / velocity:Dot(velocity)
                            if closing > 0 and closing <= HORIZON then
                                local miss = (rel + velocity * closing).Magnitude
                                if miss <= MISS_RADIUS then
                                    entry.time = closing
                                    entry.distance = miss
                                    table.insert(inbound, entry)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    Threat.tracked = tracked
    Threat.inbound = inbound
end

function Threat.readBoss()
    Threat.boss = false
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local hud = playerGui and peek(playerGui, "HUD")
    local top = hud and peek(hud, "Top")
    local holder = top and peek(top, "BossHealthBarHolder")
    if holder and holder.Visible then
        Threat.boss = true
    end
end

function Threat.arenaBox()
    if Threat.boxChecked then return Threat.box end
    Threat.boxChecked = true
    local map = peek(workspace, "Map")
    if map and map:IsA("Model") then
        local ok, cf, size = pcall(map.GetBoundingBox, map)
        if ok and cf and size and size.Magnitude > 50 then
            Threat.box = { center = cf.Position, size = size }
        end
    end
    return Threat.box
end

-- The dodge solver: for every inbound projectile, the closest point of
-- approach decides urgency; the escape direction is perpendicular to the
-- projectile's velocity, signed away from its path. That is blended with the
-- keep-out vector from walker enemies (their preferredRange band) and a pull
-- back inside the arena boundary. The result is a target position the
-- movement tier can walk to.
function Threat.solve(position)
    Threat.dodge = nil
    if not position then return end

    local accum = Vector3.zero
    for _, entry in ipairs(Threat.inbound) do
        local urgency = (1 - entry.time / HORIZON) * (1 - entry.distance / MISS_RADIUS)
        if urgency > 0 then
            local flat = Vector3.new(entry.velocity.X, 0, entry.velocity.Z)
            if flat.Magnitude > 0.5 then
                local perp = flat.Unit:Cross(Vector3.yAxis)
                local closestPoint = entry.position + entry.velocity * entry.time
                local side = perp:Dot(position - closestPoint)
                local sign
                if math.abs(side) > 0.1 then
                    sign = side > 0 and 1 or -1
                else
                    -- Dead centre on the path: pick a deterministic side so
                    -- the solver does not flip-flop between ticks.
                    sign = (math.floor(position.X) % 2 == 0) and 1 or -1
                end
                accum = accum + perp * (sign * urgency)
            end
        end
    end

    local keepOut = Vector3.zero
    for _, enemy in ipairs(Threat.enemies) do
        if enemy.walker then
            local reach = enemy.band + 6
            if enemy.distance < reach then
                local flat = Vector3.new(position.X - enemy.position.X, 0, position.Z - enemy.position.Z)
                if flat.Magnitude > 0.1 then
                    keepOut = keepOut + flat.Unit * (1 - enemy.distance / reach)
                end
            end
        end
    end

    local boundary = Vector3.zero
    local box = Threat.arenaBox()
    if box then
        local half = box.size / 2
        local offset = position - box.center
        local overX = math.abs(offset.X) - math.max(half.X - 12, 0)
        local overZ = math.abs(offset.Z) - math.max(half.Z - 12, 0)
        if overX > 0 or overZ > 0 then
            local flat = Vector3.new(box.center.X - position.X, 0, box.center.Z - position.Z)
            if flat.Magnitude > 0.1 then
                boundary = flat.Unit * math.min((math.max(overX, 0) + math.max(overZ, 0)) / 12, 1)
            end
        end
    end

    local total = accum + keepOut * 0.6 + boundary * 0.5
    local flat = Vector3.new(total.X, 0, total.Z)
    if flat.Magnitude > 0.2 then
        Threat.dodge = position + flat.Unit * 22
    end
end

function Threat.tick()
    local now = os.clock()
    local dt = now - Threat.lastTickAt
    if dt <= 0 or dt > 1 then dt = 0.05 end
    Threat.lastTickAt = now

    local character = LocalPlayer.Character
    local root = character and peek(character, "HumanoidRootPart")
    local position = root and root.Position or nil

    Threat.readEnemies(position)
    Threat.readProjectiles(position, dt)
    Threat.readBoss()
    Threat.solve(position)
end

function Threat.nearestEnemy()
    return Threat.nearest
end

function Threat.projectiles()
    return {
        count = #Threat.tracked,
        closest = Threat.closestDistance,
        inbound = #Threat.inbound,
    }
end

function Threat.dodgeVector()
    return Threat.dodge
end

function Threat.count()
    return #Threat.enemies
end

function Threat.bossActive()
    return Threat.boss
end

function Threat.reset()
    Threat.samples = {}
    Threat.tracked = {}
    Threat.inbound = {}
    Threat.enemies = {}
    Threat.nearest = nil
    Threat.dodge = nil
    Threat.closestDistance = nil
    Threat.box = nil
    Threat.boxChecked = false
end

-- The live probe the plan wanted before this detector was written. Dumps the
-- containers found, the tracked movers and the ProjectileServiceClient export
-- names, so a session with get-data-by-code can verify the projectile
-- representation (spec §8) and tune CONTAINER_HINTS without new code.
function Threat.debug()
    local containers = {}
    for _, container in ipairs(projectileContainers()) do
        table.insert(containers, container:GetFullName())
    end
    local tracked = {}
    for _, entry in ipairs(Threat.tracked) do
        table.insert(tracked, string.format(
            "%s%s(v=%.0f)",
            entry.object.Name,
            entry.named and "*" or "",
            entry.velocity.Magnitude
        ))
    end
    local serviceState = "-"
    local client = requireShared("Services", "ProjectileService", "ProjectileServiceClient")
    if client then
        local names = {}
        for key in pairs(client) do
            table.insert(names, tostring(key))
            if #names >= 12 then break end
        end
        serviceState = table.concat(names, ",")
    end
    return string.format(
        "enemies=%d boss=%s containers=[%s] tracked=%d inbound=%d closest=%s dodge=%s projClient=[%s]",
        #Threat.enemies, tostring(Threat.boss), table.concat(containers, ","),
        #Threat.tracked, #Threat.inbound,
        Threat.closestDistance and string.format("%.0f", Threat.closestDistance) or "nil",
        Threat.dodge and string.format("%.0f,%.0f,%.0f", Threat.dodge.X, Threat.dodge.Y, Threat.dodge.Z) or "nil",
        serviceState
    )
end

----------------------------------------------------------------
-- UpgradeBrain — read offers, score with synergies, pick
----------------------------------------------------------------
-- Upgrade offers gate all progress (verified live: the run sits still until
-- the modal is answered), so the loop treats a visible modal as blocking.
-- Cards are read as text from PlayerGui.Frames.Upgrades.Holder.Selection1..5
-- (verified live: the name is a plain label such as "Lifesteal" or "Demon
-- Slayer", stat lines read "Attack Speed +10%"). The pick goes through
-- GameServiceClient:UpgradeSelected — the exact call the game's own card
-- handler makes — with the game's networker as a middle fallback and a
-- synthesized MouseButton1Up as the documented last resort (the card handler
-- is bound to MouseButton1Up, verified live, which nothing else fires).

local UpgradeBrain = {
    pending = nil,       -- { index =, name =, at =, retried = }
    backoffUntil = 0,
    failNoted = false,
    pathNoted = false,
}

-- Input synthesis resolved once; only used for the fallback the plan
-- documents for GUI-bound handlers.
local virtualInput = nil
local virtualInputChecked = false

local function getVirtualInput()
    if virtualInputChecked then return virtualInput end
    virtualInputChecked = true
    local ok, service = pcall(function() return game:GetService("VirtualInputManager") end)
    if ok and service then
        virtualInput = service
    else
        note("VirtualInputManager unavailable — the upgrade/claim fallback click is disabled", "Warn")
    end
    return virtualInput
end

local RARITY_WORDS = { "common", "uncommon", "rare", "epic", "legendary", "mythic" }
local RARITY_BONUS = {
    common = 0,
    uncommon = 0.02,
    rare = 0.05,
    epic = 0.1,
    legendary = 0.18,
    mythic = 0.22,
}

-- Category keywords, most specific first: classification takes the first
-- match, so "attack speed" must outrank "speed" and "crit" must outrank
-- "damage" (crit lines read "Crit Damage +8%").
local KEYWORDS = {
    { "attack speed", "attackSpeed" },
    { "crit", "crit" },
    { "lifesteal", "lifesteal" },
    { "damage", "damage" },
    { "slayer", "damage" },
    { "projectile", "projectiles" },
    { "pierce", "pierce" },
    { "ricochet", "pierce" },
    { "bounce", "pierce" },
    { "health", "sustain" },
    { "regen", "sustain" },
    { "heal", "sustain" },
    { "evasion", "sustain" },
    { "armor", "sustain" },
    { "movement", "movement" },
    { "speed", "movement" },
    { "gold", "economy" },
    { "key", "economy" },
    { "luck", "economy" },
    { "pickup", "economy" },
    { "xp", "economy" },
}

-- Spec §5 weights. sustain is dynamic (0.5 while threatened, 0.3 otherwise)
-- and damage / attack speed are user-overridable through flags.
local BASE_WEIGHTS = {
    damage = 1.0,
    attackSpeed = 1.0,
    projectiles = 0.9,
    pierce = 0.7,
    crit = 0.6,
    lifesteal = 0.55,
    sustain = 0.3,
    movement = 0.2,
    economy = 0.15,
}

local COMBO_BONUS = 0.35
local COMBOS = {
    { "attackSpeed", "lifesteal" },
    { "projectiles", "pierce" },
    { "crit", "crit" },
}

local function classify(text)
    for _, entry in ipairs(KEYWORDS) do
        if text:find(entry[1], 1, true) then return entry[2] end
    end
    return nil
end

local function weightFor(category)
    if category == "damage" then
        return tonumber(flag("FinalSwarmWeightDamage", 1)) or 1
    end
    if category == "attackSpeed" then
        return tonumber(flag("FinalSwarmWeightAttackSpeed", 1)) or 1
    end
    return BASE_WEIGHTS[category] or 0
end

-- PlayerRunData is the game's own live view of the run (owned upgrades, held
-- weapons, rewards). Cached for a second; every read is pcall'd.
local runSnapshot = nil
local runSnapshotAt = 0

local function runData()
    if os.clock() - runSnapshotAt < 1 then return runSnapshot end
    runSnapshotAt = os.clock()
    runSnapshot = nil
    local mod = requireShared("Modules", "Core", "PlayerRunData")
    if mod and type(mod.get) == "function" then
        local ok, data = pcall(mod.get, mod, LocalPlayer)
        if ok and type(data) == "table" then runSnapshot = data end
    end
    return runSnapshot
end

local function ownedCategories()
    local owned = {}
    local data = runData()
    if type(data) == "table" and type(data.upgrades) == "table" then
        for key in pairs(data.upgrades) do
            local category = classify(tostring(key):lower())
            if category then
                owned[category] = (owned[category] or 0) + 1
            end
        end
    end
    return owned
end

local weaponNames = nil
local weaponNamesAt = 0

local function weaponNameSet()
    if weaponNames and os.clock() - weaponNamesAt < 30 then return weaponNames end
    local assets = peek(ReplicatedStorage, "Assets")
    local folder = assets and peek(assets, "Weapons")
    if folder then
        local set = {}
        for _, child in ipairs(folder:GetChildren()) do
            set[child.Name:lower()] = true
        end
        weaponNames = set
        weaponNamesAt = os.clock()
    end
    return weaponNames or {}
end

local function ownsWeapon(data, name)
    if type(data) ~= "table" or type(data.weapons) ~= "table" then return false end
    if data.weapons[name] ~= nil then return true end
    for _, weapon in ipairs(data.weapons) do
        if tostring(weapon):lower() == name then return true end
    end
    return false
end

local function upgradeHolder()
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local frames = playerGui and peek(playerGui, "Frames")
    local upgrades = frames and peek(frames, "Upgrades")
    return upgrades and peek(upgrades, "Holder") or nil
end

local function cardForIndex(index)
    local holder = upgradeHolder()
    return holder and peek(holder, "Selection" .. tostring(index)) or nil
end

local function cardLabels(card)
    local labels = {}
    for _, inst in ipairs(card:GetDescendants()) do
        if inst:IsA("TextLabel") and inst.Text ~= "" then
            table.insert(labels, inst.Text)
        end
    end
    return labels
end

function UpgradeBrain.readOffers()
    local out = {}
    local holder = upgradeHolder()
    if not holder then return out end
    for slot = 1, 5 do
        local card = peek(holder, "Selection" .. tostring(slot))
        if card and card.Visible then
            local name, rarity
            local lines = {}
            for _, text in ipairs(cardLabels(card)) do
                local lower = text:lower()
                local isRarity = false
                for _, word in ipairs(RARITY_WORDS) do
                    if lower == word then
                        isRarity = true
                        rarity = text
                        break
                    end
                end
                if not isRarity then
                    -- Stat lines carry a number ("Attack Speed +10%"); the
                    -- first clean label is taken as the card's name.
                    if not name and not text:find("%d") then
                        name = text
                    end
                    table.insert(lines, text)
                end
            end
            table.insert(out, {
                index = slot,
                name = name or card.Name,
                rarity = rarity or "Unknown",
                lines = lines,
            })
        end
    end
    return out
end

function UpgradeBrain.score(offer)
    local score = 0
    local seen = {}
    local texts = { tostring(offer.name or "") }
    for _, line in ipairs(offer.lines or {}) do
        table.insert(texts, tostring(line))
    end
    for _, text in ipairs(texts) do
        local category = classify(text:lower())
        if category and not seen[category] then
            seen[category] = true
            local weight = weightFor(category)
            if category == "sustain" and hpPercent() <= 60 then
                weight = 0.5
            end
            -- Line magnitude nudges the weight: "+20%" should outrank "+10%"
            -- within a category, without letting one big flat number dominate.
            local value = tonumber(text:match("(%d+%.?%d*)"))
            local scale = 1
            if value and value > 0 then
                scale = 1 + math.min(value, 50) / 50
            end
            score = score + weight * scale
        end
    end

    score = score + (RARITY_BONUS[(offer.rarity or ""):lower()] or 0)

    -- Synergy: an offer is worth more when the other half of its combo is
    -- already owned (attack speed x lifesteal, projectile count x pierce,
    -- crit x crit — chance and damage share the category).
    local owned = ownedCategories()
    for _, pair in ipairs(COMBOS) do
        local a, b = pair[1], pair[2]
        if seen[a] and (owned[b] or 0) > 0 then
            score = score + COMBO_BONUS
        end
        if b ~= a and seen[b] and (owned[a] or 0) > 0 then
            score = score + COMBO_BONUS
        end
    end

    -- Weapons: a new weapon is a fresh damage source with a flat early-game
    -- bonus that decays as the build fills; a weapon already held is a
    -- duplicate and scores a penalty.
    local name = (offer.name or ""):lower()
    local data = runData()
    if weaponNameSet()[name] or ownsWeapon(data, name) then
        if ownsWeapon(data, name) then
            score = score - 0.6
        else
            local upgradeCount = 0
            if type(data) == "table" and type(data.upgrades) == "table" then
                for _ in pairs(data.upgrades) do
                    upgradeCount = upgradeCount + 1
                end
            end
            score = score + 0.9 * math.max(0, 1 - upgradeCount / 12)
        end
    end

    return score
end

-- Primary: the module call the game's own card handler makes. Middle: the
-- same method over the game's networker. Last resort (the documented
-- exception): synthesize the MouseButton1Up release at the card's centre.
function UpgradeBrain.pick(index)
    local client = requireShared("Services", "GameService", "GameServiceClient")
    if client and type(client.UpgradeSelected) == "function" then
        if pcall(client.UpgradeSelected, client, index, 1) then
            return true
        end
    end
    local gameNet = net("GameService")
    if gameNet and type(gameNet.fire) == "function" then
        if pcall(gameNet.fire, gameNet, "PlayerUpgradeSelected", index, 1) then
            return true
        end
    end
    local vim = getVirtualInput()
    local card = cardForIndex(index)
    if vim and card then
        local position = card.AbsolutePosition
        local size = card.AbsoluteSize
        local x = position.X + size.X / 2
        local y = position.Y + size.Y / 2
        if pcall(function()
            vim:SendMouseMoveEvent(x, y, game)
            vim:SendMouseButtonEvent(x, y, 0, true, game, 1)
            vim:SendMouseButtonEvent(x, y, 0, false, game, 1)
        end) then
            return true
        end
    end
    if not UpgradeBrain.pathNoted then
        UpgradeBrain.pathNoted = true
        note("every upgrade path failed (client call, remote and card click)", "Warn")
    end
    return false
end

-- One call per tick. Returns true while the modal owns the tick (an offer is
-- visible or a pick is being verified), false when there is nothing to do.
function UpgradeBrain.tick()
    local now = os.clock()
    local offers = UpgradeBrain.readOffers()
    if now < UpgradeBrain.backoffUntil then
        return #offers > 0
    end
    if #offers == 0 then
        UpgradeBrain.pending = nil -- a pending pick whose modal closed: it landed
        return false
    end

    local pending = UpgradeBrain.pending
    if pending then
        if now - pending.at < 0.6 then
            return true -- give the pick a beat before judging it
        end
        if not pending.retried then
            pending.retried = true
            pending.at = now
            UpgradeBrain.pick(pending.index)
            return true
        end
        if not UpgradeBrain.failNoted then
            UpgradeBrain.failNoted = true
            note("upgrade pick for slot " .. tostring(pending.index) .. " did not register twice — backing off 5 s", "Warn")
        end
        UpgradeBrain.pending = nil
        UpgradeBrain.backoffUntil = now + 5
        return true
    end

    local best, bestScore = nil, -math.huge
    for _, offer in ipairs(offers) do
        local value = UpgradeBrain.score(offer)
        if value > bestScore then
            best, bestScore = offer, value
        end
    end
    if not best then
        return false
    end
    stats.picks = stats.picks + 1
    stats.lastPick = string.format("%s [%s] #%d", tostring(best.name), tostring(best.rarity), best.index)
    UpgradeBrain.pending = { index = best.index, name = best.name, at = now, retried = false }
    UpgradeBrain.pick(best.index)
    return true
end

function UpgradeBrain.scoredOffers()
    local out = {}
    for _, offer in ipairs(UpgradeBrain.readOffers()) do
        table.insert(out, {
            index = offer.index,
            name = offer.name,
            rarity = offer.rarity,
            score = UpgradeBrain.score(offer),
        })
    end
    return out
end

function UpgradeBrain.debug()
    local parts = {}
    for _, entry in ipairs(UpgradeBrain.scoredOffers()) do
        table.insert(parts, string.format("#%d %s [%s] %.2f", entry.index, entry.name, entry.rarity, entry.score))
    end
    local pending = "-"
    if UpgradeBrain.pending then
        pending = string.format("#%d %s retried=%s",
            UpgradeBrain.pending.index, tostring(UpgradeBrain.pending.name), tostring(UpgradeBrain.pending.retried))
    end
    return string.format("pending=%s offers=[%s]", pending, table.concat(parts, " | "))
end

function UpgradeBrain.reset()
    UpgradeBrain.pending = nil
    UpgradeBrain.backoffUntil = 0
    UpgradeBrain.failNoted = false
    UpgradeBrain.pathNoted = false
end

----------------------------------------------------------------
-- RunFlow — lobby (world/difficulty, best unlocked, queue) + round flow
----------------------------------------------------------------
-- Lobby: resolve a world and difficulty (a hand-picked flag wins over the
-- "best unlocked" scan), then queue through the game's own WorldSelection
-- networker exactly as the world-select frame does. Round: revive, claim,
-- boss portal, chests/pots and skip votes, each rate-limited, with travel
-- handed back to the loop's movement tier.
--
-- Everything here is non-yielding except the two network fetches —
-- CanPartyPlay during the unlock scan (one per tick) and EnterQueue (one per
-- 30 s) — so the 20 Hz loop keeps breathing.

local ROUND_PLACE = 79787558257549

local RunFlow = {
    adopted = false,
    worldsNoted = false,
    noneNoted = false,
    worldsCache = nil,
    difficultyCache = {},
    scanIndex = 0,
    scanCandidate = nil,
    scanDone = false,
    chosen = nil,
    lastChosenWorld = nil,
    lastChosenDifficulty = nil,
    queueState = "idle",   -- idle | waiting | failed | arrived
    lastQueueAt = 0,
    queueFailNoted = false,
    waveCache = nil,
    waveAt = 0,
    skipCount = 0,
    lastSkipAt = 0,
    chests = {},
    chestTarget = nil,
    portalTarget = nil,
    portalFiredAt = nil,
    claimStage = 0,
    claimAt = 0,
    claimNoted = false,
    claimStuckNoted = false,
    reviveAttempts = 0,
    lastReviveAt = 0,
    hadCharacter = false,
    afterClaim = false,
    postClaimAt = 0,
    postClaimNoted = false,
}

-- Place detection (verified live: the round place ships FinalSwarmService and
-- WeaponService under Shared.Services, the lobby does not). Arming inside a
-- live run therefore adopts the run and never touches the queue.
function RunFlow.placeKind()
    local shared = peek(ReplicatedStorage, "Shared")
    local services = shared and peek(shared, "Services")
    if services and (peek(services, "FinalSwarmService") or peek(services, "WeaponService")) then
        return "round"
    end
    return "lobby"
end

function RunFlow.worlds()
    if RunFlow.worldsCache then return RunFlow.worldsCache end
    local mod = requireShared("Modules", "Data", "WaveData")
    if mod and type(mod.CampaignWorlds) == "function" then
        local ok, list = pcall(mod.CampaignWorlds, mod)
        if ok and type(list) == "table" and #list > 0 then
            RunFlow.worldsCache = list
            return list
        end
    end
    return nil
end

-- Difficulty keys live in EnvironmentModifierData.Worlds[world] when it
-- ships them (verified: Volcano Normal/Hard/Nightmare/All, Atlantis
-- Normal/Hard/Nightmare); a world without the entry, or a module that will
-- not load, falls back to the one difficulty every world has.
function RunFlow.difficulties(world)
    if type(world) ~= "string" or world == "" then return nil end
    local cached = RunFlow.difficultyCache[world]
    if cached then return cached end
    local list = nil
    local mod = requireShared("Modules", "Data", "EnvironmentModifierData")
    if mod and type(mod.Worlds) == "table" then
        local entry = rawget(mod.Worlds, world)
        if type(entry) == "table" then
            list = {}
            if #entry > 0 then
                for _, value in ipairs(entry) do
                    if type(value) == "string" then table.insert(list, value) end
                end
            else
                for key in pairs(entry) do
                    if type(key) == "string" then table.insert(list, key) end
                end
                table.sort(list)
            end
            if #list == 0 then list = nil end
        end
    end
    if not list then list = { "Normal" } end
    RunFlow.difficultyCache[world] = list
    return list
end

local function canPartyPlay(world, difficulty)
    local client = net("WorldSelection")
    if not (client and type(client.fetch) == "function") then return nil end
    local ok, result = pcall(client.fetch, client, "CanPartyPlay", world, difficulty)
    if ok then return result == true end
    return nil
end

-- The unlock scan advances one CanPartyPlay fetch per tick and keeps the
-- last world that answered true — "best unlocked" never offers a world the
-- queue would reject.
local function advanceUnlockScan()
    local worlds = RunFlow.worlds()
    if not worlds then
        RunFlow.scanDone = true
        return nil, true
    end
    if RunFlow.scanIndex == 0 then
        RunFlow.scanIndex = 1
        RunFlow.scanCandidate = nil
    end
    while RunFlow.scanIndex <= #worlds do
        local world = worlds[RunFlow.scanIndex]
        RunFlow.scanIndex = RunFlow.scanIndex + 1
        if canPartyPlay(world, "Normal") == true then
            RunFlow.scanCandidate = world
        end
        return nil, false -- one fetch per tick
    end
    RunFlow.scanDone = true
    return RunFlow.scanCandidate, true
end

-- Synchronous full scan, for verification and for callers outside the loop.
function RunFlow.bestUnlocked()
    local worlds = RunFlow.worlds()
    if not worlds then return nil, nil end
    local best = nil
    for _, world in ipairs(worlds) do
        if canPartyPlay(world, "Normal") == true then
            best = world
        end
    end
    if not best then return nil, nil end
    return best, "Normal"
end

local function resolveSelection()
    local worlds = RunFlow.worlds()
    local flagWorld = flag("FinalSwarmWorld", "")
    if type(flagWorld) == "string" and flagWorld ~= "" then
        if worlds then
            for _, candidate in ipairs(worlds) do
                if candidate == flagWorld then
                    local picked = nil
                    local flagDifficulty = flag("FinalSwarmDifficulty", "")
                    local list = RunFlow.difficulties(candidate)
                    if type(flagDifficulty) == "string" and flagDifficulty ~= "" and list then
                        for _, difficulty in ipairs(list) do
                            if difficulty == flagDifficulty then
                                picked = difficulty
                                break
                            end
                        end
                    end
                    if not picked and list then
                        picked = list[1]
                    end
                    return candidate, picked or "Normal", "ok"
                end
            end
        end
        -- The flag names a world the live data does not list: fall through to
        -- the scan rather than queueing into nothing.
    end

    if flag("FinalSwarmBestUnlocked", true) ~= true then
        return nil, nil, "none"
    end
    if RunFlow.scanDone then
        if RunFlow.scanCandidate then
            return RunFlow.scanCandidate, "Normal", "ok"
        end
        return nil, nil, "none"
    end
    local candidate, done = advanceUnlockScan()
    if done then
        if candidate then
            return candidate, "Normal", "ok"
        end
        return nil, nil, "none"
    end
    return nil, nil, "scanning"
end

-- The queue sequence, exactly the calls the world-select frame makes
-- (verified live 2026-10-03: this landed the probe client in the round
-- place). EnterQueue is a fetch, so this yields for one round-trip; the
-- loop treats non-true as failure and retries at most every 30 s.
function RunFlow.queue(world, difficulty)
    local client = net("WorldSelection")
    if not (client and type(client.fire) == "function" and type(client.fetch) == "function") then
        return false
    end
    stats.queues = stats.queues + 1
    -- Order and payload copied from the game's own world-selection play
    -- handler (captured live 2026-10-03 with a local hook on the RemoteEvent):
    -- SetDifficulty, SetWorld, SetRunMode — then the EnterQueue fetch. The
    -- campaign path sends neither JoinQueue nor SetChallenges.
    local runMode = flag("FinalSwarmRunMode", "Normal")
    if type(runMode) ~= "string" or runMode == "" then runMode = "Normal" end
    pcall(client.fire, client, "SetDifficulty", difficulty)
    pcall(client.fire, client, "SetWorld", world)
    pcall(client.fire, client, "SetRunMode", runMode)
    task.wait(0.3)
    local okFetch, result = pcall(client.fetch, client, "EnterQueue")
    return okFetch and result == true
end

local dataServiceCache = nil

local function dataService()
    if dataServiceCache ~= nil then
        return dataServiceCache or nil
    end
    local packages = peek(ReplicatedStorage, "Packages")
    local mod = packages and peek(packages, "DataService")
    if mod then
        local ok, value = pcall(require, mod)
        if ok and type(value) == "table" and type(value.client) == "table" then
            dataServiceCache = value
            return value
        end
    end
    dataServiceCache = false
    return nil
end

local function personalWave()
    -- The personal wave counter lives on EnemyServiceClient (verified: the
    -- round-end screen reads it through the same method).
    local mod = requireShared("Services", "EnemyService", "EnemyServiceClient")
    if mod and type(mod.getWave) == "function" then
        local ok, wave = pcall(mod.getWave, mod)
        if ok and type(wave) == "number" then return wave end
    end
    return nil
end

function RunFlow.wave()
    local now = os.clock()
    if now - RunFlow.waveAt < 0.5 then return RunFlow.waveCache end
    RunFlow.waveAt = now
    RunFlow.waveCache = personalWave()
    return RunFlow.waveCache
end

-- Skip rules come from the game's own FinalSwarmData.Skip (verified:
-- MaxWavesSkipped 5, CooldownSeconds 5, MinCooldownSeconds 1) plus the
-- player's skipCooldownReduction / skipCapBonus stats when PlayerRunData
-- exposes them.
local function skipCaps()
    local caps = { max = 5, cooldown = 5, min = 1 }
    local mod = requireShared("Modules", "Data", "FinalSwarmData")
    if mod and type(mod.Skip) == "table" then
        caps.max = tonumber(mod.Skip.MaxWavesSkipped) or caps.max
        caps.cooldown = tonumber(mod.Skip.CooldownSeconds) or caps.cooldown
        caps.min = tonumber(mod.Skip.MinCooldownSeconds) or caps.min
    end
    local data = runData()
    if data then
        local base = type(data.baseStats) == "table" and data.baseStats or {}
        local reduction = tonumber(data.skipCooldownReduction) or tonumber(base.skipCooldownReduction) or 0
        local capBonus = tonumber(data.skipCapBonus) or tonumber(base.skipCapBonus) or 0
        caps.max = caps.max + capBonus
        caps.cooldown = math.max(caps.cooldown - reduction, caps.min)
    end
    return caps
end

function RunFlow.skipWave()
    if flag("FinalSwarmSkipWaves", false) ~= true then return false end
    local wave = RunFlow.wave()
    if type(wave) ~= "number" then return false end
    local maxWave = tonumber(flag("FinalSwarmSkipMax", 5)) or 5
    if wave > maxWave then return false end
    if Threat.bossActive() then return false end
    local caps = skipCaps()
    if RunFlow.skipCount >= caps.max then return false end
    local now = os.clock()
    if now - RunFlow.lastSkipAt < caps.cooldown then return false end
    local client = net("EnemyService")
    if not (client and type(client.fire) == "function") then return false end
    local ok = pcall(client.fire, client, "RequestSkipVote")
    if ok then
        RunFlow.lastSkipAt = now
        RunFlow.skipCount = RunFlow.skipCount + 1
        stats.skips = stats.skips + 1
        return true
    end
    return false
end

function RunFlow.enterPortal()
    local map = peek(workspace, "Map")
    local portal = map and peek(map, "BossPortal")
    if not portal then return false end
    local prompt = portal:FindFirstChild("PortalPrompt", true) or portal:FindFirstChildOfClass("ProximityPrompt")
    if not (prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled) then return false end
    if RunFlow.portalFiredAt and os.clock() - RunFlow.portalFiredAt < 5 then return false end

    local target
    if portal:IsA("BasePart") then
        target = portal.Position
    elseif portal:IsA("Model") then
        target = portal:GetPivot().Position
    else
        return false
    end

    local character = LocalPlayer.Character
    local root = character and peek(character, "HumanoidRootPart")
    if not root then return false end

    local distance = (target - root.Position).Magnitude
    local range = tonumber(prompt.MaxActivationDistance) or 15
    if distance > math.max(range - 2, 4) then
        RunFlow.portalTarget = target -- caller travels this tick
        return false
    end

    RunFlow.portalFiredAt = os.clock()
    -- fireproximityprompt is the standard trigger; not yet verified inside
    -- this game, so the prompt's own input hold is the fallback.
    if type(fireproximityprompt) == "function" then
        if pcall(fireproximityprompt, prompt) then
            RunFlow.portalTarget = nil
            return true
        end
    end
    pcall(function() prompt:InputHoldBegin() end)
    task.wait(math.max(0.05, (tonumber(prompt.HoldDuration) or 0) + 0.05))
    pcall(function() prompt:InputHoldEnd() end)
    RunFlow.portalTarget = nil
    return true
end

function RunFlow.keyCount()
    local data = runData()
    if type(data) == "table" and type(data.rewards) == "table" then
        return tonumber(data.rewards.keys)
    end
    return nil
end

function RunFlow.chestCost()
    local data = runData()
    local opened = nil
    if type(data) == "table" and type(data.getGroupData) == "function" then
        local ok, group = pcall(data.getGroupData, data)
        if ok and type(group) == "table" then
            opened = tonumber(group.chestsOpened)
        end
    end
    if not opened then return nil end
    local client = requireShared("Services", "ChestService", "ChestServiceClient")
    if client and type(client.CalcChestCost) == "function" then
        local ok, cost = pcall(client.CalcChestCost, client, opened)
        if ok and type(cost) == "number" then return cost end
    end
    return nil
end

function RunFlow.openChests()
    if flag("FinalSwarmOpenChests", true) ~= true then return false end
    local chests = peek(workspace, "Chests")
    if not chests then return false end
    local character = LocalPlayer.Character
    local root = character and peek(character, "HumanoidRootPart")
    if not root then return false end

    local now = os.clock()
    local best, bestDistance = nil, nil
    for _, chest in ipairs(chests:GetChildren()) do
        if chest:IsA("Model") or chest:IsA("BasePart") then
            local prompt = chest:FindFirstChild("chestPrompt", true) or chest:FindFirstChildOfClass("ProximityPrompt")
            if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled then
                local marker = RunFlow.chests[chest]
                if not (marker and now - marker.at < 10) then
                    local position = chest:IsA("BasePart") and chest.Position or chest:GetPivot().Position
                    local distance = (position - root.Position).Magnitude
                    if not best or distance < bestDistance then
                        best = { chest = chest, prompt = prompt, position = position, name = chest.Name }
                        bestDistance = distance
                    end
                end
            end
        end
    end
    if not best then return false end

    local range = tonumber(best.prompt.MaxActivationDistance) or 12
    if bestDistance > math.max(range - 2, 4) then
        RunFlow.chestTarget = best.position -- caller travels this tick
        return false
    end

    -- LargeChest costs keys (its prompt shows CalcChestCost(chestsOpened));
    -- fire it only when the key count says we can pay, with a conservative
    -- floor while the cost itself cannot be read.
    if best.name:lower():find("large", 1, true) then
        local keys = RunFlow.keyCount()
        local cost = RunFlow.chestCost()
        local needed = cost or 50
        if keys == nil or keys < needed then
            RunFlow.chests[best.chest] = { at = now }
            return false
        end
    end

    RunFlow.chests[best.chest] = { at = now }
    if type(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, best.prompt)
    else
        pcall(function() best.prompt:InputHoldBegin() end)
        task.wait(math.max(0.05, (tonumber(best.prompt.HoldDuration) or 0) + 0.05))
        pcall(function() best.prompt:InputHoldEnd() end)
    end
    return true
end

function RunFlow.finishClaim()
    stats.claims = stats.claims + 1
    stats.loops = stats.loops + 1
    RunFlow.afterClaim = true
    RunFlow.postClaimAt = os.clock()
    note("claimed the run rewards — requeueing")
end

function RunFlow.claimRewards()
    if flag("FinalSwarmAutoClaim", true) ~= true then return false end
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local frames = playerGui and peek(playerGui, "Frames")
    local roundEnd = frames and peek(frames, "RoundEnd")
    if not (roundEnd and roundEnd.Visible) then
        if RunFlow.claimStage > 0 then
            -- The screen is gone after we clicked: the claim landed.
            RunFlow.claimStage = 0
            RunFlow.finishClaim()
        end
        return false
    end

    local now = os.clock()
    if RunFlow.claimStage == 0 then
        RunFlow.claimStage = 1
        RunFlow.claimAt = now
        setStatus("Run ended — claiming rewards")
        return true
    end
    -- Plan: let the end screen settle for a second before clicking.
    if now - RunFlow.claimAt < (RunFlow.claimStage == 1 and 1 or 0.35) then
        return true
    end

    local buttons = peek(roundEnd, "Buttons")
    local button = buttons and peek(buttons, "ClaimReward")
    if not button then
        if not RunFlow.claimNoted then
            RunFlow.claimNoted = true
            note("RoundEnd.ClaimReward button not found — cannot claim", "Warn")
        end
        return true -- keep the priority slot; the screen will not clear itself
    end

    if RunFlow.claimStage == 1 then
        RunFlow.claimStage = 2
        RunFlow.claimAt = now
        -- A plain signal fire usually answers GUI-bound handlers, and the
        -- plan expects MouseButton1Up not to be required here (that binding
        -- is verified for the upgrade cards, not for this button — the
        -- synthesized click below covers the difference).
        pcall(function()
            if type(firesignal) == "function" then
                firesignal(button.Activated)
                firesignal(button.MouseButton1Click)
            end
        end)
        return true
    end

    if RunFlow.claimStage == 2 then
        RunFlow.claimStage = 3
        RunFlow.claimAt = now
        local vim = getVirtualInput()
        if vim then
            local position = button.AbsolutePosition
            local size = button.AbsoluteSize
            local x = position.X + size.X / 2
            local y = position.Y + size.Y / 2
            pcall(function()
                vim:SendMouseMoveEvent(x, y, game)
                vim:SendMouseButtonEvent(x, y, 0, true, game, 1)
                vim:SendMouseButtonEvent(x, y, 0, false, game, 1)
            end)
        end
        return true
    end

    -- Still visible after every path: restart the chain and say so once.
    if not RunFlow.claimStuckNoted then
        RunFlow.claimStuckNoted = true
        note("claim click did not close RoundEnd — retrying", "Warn")
    end
    RunFlow.claimStage = 1
    RunFlow.claimAt = now
    return true
end

-- Death handling: fire the game's own AttemptRevive path at most three times
-- per run (the plan's cap), then let the run end and continue the loop.
function RunFlow.reviveIfDead()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local dead = false
    if not character then
        dead = RunFlow.hadCharacter -- vanished mid-run, not a pre-spawn lobby
    elseif humanoid and humanoid.Health <= 0 then
        dead = true
    end
    if not dead then
        if humanoid and humanoid.Health > 0 then
            RunFlow.hadCharacter = true
        end
        return false
    end
    if RunFlow.reviveAttempts >= 3 then return false end
    local now = os.clock()
    if now - RunFlow.lastReviveAt < 3 then return false end
    RunFlow.lastReviveAt = now
    RunFlow.reviveAttempts = RunFlow.reviveAttempts + 1

    local client = requireShared("Services", "GameService", "GameServiceClient")
    if client and type(client.AttemptRevive) == "function" then
        if pcall(client.AttemptRevive, client) then
            stats.revives = stats.revives + 1
            return true
        end
    end
    local gameNet = net("GameService")
    if gameNet and type(gameNet.fire) == "function" then
        if pcall(gameNet.fire, gameNet, "AttemptRevive") then
            stats.revives = stats.revives + 1
            return true
        end
    end
    return false
end

-- One round tick: revive -> claim -> boss portal -> chests -> skip vote.
-- Returns (true, nil) when the tick was spent on an action, or
-- (false, objective) where objective is a position for the travel tier.
function RunFlow.roundTick()
    if RunFlow.afterClaim then
        if os.clock() - RunFlow.postClaimAt > 30 and not RunFlow.postClaimNoted then
            RunFlow.postClaimNoted = true
            note("still in the round place 30 s after claiming — waiting for the lobby hop", "Warn")
        end
        setStatus("Claimed — waiting for the lobby")
        return true, nil
    end

    if RunFlow.reviveIfDead() then
        setStatus("Down — attempting a revive")
        return true, nil
    end

    if flag("FinalSwarmBossPortal", true) == true then
        if RunFlow.enterPortal() then
            setStatus("Entering the boss portal")
            return true, nil
        end
        if RunFlow.portalTarget then
            local target = RunFlow.portalTarget
            RunFlow.portalTarget = nil
            return false, target
        end
    end

    if RunFlow.openChests() then
        setStatus("Opening a chest")
        return true, nil
    end
    if RunFlow.chestTarget then
        local target = RunFlow.chestTarget
        RunFlow.chestTarget = nil
        return false, target
    end

    if RunFlow.skipWave() then
        setStatus("Voting to skip the wave")
        return true, nil
    end

    return false, nil
end

function RunFlow.tick()
    local now = os.clock()

    -- After a claim the lobby path IS the requeue; honour the off switch.
    if RunFlow.afterClaim and flag("FinalSwarmAutoRequeue", true) ~= true then
        setStatus("Run claimed — auto requeue off")
        return true
    end

    local worlds = RunFlow.worlds()
    if not worlds then
        if not RunFlow.worldsNoted then
            RunFlow.worldsNoted = true
            note("WaveData.CampaignWorlds unavailable — lobby queueing disabled (safe mode)", "Warn")
        end
        setStatus("Lobby — world data unavailable")
        return true
    end

    local world, difficulty, state = resolveSelection()
    if state == "scanning" then
        setStatus("Lobby — checking unlocked worlds...")
        return true
    end
    if not world then
        if not RunFlow.noneNoted then
            RunFlow.noneNoted = true
            note("no queueable world (best-unlocked scan found none; no valid FinalSwarmWorld flag)", "Warn")
        end
        setStatus("Lobby — no unlocked world found")
        return true
    end

    if RunFlow.lastChosenWorld ~= world or RunFlow.lastChosenDifficulty ~= difficulty then
        RunFlow.lastChosenWorld = world
        RunFlow.lastChosenDifficulty = difficulty
        RunFlow.queueFailNoted = false
        RunFlow.queueState = "idle"
    end
    RunFlow.chosen = { world = world, difficulty = difficulty }

    local since = now - RunFlow.lastQueueAt
    if since < 120 then
        if RunFlow.queueState == "waiting" then
            -- Success is only declared once the round place actually arrives;
            -- the teleport normally destroys this instance first and the next
            -- one adopts the run. A queue that never arrives is usually a
            -- stuck lobby state: the game's own frame holds an in-flight
            -- request token and stops queueing too (verified live 2026-10-03 —
            -- the lobby pads stayed 0/4 while EnterQueue answered true). Say
            -- so instead of hammering it, which is what churned the state.
            if game.PlaceId == ROUND_PLACE then
                RunFlow.queueState = "arrived"
                setStatus("Round place reached")
            else
                setStatus(string.format(
                    "Queued %s/%s — waiting for the round place (if this sticks, rejoin the lobby)",
                    world, difficulty))
            end
        else
            setStatus(string.format("Lobby — %s/%s not accepted; retrying in %ds (rejoin clears a stuck queue)",
                world, difficulty, math.ceil(120 - since)))
        end
        return true
    end

    RunFlow.lastQueueAt = now
    setStatus(string.format("Lobby — queueing %s/%s", world, difficulty))
    if RunFlow.queue(world, difficulty) then
        RunFlow.queueState = "waiting"
        RunFlow.afterClaim = false
        setStatus(string.format("Queued %s/%s", world, difficulty))
    else
        RunFlow.queueState = "failed"
        if not RunFlow.queueFailNoted then
            RunFlow.queueFailNoted = true
            note("EnterQueue did not accept " .. world .. "/" .. difficulty .. " — retrying every 30 s", "Warn")
        end
    end
    return true
end

function RunFlow.debugState()
    local selection = "-"
    local ds = dataService()
    if ds and type(ds.client.get) == "function" then
        local ok, gameData = pcall(ds.client.get, ds.client, { "gameData" })
        if ok and type(gameData) == "table" then
            selection = tostring(gameData.map or "?") .. "/" .. tostring(gameData.difficulty or "?")
        end
    end
    local wave = RunFlow.wave()
    return string.format(
        "kind=%s adopted=%s queue=%s chosen=%s/%s profile=%s wave=%s skips=%d revives=%d afterClaim=%s",
        RunFlow.placeKind(), tostring(RunFlow.adopted), RunFlow.queueState,
        RunFlow.chosen and tostring(RunFlow.chosen.world) or "-",
        RunFlow.chosen and tostring(RunFlow.chosen.difficulty) or "-",
        selection,
        type(wave) == "number" and tostring(wave) or "-",
        RunFlow.skipCount, RunFlow.reviveAttempts, tostring(RunFlow.afterClaim)
    )
end

function RunFlow.reset()
    RunFlow.adopted = false
    RunFlow.worldsNoted = false
    RunFlow.noneNoted = false
    RunFlow.scanIndex = 0
    RunFlow.scanCandidate = nil
    RunFlow.scanDone = false
    RunFlow.chosen = nil
    RunFlow.lastChosenWorld = nil
    RunFlow.lastChosenDifficulty = nil
    RunFlow.queueState = "idle"
    RunFlow.lastQueueAt = 0
    RunFlow.queueFailNoted = false
    RunFlow.waveCache = nil
    RunFlow.waveAt = 0
    RunFlow.skipCount = 0
    RunFlow.lastSkipAt = 0
    RunFlow.chests = {}
    RunFlow.chestTarget = nil
    RunFlow.portalTarget = nil
    RunFlow.portalFiredAt = nil
    RunFlow.claimStage = 0
    RunFlow.claimAt = 0
    RunFlow.claimNoted = false
    RunFlow.claimStuckNoted = false
    RunFlow.reviveAttempts = 0
    RunFlow.lastReviveAt = 0
    RunFlow.hadCharacter = false
    RunFlow.afterClaim = false
    RunFlow.postClaimAt = 0
    RunFlow.postClaimNoted = false
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
-- Idle kite: nothing to dodge, nothing to collect, nothing to press — hold a
-- polite distance from the nearest enemy so the swarm cannot corner the
-- character while the weapons do the work on their own.
local function kiteStep()
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local nearest = Threat.nearestEnemy()
    if not nearest or nearest.distance >= 30 then
        SafeMove.target = nil
        setStatus(nearest and "Farming — weapons engaging" or "Farming — scanning")
        return
    end
    local away = Vector3.new(
        root.Position.X - nearest.position.X,
        0,
        root.Position.Z - nearest.position.Z
    )
    if away.Magnitude < 0.5 then
        SafeMove.target = nil
        return
    end
    SafeMove.moveTo(root.Position + away.Unit * (40 - nearest.distance))
    setStatus("Kiting the swarm")
end

local function stepFarm()
    local now = os.clock()
    local dt = now - (S.lastTick or now)
    if dt <= 0 or dt > 1 then dt = 0.05 end

    -- 1. survivability: the dodge decision outranks everything else — a
    --    lethal hit makes every later tier moot.
    Threat.tick()
    local dodge = Threat.dodgeVector()
    if dodge then
        SafeMove.moveTo(dodge)
        setStatus("Dodging")
        SafeMove.tick(dt)
        S.lastTick = now
        return
    end

    -- 2. shield upkeep: keep the anti-cheat canary and hit suppression live.
    Shield.ensure()

    -- 3. a pending upgrade offer blocks all progress (verified live: the run
    --    stalls on an unanswered modal), so it outranks run-flow and travel.
    if UpgradeBrain.tick() then
        SafeMove.tick(dt)
        S.lastTick = now
        return
    end

    -- 4. run-flow action, 5. travel to the objective it names, 6. idle kite —
    --    the place decides which of the three applies.
    local kind = RunFlow.placeKind()
    if kind ~= S.placeLast then
        local previous = S.placeLast
        S.placeLast = kind
        S.placeKind = kind
        Threat.reset()
        UpgradeBrain.reset()
        RunFlow.reset()
        if kind == "round" and previous == nil then
            RunFlow.adopted = true
            note("armed inside a live run — adopting it (no queue attempt)", "Warn")
        end
    else
        S.placeKind = kind
    end

    if kind == "lobby" then
        -- No movement business in the lobby; drop any stale destination.
        SafeMove.target = nil
        RunFlow.tick()
    elseif kind == "round" then
        local handled, objective = RunFlow.roundTick()
        if handled then
            -- the tick was spent on a run-flow action
        elseif objective then
            SafeMove.moveTo(objective)
            setStatus("Moving to the objective")
        else
            kiteStep()
        end
    else
        setStatus("Waiting for a place decision")
    end

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
                    "loops %d  |  claims %d  |  picks %d\nskips %d  |  revives %d  |  queues %d  |  ac %d  |  suppressed %d  |  last pick: %s",
                    stats.loops, stats.claims, stats.picks,
                    stats.skips, stats.revives, stats.queues, stats.acViolations, stats.suppressed, stats.lastPick
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
            suppress = flag("FinalSwarmSuppressHits", "Below HP%"),
            skipWaves = flag("FinalSwarmSkipWaves", false),
            skipMax = flag("FinalSwarmSkipMax", 5),
            bossPortal = flag("FinalSwarmBossPortal", true),
            openChests = flag("FinalSwarmOpenChests", true),
            autoClaim = flag("FinalSwarmAutoClaim", true),
            autoRequeue = flag("FinalSwarmAutoRequeue", true),
            bestUnlocked = flag("FinalSwarmBestUnlocked", true),
            world = flag("FinalSwarmWorld", ""),
            difficulty = flag("FinalSwarmDifficulty", ""),
            runMode = flag("FinalSwarmRunMode", "Normal"),
            weightDamage = flag("FinalSwarmWeightDamage", 1),
            weightAttackSpeed = flag("FinalSwarmWeightAttackSpeed", 1),
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
    -- Task 5-8 verification surface: component reads and one-shot actions,
    -- callable from getgenv().__FINALSWARM_FARM without any UI. Names are
    -- stable; the plan's verify steps drive these from get-data-by-code.
    run = {
        placeKind = function() return RunFlow.placeKind() end,
        worlds = function() return RunFlow.worlds() end,
        difficulties = function(world) return RunFlow.difficulties(world) end,
        bestUnlocked = function() return RunFlow.bestUnlocked() end,
        queue = function(world, difficulty) return RunFlow.queue(world, difficulty) end,
        tick = function() return RunFlow.tick() end,
        roundTick = function() return RunFlow.roundTick() end,
        skip = function() return RunFlow.skipWave() end,
        portal = function() return RunFlow.enterPortal() end,
        chests = function() return RunFlow.openChests() end,
        claim = function() return RunFlow.claimRewards() end,
        revive = function() return RunFlow.reviveIfDead() end,
        wave = function() return RunFlow.wave() end,
        state = function() return RunFlow.debugState() end,
        reset = function()
            Threat.reset()
            UpgradeBrain.reset()
            RunFlow.reset()
        end,
    },
    threat = {
        count = Threat.count,
        nearest = Threat.nearestEnemy,
        projectiles = Threat.projectiles,
        dodge = Threat.dodgeVector,
        boss = Threat.bossActive,
        debug = Threat.debug,
    },
    upgrades = {
        offers = UpgradeBrain.readOffers,
        scored = UpgradeBrain.scoredOffers,
        score = function(index)
            for _, offer in ipairs(UpgradeBrain.readOffers()) do
                if offer.index == index then return UpgradeBrain.score(offer) end
            end
            return nil
        end,
        pick = UpgradeBrain.pick,
        tick = function() return UpgradeBrain.tick() end,
        debug = UpgradeBrain.debug,
    },
    debug = function()
        return string.format(
            "status=%s armed=%s place=%s loops=%d claims=%d picks=%d skips=%d revives=%d queues=%d ac=%d suppressed=%d lastPick=%s",
            tostring(S.status), tostring(S.armed), tostring(S.placeKind),
            stats.loops, stats.claims, stats.picks, stats.skips,
            stats.revives, stats.queues, stats.acViolations, stats.suppressed, stats.lastPick
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
