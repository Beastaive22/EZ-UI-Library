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

local LocalPlayer = Players.LocalPlayer
local G = getgenv()

-- A previous injection owns render-step bindings and Drawing objects; drop it
-- before creating new ones, or the old ESP keeps drawing over the new one.
if G.ComzESP and G.ComzESP.Stop then pcall(G.ComzESP.Stop) end

----------------------------------------------------------------
-- defaults (also the fallback when the library fails to load)
----------------------------------------------------------------

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
	AimFov = 150,
	ShowFov = true,
	AimSpeed = 35,
	AimDistance = 300,
	AimPart = "Head",
	AimVisibleOnly = true,
	AimPriority = "Crosshair",
	Triggerbot = false,
	TriggerCps = 12,

	AutoLeave = true,
	AutoLeaveDelay = 3,
	AutoLeaveForce = true,

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
	MoveDodgeRadius = 18,
	MoveHazardRadius = 10,
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
local chams = {}      -- [guid] = Highlight
local chamsFolder
local fovCircle

local function newPool()
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
		h = Instance.new("Highlight")
		h.Name = "ComzChams"
		h.Parent = chamsFolder
		chams[e.id] = h
	end
	h.Adornee = e.model
	return h
end

----------------------------------------------------------------
-- line of sight (cached — a raycast per zombie per frame is wasteful)
----------------------------------------------------------------

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local visCache = {}
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
local function aimPartFor(e)
	local part = proxyPart(e, flag("AimPart"))
	if part then return part end
	part = proxyPart(e, "Head") or proxyPart(e, "Torso")
	if part then return part end
	-- Proxy gone or shaped unusually: fall back to what is on screen.
	return e.head or e.root
end

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

	cam.CFrame = cam.CFrame * CFrame.Angles(pitchDelta * alpha, yawDelta * alpha, 0)
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
local function findOkButton()
	local pg = LocalPlayer.PlayerGui
	for _, path in ipairs(OK_CONTAINERS) do
		local node = pg
		for _, part in ipairs(path) do
			node = node and node:FindFirstChild(part)
		end
		if isShowing(node) then
			for _, d in ipairs(node:GetDescendants()) do
				if (d:IsA("TextButton") or d:IsA("ImageButton"))
					and isShowing(d) and d.AbsoluteSize.X >= 40 and d.AbsoluteSize.Y >= 20 then
					if buttonLabel(d):gsub("%s", ""):upper() == "OK" then return d end
				end
			end
			local close = node:FindFirstChild("CloseButton", true)
			if close and isShowing(close) then return close end
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

	local btn = findOkButton()
	if not btn then
		autoLeave.seenAt, autoLeave.clicked = nil, false
		autoLeave.last = "watching for the OK button"
		return
	end

	-- Never press it mid-run: the HUD being up means a mission is live and this
	-- button is not an end-of-run one.
	local hud = LocalPlayer.PlayerGui:FindFirstChild("HUD")
	if hud and hud.Enabled then
		autoLeave.seenAt, autoLeave.clicked = nil, false
		autoLeave.last = "in a match"
		return
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

-- Radial push away from a hazard's centre — the right answer for a blob on the
-- floor, where stepping off it matters more than which way.
local function groundHazardPush(me, radius)
	local push = Vector3.zero
	for _, folderName in ipairs({ "ClientZombieEffects", "ClientZombieProjectiles" }) do
		local folder = Workspace:FindFirstChild(folderName)
		if folder then
			for _, obj in ipairs(folder:GetChildren()) do
				local part = obj:IsA("BasePart") and obj or obj:FindFirstChildWhichIsA("BasePart")
				if part then
					local away = me - part.Position
					local dist = away.Magnitude
					if dist > 0.01 and dist < radius then
						push = push + away.Unit * ((radius - dist) / radius)
					end
				end
			end
		end
	end
	for _, part in ipairs(hazardParts()) do
		if part.Parent then
			local away = me - part.Position
			local dist = away.Magnitude
			if dist > 0.01 and dist < radius then
				push = push + away.Unit * ((radius - dist) / radius)
			end
		end
	end
	return push
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

-- Repulsion from zombies that are inside the keep-out ring.
local function crowdPush(me, keep)
	local push = Vector3.zero
	for _, e in pairs(Entities) do
		if e.alive and e.root and e.root.Parent then
			local away = me - e.root.Position
			local dist = away.Magnitude
			if dist > 0.01 and dist < keep then
				push = push + away.Unit * ((keep - dist) / keep)
			end
		end
	end
	return push
end

-- Incoming projectiles: step perpendicular to their travel, to whichever side is
-- closer to where we already want to go.
--
-- Travel is read from position history, not AssemblyLinearVelocity: this game
-- moves things by setting CFrames (the zombie visuals are anchored), so a
-- physics velocity is frequently zero — which silently ignored every spitter
-- projectile and is why nothing was ever dodged.
local projHistory = setmetatable({}, { __mode = "k" })

local function dodgePush(me, radius, bias)
	local folder = Workspace:FindFirstChild("ClientZombieProjectiles")
	if not folder then return Vector3.zero end

	local now = os.clock()
	local push = Vector3.zero

	for _, proj in ipairs(folder:GetChildren()) do
		local part = proj:IsA("BasePart") and proj or proj:FindFirstChildWhichIsA("BasePart")
		if part then
			local pos = part.Position
			local prev = projHistory[part]
			projHistory[part] = { pos = pos, at = now }

			local toMe = me - pos
			local dist = toMe.Magnitude
			if dist > 0.01 and dist < radius then
				local travel
				if prev and now - prev.at < 0.5 then
					travel = pos - prev.pos
				else
					travel = part.AssemblyLinearVelocity * 0.05
				end

				-- 0.2 rather than a strict head-on test: a blob on a shallow
				-- angle still hurts, and stepping aside early is cheap.
				if travel.Magnitude > 0.05 and travel.Unit:Dot(toMe.Unit) > 0.2 then
					local side = travel.Unit:Cross(Vector3.new(0, 1, 0))
					if side.Magnitude > 0.01 then
						side = side.Unit
						if bias and side:Dot(bias) < 0 then side = -side end
						push = push + side * ((radius - dist) / radius)
					end
				end
			end
		end
	end
	return push
end

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
local function objectivePoint(me)
	local cm = Workspace:FindFirstChild("CURRENT_MAP")
	local map = cm and cm:GetChildren()[1]
	if not map then return nil end

	local info = dayInfo(currentDay())
	if not info or not info.Task then return nil end

	local folder = taskFolder(map, info.Task)

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

local function moveThink()
	local autoMove = flag("MoveEnabled") and flag("FarmEnabled")
		and not farm.halted and inMission()
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
	local keep = flag("MoveKeepDistance")
	local desired = Vector3.zero
	local note = nil

	-- 1. Head for the objective while there is one — this is what makes SOS
	--    (reach the survivor), Resupply (reach the supply) and Power (reach the
	--    survivors) playable at all. Holding a standoff rather than hugging it is
	--    also what "stick around him" wants: close enough to defend, not on top.
	local obj, closeFully = objectivePoint(me)
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

	-- 2. Stay off the horde — but only sideways, and never so hard that it
	--    cancels the approach. A push that opposes the objective would simply
	--    cancel it and leave the run hovering at a distance; walking around a
	--    horde is what a player does, refusing to walk past it is not.
	local push = crowdPush(me, keep)
	if push.Magnitude > 0.001 then
		if toObjDir then
			local along = push:Dot(toObjDir)
			if along < 0 then push = push - toObjDir * along end
		end
		local strength = math.min(1.2, push.Magnitude)
		if pull > 0 then strength = math.min(strength, pull * 0.8) end
		if strength > 0.001 then
			desired = desired + push.Unit * strength
			note = note and (note .. " + sidestep") or "sidestep"
		end
	end

	-- 3. Sidestep anything flying at us, and step off anything on the floor.
	local dodge = dodgePush(me, flag("MoveDodgeRadius"), desired.Magnitude > 0.001 and desired.Unit or nil)
	if dodge.Magnitude > 0.001 then
		desired = desired + dodge.Unit * 1.6
		note = note and (note .. " + dodging") or "dodging"
	end

	local hazard = groundHazardPush(me, flag("MoveHazardRadius"))
	if hazard.Magnitude > 0.001 then
		-- Deliberately stronger than the objective pull: nothing on the floor is
		-- worth standing in, and it is re-evaluated every tick so stepping out
		-- only costs a moment.
		desired = desired + hazard.Unit * math.min(3, hazard.Magnitude * 3)
		note = note and (note .. " + hazard") or "avoiding hazard"
	end

	-- 4. Hurt badly: the objective can wait, put distance on first.
	if hum.Health / math.max(hum.MaxHealth, 1) * 100 < flag("MoveFleeHealth") then
		local flee = crowdPush(me, keep * 3)
		if flee.Magnitude > 0.001 then
			desired = desired + flee.Unit * 2
			note = "fleeing"
		end
	end

	if desired.Magnitude < 0.001 then
		releaseAll()
		move.travelling = false
		move.note = obj and "holding position" or "nothing to do"
		return
	end

	updateStuck(objDist)

	-- Navigation. While a path waypoint is still a way off, the camera is aimed
	-- along the path and W is held, which makes the walk straight. Once the last
	-- leg is short the camera goes back to the aimbot and the steering below takes
	-- over, so the run can shoot while it closes the final few studs.
	local target = obj and navTarget(me, obj) or nil
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

	-- The rotate heuristic is a fallback only. Applying it while a path exists
	-- just fights the path and walks the run away from the objective.
	if stuck.bias ~= 0 and not target then
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

	-- drop pools for zombies that no longer exist
	for id, pool in pairs(pools) do
		if not Entities[id] then
			destroyPool(pool)
			pools[id] = nil
			if chams[id] then
				chams[id]:Destroy()
				chams[id] = nil
			end
		end
	end

	stats.tracked = 0
	for _ in pairs(Entities) do stats.tracked = stats.tracked + 1 end
	stats.onScreen = onScreenCount
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
	local autoFight = flag("FarmEnabled") and flag("FarmAutoFight") and not farm.halted and inMission()
	local enabled = flag("AimEnabled") or autoFight

	if fovCircle then
		if enabled and flag("ShowFov") then
			fovCircle.Visible = true
			fovCircle.Position = center
			fovCircle.Radius = flag("AimFov")
			fovCircle.Thickness = 1
			fovCircle.Color = Color3.fromRGB(255, 255, 255)
			fovCircle.Transparency = 0.5
		else
			fovCircle.Visible = false
		end
	end

	stats.locked = nil
	if not enabled then return end

	local active = autoFight
		or (aimKeyHandle and aimKeyHandle:IsActive())
		or (aimKeyHandle == nil and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2))
	if not active then return end

	local fov = flag("AimFov")
	local maxDist = flag("AimDistance")
	local visibleOnly = flag("AimVisibleOnly")
	local byDistance = flag("AimPriority") == "Nearest"
	local camPos = cam.CFrame.Position

	local best, bestScore, bestPos

	for _, e in pairs(Entities) do
		if e.alive then
			local part = aimPartFor(e)
			local pos = part and part.Position
			if pos then
				local sp, onScreen = cam:WorldToViewportPoint(pos)
				if onScreen and sp.Z > 0 then
					local screenDist = (Vector2.new(sp.X, sp.Y) - center).Magnitude
					if screenDist <= fov then
						local worldDist = (camPos - pos).Magnitude
						if worldDist <= maxDist then
							local score = byDistance and worldDist or screenDist
							if not bestScore or score < bestScore then
								if not visibleOnly or isVisible(e, pos) then
									bestScore, best, bestPos = score, e, pos
								end
							end
						end
					end
				end
			end
		end
	end

	if best then
		stats.locked = best.ztype
		-- Surfaced in the status line so it is visible what is being aimed at:
		-- the proxy Head is the hittable head (CanQuery = true) and sits ~1.2
		-- studs from the rendered one, so a crosshair that looks slightly off the
		-- mesh is still on the head hitbox.
		local part = aimPartFor(best)
		stats.aimPart = part and part.Name or "?"
		-- While the movement is on a long haul it owns the camera, or the two
		-- would fight and the walk would curve.
		if not move.travelling then
			aimCameraAt(cam, bestPos, math.clamp(flag("AimSpeed") / 100, 0.01, 1))
		end
		if flag("Triggerbot") or autoFight then
			fireTriggerbot(math.floor(center.X), math.floor(center.Y))
		end
		return
	end

	-- Nothing in the cone. Unattended that is a dead end: zombies arriving from
	-- behind never enter the view, so the run would just stand there. Turn
	-- toward the nearest one instead and it walks into the cone by itself.
	if not autoFight or move.travelling then return end

	local turnPos, turnDist
	for _, e in pairs(Entities) do
		if e.alive then
			local part = aimPartFor(e)
			local pos = part and part.Position
			if pos then
				local d = (camPos - pos).Magnitude
				if d <= maxDist and (turnDist == nil or d < turnDist) then
					turnDist, turnPos = d, pos
				end
			end
		end
	end

	if turnPos then
		stats.locked = "(turning)"
		aimCameraAt(cam, turnPos, math.clamp(flag("AimSpeed") / 100, 0.01, 1))
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
		aimBox:AddSlider("AimFov", {
			Text = "FOV radius",
			Min = 10, Max = 600, Increment = 5, Default = DEFAULTS.AimFov, Suffix = " px",
			VisibleWhen = "AimEnabled",
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
			Title = "Not covered: movement",
			Content = "There is no walk-to-objective yet, so those 15 days will stop the farm rather "
				.. "than loop on them. That is the next piece of work, and it needs watching a live SOS "
				.. "or Resupply day to find where the objective is announced.",
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
				statusLabel:Set(("Tracked %d | on screen %d | aiming %s @ %s")
					:format(stats.tracked, stats.onScreen, stats.locked or "—", stats.aimPart or "—"))
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

	for id, pool in pairs(pools) do
		destroyPool(pool)
		pools[id] = nil
	end
	for id, h in pairs(chams) do
		pcall(function() h:Destroy() end)
		chams[id] = nil
	end
	if fovCircle then
		pcall(function() fovCircle:Remove() end)
		fovCircle = nil
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
