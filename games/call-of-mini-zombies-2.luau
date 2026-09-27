-- Game guard: this module only runs in its own game.
-- game.GameId is the universe id (5497606909), so every place in that game
-- matches. Anywhere else (autoexec, a shared hub, a wrong map entry) it exits
-- before touching anything.
if game.GameId ~= 5497606909 then return end

--[[
	Call of Mini Zombies 2 — zombie ESP + aim assist

	How the game's zombies actually work (reverse-engineered, 2026-09-26):

	  workspace.ClientZombieVisuals
	      the drawn zombie: Model named "<Type>_<Variant>_<guid>"
	      (bosses: "<Type>_Boss_<guid>"), children IsZombie / Head /
	      HumanoidRootPart / Hitbox / mesh limbs + AnimationController.
	      Its parts are CanQuery = false, so nothing raycasts against them —
	      they are decoration.

	  workspace.CURRENT_MAP.<map>.ZombiesSpawnedIn   (normal maps)
	  <mapModel>.Zombie                              (boss raids)
	      the server-owned proxy: Model per zombie with attributes ZombieId,
	      ZombieType, Variant, Alive, VisualState, VisualSerial, and a real
	      Humanoid carrying replicated Health/MaxHealth. Its Head and Torso are
	      CanQuery = true, so THIS is what bullets hit. The client hides it with
	      LocalTransparencyModifier = 1.

	So: the proxy is the data + hitbox, the visual is the picture. Both are
	joined here on the guid. The proxy is located by looking for models that
	carry a zombie identity attribute, because the two layouts above share no
	path and no naming.

	Bosses are Variant == "Boss" (and carry IsBoss/BossId on the proxy).

	Auto leave presses the game's own OK button on the end-of-run screen, which
	both the mission place (MissionComplete) and the boss raid
	(MainMenu.ResultFrame) put up.

	Controls: RightShift hides the window. Aim key defaults to right mouse.
	Stop from the console: getgenv().ComzESP.Stop()
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace = game:GetService("Workspace")

-- queue_on_teleport runs this code the moment the new place loads, which is
-- before the player object exists: LocalPlayer is nil there, and everything below
-- assumes it — it failed with "attempt to index nil with 'CharacterAdded'" and the
-- module never armed, so the farm died at the first hop. Wait for it. The loader
-- one-liner usually gets away with this because the HTTP fetch takes long enough
-- for the player to appear; loading off disk does not.
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	for _ = 1, 100 do
		task.wait(0.1)
		LocalPlayer = Players.LocalPlayer
		if LocalPlayer then break end
	end
end
if not LocalPlayer then return end

local G = getgenv()

-- A previous injection owns render-step bindings and Drawing objects; drop it
-- before creating new ones, or the old ESP keeps drawing over the new one.
if G.ComzESP and G.ComzESP.Stop then pcall(G.ComzESP.Stop) end

----------------------------------------------------------------
-- surviving a teleport
----------------------------------------------------------------

-- A place change destroys this script outright — verified on a live client:
-- getgenv().ComzESP went nil on the hub -> match hop and on the match -> hub hop,
-- because the client is rebuilt from scratch. The CO-OP survival loop teleports
-- twice per run (START, then the result screen's OK), so without this it plays
-- exactly one match and then disappears.
local REARM_CODE = [[loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/loader.lua"))()]]

-- The loader always fetches the published module, which is right for anyone who
-- started from the one-liner. ComzRearm lets a local run substitute its own code
-- so an edited file can be tested across a teleport before it is pushed.
local function rearmAfterTeleport()
	local code = REARM_CODE
	local override = G.ComzRearm
	if type(override) == "string" and #override > 0 then code = override end

	local fn
	if type(queue_on_teleport) == "function" then
		fn = queue_on_teleport
	elseif type(queueonteleport) == "function" then
		fn = queueonteleport
	end
	if not fn then return false end
	return pcall(fn, code)
end

-- What the farm should be doing has to outlive the teleport too, and the EZ config
-- is only restored if autoload happens to be set up. One small file carries it
-- instead, so the loop works without depending on that.
--
-- The map and difficulty are in there for a reason: the loop uses three of them
-- per run, and if only the on/off survived then picking Glacier and Hard would
-- quietly go back to Warehouse on Normal after the first match.
local INTENT_FILE = "comz-survival.txt"

-- `ok` distinguishes "the file says the farm is off" from "the file could not be
-- read". Without it a single transient failure reads as false, and syncIntent then
-- writes that false back — silently switching the farm off and persisting it. That
-- happened for real: the intent file was found reading enabled=0 with the user
-- never having touched it.
local function readIntent()
	local out = { enabled = false, map = nil, difficulty = nil, ok = false }
	if type(isfile) ~= "function" or type(readfile) ~= "function" then return out end

	local okFile, exists = pcall(isfile, INTENT_FILE)
	if not okFile then return out end
	if not exists then
		-- No file at all is a real answer: the farm has never been switched on.
		out.ok = true
		return out
	end

	local okRead, data = pcall(readfile, INTENT_FILE)
	if not okRead or data == nil then return out end
	out.ok = true
	data = tostring(data)

	-- The first version of this file held a bare "0"/"1". Migrate it rather than
	-- reading it as an empty config, which would silently switch the farm off for
	-- anyone upgrading with it already on.
	if not data:find("=", 1, true) then
		out.enabled = data:find("1", 1, true) ~= nil
		return out
	end

	for line in data:gmatch("[^\r\n]+") do
		local key, value = line:match("^(%w+)=(.*)$")
		if key == "enabled" then out.enabled = value == "1"
		elseif key == "map" and value ~= "" then out.map = value
		elseif key == "difficulty" and value ~= "" then out.difficulty = value end
	end
	return out
end

local function writeIntent(intent)
	if type(writefile) ~= "function" then return end
	pcall(writefile, INTENT_FILE, ("enabled=%s\nmap=%s\ndifficulty=%s\n"):format(
		intent.enabled and "1" or "0", tostring(intent.map or ""), tostring(intent.difficulty or "")))
end

----------------------------------------------------------------
-- defaults (also the fallback when the library fails to load)
----------------------------------------------------------------

-- Read once, before the defaults, because three of them come out of it: the
-- on/off and the map and difficulty. Switching the farm on has to survive the
-- teleport that starting a match performs, or the loop gets one run and then
-- loads back up switched off, on a different map.
local SAVED_INTENT = readIntent()

local DEFAULTS = {
	EspEnabled = true,
	ShowBox = true,
	ShowFill = false,
	ShowName = true,
	ShowDistance = true,
	ShowHealth = true,
	ShowChams = false,
	ShowTracer = false,

	BoxColor = Color3.fromRGB(255, 64, 64),
	BossColor = Color3.fromRGB(255, 170, 40),
	DeadColor = Color3.fromRGB(120, 120, 130),
	BoxThickness = 1,
	FillTransparency = 0.75,
	NameSize = 13,
	TracerOrigin = "Bottom",
	TracerThickness = 1,
	ChamsThroughWalls = true,
	ChamsFillTransparency = 0.6,
	ChamsOutlineTransparency = 0,

	MaxDistance = 500,
	TypeFilter = nil, -- nil = every type
	DrawDead = false,
	DrawBosses = true,

	AimEnabled = false,
	-- Degrees, not pixels. A pixel radius silently changes the real cone with the
	-- player's resolution, so the same 150 meant a wide sweep on a 1080p client
	-- and a narrow one on 1440p.
	AimFovDeg = 20,
	ShowFov = true,
	AimSpeed = 35,
	AimDistance = 300,
	AimPart = "Head",
	AimVisibleOnly = true,
	-- Nearest by distance, not nearest to the crosshair: the crosshair rule was
	-- default and it kept picking whatever happened to sit under the reticle,
	-- including something far away, while a zombie was already on top of the run.
	AimPriority = "Nearest",
	-- Fire only when the crosshair is genuinely on the target. Without this the
	-- triggerbot fired the moment a target was selected, while the camera was
	-- still easing in at AimSpeed, so most rounds left before the gun pointed at
	-- anything. This is what makes it a head tap instead of a spray.
	AimFireGate = 1.6,
	-- Keep the current target unless another is at least this much better (%).
	-- Re-picking the nearest every frame makes it flip between neighbours in a
	-- crowd, and every flip swings the whole camera.
	AimSwitchMargin = 25,
	-- Bullets in this game are real projectiles carrying the weapon's own
	-- BulletSpeed (FN-2000 = 2000), so a moving target has to be led.
	AimLead = true,
	-- 0 = read BulletSpeed off the equipped weapon; anything else overrides it.
	AimLeadSpeed = 0,
	-- Draw a marker on the proxy part being aimed at. The proxy is invisible and
	-- sits ~1.17 studs from the rendered head, so without this the crosshair looks
	-- off the zombie even when it is exactly on the hitbox.
	ShowAimPoint = true,
	-- The game's reticle is not where the gun shoots. Measured on a live client:
	-- Mouse.UnitRay and the game's own AimAssist ray both project to absolute
	-- y = 482, while GunGUI.Crosshair.Center — the dot you aim with — is drawn at
	-- absolute y = 511, i.e. 29 px lower. So the shots go to the hitbox and the
	-- reticle below it makes that read as "it aims under the head".
	--
	-- On, the aim is raised by that measured angle so the reticle sits on the
	-- target. That is only cosmetic: it moves the shots up by the same 2.45
	-- degrees, so anything that relies on hitting will do worse. Off by default
	-- because the camera axis is where the bullets actually go.
	AimFollowCrosshair = false,
	-- Extra lift applied on the head, as a percentage of its half height. 0 aims at
	-- the point nearest the rendered head; positive moves it up toward the crown.
	-- Up to 90 it stays inside the hitbox and the hit is guaranteed; past that it is
	-- deliberately above the head, which is allowed because the gun resolves hits
	-- with a 2.5-stud region rather than a ray. Slider goes to 150.
	--
	-- Defaults to 70 because of what the game actually credits. Hooking
	-- ReplicatedStorage.Remotes.InflictTarget — the gun sends the part it hit and
	-- the server only counts a headshot if that part is named Head or Head2 —
	-- gives ground truth, and aiming at the head's centre credited mostly Torso.
	-- Measured over live matches: 0 of 4 shots to the head at 0, 48 of 150 (~32%)
	-- at 70. Aiming high enough pushes the top of the Torso out of whatever the
	-- gun's hit test covers, so some of the shots start counting.
	--
	-- It is not a full fix: most shots still credit Torso, and slowing the fire
	-- rate to let the weapon's spread settle did not change the ratio (25% at
	-- 3 shots/sec against 34% at 12), so the rest is inside the game's own hit
	-- resolution rather than anything this script controls. A low-spread weapon
	-- headshots far more often than this 30-round SMG.
	AimHeightBias = 70,
	Triggerbot = false,
	TriggerCps = 12,

	AutoLeave = true,
	AutoLeaveDelay = 3,
	-- Off by default. The fallback fires exactly when the game's own OK handler
	-- has already wedged, and then mutates more game state on top of it
	-- (BeginTutorial, ResetMenu, hiding the screen) — which races that handler
	-- rather than repairing it. Pressing OK is what a player does; anything
	-- beyond that is the script guessing at the game's internals.
	AutoLeaveForce = false,

	FarmEnabled = false,
	FarmAutoStart = true,
	FarmAutoFight = true,
	FarmStartDelay = 2,
	FarmMaxLosses = 3,
	FarmStopOnMoveTask = true,
	FarmClaimTasks = true,

	MoveEnabled = true,
	MoveKeepDistance = 26,
	MoveStandoff = 10,
	MoveFleeHealth = 35,
	MoveDodgeRadius = 30,
	MoveHazardRadius = 10,
	-- Kiting dies in a corner: once the horde has you in one there is no heading
	-- left that gains ground, so headings back toward the middle of the map get a
	-- small bonus.
	MoveAvoidCorners = true,

	-- Presses the game's own side-ability button. OFF BY DEFAULT because testing
	-- could not get it to fire: the button's handler bails out unless the ability's
	-- own conditions are met (JoeBlo's dash needs a zombie in front, and the
	-- presentation module returns nil without one), and even a valid presentation
	-- token sent by hand did not start the cooldown server-side. Turn it on to try
	-- it — a press that does nothing is harmless, but it is not yet a speed source
	-- to rely on the way the slider below is.
	AbilityAuto = false,

	-- Off by default, deliberately. See the speed section for why raising
	-- WalkSpeed in this game is a real risk rather than a formality.
	SpeedBoostEnabled = false,
	SpeedBoostValue = 20,

	-- CO-OP survival. All three of the ones that steer the loop come out of the
	-- saved intent, so switching it on and picking a map survives the teleport
	-- that starting a match performs.
	SurvivalEnabled = SAVED_INTENT.enabled,
	SurvivalAutoStart = true,
	SurvivalAutoFight = true,
	SurvivalLeaveAfterWipe = true,
	SurvivalMaxRuns = 0,
	SurvivalMap = SAVED_INTENT.map or "Warehouse",
	SurvivalDifficulty = SAVED_INTENT.difficulty or "Normal",
}

local EZ, Window
local aimKeyHandle

-- Read straight out of the library's flag table: SaveManager restores configs
-- through the element handles, so the flags are always the live values.
local function flag(id)
	if EZ and EZ.Flags then
		local v = EZ.Flags[id]
		if v ~= nil then return v end
	end
	return DEFAULTS[id]
end

----------------------------------------------------------------
-- entity model: proxies (data) joined to visuals (picture) on the guid
----------------------------------------------------------------

local Entities = {}     -- [guid] = entity
local zombieModels = {} -- every proxy + visual model, for raycast filtering
local proxyCount = 0

-- [proxy model] = { pos, at, vel } — how fast each zombie is moving, for leading
-- a shot. Sampled in rebuildEntities (which already visits every proxy, and 10 Hz
-- is plenty) and keyed on the proxy model, because the entity tables themselves
-- are rebuilt from scratch on every scan.
local trackHistory = setmetatable({}, { __mode = "k" })

-- Filled by knownTypes() when the filter dropdown is built. Declared up here
-- because renderESP reads it, and a local declared further down would not be in
-- scope there — it would silently resolve to a global instead.
local knownTypeSet = {}

-- A proxy is any model carrying a zombie identity. The game names the
-- attributes differently per mode: ZombieId/ZombieType for ordinary zombies,
-- BossId/BossType for bosses. Bosses carry no Variant attribute at all.
local function proxyIdentity(model)
	if not model:IsA("Model") then return nil end

	local id = model:GetAttribute("ZombieId") or model:GetAttribute("BossId")
	if id == nil then return nil end

	return id, model:GetAttribute("ZombieType") or model:GetAttribute("BossType") or model.Name
end

local containers, containersAt = {}, 0

-- Containers are found by walking for identity-bearing models rather than by
-- name, because the two modes put them in unrelated places:
--     normal maps  CURRENT_MAP.<map>.ZombiesSpawnedIn.<proxy>
--     boss raids   <mapModel>.Zombie        (a bare model beside the map parts)
-- The walk descends only through Models and Folders — map geometry is parts, so
-- it prunes hard — and stops at a node budget. Re-run on a slow timer, since a
-- map swap replaces everything at once.
local function proxyContainers()
	local now = os.clock()
	if #containers > 0 and now - containersAt < 3 then return containers end
	containersAt = now

	local found, seen, budget = {}, {}, 1500

	local function addContainer(parent)
		if parent and not seen[parent] then
			seen[parent] = true
			found[#found + 1] = parent
		end
	end

	local function walk(inst, depth)
		if budget <= 0 or depth > 3 then return end
		for _, child in ipairs(inst:GetChildren()) do
			budget = budget - 1
			if budget <= 0 then return end
			if child:IsA("Model") then
				if proxyIdentity(child) then
					addContainer(child.Parent)
				else
					walk(child, depth + 1)
				end
			elseif child:IsA("Folder") then
				walk(child, depth + 1)
			end
		end
	end

	local roots = {}
	local cm = Workspace:FindFirstChild("CURRENT_MAP")
	if cm then
		for _, child in ipairs(cm:GetChildren()) do roots[#roots + 1] = child end
	end
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model") or child:IsA("Folder") then roots[#roots + 1] = child end
	end

	for _, root in ipairs(roots) do
		if budget <= 0 then break end
		if root:IsA("Model") and proxyIdentity(root) then
			addContainer(root.Parent)
		else
			walk(root, 1)
		end
	end

	containers = found
	return found
end

local function rebuildEntities()
	local byId = {}
	proxyCount = 0

	for _, container in ipairs(proxyContainers()) do
		for _, proxy in ipairs(container:GetChildren()) do
			local id, ztype = proxyIdentity(proxy)
			if id then
				proxyCount = proxyCount + 1
				local hum = proxy:FindFirstChildOfClass("Humanoid")
				local isBoss = proxy:GetAttribute("IsBoss") == true
					or proxy:GetAttribute("BossId") ~= nil
				-- Bosses carry no Variant attribute, so they are labelled here
				-- rather than defaulting to "Normal" and reading as a minion.
				local variant = proxy:GetAttribute("Variant") or (isBoss and "Boss") or "Normal"
				byId[id] = {
					id = id,
					proxy = proxy,
					ztype = ztype,
					variant = variant,
					alive = proxy:GetAttribute("Alive") ~= false,
					isBoss = isBoss or variant == "Boss",
					hp = hum and hum.Health or nil,
					maxHp = hum and hum.MaxHealth or nil,
				}
			end
		end
	end

	-- A visual with no proxy is in its death animation: the server drops the
	-- proxy first and the client fades the model out over ~1.5s before deleting
	-- it. Treat it as dead so the aimbot does not lock onto a corpse — unless
	-- we found no proxies at all, which means the map has not streamed in yet.
	local sawProxies = proxyCount > 0
	local visuals = Workspace:FindFirstChild("ClientZombieVisuals")
	local models = {}

	if visuals then
		for _, model in ipairs(visuals:GetChildren()) do
			if model:IsA("Model") and model:FindFirstChild("IsZombie") then
				local ztype, variant, id = model.Name:match("^([%w]+)_([%w]+)_(.+)$")
				if not id then
					ztype, variant, id = model.Name, "?", model.Name
				end

				local e = byId[id]
				if not e then
					e = { id = id, ztype = ztype, variant = variant, alive = not sawProxies }
					byId[id] = e
				end

				e.model = model
				e.root = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Hitbox")
				e.head = model:FindFirstChild("Head")
				if e.isBoss == nil then e.isBoss = variant == "Boss" end
				models[#models + 1] = model
			end
		end
	end

	for _, e in pairs(byId) do
		if e.proxy and e.proxy.Parent then models[#models + 1] = e.proxy end
	end

	-- Sample how fast each zombie is moving while the walk already has its hands
	-- on the proxy. Read from position history rather than AssemblyLinearVelocity:
	-- this game moves things by writing CFrames (the visuals are anchored), so a
	-- physics velocity is frequently zero and every lead would be a no-op.
	local now = os.clock()
	for _, e in pairs(byId) do
		local proxy = e.proxy
		local part = proxy
			and (proxy:FindFirstChild("Head") or proxy:FindFirstChild("Torso"))
		if part then
			local prev = trackHistory[proxy]
			local pos = part.Position
			if not prev then
				trackHistory[proxy] = { pos = pos, at = now }
			else
				local dt = now - prev.at
				if dt > 0.02 and dt < 0.6 then
					local v = (pos - prev.pos) / dt
					-- Smoothed: a single 0.1s difference is noisy, and a jittery
					-- lead is worse than none at all.
					prev.vel = prev.vel and (prev.vel * 0.65 + v * 0.35) or v
					prev.pos, prev.at = pos, now
				elseif dt >= 0.6 then
					prev.pos, prev.at, prev.vel = pos, now, nil
				end
			end
		end
	end

	Entities = byId
	zombieModels = models
end

----------------------------------------------------------------
-- oriented bounding box, cached per model
----------------------------------------------------------------

-- GetBoundingBox() is the only way to size these rigs correctly — the visual
-- has limbs the proxy does not. Corners are stored relative to the model's own
-- root CFrame once, then re-projected through the live CFrame each frame, so
-- the box rotates with the zombie and stays cheap.
local cornersCache = setmetatable({}, { __mode = "k" })

local function getCorners(model, root)
	local cached = cornersCache[model]
	if cached then return cached end

	local ok, cf, size = pcall(model.GetBoundingBox, model)
	if not ok or typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" or size.Y < 0.5 then
		return nil
	end

	local inv = root.CFrame:Inverse()
	local corners = table.create(8)
	for _, sx in ipairs({ -0.5, 0.5 }) do
		for _, sy in ipairs({ -0.5, 0.5 }) do
			for _, sz in ipairs({ -0.5, 0.5 }) do
				corners[#corners + 1] = inv * (cf * Vector3.new(sx * size.X, sy * size.Y, sz * size.Z))
			end
		end
	end
	cornersCache[model] = corners
	return corners
end

----------------------------------------------------------------
-- drawing pool
----------------------------------------------------------------

local DRAWING_OK = type(Drawing) == "table" and type(Drawing.new) == "function"
local FONT = (Drawing and Drawing.Fonts and Drawing.Fonts.Plex) or 0

local pools = {}      -- [guid] = drawing set
local poolFree = {}   -- recycled drawing sets, see newPool/releasePool
local chams = {}      -- [guid] = Highlight
local chamsFree = {}  -- recycled Highlights
local chamsFolder
local fovCircle
local aimPoint

-- Drawing objects are expensive to create and destroy, and in survival they were
-- being created and destroyed constantly: sixty-odd zombies on screen with new
-- ones spawning and dying every second meant dozens of pools a second, eight
-- Drawing objects each, plus a Highlight. Create/destroy churn on that scale is
-- the thing that varies most between executor Drawing implementations, and it is
-- the most likely reason this game crashes on one of them after a while.
--
-- Pools are recycled instead. A zombie that dies hands its pool back and the next
-- one to spawn picks it up, so the object count settles at roughly the number of
-- zombies alive at once and then stops moving. Both free lists are capped so a map
-- with a huge one-off horde cannot leave every one of those objects resident
-- afterwards — 80 spares is 640 Drawings, which is already a generous ceiling.
local POOL_FREE_MAX = 80

local function newPool()
	local reused = table.remove(poolFree)
	if reused then return reused end

	local p = {
		box = Drawing.new("Square"),
		fill = Drawing.new("Square"),
		name = Drawing.new("Text"),
		dist = Drawing.new("Text"),
		hp = Drawing.new("Text"),
		barBg = Drawing.new("Square"),
		bar = Drawing.new("Square"),
		trace = Drawing.new("Line"),
	}

	p.box.Filled = false
	p.fill.Filled = true
	p.barBg.Filled = true
	p.bar.Filled = true
	p.barBg.Color = Color3.fromRGB(16, 16, 20)

	for _, t in ipairs({ p.name, p.dist, p.hp }) do
		t.Center = true
		t.Outline = true
		t.Font = FONT
	end
	p.name.Size = flag("NameSize")
	p.dist.Size = 12
	p.hp.Size = 12

	return p
end

local function hidePool(p)
	p.box.Visible = false
	p.fill.Visible = false
	p.name.Visible = false
	p.dist.Visible = false
	p.hp.Visible = false
	p.barBg.Visible = false
	p.bar.Visible = false
	p.trace.Visible = false
end

local function destroyPool(p)
	for _, obj in pairs(p) do pcall(function() obj:Remove() end) end
end

-- Hand a pool back for reuse rather than tearing it down. Hidden first, so a
-- recycled pool can never flash on screen at its previous position.
local function releasePool(p)
	hidePool(p)
	if #poolFree >= POOL_FREE_MAX then
		destroyPool(p)
		return
	end
	poolFree[#poolFree + 1] = p
end

local function protectedParent()
	local ok, hui = pcall(function() return gethui and gethui() end)
	if ok and typeof(hui) == "Instance" then return hui end
	ok, hui = pcall(function() return game:GetService("CoreGui") end)
	if ok and typeof(hui) == "Instance" then return hui end
	return LocalPlayer:WaitForChild("PlayerGui")
end

local function chamsFor(e)
	local h = chams[e.id]
	if not h then
		-- Recycled in the same way as the drawing pools: a Highlight per zombie,
		-- created and destroyed with every spawn and death, added up to the same
		-- kind of churn.
		h = table.remove(chamsFree)
		if not h then
			h = Instance.new("Highlight")
			h.Name = "ComzChams"
			h.Parent = chamsFolder
		end
		chams[e.id] = h
	end
	h.Adornee = e.model
	return h
end

-- Hand a Highlight back for reuse: disabled and detached first, so a recycled one
-- cannot show up adorning the wrong model.
local function releaseChams(id)
	local h = chams[id]
	if not h then return end
	h.Enabled = false
	h.Adornee = nil
	chams[id] = nil
	if #chamsFree >= POOL_FREE_MAX then
		pcall(function() h:Destroy() end)
		return
	end
	chamsFree[#chamsFree + 1] = h
end

----------------------------------------------------------------
-- line of sight (cached — a raycast per zombie per frame is wasteful)
----------------------------------------------------------------

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
-- Weakly keyed on the guid: entries are only useful while the zombie exists, and
-- a session's worth of unique guids otherwise accumulates here forever.
local visCache = setmetatable({}, { __mode = "k" })
local VIS_TTL = 0.1

-- The ray is aimed AT the target and the target is deliberately left hittable:
-- whatever it hits first is the answer. If that is the target's own proxy or
-- visual, the line is clear; if it is anything else, something got in the way.
-- (Excluding the target instead and requiring an empty hit cannot work — the
-- first thing the ray meets is the target itself, so every zombie reads as
-- blocked, which is exactly how this first went wrong.)
local function isVisible(e, worldPos)
	local cam = Workspace.CurrentCamera
	if not cam then return false end

	local cached = visCache[e.id]
	local now = os.clock()
	if cached and cached.expires > now then return cached.value end

	-- Everything that must not block the ray: the rest of the horde (their
	-- proxies are raycastable even though the visuals are not) and my own body.
	local filter = table.create(#zombieModels + 1)
	for _, m in ipairs(zombieModels) do
		if m ~= e.proxy and m ~= e.model then filter[#filter + 1] = m end
	end
	local char = LocalPlayer.Character
	if char then filter[#filter + 1] = char end

	rayParams.FilterDescendantsInstances = filter
	local origin = cam.CFrame.Position
	local hit = Workspace:Raycast(origin, worldPos - origin, rayParams)

	local value
	if hit == nil then
		-- A ray that reaches the target's position without touching anything is
		-- not a clear shot, it is a sign the aim point is not on a real hitbox —
		-- the zombie's own proxy parts are CanQuery = true, so a genuine line of
		-- sight always hits one of them. Treating this as visible is what let the
		-- aimbot lock targets it had no business shooting at.
		value = false
	elseif (e.proxy and hit.Instance:IsDescendantOf(e.proxy))
		or (e.model and hit.Instance:IsDescendantOf(e.model)) then
		value = true
	else
		value = false
	end

	visCache[e.id] = { value = value, expires = now + VIS_TTL }
	return value
end

----------------------------------------------------------------
-- aim
----------------------------------------------------------------

local function proxyPart(e, name)
	local proxy = e.proxy
	if not proxy or not proxy.Parent then return nil end
	local part = proxy:FindFirstChild(name)
	if part and part:IsA("BasePart") then return part end
	return nil
end

-- Proxy Head/Torso are the parts the game's own bullets raycast against
-- (CanQuery = true). HumanoidRootPart is not, so it is never an aim target.
--
-- There is deliberately no fallback to the visual's Head/HumanoidRootPart: every
-- part of the visual has CanQuery = false and no bullet can hit it, so aiming
-- there produced shots that looked right and did nothing. An entity with no
-- proxy is unshootable and is now skipped instead of faked.
local function aimPartFor(e)
	local part = proxyPart(e, flag("AimPart"))
	if part then return part end
	return proxyPart(e, "Head") or proxyPart(e, "Torso")
end

-- The hitbox is not where the zombie looks like it is. Measured on a live client:
-- the proxy Head sits up to ~1.4 studs from the rendered Head, in a different
-- direction per zombie. So a crosshair exactly on the hitbox centre can still read
-- as being on the body, which is the report this answers.
--
-- Any point INSIDE a part is still a guaranteed hit — a ray to an interior point
-- has to enter the part — so the aim can be moved toward the head you can see
-- without ever giving up the hit. It is clamped a margin inside the faces so it
-- cannot sit on a face and graze.
local function aimBasePoint(part, visualHead)
	local pos = part.Position
	if not visualHead or not visualHead.Parent then return pos end

	local half = part.Size * 0.5
	local margin = math.min(0.2, half.X * 0.25, half.Y * 0.25, half.Z * 0.25)
	if margin <= 0 then return pos end

	local offset = part.CFrame:VectorToObjectSpace(visualHead.Position - pos)
	local clamped = Vector3.new(
		math.clamp(offset.X, -(half.X - margin), half.X - margin),
		math.clamp(offset.Y, -(half.Y - margin), half.Y - margin),
		math.clamp(offset.Z, -(half.Z - margin), half.Z - margin))

	local out = pos + part.CFrame:VectorToWorldSpace(clamped)

	-- AimHeightBias lifts the point up the head, as a percentage of its half
	-- height. Up to 90% it is still inside the hitbox, so the hit is guaranteed and
	-- the point is clamped to stay that way. Past 90% it has deliberately left the
	-- head, and the clamp is skipped rather than silently undoing what was asked
	-- for. That is allowed here because the gun resolves hits with a 2.5-stud
	-- region and picks a single part out of it rather than casting a ray — so a
	-- point just above the skull can still register on it, and aiming high is the
	-- only thing measured so far that actually raises the headshot rate.
	local bias = math.clamp((tonumber(flag("AimHeightBias")) or 0) / 100, -1.5, 1.5)
	if bias ~= 0 then
		out = out + part.CFrame.UpVector * (half.Y * bias)
		if math.abs(bias) <= 0.9 then
			local lift = part.CFrame:VectorToObjectSpace(out - pos)
			out = pos + part.CFrame:VectorToWorldSpace(Vector3.new(
				math.clamp(lift.X, -(half.X - margin), half.X - margin),
				math.clamp(lift.Y, -(half.Y - margin), half.Y - margin),
				math.clamp(lift.Z, -(half.Z - margin), half.Z - margin)))
		end
	end
	return out
end

-- The weapon carries its own muzzle velocity (FN-2000 = 2000 studs/s), which is a
-- far better number than any guess. AimLeadSpeed overrides it when non-zero.
local leadSpeedCache, leadSpeedAt = nil, 0

local function leadSpeed()
	local override = flag("AimLeadSpeed")
	if override and override > 0 then return override end

	local now = os.clock()
	if now - leadSpeedAt < 5 then return leadSpeedCache end
	leadSpeedAt = now

	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChildWhichIsA("Tool")
	local setting = tool and tool:FindFirstChild("Setting")
	local mod = setting and setting:FindFirstChild("1")
	if not mod then
		leadSpeedCache = nil
		return nil
	end

	-- Requiring a game module can throw; a missing speed simply means no lead.
	local ok, cfg = pcall(require, mod)
	local speed = ok and type(cfg) == "table" and tonumber(cfg.BulletSpeed) or nil
	leadSpeedCache = (speed and speed > 0) and speed or nil
	return leadSpeedCache
end

-- Where to point so the round meets a moving target: the point on the hitbox
-- nearest the head you can see, plus however far it will have travelled by the
-- time the bullet arrives.
local function leadTarget(e, part, camPos)
	local pos = aimBasePoint(part, e.head)
	if not flag("AimLead") then return pos end

	local speed = leadSpeed()
	if not speed then return pos end

	local vel = e.proxy and trackHistory[e.proxy]
	vel = vel and vel.vel
	if not vel or vel.Magnitude < 0.1 then return pos end

	-- Iterated twice because the flight time depends on the distance to the lead
	-- point, which is the thing being solved for. Two passes converge here.
	local flight = (pos - camPos).Magnitude / speed
	for _ = 1, 2 do
		flight = ((pos + vel * flight) - camPos).Magnitude / speed
	end
	return pos + vel * flight
end

-- Angle in degrees between where the camera looks and the target: the fire gate.
local function aimError(cam, targetPos)
	local delta = targetPos - cam.CFrame.Position
	if delta.Magnitude < 0.05 then return 0 end
	local cos = math.clamp(cam.CFrame.LookVector:Dot(delta.Unit), -1, 1)
	return math.deg(math.acos(cos))
end

-- How far the game's own reticle sits from the camera axis, in pixels and in
-- degrees, measured off the live GUI rather than assumed.
--
-- The camera axis is what matters for hitting: Mouse.UnitRay projects exactly to
-- it, and the game's own AimAssist aims down ViewportPointToRay of the viewport
-- centre. The reticle is drawn somewhere else, which is the whole of the "it aims
-- below the head" report — the aim is on the hitbox, and the dot below it makes
-- that look wrong. Remeasured every few seconds, since a weapon swap redraws it.
local aimRef = { px = nil, deg = nil, at = 0 }

local function crosshairOffset()
	local now = os.clock()
	if aimRef.deg and now - aimRef.at < 3 then return aimRef.deg end
	aimRef.at = now

	local cam = Workspace.CurrentCamera
	local pg = LocalPlayer.PlayerGui
	local gg = pg:FindFirstChild("GunGUI")
	local cr = gg and gg:FindFirstChild("Crosshair")
	local dot = cr and (cr:FindFirstChild("Center") or cr:FindFirstChild("Dot"))
	if not cam or not dot or not dot.Visible then
		aimRef.px, aimRef.deg = nil, nil
		return nil
	end

	local ok, abs, size = pcall(function() return dot.AbsolutePosition, dot.AbsoluteSize end)
	if not ok or typeof(abs) ~= "Vector2" then
		aimRef.px, aimRef.deg = nil, nil
		return nil
	end

	-- AbsolutePosition and WorldToScreenPoint are the same coordinate space, so
	-- these are directly comparable — unlike WorldToViewportPoint, which differs
	-- by the GUI inset.
	local axis = cam.CFrame.Position + cam.CFrame.LookVector * 100
	local wsp = cam:WorldToScreenPoint(axis)
	local dy = (abs.Y + size.Y * 0.5) - wsp.Y

	local halfH = cam.ViewportSize.Y * 0.5
	if halfH < 1 then
		aimRef.px, aimRef.deg = nil, nil
		return nil
	end

	local halfFov = math.rad(math.clamp(cam.FieldOfView, 1, 120)) * 0.5
	aimRef.px = dy
	aimRef.deg = math.deg(math.atan(math.tan(halfFov) * (dy / halfH)))
	return aimRef.deg
end

-- The same direction, raised by an angle in the vertical plane. Uses the same
-- yaw/pitch convention as the camera: look = (-sin(yaw)cos(pitch), sin(pitch),
-- -cos(yaw)cos(pitch)).
local function raiseAim(camPos, targetPos, deg)
	local delta = targetPos - camPos
	local dist = delta.Magnitude
	if dist < 0.05 then return targetPos end

	local dir = delta / dist
	local yaw = math.atan2(-dir.X, -dir.Z)
	local pitch = math.clamp(math.asin(math.clamp(dir.Y, -1, 1)) + math.rad(deg), -1.5, 1.5)

	local cp, sp = math.cos(pitch), math.sin(pitch)
	local cy, sy = math.cos(yaw), math.sin(yaw)
	return camPos + Vector3.new(-sy * cp, sp, -cy * cp) * dist
end

-- Rebuilt from absolute yaw and pitch every frame instead of composed onto the
-- current CFrame. `cam.CFrame * CFrame.Angles(pitch, yaw, 0)` rotates the yaw
-- about an axis the pitch has already tilted, so roll creeps in and never
-- cancels — the horizon slowly tilts for as long as the aimbot runs.
local function aimCameraAt(cam, targetPos, alpha)
	local camPos = cam.CFrame.Position
	local delta = targetPos - camPos
	local dist = delta.Magnitude
	if dist < 0.05 then return end

	local dir = delta / dist
	local look = cam.CFrame.LookVector
	local curYaw = math.atan2(-look.X, -look.Z)
	local curPitch = math.asin(math.clamp(look.Y, -1, 1))
	local wantYaw = math.atan2(-dir.X, -dir.Z)
	local wantPitch = math.asin(math.clamp(dir.Y, -1, 1))

	local yawDelta = (wantYaw - curYaw + math.pi) % (2 * math.pi) - math.pi
	local pitchDelta = wantPitch - curPitch

	local newYaw = curYaw + yawDelta * alpha
	-- Straight up and down is a gimbal trap, so stop just short of the poles.
	local newPitch = math.clamp(curPitch + pitchDelta * alpha, -1.5, 1.5)

	cam.CFrame = CFrame.new(camPos) * CFrame.fromEulerAnglesYXZ(newPitch, newYaw, 0)
end

local triggerReady = true

-- Fired at the crosshair, not the mouse: the shot in this game follows the
-- camera, which the aimbot has already pointed at the target.
local function fireTriggerbot(cx, cy)
	if not triggerReady then return end
	triggerReady = false
	task.spawn(function()
		pcall(function()
			VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
			task.wait(0.01)
			VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
		end)
		task.wait(1 / math.max(flag("TriggerCps"), 1))
		triggerReady = true
	end)
end

----------------------------------------------------------------
-- auto leave: press the game's own OK button
----------------------------------------------------------------

-- Both end-of-run screens carry a button labelled OK, and pressing it is the
-- whole of "leave":
--     normal mission  PlayerGui.MissionComplete.MainFrame.Frame.CloseButton
--     boss raid       PlayerGui.MainMenu.ResultFrame.CloseButton
-- Pressing it is what a player does, so the game's own handler runs and its
-- bookkeeping stays correct — unlike firing the leave sequence by hand, which
-- leaves an internal flag in MissionComplete stale and stops the rewards screen
-- appearing again. That hand-rolled sequence is kept only as a fallback for the
-- case where the button does not take.
local autoLeave = { last = "idle", seenAt = nil, clicked = false }

-- Gate on the container itself. For MissionComplete that is the ScreenGui, not
-- the inner frame: a disabled ScreenGui leaves every child's Visible = true, so
-- checking a descendant would happily press buttons on a screen that is not on
-- screen at all.
local OK_CONTAINERS = {
	{ "MissionComplete" },
	{ "MainMenu", "ResultFrame" },
}

-- True only if the instance and every ancestor up to its ScreenGui are showing.
local function isShowing(inst)
	if not inst then return false end

	local node = inst
	while node do
		if node:IsA("ScreenGui") then
			return node.Enabled
		elseif node:IsA("GuiObject") then
			if not node.Visible then return false end
		end
		node = node.Parent
	end
	return true
end

local function buttonLabel(btn)
	local label = btn:FindFirstChildWhichIsA("TextLabel")
	if label then return label.Text end
	if btn:IsA("TextButton") then return btn.Text end
	return ""
end

-- Looks only inside the two known containers, so a stray "OK" somewhere else
-- (a purchase confirmation, say) can never be pressed by mistake.
--
-- Returns which container it matched as well, because the two need different
-- treatment: a result frame is the end of a run whatever the HUD is doing, while
-- MissionComplete can be up while the run is still live.
local function findOkButton()
	local pg = LocalPlayer.PlayerGui
	for _, path in ipairs(OK_CONTAINERS) do
		local node = pg
		for _, part in ipairs(path) do
			node = node and node:FindFirstChild(part)
		end
		if isShowing(node) then
			local which = path[#path]
			for _, d in ipairs(node:GetDescendants()) do
				if (d:IsA("TextButton") or d:IsA("ImageButton"))
					and isShowing(d) and d.AbsoluteSize.X >= 40 and d.AbsoluteSize.Y >= 20 then
					if buttonLabel(d):gsub("%s", ""):upper() == "OK" then return d, which end
				end
			end
			local close = node:FindFirstChild("CloseButton", true)
			if close and isShowing(close) then return close, which end
		end
	end
	return nil
end

-- AbsolutePosition is measured from below the top bar, but a simulated click is
-- a raw screen coordinate. Measured on a live client: clicking AbsolutePosition
-- misses, adding GuiService:GetGuiInset() lands (0, 58 here).
local function clickButton(btn)
	local inset = GuiService:GetGuiInset()
	local point = btn.AbsolutePosition + btn.AbsoluteSize * 0.5 + inset
	local x, y = math.floor(point.X), math.floor(point.Y)

	VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
	task.wait(0.05)
	VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
end

-- Fallback only. Mirrors the pause menu's QuitButton: the BeginTutorial opcode
-- is the server call that ends the run, ResetMenu rebuilds the lobby behind it.
local function forceLeave()
	local lp = LocalPlayer
	local pg = lp.PlayerGui

	local loading = pg:FindFirstChild("LOADING")
	if loading and loading:FindFirstChild("LoadGame") then
		pcall(function() loading.LoadGame:Fire(1.5) end)
	end
	pcall(function() lp.PlayerScripts.ShiftLockCameraScript.Enabled = false end)
	pcall(function() lp.PlayerScripts.OrbitCameraScript.Toggle.Value = false end)

	task.spawn(function()
		pcall(function() ReplicatedStorage.BeginTutorial:InvokeServer(8) end)
	end)

	local menu = pg:FindFirstChild("MainMenu")
	if menu and menu:FindFirstChild("Events") then
		pcall(function() menu.Events.ResetMenu:Fire() end)
	end

	local hud = pg:FindFirstChild("HUD")
	if hud then
		pcall(function()
			hud.Enabled = false
			hud.HealthFrame.Visible = true
			hud.DAY_Text.Visible = true
			hud.AbilityFrame.Visible = true
		end)
	end

	local complete = pg:FindFirstChild("MissionComplete")
	if complete then pcall(function() complete.Enabled = false end) end
end

local function watchAutoLeave()
	if not flag("AutoLeave") then
		autoLeave.seenAt, autoLeave.clicked = nil, false
		autoLeave.last = "off"
		return
	end

	local btn, container = findOkButton()
	if not btn then
		autoLeave.seenAt, autoLeave.clicked = nil, false
		autoLeave.last = "watching for the OK button"
		return
	end

	-- Never press it mid-run — but only for a mission. A result frame is the end of
	-- a run whatever the HUD is doing, and in survival it genuinely is still up
	-- while the result shows: measured on a live client, HUD.Enabled was true with
	-- MainMenu.ResultFrame visible, and the guard below then refused to press
	-- forever. That is a wedged farm, not a safety check.
	if container ~= "ResultFrame" then
		local hud = LocalPlayer.PlayerGui:FindFirstChild("HUD")
		if hud and hud.Enabled then
			autoLeave.seenAt, autoLeave.clicked = nil, false
			autoLeave.last = "in a match"
			return
		end
	end

	local now = os.clock()
	if not autoLeave.seenAt then
		autoLeave.seenAt = now
		autoLeave.last = "OK button is up"
		return
	end

	local elapsed = now - autoLeave.seenAt
	if not autoLeave.clicked then
		if elapsed < flag("AutoLeaveDelay") then
			autoLeave.last = ("leaving in %.1fs"):format(flag("AutoLeaveDelay") - elapsed)
			return
		end
		-- Pressing OK leaves the place, which destroys this script. Queue the
		-- reload first, or the loop the user switched on dies with the press.
		rearmAfterTeleport()
		clickButton(btn)
		autoLeave.clicked = true
		autoLeave.last = "pressed OK"
		return
	end

	-- Still up six seconds after the press: the game's handler has not taken.
	if elapsed > flag("AutoLeaveDelay") + 6 then
		if flag("AutoLeaveForce") and btn:IsDescendantOf(LocalPlayer.PlayerGui) then
			pcall(forceLeave)
			autoLeave.last = "OK did not take — forced the leave"
		else
			autoLeave.last = "OK did not take"
		end
		autoLeave.seenAt, autoLeave.clicked = nil, false
	end
end

----------------------------------------------------------------
-- mission farm
----------------------------------------------------------------

-- The loop is driven entirely off state that is already observable, rather than
-- off timers: HUD.Enabled means a mission is live, MainMenu.Enabled means the
-- lobby is up, and an OK button means the run has ended. Stats.DAY only moves on
-- a win, so comparing it either side of a run is the win/loss signal — no event
-- needed, and it works in the boss raid too.
--
-- Starting a day is two steps in the game: MapUI's DAY button opens MissionUI,
-- then its START button runs the day (which fires BeginDay:FireServer("DAYS")).
-- This opens the panel the same way the button does, then presses START for real.
local farm = {
	state = "idle",
	note = "",
	runs = 0,
	wins = 0,
	losses = 0,
	streak = 0,
	lastDay = nil,      -- last day seen, for counting clears
	dayAtStart = nil,   -- the day START was pressed for, for counting losses
	enteredLobbyAt = nil,
	armed = false,
	halted = false,
}

-- These tasks ask the player to physically go somewhere — rescue a survivor,
-- carry a supply back, restore power. Shooting everything does not finish them,
-- so the farm stops rather than burning attempts on them.
local MOVE_TASKS = { SOS = true, Resupply = true, Power = true }

local dayCatalog
do
	local ok, mod = pcall(require, ReplicatedStorage:FindFirstChild("DAYS_Module"))
	if ok and type(mod) == "table" then dayCatalog = mod end
end

local function currentDay()
	local stats = LocalPlayer:FindFirstChild("Stats")
	local day = stats and stats:FindFirstChild("DAY")
	return day and day.Value or nil
end

local function dayInfo(day)
	if not dayCatalog or not day then return nil end
	return dayCatalog["DAY " .. tostring(day)]
end

local function inMission()
	local hud = LocalPlayer.PlayerGui:FindFirstChild("HUD")
	return hud ~= nil and hud.Enabled
end

local function findStartButton()
	local pg = LocalPlayer.PlayerGui
	local menu = pg:FindFirstChild("MainMenu")
	local main = menu and menu:FindFirstChild("MainFrame")
	local panel = main and main:FindFirstChild("MissionUI")
	local frame = panel and panel:FindFirstChild("Frame")
	local btn = frame and frame:FindFirstChild("StartButton")
	if btn and isShowing(btn) and btn.AbsoluteSize.X >= 40 and btn.AbsoluteSize.Y >= 20 then
		return btn
	end
	return nil
end

-- Same two assignments MapUI's DAY button makes, minus its sounds and tweens.
local function openMissionPanel()
	local pg = LocalPlayer.PlayerGui
	local menu = pg:FindFirstChild("MainMenu")
	local main = menu and menu:FindFirstChild("MainFrame")
	if not main then return false end

	local panel = main:FindFirstChild("MissionUI")
	if not panel then return false end

	pcall(function()
		local current = main:FindFirstChild("CurrentUI")
		if current then current.Value = "MissionUI" end
		panel.Visible = true
	end)
	return true
end

local function setFarmHalted(reason)
	farm.halted = true
	farm.state = "halted"
	farm.note = reason
	if EZ then
		EZ:Notify({ Title = "Farm stopped", Content = reason, Duration = 8, Type = "warning" })
	end
end

local function watchFarm()
	if not flag("FarmEnabled") then
		farm.state, farm.note = "idle", "off"
		farm.enteredLobbyAt = nil
		farm.dayAtStart = nil
		farm.armed = false
		return
	end

	-- First tick after being switched on: start counting from wherever the game
	-- already is, so days cleared without this instance pressing START still
	-- register. It also clears a previous halt, which is what the stop message
	-- tells you to do.
	if not farm.armed then
		farm.armed = true
		farm.halted = false
		farm.lastDay = currentDay()
		farm.dayAtStart = nil
		farm.enteredLobbyAt = nil
	end

	if farm.halted then return end

	local pg = LocalPlayer.PlayerGui
	local menu = pg:FindFirstChild("MainMenu")
	local lobby = menu ~= nil and menu.Enabled

	if findOkButton() ~= nil then
		farm.state = "ending"
		farm.note = "run over — auto leave is clearing it"
		return
	end

	-- A clear is simply the day moving on, and the game chains days by itself
	-- once a run finishes — it does not always pass through the lobby between
	-- them. So this is checked before the in-mission return, not after it:
	-- waiting for the lobby is how the first version managed to clear two days
	-- and count neither.
	local day = currentDay()
	if farm.lastDay ~= nil and day ~= nil and day ~= farm.lastDay then
		farm.wins = farm.wins + 1
		farm.streak = 0
		farm.note = ("DAY %s cleared"):format(tostring(farm.lastDay))
		farm.lastDay = day
		-- The day we pressed START for has moved on, so it is no longer a
		-- candidate for the "came back unadvanced" loss below.
		if farm.dayAtStart ~= nil and farm.dayAtStart ~= day then
			farm.dayAtStart = nil
		end
		farm.enteredLobbyAt = nil
	end

	if inMission() then
		farm.state = "playing"
		local info = dayInfo(day)
		farm.note = ("playing DAY %s%s"):format(
			tostring(day), info and (" (" .. tostring(info.Task) .. ")") or "")
		farm.enteredLobbyAt = nil
		return
	end

	if not lobby then
		farm.state = "waiting"
		farm.note = "waiting for the lobby"
		return
	end

	-- Back in the lobby with the day we started still in place: that run did not
	-- clear. Only checked against a day this farm actually pressed START for, so
	-- a day cleared by the game's own chaining can never be counted as a loss.
	if farm.dayAtStart ~= nil and day == farm.dayAtStart then
		if farm.enteredLobbyAt == nil then
			farm.enteredLobbyAt = os.clock()
		elseif os.clock() - farm.enteredLobbyAt > 5 then
			farm.losses = farm.losses + 1
			farm.streak = farm.streak + 1
			farm.note = ("DAY %s did not clear"):format(tostring(day))
			farm.dayAtStart = nil
			farm.enteredLobbyAt = nil
			if farm.streak >= flag("FarmMaxLosses") then
				setFarmHalted(("%d runs in a row did not clear — stopping. Re-enable to retry."):format(farm.streak))
				return
			end
		end
	end

	local info = dayInfo(day)
	if flag("FarmStopOnMoveTask") and info and MOVE_TASKS[info.Task] then
		setFarmHalted(("DAY %s is a %s task — it needs you to move to the objective, so it cannot be farmed unattended.")
			:format(tostring(day), tostring(info.Task)))
		return
	end

	if not flag("FarmAutoStart") then
		farm.state, farm.note = "idle", "auto start is off"
		return
	end

	-- Let the lobby settle before reaching for the button, so the menu's own
	-- busy flag is clear and the press is not swallowed.
	if farm.enteredLobbyAt == nil then
		farm.enteredLobbyAt = os.clock()
		farm.state, farm.note = "waiting", "letting the lobby settle"
		return
	end
	if os.clock() - farm.enteredLobbyAt < flag("FarmStartDelay") then
		farm.state = "waiting"
		farm.note = ("starting in %.1fs"):format(flag("FarmStartDelay") - (os.clock() - farm.enteredLobbyAt))
		return
	end

	local btn = findStartButton()
	if not btn then
		if not openMissionPanel() then
			farm.state, farm.note = "paused", "no mission panel in this place"
			return
		end
		farm.state, farm.note = "starting", "opening the mission panel"
		return
	end

	farm.dayAtStart = day
	farm.runs = farm.runs + 1
	farm.state = "starting"
	farm.note = ("pressed START for DAY %s"):format(tostring(day))
	farm.enteredLobbyAt = nil
	clickButton(btn)
end

----------------------------------------------------------------
-- CO-OP survival
----------------------------------------------------------------

-- From ReplicatedStorage.Shared.PartyHubConfig, which is the game's own source of
-- truth for where each mode lives. Copying the ids here rather than requiring the
-- module, because it is only present in some places.
local PLACES = {
	Lobby = 15899178400,
	BossRaidHub = 102358977893515,
	SurvivalHub = 98612952479093,
	BossRaidMatch = 80561320113856,
	SurvivalMatch = 103889213166377,
}

-- Read off the hub's own map grid (`CO-OP.StartFrame.MAIN.MAPS`), not from the
-- config: PartyHubConfig.AllowedMaps also lists Forest, Desert, Arctic, Arena and
-- ParkingLot, but those have no button, so asking the server for one would be
-- asking for something the game does not offer.
local SURVIVAL_MAPS = {
	"Biolab", "Junkyard", "Sewers", "Church", "Warehouse", "Glacier",
	"Snowy Top", "UndergroundBioLab", "City", "Volcanic Cave",
	"Residential Area", "City Ruins",
}

-- PartyHubConfig.Modes.Survival.AllowedDifficulties. Hard is +30% zombie speed
-- and 2x cash; Normal is slow zombies and weak bosses.
local SURVIVAL_DIFFICULTIES = { "Normal", "Medium", "Hard" }

local survival = {
	state = "idle",
	note = "",
	runs = 0,
	lastWave = nil,
	createAt = nil,
	startAt = nil,
	endedAt = nil,
	halted = false,
	intent = nil,
}

-- The hub's party state, taken from the server's own replies instead of guessed
-- from the UI. CO-OPPartyHandler listens to the same event, so this only mirrors
-- it — the script never drives that UI, it just needs to know whether a party
-- already exists before asking for another one.
local partyHub = { party = nil, action = nil }
do
	local remote = ReplicatedStorage:FindFirstChild("PartyHubRemote")
	if remote then
		remote.OnClientEvent:Connect(function(action, data)
			partyHub.action = action
			if action == "CREATE" or action == "JOIN" or action == "UPDATE" then
				partyHub.party = data
			end
		end)
	end
end

local function hubHasParty()
	if partyHub.party then return true end
	-- Fallback for a reply that arrived before this script loaded.
	local co = LocalPlayer.PlayerGui:FindFirstChild("CO-OP")
	local pf = co and co:FindFirstChild("PartyFrame")
	return pf ~= nil and pf.Visible
end

-- Wave number, straight off the match's own state.
local function matchWave()
	local mf = ReplicatedStorage:FindFirstChild("MATCH FOLDER")
	local wave = mf and mf:FindFirstChild("WAVE")
	if not wave then return nil end
	local ok, value = pcall(function() return wave.Value end)
	return ok and value or nil
end

local function inSurvivalMatch()
	return game.PlaceId == PLACES.SurvivalMatch
end

local function setSurvivalHalted(reason)
	survival.halted = true
	survival.state = "halted"
	survival.note = reason
	if EZ then
		EZ:Notify({ Title = "Survival stopped", Content = reason, Duration = 8, Type = "warning" })
	end
end

-- Written only when the value changes, so this is not a file write every tick.
local function syncIntent()
	-- Never write when the file could not be read this process: we do not know what
	-- the user asked for, and writing would persist a default over their choice. A
	-- single failed read used to switch the farm off for good.
	if not SAVED_INTENT.ok then return end

	local now = {
		enabled = flag("SurvivalEnabled") and true or false,
		map = flag("SurvivalMap"),
		difficulty = flag("SurvivalDifficulty"),
	}
	local was = survival.intent
	-- Only write when something actually changed; this runs twice a second.
	if was and was.enabled == now.enabled and was.map == now.map and was.difficulty == now.difficulty then
		return
	end
	survival.intent = now
	writeIntent(now)
end

local function watchSurvival()
	syncIntent()

	if not flag("SurvivalEnabled") then
		survival.state, survival.note = "idle", "off"
		return
	end
	if survival.halted then return end

	-- In a match: play it, and notice when it ends. The fight and the movement are
	-- driven elsewhere off the same flag; this only runs the loop.
	if inSurvivalMatch() then
		survival.lastWave = matchWave() or survival.lastWave
		survival.state = "in match"

		local btn = findOkButton()
		if not btn then
			survival.endedAt = nil
			survival.note = ("playing, wave %s"):format(tostring(survival.lastWave))
			return
		end

		-- The result screen is up, so the run is over. Count it once.
		if not survival.endedAt then
			survival.endedAt = os.clock()
			survival.runs = survival.runs + 1
			survival.note = ("run %d ended at wave %s"):format(survival.runs, tostring(survival.lastWave))

			local cap = flag("SurvivalMaxRuns")
			if cap and cap > 0 and survival.runs >= cap then
				setSurvivalHalted(("stopped after %d runs"):format(survival.runs))
				return
			end
		end

		-- Auto leave presses this same button and re-arms for the teleport itself,
		-- so only press here when it is switched off — otherwise the two would race
		-- for one button and one of them would double-press it.
		if not flag("AutoLeave") and flag("SurvivalLeaveAfterWipe") then
			rearmAfterTeleport()
			clickButton(btn)
			survival.note = "clearing the result"
		else
			survival.note = survival.note .. " (auto leave clearing it)"
		end
		return
	end

	-- In the hub: make a party for the chosen map and difficulty, then start it.
	if game.PlaceId == PLACES.SurvivalHub then
		if not flag("SurvivalAutoStart") then
			survival.state, survival.note = "hub", "auto-start is off"
			return
		end

		local remote = ReplicatedStorage:FindFirstChild("PartyHubRemote")
		if not remote then
			survival.state, survival.note = "hub", "no PartyHubRemote in this place"
			return
		end

		local now = os.clock()

		if not hubHasParty() then
			-- Throttled: if the server refuses, wait before asking again rather
			-- than hammering the remote twice a second.
			if survival.createAt and now - survival.createAt < 15 then
				survival.state, survival.note = "hub", "waiting for the party"
				return
			end
			survival.createAt = now
			survival.state = "starting"

			local map, diff = flag("SurvivalMap"), flag("SurvivalDifficulty")
			survival.note = ("creating %s / %s"):format(tostring(map), tostring(diff))
			-- Exactly the payload the hub's own CreateLobby sends, verified on a
			-- live client to land in the requested map.
			remote:FireServer("CREATE", {
				Limit = 4,
				Status = true,
				Password = "",
				Difficulty = diff,
				Map = map,
			})
			return
		end

		if survival.startAt and now - survival.startAt < 12 then
			survival.state, survival.note = "hub", "party ready"
			return
		end
		survival.startAt = now
		survival.state = "starting"
		survival.note = "starting the match"
		-- START teleports, so arm the reload before asking for it or this script
		-- dies on the way into the match.
		rearmAfterTeleport()
		remote:FireServer("START")
		return
	end

	-- Anywhere else — the personal lobby, a boss raid, the raid hub. Says so
	-- rather than guessing at a launch path it has not verified.
	survival.createAt, survival.startAt = nil, nil
	survival.state, survival.note = "elsewhere", "not in the survival hub"
end

----------------------------------------------------------------
-- speed
----------------------------------------------------------------

-- The game's own side ability is the only speed source here that cannot be
-- held against you: its cooldown is enforced by a server-written attribute and
-- pressing it is the same button a player presses. Nothing about it is
-- distinguishable from a human playing well.
--
-- Raising Humanoid.WalkSpeed is a different matter, and the reason the slider
-- below ships off. The character carries a RemoteFunction that hands
-- {WalkSpeed, JumpPower} to the server whenever it asks, and a WarningMessage
-- script whose entire content is "Suspicious Activity Detected! Your account is
-- at risk of being banned." A WalkSpeed change cannot be hidden from either one.
local speed = {
	orig = nil,       -- the game's own WalkSpeed for this character, to put back
	lastAbility = 0,
	note = "idle",
}

-- Every side-ability cooldown is written to the character as
-- <Character>SideReadyAt, and they are all stamped together, so the latest one
-- is the one that matters.
local ABILITY_READY_SUFFIX = "SideReadyAt"

local function currentHumanoid()
	local ch = LocalPlayer.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then return hum end
	return nil
end

local function restoreWalkSpeed()
	if not speed.orig then return end
	local hum = currentHumanoid()
	if hum then pcall(function() hum.WalkSpeed = speed.orig end) end
	speed.orig = nil
end

-- The game sets WalkSpeed itself — it is 16.05 in a match rather than the stock
-- 16, and weapons modify it — so the value found on arrival is remembered and
-- put back verbatim rather than assumed to be 16.
local function applyWalkSpeed()
	if not flag("SpeedBoostEnabled") then
		restoreWalkSpeed()
		speed.note = "off"
		return
	end

	local hum = currentHumanoid()
	if not hum then return end

	if not speed.orig then speed.orig = hum.WalkSpeed end
	local want = math.clamp(flag("SpeedBoostValue"), 8, 200)
	if math.abs(hum.WalkSpeed - want) > 0.01 then
		pcall(function() hum.WalkSpeed = want end)
	end
	speed.note = ("%.0f (game had %.2f)"):format(want, speed.orig)
end

local function abilityButton()
	local pg = LocalPlayer.PlayerGui
	local hud = pg and pg:FindFirstChild("HUD")
	if not hud or not hud.Enabled then return nil end
	local af = hud:FindFirstChild("AbilityFrame")
	local btn = af and af:FindFirstChild("BUTTON", true)
	if btn and isShowing(btn) then return btn end
	return nil
end

-- Ready is the server's own answer. The button's countdown label is the fallback
-- for a character whose ability does not stamp that attribute.
local function abilityReady()
	local ch = LocalPlayer.Character
	if ch then
		local latest
		for name, value in pairs(ch:GetAttributes()) do
			if type(value) == "number" and name:sub(-#ABILITY_READY_SUFFIX) == ABILITY_READY_SUFFIX then
				if not latest or value > latest then latest = value end
			end
		end
		if latest then return latest <= workspace:GetServerTimeNow() end
	end

	local btn = abilityButton()
	local timer = btn and btn:FindFirstChild("TIMER")
	if timer and timer:IsA("TextLabel") then return timer.Text == "" end
	return false
end

-- Fired as a signal rather than keyed: the game's own handler works out whatever
-- the ability needs, direction included, and LeftShift is also Roblox's own
-- shift-lock toggle, so synthesising the key would fight the game for it.
--
-- firesignal drives the button's own MouseButton1Click handler directly, so it
-- cannot be swallowed by a GUI hit test or land on the wrong control if the HUD
-- moves. The synthetic click is kept as the fallback for an executor without it.
local function pressAbility()
	local btn = abilityButton()
	if not btn then return false end

	if type(firesignal) == "function" then
		if pcall(firesignal, btn.MouseButton1Click) then return true end
	end

	clickButton(btn)
	return true
end

local function watchSpeed()
	-- Never leave a raised WalkSpeed behind once the run is over, whatever the
	-- toggle says.
	if not inMission() then
		restoreWalkSpeed()
		speed.note = "idle"
		return
	end

	applyWalkSpeed()

	if not flag("AbilityAuto") then return end
	-- Asking is harmless while it is still cooling down — the server simply
	-- refuses — but there is no reason to hammer it either.
	if os.clock() - speed.lastAbility < 1 then return end
	if not abilityReady() then return end
	if pressAbility() then speed.lastAbility = os.clock() end
end

-- A new character means a new Humanoid with the game's own WalkSpeed, so the
-- remembered value has to be dropped or the restored speed would be the last
-- character's.
LocalPlayer.CharacterAdded:Connect(function()
	speed.orig = nil
	speed.lastAbility = 0
	task.defer(applyWalkSpeed)
end)

----------------------------------------------------------------
-- challenge auto-claim
----------------------------------------------------------------

-- TaskManager's Hourly/Daily/Weekly/Monthly challenges each carry Completed and
-- Claimed booleans, so a completed-but-unclaimed entry is a reward sitting there
-- uncollected. ClaimTask takes the category name and the task's slot.
local CLAIM_CATEGORIES = { "Hourly", "Daily", "Weekly", "Monthly" }
local claims = { last = 0, total = 0, note = "idle" }

local function claimFinishedTasks()
	local tm = ReplicatedStorage:FindFirstChild("Modules")
	local manager = tm and tm:FindFirstChild("TaskManager")
	local remotes = manager and manager:FindFirstChild("Remotes")
	if not remotes then return 0, "no TaskManager" end

	local getTasks = remotes:FindFirstChild("GetTasks")
	local claimTask = remotes:FindFirstChild("ClaimTask")
	local claimMilestone = remotes:FindFirstChild("ClaimStarMilestone")
	if not (getTasks and claimTask) then return 0, "no claim remotes" end

	local ok, data = pcall(function() return getTasks:InvokeServer() end)
	if not ok or type(data) ~= "table" then return 0, "GetTasks failed" end

	local claimed = 0

	local categories = data.Categories
	if type(categories) == "table" then
		for _, name in ipairs(CLAIM_CATEGORIES) do
			local bucket = categories[name]
			local list = type(bucket) == "table" and bucket.Tasks or nil
			if type(list) == "table" then
				for slot, task in pairs(list) do
					if type(task) == "table" and task.Completed == true and task.Claimed ~= true then
						local ok2 = pcall(function()
							return claimTask:InvokeServer(name, task.Slot or slot)
						end)
						if ok2 then claimed = claimed + 1 end
					end
				end
			end
		end
	end

	-- Star roadmap milestones are keyed by their Stars threshold, not an index —
	-- confirmed against the server: ClaimStarMilestone(3) answers "Not enough
	-- Stars.", while an index or the cycle key answers "Invalid milestone.".
	local roadmap = data.StarRoadmap
	if claimMilestone and type(roadmap) == "table" and type(roadmap.Milestones) == "table" then
		local stars = tonumber(roadmap.Stars) or 0

		-- The claimed list may be an array of thresholds or a map of them.
		local done = {}
		for k, v in pairs(roadmap.ClaimedMilestones or {}) do
			if type(k) == "number" then done[k] = true end
			if type(v) == "number" then done[v] = true end
		end

		for _, milestone in pairs(roadmap.Milestones) do
			local need = type(milestone) == "table" and tonumber(milestone.Stars)
			if need and stars >= need and not done[need] then
				local ok3 = pcall(function() return claimMilestone:InvokeServer(need) end)
				if ok3 then claimed = claimed + 1 end
			end
		end
	end

	return claimed
end

local function watchClaims()
	if not flag("FarmClaimTasks") then
		claims.note = "off"
		return
	end
	if os.clock() - claims.last < 60 then return end
	claims.last = os.clock()

	local claimed, err = claimFinishedTasks()
	if err then
		claims.note = err
		return
	end
	if claimed > 0 then
		claims.total = claims.total + claimed
		if EZ then
			EZ:Notify({ Title = "Challenges claimed", Content = claimed .. " reward(s) collected", Type = "success" })
		end
	end
	claims.note = ("%d claimed this session"):format(claims.total)
end

----------------------------------------------------------------
-- movement
----------------------------------------------------------------

-- The game moves camera-relative through its own control module, and
-- Humanoid:Move is overwritten by it (measured: 0.03 studs in a second). So
-- movement here is simulated WASD, which the control module does read (measured:
-- W held moved 5.06 studs). A world direction is projected onto the camera's
-- flattened look/right basis to pick the keys.
--
-- Because it is camera-relative and the aimbot owns the camera, the character
-- can strafe and back away while still facing the target — which is how a player
-- kites a horde.
local move = { held = {}, note = "idle" }
local MOVE_KEYS = { Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D }

-- Walking straight at the objective walks into whatever is between, and a
-- "rotate until it gets closer" heuristic does not fix that — it thrashes
-- (measured: it wandered from 19 to 109 studs off). So navigation is real
-- pathfinding: PathfindingService around the actual geometry, walked waypoint by
-- waypoint. The rotate heuristic survives only as a fallback for when a path
-- cannot be computed.
local nav = { waypoints = nil, index = 1, goal = nil, at = 0, failedAt = 0 }

local PathfindingService = game:GetService("PathfindingService")
local PATH_REFRESH = 2.5
local WAYPOINT_REACHED = 5

local function recomputePath(from, to)
	local ok, path = pcall(function()
		local p = PathfindingService:CreatePath({
			AgentRadius = 2.5,
			AgentHeight = 5,
			AgentCanJump = true,
			WaypointSpacing = 6,
		})
		p:ComputeAsync(from, to)
		return p
	end)
	-- A Path is a userdata, not a table — checking for a table here rejected
	-- every successful path and silently disabled navigation.
	if not ok or path == nil then return nil end

	local okStatus, status = pcall(function() return path.Status end)
	if not okStatus or status ~= Enum.PathStatus.Success then return nil end

	local okPoints, points = pcall(function() return path:GetWaypoints() end)
	if not okPoints or type(points) ~= "table" or #points < 2 then return nil end
	return points
end

-- Returns the point to walk at right now, or nil if pathing is unavailable.
local function navTarget(me, obj)
	local now = os.clock()

	local stale = nav.goal == nil
		or (nav.goal - obj).Magnitude > 6
		or now - nav.at > PATH_REFRESH
		or nav.waypoints == nil

	if stale and now - nav.failedAt > 1 then
		local points = recomputePath(me, obj)
		nav.at = now
		if points then
			nav.waypoints = points
			nav.index = 2
			nav.goal = obj
		else
			nav.waypoints = nil
			nav.goal = nil
			nav.failedAt = now
		end
	end

	local points = nav.waypoints
	if not points then return nil end

	-- advance past anything already reached
	while nav.index <= #points and (me - points[nav.index].Position).Magnitude < WAYPOINT_REACHED do
		nav.index = nav.index + 1
	end
	if nav.index > #points then
		nav.waypoints = nil
		return nil
	end

	local wp = points[nav.index]
	if wp.Action == Enum.PathWaypointAction.Jump then
		pcall(function() VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game) end)
		pcall(function() VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game) end)
	end
	return wp.Position
end

-- Anything that could hurt to stand near. The two client folders hold live
-- projectiles and effects (acid, puddles); the map holds invisible trigger
-- volumes named DangerPart. Names are matched loosely because the set is not
-- documented anywhere and a missed hazard costs health.
local HAZARD_WORDS = { "danger", "acid", "puddle", "hazard", "poison", "fire", "lava", "zone", "spill", "toxic" }

local function isHazardName(name)
	local n = name:lower()
	for _, word in ipairs(HAZARD_WORDS) do
		if n:find(word, 1, true) then return true end
	end
	return false
end

local hazardCache, hazardCacheAt = {}, 0

-- Walking the map every tick would be far too expensive, so the list is cached
-- and refreshed on a slow timer.
local function hazardParts()
	local now = os.clock()
	if now - hazardCacheAt < 2 then return hazardCache end
	hazardCacheAt = now

	local found = {}
	local cm = Workspace:FindFirstChild("CURRENT_MAP")
	local map = cm and cm:GetChildren()[1]
	if map then
		for _, d in ipairs(map:GetDescendants()) do
			if d:IsA("BasePart") and isHazardName(d.Name) then found[#found + 1] = d end
		end
	end
	hazardCache = found
	return found
end

-- Everything that can hurt to walk through: the map's own named hazard parts,
-- plus whatever the client spawns into ClientZombieEffects (acid, puddles) and
-- ClientZombieProjectiles. Collected as positions for the heading scorer to
-- weigh, rather than pushed out of radially.
local function hazardPoints(radius, me)
	local out = {}

	for _, part in ipairs(hazardParts()) do
		if part.Parent then out[#out + 1] = part.Position end
	end

	for _, folderName in ipairs({ "ClientZombieEffects", "ClientZombieProjectiles" }) do
		local folder = Workspace:FindFirstChild(folderName)
		if folder then
			for _, obj in ipairs(folder:GetChildren()) do
				local part = obj:IsA("BasePart") and obj or obj:FindFirstChildWhichIsA("BasePart")
				if part and (part.Position - me).Magnitude < radius * 2 then
					out[#out + 1] = part.Position
				end
			end
		end
	end
	return out
end

local stuck = { bestDist = nil, since = 0, bias = 0, cycles = 0 }

local function rotateY(v, degrees)
	local r = math.rad(degrees)
	local c, s = math.cos(r), math.sin(r)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function updateStuck(objDist)
	local now = os.clock()
	if objDist == nil then
		stuck.bestDist = nil
		stuck.bias = 0
		stuck.cycles = 0
		return
	end
	if stuck.bestDist == nil or objDist < stuck.bestDist - 0.5 then
		stuck.bestDist = objDist
		stuck.since = now
		stuck.bias = 0
		stuck.cycles = 0
		return
	end
	if now - stuck.since > 1.5 then
		stuck.cycles = stuck.cycles + 1
		local step = 60 * math.ceil(stuck.cycles / 2)
		stuck.bias = (stuck.cycles % 2 == 1) and step or -step
		stuck.since = now
	end
end

local function holdKeys(want)
	for _, key in ipairs(MOVE_KEYS) do
		local should = want[key] == true
		if (move.held[key] == true) ~= should then
			move.held[key] = should or nil
			pcall(function() VirtualInputManager:SendKeyEvent(should, key, false, game) end)
		end
	end
end

local function releaseAll()
	if next(move.held) then holdKeys({}) end
end

local function steer(worldDir)
	local cam = Workspace.CurrentCamera
	if not cam then return end

	local dir = Vector3.new(worldDir.X, 0, worldDir.Z)
	if dir.Magnitude < 0.001 then
		releaseAll()
		return
	end
	dir = dir.Unit

	local look = cam.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 0.001 then flatLook = Vector3.new(0, 0, -1) end
	flatLook = flatLook.Unit
	local flatRight = flatLook:Cross(Vector3.new(0, 1, 0))

	local fwd = dir:Dot(flatLook)
	local right = dir:Dot(flatRight)

	-- 0.38 is sin(22.5 deg): inside that wedge one key, outside it two, so the
	-- eight-way result lands as close to the wanted angle as WASD can manage.
	local want = {}
	if fwd > 0.38 then want[Enum.KeyCode.W] = true end
	if fwd < -0.38 then want[Enum.KeyCode.S] = true end
	if right > 0.38 then want[Enum.KeyCode.D] = true end
	if right < -0.38 then want[Enum.KeyCode.A] = true end
	holdKeys(want)
end

local function myBody()
	local ch = LocalPlayer.Character
	if not ch then return nil end
	local hum = ch:FindFirstChildOfClass("Humanoid")
	local root = ch:FindFirstChild("HumanoidRootPart")
	if hum and root and hum.Health > 0 then return hum, root end
	return nil
end

-- Incoming projectiles: the heading scorer reads their travel from position
-- history, not AssemblyLinearVelocity. This game moves things by setting CFrames
-- (the zombie visuals are anchored), so a physics velocity is frequently zero —
-- which silently ignored every spitter projectile and is why nothing was ever
-- dodged before.
local projHistory = setmetatable({}, { __mode = "k" })

-- The map carries a folder named after the day's task holding that task's
-- waypoints — but the folder is upper-case ("RESUPPLY") while DAYS_Module's task
-- name is not ("Resupply"), and FindFirstChild is case-sensitive, so the lookup
-- has to ignore case.
local function taskFolder(map, task)
	for _, child in ipairs(map:GetChildren()) do
		if (child:IsA("Folder") or child:IsA("Model"))
			and child.Name:lower() == tostring(task):lower() then
			return child
		end
	end
	return nil
end

-- Tasks where the job is to keep someone alive rather than to reach a place.
local PROTECT_TASKS = { SOS = true, Power = true }

-- The person to protect is a model named after the day's SpecialCharacter
-- ("Hubert" on day 9), with a real Humanoid and no IsZombie marker. Following its
-- live position is what "move with him" needs: a static waypoint cannot escort a
-- target that walks. The standoff below then keeps the run close enough to shoot
-- whatever is attacking him without standing inside him.
local function vipPoint()
	local info = dayInfo(currentDay())
	if not info or not PROTECT_TASKS[info.Task] then return nil end

	local name = info.SpecialCharacter
	if not name or name == "None" then return nil end

	local cm = Workspace:FindFirstChild("CURRENT_MAP")
	local map = cm and cm:GetChildren()[1]
	if not map then return nil end

	local model = map:FindFirstChild(name, true)
	if not model or model:FindFirstChild("IsZombie") then return nil end

	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return nil end

	local root = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
	return root and root.Position
end

-- SOS and similar lay out an invisible waypoint route (SOS/Waypoints/WP*). Which
-- end is the goal is not labelled anywhere, so the one farthest from the player
-- is taken as the destination — and the choice is held until the player gets
-- close, so it cannot flip mid-walk and leave the run oscillating.
local wpChoice
local function waypointTarget(me, folder)
	local route = folder:FindFirstChild("Waypoints")
	if not route then return nil end

	local parts = {}
	for _, d in ipairs(route:GetChildren()) do
		if d:IsA("BasePart") then parts[#parts + 1] = d end
	end
	if #parts == 0 then return nil end

	if wpChoice and wpChoice.Parent and (me - wpChoice.Position).Magnitude > 15 then
		return wpChoice.Position
	end

	local best, bestDist
	for _, p in ipairs(parts) do
		local d = (me - p.Position).Magnitude
		if bestDist == nil or d > bestDist then bestDist, best = d, p end
	end
	wpChoice = best
	return best and best.Position
end

-- Priority order, and it matters:
--   1. The game's own waypoint arrow. Each task folder holds ARROW models whose
--      MeshPart is visible only while that step is the one outstanding — on
--      Resupply the supply's arrow hides and the base's appears the moment the
--      box is picked up. Following it is what makes the return leg work at all;
--      without it the run reaches the supply and then has nothing to do.
--   2. A part with a TouchTransmitter — the interaction volume. This is often
--      invisible by design (RESUPPLY's SUPPLY_PICKUP sits at Transparency = 1),
--      so it is checked independently of visibility, and after the arrow.
--   3. An invisible waypoint route (SOS).
--   4. Any visible part, so a task with none of the above still has a goal.
-- The game's own arrow is the authority on what to do next, in every task: it
-- points at the current objective, it moves on when that objective is done, and
-- it shows the finish at the end of a run. Anything else here is a guess about
-- its intent, so the arrow is always asked first.
--
-- Arrows are not confined to the task folder — SOS carries one at its spawn and
-- another parented to the person being escorted, and that second one is the
-- bobbing marker that has to be walked into. So the whole map is searched, and
-- among the visible ones the nearest is taken, which is whichever step is
-- currently outstanding.
local arrowCache, arrowCacheAt = {}, 0

local function arrowParts(map)
	local now = os.clock()
	if now - arrowCacheAt < 1.5 then return arrowCache end
	arrowCacheAt = now

	local found = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") and d.Name:upper():find("ARROW") and d.Transparency < 0.5 then
			found[#found + 1] = d
		end
	end
	arrowCache = found
	return found
end

local function visibleArrow(map, me)
	local best, bestDist
	for _, part in ipairs(arrowParts(map)) do
		if part.Parent then
			local dist = (me - part.Position).Magnitude
			if bestDist == nil or dist < bestDist then bestDist, best = dist, part end
		end
	end
	return best and best.Position
end

-- Returns the point to walk at, and whether the run has to actually reach it.
-- Standing ON an arrow or a pickup is what completes a step, so those must be
-- closed to zero distance — the configured standoff is only right for the person
-- being escorted, who you want to be near rather than inside.
-- Universal escort tracker. Arrows are a bonus, not the signal: Power days carry
-- no arrows at all (verified — LAB POWER has zero arrow parts) and instead put
-- two living NPCs in the map, a Doctor and an Inspector. So the reliable test is
-- simply a model with a living Humanoid that is not a zombie — which also covers
-- the SOS person and anything the game adds later.
--
-- The models are cached, but their positions are read live each tick, since the
-- whole point is that they move.
local escortCache, escortCacheAt = {}, 0

local function escortModels(map)
	local now = os.clock()
	if now - escortCacheAt < 1.5 then return escortCache end
	escortCacheAt = now

	local found = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("Humanoid") and d.Health > 0 then
			local model = d.Parent
			if model and not model:FindFirstChild("IsZombie") then
				local root = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
				if root then found[#found + 1] = root end
			end
		end
	end
	escortCache = found
	return found
end

-- Nearest one wins, so the run goes to whoever is in trouble first rather than
-- splitting the difference between two survivors.
local function escortPoint(me)
	local cm = Workspace:FindFirstChild("CURRENT_MAP")
	local map = cm and cm:GetChildren()[1]
	if not map then return nil end

	local best, bestDist
	for _, root in ipairs(escortModels(map)) do
		if root.Parent then
			local dist = (me - root.Position).Magnitude
			if bestDist == nil or dist < bestDist then bestDist, best = dist, root.Position end
		end
	end
	return best
end

-- Kept as a secondary signal: an arrow attached to a living non-zombie model is
-- still a strong hint, and it points above the head rather than at the feet.
local function vipFromArrows(map)
	for _, part in ipairs(arrowParts(map)) do
		if part.Parent then
			local node = part.Parent
			while node and node ~= map do
				if node:IsA("Model") then
					local hum = node:FindFirstChildOfClass("Humanoid")
					if hum and hum.Health > 0 and not node:FindFirstChild("IsZombie") then
						return part.Position
					end
				end
				node = node.Parent
			end
		end
	end
	return nil
end

local function objectivePoint(me)
	local cm = Workspace:FindFirstChild("CURRENT_MAP")
	local map = cm and cm:GetChildren()[1]
	if not map then return nil end

	local info = dayInfo(currentDay())
	if not info or not info.Task then return nil end

	local folder = taskFolder(map, info.Task)

	-- Someone to protect outranks every marker: escorting them is the objective,
	-- and it is the only signal that works on days with no arrows at all.
	local escort = escortPoint(me) or vipFromArrows(map)
	if escort then return escort, false end

	local arrow = visibleArrow(map, me)
	if arrow then return arrow, true end

	if not folder then
		local vip = vipPoint()
		return vip, false
	end

	-- No arrow up: fall back to the live person on the protect tasks, then to
	-- the interaction volume, then to an invisible waypoint route, then to any
	-- visible part.
	local vip = vipPoint()
	if vip then return vip, false end

	local touch, visible
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("BasePart") then
			if not touch and d:FindFirstChildOfClass("TouchTransmitter") then
				touch = d.Position
			end
			if not visible and d.Transparency < 0.9 then
				visible = d.Position
			end
		end
	end

	if touch then return touch, true end

	local wp = waypointTarget(me, folder)
	if wp then return wp, true end

	return visible, visible ~= nil
end

----------------------------------------------------------------
-- heading choice: score a ring, commit, re-decide
----------------------------------------------------------------

-- The old movement added an objective pull, a crowd push, a dodge push and a
-- hazard push together and then rounded the sum into WASD, twenty times a second.
-- Four competing forces re-decided every tick and quantised to the nearest 22.5
-- degrees is how you get oscillation — measured runs went 136 -> 61 -> 107 studs
-- and never converged — and in survival it is how you stand still in the wave
-- until you die.
--
-- Instead: score a ring of candidate headings on what actually happens over the
-- next fraction of a second, take the best, and hold it for a moment.
--
-- Two things make the scoring honest. The old dodge tested "is something near",
-- which fires for shots that were never going to hit; this tests the closest
-- approach along the path, so a threat only counts if the path is actually hit.
-- And because it compares paths rather than pushing on the current position, a
-- zombie charging at you counts the same as you walking into it.
local KITE_DIRECTIONS = 16
local KITE_COMMIT = 0.3     -- seconds a chosen heading is held before re-deciding
local KITE_HORIZON = 0.9    -- seconds of danger each heading is scored against
local KITE_SPEED = 16       -- studs/s the character manages, for prediction

local kite = { dir = nil, at = 0, note = "" }
local kiteParams = RaycastParams.new()
kiteParams.FilterType = Enum.RaycastFilterType.Exclude
local kiteFilter = {}

local mapCentre, mapCentreAt = nil, 0

-- Rough middle of the play area, for the corner bias. Corners are where kiting
-- dies: once the horde has you in one there is no heading left that gains space.
local function mapCentrePoint()
	local now = os.clock()
	if mapCentre and now - mapCentreAt < 10 then return mapCentre end
	mapCentreAt = now

	local cm = Workspace:FindFirstChild("CURRENT_MAP")
	local map = cm and cm:GetChildren()[1]
	if not map then
		mapCentre = nil
		return nil
	end
	local ok, cf = pcall(function() return map:GetBoundingBox() end)
	if not ok or typeof(cf) ~= "CFrame" then
		mapCentre = nil
		return nil
	end
	mapCentre = cf.Position
	return mapCentre
end

-- Closest the path comes to a threat that is itself moving, over the horizon.
local function closestApproach(me, dir, p, vel)
	local rel = vel - dir * KITE_SPEED
	local to = p - me
	local t = 0
	local denom = rel:Dot(rel)
	if denom > 0.0001 then
		t = math.clamp(to:Dot(rel) / denom, 0, KITE_HORIZON)
	end
	local us = me + dir * (KITE_SPEED * t)
	local them = p + vel * t
	return (us - them).Magnitude, t
end

-- How far the heading stays clear, from chest height so a kerb is not a wall.
local function clearDistance(me, dir)
	kiteParams.FilterDescendantsInstances = kiteFilter
	local origin = me + Vector3.new(0, 2.5, 0)
	local reach = KITE_SPEED * KITE_HORIZON
	local hit = Workspace:Raycast(origin, dir * reach, kiteParams)
	return hit and hit.Distance or reach
end

local function chooseHeading(me, objDir, flee)
	local now = os.clock()
	local keep = flag("MoveKeepDistance")
	local hazardRadius = flag("MoveHazardRadius")

	-- A committed heading is held, unless something has got right on top of us —
	-- then it is worth throwing the decision away and re-scoring immediately.
	if kite.dir and now - kite.at < KITE_COMMIT then
		local pressed = false
		for _, e in pairs(Entities) do
			local proxy = e.proxy
			local part = proxy and proxy.Parent
				and (proxy:FindFirstChild("Head") or proxy:FindFirstChild("Torso"))
			if e.alive and part and (part.Position - me).Magnitude < keep * 0.5 then
				pressed = true
				break
			end
		end
		if not pressed then return kite.dir, kite.note end
	end

	-- Build the threat lists once, not once per candidate.
	local threats = {}
	for _, e in pairs(Entities) do
		local proxy = e.proxy
		local part = proxy and proxy.Parent
			and (proxy:FindFirstChild("Head") or proxy:FindFirstChild("Torso"))
		if e.alive and part then
			local pos = part.Position
			if (pos - me).Magnitude < keep * 3 then
				local rec = trackHistory[proxy]
				threats[#threats + 1] = { pos = pos, vel = rec and rec.vel or Vector3.zero }
			end
		end
	end

	-- Travel from position history: this game moves projectiles by writing CFrames,
	-- so AssemblyLinearVelocity is frequently zero and every dodge would be blind.
	local projectiles = {}
	local projFolder = Workspace:FindFirstChild("ClientZombieProjectiles")
	if projFolder then
		for _, proj in ipairs(projFolder:GetChildren()) do
			local part = proj:IsA("BasePart") and proj or proj:FindFirstChildWhichIsA("BasePart")
			if part then
				local pos = part.Position
				if (pos - me).Magnitude < keep * 2 then
					local prev = projHistory[part]
					local vel = Vector3.zero
					local dt = prev and (now - prev.at) or 0
					if prev and dt > 0.001 and dt < 0.5 then
						vel = (pos - prev.pos) / dt
					end
					projectiles[#projectiles + 1] = { pos = pos, vel = vel }
				end
			end
		end
	end

	local hazards = hazardPoints(hazardRadius, me)
	local centre = flag("MoveAvoidCorners") and mapCentrePoint() or nil

	kiteFilter[1] = LocalPlayer.Character
	for i = 1, #zombieModels do kiteFilter[i + 1] = zombieModels[i] end
	for i = #zombieModels + 2, #kiteFilter do kiteFilter[i] = nil end

	local best, bestScore, bestWhy
	for i = 0, KITE_DIRECTIONS - 1 do
		local angle = (i / KITE_DIRECTIONS) * math.pi * 2
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local score, why = 0, nil

		for _, t in ipairs(threats) do
			local d = closestApproach(me, dir, t.pos, t.vel)
			if d < keep then
				score = score - (keep - d) * 3
				why = why or "slipping the horde"
			elseif d < keep * 2 then
				score = score - (keep * 2 - d) * 0.5
			end
		end

		for _, p in ipairs(projectiles) do
			local d = closestApproach(me, dir, p.pos, p.vel)
			if d < 4 then
				score = score - (4 - d) * 8
				why = "dodging"
			end
		end

		if hazardRadius > 0 then
			for _, hpos in ipairs(hazards) do
				local d = closestApproach(me, dir, hpos, Vector3.zero)
				if d < hazardRadius then
					score = score - (hazardRadius - d) * 2
					why = why or "off the hazard"
				end
			end
		end

		local reach = KITE_SPEED * KITE_HORIZON
		local free = clearDistance(me, dir)
		if free < reach then
			score = score - (reach - free) * 0.35
			why = why or "along the wall"
		end

		if centre then
			local away = centre - me
			if away.Magnitude > 1 then score = score + dir:Dot(away.Unit) * 0.6 end
		end

		if objDir then
			-- The objective is a bias on this score, not a force fighting the
			-- others; when hurt it stops mattering much.
			score = score + dir:Dot(objDir) * (flee and 0.2 or 2.0)
			if dir:Dot(objDir) > 0.7 then why = why or "to the objective" end
		end

		if not bestScore or score > bestScore then
			bestScore, best, bestWhy = score, dir, why
		end
	end

	kite.dir, kite.at, kite.note = best, now, bestWhy or "kiting"
	return best, kite.note
end

local function moveThink()
	-- Either farm can drive the character; both need a live match to do it in.
	local autoMove = flag("MoveEnabled") and inMission() and (
		(flag("FarmEnabled") and not farm.halted)
		or (flag("SurvivalEnabled") and not survival.halted)
	)
	if not autoMove then
		if next(move.held) then releaseAll() end
		move.note = "off"
		return
	end

	local hum, root = myBody()
	if not hum then
		releaseAll()
		move.note = "no character"
		return
	end

	local me = root.Position
	local desired = Vector3.zero
	local note = nil

	-- 1. Head for the objective while there is one — this is what makes SOS
	--    (reach the survivor), Resupply (reach the supply) and Power (reach the
	--    survivors) playable at all. Holding a standoff rather than hugging it is
	--    also what "stick around him" wants: close enough to defend, not on top.
	--
	--    Survival has no objective at all — there is nothing to reach, the whole
	--    job is to not die — and Stats.DAY still holds the last mission's day
	--    number in there, so objectivePoint would otherwise go looking for a
	--    Resupply folder in a map that has none.
	local obj, closeFully
	if not inSurvivalMatch() then
		obj, closeFully = objectivePoint(me)
	end
	local toObjDir
	local pull = 0
	local objDist
	if obj then
		local toObj = obj - me
		objDist = toObj.Magnitude
		local standoff = closeFully and 0 or flag("MoveStandoff")
		if objDist > standoff then
			toObjDir = toObj.Unit
			-- Deliberately stronger than the sidestep below: a pull that only
			-- just exceeds it makes the run orbit the objective instead of
			-- closing on it.
			pull = math.min(2.5, (objDist - standoff) / 8)
			desired = desired + toObjDir * pull
			note = closeFully and "to the marker" or "to objective"
		end
	end

	-- 2. One decision, not four competing forces. The scorer below weighs the
	--    horde, incoming fire, floor hazards, walls, the map centre and the
	--    objective together against each candidate heading, and the one it returns
	--    is held for a moment instead of being re-made twenty times a second.
	--
	--    It replaces the old objective pull + crowd push + dodge push + hazard push
	--    entirely: those were summed and then rounded into WASD, which is what made
	--    it orbit, oscillate, and in survival stand still until it died.
	local flee = hum.Health / math.max(hum.MaxHealth, 1) * 100 < flag("MoveFleeHealth")
	local heading, why = chooseHeading(me, toObjDir, flee)
	if heading then
		desired = heading
		note = why
		if flee then note = note .. " + hurt" end
	end

	if desired.Magnitude < 0.001 then
		releaseAll()
		move.travelling = false
		move.note = obj and "holding position" or "nothing to do"
		return
	end

	updateStuck(objDist)

	-- Stuck on something low: hop it, and drop the path so it is replanned from
	-- where the run actually ended up. Ledges, crates and stair lips are the usual
	-- culprits and a jump clears them without needing a new plan; replanning
	-- afterwards stops it walking back into the same corner.
	if stuck.cycles >= 2 and os.clock() - (nav.hopAt or 0) > 2 then
		nav.hopAt = os.clock()
		pcall(function() VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game) end)
		pcall(function() VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game) end)
		nav.waypoints = nil
	end

	-- Navigation. Markers that must be stood on skip pathfinding entirely: a path
	-- ends at its final waypoint, which is several studs shy of the goal, and the
	-- run would stop there and look like it had arrived — measured stopping 8.7
	-- studs short of the arrow, standing in the ring rather than on it. The last
	-- stretch is walked straight, with no standoff, so the marker is actually
	-- entered. Pathfinding is only for long hauls around geometry.
	-- Pathfinding for the whole approach, markers included. Steering straight at a
	-- target presses the run into whatever is between, which is the wall-hugging
	-- that leaves it stuck and then cornered. Only the last few studs are walked
	-- straight, which is still enough to step onto a marker.
	local target
	if obj and (not closeFully or objDist > 8) then
		target = navTarget(me, obj)
	end
	if target then
		local toTarget = Vector3.new(target.X - me.X, 0, target.Z - me.Z)
		if toTarget.Magnitude > 15 then
			local cam = Workspace.CurrentCamera
			if cam then aimCameraAt(cam, me + toTarget.Unit * 10, 0.3) end
			holdKeys({ [Enum.KeyCode.W] = true })
			move.travelling = true
			move.note = ("pathing (%d/%d)"):format(nav.index, #nav.waypoints)
			return
		end
		-- final leg: steer at the waypoint instead of the objective itself
		desired = toTarget.Magnitude > 0.01 and toTarget.Unit * 1.5 or desired
		note = "final leg"
	end
	move.travelling = false

	-- The rotate heuristic is a fallback only, and never for a marker that has to
	-- be stood on: circling an arrow is the one thing that cannot work, and it is
	-- exactly what happened — the run orbited at 9 studs, the "no progress" check
	-- kept re-rotating the heading, and it never walked in.
	if stuck.bias ~= 0 and not target and not closeFully and (objDist or 0) > 20 then
		desired = rotateY(desired, stuck.bias)
		note = (note and (note .. " + ") or "") .. "detouring"
	end

	steer(desired)
	move.note = note or "moving"
end

----------------------------------------------------------------
-- per-frame work
----------------------------------------------------------------

local stats = { tracked = 0, onScreen = 0, locked = nil }

local function renderESP()
	local cam = Workspace.CurrentCamera
	if not cam then return end

	local enabled = flag("EspEnabled")
	local vp = cam.ViewportSize
	local camPos = cam.CFrame.Position

	local showBox = enabled and flag("ShowBox")
	local showFill = enabled and flag("ShowFill") and showBox
	local showName = enabled and flag("ShowName")
	local showDist = enabled and flag("ShowDistance")
	local showHp = enabled and flag("ShowHealth")
	local showChams = enabled and flag("ShowChams")
	local showTracer = enabled and flag("ShowTracer")
	local maxDist = flag("MaxDistance")
	local drawDead = flag("DrawDead")
	local drawBosses = flag("DrawBosses")
	local normalColor = flag("BoxColor")
	local bossColor = flag("BossColor")
	local deadColor = flag("DeadColor")
	local filter = flag("TypeFilter")

	local thickness = flag("BoxThickness")
	local fillTransparency = flag("FillTransparency")
	local tracerOrigin = flag("TracerOrigin")
	local tracerThickness = flag("TracerThickness")

	local originY = (tracerOrigin == "Top" and 0) or (tracerOrigin == "Center" and vp.Y * 0.5) or vp.Y
	local tracerFrom = Vector2.new(vp.X * 0.5, originY)

	local onScreenCount = 0

	for id, e in pairs(Entities) do
		local pool = pools[id]
		local model = e.model
		local root = e.root

		local draw = enabled and model ~= nil and model.Parent ~= nil
			and root ~= nil and root.Parent ~= nil
		if draw and not e.alive and not drawDead then draw = false end
		if draw and e.isBoss and not drawBosses then draw = false end
		-- A type the game ships but the filter list somehow missed is drawn
		-- rather than silently swallowed.
		if draw and filter ~= nil and knownTypeSet[e.ztype] and not filter[e.ztype] then
			draw = false
		end

		local distance
		if draw then
			distance = (camPos - root.Position).Magnitude
			if distance > maxDist then draw = false end
		end

		local corners = draw and getCorners(model, root) or nil
		if draw and not corners then draw = false end

		-- project the 8 corners; anything with a corner on screen gets a box
		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		if draw then
			local rootCF = root.CFrame
			local visible = false
			for _, corner in ipairs(corners) do
				local sp, onScreen = cam:WorldToViewportPoint(rootCF * corner)
				if onScreen and sp.Z > 0 then
					visible = true
					if sp.X < minX then minX = sp.X end
					if sp.Y < minY then minY = sp.Y end
					if sp.X > maxX then maxX = sp.X end
					if sp.Y > maxY then maxY = sp.Y end
				end
			end
			draw = visible
		end

		if draw then
			onScreenCount = onScreenCount + 1
			if not pool then
				pool = newPool()
				pools[id] = pool
			end

			local color = e.isBoss and bossColor or normalColor
			if not e.alive then color = deadColor end

			local w, h = maxX - minX, maxY - minY
			if w < 3 then w = 3 end

			if showBox then
				pool.box.Visible = true
				pool.box.Color = color
				pool.box.Thickness = thickness
				pool.box.Position = Vector2.new(minX, minY)
				pool.box.Size = Vector2.new(w, h)
			else
				pool.box.Visible = false
			end

			if showFill then
				pool.fill.Visible = true
				pool.fill.Color = color
				pool.fill.Transparency = fillTransparency
				pool.fill.Position = Vector2.new(minX, minY)
				pool.fill.Size = Vector2.new(w, h)
			else
				pool.fill.Visible = false
			end

			local label = e.ztype
			if e.variant and e.variant ~= "Normal" and e.variant ~= "?" then
				label = label .. " " .. e.variant
			end

			if showName then
				pool.name.Visible = true
				pool.name.Text = label
				pool.name.Size = flag("NameSize")
				pool.name.Color = color
				pool.name.Position = Vector2.new(minX + w * 0.5, minY - 16)
			else
				pool.name.Visible = false
			end

			if showDist then
				pool.dist.Visible = true
				pool.dist.Text = ("%d st"):format(distance)
				pool.dist.Color = color
				pool.dist.Position = Vector2.new(minX + w * 0.5, maxY + 2)
			else
				pool.dist.Visible = false
			end

			-- Health comes off the proxy Humanoid, so it is the server's number,
			-- not an estimate. Drawn as a bar hugging the left edge of the box.
			local hasHp = showHp and e.hp and e.maxHp and e.maxHp > 0
			if hasHp then
				local pct = math.clamp(e.hp / e.maxHp, 0, 1)
				local barH = h * pct
				local barX = minX - 6
				pool.barBg.Visible = true
				pool.barBg.Color = Color3.fromRGB(16, 16, 20)
				pool.barBg.Transparency = 0.25
				pool.barBg.Position = Vector2.new(barX, minY)
				pool.barBg.Size = Vector2.new(4, h)
				pool.bar.Visible = true
				pool.bar.Color = Color3.fromHSV(0.33 * pct, 0.85, 1)
				pool.bar.Transparency = 0
				pool.bar.Position = Vector2.new(barX, maxY - barH)
				pool.bar.Size = Vector2.new(4, barH)
				pool.hp.Visible = true
				pool.hp.Text = ("%d/%d"):format(math.floor(e.hp + 0.5), math.floor(e.maxHp + 0.5))
				pool.hp.Color = color
				pool.hp.Position = Vector2.new(minX + w * 0.5, maxY + 15)
			else
				pool.barBg.Visible = false
				pool.bar.Visible = false
				pool.hp.Visible = false
			end

			if showTracer then
				pool.trace.Visible = true
				pool.trace.Color = color
				pool.trace.Thickness = tracerThickness
				pool.trace.From = tracerFrom
				pool.trace.To = Vector2.new(minX + w * 0.5, minY + h * 0.5)
			else
				pool.trace.Visible = false
			end

			if showChams then
				local h2 = chamsFor(e)
				h2.FillColor = color
				h2.OutlineColor = color
				h2.FillTransparency = flag("ChamsFillTransparency")
				h2.OutlineTransparency = flag("ChamsOutlineTransparency")
				h2.DepthMode = flag("ChamsThroughWalls")
					and Enum.HighlightDepthMode.AlwaysOnTop
					or Enum.HighlightDepthMode.Occluded
				h2.Enabled = true
			elseif chams[id] then
				chams[id].Enabled = false
			end
		elseif pool then
			hidePool(pool)
			if chams[id] then chams[id].Enabled = false end
		end
	end

	-- Recycle pools and highlights for zombies that no longer exist, rather than
	-- tearing them down and rebuilding them for the next spawn.
	for id, pool in pairs(pools) do
		if not Entities[id] then
			releasePool(pool)
			pools[id] = nil
			releaseChams(id)
		end
	end

	stats.tracked = 0
	for _ in pairs(Entities) do stats.tracked = stats.tracked + 1 end
	stats.onScreen = onScreenCount
end

-- Aim state that has to survive between frames: which target is being held, and
-- which one the turn fallback committed to. Both exist because re-deciding from
-- scratch sixty times a second is what made the camera thrash.
local aim = { currentId = nil, turnId = nil, turnAt = 0 }

-- The FOV is an angle now, so it means the same thing at any resolution. The
-- circle is drawn at whatever pixel radius that angle covers on this viewport.
local function fovPixelRadius(cam)
	local fov = math.rad(math.clamp(flag("AimFovDeg"), 0.5, 89))
	local half = math.rad(math.clamp(cam.FieldOfView, 1, 120)) / 2
	local tanHalf = math.tan(half)
	if tanHalf < 0.001 then return 0 end
	return (cam.ViewportSize.Y / 2) * math.tan(fov) / tanHalf
end

local function renderAim()
	local cam = Workspace.CurrentCamera
	if not cam then return end

	local vp = cam.ViewportSize
	local center = Vector2.new(vp.X * 0.5, vp.Y * 0.5)

	-- Auto fight: while the farm is driving a live mission it holds the aim key
	-- down for you, so combat needs no input at all. It also stands in for the
	-- aimbot's own toggle — asking someone to switch on two things to get one
	-- behaviour is a trap.
	local autoFight = inMission() and (
		(flag("FarmEnabled") and flag("FarmAutoFight") and not farm.halted)
		or (flag("SurvivalEnabled") and flag("SurvivalAutoFight") and not survival.halted)
	)
	local enabled = flag("AimEnabled") or autoFight

	if fovCircle then
		if enabled and flag("ShowFov") then
			fovCircle.Visible = true
			fovCircle.Position = center
			fovCircle.Radius = fovPixelRadius(cam)
			fovCircle.Thickness = 1
			fovCircle.Color = Color3.fromRGB(255, 255, 255)
			fovCircle.Transparency = 0.5
		else
			fovCircle.Visible = false
		end
	end

	-- aimPart is cleared here too, not only set when a target is found: leaving it
	-- behind made the status line report a part for a frame with no target at all.
	stats.locked, stats.aimError, stats.aimPos, stats.aimPart = nil, nil, nil, nil
	stats.crosshairDeg = crosshairOffset()
	if not enabled then
		aim.currentId, aim.turnId = nil, nil
		if aimPoint then aimPoint.Visible = false end
		return
	end

	local active = autoFight
		or (aimKeyHandle and aimKeyHandle:IsActive())
		or (aimKeyHandle == nil and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2))
	if not active then
		aim.currentId, aim.turnId = nil, nil
		if aimPoint then aimPoint.Visible = false end
		return
	end

	local fovDeg = flag("AimFovDeg")
	local maxDist = flag("AimDistance")
	local visibleOnly = flag("AimVisibleOnly")
	local byDistance = flag("AimPriority") == "Nearest"
	local camPos = cam.CFrame.Position

	local best, bestScore
	-- Score of the target being held, if it is still a legal choice this frame.
	local heldScore

	for _, e in pairs(Entities) do
		if e.alive then
			local part = aimPartFor(e)
			local pos = part and part.Position
			if pos then
				-- An angular cone is circular on screen and resolution-proof, and
				-- it excludes anything behind the camera for free (>90 degrees).
				local err = aimError(cam, pos)
				if err <= fovDeg then
					local worldDist = (camPos - pos).Magnitude
					if worldDist <= maxDist then
						local score = byDistance and worldDist or err
						if e.id == aim.currentId then heldScore = score end
						if not bestScore or score < bestScore then
							if not visibleOnly or isVisible(e, pos) then
								bestScore, best = score, e
							end
						end
					end
				end
			end
		end
	end

	-- Hysteresis. Picking the nearest every frame made it flip between two zombies
	-- at almost equal range in a crowd, and every flip swings the whole camera —
	-- which is exactly what read as the bot hallucinating its target.
	if best and heldScore and best.id ~= aim.currentId then
		local margin = math.clamp(flag("AimSwitchMargin") / 100, 0, 0.9)
		if bestScore >= heldScore * (1 - margin) then
			local held = Entities[aim.currentId]
			local heldPart = held and held.alive and aimPartFor(held)
			if heldPart then
				best = held
			end
		end
	end

	local part = best and best.alive and aimPartFor(best)
	if part then
		aim.currentId = best.id
		aim.turnId = nil
		stats.locked = best.ztype
		-- Surfaced so it is visible what is actually being aimed at: the proxy
		-- Head is the hittable head (CanQuery = true) and sits ~1.17 studs from
		-- the rendered one, so a crosshair that looks slightly off the mesh is
		-- still dead on the head hitbox.
		stats.aimPart = part.Name

		local aimPos = leadTarget(best, part, camPos)

		-- Optionally raise the aim to where the game draws its reticle instead of
		-- where the gun fires. Purely so the dot and the shots agree; it moves the
		-- impact up by the same angle, so hit registration pays for it.
		if flag("AimFollowCrosshair") then
			local deg = crosshairOffset()
			if deg and math.abs(deg) > 0.01 then
				aimPos = raiseAim(camPos, aimPos, deg)
			end
		end
		stats.aimPos = aimPos

		-- While the movement is on a long haul it owns the camera, or the two
		-- would fight and the walk would curve.
		if not move.travelling then
			aimCameraAt(cam, aimPos, math.clamp(flag("AimSpeed") / 100, 0.01, 1))
		end

		-- Fire gate: shoot only once the crosshair is genuinely on the target.
		-- Without it the triggerbot fired the instant a target was selected,
		-- while the camera was still easing in at AimSpeed, so most rounds left
		-- before the gun pointed at anything.
		local err = aimError(cam, aimPos)
		stats.aimError = err
		if (flag("Triggerbot") or autoFight) and err <= flag("AimFireGate") then
			fireTriggerbot(math.floor(center.X), math.floor(center.Y))
		end

		-- Show exactly where the shot is being sent. Green while the shot is
		-- allowed, red while the fire gate is still holding it — so it is obvious
		-- at a glance whether the aim is on target or the gate is too tight.
		if aimPoint then
			if flag("ShowAimPoint") then
				local sp, onScreen = cam:WorldToViewportPoint(aimPos)
				if onScreen and sp.Z > 0 then
					local size = 12
					aimPoint.Visible = true
					aimPoint.Position = Vector2.new(sp.X - size / 2, sp.Y - size / 2)
					aimPoint.Size = Vector2.new(size, size)
					aimPoint.Color = err <= flag("AimFireGate")
						and Color3.fromRGB(80, 255, 120)
						or Color3.fromRGB(255, 90, 90)
				else
					aimPoint.Visible = false
				end
			else
				aimPoint.Visible = false
			end
		end
		return
	end

	if aimPoint then aimPoint.Visible = false end
	aim.currentId = nil

	-- Nothing in the cone. Unattended that is a dead end: zombies arriving from
	-- behind never enter the view, so the run would just stand there. Turn toward
	-- one instead and it walks into the cone by itself — but only a VISIBLE one,
	-- and only every so often. Re-choosing the nearest every frame whipped the
	-- camera between two zombies at similar range and it never settled.
	if not autoFight or move.travelling then
		aim.turnId = nil
		return
	end

	local now = os.clock()
	local turnSpeed = math.clamp(flag("AimSpeed") / 100, 0.01, 1)

	-- Hold a committed turn for a moment so it can actually complete.
	if aim.turnId and now - aim.turnAt < 1.2 then
		local held = Entities[aim.turnId]
		local heldPart = held and held.alive and aimPartFor(held)
		if heldPart then
			stats.locked = "(turning)"
			aimCameraAt(cam, heldPart.Position, turnSpeed)
			return
		end
		aim.turnId = nil
	end

	-- And do not re-pick the turn target more than a couple of times a second.
	if now - aim.turnAt < 0.4 then return end

	local turn, turnDist
	for _, e in pairs(Entities) do
		if e.alive then
			local p = aimPartFor(e)
			local pos = p and p.Position
			if pos then
				local d = (camPos - pos).Magnitude
				if d <= maxDist and (turnDist == nil or d < turnDist) then
					if not visibleOnly or isVisible(e, pos) then
						turnDist, turn = d, e
					end
				end
			end
		end
	end

	aim.turnAt = now
	local turnPart = turn and aimPartFor(turn)
	if turnPart then
		aim.turnId = turn.id
		stats.locked = "(turning)"
		aimCameraAt(cam, turnPart.Position, turnSpeed)
	end
end

----------------------------------------------------------------
-- type list, read from the game rather than hardcoded
----------------------------------------------------------------

-- ReplicatedStorage.ZombieVisuals.Models is every normal zombie type and
-- .BossModels every boss, so the filter can offer types that are not currently
-- spawned instead of only the ones we happen to have seen. knownTypeSet (the
-- lookup renderESP uses) is declared near the top of the file.
local function knownTypes()
	local list = {}
	local visuals = ReplicatedStorage:FindFirstChild("ZombieVisuals")

	for _, folderName in ipairs({ "Models", "BossModels" }) do
		local folder = visuals and visuals:FindFirstChild(folderName)
		if folder then
			for _, entry in ipairs(folder:GetChildren()) do
				if entry.Name ~= "Template" then
					list[#list + 1] = entry.Name
					knownTypeSet[entry.Name] = true
				end
			end
		end
	end

	if #list == 0 then
		list = { "Shambler", "Nurse", "Dog", "Bomber", "Clown", "Crow", "SWAT", "Cowboy", "Cop", "Miner", "Marine", "Strawminion", "Sailor" }
		for _, name in ipairs(list) do knownTypeSet[name] = true end
	end
	table.sort(list)
	return list
end

----------------------------------------------------------------
-- EZ UI
----------------------------------------------------------------

local statusLabel
local autoLeaveLabel
local farmLabel
local moveLabel
local speedLabel
local survivalLabel
local farmToggleHandle

do
	local ok, lib = pcall(function()
		return loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Library.lua"))()
	end)
	if ok and type(lib) == "table" then
		EZ = lib
		Window = EZ:CreateWindow({
			Title = "Call of Mini Zombies 2",
			SubTitle = "zombie ESP + aim assist",
			ToggleKey = Enum.KeyCode.RightShift,
			ToggleIcon = "crosshair",
		})

		local espTab = Window:AddTab("ESP", "eye")

		local drawBox = espTab:AddLeftGroupbox("Draw", "box-select")
		drawBox:AddToggle("EspEnabled", {
			Text = "Zombie ESP",
			Default = DEFAULTS.EspEnabled,
			Tooltip = "Master switch for everything on this tab.",
		})
		drawBox:AddToggle("ShowBox", {
			Text = "Box",
			Default = DEFAULTS.ShowBox,
			Tooltip = "Tight box around the drawn model — it rotates with the zombie.",
		})
		drawBox:AddToggle("ShowFill", {
			Text = "Box fill",
			Default = DEFAULTS.ShowFill,
			Tooltip = "Translucent panel behind the box outline.",
		})
		drawBox:AddToggle("ShowName", {
			Text = "Name",
			Default = DEFAULTS.ShowName,
			Tooltip = "Zombie type and variant, e.g. \"Bomber Nightmare\".",
		})
		drawBox:AddToggle("ShowDistance", {
			Text = "Distance",
			Default = DEFAULTS.ShowDistance,
			Tooltip = "Studs from the camera.",
		})
		drawBox:AddToggle("ShowHealth", {
			Text = "Health bar",
			Default = DEFAULTS.ShowHealth,
			Tooltip = "Left edge of the box. Read off the zombie's own Humanoid, so it is the server's number.",
		})
		drawBox:AddToggle("ShowChams", {
			Text = "Chams",
			Default = DEFAULTS.ShowChams,
			Tooltip = "Solid colour over the whole model — the game's own zombie radar does this too.",
		})
		drawBox:AddToggle("ShowTracer", {
			Text = "Tracer",
			Default = DEFAULTS.ShowTracer,
			Tooltip = "Line from the screen edge to each zombie.",
		})
		drawBox:AddToggle("ShowAimPoint", {
			Text = "Show aim point",
			Default = DEFAULTS.ShowAimPoint,
			Tooltip = "A box on the exact hitbox the aimbot is firing at. It goes green when the shot is "
				.. "allowed and red while it is holding fire. The zombies you see are decoration that "
				.. "bullets pass straight through — the real hitbox is an invisible model about 1.2 studs "
				.. "away, so this is how you tell where the shots are really going.",
		})

		local styleBox = espTab:AddRightGroupbox("Style", "palette")
		styleBox:AddColorPicker("BoxColor", {
			Text = "Normal colour",
			Default = DEFAULTS.BoxColor,
			Palette = {
				Color3.fromRGB(255, 64, 64),
				Color3.fromRGB(255, 170, 40),
				Color3.fromRGB(120, 255, 120),
				Color3.fromRGB(80, 200, 255),
				Color3.fromRGB(220, 120, 255),
				Color3.fromRGB(255, 255, 255),
			},
		})
		styleBox:AddColorPicker("BossColor", {
			Text = "Boss colour",
			Default = DEFAULTS.BossColor,
			Tooltip = "Bosses are Variant = \"Boss\" in the game's own data, not guessed from size.",
		})
		styleBox:AddColorPicker("DeadColor", {
			Text = "Dying colour",
			Default = DEFAULTS.DeadColor,
			Tooltip = "Only used when \"Show dying\" is on.",
		})
		styleBox:AddSlider("BoxThickness", {
			Text = "Box thickness",
			Min = 1, Max = 4, Increment = 1, Default = DEFAULTS.BoxThickness, Suffix = " px",
		})
		styleBox:AddSlider("FillTransparency", {
			Text = "Fill opacity",
			Min = 0, Max = 1, Increment = 0.05, Default = DEFAULTS.FillTransparency,
		})
		styleBox:AddSlider("NameSize", {
			Text = "Name size",
			Min = 8, Max = 24, Increment = 1, Default = DEFAULTS.NameSize, Suffix = " px",
		})
		styleBox:AddSlider("TracerThickness", {
			Text = "Tracer thickness",
			Min = 1, Max = 4, Increment = 1, Default = DEFAULTS.TracerThickness, Suffix = " px",
		})
		styleBox:AddDropdown("TracerOrigin", {
			Text = "Tracer from",
			Values = { "Bottom", "Center", "Top" },
			Default = DEFAULTS.TracerOrigin,
		})
		styleBox:AddToggle("ChamsThroughWalls", {
			Text = "Chams through walls",
			Default = DEFAULTS.ChamsThroughWalls,
			VisibleWhen = "ShowChams",
			Tooltip = "Off = the model is only coloured while you can actually see it.",
		})
		styleBox:AddSlider("ChamsFillTransparency", {
			Text = "Chams fill opacity",
			Min = 0, Max = 1, Increment = 0.05, Default = DEFAULTS.ChamsFillTransparency,
			VisibleWhen = "ShowChams",
		})
		styleBox:AddSlider("ChamsOutlineTransparency", {
			Text = "Chams outline opacity",
			Min = 0, Max = 1, Increment = 0.05, Default = DEFAULTS.ChamsOutlineTransparency,
			VisibleWhen = "ShowChams",
		})

		local filterBox = espTab:AddLeftGroupbox("Filter", "filter")
		local zombieTypes = knownTypes()
		filterBox:AddDropdown("TypeFilter", {
			Text = "Zombie types",
			Multi = true,
			Searchable = true,
			Values = zombieTypes,
			Default = table.clone(zombieTypes),
			Tooltip = "Unticked types are not drawn. The list is every type the game ships, read from ReplicatedStorage — not just the ones alive right now.",
		})
		filterBox:AddSlider("MaxDistance", {
			Text = "Max distance",
			Min = 50, Max = 2000, Increment = 25, Default = DEFAULTS.MaxDistance, Suffix = " st",
		})
		filterBox:AddToggle("DrawDead", {
			Text = "Show dying",
			Default = DEFAULTS.DrawDead,
			Tooltip = "Zombies stay drawn for ~1.5s after death while the model fades out.",
		})
		filterBox:AddToggle("DrawBosses", {
			Text = "Show bosses",
			Default = DEFAULTS.DrawBosses,
		})

		local aimTab = Window:AddTab("Aim", "crosshair")

		local aimBox = aimTab:AddLeftGroupbox("Aimbot", "target")
		aimBox:AddToggle("AimEnabled", {
			Text = "Aimbot",
			Default = DEFAULTS.AimEnabled,
		})
		aimKeyHandle = aimBox:AddKeybind("AimKey", {
			Text = "Aim key",
			Mode = "Hold",
			Default = "MouseButton2",
			Tooltip = "Held down while the aimbot pulls. Default is right mouse.",
		})
		aimBox:AddToggle("ShowFov", {
			Text = "Show FOV circle",
			Default = DEFAULTS.ShowFov,
			VisibleWhen = "AimEnabled",
		})
		aimBox:AddSlider("AimFovDeg", {
			Text = "FOV cone",
			Min = 1, Max = 90, Increment = 1, Default = DEFAULTS.AimFovDeg, Suffix = "°",
			VisibleWhen = "AimEnabled",
			Tooltip = "Half-angle around the crosshair, in degrees. An angle rather than a pixel radius, "
				.. "so it means the same thing whatever your resolution is.",
		})
		aimBox:AddSlider("AimFireGate", {
			Text = "Fire within",
			Min = 0.2, Max = 15, Increment = 0.2, Default = DEFAULTS.AimFireGate, Suffix = "°",
			VisibleWhen = "AimEnabled",
			Tooltip = "Shoot only once the crosshair is this close to the target. Set it too wide and it "
				.. "sprays again; too tight and it stops firing at all as zombies move.",
		})
		aimBox:AddSlider("AimSwitchMargin", {
			Text = "Switch target only if better by",
			Min = 0, Max = 90, Increment = 5, Default = DEFAULTS.AimSwitchMargin, Suffix = "%",
			VisibleWhen = "AimEnabled",
			Tooltip = "Stops it flip-flopping between two zombies at almost equal range, which swings the "
				.. "camera and wastes the shots in between. 0 = always take the closest.",
		})
		aimBox:AddToggle("AimLead", {
			Text = "Lead moving targets",
			Default = DEFAULTS.AimLead,
			VisibleWhen = "AimEnabled",
			Tooltip = "Bullets here are real projectiles, so this aims where the zombie will be rather than "
				.. "where it is. The travel time comes from the equipped weapon's own BulletSpeed.",
		})
		aimBox:AddSlider("AimLeadSpeed", {
			Text = "Bullet speed override",
			Min = 0, Max = 3000, Increment = 50, Default = DEFAULTS.AimLeadSpeed, Suffix = " st/s",
			VisibleWhen = "AimEnabled",
			Tooltip = "0 = read it off the equipped weapon (your FN-2000 says 2000). Set it only if a "
				.. "weapon's config cannot be read and the lead looks wrong.",
		})
		aimBox:AddSlider("AimSpeed", {
			Text = "Aim speed",
			Min = 1, Max = 100, Increment = 1, Default = DEFAULTS.AimSpeed, Suffix = "%",
			VisibleWhen = "AimEnabled",
			Tooltip = "Share of the remaining angle covered per frame. 100 = instant snap, low values glide.",
		})
		aimBox:AddSlider("AimDistance", {
			Text = "Max aim distance",
			Min = 20, Max = 1000, Increment = 10, Default = DEFAULTS.AimDistance, Suffix = " st",
			VisibleWhen = "AimEnabled",
		})
		aimBox:AddDropdown("AimPart", {
			Text = "Aim at",
			Values = { Head = "Head", Torso = "Torso" },
			Default = DEFAULTS.AimPart,
			VisibleWhen = "AimEnabled",
			Tooltip = "Both are the zombie's real hitboxes — the parts the game's own bullets raycast against.",
		})
		aimBox:AddDropdown("AimPriority", {
			Text = "Pick target by",
			Values = { Crosshair = "Closest to crosshair", Nearest = "Nearest zombie" },
			Default = DEFAULTS.AimPriority,
			VisibleWhen = "AimEnabled",
		})
		aimBox:AddToggle("AimVisibleOnly", {
			Text = "Only aim with line of sight",
			Default = DEFAULTS.AimVisibleOnly,
			VisibleWhen = "AimEnabled",
			Tooltip = "Skips zombies behind walls.",
		})
		aimBox:AddToggle("AimFollowCrosshair", {
			Text = "Aim at the game's crosshair, not the gun",
			Default = DEFAULTS.AimFollowCrosshair,
			VisibleWhen = "AimEnabled",
			Tooltip = "OFF BY DEFAULT, AND WORTH UNDERSTANDING FIRST. Your gun does not shoot where its "
				.. "crosshair is drawn. Measured on a live client: Mouse.UnitRay and the game's own "
				.. "AimAssist ray both project to screen y = 482, while GunGUI.Crosshair.Center, the dot "
				.. "you aim with, is drawn at y = 511 — 29 px, or about 2.45 degrees, lower. So the shots "
				.. "already go to the hitbox and the dot below it makes that look like it aims under the "
				.. "head. Turning this ON raises the aim onto the dot, which is what the eye wants and "
				.. "costs you the same 2.45 degrees of miss above the target. The green aim marker shows "
				.. "where the shots actually go in both cases.",
		})
		aimBox:AddSlider("AimHeightBias", {
			Text = "Aim height in the head",
			Min = -50, Max = 150, Increment = 5, Default = DEFAULTS.AimHeightBias, Suffix = "%",
			VisibleWhen = "AimEnabled",
			Tooltip = "Where the crosshair sits on the head, as a percentage of half its height. The "
				.. "hitbox and the zombie you can see are not in the same place — measured up to 1.4 "
				.. "studs apart, in a different direction per zombie — so the aim sits at whichever point "
				.. "is inside the hitbox and closest to the head you can see, and this lifts it from "
				.. "there. Up to 90% it is still inside the hitbox and the hit is guaranteed. Past 90% "
				.. "it has left the head on purpose: that is allowed because the gun resolves hits with a "
				.. "2.5-stud region rather than a ray, so a point just above the skull can still register "
				.. "on it — and aiming high is the only thing measured so far that raises the headshot "
				.. "rate. If shots start missing entirely, you have gone too far.",
		})

		local trigBox = aimTab:AddRightGroupbox("Triggerbot", "mouse-pointer-click")
		trigBox:AddToggle("Triggerbot", {
			Text = "Auto-fire",
			Default = DEFAULTS.Triggerbot,
			VisibleWhen = "AimEnabled",
			Tooltip = "Clicks the moment a target is locked. Shots follow the crosshair in this game, so it needs the aimbot on to be pointed at anything.",
		})
		trigBox:AddSlider("TriggerCps", {
			Text = "Max clicks/sec",
			Min = 1, Max = 30, Increment = 1, Default = DEFAULTS.TriggerCps,
			VisibleWhen = "Triggerbot",
		})

		local matchTab = Window:AddTab("Match", "log-out")
		local leaveBox = matchTab:AddLeftGroupbox("Auto leave", "door-open")
		leaveBox:AddToggle("AutoLeave", {
			Text = "Press OK for me when a run ends",
			Default = DEFAULTS.AutoLeave,
			Tooltip = "Both end-of-run screens carry a button labelled OK, and pressing it is the whole "
				.. "of leaving. This watches for it and presses it — in normal missions and in boss "
				.. "raids alike.",
		})
		leaveBox:AddSlider("AutoLeaveDelay", {
			Text = "Wait before pressing",
			Min = 0, Max = 15, Increment = 0.5, Default = DEFAULTS.AutoLeaveDelay, Suffix = " s",
			VisibleWhen = "AutoLeave",
			Tooltip = "Long enough to read the result, short enough to keep the loop moving.",
		})
		leaveBox:AddToggle("AutoLeaveForce", {
			Text = "Force the leave if OK does not take",
			Default = DEFAULTS.AutoLeaveForce,
			VisibleWhen = "AutoLeave",
			Tooltip = "Six seconds after the press, if the screen is still up, run the game's leave "
				.. "sequence directly instead. Only fires when the button has failed.",
		})
		autoLeaveLabel = leaveBox:AddLabel("Auto leave: idle")

		local leaveHowBox = matchTab:AddRightGroupbox("How it leaves", "route")
		leaveHowBox:AddParagraph({
			Title = "It presses the real button",
			Content = "A genuine simulated click at the button's own screen position, so the game's own "
				.. "handler runs and its internal bookkeeping stays correct. Two details that matter: "
				.. "the click point is AbsolutePosition + half the size + GuiService:GetGuiInset() "
				.. "(without the inset it lands 58px high and misses), and it only ever looks inside "
				.. "MissionComplete and MainMenu.ResultFrame, so a stray OK elsewhere cannot be hit.",
		})
		leaveHowBox:AddParagraph({
			Title = "Where it works",
			Content = "Normal missions (MissionComplete) and boss raids (MainMenu.ResultFrame) both have "
				.. "this button, so both are covered. A raid already drops you back to the lobby on its "
				.. "own — the button is what clears the result panel over it.",
		})
		leaveHowBox:AddParagraph({
			Title = "The fallback",
			Content = "Only used if the button has not taken after six seconds. It runs the same sequence "
				.. "the pause menu's Quit button does — the loading wipe, the BeginTutorial call that ends "
				.. "the run, then a lobby rebuild. It skips the reward animations, and leaves an internal "
				.. "flag stale so the rewards screen may stop appearing until you press OK by hand once.",
		})

		local farmTab = Window:AddTab("Farm", "repeat")
		local farmBox = farmTab:AddLeftGroupbox("Auto farm", "sprout")
		farmToggleHandle = farmBox:AddToggle("FarmEnabled", {
			Text = "Farm missions on repeat",
			Default = DEFAULTS.FarmEnabled,
			Tooltip = "Start the current day, fight it, let auto leave clear the result, then start the "
				.. "next one. Runs off the lobby/mission state the game already exposes, so it does not "
				.. "care which map or day you are on.",
		})
		farmBox:AddToggle("FarmAutoStart", {
			Text = "Start the next mission",
			Default = DEFAULTS.FarmAutoStart,
			VisibleWhen = "FarmEnabled",
			Tooltip = "Opens the mission panel and presses START. Off = it will only play, never start.",
		})
		farmBox:AddToggle("FarmAutoFight", {
			Text = "Fight for me",
			Default = DEFAULTS.FarmAutoFight,
			VisibleWhen = "FarmEnabled",
			Tooltip = "Holds the aim key down for the whole mission and fires whenever a zombie is "
				.. "locked, so nothing needs pressing.",
		})
		farmBox:AddSlider("FarmStartDelay", {
			Text = "Wait before starting",
			Min = 0, Max = 15, Increment = 0.5, Default = DEFAULTS.FarmStartDelay, Suffix = " s",
			VisibleWhen = "FarmEnabled",
			Tooltip = "Lets the lobby settle first — the menu ignores clicks while it is still animating.",
		})
		farmBox:AddSlider("FarmMaxLosses", {
			Text = "Stop after",
			Min = 1, Max = 20, Increment = 1, Default = DEFAULTS.FarmMaxLosses, Suffix = " losses",
			VisibleWhen = "FarmEnabled",
			Tooltip = "Consecutive runs that do not clear the day. Guards against burning attempts on a "
				.. "day the bot cannot finish.",
		})
		farmBox:AddToggle("FarmStopOnMoveTask", {
			Text = "Pause on days that need you to move",
			Default = DEFAULTS.FarmStopOnMoveTask,
			VisibleWhen = "FarmEnabled",
			Tooltip = "On by default: the movement below handles SOS, Resupply and Power but its "
				.. "navigation is not yet reliable, so those days stop with a note rather than wander. "
				.. "Turn this off to let it try them.",
		})
		farmBox:AddToggle("FarmClaimTasks", {
			Text = "Claim finished challenges",
			Default = DEFAULTS.FarmClaimTasks,
			Tooltip = "Checks the Hourly / Daily / Weekly / Monthly challenges once a minute and claims "
				.. "any that are complete but uncollected.",
		})
		local moveBox = farmTab:AddLeftGroupbox("Movement", "footprints")
		moveBox:AddToggle("MoveEnabled", {
			Text = "Move me",
			Default = DEFAULTS.MoveEnabled,
			Tooltip = "Simulated WASD, which the game's own control module reads. It only engages while "
				.. "the farm is driving a live mission, so manual play is left alone.",
		})
		moveBox:AddSlider("MoveKeepDistance", {
			Text = "Keep away from zombies",
			Min = 5, Max = 60, Increment = 1, Default = DEFAULTS.MoveKeepDistance, Suffix = " st",
			Tooltip = "Backs off whenever a zombie gets inside this ring.",
		})
		moveBox:AddSlider("MoveStandoff", {
			Text = "Objective standoff",
			Min = 2, Max = 40, Increment = 1, Default = DEFAULTS.MoveStandoff, Suffix = " st",
			Tooltip = "How close to get to a rescue / supply / survivor and then hold. Close enough to "
				.. "defend, not standing on top of them.",
		})
		moveBox:AddSlider("MoveDodgeRadius", {
			Text = "Dodge projectiles within",
			Min = 5, Max = 50, Increment = 1, Default = DEFAULTS.MoveDodgeRadius, Suffix = " st",
			Tooltip = "Sidesteps anything travelling towards you inside this range.",
		})
		moveBox:AddSlider("MoveFleeHealth", {
			Text = "Flee below",
			Min = 5, Max = 90, Increment = 5, Default = DEFAULTS.MoveFleeHealth, Suffix = "% health",
			Tooltip = "Below this the objective is dropped and distance is put on the horde instead.",
		})
		moveBox:AddSlider("MoveHazardRadius", {
			Text = "Step off hazards within",
			Min = 0, Max = 40, Increment = 1, Default = DEFAULTS.MoveHazardRadius, Suffix = " st",
			Tooltip = "Acid, puddles, anything named as a danger zone, and whatever the client spawns into "
				.. "ClientZombieEffects — it walks out of these. Set 0 to ignore them.",
		})
		moveBox:AddToggle("MoveAvoidCorners", {
			Text = "Steer away from corners",
			Default = DEFAULTS.MoveAvoidCorners,
			Tooltip = "Headings back toward the middle of the map get a small bonus. Kiting dies in a "
				.. "corner: once the horde has you in one there is no heading left that gains ground, so "
				.. "this is what stops it backing itself into scenery.",
		})
		moveLabel = moveBox:AddLabel("Move: idle")

		farmLabel = farmBox:AddLabel("Farm: idle")

		local farmHowBox = farmTab:AddRightGroupbox("What it does and does not do", "list-checks")
		farmHowBox:AddParagraph({
			Title = "State, not timers",
			Content = "HUD.Enabled means a mission is live, MainMenu.Enabled means the lobby is up, an OK "
				.. "button means the run ended, and Stats.DAY only moves on a win — so comparing it "
				.. "either side of a run is the win/loss signal. No timing guesses anywhere.",
		})
		farmHowBox:AddParagraph({
			Title = "Covers the combat days",
			Content = "Normal, Boss, Tank, BloodMoon and Heartbeat — 52 of the 67 days — are cleared by "
				.. "killing what spawns, which is what the aimbot does. The other 15 (SOS 7, Resupply 6, "
				.. "Power 2) need you to walk somewhere.",
		})
		farmHowBox:AddParagraph({
			Title = "Movement is the weak link",
			Content = "SOS, Resupply and Power need you to walk somewhere, and the movement below does try: "
				.. "it follows the game's own arrow, paths around geometry, and escorts the person on "
				.. "escort days. But its navigation is still not reliable — measured runs oscillate rather "
				.. "than converge — so the farm stops on those 15 days by default rather than burning "
				.. "attempts on a wander. Turn off the stop toggle to watch it try.",
		})

		local speedTab = Window:AddTab("Speed", "zap")
		local abilityBox = speedTab:AddLeftGroupbox("The game's own speed", "wind")
		abilityBox:AddToggle("AbilityAuto", {
			Text = "Use my ability on cooldown",
			Default = DEFAULTS.AbilityAuto,
			Tooltip = "Presses the game's own ability button for you whenever the server says it is ready. "
				.. "OFF BY DEFAULT, AND NOT YET RELIABLE. Testing could not get it to fire: the game's "
				.. "handler refuses unless the ability's own conditions are met, and JoeBlo's dash needs a "
				.. "zombie in front of you before it will go. A failed press does nothing, so turning it on "
				.. "is harmless — just do not count on it yet. The ability itself is still the safe way to "
				.. "be fast once this works properly.",
		})
		abilityBox:AddParagraph({
			Title = "What this does not do",
			Content = "It does not change how fast you walk. In this game WalkSpeed is the risky thing to "
				.. "touch, which is what the box on the right is about.",
		})
		abilityBox:AddParagraph({
			Title = "Why the button and not LeftShift",
			Content = "LeftShift is also Roblox's own shift-lock toggle, so synthesising the key would fight "
				.. "the game for it. Pressing the ability button is what a player does, and the game's own "
				.. "handler works out the rest.",
		})

		local speedBox = speedTab:AddRightGroupbox("WalkSpeed override (risky)", "triangle-alert")
		speedBox:AddToggle("SpeedBoostEnabled", {
			Text = "Override my walk speed",
			Default = DEFAULTS.SpeedBoostEnabled,
			Tooltip = "OFF BY DEFAULT, AND WORTH LEAVING OFF. Your character carries a script that hands "
				.. "its WalkSpeed to the server whenever the server asks for it, and another that raises "
				.. "\"Suspicious Activity Detected! Your account is at risk of being banned.\" A raised "
				.. "WalkSpeed cannot be hidden from either, and nothing client-side can undo that. This is "
				.. "the one switch here that puts your account at risk, which is why it is off.",
		})
		speedBox:AddSlider("SpeedBoostValue", {
			Text = "Walk speed",
			Min = 8, Max = 100, Increment = 1, Default = DEFAULTS.SpeedBoostValue,
			VisibleWhen = "SpeedBoostEnabled",
			Tooltip = "The game's own value in a match is about 16.05 rather than the stock 16, so whatever "
				.. "it is when you switch this on is remembered and put back exactly.",
		})
		speedBox:AddParagraph({
			Title = "Put back on the way out",
			Content = "Switching the toggle off, dying and respawning, the match ending, or unloading the "
				.. "script all restore the game's own value.",
		})
		speedLabel = speedBox:AddLabel("Speed: idle")

		local survTab = Window:AddTab("Survival", "skull")
		local survBox = survTab:AddLeftGroupbox("CO-OP survival", "play")
		survBox:AddToggle("SurvivalEnabled", {
			Text = "Farm CO-OP survival",
			Default = DEFAULTS.SurvivalEnabled,
			Tooltip = "Plays CO-OP survival on repeat: makes a party for the map and difficulty below, "
				.. "starts it, fights the run, then clears the result screen and goes again. The switch "
				.. "survives the restarts, because starting a match changes place and a place change "
				.. "wipes the script — so it reloads itself at each hop.",
		})
		survBox:AddDropdown("SurvivalMap", {
			Text = "Map",
			Values = SURVIVAL_MAPS,
			Default = DEFAULTS.SurvivalMap,
			VisibleWhen = "SurvivalEnabled",
			Tooltip = "The twelve the hub actually offers. The server is asked for this map by name in "
				.. "the party it creates, and it is honoured — verified landing in Warehouse on request.",
		})
		survBox:AddDropdown("SurvivalDifficulty", {
			Text = "Difficulty",
			Values = SURVIVAL_DIFFICULTIES,
			Default = DEFAULTS.SurvivalDifficulty,
			VisibleWhen = "SurvivalEnabled",
			Tooltip = "Normal: slow zombies, weak bosses. Medium: +15% zombie speed, 1.5x cash and XP. "
				.. "Hard: +30% zombie speed, 2x cash and XP.",
		})
		survBox:AddToggle("SurvivalAutoStart", {
			Text = "Start each match",
			Default = DEFAULTS.SurvivalAutoStart,
			VisibleWhen = "SurvivalEnabled",
			Tooltip = "Off = it will only play a match you started yourself.",
		})
		survBox:AddToggle("SurvivalAutoFight", {
			Text = "Fight for me",
			Default = DEFAULTS.SurvivalAutoFight,
			VisibleWhen = "SurvivalEnabled",
			Tooltip = "Holds the aim key and fires while a survival run is live. Survival has no "
				.. "objective, so this is the whole of the attack.",
		})
		survBox:AddToggle("SurvivalLeaveAfterWipe", {
			Text = "Clear the result and go again",
			Default = DEFAULTS.SurvivalLeaveAfterWipe,
			VisibleWhen = "SurvivalEnabled",
			Tooltip = "Presses the result screen's own button, which returns you to the hub for the next "
				.. "run. With auto leave on, that handles the press instead and this just counts the run.",
		})
		survBox:AddSlider("SurvivalMaxRuns", {
			Text = "Stop after",
			Min = 0, Max = 50, Increment = 1, Default = DEFAULTS.SurvivalMaxRuns, Suffix = " runs",
			VisibleWhen = "SurvivalEnabled",
			Tooltip = "0 = never stop. A run ends when the party wipes, so this is a run counter, not a "
				.. "wave target.",
		})
		survivalLabel = survBox:AddLabel("Survival: idle")

		local survHowBox = survTab:AddRightGroupbox("How it works", "route")
		survHowBox:AddParagraph({
			Title = "It talks to the hub directly",
			Content = "It creates the party and starts it by calling the hub's own remote, with the same "
				.. "payload the hub's UI sends — Limit 4, public, your chosen map and difficulty. No "
				.. "button clicking in the hub.",
		})
		survHowBox:AddParagraph({
			Title = "It has to reload itself",
			Content = "Starting a match, and leaving one, both change place, and a place change destroys "
				.. "a script completely. So it re-queues itself for the next place before every teleport "
				.. "it causes. If the executor has no queue_on_teleport, the loop will do one run and "
				.. "stop, and the status line will say so.",
		})
		survHowBox:AddParagraph({
			Title = "Runs end by wiping",
			Content = "CO-OP survival is endless waves — bosses every 7 — and there is no winning, only "
				.. "how far you get. A run ends when the party goes down, and the result screen reports "
				.. "the wave reached.",
		})

		local infoTab = Window:AddTab("Info", "info")
		local howBox = infoTab:AddLeftGroupbox("How this reads the game", "scan-eye")
		howBox:AddParagraph({
			Title = "Two layers, joined on the zombie's guid",
			Content = "ClientZombieVisuals holds the model you see. A separate proxy folder holds the "
				.. "server's model for the same zombie, which is where type, variant, alive state and "
				.. "health actually live. The box and tracer are drawn from the model; health, boss flag "
				.. "and target validity come from the proxy.",
		})
		howBox:AddParagraph({
			Title = "The proxy lives in different places",
			Content = "Normal maps keep it at CURRENT_MAP.<map>.ZombiesSpawnedIn.<zombie>. Boss raids keep "
				.. "it as a bare model beside the map parts, e.g. <map>.Zombie. It is found by looking "
				.. "for models that carry a zombie identity attribute rather than by path or name, so "
				.. "both layouts work.",
		})
		howBox:AddParagraph({
			Title = "Bosses",
			Content = "Variant = \"Boss\" (they also carry IsBoss/BossId). They are picked up by the same "
				.. "scan, so they show up without a separate setting — just in their own colour.",
		})
		howBox:AddParagraph({
			Title = "Corpses",
			Content = "A dying zombie keeps its model for about 1.5s while it fades. Its proxy is gone by "
				.. "then, so it counts as dead: still drawn if you ask for it, never aimed at.",
		})

		local statusBox = infoTab:AddRightGroupbox("Live", "activity")
		statusLabel = statusBox:AddLabel("Scanning...")

		EZ:Notify({
			Title = "Call of Mini Zombies 2",
			Content = "Loaded. RightShift = window, right mouse = aim, auto leave is on.",
			Duration = 4,
			Type = "success",
		})
	else
		warn("[ComzESP] EZ UI failed to load — running headless (ESP on, aim on right mouse)")
	end
end

----------------------------------------------------------------
-- run
----------------------------------------------------------------

if not DRAWING_OK then
	warn("[ComzESP] this executor has no Drawing library — the ESP cannot draw")
	if EZ then
		EZ:Notify({ Title = "ESP unavailable", Content = "No Drawing library in this executor.", Type = "error" })
	end
end

if chamsFolder == nil then
	chamsFolder = Instance.new("Folder")
	chamsFolder.Name = "ComzChams"
	pcall(function() chamsFolder.Parent = protectedParent() end)
end

if DRAWING_OK then
	fovCircle = Drawing.new("Circle")
	fovCircle.NumSides = 60
	fovCircle.Filled = false
	fovCircle.Visible = false

	-- Marks the exact proxy part the aimbot is firing at. The proxy is invisible
	-- and sits ~1.17 studs from the rendered head, so without this the crosshair
	-- looks like it is floating off the zombie even when it is dead on. Seeing it
	-- is what makes "is it actually aiming at the head?" answerable at a glance.
	aimPoint = Drawing.new("Square")
	aimPoint.Filled = false
	aimPoint.Thickness = 1
	aimPoint.Visible = false
end

local running = true

-- Auto leave polls for the OK button rather than listening for an event: the
-- mission place signals its end through MissionComplete.MissionEnd, but the boss
-- raid has no MissionComplete at all, and polling the button covers both without
-- needing to know which kind of run just finished.
task.spawn(function()
	while running do
		local ok, err = pcall(watchAutoLeave)
		if not ok then warn("[ComzESP] leave:", err) end
		local ok2, err2 = pcall(watchFarm)
		if not ok2 then warn("[ComzESP] farm:", err2) end
		local ok3, err3 = pcall(watchClaims)
		if not ok3 then warn("[ComzESP] claims:", err3) end
		local ok4, err4 = pcall(watchSpeed)
		if not ok4 then warn("[ComzESP] speed:", err4) end
		local ok5, err5 = pcall(watchSurvival)
		if not ok5 then warn("[ComzESP] survival:", err5) end
		task.wait(0.5)
	end
end)

-- Movement runs on its own faster loop: steering has to keep up with the camera
-- the aimbot is turning, but the watchers above walk GUI trees and have no
-- business running twenty times a second.
task.spawn(function()
	while running do
		local ok, err = pcall(moveThink)
		if not ok then
			warn("[ComzESP] move:", err)
			-- never leave a key held if the steering logic falls over
			pcall(releaseAll)
		end
		task.wait(0.05)
	end
end)

task.spawn(function()
	while running do
		local ok, err = pcall(rebuildEntities)
		if not ok then warn("[ComzESP] scan:", err) end
		task.wait(0.1)
	end
end)

task.spawn(function()
	while running do
		task.wait(1)
		if statusLabel then
			pcall(function()
				-- The aim error is in the line on purpose: it is the difference
				-- between "it has a target" and "it is actually allowed to shoot",
				-- and it is the number to watch when the fire gate needs tuning.
				-- The object counts are in this line on purpose: if the game ever
				-- crashes after a while, these are the numbers to watch. They should
				-- sit flat at roughly the number of zombies alive at once; if they
				-- climb match after match, something is not being recycled.
				statusLabel:Set(("Tracked %d | on screen %d | aiming %s @ %s | err %s | reticle %s | draw %d + %d spare, chams %d + %d")
					:format(stats.tracked, stats.onScreen, stats.locked or "—", stats.aimPart or "—",
						stats.aimError and ("%.2f°"):format(stats.aimError) or "—",
						stats.crosshairDeg and ("%+.2f° off axis"):format(stats.crosshairDeg) or "not found",
						#pools, #poolFree, #chams, #chamsFree))
			end)
		end
		if autoLeaveLabel then
			pcall(function() autoLeaveLabel:Set("Auto leave: " .. autoLeave.last) end)
		end
		if farmLabel then
			pcall(function()
				farmLabel:Set(("Farm: %s | %s | runs %d, cleared %d, failed %d | claims: %s")
					:format(farm.state, farm.note, farm.runs, farm.wins, farm.losses, claims.note))
			end)
		end
		if moveLabel then
			pcall(function() moveLabel:Set("Move: " .. move.note) end)
		end
		if speedLabel then
			pcall(function()
				speedLabel:Set(("Speed: %s | ability %s"):format(
					speed.note, flag("AbilityAuto") and (abilityReady() and "ready" or "cooling") or "off"))
			end)
		end
		if survivalLabel then
			pcall(function()
				survivalLabel:Set(("Survival: %s | %s | runs %d | place %d"):format(
					survival.state, survival.note, survival.runs, game.PlaceId))
			end)
		end
	end
end)

-- The aim loop is bound even without a Drawing library: it only needs one for
-- the FOV circle, and renderAim guards that. The ESP has nothing to draw with,
-- so its loop is skipped entirely.
if DRAWING_OK then
	RunService:BindToRenderStep("ComzESP", Enum.RenderPriority.Camera.Value + 60, function()
		local ok, err = pcall(renderESP)
		if not ok then warn("[ComzESP] draw:", err) end
	end)
end

RunService:BindToRenderStep("ComzAim", Enum.RenderPriority.Camera.Value + 50, function()
	local ok, err = pcall(renderAim)
	if not ok then warn("[ComzESP] aim:", err) end
end)

----------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------

local stopping = false

local function stop(destroyWindow)
	if stopping then return end
	stopping = true
	running = false

	pcall(function() RunService:UnbindFromRenderStep("ComzESP") end)
	pcall(function() RunService:UnbindFromRenderStep("ComzAim") end)

	-- A held movement key would keep the character walking after teardown.
	pcall(releaseAll)

	-- And a raised WalkSpeed would outlive the script entirely, which is the one
	-- piece of state here the game would keep seeing after it is gone.
	pcall(restoreWalkSpeed)

	for id, pool in pairs(pools) do
		destroyPool(pool)
		pools[id] = nil
	end
	for id, h in pairs(chams) do
		pcall(function() h:Destroy() end)
		chams[id] = nil
	end
	-- The recycled ones have to go too, or unloading leaves a screenful of idle
	-- Drawings and Highlights behind.
	for i = #poolFree, 1, -1 do
		destroyPool(poolFree[i])
		poolFree[i] = nil
	end
	for i = #chamsFree, 1, -1 do
		pcall(function() chamsFree[i]:Destroy() end)
		chamsFree[i] = nil
	end
	if fovCircle then
		pcall(function() fovCircle:Remove() end)
		fovCircle = nil
	end
	if aimPoint then
		pcall(function() aimPoint:Remove() end)
		aimPoint = nil
	end
	if chamsFolder then
		pcall(function() chamsFolder:Destroy() end)
		chamsFolder = nil
	end
	if destroyWindow and Window then
		pcall(function() Window:Destroy() end)
	end

	G.ComzESP = nil
end

if EZ then
	-- The window's X runs a full EZ:Destroy(); the library is already tearing
	-- itself down there, so only clean up our own objects.
	EZ:OnDestroy(function() stop(false) end)
end

G.ComzESP = {
	Stop = function() stop(true) end,
	Entities = function() return Entities end,
	Stats = function() return stats end,
	AutoLeave = function() return autoLeave end,
	Farm = function() return farm end,
	Claims = function() return claims end,
	Move = function() return move end,
	Speed = function() return speed end,
	Aim = function() return aim end,
	Survival = function() return survival end,
	PartyHub = function() return partyHub end,
	Rearm = rearmAfterTeleport,
	FarmToggle = farmToggleHandle,
	-- Sets a flag through its element handle, so the UI and any listeners stay in
	-- sync (writing EZ.Flags directly does neither).
	SetFlag = function(id, value)
		local handle = EZ and EZ._elements and EZ._elements[id]
		if handle and handle.Set then
			handle:Set(value)
			return true
		end
		return false
	end,
	Flags = DEFAULTS,
}

print("[ComzESP] armed | proxies:", proxyCount, "| drawing:", tostring(DRAWING_OK))
