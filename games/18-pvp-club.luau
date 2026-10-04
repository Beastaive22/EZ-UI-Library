-- Game guard: this module only runs in "1.8 PVP Club" (universe 10764891927).
if game.GameId ~= 10764891927 then return end

--!nocheck
-- pvp-tool.luau — "1.8 PVP Club" melee core (kill aura via simulated input).
-- Executor: Potassium / sUNC. Control surface: getgenv().PvpClubTool
-- Keybinds: RightControl = toggle aura, End = unload.
--
-- SAFETY: every attack goes through ONE click funnel (doClick): minimum gap
-- 1/14 s AND at most 14 clicks in any rolling 1-second window. No code path can
-- reset or bypass the limiter, and timing jitter only ever lengthens the gap.
-- The user reports autoclicker-like >20 CPS patterns get banned — never raise it.
--
-- ARCHITECTURE (v2, frame-driven): one Heartbeat handler, split into
--   stepWorld — survival checks, lobby travel, target selection (full scan at
--     <=10 Hz + per-frame re-validation of the current target), movement + aim
--     EVERY frame. Attack timers never gate movement or selection.
--   stepFire  — i-frame window timing (learned iframeEst + Data-Ping latency),
--     crit state machine (NORMAL/JUMP_SENT/AIRBORNE/FALL_FIRE), w-tap frame
--     state machine, and the click funnel. readyAt = max(rate, openAt, retryAt).
-- A loopBusy re-entrancy guard makes the loop single-copy: Heartbeat starts a
-- fresh invocation each frame while an old one may be parked in a yield
-- (pathfinding ComputeAsync, hotbar equip scan, pillar routine) — those
-- re-entries are counted (dbg.busySkips) and skipped, so clicks never
-- double-fire and sprint never flip-flops from parallel copies.
--
-- INPUT MODE (why): the server validates each Attack remote's `seq` and
-- silently rejects regressions. Our earlier remote-based sends poisoned that
-- sequence (the real client's own clicks started getting rejected — "sword stops
-- working"). So the tool never fires Attack itself: it aims the camera at the
-- target and calls mouse1click(), letting the game client build and send a
-- 100% authentic attack (its own seq counter, gates, swing animation, first-person
-- viewmodel). Target selection reuses the game's MinecraftMeleeGeometry
-- (Reach 9.6, box tests) plus a LOS raycast that excludes character models.
-- The attack direction is the camera LOOK with the eye (HRP+1.5) as origin, so
-- binder, aim lead and the pre-click snap all share one eye->aimPoint unit.
--
-- NOTE: after a poisoned session, rejoin the server — the stale per-player attack
-- sequence resets on rejoin.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local cloneref = cloneref or function(x) return x end
local LocalPlayer = cloneref(Players.LocalPlayer)

local okGeo, geo = pcall(function()
	return require(RS:WaitForChild("MinecraftMeleeGeometry", 10))
end)
if not okGeo or not geo then
	warn("[PvpClubTool] MinecraftMeleeGeometry unavailable; abort")
	return
end

local Combat = RS:WaitForChild("MinecraftCombat", 10)
if not Combat then
	warn("[PvpClubTool] MinecraftCombat folder missing; abort")
	return
end
local Attack = Combat:WaitForChild("Attack", 5)
local Block = Combat:WaitForChild("Block", 5)
local Sprint = Combat:WaitForChild("Sprint", 5)
local Feedback = Combat:WaitForChild("Feedback", 5)
local Swing = Combat:WaitForChild("Swing", 5)
local Flash = RS:WaitForChild("ConfirmedMeleeFlash", 10)
if not (Attack and Block and Sprint) then
	warn("[PvpClubTool] combat remotes missing; abort")
	return
end

local G = getgenv()
if G.PvpClubTool and G.PvpClubTool.Unload then
	pcall(G.PvpClubTool.Unload)
end

local CPS_CLAMP = { min = 2, max = 14 }

local cfg = {
	enabled = false,
	cps = 8,
	cpsJitter = 0.25,
	blockHit = false,        -- remote block automation; off: remote sends are risky (seq poisoning)
	alwaysBlock = false,     -- hold block while waiting between attacks
	wTap = true,             -- sprint-reset around each swing (input: LeftShift tap via VIM)
	wTapDelayMs = 60,
	autoSprint = false,
	autoReequip = true,      -- auto re-equip the sword (throttled) when bow/apple/empty is out
	autoPrestige = true,     -- lobby + level >= PrestigeConfig.RequiredLevel (200): walk to the Prestige Merchant and prestige
	autoCrate = true,        -- auto buy + open the Gold cosmetic crate (10k coins) whenever you can afford it
	adTag = true,            -- rewrite every player's overhead nametag (client-side): keep their tags, swap the username for the rainbow EZ Hub discord plug
	comboMove = true,        -- drive WASD while engaged: chase, strafe, edge spacing
	engageRange = 512,       -- chase radius — effectively the whole arena (full autoplay)
	preferredRange = 9.35,   -- band high edge, HIT distance (aim ray -> body); clamped to Reach-0.25
	backoffRange = 8.5,      -- band low edge, HIT distance; clamped to Reach-1.1
	strafeFlipMinMs = 280,   -- reactive strafe: safety-net flip window lower bound (ms)
	strafeFlipMaxMs = 620,   -- reactive strafe: safety-net flip window upper bound (ms)
	autoJumpReset = true,    -- jump when the target swings (airborne softens incoming knockback)
	critMode = true,         -- jump-crits: swing while falling; only when the target is in our combo
	critComboWindow = 1.4,   -- seconds since our last landed hit that count as "they're in our combo"
	critJumpCooldown = 0.8,  -- min seconds between deliberate crit jumps (no crit spam)
	autoTravel = true,       -- lobby (Y >= arenaY): walk to the drop hole instead of fighting
	arenaY = 60,             -- at/above this height is the safe zone — never attack there
	dropPoint = Vector3.new(385, 84, -14), -- SkySpawn hole down into OvergrownCourtyard
	autoEat = true,          -- under eatHpThreshold (3 hearts): flee + eat a golden apple
	eatHpThreshold = 6,      -- HP below this triggers the survival eat (3 hearts = 6 HP)
	appleSlot = 3,           -- hotbar slot of the golden apple (fallback scans all slots)
	swordSlot = 8,           -- hotbar slot of the sword for re-equip after eating
	pickaxeSlot = 5,         -- hotbar slot of the diamond pickaxe (mining)
	cobbleSlot = 4,          -- hotbar slot of cobblestone (building experiments)
	buildMode = false,       -- EXPERIMENTAL: pillar-up with placed blocks when targets are above
	includeNPC = true,
	scoring = "nearest",     -- nearest | lowestHP | angle
	aimHeight = 1.5,
	aimSpeed = 16,           -- camera tracking responsiveness (render-step aim; higher = snappier)
	swingAnim = true,        -- kept for compatibility (swings now come from the game itself)
}

local stats = {
	attacksSent = 0,
	confirmAny = 0,
	critConfirms = 0,
	flashesOnTarget = 0,
	hpDamageObserved = 0,
	lastTargetName = nil,
	lastSendAt = 0,
	lastConfirmAt = 0,
	startedAt = os.clock(),
}

-- per-target bookkeeping: some players silently absorb attacks (probe finding) —
-- track landing signals per target and temporarily skip "dry" ones.
local lastSendByTarget = {}
local dryInfo = {}
local lastFeedbackAt = 0
local comboHeatAt = 0
local hurtAt = {} -- last confirmed hit time per target (drives i-frame window timing)
local selfHurtAt = 0 -- last time WE took damage (sticky-target drop signal)

local function markLanding(name)
	local info = dryInfo[name]
	if not info then
		info = { dry = 0, dryUntil = 0, lastLanding = 0 }
		dryInfo[name] = info
	end
	info.lastLanding = os.clock()
	info.dry = 0
	info.dryUntil = 0
	comboHeatAt = os.clock()
	hurtAt[name] = os.clock()
end

local function isDry(name)
	local info = dryInfo[name]
	return info ~= nil and info.dryUntil > os.clock()
end

local function comboHotNow(t)
	return (t - comboHeatAt) < cfg.critComboWindow
end

local function now()
	return workspace:GetServerTimeNow()
end

-- swing / sprint / block local state ----------------------------------------

local lastSwingAt = -10
local sprintState = nil
local lastSprintFireAt = -10
local blockState = false
local pendingReblock = false

local function fireSprint(v)
	local t = os.clock()
	if sprintState == v then
		return
	end
	if t - lastSprintFireAt < 0.12 then
		return
	end
	sprintState = v
	lastSprintFireAt = t
	pcall(function()
		Sprint:FireServer(v)
	end)
end

local lastBlockFireAt = -10
local pendingBlockValue = nil
local blockFlushScheduled = false

local function fireBlock(v)
	if blockState == v then
		return
	end
	local t = os.clock()
	local dt = t - lastBlockFireAt
	if dt < 0.25 then
		-- throttle: block flips at ~9 CPS made the view jitter; debounce them
		pendingBlockValue = v
		if not blockFlushScheduled then
			blockFlushScheduled = true
			task.delay(0.25 - dt, function()
				blockFlushScheduled = false
				local w = pendingBlockValue
				pendingBlockValue = nil
				if w ~= nil and blockState ~= w then
					blockState = w
					lastBlockFireAt = os.clock()
					pcall(function()
						Block:FireServer(w)
					end)
				end
			end)
		end
		return
	end
	blockState = v
	lastBlockFireAt = t
	pcall(function()
		Block:FireServer(v)
	end)
end

-- NOTE: no FirstPersonItemSwing.Pose hook here anymore. Swing visuals come from the
-- game itself now (real clicks), and stacking hooks across reloads corrupted the
-- render step (frozen viewmodel/camera). Never hook that function.

-- movement engine (VirtualInputManager) ------------------------------------------
-- Verified live in this game (Potassium):
--   * VIM SendKeyEvent(Enum.KeyCode.W/A/S/D)  -> drives movement
--   * VIM SendKeyEvent(Enum.KeyCode.Space)    -> jumps
--   * VIM SendKeyEvent(Enum.KeyCode.LeftShift) while moving -> toggles sprint
--   * mouse1click()                           -> triggers the game's own attack
--   * keypress()/keyrelease() are dead here — never use them for movement.

local vim = game:GetService("VirtualInputManager")
local heldKeys = {}

local function keySet(kc, down)
	if down then
		if not heldKeys[kc] then
			heldKeys[kc] = true
			pcall(function()
				vim:SendKeyEvent(true, kc, false, game)
			end)
		end
	elseif heldKeys[kc] then
		heldKeys[kc] = nil
		pcall(function()
			vim:SendKeyEvent(false, kc, false, game)
		end)
	end
end

local function releaseAllKeys()
	for kc in pairs(heldKeys) do
		pcall(function()
			vim:SendKeyEvent(false, kc, false, game)
		end)
	end
	table.clear(heldKeys)
end

-- robust jump (NON-BLOCKING): a single synthetic Space press can be dropped,
-- which made the auto step-jump "fail sometimes". Retry up to 3 times until
-- airborne, then fall back to the Humanoid property as a last resort. Runs on
-- its own thread so Heartbeat callers never park the loop (the old blocking
-- version held the aura handler for up to 0.24 s per jump); an in-flight flag
-- collapses duplicate requests so callers never stack retry loops.
local jumpInFlight = false
local function inputJump()
	if jumpInFlight then
		return
	end
	jumpInFlight = true
	task.spawn(function()
		local attempts = 0
		local function attempt()
			attempts += 1
			pcall(function()
				vim:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
			end)
			task.delay(0.06, function()
				pcall(function()
					vim:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
				end)
			end)
		end
		attempt()
		local t0 = os.clock()
		while os.clock() - t0 < 0.24 do
			task.wait(0.04)
			local c = LocalPlayer.Character
			if c and c:GetAttribute("MinecraftGrounded") == false then
				break
			end
			if attempts < 3 and os.clock() - t0 > attempts * 0.08 then
				attempt()
			end
		end
		local c = LocalPlayer.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if h then
			pcall(function()
				h.Jump = true
			end)
		end
		jumpInFlight = false
	end)
end

local function inputTapSprint()
	pcall(function()
		vim:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
	end)
	task.delay(0.05, function()
		pcall(function()
			vim:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
		end)
	end)
end

local function sprintStateNow()
	local c = LocalPlayer.Character
	return c and c:GetAttribute("SprintRequested") or nil
end

-- toggle sprint only when the current state doesn't already match the target
local function ensureSprint(on)
	if sprintStateNow() == on then
		return
	end
	inputTapSprint()
	task.delay(0.16, function()
		if sprintStateNow() ~= on then
			inputTapSprint()
		end
	end)
end

local moveState = {
	strafeDir = 1,       -- current strafe/nudge side (+1 = D, -1 = A)
	flipAt = 0,          -- last strafe flip time
	netAt = 0,           -- safety-net flip deadline (set on each flip)
	engaged = false,
	rangeMode = "strafe", -- fight-band controller state: close | strafe | retreat
	lastSafePos = nil,   -- last verified non-hazard ground (lava escape target)
	airGraceUntil = 0,   -- airtime target-retention deadline
	inAirGrace = false,
}
local currentTarget = nil
local stickyTarget = nil
local stickyAt = 0
local stickyRefDist = 0 -- root distance when the sticky was locked (drop if it grows >25)
local lastKeyRefreshAt = 0
-- continuous aim state: {target} = aim at a model's chest, {dir} = aim along a
-- direction (chase/travel), {pos} = aim at a world position (mining/building).
-- Written by the movement/aura code, read every frame by the render-step binder.
local aim = { target = nil, dir = nil, pos = nil }
-- assigned after the equip/mining utilities below are defined (declaration order:
-- comboMoveStep runs earlier in the file than those helpers)
local stuckMineHook = nil
local pillarHook = nil

-- synthetic keys can be dropped when the Roblox window loses focus; re-press
-- everything we hold once per second (and on focus gain) so movement never stalls.
local function refreshHeldKeys(force)
	local t = os.clock()
	if not force and t - lastKeyRefreshAt < 1 then
		return
	end
	lastKeyRefreshAt = t
	for kc in pairs(heldKeys) do
		pcall(function()
			vim:SendKeyEvent(true, kc, false, game)
		end)
	end
end

-- shared combat state (read across the movement, selection and fire steps) ------
local enemySwingAt = 0         -- last time our current target swung (reactive strafe input)
local kbJump = { at = 0 }      -- knockback signal -> jump-reset (NOT enemy swings)
local lastGroundY = nil       -- ground reference: the vertical-gap filter must not follow our jumps
local frameDt = 0.016         -- smoothed render dt -> aim lead time
local airGraceUses = 0        -- diagnostics: airtime target-grace activations
local crit = { state = "NORMAL", jumpAt = 0, lastJumpAt = -10, leftGround = false }

-- per-target positional velocity (EMA of positional deltas — more reliable than
-- AssemblyLinearVelocity for remote-driven characters). Feeds aim lead and the
-- intercept/pursuit math. Keyed by model; dead entries pruned by the candidate cache.
local velTrack = {}
local function updateVel(model, pos, t)
	local e = velTrack[model]
	if not e then
		velTrack[model] = { pos = pos, at = t, v = Vector3.zero }
		return Vector3.zero
	end
	local dt = t - e.at
	if dt > 0.016 and dt < 1 then
		local inst = (pos - e.pos) / dt
		local a = math.clamp(dt * 10, 0.1, 1)
		e.v = e.v + (inst - e.v) * a
		e.pos = pos
		e.at = t
	elseif dt >= 1 then
		e.pos = pos
		e.at = t
	end
	return e.v
end
local function velOf(model)
	local e = velTrack[model]
	return e and e.v or Vector3.zero
end
-- the game reads target positions 1-2 frames after our camera write, so aim a
-- touch ahead: lead time scales with frame time (clamped to ~1-2 frames)
local function leadTimeNow()
	return math.clamp(frameDt * 1.5, 0.015, 0.05)
end
local function aimPointFor(model, thrp)
	return thrp.Position + Vector3.new(0, cfg.aimHeight, 0) + velOf(model) * leadTimeNow()
end
-- intercept point: where the target will be by the time we could close the gap
local function interceptPos(hrp, hum, thrp, model)
	local flat = (thrp.Position - hrp.Position) * Vector3.new(1, 0, 1)
	local fd = flat.Magnitude
	local vFlat = velOf(model) * Vector3.new(1, 0, 1)
	local ws = (hum and hum.WalkSpeed > 1) and hum.WalkSpeed or 16
	local tt = math.clamp(fd / math.max(ws, 1), 0, 0.8)
	return thrp.Position + vFlat * tt
end

-- attack timing state (single click funnel — see doClick) ------------------------
local MIN_CLICK_GAP = 1 / 14 -- hard CPS ceiling: never click faster than 14/s
local IFRAME_MIN, IFRAME_MAX = 0.38, 0.55
local clickTimes = {} -- rolling 1 s window of click timestamps (<= 14 entries)
local lastClickAt = -10
local lastClickTarget = nil -- name of the model we last clicked
local lastClickModel = nil
local iframe = { est = 0.45, retryAt = 0, clean = 0 }
local latencyCache = { at = 0, val = 0.05 }

local function pruneClicks(t)
	while #clickTimes > 0 and t - clickTimes[1] >= 1 do
		table.remove(clickTimes, 1)
	end
end

-- the ONLY path that may click. Hard governor: minimum gap 1/14 s AND at most
-- 14 clicks in the rolling 1 s window. Nothing resets or bypasses it.
-- The click is client-level (VirtualInputManager into THIS client's viewport
-- centre), NOT an OS mouse click: it works with the window in the background
-- and can never land on another window (the old mouse1click clicked whatever
-- had keyboard focus — that was the "clicking random shit" bug). Press now,
-- release 35 ms later on a delayed thread so the click has both edges.
local function doClick(t)
	pruneClicks(t)
	if #clickTimes >= 14 then
		return false
	end
	if #clickTimes > 0 and t - clickTimes[#clickTimes] < MIN_CLICK_GAP then
		return false
	end
	if t - lastClickAt < MIN_CLICK_GAP then
		return false
	end
	local cam2 = workspace.CurrentCamera
	if not cam2 then
		return false
	end
	local vp = cam2.ViewportSize
	local cx, cy = vp.X / 2, vp.Y / 2
	local ok = pcall(function()
		vim:SendMouseMoveEvent(cx, cy, game)
		vim:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
	end)
	if not ok then
		return false
	end
	task.delay(0.035, function()
		pcall(function()
			vim:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
		end)
	end)
	table.insert(clickTimes, t)
	lastClickAt = t
	return true
end

-- one-way latency from Data Ping (round-trip / 2), clamped; 0.05 fallback
local function latencyNow()
	local t = os.clock()
	if t - latencyCache.at > 1 then
		latencyCache.at = t
		local ok, v = pcall(function()
			return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		if ok and type(v) == "number" and v > 0 then
			latencyCache.val = math.clamp(v / 2000, 0.01, 0.15)
		end
	end
	return latencyCache.val
end

-- w-tap (frame state machine, no waits): drop sprint just before the swing so
-- the hit is a non-sprint hit (reduced knockback = combo-friendly), then restore
-- sprint after the click. comboMoveStep must not re-press sprint while a tap is
-- in flight (that was un-doing every tap).
local wtap = { phase = "idle", at = 0, pretapAt = 0, lastEnd = 0 }

local function wtapInFlight()
	return wtap.phase ~= "idle"
end

local function wtapStep(t)
	if wtap.phase == "pretap" then
		-- the click we armed for never happened: restore sprint and bail
		if t - wtap.pretapAt > 0.35 then
			wtap.phase = "restore"
			wtap.at = t
		end
	elseif wtap.phase == "restore" then
		if t >= wtap.at then
			wtap.phase = "idle"
			wtap.lastEnd = t
			if cfg.enabled then
				ensureSprint(true)
			end
		end
	end
end

-- arm the sprint-off tap in the last ~60 ms before the click is due
local function wtapPrep(t, readyAt)
	if not cfg.wTap or wtap.phase ~= "idle" then
		return
	end
	if readyAt - t > 0.06 then
		return
	end
	-- a tap needs sprint to actually be on
	if sprintStateNow() == true then
		wtap.phase = "pretap"
		wtap.pretapAt = t
		inputTapSprint()
	end
end

local function wtapClicked(t)
	if wtap.phase == "pretap" then
		wtap.phase = "restore"
		wtap.at = t + math.max(cfg.wTapDelayMs, 40) / 1000
	end
end

-- connections registry + NPC registry (mirrors the game client's melee NPC
-- tracking). Declared EARLY: the hazard/LOS exclusion lists below include NPC
-- characters, so npcSet must exist before any probe helper.
local conns = {}
local npcSet = {}
local function registerNPC(hum)
	if hum:IsA("Humanoid") and hum.Parent and hum.Parent:IsA("Model") and not Players:GetPlayerFromCharacter(hum.Parent) then
		npcSet[hum.Parent] = true
	end
end

for _, d in ipairs(workspace:GetDescendants()) do
	if d:IsA("Humanoid") then
		registerNPC(d)
	end
end

table.insert(conns, workspace.DescendantAdded:Connect(function(d)
	if d:IsA("Humanoid") then
		task.defer(registerNPC, d)
	end
end))
table.insert(conns, workspace.DescendantRemoving:Connect(function(d)
	npcSet[d] = nil
end))

-- environment awareness ----------------------------------------------------------

local function flatDir(fromPos, toPos)
	local d = (toPos - fromPos) * Vector3.new(1, 0, 1)
	local m = d.Magnitude
	if m > 0.01 then
		return d / m
	end
	return nil
end

-- raycast params that exclude EVERY character (players + NPCs + us) so neither
-- floor probes nor LOS tests can be blocked by — or land on — a player.
--   ground: RespectCanCollide (decor must not read as floor)
--   los:    IgnoreWater (matches the original LOS behaviour)
local envCache = { at = 0, char = nil, ground = nil, los = nil }
local function envParams(char)
	local t = os.clock()
	if envCache.ground == nil or envCache.char ~= char or t - envCache.at > 0.5 then
		local list = {}
		if char then
			table.insert(list, char)
		end
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Character then
				table.insert(list, p.Character)
			end
		end
		for m in pairs(npcSet) do
			if m.Parent then
				table.insert(list, m)
			end
		end
		local g = RaycastParams.new()
		g.FilterType = Enum.RaycastFilterType.Exclude
		g.FilterDescendantsInstances = list
		g.RespectCanCollide = true
		local l = RaycastParams.new()
		l.FilterType = Enum.RaycastFilterType.Exclude
		l.FilterDescendantsInstances = list
		l.IgnoreWater = true
		envCache.ground = g
		envCache.los = l
		envCache.char = char
		envCache.at = t
	end
	return envCache.ground
end

local function envLOSParams(char)
	envParams(char)
	return envCache.los
end

-- ground probe `dist` studs ahead of `pos` along `dir` (dist 0 = straight down)
local function probeGroundAt(pos, dir, dist)
	local from = pos + Vector3.new(0, 2.5, 0) + dir * dist
	local hit = workspace:Raycast(from, Vector3.new(0, -34, 0), envParams(LocalPlayer.Character))
	if hit then
		return hit.Instance, hit.Position.Y
	end
	return nil, nil
end

-- touch-damage hazards: anything here must never be stepped on / walked into
-- (maps rotate, so this is name-driven — extend the list as new maps appear)
local HAZARD_WORDS = {
	"lava",
	"fire",
	"magma",
	"cactus",
	"campfire",
	"berry",
	"bramble",
	"spike",
	"saw",
	"thorns",
}

local function isHazardName(name)
	local n = string.lower(name)
	for _, w in ipairs(HAZARD_WORDS) do
		if string.find(n, w, 1, true) then
			return true
		end
	end
	return false
end

-- can we physically move along `dir` without dying? THREE probes along the
-- ACTUAL move direction (1.5 / 3 / 4.5 studs) so short hazards (1-3 stud lava
-- strips, cactus) and lips are caught — the old single 4.5-stud probe stepped
-- right onto them. Characters are excluded (nobody counts as floor).
-- terrain debug tracer: ring buffer of recent terrain/movement decisions (no
-- behavior change; read via getgenv().PvpClubToolDebug.ev). minGap throttles.
-- optional `key` throttles that event class on its own clock, so a burst of one
-- event can't swallow another (nav:compute/ok/fail, detour on/off).
local lastTraceAt = 0
local traceKeyAt = {}
local function traceEvent(s, minGap, key)
	local d = G.PvpClubToolDebug
	if not d then
		return
	end
	local now = os.clock()
	if key then
		if minGap and now - (traceKeyAt[key] or -10) < minGap then
			return
		end
		traceKeyAt[key] = now
	else
		if minGap and now - lastTraceAt < minGap then
			return
		end
		lastTraceAt = now
	end
	local ev = d.ev
	if type(ev) ~= "table" then
		ev = {}
		d.ev = ev
	end
	ev[#ev + 1] = string.format("%.2f|%s", now % 10000, s)
	while #ev > 80 do
		table.remove(ev, 1)
	end
end

local function safeToMove(hrp, dir, dist)
	if not dir then
		return false
	end
	dist = dist or 4.5
	local rp = envParams(LocalPlayer.Character)
	for _, d in ipairs({ 1.5, 3.0, 4.5 }) do
		if d > dist then
			break
		end
		local from = hrp.Position + Vector3.new(0, 2.5, 0) + dir * d
		local hit = workspace:Raycast(from, Vector3.new(0, -34, 0), rp)
		if not hit then
			traceEvent(string.format("safe:void dir=(%.2f,%.2f,%.2f) d=%.1f", dir.X, dir.Y, dir.Z, d), 0.4)
			return false                          -- void: no floor ahead
		end
		if isHazardName(hit.Instance.Name) then
			traceEvent("safe:hazard", 0.4)
			return false                          -- lava / fire ahead
		end
		if hit.Position.Y < hrp.Position.Y - 14 then
			traceEvent(string.format("safe:drop hitY=%.1f us=%.1f", hit.Position.Y, hrp.Position.Y), 0.4)
			return false                          -- long drop = ledge, don't walk off
		end
	end
	return true
end

-- unified stuck recovery: no progress for 1.2s WHILE ACTUALLY HOLDING W or S
-- (band-strafing near a wall must not false-positive) -> hop + a HAZARD-CHECKED
-- sustained wall-slide (the old nudge never called safeToMove — that is how the
-- bot walked into lava). The slide holds a strafe key toward the chosen side for
-- SLIDE_TIME while the caller keeps W held; if the first half moved us < 1.5
-- studs the side is flipped once. Escalates to pathfinding assist when still pinned.
local SLIDE_TIME = 1.2
local function checkStuck(hrp, t, right)
	if t - (moveState.lastMoveCheck or 0) > 1.2 then
		local last = moveState.lastMovePos
		local moved = last and (hrp.Position - last).Magnitude or 99
		moveState.lastMovePos = hrp.Position
		moveState.lastMoveCheck = t
		if moved < 2 and (heldKeys[Enum.KeyCode.W] or heldKeys[Enum.KeyCode.S]) then
			moveState.stuckCount = (moveState.stuckCount or 0) + 1
			moveState.nudgeUntil = t + SLIDE_TIME
			moveState.slideFlipAt = t + SLIDE_TIME * 0.5
			moveState.slideFrom = hrp.Position
			moveState.slideFlipped = false
			moveState.strafeDir = -(moveState.strafeDir or 1)
			moveState.flipAt = t
			moveState.netAt = t + SLIDE_TIME
			inputJump()
			traceEvent(string.format("stuck#%d moved=%.2f pos=(%.0f,%.0f,%.0f)", moveState.stuckCount or 0, moved, hrp.Position.X, hrp.Position.Y, hrp.Position.Z), 0.3)
		elseif moved >= 2 then
			moveState.stuckCount = 0
			moveState.detourUntil = 0
		end
	end
	local nudging = t < (moveState.nudgeUntil or 0)
	if nudging then
		-- sideways slide, hazard-checked on BOTH sides; neither safe -> no input
		keySet(Enum.KeyCode.D, false)
		keySet(Enum.KeyCode.A, false)
		if not moveState.slideFlipped and t >= (moveState.slideFlipAt or 0) then
			moveState.slideFlipped = true
			local from = moveState.slideFrom
			if from and (hrp.Position - from).Magnitude < 1.5 then
				moveState.strafeDir = -(moveState.strafeDir or 1)
				moveState.flipAt = t
			end
		end
		if right then
			local side = moveState.strafeDir or 1
			if not safeToMove(hrp, right * side, 2.5) then
				if safeToMove(hrp, right * -side, 2.5) then
					side = -side
				else
					side = 0
				end
			end
			traceEvent("nudge side=" .. tostring(side), 0.3)
			if side ~= 0 then
				keySet(side > 0 and Enum.KeyCode.D or Enum.KeyCode.A, true)
			end
		end
	end
	return nudging
end

-- auto step-up (MC auto-jump style), FEET-relative (feet = root.Y - 4: root
-- size Y=2 + HipHeight=3). Probes run along the humanoid's ACTUAL move
-- direction so any held key combo works; ankle + knee heights in front, then
-- sideways probes when we're blocked but the forward rays see nothing (low
-- lips / one-block steps they glide over). Jumps only when the obstacle top
-- is climbable: 0.3 < top - feet <= jumpH - 0.3 (jumpH ~5.1 measured).
local JUMP_HEIGHT = 5.1
local function maybeStepJump(hrp, hum, t)
	local char = LocalPlayer.Character
	if not char or not hum then
		return
	end
	if char:GetAttribute("MinecraftGrounded") == false then
		return
	end
	if math.abs(hrp.AssemblyLinearVelocity.Y) > 4 then
		return
	end
	if t - (moveState.lastStepJump or 0) < 0.25 then
		return
	end
	local moveDir = hum.MoveDirection
	if moveDir.Magnitude < 0.3 then
		return
	end
	local rp = envParams(char)
	local feetY = hrp.Position.Y - 4
	local feetPos = Vector3.new(hrp.Position.X, feetY, hrp.Position.Z)

	-- forward probes at ankle and knee height
	local hit, probeDir
	for _, hOff in ipairs({ 0.35, 1.0 }) do
		hit = workspace:Raycast(feetPos + moveDir * 0.5 + Vector3.new(0, hOff, 0), moveDir * 1.4, rp)
		if hit then
			probeDir = moveDir
			break
		end
	end
	-- blocked with no forward ray hit: sideways probes
	if not hit then
		local side = moveDir:Cross(Vector3.new(0, 1, 0))
		if side.Magnitude > 0.01 then
			side = side.Unit
			for _, s in ipairs({ 1, -1 }) do
				hit = workspace:Raycast(feetPos + side * 0.5 * s + Vector3.new(0, 0.35, 0), side * 1.2 * s, rp)
				if hit then
					probeDir = side * s
					break
				end
			end
		end
	end
	if not hit then
		traceEvent(string.format("stepjump:nohit dir=(%.2f,%.2f,%.2f) pos=(%.0f,%.0f,%.0f)", moveDir.X, moveDir.Y, moveDir.Z, hrp.Position.X, hrp.Position.Y, hrp.Position.Z), 0.5)
		return
	end
	-- top of the obstacle from directly above the hit point; it only counts when
	-- the ray lands on the SAME part. One retry a little further INTO the face.
	-- A part that is never found from above is taller than a jump (a pier/wall:
	-- the ray starts inside it or lands on distant ground) -> TALL, never a jump.
	local aboveOff = Vector3.new(0, JUMP_HEIGHT + 0.5, 0)
	local downRay = Vector3.new(0, -(JUMP_HEIGHT + 1.5), 0)
	local topHit = workspace:Raycast(hit.Position + aboveOff, downRay, rp)
	if not (topHit and topHit.Instance == hit.Instance) then
		topHit = workspace:Raycast(hit.Position + probeDir * 0.75 + aboveOff, downRay, rp)
		if not (topHit and topHit.Instance == hit.Instance) then
			topHit = nil
		end
	end
	if not topHit then
		moveState.tallBlockedAt = t
		traceEvent(string.format(
			"stepjump:tall hit=%s@(%.1f,%.1f,%.1f) probe=(%.2f,%.2f,%.2f) tall=true -> NO",
			hit.Instance.Name, hit.Position.X, hit.Position.Y, hit.Position.Z,
			probeDir.X, probeDir.Y, probeDir.Z), 0.5)
		return
	end
	local topY = topHit.Position.Y
	local step = topY - feetY
	local willJump = step > 0.3 and step <= JUMP_HEIGHT - 0.3
	if step > JUMP_HEIGHT - 0.3 then
		moveState.tallBlockedAt = t
	end
	traceEvent(string.format(
		"stepjump rise=%.2f top=%.2f hit=%s@(%.1f,%.1f,%.1f) probe=(%.2f,%.2f,%.2f) -> %s",
		step, topY, hit.Instance.Name, hit.Position.X, hit.Position.Y, hit.Position.Z,
		probeDir.X, probeDir.Y, probeDir.Z, willJump and "JUMP" or "NO"), 0.25)
	if willJump then
		moveState.lastStepJump = t
		inputJump()
		task.delay(0.35, function()
			local c = LocalPlayer.Character
			if c then
				traceEvent("jumpAir airborne=" .. tostring(c:GetAttribute("MinecraftGrounded") == false), 0.05)
			end
		end)
	end
end

-- reactive strafe (replaces the blind flip timer): flips on the enemy's swing
-- relay, on facing pressure while they track us (short random reversal), on
-- hazards, with a 0.5-0.9 s safety net so no side is held forever. Only used
-- INSIDE the strafe band — never while closing or retreating (W+D = 71% speed).
local strafeFlipTimes = {}
local function noteStrafeFlip(t)
	table.insert(strafeFlipTimes, t)
	while #strafeFlipTimes > 0 and t - strafeFlipTimes[1] > 60 do
		table.remove(strafeFlipTimes, 1)
	end
end

local function strafeFlip(t)
	moveState.strafeDir = -(moveState.strafeDir or 1)
	moveState.flipAt = t
	local netMin = math.max(cfg.strafeFlipMinMs, 500) / 1000
	local netMax = math.max(cfg.strafeFlipMaxMs, netMin * 1000) / 1000
	moveState.netAt = t + netMin + math.random() * (netMax - netMin)
	noteStrafeFlip(t)
end

-- returns +1 (hold D), -1 (hold A) or 0 (both sides unsafe -> no strafe)
local function strafeChoose(hrp, right, model, comboHot, t)
	if not right then
		return 0
	end
	local dir = moveState.strafeDir or 1
	-- hazard first: never strafe into lava / off a ledge; try the other side
	if not safeToMove(hrp, right * dir, 2.2) then
		if safeToMove(hrp, right * -dir, 2.2) then
			strafeFlip(t)
			dir = moveState.strafeDir
		else
			return 0
		end
	end
	-- dodge their swing timing (min 0.12 s between flips so 8-10 CPS swings
	-- can't turn us into pure jitter)
	if enemySwingAt > (moveState.lastSwingFlipAt or 0) and t - moveState.flipAt > 0.12 then
		moveState.lastSwingFlipAt = enemySwingAt
		strafeFlip(t)
		dir = moveState.strafeDir
	end
	-- facing pressure while not in our combo: they're tracking our side —
	-- schedule a short reversal (120-260 ms) to break their tracking
	if not comboHot and model and model.Parent then
		local thrp = model:FindFirstChild("HumanoidRootPart")
		if thrp then
			local theirLook = thrp.CFrame.LookVector * Vector3.new(1, 0, 1)
			local toUs = (hrp.Position - thrp.Position) * Vector3.new(1, 0, 1)
			if theirLook.Magnitude > 0.1 and toUs.Magnitude > 0.5
				and theirLook.Unit:Dot(toUs.Unit) > 0.55
				and not moveState.reverseAt
			then
				moveState.reverseAt = t + (120 + math.random() * 140) / 1000
			end
		end
	end
	if moveState.reverseAt and t >= moveState.reverseAt then
		moveState.reverseAt = nil
		strafeFlip(t)
		dir = moveState.strafeDir
	end
	-- safety net: never hold one side too long
	if t >= (moveState.netAt or 0) then
		strafeFlip(t)
		dir = moveState.strafeDir
	end
	return dir
end

-- PURSUE-KB: the target is running away and their i-frame window re-opens at
-- hurtAt + iframeEst — predict where they'll be then and close EARLY so we're
-- at the band edge the moment the window opens (instead of reacting 100+ ms late).
local function pursueKBCheck(t, hrp, thrp, model, E_lo)
	local hurt = hurtAt[model.Name]
	if not hurt or t - hurt > iframe.est + 0.25 then
		return false
	end
	local vFlat = velOf(model) * Vector3.new(1, 0, 1)
	if vFlat.Magnitude <= 4 then
		return false
	end
	local away = (thrp.Position - hrp.Position) * Vector3.new(1, 0, 1)
	if away.Magnitude < 0.5 or vFlat.Unit:Dot(away.Unit) < 0.3 then
		return false
	end
	local tOpen = hurt + iframe.est
	local pred = thrp.Position + vFlat * math.max(tOpen - t, 0)
	local predDist = ((pred - hrp.Position) * Vector3.new(1, 0, 1)).Magnitude - 0.8
	return predDist > E_lo + 0.3
end

-- pathfinding assist: engaged only after repeated stuck cycles during a chase.
-- ComputeAsync YIELDS, so it runs on its own thread: results are computed into
-- locals and swapped in atomically on success. The OLD path stays active while
-- recomputing (the old code deactivated it first and walked straight at the
-- wall for the whole 2 s compute). nav.computing dedupes concurrent requests.
local PathfindingService = game:GetService("PathfindingService")
local nav = { path = nil, index = 1, at = 0, active = false, lastTry = 0, computing = false, dest = nil }

-- isDetour: the request came from the fight-branch detour; its outcome feeds
-- moveState.detourFails (two failures -> fall back to the mini side-detour).
local function navCompute(hrp, dest, fallbackDest, isDetour)
	if nav.computing then
		return false
	end
	nav.computing = true
	local from = hrp.Position
	traceEvent(string.format("nav:compute start dest=(%.0f,%.0f,%.0f)", dest.X, dest.Y, dest.Z), 0.4, "nav:start")
	task.spawn(function()
		local ok, path = pcall(function()
			local p = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 6,
				AgentCanJump = true,
				AgentMaxSlope = 60,
			})
			p:ComputeAsync(from, dest)
			return p
		end)
		if not (ok and path and path.Status == Enum.PathStatus.Success) and fallbackDest then
			-- target endpoint unreachable (tower/roof/inside): path to the point
			-- under them at our level, then build/climb from there
			ok, path = pcall(function()
				local p = PathfindingService:CreatePath({
					AgentRadius = 2,
					AgentHeight = 6,
					AgentCanJump = true,
					AgentMaxSlope = 60,
				})
				p:ComputeAsync(from, fallbackDest)
				return p
			end)
		end
		nav.computing = false
		if ok and path and path.Status == Enum.PathStatus.Success then
			nav.path = path
			nav.index = 2
			nav.at = os.clock()
			nav.dest = dest
			nav.active = true
			if isDetour then
				moveState.detourFails = 0
			end
			local wpCount = 0
			pcall(function()
				wpCount = #path:GetWaypoints()
			end)
			traceEvent("nav:ok wp=" .. tostring(wpCount), 0.4, "nav:ok")
		else
			if isDetour then
				moveState.detourFails = (moveState.detourFails or 0) + 1
			end
			traceEvent("nav:fail", 0.4, "nav:fail")
			if fallbackDest then
				-- both endpoints unreachable: perpendicular detour for a while
				moveState.detourUntil = os.clock() + 1.4
				moveState.detourSide = -(moveState.detourSide or 1)
			end
		end
	end)
	return true
end

-- advance along the path; returns the flat direction to follow (or nil).
-- Loops past waypoints we've already reached (the old one-per-tick advance
-- burned a full tick of "no direction" at every waypoint).
local function navStep(hrp)
	if not (nav.active and nav.path) then
		return nil
	end
	if os.clock() - nav.at > 14 then
		nav.active = false
		return nil
	end
	local wps = nav.path:GetWaypoints()
	local i = nav.index
	while i <= #wps do
		local wp = wps[i]
		local flat = (wp.Position - hrp.Position) * Vector3.new(1, 0, 1)
		if flat.Magnitude < 3.5 then
			if wp.Action == Enum.PathWaypointAction.Jump then
				inputJump()
			end
			i += 1
		else
			nav.index = i
			return flat.Unit
		end
	end
	nav.active = false
	return nil
end

-- clear line to the target: BOTH a chest-height ray and a feet-height ray miss
-- (characters excluded; a low wall hides below the chest) and the vertical gap
-- is small. Shared by the chase branch and the fight-branch detour cancel.
local function directClearTo(char, hrp, thrp)
	local rp = envParams(char)
	local from = hrp.Position + Vector3.new(0, 1.2, 0)
	local delta = (thrp.Position + Vector3.new(0, 1.2, 0)) - from
	if delta.Magnitude <= 0.1 then
		return false
	end
	local rayLen = math.min(delta.Magnitude, 24)
	local hitChest = workspace:Raycast(from, delta.Unit * rayLen, rp)
	local hitFeet = workspace:Raycast(hrp.Position - Vector3.new(0, 3.5, 0), delta.Unit * rayLen, rp)
	return (hitChest == nil and hitFeet == nil) and math.abs(delta.Y) < 3.5
end

-- dynamic drop-hole detection (the lobby/map can change, so never trust a constant):
-- scan rings around the player for a floor spot whose downward ray reaches the arena
local holeCache = { point = nil, at = 0, floorPos = nil }

local function findDropPoint(hrp)
	if holeCache.point and os.clock() - holeCache.at < 45 then
		return holeCache.point
	end
	local ex = { LocalPlayer.Character }
	local best, bestD, bestFloor
	for radius = 8, 96, 6 do
		for ang = 0, 340, 20 do
			local a = math.rad(ang)
			local x = hrp.Position.X + math.cos(a) * radius
			local z = hrp.Position.Z + math.sin(a) * radius
			local rp = RaycastParams.new()
			rp.FilterType = Enum.RaycastFilterType.Exclude
			rp.FilterDescendantsInstances = ex
			local hit = workspace:Raycast(Vector3.new(x, hrp.Position.Y + 6, z), Vector3.new(0, -180, 0), rp)
			if hit and hit.Position.Y < cfg.arenaY - 10 then
				if not bestD or radius < bestD then
					best, bestD = Vector3.new(x, hrp.Position.Y, z), radius
					bestFloor = hit.Position
				end
			end
		end
		if best then
			break
		end
	end
	holeCache.point = best
	holeCache.floorPos = bestFloor
	holeCache.at = os.clock()
	return best
end

-- arena anchor used as the pathfinding destination for lobby travel
local function findDropFloor(hrp)
	findDropPoint(hrp)
	return holeCache.floorPos
end

-- combat movement (frame-rate controller — called EVERY Heartbeat):
--   fight (engaged/hittable): hit-distance band controller — CLOSE above E_hi,
--     STRAFE inside the band (reactive A/D, no W/S), RETREAT under E_lo, with
--     0.3-stud hysteresis so the edges don't flicker. PURSUE-KB closes early
--     against runners whose i-frames reopen soon. W and S are never held
--     together (structural); no strafe while closing.
--   chase (not engaged): sprint at the INTERCEPT point (pos + v*tClose),
--     pathfind when obstructed, mine player-blocks when pinned.
--   both: never step into void/lava (3-point hazard probes); on lava run back
--     to lastSafePos (not merely away from the target); hop + hazard-checked
--     sidestep when stuck; feet-relative step-jump over climbable blockers.
local function comboMoveStep(char, hum, hrp, thrp, distEff, fightMode, t)
	if not (hrp and thrp and thrp.Parent) then
		return
	end
	local model = thrp.Parent

	-- lava / touch hazard: escape to the last verified safe ground + hop
	local hazardous = char:GetAttribute("InLava") == true
	if not hazardous then
		-- the attribute lags reality by 1-3 frames — check the floor too
		local inst = probeGroundAt(hrp.Position, Vector3.zero, 0)
		if inst and isHazardName(inst.Name) then
			hazardous = true
		end
	end
	if hazardous then
		moveState.lavaUntil = t + 0.8
	end
	if t < (moveState.lavaUntil or 0) then
		keySet(Enum.KeyCode.A, false)
		keySet(Enum.KeyCode.D, false)
		local safe = moveState.lastSafePos
		local dir = safe and flatDir(hrp.Position, safe) or nil
		if dir then
			aim.target = nil
			aim.dir = dir
			keySet(Enum.KeyCode.W, true)
			keySet(Enum.KeyCode.S, false)
		else
			-- no safe point recorded: legacy straight back-off
			keySet(Enum.KeyCode.W, false)
			keySet(Enum.KeyCode.S, true)
		end
		if t - (moveState.lastLavaJump or 0) > 0.45 then
			moveState.lastLavaJump = t
			inputJump()
		end
		refreshHeldKeys()
		moveState.engaged = true
		return
	end

	updateVel(model, thrp.Position, t)
	local iPos = interceptPos(hrp, hum, thrp, model)
	local forward = flatDir(hrp.Position, iPos)
	local right = forward and forward:Cross(Vector3.new(0, 1, 0)) or nil

	-- building: pillar up toward targets above us — runs in BOTH chase and fight
	-- (a towerer near you stays "fight" range; building must still engage)
	if pillarHook then
		pillarHook(char, hrp, thrp)
	end

	local nudging = checkStuck(hrp, t, right)

	if fightMode then
		-- ---------- fight: pressure controller ----------
		-- Never backpedal in a fight: backing away while someone pressures you
		-- is how you get comboed (the user hated the old auto-retreat). CLOSE
		-- above E_hi; otherwise STRAFE (circle the target and keep swinging).
		-- Hugging is handled by the clinch hop; genuinely low HP is handled by
		-- survivalStep (flee + eat), NOT here. distEff is in geo.Hit space;
		-- E_hi = Reach-0.25 (edge of reach).
		local E_hi = math.clamp(cfg.preferredRange, 6, geo.Reach - 0.25)
		local E_lo = math.clamp(cfg.backoffRange, 4, math.min(geo.Reach - 1.1, E_hi - 0.3))
		local mode = moveState.rangeMode or "strafe"
		if distEff > E_hi + 0.3 then
			mode = "close"
		elseif mode == "close" and distEff <= E_hi - 0.3 then
			mode = "strafe"
		end
		-- PURSUE-KB: runner + i-frames reopening soon -> close early
		if mode ~= "close" and pursueKBCheck(t, hrp, thrp, model, E_lo) then
			mode = "close"
		end
		moveState.rangeMode = mode

		-- DETOUR: pinned while closing (stuck, or a pier/wall too tall to hop) with
		-- no clear short line to the target -> route around it with the async
		-- pathfinder. Movement only: aim + swings continue untouched; the walk
		-- direction is mapped onto W/A/S/D relative to the (target-facing) camera.
		local detourDir = nil
		do
			if moveState.detourTarget ~= model then
				moveState.detourTarget = model
				moveState.detourFails = 0
				moveState.miniSince = nil
			end
			local detouring = moveState.fightDetour == true
			local pinned = (moveState.stuckCount or 0) >= 1 or (t - (moveState.tallBlockedAt or -10)) < 1.5
			if (pinned or detouring) and forward and right then
				local flatDist = ((thrp.Position - hrp.Position) * Vector3.new(1, 0, 1)).Magnitude
				local clearNear = flatDist < 14 and directClearTo(char, hrp, thrp)
				if mode ~= "close" or clearNear then
					if detouring then
						moveState.fightDetour = false
						nav.active = false
						traceEvent("nav:detour off", 0.4, "nav:detour")
					end
				else
					if not detouring then
						moveState.fightDetour = true
						moveState.detourHadNav = false
						traceEvent("nav:detour on", 0.4, "nav:detour")
					end
					if (moveState.detourFails or 0) < 2 then
						moveState.miniSince = nil
						if t - nav.lastTry > 0.8 and not nav.computing then
							local needNew = (not nav.active)
								or (t - nav.at > 2)
								or (nav.dest ~= nil and (nav.dest - thrp.Position).Magnitude > 6)
							if needNew then
								nav.lastTry = t
								local dest = flatDist < 30 and iPos or thrp.Position
								navCompute(hrp, dest, Vector3.new(thrp.Position.X, hrp.Position.Y, thrp.Position.Z), true)
							end
						end
						if nav.active then
							moveState.detourHadNav = true
							detourDir = navStep(hrp)
						end
						if moveState.detourHadNav and not nav.active and not nav.computing then
							-- path finished: hand control back to the normal controller
							moveState.fightDetour = false
							moveState.stuckCount = 0
							moveState.tallBlockedAt = nil
							traceEvent("nav:detour off", 0.4, "nav:detour")
						end
					else
						-- pathfinder failed twice for this target: existing mini-detour
						moveState.miniSince = moveState.miniSince or t
						if t - moveState.miniSince > 5 then
							moveState.detourFails = 1
							moveState.miniSince = nil
						end
						if t >= (moveState.detourUntil or 0) then
							moveState.detourUntil = t + 1.4
							moveState.detourSide = -(moveState.detourSide or 1)
						end
						detourDir = (moveState.detourSide or 1) > 0 and right or -right
					end
				end
			elseif detouring then
				moveState.fightDetour = false
				traceEvent("nav:detour off", 0.4, "nav:detour")
			elseif not pinned then
				moveState.detourFails = 0
				moveState.miniSince = nil
			end
			if detourDir and not safeToMove(hrp, detourDir, 4.5) then
				detourDir = nil
			end
		end

		if detourDir then
			local fc = detourDir:Dot(forward)
			local rc = detourDir:Dot(right)
			keySet(Enum.KeyCode.W, fc > 0.38)
			keySet(Enum.KeyCode.S, fc < -0.38)
			if not nudging then
				keySet(Enum.KeyCode.D, rc > 0.38)
				keySet(Enum.KeyCode.A, rc < -0.38)
			end
			maybeStepJump(hrp, hum, t)
		else
			local wantW = mode == "close"
			if wantW and forward and not safeToMove(hrp, forward, 4.5) then
				wantW = false
			end
			keySet(Enum.KeyCode.W, wantW)
			keySet(Enum.KeyCode.S, false)
			-- strafe whenever not closing (pressure: circle the target)
			if mode ~= "close" and right and not nudging then
				local sd = strafeChoose(hrp, right, model, comboHotNow(t), t)
				keySet(Enum.KeyCode.D, sd > 0)
				keySet(Enum.KeyCode.A, sd < 0)
			elseif not nudging then
				keySet(Enum.KeyCode.D, false)
				keySet(Enum.KeyCode.A, false)
			end
			if wantW then
				maybeStepJump(hrp, hum, t)
			end
		end
		-- clinch breaker: if they are hugging us, hop away periodically
		if not comboHotNow(t) and distEff < math.max(E_lo - 2.5, 3.5)
			and t - (moveState.clinchJumpAt or 0) > 0.9
			and char:GetAttribute("MinecraftGrounded") ~= false
		then
			moveState.clinchJumpAt = t
			inputJump()
		end
		-- engaged aim: the camera stays ON the target the whole fight — never
		-- fall back to aim.dir mid-fight (that drifts the camera off target)
		aim.target = model
		aim.dir = nil
	else
		-- ---------- smart chase ----------
		-- Direct sprint only when genuinely clear AND close; otherwise keep the
		-- pathfinder engaged (a clear chest-ray through a doorway must not cancel
		-- an active path and send us into the wall next to it). Clear = BOTH the
		-- chest ray and a feet-height ray miss (a low wall hides below the chest).
		local directClear = directClearTo(char, hrp, thrp)
		local flatDist = ((thrp.Position - hrp.Position) * Vector3.new(1, 0, 1)).Magnitude
		-- only close the path at short range; long-range "clear" rays lie
		if nav.active and directClear and flatDist < 14 then
			nav.active = false
		end
		local wantNav = nav.active or (not directClear) or (moveState.stuckCount or 0) >= 1
		if wantNav and t - nav.lastTry > 0.8 and not nav.computing then
			local needNew = (not nav.active)
				or (t - nav.at > 2)
				or (nav.dest ~= nil and (nav.dest - thrp.Position).Magnitude > 6)
			if needNew then
				nav.lastTry = t
				-- intercept destination inside 30 studs, their position beyond
				local dest = flatDist < 30 and iPos or thrp.Position
				navCompute(hrp, dest, Vector3.new(thrp.Position.X, hrp.Position.Y, thrp.Position.Z))
			end
		end
		-- stuck on the way? break a player-placed block or climb (experiments)
		if (moveState.stuckCount or 0) >= 2 and stuckMineHook then
			stuckMineHook(char, hrp, forward)
		end
		local walkDir = forward
		if nav.active then
			local nd = navStep(hrp)
			if nd then
				walkDir = nd
			end
		end
		if not nav.active and t < (moveState.detourUntil or 0) and right then
			walkDir = (moveState.detourSide or 1) > 0 and right or -right
		end
		if walkDir then
			aim.target = nil
			aim.dir = walkDir
		end
		local okW = walkDir ~= nil and safeToMove(hrp, walkDir, 4.5)
		keySet(Enum.KeyCode.W, okW)
		keySet(Enum.KeyCode.S, false)
		if not nudging then
			keySet(Enum.KeyCode.D, false)
			keySet(Enum.KeyCode.A, false)
		end
		if okW then
			maybeStepJump(hrp, hum, t)
		end
	end

	-- sprint upkeep — skipped while a w-tap is in flight (it would undo the tap)
	if not wtapInFlight() then
		ensureSprint(true)
	end
	refreshHeldKeys()
	moveState.engaged = true
end

-- lobby -> arena travel: pathfinding to the arena floor below the drop hole,
-- falling back to a straight walk at the hole. Handles lobby walls/architecture.
local function travelStep(char, hrp)
	-- dynamic detection first (map/lobby can change); hardcoded point only as fallback
	local drop = findDropPoint(hrp) or cfg.dropPoint
	if typeof(drop) ~= "Vector3" then
		if moveState.engaged then
			moveState.engaged = false
			releaseAllKeys()
		end
		return
	end
	local flat = Vector3.new(drop.X, hrp.Position.Y, drop.Z)
	local anchor = findDropFloor(hrp) or Vector3.new(drop.X, hrp.Position.Y - 70, drop.Z)
	local t = os.clock()
	local dist = (flat - hrp.Position).Magnitude

	-- real pathfinding across the lobby (routes around walls, down through the
	-- hole); async — the old path stays live while a recompute is in flight
	if not nav.active and not nav.computing and t - nav.lastTry > 1.5 then
		nav.lastTry = t
		navCompute(hrp, anchor)
	end

	local walkDir = flatDir(hrp.Position, flat)
	local navFollowing = false
	if nav.active then
		local nd = navStep(hrp)
		if nd then
			walkDir = nd
			navFollowing = true
		end
	end

	local right = walkDir and walkDir:Cross(Vector3.new(0, 1, 0)) or nil
	local nudging = checkStuck(hrp, t, right)

	if walkDir then
		aim.target = nil
		aim.dir = walkDir
	end
	local wantW = walkDir ~= nil
	-- straight-line fallback keeps the void guard (except near the hole);
	-- a pathfinding route is trusted to lead us over the edge/into the hole
	if not navFollowing and dist > 6 and walkDir and not safeToMove(hrp, walkDir, 4.5) then
		traceEvent(string.format("travel:Wcancel d=%.1f navFollowing=%s", dist, tostring(navFollowing)), 0.5)
		wantW = false
	end
	keySet(Enum.KeyCode.W, wantW)
	keySet(Enum.KeyCode.S, false)
	if not nudging then
		keySet(Enum.KeyCode.D, false)
		keySet(Enum.KeyCode.A, false)
	end
	if wantW then
		maybeStepJump(hrp, char:FindFirstChildOfClass("Humanoid"), t)
	end
	if G.PvpClubToolDebug then
		G.PvpClubToolDebug.travel = string.format(
			"d=%.1f drop=(%.0f,%.0f,%.0f) nav=%s/%s comp=%s W=%s stuck=%d keys=%s%s%s%s pos=(%.0f,%.0f,%.0f)",
			dist, drop.X, drop.Y, drop.Z, tostring(nav.active), tostring(navFollowing), tostring(nav.computing),
			tostring(wantW), moveState.stuckCount or 0,
			heldKeys[Enum.KeyCode.W] and "W" or "-", heldKeys[Enum.KeyCode.A] and "A" or "-",
			heldKeys[Enum.KeyCode.S] and "S" or "-", heldKeys[Enum.KeyCode.D] and "D" or "-",
			hrp.Position.X, hrp.Position.Y, hrp.Position.Z)
	end
	ensureSprint(true)
	refreshHeldKeys()
	moveState.engaged = true
end

-- auto prestige (lobby, level >= PrestigeConfig.RequiredLevel) ---------------------
-- Yield-free per-tick state machine, called from the lobby branch of stepWorld:
--   idle -> walk (to the Prestige Merchant) -> prompt (fire OpenPrestige) ->
--   openWait (menu Enabled) -> click (PrestigeButton: VIM mouse, then firesignal) ->
--   verify (Prestige string changed / Level dropped; optional confirm button) -> idle.
-- Any failure closes the menu and sleeps 30 s before a full retry from walk.
-- Only the proximity prompt and GUI clicks touch the game — no combat remotes.
local PRESTIGE_WALK_STOP = 8      -- flat studs from the merchant (prompt range is 12)
local PRESTIGE_WALK_TIMEOUT = 25
local PRESTIGE_OPEN_TIMEOUT = 2.0
local PRESTIGE_VERIFY_TIMEOUT = 3.0
local PRESTIGE_RETRY_COOLDOWN = 30

local prestige = {
	phase = "idle", t = 0, tries = 0, cooldownUntil = 0,
	oldPrestige = nil, oldLevel = nil,
	deadline = 0, confirmed = false, seen = nil, scanAt = 0,
	required = nil, result = nil, successes = 0,
}

local function prestigeRequiredLevel()
	if not prestige.required then
		local ok, v = pcall(function()
			return require(RS:FindFirstChild("PrestigeConfig")).RequiredLevel
		end)
		if ok and type(v) == "number" then
			prestige.required = v
		else
			return 200
		end
	end
	return prestige.required
end

local function prestigePrompt()
	local ok, res = pcall(function()
		local sky = workspace:FindFirstChild("SkySpawn")
		local areas = sky and sky:FindFirstChild("SpawnAreas")
		local npc = areas and areas:FindFirstChild("Prestige Merchant")
		local torso = npc and npc:FindFirstChild("Torso")
		local p = torso and torso:FindFirstChild("OpenPrestige")
		if p and p:IsA("ProximityPrompt") then
			return p
		end
		return nil
	end)
	return ok and res or nil
end

local function prestigeStat(name)
	local ls = LocalPlayer:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(name)
	return v and v.Value or nil
end

local function prestigeMenu()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	return pg and pg:FindFirstChild("PrestigeMenu") or nil
end

local function prestigeButtonOf(menu)
	local shade = menu and menu:FindFirstChild("Shade")
	local win = shade and shade:FindFirstChild("Window")
	return win and win:FindFirstChild("PrestigeButton") or nil
end

-- synthetic mouse click at the centre of a GuiObject (instant: move, down, up)
local function prestigeVimClick(btn)
	local ok = pcall(function()
		local pos = btn.AbsolutePosition + btn.AbsoluteSize / 2
		vim:SendMouseMoveEvent(pos.X, pos.Y, game)
		vim:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 1)
		vim:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 1)
	end)
	return ok
end

local function prestigeSignalClick(btn)
	pcall(function()
		firesignal(btn.Activated)
	end)
	pcall(function()
		firesignal(btn.MouseButton1Click)
	end)
end

local function prestigeCloseMenu()
	local menu = prestigeMenu()
	if not menu then
		return
	end
	local closeBtn = nil
	pcall(function()
		closeBtn = menu:FindFirstChild("Close", true)
	end)
	if closeBtn and closeBtn:IsA("GuiButton") and prestigeVimClick(closeBtn) then
		return
	end
	pcall(function()
		menu.Enabled = false
	end)
end

local function prestigeButtonsVisible(menu, skip)
	local out = {}
	pcall(function()
		for _, d in ipairs(menu:GetDescendants()) do
			if d:IsA("TextButton") and d ~= skip and d.Name ~= "Close" and d.Visible and d.AbsoluteSize.X > 0 then
				local tx = string.lower(d.Text)
				if string.find(tx, "confirm", 1, true) or string.find(tx, "prestige", 1, true) or string.find(tx, "yes", 1, true) then
					out[d] = true
				end
			end
		end
	end)
	return out
end

local function prestigeRelease()
	keySet(Enum.KeyCode.W, false)
	aim.dir = nil
end

local function prestigeFail(reason, t)
	prestigeCloseMenu()
	prestigeRelease()
	prestige.phase = "idle"
	prestige.cooldownUntil = t + PRESTIGE_RETRY_COOLDOWN
	prestige.tries += 1
	prestige.result = reason
	traceEvent("prestige:fail " .. tostring(reason), 0.5)
end

-- returns true while a prestige attempt is in progress (caller skips travel)
local function prestigeStep(char, hum, hrp)
	local t = os.clock()
	prestige.t = t

	if prestige.phase == "idle" then
		if t < prestige.cooldownUntil then
			return false
		end
		local lvl = prestigeStat("Level")
		if type(lvl) ~= "number" or lvl < prestigeRequiredLevel() then
			return false
		end
		-- requirement met but not in the lobby: RESET the character — it
		-- respawns at SkySpawn in about a second (BreakJoints, verified live);
		-- the merchant teleport + prestige then run from there. Cross-zone
		-- teleports are server-reverted, so this is the only door home
		-- mid-arena. Everything else stays paused while this runs.
		if hrp.Position.Y < cfg.arenaY then
			if t - (prestige.lastHomeAt or -99) > 10 then
				prestige.lastHomeAt = t
				prestige.result = "respawn-home"
				local okR = pcall(function()
					char:BreakJoints()
				end)
				if not okR then
					pcall(function()
						local hum0 = hum or char:FindFirstChildOfClass("Humanoid")
						if hum0 then
							hum0.Health = 0
						end
					end)
				end
				traceEvent("prestige:reset character -> lobby", 1)
			end
			return true
		end
		prestige.homeTries = nil
		local promptNow = prestigePrompt()
		if not promptNow then
			return false
		end
		-- in the lobby: stand AT the merchant before firing — the server's
		-- prompt is proximity-checked (fired from across the lobby it never
		-- answers). Teleports inside the lobby stick (verified live), so no
		-- walking: one little tp puts us on its doorstep.
		local npcPart0 = promptNow.Parent
		if npcPart0 and npcPart0:IsA("BasePart") then
			local flat0 = ((npcPart0.Position - hrp.Position) * Vector3.new(1, 0, 1)).Magnitude
			if flat0 > 9 then
				if t - (prestige.gotoAt or -99) > 1.5 then
					prestige.gotoAt = t
					prestige.result = "tomarket"
					pcall(function()
						hrp.CFrame = CFrame.new(npcPart0.Position + Vector3.new(8, 1.2, 0.6))
					end)
					traceEvent("prestige:goto merchant (lobby tp)", 1)
				end
				return true
			end
			if t - (prestige.gotoAt or -99) < 0.25 then
				return true -- let the tp settle a beat before firing the prompt
			end
		end
		-- direct confirm failed once before -> walk-up UI flow this round
		-- (lobby only: the NPC lives there; elsewhere retry later)
		if prestige.direct and prestige.result == "verify" then
			if hrp.Position.Y >= cfg.arenaY then
				prestige.phase = "walk"
				prestige.deadline = t + PRESTIGE_WALK_TIMEOUT
				prestige.direct = nil
				prestige.result = nil
				return true
			end
			prestigeFail("outzone", t)
			return false
		end
		-- one-time token capture: the server answers the prompt with
		-- PrestigeAction("Open", <token>); the game's client stores that token
		-- as its confirm argument (u42). We capture the same token and send the
		-- exact same Confirm message the game's own button sends — no walking,
		-- no menu clicks.
		if not prestige.net then
			prestige.net = true
			local pa = game:GetService("ReplicatedStorage"):FindFirstChild("PrestigeAction")
			if pa and pa:IsA("RemoteEvent") then
				table.insert(conns, pa.OnClientEvent:Connect(function(kind, a2)
					if kind == "Open" then
						prestige.token = a2
					end
				end))
			end
		end
		prestige.token = nil
		prestige.direct = nil
		prestige.confirmed = false
		prestige.seen = nil
		prestige.result = nil
		prestige.phase = "awaitToken"
		prestige.deadline = t + 2.5
		pcall(fireproximityprompt, promptNow)
		traceEvent("prestige:prompt fired (direct)", 0.5)
	end

	-- direct path: token received -> send the game's own Confirm message
	if prestige.phase == "awaitToken" then
		if prestige.token ~= nil then
			local pa = game:GetService("ReplicatedStorage"):FindFirstChild("PrestigeAction")
			if pa and pa:IsA("RemoteEvent") then
				prestige.oldPrestige = prestigeStat("Prestige")
				prestige.oldLevel = prestigeStat("Level")
				prestige.direct = true
				prestige.confirmAt = t
				prestige.confFb = true -- skip the VIM button fallback in verify
				pcall(function()
					pa:FireServer("Confirm", prestige.token)
				end)
				traceEvent("prestige:direct confirm sent", 0.5)
				prestige.phase = "verify"
				prestige.deadline = t + PRESTIGE_VERIFY_TIMEOUT
				return true
			end
			prestigeFail("noremote", t)
			return false
		end
		if t > prestige.deadline then
			-- server never answered the prompt: walk-up UI flow, lobby only
			if hrp.Position.Y >= cfg.arenaY then
				prestige.phase = "walk"
				prestige.deadline = t + PRESTIGE_WALK_TIMEOUT
				traceEvent("prestige:no token, fallback to UI", 0.5)
				return true
			end
			prestigeFail("notoken", t)
			return false
		end
		return true
	end

	local prompt = prestigePrompt()
	local npcPart = prompt and prompt.Parent
	if prestige.phase == "walk" or prestige.phase == "prompt" then
		if not (prompt and npcPart and npcPart:IsA("BasePart")) then
			prestigeFail("noprompt", t)
			return false
		end
	end

	if prestige.phase == "walk" then
		local flatDist = ((npcPart.Position - hrp.Position) * Vector3.new(1, 0, 1)).Magnitude
		if flatDist <= PRESTIGE_WALK_STOP then
			prestige.phase = "prompt"
		elseif t > prestige.deadline then
			prestigeFail("walk", t)
			return false
		else
			local dir = flatDir(hrp.Position, npcPart.Position)
			aim.target = nil
			aim.dir = dir
			local wantW = dir ~= nil and safeToMove(hrp, dir, 4.5)
			keySet(Enum.KeyCode.W, wantW)
			keySet(Enum.KeyCode.S, false)
			keySet(Enum.KeyCode.A, false)
			keySet(Enum.KeyCode.D, false)
			if wantW then
				maybeStepJump(hrp, hum, t)
			end
			ensureSprint(true)
			refreshHeldKeys()
			moveState.engaged = true
			return true
		end
	end

	if prestige.phase == "prompt" then
		prestigeRelease()
		pcall(fireproximityprompt, prompt)
		prestige.phase = "openWait"
		prestige.deadline = t + PRESTIGE_OPEN_TIMEOUT
		return true
	end

	if prestige.phase == "openWait" then
		local menu = prestigeMenu()
		if menu and menu.Enabled == true then
			prestige.phase = "click"
		elseif t > prestige.deadline then
			prestigeFail("menu", t)
			return false
		else
			return true
		end
	end

	-- click #1: arm only. The game's own PrestigeMenu handler arms on the first
	-- click ("PRESTIGE <roman>" -> "CONFIRM PRESTIGE") and fires
	-- PrestigeAction:FireServer("Confirm", ...) only on the second, so we do
	-- one click per step. Signal first (the handler is bound to Activated),
	-- with a single VIM click as fallback if the transition stalls.
	if prestige.phase == "click" then
		local menu = prestigeMenu()
		local btn = prestigeButtonOf(menu)
		if not btn then
			if t > prestige.deadline + 1 then
				prestigeFail("button", t)
				return false
			end
			return true
		end
		local lower = string.lower(btn.Text)
		if string.find(lower, "required", 1, true) then
			prestigeFail("notready", t)
			return false
		end
		if btn.Active == false or not string.find(lower, "prestige", 1, true) then
			-- text not settled yet (empty / stale label on a just-opened menu)
			if t > prestige.deadline + 1 then
				prestigeFail("button", t)
				return false
			end
			return true
		end
		prestige.oldPrestige = prestigeStat("Prestige")
		prestige.oldLevel = prestigeStat("Level")
		prestige.seen = prestigeButtonsVisible(menu, btn)
		prestige.armed2 = nil
		prestige.armed3 = nil
		prestige.confFb = nil
		prestigeSignalClick(btn)
		prestige.armAt = t
		prestige.phase = "confirm"
		prestige.deadline = t + PRESTIGE_VERIFY_TIMEOUT
		return true
	end

	-- click #2: the same button must now read "CONFIRM PRESTIGE"
	if prestige.phase == "confirm" then
		local menu = prestigeMenu()
		local btn = prestigeButtonOf(menu)
		local lower = btn and string.lower(btn.Text) or ""
		if btn and string.find(lower, "confirm", 1, true) then
			prestigeSignalClick(btn)
			prestige.confirmAt = t
			prestige.phase = "verify"
			prestige.deadline = t + PRESTIGE_VERIFY_TIMEOUT
			prestige.scanAt = 0
			return true
		end
		-- signal may not have armed it: one VIM fallback, then one signal retry
		if t - (prestige.armAt or t) > 0.8 and not prestige.armed2 then
			prestige.armed2 = true
			if btn then
				prestigeVimClick(btn)
			end
			return true
		end
		if t - (prestige.armAt or t) > 1.8 and not prestige.armed3 then
			prestige.armed3 = true
			if btn then
				prestigeSignalClick(btn)
			end
			return true
		end
		if t > prestige.deadline then
			prestigeFail("confirm", t)
			return false
		end
		return true
	end

	if prestige.phase == "verify" then
		local nowPrestige = prestigeStat("Prestige")
		local nowLevel = prestigeStat("Level")
		if nowPrestige ~= prestige.oldPrestige
			or (type(nowLevel) == "number" and type(prestige.oldLevel) == "number" and nowLevel < prestige.oldLevel) then
			local menu = prestigeMenu()
			if menu and menu.Enabled == true then
				prestigeCloseMenu()
			end
			prestige.phase = "idle"
			prestige.cooldownUntil = 0
			prestige.successes += 1
			prestige.result = "ok"
			return false
		end
		-- the confirm click may not have landed: one VIM fallback, once
		if t - (prestige.confirmAt or t) > 0.9 and not prestige.confFb then
			prestige.confFb = true
			local menu = prestigeMenu()
			local btn = menu and prestigeButtonOf(menu)
			if btn then
				prestigeVimClick(btn)
			end
			return true
		end
		if t > prestige.deadline then
			prestigeFail("verify", t)
			return false
		end
		return true
	end

	prestige.phase = "idle"
	return false
end

-- auto cosmetic crate (Gold): mirrors the game's own CosmeticCrateUI, which buys
-- the coin crate with CosmeticCrateOpen:FireServer("Gold") ("Paid" is the
-- real-money path and is NEVER fired here). Success is inferred from the Coins
-- attribute dropping by the crate cost inside the pending window; the server
-- stays fully authoritative and a crate only ever fires while coins cover it.
local crate = { lastAt = -10, sentAt = 0, pendingFrom = nil, fails = 0, opened = 0, result = nil, cost = nil }

local CRATE_COST_KEYS = { "Price", "Cost", "Coins", "PriceCoins", "CoinPrice", "GoldPrice", "GoldCost" }

local function crateCostOf(entry)
	if type(entry) ~= "table" then
		return nil
	end
	for _, k in ipairs(CRATE_COST_KEYS) do
		local v = tonumber(entry[k])
		if v then
			return v
		end
	end
	return nil
end

local function crateResolveCost()
	if crate.cost ~= nil then
		return
	end
	crate.cost = 10000 -- known coin price of the Gold crate; the dynamic read below may refine it once
	local okRead, modCfg = pcall(function()
		local mod = RS:FindFirstChild("CosmeticCrateConfig")
		if not mod then
			return nil
		end
		-- coroutine + status check keeps this yield-free: an uncached require
		-- parks the throwaway coroutine instead of this Heartbeat step
		local co = coroutine.create(function()
			return require(mod)
		end)
		local okRes, res = coroutine.resume(co)
		if not okRes or coroutine.status(co) ~= "dead" then
			return nil
		end
		return res
	end)
	if not okRead or type(modCfg) ~= "table" then
		return
	end
	local found = nil
	if type(modCfg.Gold) == "number" then
		found = modCfg.Gold
	else
		found = crateCostOf(modCfg.Gold)
	end
	if found == nil then
		for _, k in ipairs({ "Costs", "Prices", "Crates" }) do
			local sub = modCfg[k]
			if type(sub) == "table" then
				if type(sub.Gold) == "number" then
					found = sub.Gold
				else
					found = crateCostOf(sub.Gold)
				end
				if found ~= nil then
					break
				end
			end
		end
	end
	if found == nil then
		for _, entry in ipairs(modCfg) do
			if type(entry) == "table" and entry.Name == "Gold" then
				found = crateCostOf(entry)
				if found ~= nil then
					break
				end
			end
		end
	end
	-- sanity band: a crate price is a plain coin amount; reject odds/weight misreads
	if type(found) == "number" and found >= 100 and found <= 1000000 then
		crate.cost = found
		traceEvent("crate:cost " .. tostring(found), 1)
	end
end

local function crateStep(t)
	if t - (crate.checkedAt or 0) < 0.25 then
		return
	end
	crate.checkedAt = t
	if not cfg.autoCrate then
		return
	end
	local coins = tonumber(LocalPlayer:GetAttribute("Coins"))
	if not coins then
		return
	end
	crateResolveCost()
	if crate.pendingFrom ~= nil then
		if coins <= crate.pendingFrom - crate.cost then
			crate.opened += 1
			crate.result = "opened"
			crate.pendingFrom = nil
			crate.fails = 0
		elseif t - crate.sentAt > 8 then
			crate.pendingFrom = nil
			crate.result = "noresp"
			crate.fails += 1
		end
		if crate.pendingFrom ~= nil then
			return
		end
	end
	local cooldown = crate.fails >= 3 and 60 or 6
	if coins >= crate.cost and t - crate.lastAt >= cooldown then
		local r = RS:FindFirstChild("CosmeticCrateOpen")
		if not r or not r:IsA("RemoteEvent") then
			return
		end
		pcall(function()
			r:FireServer("Gold")
		end)
		crate.lastAt = t
		crate.sentAt = t
		crate.pendingFrom = coins
		crate.result = "sent"
		traceEvent(string.format("crate:fire coins=%.0f", coins), 1)
	end
end

-- discord nametag plug: rewrites every player's overhead name (client-side) to
-- the EZ Hub discord link while KEEPING the game's tags — clan tag, prestige/
-- level badge, rank tag ([VIP]/[MVP]/[OWNER]) and bounty suffix. Only the
-- username part is swapped for the rainbow link. The label is game-owned; we
-- re-apply periodically so rank/kill refreshes can't undo it.
local AD_LINK_TEXT = "discord.gg/6kWbFG5qa7"
local adTag = { lastAt = 0, count = 0, done = setmetatable({}, { __mode = "k" }) }

local function escapeName(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;"))
end

local function rainbowText(s)
	local parts = {}
	local n = #s
	for i = 1, n do
		parts[i] = '<font color="#' .. Color3.fromHSV((i - 1) / n, 1, 1):ToHex() .. '">' .. s:sub(i, i) .. "</font>"
	end
	return table.concat(parts)
end

local AD_LINK_RICH = rainbowText(AD_LINK_TEXT)

-- swap the subject's own name (the game appends it after every tag) for the
-- rainbow link. The name is the last plain-text run before the bounty suffix.
local function adTagLabel(label, subject)
	local text = label.Text
	if text == "" or adTag.done[label] == text then
		return text ~= ""
	end
	local esc = escapeName(subject:IsA("Player") and subject.DisplayName or subject.Name)
	if esc == "" then
		return false
	end
	local init, pos = nil, 1
	while true do
		local s = text:find(esc, pos, true)
		if not s then
			break
		end
		init = s
		pos = s + 1
	end
	if not init then
		return false
	end
	local repl = AD_LINK_RICH
	local len = #esc
	if text:sub(init + len, init + len + 6) == "</font>" then
		-- the name sits inside its own font span: close it, then the rainbow runs
		repl = "</font>" .. repl
		len += 7
	end
	local newText = text:sub(1, init - 1) .. repl .. text:sub(init + len)
	local ok = pcall(function()
		label.RichText = true
		label.Text = newText
	end)
	if ok then
		adTag.done[label] = newText
	end
	return ok
end

local function adTagStep(t)
	if not cfg.adTag then
		return
	end
	if t - adTag.lastAt < 1.5 then
		return
	end
	adTag.lastAt = t
	local n = 0
	local function plug(label, subject)
		if label and label:IsA("TextLabel") and adTagLabel(label, subject) then
			n += 1
		end
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local tag = char and char:FindFirstChild("MinecraftNametag")
		plug(tag and tag:FindFirstChild("PlayerName"), plr)
	end
	local bots = workspace:FindFirstChild("ArenaPvPBots")
	if bots then
		for _, bot in ipairs(bots:GetChildren()) do
			local tag = bot:FindFirstChild("MinecraftNametag")
			plug(tag and tag:FindFirstChild("PlayerName"), bot)
		end
	end
	adTag.count = n
end

-- sticky-target validity: the sticky lasts 12 s, but drop it when a different
-- enemy is right on top of us (<10 studs), when we just took a hurt (retarget
-- the attacker instead), or when the sticky ran >25 studs farther away than
-- where we locked it.
local function stickyValid(hrp)
	if not (stickyTarget and stickyTarget.Parent) then
		return false
	end
	if os.clock() - stickyAt > 12 then
		return false
	end
	local root = stickyTarget:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local d = (root.Position - hrp.Position).Magnitude
	if stickyRefDist > 0 and d - stickyRefDist > 25 then
		return false
	end
	if os.clock() - selfHurtAt < 0.6 and d > 12 then
		return false
	end
	local myId = LocalPlayer.UserId
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId ~= myId and p.Character and p.Character ~= stickyTarget then
			local c = p.Character
			local h = c:FindFirstChildOfClass("Humanoid")
			local r = c:FindFirstChild("HumanoidRootPart")
			if h and r and h.Health > 0 and r.Position.Y < cfg.arenaY
				and (r.Position - hrp.Position).Magnitude < 10
			then
				return false
			end
		end
	end
	return true
end

-- nearest enemy inside the chase radius (players only; used when nothing is
-- hittable). Prefers the sticky target while it stays valid, so the bot
-- does not thrash between two enemies on opposite sides.
local function findApproachTarget(hrp, range)
	if stickyValid(hrp) then
		local shum = stickyTarget:FindFirstChildOfClass("Humanoid")
		local sroot = stickyTarget:FindFirstChild("HumanoidRootPart")
		if shum and shum.Health > 0 and sroot
			and sroot.Position.Y < cfg.arenaY
			and (sroot.Position - hrp.Position).Magnitude <= range + 3
		then
			return sroot
		end
	end
	local myId = LocalPlayer.UserId
	local best, bestD
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId ~= myId then
			local c = p.Character
			local h = c and c:FindFirstChildOfClass("Humanoid")
			local r = c and c:FindFirstChild("HumanoidRootPart")
			-- arena players only (lobby players are in the safe zone)
			if h and r and h.Health > 0 and r.Position.Y < cfg.arenaY then
				local d = (r.Position - hrp.Position).Magnitude
				if d <= range and (not bestD or d < bestD) then
					best, bestD = r, d
				end
			end
		end
	end
	return best, bestD
end

-- survival: when low, flee and eat a golden apple ----------------------------------
-- Eating (decoded from MinecraftGoldenAppleClient): equip the apple tool, then
-- HOLD right mouse — the client fires EatGoldenApple("Begin"); releasing cancels.
-- Server refills health and adds the AppleShield absorption on completion.

-- hotbar keys come from the player's own keybind settings (Slot1 may be Q, etc.)
local SLOT_KEYS = (function()
	local defaults = { "Q", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
	local names = {}
	for i, v in ipairs(defaults) do
		names[i] = v
	end
	local json = LocalPlayer:GetAttribute("PlayerSettingsJSON")
	if type(json) == "string" then
		local ok, data = pcall(function()
			return game:GetService("HttpService"):JSONDecode(json)
		end)
		if ok and type(data) == "table" and type(data.PC) == "table" then
			for i = 1, 8 do
				local n = data.PC["Slot" .. i]
				if type(n) == "string" and n ~= "" then
					names[i] = n
				end
			end
		end
	end
	local keys = {}
	for i = 1, 9 do
		keys[i] = Enum.KeyCode[names[i]] or Enum.KeyCode[defaults[i]]
	end
	return keys
end)()

local function toolNameNow()
	local c = LocalPlayer.Character
	local t = c and c:FindFirstChildOfClass("Tool")
	return t and t.Name or "none"
end

local function tapHotbarKey(kc)
	pcall(function()
		vim:SendKeyEvent(true, kc, false, game)
	end)
	task.delay(0.05, function()
		pcall(function()
			vim:SendKeyEvent(false, kc, false, game)
		end)
	end)
end

-- click a hotbar slot button as a UI fallback (equip via the game's own signal)
local function clickSlotUI(i)
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local pack = pg and pg:FindFirstChild("MinecraftPackHUD")
	local hud = pack and pack:FindFirstChild("SurvivalHUD")
	local slot = hud and hud:FindFirstChild("Slot" .. i)
	if slot then
		pcall(function()
			firesignal(slot.Activated)
		end)
		pcall(function()
			firesignal(slot.MouseButton1Click)
		end)
		return true
	end
	return false
end

-- item availability: the tool must exist (equipped or backpack) and, where the
-- game tracks it, still have Count > 0 — otherwise NEVER touch the hotbar
local function itemAvailable(nameLower)
	local function has(tool)
		if not (tool and tool:IsA("Tool")) then
			return false
		end
		if not string.find(string.lower(tool.Name), nameLower, 1, true) then
			return false
		end
		local cnt = tool:GetAttribute("Count")
		if type(cnt) == "number" and cnt <= 0 then
			return false
		end
		return true
	end
	local c = LocalPlayer.Character
	if c then
		for _, t in ipairs(c:GetChildren()) do
			if has(t) then
				return true
			end
		end
	end
	local bp = LocalPlayer:FindFirstChild("Backpack")
	if bp then
		for _, t in ipairs(bp:GetChildren()) do
			if has(t) then
				return true
			end
		end
	end
	return false
end

-- discovered hotbar slots are cached; the full-slot scan runs at most once per
-- item per 20s so the bot never visibly cycles the inventory over and over
local slotOverride = {}
local lastScanAt = {}

local function equipSlot(slot, nameCheck, opts)
	opts = opts or {}
	if nameCheck(toolNameNow()) then
		return true
	end
	if opts.item and not itemAvailable(opts.item) then
		return false
	end
	local tryOrder = {}
	local cached = opts.item and slotOverride[opts.item]
	if cached then
		table.insert(tryOrder, cached)
	end
	table.insert(tryOrder, slot)
	for _, s in ipairs(tryOrder) do
		local kc = SLOT_KEYS[s]
		if kc then
			tapHotbarKey(kc)
			task.wait(0.25)
			if nameCheck(toolNameNow()) then
				return true
			end
		end
	end
	if opts.scan and opts.item and (os.clock() - (lastScanAt[opts.item] or -100)) > 20 then
		lastScanAt[opts.item] = os.clock()
		for i, key in ipairs(SLOT_KEYS) do
			tapHotbarKey(key)
			clickSlotUI(i)
			task.wait(0.16)
			if nameCheck(toolNameNow()) then
				slotOverride[opts.item] = i
				return true
			end
		end
	end
	return false
end

local function hasGoldenApple()
	return itemAvailable("golden apple")
end

local survival = { eating = false, startedAt = 0 }

local function fleeStep(hrp)
	local enemy = findApproachTarget(hrp, 60)
	local fleeDir
	if enemy then
		fleeDir = flatDir(enemy.Position, hrp.Position)
	end
	if fleeDir then
		local dir = fleeDir
		if not safeToMove(hrp, dir, 4.5) then
			local right = dir:Cross(Vector3.new(0, 1, 0))
			if safeToMove(hrp, right, 4.5) then
				dir = right
			elseif safeToMove(hrp, -right, 4.5) then
				dir = -right
			else
				dir = nil
			end
		end
		if dir then
			aim.target = nil
			aim.dir = dir
			keySet(Enum.KeyCode.W, true)
		else
			keySet(Enum.KeyCode.W, false)
		end
	else
		keySet(Enum.KeyCode.W, false)
	end
	keySet(Enum.KeyCode.S, false)
	keySet(Enum.KeyCode.D, false)
	keySet(Enum.KeyCode.A, false)
	ensureSprint(true)
	refreshHeldKeys()
	moveState.engaged = true
end

local function survivalStep(char, hum, hrp)
	local t = os.clock()
	if not survival.eating then
		-- equip the apple first
		if not equipSlot(cfg.appleSlot, function(n)
			return string.find(string.lower(n), "golden apple", 1, true) ~= nil
		end, { item = "golden apple", scan = true }) then
			return false
		end
		survival.eating = true
		survival.startedAt = t
		pcall(function()
			mouse2press()
		end)
		return true
	end

	-- keep eating; flee from the nearest enemy meanwhile
	fleeStep(hrp)

	local eatingAttr = char:GetAttribute("EatingApple")
	local elapsed = t - survival.startedAt
	local done = (eatingAttr ~= true and elapsed > 0.8) or elapsed > 4.5
	if done then
		pcall(function()
			mouse2release()
		end)
		survival.eating = false
		equipSlot(cfg.swordSlot, function(n)
			return string.find(string.lower(n), "sword", 1, true) ~= nil
		end, { item = "sword", scan = true })
		return false
	end
	return true
end

-- mining: break a player-placed block that is blocking the chase -------------------
-- (pickaxe + hold Attack; the game's building client loops MineStart/MineFinish)
stuckMineHook = function(char, hrp, dir)
	local t = os.clock()
	if t - (moveState.lastMineTry or 0) < 5 then
		return
	end
	moveState.lastMineTry = t
	if not dir then
		return
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }
	local from = hrp.Position + Vector3.new(0, 1.2, 0) + dir * 1.5
	local hit = workspace:Raycast(from, dir * 7, rp)
	if not hit then
		return
	end
	-- only player-placed blocks are breakable
	if not hit.Instance:FindFirstAncestor("PlayerBlocks") then
		return
	end
	if not equipSlot(cfg.pickaxeSlot, function(n)
		return string.find(string.lower(n), "pickaxe", 1, true) ~= nil
	end, { item = "pickaxe", scan = true }) then
		return
	end
	aim.target = nil
	aim.dir = nil
	aim.pos = hit.Position
	pcall(function()
		mouse1press()
	end)
	task.wait(1.4)
	pcall(function()
		mouse1release()
	end)
	aim.pos = nil
	-- if it is still there, one more mining cycle
	local still = workspace:Raycast(from, dir * 7, rp)
	if still and still.Instance:FindFirstAncestor("PlayerBlocks") then
		aim.pos = still.Position
		pcall(function()
			mouse1press()
		end)
		task.wait(1.2)
		pcall(function()
			mouse1release()
		end)
		aim.pos = nil
	end
	equipSlot(cfg.swordSlot, function(n)
		return string.find(string.lower(n), "sword", 1, true) ~= nil
	end, { item = "sword", scan = true })
end

-- building experiment: pillar up when the target is above us ------------------------
-- (grid placement: look straight down, jump, place into the feet cell)
pillarHook = function(char, hrp, thrp)
	if not cfg.buildMode then
		return
	end
	local t = os.clock()
	if t - (moveState.lastPillarTry or 0) < 0.75 then
		return
	end
	if t < (moveState.pillarPauseUntil or 0) then
		return
	end
	if char:GetAttribute("MinecraftGrounded") == false then
		return
	end
	local targetRoot = thrp
	local above = targetRoot.Position.Y - hrp.Position.Y
	local flat = (targetRoot.Position - hrp.Position) * Vector3.new(1, 0, 1)
	-- engage whenever the target is meaningfully above us and roughly overhead
	if above < 3.6 or flat.Magnitude > 9 or flat.Magnitude < 1 then
		return
	end
	if not equipSlot(cfg.cobbleSlot, function(n)
		return string.find(string.lower(n), "cobblestone", 1, true) ~= nil
	end, { item = "cobblestone", scan = true }) then
		-- no cobblestone at all: don't hammer the inventory on every tick
		moveState.pillarPauseUntil = t + 5
		return
	end
	moveState.lastPillarTry = t
	-- grid placement, MC-style: look STRAIGHT DOWN at the block under our feet,
	-- jump, place while airborne -> the block goes into our own feet cell
	aim.target = nil
	aim.pos = hrp.Position - Vector3.new(0, 4.6, 0)
	local pb = workspace:FindFirstChild("PlayerBlocks")
	local before = pb and #pb:GetChildren() or 0
	inputJump()
	local deadline = os.clock() + 0.35
	while os.clock() < deadline do
		local c = LocalPlayer.Character
		if c and c:GetAttribute("MinecraftGrounded") == false then
			break
		end
		task.wait(0.03)
	end
	task.wait(0.1)
	pcall(function()
		mouse2press()
	end)
	task.wait(0.12)
	pcall(function()
		mouse2release()
	end)
	aim.pos = nil
	-- verify a block actually appeared; two silent failures = pause the pillar
	task.wait(0.22)
	if pb then
		local after = #pb:GetChildren()
		if after <= before then
			moveState.pillarFail = (moveState.pillarFail or 0) + 1
			if moveState.pillarFail >= 2 then
				moveState.pillarFail = 0
				moveState.pillarPauseUntil = t + 4
			end
		else
			moveState.pillarFail = 0
		end
	end
	equipSlot(cfg.swordSlot, function(n)
		return string.find(string.lower(n), "sword", 1, true) ~= nil
	end, { item = "sword", scan = true })
end

local function releaseMovement()
	nav.active = false
	aim.target = nil
	aim.dir = nil
	aim.pos = nil
	if moveState.engaged then
		moveState.engaged = false
		releaseAllKeys()
	end
end

-- continuous aim (runs every frame, after the game's camera update) ---------------
-- The aim DIRECTION is the validated eye->aimPoint unit (the game reads the
-- camera LOOK as the attack direction, eye as origin) — the same unit the
-- fire step snaps to, so validation and click always agree. Per-mode speeds:
-- fight snaps hard (2.5x, clamped 36-50), crit holds get 1.5x (24-50) so jumps
-- don't unlock the camera, chase/travel use cfg.aimSpeed. Residual < 6 degrees
-- snaps exact; > 35 degrees closes at double speed so target switches don't
-- linger. Target positions are led by their EMA velocity (the game reads
-- positions 1-2 frames after our write).
pcall(function()
	RunService:UnbindFromRenderStep("PvpClubAim")
end)

RunService:BindToRenderStep("PvpClubAim", Enum.RenderPriority.Camera.Value + 1, function(dt)
	frameDt = frameDt > 0 and (frameDt * 0.8 + dt * 0.2) or dt
	if not cfg.enabled then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local pos
	local fightSpeed = false
	if aim.pos then
		pos = aim.pos
	elseif aim.target and aim.target.Parent then
		local r = aim.target:FindFirstChild("HumanoidRootPart")
		if r then
			pos = aimPointFor(aim.target, r)
			fightSpeed = true
		end
	elseif aim.dir then
		pos = hrp.Position + aim.dir * 12 + Vector3.new(0, 1.5, 0)
	end
	if not pos then
		return
	end
	local eye = geo.Eye(hrp.Position, char:GetAttribute("Sneaking"))
	local toT = pos - eye
	if toT.Magnitude < 1e-4 then
		return
	end
	local unit = toT.Unit
	local speed = cfg.aimSpeed
	if fightSpeed then
		if crit.state ~= "NORMAL" then
			speed = math.clamp(cfg.aimSpeed * 1.5, 24, 50) -- crit-hold
		else
			speed = math.clamp(cfg.aimSpeed * 2.5, 36, 50) -- fight
		end
	end
	local cur = cam.CFrame
	local d = math.clamp(cur.LookVector:Dot(unit), -1, 1)
	local angDeg = math.deg(math.acos(d))
	local desired = CFrame.lookAt(cur.Position, cur.Position + unit)
	if angDeg < 6 then
		cam.CFrame = desired
	else
		if angDeg > 35 then
			speed = speed * 2
		end
		local k = 1 - math.exp(-dt * speed)
		cam.CFrame = cur:Lerp(desired, k)
	end
end)

-- character helpers -----------------------------------------------------------

local function getCharacter()
	local char = LocalPlayer.Character
	if not char or not char.Parent then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not (hum and hrp) or hum.Health <= 0 then
		return nil
	end
	return char, hum, hrp
end

local function getSword(char)
	local tool = char and char:FindFirstChildOfClass("Tool")
	if tool and tool:GetAttribute("MinecraftBow") then
		return nil
	end
	if tool and string.find(string.lower(tool.Name), "sword") then
		return tool
	end
	return nil
end

-- the sword gate used to return silently forever (bow/apple/unequip = no
-- attacks AND no movement). Re-equip on a throttled background thread instead;
-- movement keeps running while the swap happens. Yields nothing on the hot path.
local reequipState = { at = 0, busy = false }
local function trySwordReequip(t)
	if not cfg.autoReequip then
		return
	end
	if reequipState.busy or t - reequipState.at < 1.5 then
		return
	end
	-- don't fight the pillar/mining routines for the hotbar
	if t - (moveState.lastPillarTry or 0) < 1.5 or t - (moveState.lastMineTry or 0) < 1.5 then
		return
	end
	reequipState.at = t
	reequipState.busy = true
	task.spawn(function()
		pcall(function()
			equipSlot(cfg.swordSlot, function(n)
				return string.find(string.lower(n), "sword", 1, true) ~= nil
			end, { item = "sword", scan = true })
		end)
		reequipState.busy = false
	end)
end

-- target selection -------------------------------------------------------------

local function buildCandidates()
	local list = {}
	local myUserId = LocalPlayer.UserId
	for _, p in ipairs(Players:GetPlayers()) do
		-- NOTE: cloneref breaks `==` on instances (verified live), so compare UserIds.
		if p.UserId ~= myUserId and p.Character then
			local root = p.Character:FindFirstChild("HumanoidRootPart")
			-- only chase people in the arena; lobby (safe zone) players are untouchable
			if root and root.Position.Y < cfg.arenaY then
				table.insert(list, p.Character)
			end
		end
	end
	if cfg.includeNPC then
		for m in pairs(npcSet) do
			if m.Parent then
				local root = m:FindFirstChild("HumanoidRootPart")
				if root and root.Position.Y < cfg.arenaY then
					table.insert(list, m)
				end
			end
		end
	end
	return list
end

-- candidate cache: full scans run at <=10 Hz; the CURRENT target is
-- re-validated every frame by recheckTarget below. The vertical-gap filter uses
-- a GROUND reference (lastGroundY), not our live Y — a crit jump raises us ~5
-- studs and must not drop the target mid-air (that "unlocked the camera" and
-- stalled swings for ~0.5 s).
local candidateCache = { list = nil, at = 0 }
local function refreshCandidates(t)
	if candidateCache.list and t - candidateCache.at < 0.1 then
		return candidateCache.list
	end
	candidateCache.list = buildCandidates()
	candidateCache.at = t
	for m in pairs(velTrack) do
		if not m.Parent then
			velTrack[m] = nil
		end
	end
	return candidateCache.list
end

local function selectTarget(char, hrp)
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	local eyeBase = geo.Eye(hrp.Position, char:GetAttribute("Sneaking"))
	local cap = geo.Reach + 0.001

	local candidates = refreshCandidates(os.clock())
	local rayParams = envLOSParams(char)

	local camLook = cam.CFrame.LookVector
	local grounded = char:GetAttribute("MinecraftGrounded") ~= false
	local refY = grounded and hrp.Position.Y or (lastGroundY or hrp.Position.Y)
	local stickyOK = stickyValid(hrp)

	local best, bestScore, bestData
	local dryBest, dryScore, dryData

	for _, model in ipairs(candidates) do
		local hum = model:FindFirstChildOfClass("Humanoid")
		local thrp = model:FindFirstChild("HumanoidRootPart")
		if hum and thrp and hum.Health > 0 then
			local aimPoint = aimPointFor(model, thrp)
			updateVel(model, thrp.Position, os.clock())
			local unit = aimPoint - eyeBase
			local verticalGap = math.abs(thrp.Position.Y - refY)
			if unit.Magnitude >= 1e-4 and verticalGap <= 3.5 then
				unit = unit.Unit
				local dist, part = geo.Hit(eyeBase, unit, thrp.Position, model:GetAttribute("Sneaking"), cap)
				if dist then
					local wall = workspace:Raycast(eyeBase, unit * (dist + 0.5), rayParams)
					if not wall or wall.Distance >= dist - 0.05 then
						local score
						if cfg.scoring == "lowestHP" then
							score = hum.Health
						elseif cfg.scoring == "angle" then
							score = -camLook:Dot(unit)
						else
							score = dist
						end
						-- stick to the current target while it stays valid
						if model == stickyTarget and stickyOK then
							score = score - 1000
						end
						local data = {
							unit = unit,
							eye = eyeBase,
							dist = dist,
							part = part,
							thrp = thrp,
						}
						if isDry(model.Name) then
							-- keep as a fallback: dryness must never stall every swing
							if not dryScore or score < dryScore then
								dryBest, dryScore, dryData = model, score, data
							end
						elseif not bestScore or score < bestScore then
							best, bestScore, bestData = model, score, data
						end
					end
				end
			end
		end
	end
	if best then
		return best, bestData
	end
	return dryBest, dryData
end

-- per-frame re-validation of the current target (one geometry hit + one ray).
-- This is what makes the first swing at the i-frame reopen land in range —
-- selection no longer waits for the attack-rate timer.
local function recheckTarget(char, hrp, model)
	local thrp = model:FindFirstChild("HumanoidRootPart")
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not (thrp and hum and hum.Health > 0) then
		return nil
	end
	local eyeBase = geo.Eye(hrp.Position, char:GetAttribute("Sneaking"))
	local aimPoint = aimPointFor(model, thrp)
	local unit = aimPoint - eyeBase
	local grounded = char:GetAttribute("MinecraftGrounded") ~= false
	local refY = grounded and hrp.Position.Y or (lastGroundY or hrp.Position.Y)
	local verticalGap = math.abs(thrp.Position.Y - refY)
	if unit.Magnitude < 1e-4 or verticalGap > 3.5 then
		return nil
	end
	unit = unit.Unit
	local dist, part = geo.Hit(eyeBase, unit, thrp.Position, model:GetAttribute("Sneaking"), geo.Reach + 0.001)
	if not dist then
		return nil
	end
	local wall = workspace:Raycast(eyeBase, unit * (dist + 0.5), envLOSParams(char))
	if wall and wall.Distance < dist - 0.05 then
		return nil
	end
	return {
		unit = unit,
		eye = eyeBase,
		dist = dist,
		part = part,
		thrp = thrp,
	}
end

-- attack ------------------------------------------------------------------------
-- INPUT MODE (why): the server validates each Attack's seq, and our remote sends
-- poisoned it — big seq seeds made the real client's own clicks get rejected as
-- stale ("sword stops working"). Input-generated attacks carry the game client's
-- own counter and always validate, so the tool aims the camera and clicks for you
-- instead of firing remotes.
--
-- fireAtTarget is YIELD-FREE: it snaps the camera along the validated unit (a
-- tiny correction only when the residual is > 2 degrees — the unconditional
-- snap fought the render-step binder), then clicks through the doClick funnel.
-- Returns true only when a real click happened; the rate timer advances only
-- on that. (The old version task.wait(0.05)'d here — re-entrant Heartbeats
-- stacked extra clicks and flipped sprint.)

local function scheduleDryCheck(name, sentAt, prevSend)
	task.delay(0.6, function()
		local info = dryInfo[name]
		if not info then
			info = { dry = 0, dryUntil = 0, lastLanding = 0 }
			dryInfo[name] = info
		end
		-- any landing OR any combat feedback for our click (e.g. Immune =
		-- i-frames) means the target is fine; only a truly silent target counts
		-- toward "dry". lastFeedbackAt is only set by HitConfirm/Immune now —
		-- our own SprintState toggles must never reset it.
		if info.lastLanding > sentAt - 0.01 or lastFeedbackAt > sentAt - 0.01 then
			info.dry = 0
			return
		end
		-- clicks bunched < 0.1 s apart are ONE attempt: only the last of a
		-- burst gets judged
		if prevSend and sentAt - prevSend < 0.1 then
			return
		end
		local nextSend = lastSendByTarget[name]
		if nextSend and nextSend > sentAt and nextSend - sentAt < 0.1 then
			return
		end
		info.dry += 1
		if info.dry >= 8 then
			info.dry = 0
			info.dryUntil = os.clock() + 4
		end
	end)
end

local function fireAtTarget(target, data, t)
	local owner = Players:GetPlayerFromCharacter(target)
	if owner and owner.UserId == LocalPlayer.UserId then
		return false
	end

	local cam = workspace.CurrentCamera
	if not cam or type(mouse1click) ~= "function" then
		return false
	end

	-- the game reads the camera LOOK as the attack direction (eye as origin):
	-- aim exactly along the validated eye->aimPoint unit, shared with the binder
	local camPos = cam.CFrame.Position
	local d = math.clamp(cam.CFrame.LookVector:Dot(data.unit), -1, 1)
	if math.deg(math.acos(d)) > 2 then
		local okAim = pcall(function()
			cam.CFrame = CFrame.lookAt(camPos, camPos + data.unit)
		end)
		if not okAim then
			return false
		end
	end

	if not doClick(t) then
		return false
	end

	stats.attacksSent += 1
	stats.lastTargetName = target.Name
	stats.lastSendAt = t
	lastClickTarget = target.Name
	lastClickModel = target
	local prevSend = lastSendByTarget[target.Name]
	lastSendByTarget[target.Name] = t
	scheduleDryCheck(target.Name, t, prevSend)
	return true
end

-- telemetry -----------------------------------------------------------------------

local hpTable = {}

table.insert(conns, RunService.Heartbeat:Connect(function()
	for _, p in ipairs(Players:GetPlayers()) do
		local c = p.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if h then
			local prev = hpTable[c]
			if prev and h.Health < prev then
				if c.Name == LocalPlayer.Name then
					-- WE took damage: sticky-target drop signal
					selfHurtAt = os.clock()
				else
					-- HP-drop fallback landing attribution (HitConfirm is the
					-- primary; this stays for safety)
					local sentAt = lastSendByTarget[c.Name]
					if sentAt and (os.clock() - sentAt) < 1.5 then
						stats.hpDamageObserved += (prev - h.Health)
						markLanding(c.Name)
					end
				end
			end
			hpTable[c] = h.Health
		end
	end
	for c in pairs(hpTable) do
		if not c.Parent then
			hpTable[c] = nil
		end
	end
end))

local feedbackCounts = {}

if Feedback then
	table.insert(conns, Feedback.OnClientEvent:Connect(function(kind, a2, a3, ...)
		local t = os.clock()
		if kind then
			feedbackCounts[kind] = (feedbackCounts[kind] or 0) + 1
		end
		-- dry tracking: only real combat responses reset it — our own SprintState
		-- toggles must never count (that starved the dry system before)
		if kind == "HitConfirm" or kind == "Immune" then
			lastFeedbackAt = t
		end
		if kind == "HitConfirm" then
			stats.confirmAny += 1
			stats.lastConfirmAt = t
			if a2 == true then
				stats.critConfirms += 1
			end
			-- the EARLIEST landing signal: attribute to our last click if it was
			-- recent (drives hurtAt -> the i-frame reopen timing)
			if lastClickTarget and t - lastClickAt <= 0.4 then
				markLanding(lastClickTarget)
				iframe.clean += 1
				if iframe.clean >= 6 then
					-- 6 clean landings without an Immune: window is a touch
					-- shorter than we think — drift the estimate down
					iframe.clean = 0
					iframe.est = math.max(IFRAME_MIN, iframe.est - 0.005)
				end
			end
		elseif kind == "Immune" then
			-- we clicked into their i-frame window: lengthen the estimate and
			-- retry shortly (no Immune flood — the click stays gated)
			if lastClickTarget and t - lastClickAt < 0.15 then
				iframe.est = math.min(IFRAME_MAX, iframe.est + 0.02)
				iframe.retryAt = t + 0.06
				iframe.clean = 0
			end
		elseif kind == "ApplyKnockback" then
			-- knockback applied to US: the jump-reset signal (jump within ~50 ms
			-- while grounded — NOT enemy swings, those hop us 8-10 times/sec)
			if typeof(a3) == "Instance" then
				local pl = Players:GetPlayerFromCharacter(a3)
				if (pl and pl.UserId == LocalPlayer.UserId) or a3.Name == LocalPlayer.Name then
					kbJump.at = t
				end
			end
		end
	end))
end

if Flash then
	table.insert(conns, Flash.OnClientEvent:Connect(function(model, ...)
		if typeof(model) ~= "Instance" then
			return
		end
		-- ignore flashes on our own model (those are hits WE took, not hits we landed)
		if model.Name == LocalPlayer.Name then
			return
		end
		local t = os.clock()
		local sentAt = lastSendByTarget[model.Name]
		if sentAt and (t - sentAt) < 0.35 then
			stats.flashesOnTarget += 1
			markLanding(model.Name)
		end
	end))
end

-- focus loss drops synthetic key state; re-press everything we hold on focus gain
table.insert(conns, UserInputService.WindowFocused:Connect(function()
	refreshHeldKeys(true)
end))

-- enemy swing relay: feeds the reactive strafe only. (The old version also
-- jumped on every swing — a clicker swinging 8-10 CPS kept us hopping
-- constantly. Jump-reset is knockback-driven now, in stepWorld.)
if Swing then
	table.insert(conns, Swing.OnClientEvent:Connect(function(who)
		local model = who
		if typeof(who) == "Instance" and who:IsA("Player") then
			model = who.Character
		end
		if typeof(model) == "Instance" and model == currentTarget then
			enemySwingAt = os.clock()
		end
	end))
end

-- aura loop (frame-driven) ------------------------------------------------------
-- stepWorld: survival + travel + selection + movement + aim — every Heartbeat.
-- stepFire:  window timing + crit machine + w-tap + the click funnel.
-- loopBusy:  Heartbeat starts a fresh copy each frame; anything inside that
-- yields (pathfinding compute, equip scan, pillar routine) parks the old copy
-- — re-entries are counted (dbg.busySkips) and skipped, so clicks never
-- double-fire and sprint never flip-flops from parallel copies.

local loopBusy = false
local nextAttackAt = 0
local lastSelectAt = 0
local lastHittableAt = 0
local lastLOSAt = 0

local function stepWorld(t, frame)
	local char, hum, hrp = getCharacter()
	if not char then
		releaseMovement()
		if not cfg.enabled then
			crit.state = "NORMAL"
			wtap.phase = "idle"
		end
		return false
	end
	frame.char, frame.hum, frame.hrp = char, hum, hrp
	frame.grounded = char:GetAttribute("MinecraftGrounded") ~= false
	frame.engageState = "none"

	-- AUTOMATION runs on its own toggles, independent of the aura master
	-- switch: auto prestige and the gold crate keep working with the aura off.
	-- Auto prestige fires from ANY zone the moment the level requirement is
	-- met; go-home (teleport/respawn), the merchant prompt and the Confirm all
	-- run inside prestigeStep. The Gold crate is cooldown-gated, one in flight.
	if cfg.autoPrestige and prestigeStep(char, hum, hrp) then
		return false
	end
	if cfg.autoCrate then
		crateStep(t)
	end
	-- branding runs with the automation (aura-independent)
	adTagStep(t)

	if not cfg.enabled then
		releaseMovement()
		crit.state = "NORMAL"
		wtap.phase = "idle"
		return false
	end

	if char:GetAttribute("EatingApple") or char:GetAttribute("BowDrawStarted") then
		-- survival eat in progress (ours or the player's): keep fleeing + eating
		if char:GetAttribute("EatingApple") == true and cfg.autoEat then
			survivalStep(char, hum, hrp)
			return false
		end
		releaseMovement()
		return false
	end

	-- survival: low health (under 3 hearts by default) -> flee + golden apple
	if cfg.autoEat and survival.eating then
		survivalStep(char, hum, hrp)
		return false
	end
	if cfg.autoEat and hum.Health < cfg.eatHpThreshold and hasGoldenApple() and char:GetAttribute("BowDrawStarted") ~= true then
		survivalStep(char, hum, hrp)
		return false
	end

	-- safe zone (lobby): never attack up here; optionally walk to the drop hole
	if hrp.Position.Y >= cfg.arenaY then
		if cfg.autoTravel then
			travelStep(char, hrp)
		else
			releaseMovement()
		end
		return false
	end

	-- ground reference for the vertical-gap filter (must not follow our jumps)
	if frame.grounded then
		lastGroundY = hrp.Position.Y
	end

	local sword = getSword(char)
	if not sword then
		-- bow/apple/empty: swap back to the sword on a background thread;
		-- movement keeps running meanwhile (used to freeze forever here)
		trySwordReequip(t)
	end

	-- keep block held between attacks
	if cfg.alwaysBlock and cfg.blockHit and sword and not pendingReblock then
		if not blockState and (t - stats.lastSendAt) > 0.18 then
			fireBlock(true)
		end
	end

	-- optional auto-sprint upkeep
	if cfg.autoSprint and sword then
		local moving = hum.MoveDirection.Magnitude > 0.1
		if moving and char:GetAttribute("SprintRequested") ~= true then
			fireSprint(true)
		end
	end

	-- jump-reset is KNOCKBACK-driven: hop within ~50 ms of a real knockback
	-- signal, when grounded (enemy swings only flip the strafe now)
	if cfg.autoJumpReset then
		if char:GetAttribute("KnockbackActive") == true then
			kbJump.at = t
		end
		if kbJump.at > 0 and t - kbJump.at < 0.05 and frame.grounded and crit.state == "NORMAL" then
			kbJump.at = 0
			inputJump()
		end
	end

	-- remember the last verified-safe ground (lava escape runs back to it)
	if frame.grounded and char:GetAttribute("InLava") ~= true then
		local inst = probeGroundAt(hrp.Position, Vector3.zero, 0)
		if inst == nil or not isHazardName(inst.Name) then
			moveState.lastSafePos = hrp.Position
		end
	end

	-- target selection: full scan at <=10 Hz; per-frame re-check of the current
	local target, data = nil, nil
	if t - lastSelectAt >= 0.1 then
		lastSelectAt = t
		target, data = selectTarget(char, hrp)
	end
	if target then
		if target ~= stickyTarget then
			stickyTarget = target
			local r = target:FindFirstChild("HumanoidRootPart")
			stickyRefDist = r and (r.Position - hrp.Position).Magnitude or 0
		end
		stickyAt = t
		currentTarget = target
		lastHittableAt = t
		lastLOSAt = t
	elseif currentTarget and currentTarget.Parent then
		data = recheckTarget(char, hrp, currentTarget)
		if data then
			lastHittableAt = t
			lastLOSAt = t
		end
	else
		currentTarget = nil
	end

	-- engagement hysteresis: recently hittable + flat < ~14 studs + fresh LOS
	-- keeps us "engaged" (camera stays ON the target, clicks only when actually
	-- hittable). Kills the chase/fight flicker at the 9.6-stud reach edge.
	local thrp = nil
	local engaged = false
	if currentTarget and currentTarget.Parent then
		thrp = currentTarget:FindFirstChild("HumanoidRootPart")
	end
	if thrp then
		if data then
			engaged = true
		else
			local flatDist = ((thrp.Position - hrp.Position) * Vector3.new(1, 0, 1)).Magnitude
			if t - lastLOSAt >= 0.5 then
				-- re-test LOS toward them (single ray, all characters excluded)
				local eye = geo.Eye(hrp.Position, char:GetAttribute("Sneaking"))
				local to = aimPointFor(currentTarget, thrp) - eye
				if to.Magnitude > 0.01 then
					if workspace:Raycast(eye, to.Unit * math.min(to.Magnitude + 1, 60), envLOSParams(char)) == nil then
						lastLOSAt = t
					end
				end
			end
			engaged = (t - lastHittableAt) < 1.2 and flatDist <= 14 and (t - lastLOSAt) < 0.5
		end
	end

	-- airtime grace: keep the last target + aim through our own jump arcs even
	-- if hittability/LOS blip (the vertical-gap filter used to drop mid-jump)
	local airborne = (not frame.grounded) or crit.state ~= "NORMAL"
	local effEngaged = engaged
	if not engaged and airborne and thrp and t < (moveState.airGraceUntil or 0) then
		effEngaged = true
		if not moveState.inAirGrace then
			moveState.inAirGrace = true
			airGraceUses += 1
		end
	else
		moveState.inAirGrace = false
	end
	if engaged and airborne and thrp then
		moveState.airGraceUntil = t + 0.4
	end

	frame.target = currentTarget
	frame.thrp = thrp
	frame.data = data
	frame.openOffset = nil

	if not thrp then
		-- nothing engaged: chase the nearest arena player (map-wide)
		if cfg.comboMove then
			local approach = findApproachTarget(hrp, cfg.engageRange)
			if approach and approach.Parent then
				local amodel = approach.Parent
				updateVel(amodel, approach.Position, t)
				local adata = recheckTarget(char, hrp, amodel)
				if adata then
					-- came into reach mid-chase: adopt immediately (no 10 Hz wait
					-- for the first swing)
					currentTarget = amodel
					if amodel ~= stickyTarget then
						stickyTarget = amodel
						stickyRefDist = (approach.Position - hrp.Position).Magnitude
					end
					stickyAt = t
					lastHittableAt = t
					lastLOSAt = t
					frame.target = amodel
					frame.thrp = approach
					frame.data = adata
					frame.distEff = adata.dist
					frame.engageState = "fight"
					comboMoveStep(char, hum, hrp, approach, adata.dist, true, t)
					return true
				end
				aim.target = nil
				aim.dir = flatDir(hrp.Position, interceptPos(hrp, hum, approach, amodel))
				comboMoveStep(char, hum, hrp, approach, nil, false, t)
				frame.engageState = "chase"
				return false
			end
		end
		releaseMovement()
		return false
	end

	-- hit distance for the range controller: measured when hittable (geo.Hit),
	-- estimated (flat - 0.8) otherwise — NEVER raw root-to-root distance
	local distEff
	if data then
		distEff = data.dist
	else
		distEff = math.max(((thrp.Position - hrp.Position) * Vector3.new(1, 0, 1)).Magnitude - 0.8, 0)
	end
	frame.distEff = distEff

	if not cfg.comboMove then
		-- steering is the user's: original behaviour (aim cleared; the fire step
		-- still snaps the camera along the unit right before each click)
		releaseMovement()
		return true
	end

	frame.engageState = effEngaged and "fight" or "chase"
	comboMoveStep(char, hum, hrp, thrp, distEff, effEngaged, t)
	return true
end

local function stepFire(t, frame)
	local char = frame.char
	local hrp = frame.hrp
	if not (char and hrp) then
		return
	end

	-- crit state machine: NORMAL -> JUMP_SENT -> AIRBORNE -> FALL_FIRE.
	-- Deterministic, frame-driven, leftGround latch: MinecraftGrounded lags
	-- reality by 1-3 frames, so the jump is only cancelled if it NEVER left the
	-- ground within 0.15 s — no ground-swing at takeoff wasting the cooldown.
	local velY = hrp.AssemblyLinearVelocity.Y
	local grounded = frame.grounded
	local falling = (not grounded) and velY < -1
	if cfg.critMode then
		if crit.state == "JUMP_SENT" then
			if not grounded then
				crit.leftGround = true
				crit.state = "AIRBORNE"
			elseif not crit.leftGround and t - crit.jumpAt > 0.15 then
				crit.state = "NORMAL"
			elseif t - crit.jumpAt > 0.9 then
				crit.state = "NORMAL"
			end
		elseif crit.state == "AIRBORNE" then
			if falling then
				crit.state = "FALL_FIRE"
			elseif grounded then
				crit.state = "NORMAL"
			elseif t - crit.jumpAt > 0.9 then
				crit.state = "NORMAL"
			end
		elseif crit.state == "FALL_FIRE" then
			if grounded then
				crit.state = "NORMAL"
			end
		end
	else
		crit.state = "NORMAL"
	end

	-- clicks are NEVER held for windows or crits: we swing continuously at the
	-- configured rate (hard-capped by the governor) and let damage land whenever
	-- the victim's window opens — that is how a human spam-clicker plays.
	local target = frame.target
	local data = frame.data
	if not (target and target.Parent and data) then
		frame.block = "notgt"
		return
	end
	if not getSword(char) then
		frame.block = "nosword"
		return
	end

	local name = target.Name

	-- i-frame window info (DEBUG ONLY — no longer throttles clicks)
	local hurt = hurtAt[name]
	if hurt and t - hurt < 1.2 then
		frame.openOffset = math.clamp(iframe.est - 2 * latencyNow() - 0.02, 0.25, 0.45)
	end

	-- rate gate: configured CPS (governor-capped), nothing else throttles
	local readyAt = math.max(nextAttackAt, lastClickAt + MIN_CLICK_GAP)

	-- w-tap: drop sprint in the last ~60 ms before the click; at most one tap
	-- per 0.25 s so sprint isn't held off permanently at high CPS
	if t - wtap.lastEnd > 0.25 then
		wtapPrep(t, readyAt)
	end
	if t < readyAt then
		frame.block = "hold"
		return
	end
	-- if the sprint-off tap just armed this frame, let it register first
	if wtap.phase == "pretap" and t - wtap.pretapAt < 0.03 then
		frame.block = "wtap"
		return
	end

	-- crit entry: deliberate jump only when the target is already in our combo
	-- (spamming crit jumps gets you comboed); falls crit naturally since the
	-- click stream keeps flowing while airborne
	if cfg.critMode and crit.state == "NORMAL" then
		if comboHotNow(t) and grounded
			and frame.distEff and frame.distEff <= geo.Reach - 0.5
			and t - crit.lastJumpAt > cfg.critJumpCooldown
		then
			crit.lastJumpAt = t
			crit.jumpAt = t
			crit.leftGround = false
			crit.state = "JUMP_SENT"
			inputJump()
			frame.block = "critjump"
			return
		end
	end

	if fireAtTarget(target, data, t) then
		frame.block = "sent"
		-- advance the rate timer ONLY on a real click; jitter is upward-only
		local interval = 1 / math.clamp(cfg.cps, CPS_CLAMP.min, CPS_CLAMP.max)
		nextAttackAt = t + interval * (1 + math.random() * cfg.cpsJitter)
		wtapClicked(t)
	else
		frame.block = "fail"
	end
end

local function auraLoop()
	local dbg = G.PvpClubToolDebug
	local t = os.clock()
	if dbg then
		dbg.ticks = (dbg.ticks or 0) + 1
		dbg.last = t
		dbg.enabled = cfg.enabled
	end
	if loopBusy then
		if dbg then
			dbg.busySkips = (dbg.busySkips or 0) + 1
		end
		return
	end
	loopBusy = true
	local frame = {}
	local okLoop, loopErr = pcall(function()
		-- menu/chat guard: with the Roblox escape menu open or a text box
		-- focused (in-game chat), send NO synthetic input at all. Client-level
		-- input still reaches the game while unfocused, so this guard is what
		-- keeps it out of the menu and out of your chat text.
		if game:GetService("GuiService").MenuIsOpen or UserInputService:GetFocusedTextBox() ~= nil then
			releaseMovement()
			frame.block = "menu"
			return
		end
		wtapStep(t)
		if stepWorld(t, frame) then
			stepFire(t, frame)
		else
			frame.block = "world"
		end
		if dbg then
			pruneClicks(t)
			dbg.clicksLast1s = #clickTimes
			dbg.maxClicks1s = math.max(dbg.maxClicks1s or 0, #clickTimes)
			dbg.iframeEst = iframe.est
			if frame.openOffset then
				dbg.lastOpenAt = frame.openOffset
			end
			dbg.engage = frame.engageState or "none"
			dbg.wtap = wtap.phase
			dbg.strafeFlipsPerMin = #strafeFlipTimes
			dbg.airGraceUses = airGraceUses
			dbg.prestige = prestige.phase
			dbg.prestigeResult = prestige.result
			dbg.prestigeTries = prestige.tries
			dbg.prestigeOk = prestige.successes
			dbg.crateResult = crate.result
			dbg.crateOpened = crate.opened
			dbg.adTagCount = adTag.count
			dbg.crateCost = crate.cost
			dbg.critState = crit.state
			dbg.tDist = frame.distEff
			local blk = frame.block or "none"
			dbg.fireBlock = blk
			if type(dbg.fbCount) ~= "table" then
				dbg.fbCount = {}
			end
			dbg.fbCount[blk] = (dbg.fbCount[blk] or 0) + 1
		end
	end)
	loopBusy = false
	if not okLoop and dbg then
		dbg.err = tostring(loopErr)
	end
end

table.insert(conns, RunService.Heartbeat:Connect(auraLoop))

-- keybinds ---------------------------------------------------------------------------

table.insert(conns, UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.RightControl then
		if G.PvpClubTool then
			G.PvpClubTool.Toggle()
		else
			cfg.enabled = not cfg.enabled
		end
		print("[PvpClubTool] aura " .. (cfg.enabled and "ENABLED" or "PAUSED"))
	elseif input.KeyCode == Enum.KeyCode.End then
		G.PvpClubTool.Unload()
	end
end))

-- persisted config ----------------------------------------------------------------

local HttpService = game:GetService("HttpService")
local CONFIG_FILE = "pvp-club-tool-config.json"
local saveDirty = false

local function markDirty()
	saveDirty = true
end

local function saveConfig()
	return pcall(function()
		writefile(CONFIG_FILE, HttpService:JSONEncode({
			cps = cfg.cps,
			cpsJitter = cfg.cpsJitter,
			silentAim = cfg.silentAim,
			blockHit = cfg.blockHit,
			alwaysBlock = cfg.alwaysBlock,
			wTap = cfg.wTap,
			wTapDelayMs = cfg.wTapDelayMs,
			autoSprint = cfg.autoSprint,
			autoReequip = cfg.autoReequip,
			autoPrestige = cfg.autoPrestige,
			autoCrate = cfg.autoCrate,
			adTag = cfg.adTag,
			comboMove = cfg.comboMove,
			engageRange = cfg.engageRange,
			preferredRange = cfg.preferredRange,
			backoffRange = cfg.backoffRange,
			strafeFlipMinMs = cfg.strafeFlipMinMs,
			strafeFlipMaxMs = cfg.strafeFlipMaxMs,
			autoJumpReset = cfg.autoJumpReset,
			critMode = cfg.critMode,
			critComboWindow = cfg.critComboWindow,
			critJumpCooldown = cfg.critJumpCooldown,
			autoTravel = cfg.autoTravel,
			arenaY = cfg.arenaY,
			autoEat = cfg.autoEat,
			eatHpThreshold = cfg.eatHpThreshold,
			buildMode = cfg.buildMode,
			includeNPC = cfg.includeNPC,
			scoring = cfg.scoring,
			aimSpeed = cfg.aimSpeed,
			swingAnim = cfg.swingAnim,
		}))
	end)
end

local function loadConfig()
	local ok, res = pcall(function()
		if isfile(CONFIG_FILE) then
			return HttpService:JSONDecode(readfile(CONFIG_FILE))
		end
		return nil
	end)
	if ok and type(res) == "table" then
		for k, v in pairs(res) do
			if cfg[k] ~= nil then
				cfg[k] = v
			end
		end
	end
end

loadConfig()

-- UI (EZ-UI-Library) ---------------------------------------------------------------

local ui = { EZ = nil, window = nil, handles = {} }

local SCORING_LABEL = { nearest = "Nearest", lowestHP = "Lowest HP", angle = "Angle" }
local SCORING_VALUE = { Nearest = "nearest", ["Lowest HP"] = "lowestHP", Angle = "angle" }

local function buildUI()
	local okLib, lib = pcall(function()
		return loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Library.lua"))()
	end)
	if not okLib or type(lib) ~= "table" then
		print("[PvpClubTool] EZ UI unavailable: " .. tostring(lib))
		return false
	end
	local EZ = lib
	pcall(function()
		local Icons = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/addons/Icons.lua"))()
		if type(Icons) == "table" then
			EZ:SetIcons(Icons)
		end
	end)

	-- SaveManager / ThemeManager addons (pcall'd — a failed fetch only drops
	-- the Themes/Configs boxes; the Settings tab still builds). Bound BEFORE
	-- CreateWindow, and LoadSaved() runs before the window exists so the saved
	-- theme is applied without a colour flash.
	local SaveManager, ThemeManager
	pcall(function()
		local sm = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/addons/SaveManager.lua"))()
		if type(sm) == "table" then
			SaveManager = sm
		end
	end)
	pcall(function()
		local tm = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/addons/ThemeManager.lua"))()
		if type(tm) == "table" then
			ThemeManager = tm
		end
	end)
	if SaveManager then
		pcall(function()
			SaveManager:Bind(EZ, "PvpClubTool")
		end)
	end
	if ThemeManager then
		pcall(function()
			ThemeManager:Bind(EZ, { File = "PvpClubTool_Theme.txt" })
		end)
		pcall(function()
			ThemeManager:LoadSaved()
		end)
		pcall(function()
			for name, tbl in pairs(EZ.Themes) do
				ThemeManager:AddTheme(name, tbl)
			end
		end)
	end

	local Window = EZ:CreateWindow({
		Title = "1.8 PVP Club",
		SubTitle = "aura suite",
		ToggleKey = Enum.KeyCode.RightShift,
		ToggleIcon = "swords",
		-- the Settings tab is built below via AddSettingsTab(); the auto one
		-- would rebind the addons to default files and run its own autoload on
		-- top of this script's own config persistence
		AutoSettings = false,
	})
	ui.EZ = EZ
	ui.window = Window
	local handles = ui.handles

	local combat = Window:AddTab("Combat", "swords")
	local secAura = combat:AddSection("Kill aura")
	handles.AuraEnabled = secAura:AddToggle("AuraEnabled", {
		Text = "Kill aura",
		Default = cfg.enabled,
		Tooltip = "Auto-attacks with the game's own payloads. RightControl also toggles this.",
		Callback = function(v)
			cfg.enabled = v == true
			if not cfg.enabled then
				fireSprint(true)
				fireBlock(false)
			end
			markDirty()
		end,
	})
	secAura:AddSlider("AuraCps", {
		Text = "Attack rate",
		Min = CPS_CLAMP.min,
		Max = CPS_CLAMP.max,
		Default = cfg.cps,
		Increment = 1,
		Suffix = " CPS",
		Tooltip = "Stay well under 20 CPS — autoclicker-like rates are reportedly banned.",
		Callback = function(v)
			cfg.cps = math.clamp(v, CPS_CLAMP.min, CPS_CLAMP.max)
			markDirty()
		end,
	})
	secAura:AddSlider("AuraJitter", {
		Text = "Timing jitter",
		Min = 0,
		Max = 50,
		Default = math.round(cfg.cpsJitter * 100),
		Increment = 5,
		Suffix = "%",
		Callback = function(v)
			cfg.cpsJitter = v / 100
			markDirty()
		end,
	})
	local secTarget = combat:AddSection("Targeting")
	secTarget:AddDropdown("AuraScoring", {
		Text = "Target priority",
		Values = { "Nearest", "Lowest HP", "Angle" },
		Default = SCORING_LABEL[cfg.scoring] or "Nearest",
		Callback = function(v)
			cfg.scoring = SCORING_VALUE[v] or "nearest"
			markDirty()
		end,
	})
	secTarget:AddToggle("OptIncludeNpc", {
		Text = "Include NPC targets",
		Default = cfg.includeNPC,
		Callback = function(v)
			cfg.includeNPC = v == true
			markDirty()
		end,
	})

	local secAim = combat:AddSection("Aiming")
	secAim:AddSlider("AuraAimSpeed", {
		Text = "Aim tracking speed",
		Min = 5,
		Max = 40,
		Default = cfg.aimSpeed,
		Increment = 1,
		Tooltip = "How fast the camera locks onto the target. Higher = snappier; lower = smoother. Tracking runs every frame.",
		Callback = function(v)
			cfg.aimSpeed = v
			markDirty()
		end,
	})

	local secBlock = combat:AddSection("Shield play")
	secBlock:AddToggle("AuraBlockHit", {
		Text = "Block-hit cycle",
		Default = cfg.blockHit,
		Tooltip = "Drops block, attacks, re-blocks after 0.1s — the game client's own pattern.",
		Callback = function(v)
			cfg.blockHit = v == true
			markDirty()
		end,
	})
	secBlock:AddToggle("AuraAlwaysBlock", {
		Text = "Hold block between attacks",
		Default = cfg.alwaysBlock,
		VisibleWhen = "AuraBlockHit",
		Callback = function(v)
			cfg.alwaysBlock = v == true
			markDirty()
		end,
	})

	local secCrit = combat:AddSection("Crit play")
	secCrit:AddToggle("AuraCritMode", {
		Text = "Jump-crits (swing while falling)",
		Default = cfg.critMode,
		Tooltip = "Crits (×1.5 damage) only land while falling. Swings mid-fall always count; the tool only jumps for a crit when the target is already in your combo — spamming jumps gets YOU comboed.",
		Callback = function(v)
			cfg.critMode = v == true
			markDirty()
		end,
	})
	secCrit:AddSlider("AuraCritWindow", {
		Text = "Combo window",
		Min = 6,
		Max = 25,
		Default = math.round(cfg.critComboWindow * 10),
		Increment = 1,
		Suffix = " ×0.1s",
		Tooltip = "How long after landing a hit the target counts as 'in your combo' (crit jumps allowed).",
		VisibleWhen = "AuraCritMode",
		Callback = function(v)
			cfg.critComboWindow = v / 10
			markDirty()
		end,
	})
	secCrit:AddSlider("AuraCritCooldown", {
		Text = "Crit jump cooldown",
		Min = 4,
		Max = 16,
		Default = math.round(cfg.critJumpCooldown * 10),
		Increment = 1,
		Suffix = " ×0.1s",
		VisibleWhen = "AuraCritMode",
		Callback = function(v)
			cfg.critJumpCooldown = v / 10
			markDirty()
		end,
	})

	local movement = Window:AddTab("Movement", "footprints")
	local secSprint = movement:AddSection("Sprint control")
	secSprint:AddToggle("MoveWTap", {
		Text = "W-tap sprint reset",
		Default = cfg.wTap,
		Tooltip = "Taps sprint off just before each swing, back on right after — the 1.8 reduced-knockback hit so targets stay in your combo.",
		Callback = function(v)
			cfg.wTap = v == true
			markDirty()
		end,
	})
	secSprint:AddSlider("MoveWTapDelay", {
		Text = "Re-sprint delay",
		Min = 40,
		Max = 120,
		Default = cfg.wTapDelayMs,
		Increment = 5,
		Suffix = " ms",
		VisibleWhen = "MoveWTap",
		Callback = function(v)
			cfg.wTapDelayMs = v
			markDirty()
		end,
	})
	secSprint:AddToggle("MoveAutoSprint", {
		Text = "Auto sprint upkeep",
		Default = cfg.autoSprint,
		Tooltip = "Keeps sprint requested while you move forward.",
		Callback = function(v)
			cfg.autoSprint = v == true
			markDirty()
		end,
	})

	local secCombo = movement:AddSection("Combo movement (auto WASD)")
	secCombo:AddToggle("MoveCombo", {
		Text = "Combo movement",
		Default = cfg.comboMove,
		Tooltip = "While a target is in range the tool drives movement for you: closes distance, circle-strafes to dodge their aim, backs off when too close. Takes over WASD — toggle off to steer yourself.",
		Callback = function(v)
			cfg.comboMove = v == true
			if not cfg.comboMove then
				releaseMovement()
			end
			markDirty()
		end,
	})
	secCombo:AddSlider("MoveRange", {
		Text = "Band edge (close in above)",
		Min = 6,
		Max = 9.35,
		Default = cfg.preferredRange,
		Increment = 0.05,
		Suffix = " studs",
		Tooltip = "Hit-distance band edge (aim ray reaching their body, not root-to-root). Closes in above it, strafes inside the band. Clamped to just inside real reach (9.35).",
		VisibleWhen = "MoveCombo",
		Callback = function(v)
			cfg.preferredRange = v
			markDirty()
		end,
	})
	secCombo:AddSlider("MoveBackoff", {
		Text = "Band low edge (back off under)",
		Min = 5,
		Max = 8.5,
		Default = cfg.backoffRange,
		Increment = 0.05,
		Suffix = " studs",
		Tooltip = "Backs away when the hit distance drops under this (default 8.5 = reach - 1.1). Never holds W and S together.",
		VisibleWhen = "MoveCombo",
		Callback = function(v)
			cfg.backoffRange = v
			markDirty()
		end,
	})
	secCombo:AddSlider("MoveEngage", {
		Text = "Chase radius",
		Min = 10,
		Max = 512,
		Default = cfg.engageRange,
		Increment = 10,
		Suffix = " studs",
		Tooltip = "Chases the nearest arena player inside this radius. 512 = the whole map (full autoplay).",
		VisibleWhen = "MoveCombo",
		Callback = function(v)
			cfg.engageRange = v
			markDirty()
		end,
	})
	secCombo:AddSlider("MoveStrafeMax", {
		Text = "Strafe safety net max",
		Min = 300,
		Max = 1200,
		Default = cfg.strafeFlipMaxMs,
		Increment = 50,
		Suffix = " ms",
		Tooltip = "Longest a strafe direction is held with no dodge trigger (enemy swing / facing pressure / hazard). Strafe only runs inside the fight band — never while closing.",
		VisibleWhen = "MoveCombo",
		Callback = function(v)
			cfg.strafeFlipMaxMs = v
			markDirty()
		end,
	})
	secCombo:AddToggle("MoveJumpReset", {
		Text = "Knockback jump-reset",
		Default = cfg.autoJumpReset,
		Tooltip = "Hops within ~50 ms of real knockback (server ApplyKnockback / KnockbackActive) — being airborne softens it. Enemy swings only flip the strafe, they never hop you.",
		Callback = function(v)
			cfg.autoJumpReset = v == true
			markDirty()
		end,
	})

	local secTravel = movement:AddSection("Travel")
	secTravel:AddToggle("MoveTravel", {
		Text = "Auto walk to arena (lobby only)",
		Default = cfg.autoTravel,
		Tooltip = "In the lobby (safe zone) the tool never attacks — it walks to the drop hole and falls into the arena.",
		Callback = function(v)
			cfg.autoTravel = v == true
			if not cfg.autoTravel then
				releaseMovement()
			end
			markDirty()
		end,
	})

	local survivalTab = Window:AddTab("Survival", "heart")
	local secEat = survivalTab:AddSection("Health")
	secEat:AddToggle("AuraAutoEat", {
		Text = "Flee + eat golden apple when low",
		Default = cfg.autoEat,
		Tooltip = "Under the HP threshold it disengages, runs from enemies, eats a golden apple (full heal + 2 extra hearts), then re-equips the sword.",
		Callback = function(v)
			cfg.autoEat = v == true
			markDirty()
		end,
	})
	secEat:AddSlider("AuraEatHp", {
		Text = "Eat below (HP)",
		Min = 2,
		Max = 16,
		Default = cfg.eatHpThreshold,
		Increment = 1,
		Suffix = " HP",
		Tooltip = "3 hearts = 6 HP. Default 6 = flees and eats when under 3 hearts.",
		VisibleWhen = "AuraAutoEat",
		Callback = function(v)
			cfg.eatHpThreshold = v
			markDirty()
		end,
	})

	local secLoadout = survivalTab:AddSection("Loadout")
	secLoadout:AddToggle("AutoReequip", {
		Text = "Auto re-equip sword",
		Default = cfg.autoReequip,
		Tooltip = "While the aura runs, swaps a held bow or golden apple back to the sword (throttled, skipped while mining/pillaring).",
		Callback = function(v)
			cfg.autoReequip = v == true
			markDirty()
		end,
	})

	local automationTab = Window:AddTab("Automation", "sparkles")
	local secPrestige = automationTab:AddSection("Prestige")
	secPrestige:AddToggle("AutoPrestige", {
		Text = "Auto prestige at level 200",
		Default = cfg.autoPrestige,
		Tooltip = "In the lobby, when you hit level 200 it walks to the Prestige Merchant, opens the menu and presses prestige. Wipes your level; repeats each 200.",
		Callback = function(v)
			cfg.autoPrestige = v == true
			markDirty()
		end,
	})

	local secCrate = automationTab:AddSection("Cosmetics")
	secCrate:AddToggle("AutoCrateGold", {
		Text = "Auto open Gold crate (10,000 coins)",
		Default = cfg.autoCrate,
		Tooltip = "Whenever you can afford the Gold crate (10,000 coins) it buys and opens one automatically, until coins run short. Fires the game's own CosmeticCrateOpen remote.",
		Callback = function(v)
			cfg.autoCrate = v == true
			markDirty()
		end,
	})

	local buildingTab = Window:AddTab("Building", "hammer")
	local secBuild = buildingTab:AddSection("Building (experimental)")
	secBuild:AddToggle("AuraBuildMode", {
		Text = "Pillar up to targets above you",
		Default = cfg.buildMode,
		Tooltip = "EXPERIMENT: when a target is above you on a structure, it places cobblestone below itself and jumps to climb. Watch it before trusting it.",
		Callback = function(v)
			cfg.buildMode = v == true
			markDirty()
		end,
	})
	secBuild:AddLabel("Mining: when stuck, it breaks player-placed blocks ahead with the pickaxe.")

	local statsTab = Window:AddTab("Stats", "activity")
	local secLive = statsTab:AddSection("Live telemetry")
	handles.statLine1 = secLive:AddLabel("Attacks: 0 | hits: 0 | damage: 0")
	handles.statLine2 = secLive:AddLabel("Target: - | dry: 0 | uptime: 0s")
	handles.statLine3 = secLive:AddLabel("Feedback: -")
	local secNotes = statsTab:AddSection("Notes")
	secNotes:AddLabel("Hits/damage count server feedback arriving right after each send.")
	secNotes:AddLabel("Players that silently absorb attacks are skipped for 10s (dry).")

	-- real library Settings tab (Menu / Themes / Configs groupboxes — a box
	-- whose addon failed to load is skipped) plus the tool's own controls
	local settingsTab = Window:AddSettingsTab()
	local secTool = settingsTab:AddSection("Tool")
	secTool:AddButton({
		Text = "Save settings now",
		Callback = function()
			if saveConfig() then
				pcall(function()
					EZ:Notify({ Title = "PvpClubTool", Content = "Settings saved.", Duration = 2, Type = "success" })
				end)
			end
		end,
	})
	secTool:AddButton({
		Text = "Unload tool",
		Callback = function()
			if G.PvpClubTool then
				G.PvpClubTool.Unload()
			end
		end,
	})
	secTool:AddLabel("Keys: RightControl = aura, End = unload, RightShift = this window.")
	secTool:AddToggle("AdNametag", {
		Text = "Discord nametag plug (EZ Hub)",
		Default = cfg.adTag,
		Tooltip = "Rewrites every player's overhead name tag (client-side) to the rainbow EZ Hub discord link while keeping their clan/prestige/rank tags.",
		Callback = function(v)
			cfg.adTag = v == true
			markDirty()
		end,
	})

	-- addon teardown rides EZ:Destroy(): G.PvpClubTool.Unload and the window X
	-- button both end there, and Destroy runs OnDestroy handlers first
	pcall(function()
		EZ:OnDestroy(function()
			if SaveManager then
				pcall(function()
					SaveManager:Destroy()
				end)
			end
			if ThemeManager then
				pcall(function()
					ThemeManager:Destroy()
				end)
			end
		end)
	end)

	pcall(function()
		handles.watermark = EZ:CreateWatermark({
			Text = "1.8 PVP Club | aura={flag:AuraEnabled} | {fps} fps | {ping} ms",
		})
		if handles.watermark and handles.watermark.Show then
			handles.watermark:Show()
		end
	end)

	pcall(function()
		EZ:Notify({
			Title = "1.8 PVP Club",
			Content = "Aura suite ready. RightControl toggles the aura.",
			Duration = 4,
			Type = "success",
		})
	end)
	return true
end

-- stats display loop
task.spawn(function()
	while true do
		task.wait(0.5)
		if not G.PvpClubTool then
			break
		end
		local h = ui.handles
		if h.statLine1 then
			pcall(function()
				h.statLine1:Set(("Attacks: %d | hits: %d (crits: %d) | damage: %.1f"):format(stats.attacksSent, stats.flashesOnTarget, stats.critConfirms, stats.hpDamageObserved))
				local dryCount = 0
				for _, info in pairs(dryInfo) do
					if info.dryUntil > os.clock() then
						dryCount += 1
					end
				end
				h.statLine2:Set(("Target: %s | dry: %d | uptime: %ds"):format(tostring(stats.lastTargetName), dryCount, math.floor(os.clock() - stats.startedAt)))
				local parts = {}
				for k, v in pairs(feedbackCounts) do
					table.insert(parts, k .. "=" .. tostring(v))
				end
				h.statLine3:Set("Feedback: " .. (#parts > 0 and table.concat(parts, " ") or "-"))
			end)
		end
	end
end)

-- config autosave loop
task.spawn(function()
	while true do
		task.wait(5)
		if not G.PvpClubTool then
			break
		end
		if saveDirty then
			saveDirty = false
			saveConfig()
		end
	end
end)

-- control surface ----------------------------------------------------------------------

G.PvpClubTool = {
	Flags = cfg,
	SetEnabled = function(v)
		cfg.enabled = v == true
		if not cfg.enabled then
			releaseMovement()
			fireBlock(false)
			local c = getCharacter()
			if c and c:GetAttribute("SprintRequested") == false then
				inputTapSprint()
			end
		end
		if ui.handles.AuraEnabled then
			pcall(function()
				ui.handles.AuraEnabled:Set(cfg.enabled, true)
			end)
		end
	end,
	Toggle = function()
		cfg.enabled = not cfg.enabled
		if not cfg.enabled then
			releaseMovement()
			fireBlock(false)
			local c = getCharacter()
			if c and c:GetAttribute("SprintRequested") == false then
				inputTapSprint()
			end
		end
		if ui.handles.AuraEnabled then
			pcall(function()
				ui.handles.AuraEnabled:Set(cfg.enabled, true)
			end)
		end
	end,
	Set = function(key, value)
		if key == "cps" then
			cfg.cps = math.clamp(tonumber(value) or cfg.cps, CPS_CLAMP.min, CPS_CLAMP.max)
		elseif cfg[key] ~= nil or key == "includeNPC" then
			cfg[key] = value
		end
	end,
	GetStats = function()
		local dry = {}
		for name, info in pairs(dryInfo) do
			if info.dryUntil > os.clock() then
				dry[name] = true
			end
		end
		return {
			enabled = cfg.enabled,
			attacksSent = stats.attacksSent,
			confirmAny = stats.confirmAny,
			critConfirms = stats.critConfirms,
			flashesOnTarget = stats.flashesOnTarget,
			hpDamageObserved = stats.hpDamageObserved,
			lastTargetName = stats.lastTargetName,
			feedback = feedbackCounts,
			dryTargets = dry,
			uptime = os.clock() - stats.startedAt,
		}
	end,
	Unload = function()
		saveDirty = false
		pcall(saveConfig)
		for _, c in ipairs(conns) do
			pcall(function()
				c:Disconnect()
			end)
		end
		pcall(function()
			fireBlock(false)
		end)
		releaseMovement()
		pcall(function()
			RunService:UnbindFromRenderStep("PvpClubAim")
		end)
		if ui.EZ then
			pcall(function()
				ui.EZ:Destroy()
			end)
		end
		G.PvpClubTool = nil
		print("[PvpClubTool] unloaded")
	end,
}

-- UI startup (headless-safe)
if buildUI() then
	print("[PvpClubTool] EZ UI attached — RightShift opens the window")
else
	print("[PvpClubTool] running headless (EZ UI unavailable)")
end

print("[PvpClubTool] armed (melee core). RightControl toggles aura, End unloads.")
print("[PvpClubTool] control: getgenv().PvpClubTool — .Set('cps', n) | .GetStats() | .Flags")
