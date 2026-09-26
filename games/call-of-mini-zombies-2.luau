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

-- Everything that must not block the ray: the target's own proxy + visual, the
-- rest of the horde (their proxies are raycastable even though the visuals are
-- not), and the local character.
local function isVisible(e, worldPos)
	local cam = Workspace.CurrentCamera
	if not cam then return false end

	local cached = visCache[e.id]
	local now = os.clock()
	if cached and cached.expires > now then return cached.value end

	local filter = table.create(#zombieModels + 1)
	for _, m in ipairs(zombieModels) do
		if m ~= e.proxy and m ~= e.model then filter[#filter + 1] = m end
	end
	local char = LocalPlayer.Character
	if char then filter[#filter + 1] = char end

	rayParams.FilterDescendantsInstances = filter
	local origin = cam.CFrame.Position
	local hit = Workspace:Raycast(origin, worldPos - origin, rayParams)
	local value = hit == nil

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

	local enabled = flag("AimEnabled")

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

	local active = aimKeyHandle and aimKeyHandle:IsActive()
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
		aimCameraAt(cam, bestPos, math.clamp(flag("AimSpeed") / 100, 0.01, 1))
		if flag("Triggerbot") then
			fireTriggerbot(math.floor(center.X), math.floor(center.Y))
		end
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
		task.wait(0.5)
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
				statusLabel:Set(("Tracked %d | on screen %d | aiming %s")
					:format(stats.tracked, stats.onScreen, stats.locked or "—"))
			end)
		end
		if autoLeaveLabel then
			pcall(function() autoLeaveLabel:Set("Auto leave: " .. autoLeave.last) end)
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
	Flags = DEFAULTS,
}

print("[ComzESP] armed | proxies:", proxyCount, "| drawing:", tostring(DRAWING_OK))
