-- Game guard: this module only runs in its own game.
-- game.GameId is the universe id (2124320492), so every place in that
-- game matches. Anywhere else (autoexec, a shared hub, a wrong map
-- entry) it exits before touching anything.
if game.GameId ~= 2124320492 then return end

--[[
    Fight Park — Court Gem Farm (fleet edition)
    Built on EZ-UI-Library (https://github.com/Beastaive22/EZ-UI-Library)
    Executor: Potassium / sUNC

    One script, two roles (Fleet section):
      * Main  — full combat farm: queue, auto-start, TP-kill every round,
                instant requeue. Runs standalone exactly like before.
      * Alt   — zero-combat filler: watches every court's replicated state,
                finds the main account's court, takes a free pad, groups up
                with its side during rounds so the main's multi-target Hit
                lands on the whole cluster from one spot. Never fires
                Swing/Hit, so it can never kill the main or steal a round.

    Coordination is entirely game-state: every client already receives each
    court's queue/match/score/HP through the court Replicator, so the alt
    knows where to go and what to do with no custom messaging and nothing
    in the hot loop waiting on commands.

    All main-side actions go through the game's own remotes (Character.Swing
    / Character.Hit / Courts.Start) with Shield-shaped payloads. The server
    validates range, so we TP into range first and stay inside the court at
    all times — leaving the cage mid-match counts as a "log".

    Rewards: Profile.Results carries {Gems, Deaths, Kills, Damage} per match
    (solo 10 / duo 15 / trio 20 gems on a win).

    Toggle UI: RightShift
]]

local game = game
local getgenv = getgenv

print("[FP-FARM] starting")
if getgenv().__FP_FARM_LOADED then
    pcall(function() getgenv().__FP_FARM_DESTROY() end)
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
SaveManager:Bind(EZ, "FightParkFarmConfigs")
ThemeManager:Bind(EZ, { File = "FightParkFarm_Theme.txt" })
ThemeManager:LoadSaved() -- apply saved theme before the window builds: no colour flash
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

----------------------------------------------------------------
-- Game handles
----------------------------------------------------------------
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Remotes = RS.Remotes
local Courts = workspace:WaitForChild("World"):WaitForChild("Courts")
local lp = Players.LocalPlayer

local COURTS = {
    ["1"] = { name = "Court 1 — Solo", mode = "Solo" },
    ["2"] = { name = "Court 2 — Solo", mode = "Solo" },
    ["3"] = { name = "Court 3 — Duo", mode = "Duo" },
    ["4"] = { name = "Court 4 — Duo", mode = "Duo" },
    ["5"] = { name = "Court 5 — Trio", mode = "Trio" },
}

local TICK = 0.03 -- master loop cadence for both roles

----------------------------------------------------------------
-- Shared state
----------------------------------------------------------------
local RUNNING = true
local log -- assigned once the Stats tab builds its log console
local statusLabel -- live status paragraph on Main
local fleetLabel -- court membership paragraph on Main
local statsLabel -- live session paragraph on Stats

local Stats = {
    startedAt = 0,
    matchesWon = 0, matchesLost = 0, roundsWon = 0,
    gems = 0, kills = 0, deaths = 0, damage = 0,
    hitsAccepted = 0, hitsFired = 0,
}

-- per-court replicated state (the wire protocol), one entry per court
local STATES = {} -- [courtId] = { raw, first, clock, expiry, waiting, Left, Right, waitingList }
local HOOKED = {} -- [courtId] = true once subscribed
local CONNS = {} -- event connections, all disconnected on destroy

local function newCourtState()
    return { raw = nil, first = nil, clock = nil, expiry = nil, waiting = nil,
        Left = {}, Right = {}, waitingList = {} }
end

local function parseMember(entry)
    if entry == "X" or entry == "" then return nil end
    local uid, streak, hp = entry:match("^(%d+)%.([%-%d]*)%.(%d+)$")
    if uid then return { uid = uid, streak = tonumber(streak), hp = tonumber(hp) } end
    uid, streak = entry:match("^(%d+)%.([%-%d]*)$")
    if uid then return { uid = uid, streak = tonumber(streak), hp = nil } end
    return { uid = entry, streak = nil, hp = nil }
end

local function parseStateInto(st, cs)
    cs.raw = st
    cs.first = st:sub(1, 1)
    local parts = st:split(":")
    for i, side in ipairs({ "Left", "Right" }) do
        cs[side] = {}
        local idx = 0
        for entry in (parts[i + 1] or ""):gmatch("[^,]+") do
            idx += 1
            cs[side][idx] = parseMember(entry)
        end
    end
end

local function findMeIn(cs, side, uid)
    uid = uid or lp.UserId
    local key = tostring(uid)
    for _, m in ipairs(cs[side]) do
        if m and m.uid == key then return m end
    end
    return nil
end

local function mySideIn(cs, uid)
    return findMeIn(cs, "Left", uid) and "Left"
        or (findMeIn(cs, "Right", uid) and "Right" or nil)
end

local function enemySideOf(side)
    return side == "Left" and "Right" or "Left"
end

----------------------------------------------------------------
-- Movement helpers
----------------------------------------------------------------
local function rootPart(pl)
    local ch = pl and pl.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function myRoot()
    return rootPart(lp)
end

-- server-pin guard: the game's own teleports (round start/end) can leave the
-- character server-owned for a window — CFrame writes then run client-side
-- only (the "client thinks it TP'd, server disagrees" desync) and every
-- volley whiffs the range check. Humanoid WALKING still replicates in that
-- state, so while pinned we walk to the target and only volley once the walk
-- has actually closed the distance; the first landed hit proves replication
-- and restores the teleport fast path.
local TPV = { held = false, misses = 0, tptest = false, since = 0, lastMove = "tp" }

local function tpTo(pos)
    local root = myRoot()
    if not root then return end
    if TPV.held and not TPV.tptest then
        local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
        if hum then
            hum:MoveTo(pos) -- walking replicates; teleporting does not
            TPV.lastMove = "walk"
        end
        return
    end
    TPV.lastMove = "tp"
    root.CFrame = CFrame.new(pos)
    root.AssemblyLinearVelocity = Vector3.zero -- no fling -> no desync
end

-- stand on a pad: 3 studs above its top
local function padPos(pad)
    return pad.Position + Vector3.new(0, pad.Size.Y * 0.5 + 2.5, 0)
end

-- find a pad we can queue on: free start pads first, then the waiting line
local function findQueuePad(court)
    local spots = court:FindFirstChild("Spots")
    if not spots then return nil end
    for _, side in ipairs({ "Left", "Right" }) do
        local f = spots:FindFirstChild(side)
        if f then
            for _, pad in ipairs(f:GetChildren()) do
                if pad:IsA("BasePart") and pad:GetAttribute("Occupied") == false then
                    return pad
                end
            end
        end
    end
    local waiting = spots:FindFirstChild("Waiting")
    if waiting then
        for _, pad in ipairs(waiting:GetChildren()) do
            local part = pad:IsA("BasePart") and pad or pad:FindFirstChildWhichIsA("BasePart")
            if part and part:GetAttribute("Occupied") == false then
                return part
            end
        end
    end
    return nil
end

-- only walk to a pad we're not already standing on (no TP churn) — unless
-- we're server-pinned, in which case keep probing or the claim never lands
local function tpToPadIfFar(pad)
    local pos = padPos(pad)
    local root = myRoot()
    if not root or TPV.held or (root.Position - pos).Magnitude > 2 then
        tpTo(pos)
    end
end

----------------------------------------------------------------
-- Court bounds (the cage) — never TP outside it: leaving mid-match = "log"
----------------------------------------------------------------
local function courtAnchor(court)
    local base = court:FindFirstChild("Base")
    local floor = base and base:FindFirstChild("Floor")
    return floor and floor.Position or nil
end

local function insideCourt(court, pos, margin)
    local anchor = courtAnchor(court)
    if not anchor then return true end -- unknown geometry: fall back to old behavior
    return (pos - anchor).Magnitude <= (margin or 45)
end

-- this client's spawn marker on a side, ranked by UserId among that side's
-- members — pre-positioning there during the inter-round gap means the
-- server's round-start teleport lands us (nearly) where we already are
local function mySpawnPart(court, side, cs)
    local spots = court:FindFirstChild("Spots")
    local spawns = spots and spots:FindFirstChild("Spawns")
    local f = spawns and spawns:FindFirstChild(side)
    if not f then return nil end
    local uids = {}
    for _, m in ipairs(cs[side]) do
        if m then table.insert(uids, tonumber(m.uid) or 0) end
    end
    table.sort(uids)
    local myrank
    for i, u in ipairs(uids) do
        if u == lp.UserId then myrank = i break end
    end
    if not myrank then return nil end
    local parts = {}
    for _, sp in ipairs(f:GetChildren()) do
        if sp:IsA("BasePart") then table.insert(parts, sp) end
    end
    table.sort(parts, function(a, b) return a.Name < b.Name end)
    return parts[myrank] or parts[#parts]
end

-- centroid of a side's spawn markers (static, always-in-bounds target)
local function spawnCentroid(court, side)
    local spots = court:FindFirstChild("Spots")
    local spawns = spots and spots:FindFirstChild("Spawns")
    local f = spawns and spawns:FindFirstChild(side)
    if not f then return nil end
    local pts = {}
    for _, sp in ipairs(f:GetChildren()) do
        if sp:IsA("BasePart") then table.insert(pts, sp.Position) end
    end
    if #pts == 0 then return nil end
    local sum = Vector3.zero
    for _, v in ipairs(pts) do sum += v end
    return sum / #pts
end

-- main-side gap pre-positioning: stand 3.5 studs off the enemy spawn cluster
-- so the round-start burst needs no TP when the enemies revive right there.
-- Spawn markers sit AT floor level (Y=500) — the root must ride ~3 above them
-- or the character gets written into the ground (clip + jitter loop).
local function prePosition(court, eside)
    local c = spawnCentroid(court, eside)
    local root = myRoot()
    if not c or not root then return end
    local away = root.Position - c
    away = Vector3.new(away.X, 0, away.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(0, 0, 1) end
    local target = c + away.Unit * 3.5 + Vector3.new(0, 3, 0)
    if insideCourt(court, target) and (TPV.held or (root.Position - target).Magnitude > 2) then
        tpTo(target)
    end
end

-- closest Left/Right start pad to a position, any occupancy — lets us HOLD our
-- pad when the queue state briefly blips us out during requeue
local function nearestStartPad(court, pos, maxDist)
    local spots = court:FindFirstChild("Spots")
    if not spots then return nil end
    local best, bestD = nil, maxDist
    for _, side in ipairs({ "Left", "Right" }) do
        local f = spots:FindFirstChild(side)
        if f then
            for _, pad in ipairs(f:GetChildren()) do
                if pad:IsA("BasePart") then
                    local d = (pad.Position - pos).Magnitude
                    if d < bestD then best, bestD = pad, d end
                end
            end
        end
    end
    return best
end

-- score readout: state raw is "<mode><Lscore><Rscore><survivor>..."
local function sideScore(cs, side)
    if not cs.raw or #cs.raw < 3 then return 0 end
    return tonumber(side == "Left" and cs.raw:sub(2, 2) or cs.raw:sub(3, 3)) or 0
end

local function matchOver(cs)
    return sideScore(cs, "Left") >= 2 or sideScore(cs, "Right") >= 2
end

-- results phase: stand on a free start pad (own side first) so the court
-- queues us the instant it releases — no extra hop from the winner/loser pad
local function claimStartPad(court, side)
    local spots = court:FindFirstChild("Spots")
    if not spots then return end
    local root = myRoot()
    for _, s in ipairs({ side, side == "Left" and "Right" or "Left" }) do
        local f = spots:FindFirstChild(s)
        if f then
            for _, pad in ipairs(f:GetChildren()) do
                if pad:IsA("BasePart") and pad:GetAttribute("Occupied") == false then
                    tpToPadIfFar(pad)
                    return
                end
            end
        end
    end
end

----------------------------------------------------------------
-- Main-role combat
----------------------------------------------------------------
local function playersForMembers(members)
    local out = {}
    for _, m in ipairs(members) do
        local p = Players:GetPlayerByUserId(tonumber(m.uid))
        if p and rootPart(p) then table.insert(out, p) end
    end
    return out
end

-- burst: Swing+Hit pairs at the locked targets; stops the instant the live
-- state shows every locked target dead
local function burst(courtId, eside, enemies)
    local targets = playersForMembers(enemies)
    if #targets == 0 then return end
    local payload = #targets == 1 and targets[1] or targets
    local burstSize = EZ.Flags.BurstSize or 15
    local burstGap = EZ.Flags.BurstGap or 0
    local cs = STATES[courtId]
    for i = 1, burstSize do
        Remotes.Character.Swing:FireServer(1)
        Remotes.Character.Hit:FireServer(payload)
        Stats.hitsFired += 1
        -- live death check every 3 pairs — the snapshot hp in `enemies` is
        -- stale, the replicated court state is not
        if cs and i % 3 == 0 then
            local allDead = true
            for _, m in ipairs(cs[eside]) do
                if m and m.hp and m.hp > 0 then
                    allDead = false
                    break
                end
            end
            if allDead then break end
        end
        if burstGap > 0 then task.wait(burstGap) end
    end
end

-- centroid of the living, in-bounds members (used for chase TP + settle)
local function enemyCentroid(court, members)
    local pts = {}
    for _, m in ipairs(members) do
        local r = rootPart(Players:GetPlayerByUserId(tonumber(m.uid)))
        if r and insideCourt(court, r.Position) then table.insert(pts, r.Position) end
    end
    if #pts == 0 then return nil end
    local sum = Vector3.zero
    for _, v in ipairs(pts) do sum += v end
    return sum / #pts
end

-- TP to ~3.5 studs (planar) off the living enemy centroid; targets outside the
-- cage are refused, and TPs already in range are skipped entirely (fewer
-- writes = less desync)
local function tpToEnemies(court, enemies)
    local root = myRoot()
    if not root then return end
    local centroid = enemyCentroid(court, enemies)
    if not centroid then return end
    local away = root.Position - centroid
    away = Vector3.new(away.X, 0, away.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(0, 0, 1) end
    local target = centroid + away.Unit * 3.5
    if insideCourt(court, target) and (TPV.held or (root.Position - target).Magnitude > 3) then
        tpTo(target)
    end
end

local engine = { phase = "idle", note = "", lastRoundKey = nil, lastStart = 0 }

local function farmTick(courtId)
    local court = Courts:FindFirstChild(courtId)
    local cs = STATES[courtId]
    if not court or not cs then
        engine.phase = "no court"
        return
    end

    local queued = mySideIn(cs)
    if queued and not engine.wasQueued then
        -- the server just registered our queue: pad claims replicate again
        engine.holdSince = nil
        TPV.held = false
        TPV.tptest = false
    end
    engine.wasQueued = queued and true or false

    if not queued then
        engine.lastRoundKey = nil
        if cs.first == "2" then
            engine.phase = "match running (not in it)"
        elseif cs.first == "1" then
            engine.phase = "queue full (not in it)"
        elseif cs.waitingList[lp.UserId] then
            engine.phase = "in line — waiting pad"
        elseif EZ.Flags.AutoFindPad then
            -- hold our pad through queue-state blips: only re-pick when we're
            -- genuinely not on/near a start pad (winner-pad TP, walkback etc.)
            local root = myRoot()
            local hold = nil
            if root then
                local near = nearestStartPad(court, root.Position, 5)
                if near and (near:GetAttribute("Occupied") ~= true
                    or (padPos(near) - root.Position).Magnitude < 2) then
                    hold = near
                end
            end
                        local pad = hold or findQueuePad(court)
            if hold then
                engine.holdSince = engine.holdSince or tick()
                if not TPV.held and tick() - engine.holdSince > 1.5 then
                    -- on/near a pad but still not queued: the server can't see
                    -- our position — switch to walk mode
                    TPV.held = true
                    TPV.since = tick()
                end
            else
                engine.holdSince = nil
            end
            if pad then
                engine.phase = "taking a pad"
                tpToPadIfFar(pad)
            else
                engine.phase = "court full — no free pad"
            end
        else
            engine.phase = "stand on a pad"
        end
        return
    end

    -- queued on this court
    if cs.first == "0" then
        engine.phase = "queued — waiting for opponent"
        return
    end

    if cs.first == "1" then
        -- fire Start instantly; retry at most every 0.5s if the state doesn't flip
        if tick() - engine.lastStart > 0.5 then
            engine.lastStart = tick()
            if EZ.Flags.AutoStart then
                Remotes.Courts.Start:FireServer()
            end
        end
        engine.phase = EZ.Flags.AutoStart and "queue full — starting" or "queue full — press Start"
        return
    end

    -- active match
    local eside = enemySideOf(queued)
    local meM = findMeIn(cs, queued)

    -- stranded outside (respawn at map spawn): get back inside before anything
    local rootMe = myRoot()
    if rootMe and not insideCourt(court, rootMe.Position) then
        local anchor = courtAnchor(court)
        if anchor then
            engine.phase = "returning to court"
            tpTo(anchor + Vector3.new(0, 5.5, 0))
            return
        end
    end
    local enemies, alive = {}, {}
    for _, m in ipairs(cs[eside]) do
        if m then table.insert(enemies, m) end
        if m and m.hp and m.hp > 0 then table.insert(alive, m) end
    end
    if #enemies == 0 then
        engine.phase = "no enemies — waiting reset"
        engine.lastRoundKey = nil
        return
    end

    if meM and meM.hp == 0 then
        engine.lastRoundKey = nil
        if matchOver(cs) then
            engine.phase = "match over — claiming pad"
            claimStartPad(court, queued)
        else
            engine.phase = "dead — next round soon"
            prePosition(court, eside)
        end
        return
    end

    if #alive == 0 then
        if engine.phase == "fighting" then
            Stats.roundsWon += 1
        end
        engine.lastRoundKey = nil
        if matchOver(cs) then
            engine.phase = "match over — claiming pad"
            claimStartPad(court, queued)
        else
            engine.phase = "round won — waiting reset"
            prePosition(court, eside)
        end
        return
    end

    -- only chase enemies that are actually inside the cage (a respawned
    -- member waiting at map spawn must not lure us out of bounds)
    local chase = {}
    for _, m in ipairs(alive) do
        local r = rootPart(Players:GetPlayerByUserId(tonumber(m.uid)))
        if r and insideCourt(court, r.Position) then table.insert(chase, m) end
    end
    if #chase == 0 then
        engine.phase = "enemies outside — waiting"
        engine.lastRoundKey = nil
        return
    end

    -- fresh round? (all enemy HP back to full) -> TP onto them, settle, burst
    local fresh = true
    for _, m in ipairs(alive) do
        if m.hp ~= 1000 then fresh = false end
    end
    local key = table.concat((function()
        local t = {}
        for _, m in ipairs(alive) do table.insert(t, m.uid) end
        return t
    end)(), ",") .. "@" .. tostring(fresh)

    if fresh and engine.lastRoundKey ~= key then
        engine.lastRoundKey = key
        engine.phase = "TP + burst"
        -- fire the moment the enemies' positions are stable (server teleport
        -- replicated) — no fixed floor. TP and burst happen in the same frame.
        local settleT0 = tick()
        local snap = enemyCentroid(court, chase)
        local stableAt = nil
        while tick() - settleT0 < 0.5 do
            local c = enemyCentroid(court, chase)
            if snap and c and (c - snap).Magnitude < 0.5 then
                stableAt = stableAt or tick()
                if tick() - stableAt >= 0.06 then break end
            else
                stableAt = nil
                if c then snap = c end
            end
            task.wait(TICK)
        end
        if not TPV.held then
            tpToEnemies(court, chase)
        end
    end

    -- burst until dead. While server-pinned, tpTo walks (Humanoid channel) and
    -- we only volley once the walk has actually closed the distance — the
    -- local root tracks the server while walking, so local distance is the
    -- true one. A landed volley after a walk arms a TP test; a landed volley
    -- after a TP proves the fast path again.
    local before = Stats.hitsAccepted
    if not TPV.held then
        tpToEnemies(court, chase)
        burst(courtId, eside, chase)
        local t0 = tick()
        while Stats.hitsAccepted == before and tick() - t0 < 0.08 do
            task.wait(TICK)
        end
        if Stats.hitsAccepted > before then
            TPV.misses = 0
            engine.phase = "fighting"
        else
            TPV.misses += 1
            if TPV.misses >= 2 then
                TPV.held = true
                TPV.since = tick()
            end
            tpToEnemies(court, chase)
            engine.phase = TPV.held and "fighting (server pin — walking)" or "fighting"
        end
    else
        tpToEnemies(court, chase) -- walks, or CFrame when tptest is armed
        local c = enemyCentroid(court, chase)
        local root = myRoot()
        if c and root and (root.Position - c).Magnitude < 5 then
            burst(courtId, eside, chase)
            local t0 = tick()
            while Stats.hitsAccepted == before and tick() - t0 < 0.08 do
                task.wait(TICK)
            end
            if Stats.hitsAccepted > before then
                if TPV.lastMove == "tp" then
                    TPV.held = false -- TP proven: full speed
                    TPV.tptest = false
                    TPV.misses = 0
                    engine.phase = "fighting"
                else
                    TPV.tptest = true -- walking proved range; test the TP next
                    TPV.misses = 0
                    engine.phase = "fighting (server pin — testing TP)"
                end
            else
                TPV.misses += 1
                if TPV.misses >= 2 then
                    TPV.tptest = false -- TP still pinned; back to walking
                    TPV.misses = 0
                end
                engine.phase = "fighting (server pin — walking)"
            end
        else
            engine.phase = "fighting (server pin — walking)"
        end
    end
end

----------------------------------------------------------------
-- Alt-role logic (zero combat)
----------------------------------------------------------------
local ALT = { phase = "idle", court = nil, mainUid = nil, sawFullAt = nil,
    huddleAt = 0, huddled = false }

local function resolveMainUid()
    if ALT.mainUid then return ALT.mainUid end
    local name = EZ.Flags.MainAccount
    if not name or name == "" or name:sub(1, 1) == "@" then return nil end
    local p = Players:FindFirstChild(name)
    if p and p:IsA("Player") then
        ALT.mainUid = p.UserId
        return ALT.mainUid
    end
    return nil
end

local function findMainCourt(uid)
    for id, cs in pairs(STATES) do
        if mySideIn(cs, uid) then return id end
    end
    for id, cs in pairs(STATES) do
        if cs.waitingList[uid] then return id end
    end
    return nil
end

-- group anchor: centroid of my side's living members. Members outside the
-- cage (respawned) are ignored so the anchor stays inside. Alone on the side
-- -> hold position (no TP at all); with teammates -> tiny planar per-uid
-- spread at root height, so the cluster stays inside the main's hit range.
local function huddleTarget(court, cs, side)
    local pts = {}
    for _, m in ipairs(cs[side]) do
        if m and m.hp and m.hp > 0 then
            local r = rootPart(Players:GetPlayerByUserId(tonumber(m.uid)))
            if r and insideCourt(court, r.Position) then table.insert(pts, r.Position) end
        end
    end
    if #pts == 0 then return nil end
    local sum = Vector3.zero
    for _, v in ipairs(pts) do sum += v end
    local centroid = sum / #pts
    if #pts == 1 then
        return centroid
    end
    local uid = lp.UserId
    local ox = ((uid % 5) - 2) * 1.0
    local oz = ((math.floor(uid / 5) % 5) - 2) * 1.0
    return centroid + Vector3.new(ox, 0, oz)
end

local function altTick()
    local uid = resolveMainUid()
    if not uid then
        ALT.phase = "set Main Username (Fleet)"
        return
    end

    local courtId = findMainCourt(uid)
    if not courtId then
        ALT.court = nil
        ALT.phase = "main not queued — standing by"
        ALT.huddled = false
        return
    end
    ALT.court = courtId

    local court = Courts:FindFirstChild(courtId)
    local cs = STATES[courtId]
    if not court or not cs then return end

    local side = mySideIn(cs)

    if side and not ALT.wasSide then
        -- the server just registered our queue: pad claims replicate again
        ALT.holdSince = nil
        TPV.held = false
        TPV.tptest = false
    end
    ALT.wasSide = side and true or false

    if not side then
        ALT.huddled = false
        if cs.first == "2" then
            ALT.phase = "match running — standing by"
        elseif cs.waitingList[lp.UserId] then
            ALT.phase = "in line — waiting pad"
        elseif EZ.Flags.AutoFindPad then
            -- same pad-hold as the main: never TP off a pad over a state blip
            local root = myRoot()
            local hold = nil
            if root then
                local near = nearestStartPad(court, root.Position, 5)
                if near and (near:GetAttribute("Occupied") ~= true
                    or (padPos(near) - root.Position).Magnitude < 2) then
                    hold = near
                end
            end
            local pad = hold or findQueuePad(court)
            if hold then
                ALT.holdSince = ALT.holdSince or tick()
                if not TPV.held and tick() - ALT.holdSince > 1.5 then
                    -- on/near a pad but still not queued: the server can't see
                    -- our position — switch to walk mode
                    TPV.held = true
                    TPV.since = tick()
                end
            else
                ALT.holdSince = nil
            end
            if pad then
                ALT.phase = "taking pad on court " .. courtId
                tpToPadIfFar(pad)
            else
                ALT.phase = "court full — no free pad"
            end
        else
            ALT.phase = "stand on a pad (court " .. courtId .. ")"
        end
        return
    end

    if cs.first == "0" then
        ALT.sawFullAt = nil
        ALT.phase = "queued — waiting opponent"
        return
    end

    if cs.first == "1" then
        -- backup start: only if the main hasn't fired within 0.5s
        if not ALT.sawFullAt then ALT.sawFullAt = tick() end
        if EZ.Flags.AltAutoStart and tick() - ALT.sawFullAt > 0.5 then
            ALT.sawFullAt = math.huge
            Remotes.Courts.Start:FireServer()
            ALT.phase = "backup start fired"
        else
            ALT.phase = "queue full — main starting"
        end
        return
    end
    ALT.sawFullAt = nil

    -- active match: huddle with my side, never attack
    local meM = findMeIn(cs, side)
    -- match decided (either side at 2 wins): walk to a free start pad during
    -- the results phase so we queue the instant the court releases — this
    -- covers alive, dead (once respawned) and respawned-outside states
    if matchOver(cs) then
        ALT.huddled = false
        ALT.phase = "match over — claiming pad"
        claimStartPad(court, side)
        return
    end
    -- stranded outside (respawn at map spawn): get back inside even while
    -- dead, so the respawned body is already in the court when the next
    -- round starts and the main never waits on us
    local root0 = myRoot()
    if root0 and not insideCourt(court, root0.Position) then
        -- respawned at map spawn: walk back to OUR OWN spawn marker (uid-ranked)
        -- so the server's round-start teleport lands us where we already stand
        local spawnPart = mySpawnPart(court, side, cs)
        local anchor = courtAnchor(court)
        local target = (spawnPart and spawnPart.Position + Vector3.new(0, 3, 0))
            or (anchor and anchor + Vector3.new(0, 5.5, 0))
        if target then
            ALT.phase = "returning to spawn"
            if TPV.held or (root0.Position - target).Magnitude > 2 then
                tpTo(target)
            end
            return
        end
    end
    if meM and meM.hp == 0 then
        ALT.phase = "dead — next round soon"
        ALT.huddled = false
        return
    end

    local fresh = true
    for _, m in ipairs(cs[side]) do
        if m and m.hp ~= 1000 then fresh = false end
    end
    if fresh and not ALT.huddled then
        ALT.huddled = true
        ALT.huddleAt = tick() + 0.05 -- let the server's spawn TP land first
    elseif not fresh then
        ALT.huddled = false
    end

    local mainSide = mySideIn(cs, uid)

    if ALT.huddled and tick() >= ALT.huddleAt then
        local target = huddleTarget(court, cs, side)
        if target and not insideCourt(court, target) then
            local anchor = courtAnchor(court)
            target = anchor and (anchor + Vector3.new(0, 5.5, 0)) or nil
        end
        if target and root0 and (TPV.held or (root0.Position - target).Magnitude > 1.5) then
            tpTo(target)
        end
    end

    if mainSide == side then
        ALT.phase = "teammate — holding position"
    else
        ALT.phase = "enemy — grouped for the main"
    end
end

----------------------------------------------------------------
-- Master loop
----------------------------------------------------------------
local function masterLoop()
    while RUNNING do
        getgenv().__FP_BEAT = (getgenv().__FP_BEAT or 0) + 1
        local ok, err = pcall(function()
            if not EZ.Flags.FarmEnabled then
                engine.phase = engine.phase == "off" and engine.phase or "off"
                ALT.phase = ALT.phase == "off" and ALT.phase or "off"
                return
            end
            if (EZ.Flags.ClientRole or "Main") == "Alt" then
                altTick()
            else
                farmTick(EZ.Flags.FarmCourt or "1")
            end
        end)
        if not ok then
            engine.phase = "error: " .. tostring(err)
            ALT.phase = "error: " .. tostring(err)
        end
        -- periodic un-pin test: give the fast path another chance after a hold
if TPV.held and tick() - TPV.since > 6 then
    TPV.held = false
    TPV.tptest = false
    TPV.misses = 0
end
-- phase history (stall diagnostics)
        local hist = getgenv().__FP_HIST
        if hist then
            local stamp = string.format("%06.1f", tick() % 100000)
            local lastE = hist.eng[#hist.eng]
            if not lastE or lastE.p ~= engine.phase then
                table.insert(hist.eng, { t = stamp, p = engine.phase })
                if #hist.eng > 40 then table.remove(hist.eng, 1) end
            end
            local lastA = hist.alt[#hist.alt]
            if not lastA or lastA.p ~= ALT.phase then
                table.insert(hist.alt, { t = stamp, p = ALT.phase })
                if #hist.alt > 40 then table.remove(hist.alt, 1) end
            end
        end
        task.wait(TICK)
    end
end

----------------------------------------------------------------
-- Hooks: court subscriptions + results + accepted-hit accounting
----------------------------------------------------------------
local function hookCourt(court)
    local id = court.Name
    if HOOKED[id] or not court:FindFirstChild("Replicator") then return end
    HOOKED[id] = true
    STATES[id] = newCourtState()
    local cs = STATES[id]
    table.insert(CONNS, court.Replicator.OnClientEvent:Connect(function(clock, st, waiting)
        if st then parseStateInto(st, cs) end
        if clock then
            local c, e = clock:match("(%d+):(%d+)")
            if c then cs.clock, cs.expiry = tonumber(c), tonumber(e) end
        end
        if waiting ~= nil then
            cs.waiting = waiting
            cs.waitingList = {}
            for wuid in waiting:gmatch("[^,]+") do
                cs.waitingList[tonumber(wuid)] = true
            end
        end
    end))
    court.Replicator:FireServer()
end

local function hookAllCourts()
    for _, court in ipairs(Courts:GetChildren()) do
        hookCourt(court)
    end
    Courts.ChildAdded:Connect(function(c)
        task.wait(0.5)
        if c:IsA("Folder") then hookCourt(c) end
    end)
end

local function hookRemotes()
    table.insert(CONNS, Remotes.Profile.Results.OnClientEvent:Connect(function(kind, mode, score, extra)
        if typeof(extra) ~= "table" then extra = {} end
        if kind == "w" then
            Stats.matchesWon += 1
            Stats.gems += tonumber(extra.Gems) or 0
            Stats.kills += tonumber(extra.Kills) or 0
            Stats.damage += tonumber(extra.Damage) or 0
            local msg = string.format("Match WON (%s) %s — +%d gems", mode or "?", score or "?", extra.Gems or 0)
            if log then log.Success(msg) end
            if EZ.Flags.NotifyWins then
                EZ:Notify({ Title = "Match won", Content = msg, Duration = 4, Type = "success" })
            end
        else
            Stats.matchesLost += 1
            Stats.deaths += tonumber(extra.Deaths) or 0
            local msg = string.format("Match lost (%s) %s", mode or "?", score or "?")
            if log then log.Warn(msg) end
        end
    end))

    table.insert(CONNS, Remotes.Character.Hit.OnClientEvent:Connect(function(_, targets, res)
        if not res or not res:find("H") then return end
        local list = typeof(targets) == "table" and targets or { targets }
        for _, t in ipairs(list) do
            if t ~= lp then -- hits I receive don't count as landed
                Stats.hitsAccepted += 1
                break
            end
        end
    end))
end

----------------------------------------------------------------
-- Window
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "Fight Park — Court Farm",
    SubTitle = lp.Name,
    ToggleKey = Enum.KeyCode.RightShift,
    Width = 640,
    Height = 460,
})

QuickBar:Bind(EZ, Window)
NotifHistory:Bind(EZ, Window)

local TabMain = Window:AddTab("Main", "swords")
local TabStats = Window:AddTab("Stats", "chart-line")

----------------------------------------------------------------
-- MAIN tab
----------------------------------------------------------------
local secStatus = TabMain:AddSection("Status")
statusLabel = secStatus:AddParagraph({ Title = "Live", Content = "off" })
fleetLabel = secStatus:AddParagraph({ Title = "Court Members", Content = "-" })

local ctlLeft = TabMain:AddLeftGroupbox("Farm", "activity")
ctlLeft:AddToggle("FarmEnabled", {
    Text = "Enable Auto Farm",
    Default = false,
    Tooltip = "Runs your role's loop: Main farms matches, Alt follows the main and fills courts",
})
ctlLeft:AddDropdown("FarmCourt", {
    Text = "Court (Main role)",
    Values = {
        ["1"] = "Court 1 — Solo (10 gems)",
        ["2"] = "Court 2 — Solo (10 gems)",
        ["3"] = "Court 3 — Duo (15 gems)",
        ["4"] = "Court 4 — Duo (15 gems)",
        ["5"] = "Court 5 — Trio (20 gems)",
    },
    Default = "1",
    Tooltip = "Which court the main queues on. Alts ignore this and follow the main automatically",
})
ctlLeft:AddToggle("AutoStart", {
    Text = "Auto Start Match",
    Default = true,
    Tooltip = "Fires the Start remote the moment the queue fills (both pads taken)",
})
ctlLeft:AddToggle("AutoFindPad", {
    Text = "Auto Find Pad",
    Default = true,
    Tooltip = "When not in a match, TP onto a free start pad (or the waiting line when all are taken)",
})
ctlLeft:AddToggle("NotifyWins", {
    Text = "Notify On Wins",
    Default = true,
})

local ctlFleet = TabMain:AddLeftGroupbox("Fleet", "users")
ctlFleet:AddDropdown("ClientRole", {
    Text = "Client Role",
    Values = { "Main", "Alt" },
    Default = "Main",
    Tooltip = "Main = combat farm. Alt = zero-combat filler that follows the main and groups up",
})
ctlFleet:AddPlayerSelector("MainAccount", {
    Text = "Main Account",
    ExcludeSelf = true,
    Multi = false,
    Callback = function()
        ALT.mainUid = nil -- re-resolve when the selection changes
    end,
})
ctlFleet:AddToggle("AltAutoStart", {
    Text = "Alt Backup Start",
    Default = true,
    Tooltip = "Alts only: fire Start if the queue stays full for 0.5s without the main starting it",
})

local ctlRight = TabMain:AddRightGroupbox("Tuning", "settings-2")
ctlRight:AddSlider("BurstSize", {
    Text = "Burst Size",
    Min = 5, Max = 40, Default = 15, Increment = 1,
    Tooltip = "Swing+Hit pairs fired per burst — server accepts ~9-10 of an instant burst",
})
ctlRight:AddSlider("BurstGap", {
    Text = "Burst Gap",
    Min = 0, Max = 0.3, Default = 0, Increment = 0.01, Suffix = "s",
    Tooltip = "Pause between pairs inside a burst; 0 = all at once (fastest, ~10 accepted)",
})

ctlRight:AddDivider()
ctlRight:AddButton({
    Text = "Teleport To Court Pad",
    Tooltip = "Moves you onto the selected court's first free pad right now",
    Callback = function()
        local court = Courts:FindFirstChild(EZ.Flags.FarmCourt or "1")
        if not court then return end
        local pad = findQueuePad(court)
        if pad then
            tpTo(padPos(pad))
            if log then log.Info("Teleported to " .. court.Name .. " pad") end
        elseif log then
            log.Warn("No free pad on court " .. court.Name)
        end
    end,
})

----------------------------------------------------------------
-- STATS tab
----------------------------------------------------------------
local secSession = TabStats:AddSection("Session")
statsLabel = secSession:AddParagraph({ Title = "Session", Content = "-" })

local secLog = TabStats:AddSection("Activity")
log = secLog:AddLog({ Height = 140, MaxLines = 80 })
log.Info("Fight Park court farm loaded (fleet edition)")

secSession:AddButton({
    Text = "Reset Session Stats",
    Callback = function()
        Stats.startedAt = tick()
        Stats.matchesWon, Stats.matchesLost, Stats.roundsWon = 0, 0, 0
        Stats.gems, Stats.kills, Stats.deaths, Stats.damage = 0, 0, 0
        Stats.hitsAccepted, Stats.hitsFired = 0, 0
        if log then log.Info("Session stats reset") end
    end,
})

----------------------------------------------------------------
-- Dashboards
----------------------------------------------------------------
local function memberLine(cs, side)
    local txt = {}
    for _, m in ipairs(cs[side]) do
        if m then
            local p = Players:GetPlayerByUserId(tonumber(m.uid))
            local name = p and p.Name or m.uid
            if m.hp then
                table.insert(txt, ("%s %s"):format(name, m.hp > 0 and tostring(math.floor(m.hp / 10)) or "dead"))
            else
                table.insert(txt, name)
            end
        end
    end
    return table.concat(txt, " | ")
end

task.spawn(function()
    while RUNNING do
        pcall(function()
            local isAlt = (EZ.Flags.ClientRole or "Main") == "Alt"
            local lines = {}

            if isAlt then
                local phaseText = EZ.Flags.FarmEnabled and ALT.phase or "off"
                local mainName = (EZ.Flags.MainAccount and EZ.Flags.MainAccount ~= "" and EZ.Flags.MainAccount:sub(1, 1) ~= "@") and EZ.Flags.MainAccount or "(pick a Main Account)"
                table.insert(lines, ("Alt: %s — %s"):format(EZ.Flags.FarmEnabled and "ON" or "OFF", phaseText))
                table.insert(lines, ("Following: %s%s"):format(mainName,
                    ALT.court and (" → court " .. ALT.court) or ""))
                if ALT.court and STATES[ALT.court] then
                    local cs = STATES[ALT.court]
                    local meta = COURTS[ALT.court] or { name = "Court " .. ALT.court, mode = "?" }
                    table.insert(lines, ("Court: %s"):format(meta.name))
                    if cs.first == "2" then
                        local side = mySideIn(cs)
                        if side then
                            table.insert(lines, ("My side: %s"):format(memberLine(cs, side)))
                        end
                    end
                end
            else
                local courtId = EZ.Flags.FarmCourt or "1"
                local meta = COURTS[courtId] or { name = "Court " .. courtId, mode = "?" }
                local cs = STATES[courtId]
                local phaseText = EZ.Flags.FarmEnabled and engine.phase or "off"
                table.insert(lines, ("Farm: %s — %s"):format(EZ.Flags.FarmEnabled and "ON" or "OFF", phaseText))
                table.insert(lines, ("Court: %s"):format(meta.name))
                if cs and cs.first == "2" then
                    local side = mySideIn(cs)
                    local scoreL, scoreR = cs.raw:sub(2, 2), cs.raw:sub(3, 3)
                    table.insert(lines, ("Score: %s : %s | round clock: %ss"):format(scoreL, scoreR, cs.clock or "?"))
                    local eside = side and enemySideOf(side)
                    if eside then
                        table.insert(lines, ("Enemy: %s"):format(memberLine(cs, eside)))
                    end
                elseif cs and cs.first == "1" then
                    table.insert(lines, "Queue full — ready to start")
                elseif cs and cs.first == "0" then
                    table.insert(lines, "Queue: waiting for players")
                end
            end
            statusLabel:Set(table.concat(lines, "\n"))

            -- court membership panel (both roles)
            local panelCourt = isAlt and ALT.court or (EZ.Flags.FarmCourt or "1")
            local pcs = panelCourt and STATES[panelCourt]
            if pcs and pcs.raw then
                local plines = {
                    ("%s — %s"):format(COURTS[panelCourt] and COURTS[panelCourt].name or ("Court " .. panelCourt),
                        pcs.first == "2" and "match active" or pcs.first == "1" and "queue full" or "idle"),
                    ("L: %s"):format(memberLine(pcs, "Left")),
                    ("R: %s"):format(memberLine(pcs, "Right")),
                }
                if #pcs.waitingList > 0 then
                    local names = {}
                    for wuid in pairs(pcs.waitingList) do
                        local p = Players:GetPlayerByUserId(wuid)
                        table.insert(names, p and p.Name or tostring(wuid))
                    end
                    table.insert(plines, "Line: " .. table.concat(names, ", "))
                end
                fleetLabel:Set(table.concat(plines, "\n"))
            else
                fleetLabel:Set("-")
            end

            local mins = (tick() - Stats.startedAt) / 60
            local acc = Stats.hitsFired > 0 and (100 * Stats.hitsAccepted / Stats.hitsFired) or 0
            local rate = mins > 0.2 and (Stats.gems / mins) or 0
            statsLabel:Set(table.concat({
                ("Wins: %d | Losses: %d | Rounds: %d"):format(Stats.matchesWon, Stats.matchesLost, Stats.roundsWon),
                ("Gems: %d (%.0f/min)"):format(Stats.gems, rate),
                ("Kills: %d | Deaths: %d"):format(Stats.kills, Stats.deaths),
                ("Hits: %d/%d (%.0f%%)"):format(Stats.hitsAccepted, Stats.hitsFired, acc),
                ("Session: %dm %02ds"):format(math.floor(mins), math.floor((mins % 1) * 60)),
            }, "\n"))
        end)
        task.wait(0.4)
    end
end)

----------------------------------------------------------------
-- Boot
----------------------------------------------------------------
hookRemotes()
hookAllCourts()
Stats.startedAt = tick()
getgenv().__FP_HIST = { eng = {}, alt = {} }
task.spawn(masterLoop)

-- QuickBar: floating dock with your most-used toggles, visible while the window is hidden
pcall(function()
    QuickBar:Pin("FarmEnabled", { Icon = "swords" })
    QuickBar:PinButton("Teleport To Court", { Icon = "map-pin", Callback = function()
        local court = Courts:FindFirstChild(EZ.Flags.FarmCourt or "1")
        local pad = court and findQueuePad(court)
        if pad then tpTo(padPos(pad)) end
    end })
end)

-- Config autoload: restores your saved toggles/configs on launch
pcall(function() SaveManager:LoadAutoloadConfig() end)

----------------------------------------------------------------
-- Shutdown
----------------------------------------------------------------
EZ:OnDestroy(function()
    RUNNING = false
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    table.clear(CONNS)
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHistory:Destroy() end)
end)
getgenv().__FP_FARM_LOADED = true
getgenv().__FP_FARM_EZ = EZ
getgenv().__FP_FARM_STATE = STATES
getgenv().__FP_FARM_ALT = ALT
getgenv().__FP_FARM_ENGINE = engine
getgenv().__FP_FARM_DESTROY = function() pcall(function() EZ:Destroy() end) end