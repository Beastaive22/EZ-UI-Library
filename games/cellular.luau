-- Cellular.io — Player Finder (sUNC / Potassium)
-- 1:1 minimap with true blob sizes · teammate selector · tracers · camera zoom · fast feed
if game.GameId ~= 10470290403 then return end

--[[
	How it reads the game: the client renders every cell as a GUI frame from a decoded
	snapshot. This script resolves the live GameController + RenderController tables out of
	the GC, so positions/mass/colours are the same values the game itself draws with.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local genv = getgenv()
if genv.CellularFinder then
	pcall(function()
		genv.CellularFinder.destroy()
	end)
	genv.CellularFinder = nil
end

----------------------------------------------------------------
-- Game constants (mirrored from ReplicatedStorage.Shared.Config)
----------------------------------------------------------------

local MAP_SIZE = 11000
local PELLET_VISUAL_RADIUS = 32

local FALLBACK_PALETTE = {
	Color3.fromRGB(255, 89, 89),
	Color3.fromRGB(255, 149, 89),
	Color3.fromRGB(255, 222, 89),
	Color3.fromRGB(150, 255, 89),
	Color3.fromRGB(89, 255, 131),
	Color3.fromRGB(89, 255, 236),
	Color3.fromRGB(89, 172, 255),
	Color3.fromRGB(120, 89, 255),
	Color3.fromRGB(214, 89, 255),
	Color3.fromRGB(255, 89, 193),
	Color3.fromRGB(255, 120, 120),
	Color3.fromRGB(64, 224, 208),
}

local PALETTE = FALLBACK_PALETTE
do
	local ok, cfg = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared", 10):WaitForChild("Config", 10))
	end)
	if ok and type(cfg) == "table" and type(cfg.PALETTE) == "table" then
		PALETTE = cfg.PALETTE
		if type(cfg.MAP_SIZE) == "number" then
			MAP_SIZE = cfg.MAP_SIZE
		end
		if type(cfg.PELLET_VISUAL_RADIUS) == "number" then
			PELLET_VISUAL_RADIUS = cfg.PELLET_VISUAL_RADIUS
		end
	end
end

-- radius of a cell in world units (Shared.GameMath.massToRadius)
local function massToRadius(mass)
	return math.sqrt(math.max(mass, 0) * 100)
end

local function paletteColor(index)
	if type(index) ~= "number" then
		return PALETTE[1]
	end
	return PALETTE[index + 1] or PALETTE[1]
end

----------------------------------------------------------------
-- Live game state (GameController + RenderController, via GC)
----------------------------------------------------------------

local State = {
	game = nil,
	render = nil,
	lastResolve = 0,
	failStreak = 0,
}

local function findGameTable()
	for _, v in getgc(true) do
		if
			type(v) == "table"
			and type(rawget(v, "snapshot")) == "function"
			and type(rawget(v, "myId")) == "number"
			and type(rawget(v, "entities")) == "table"
			and type(rawget(v, "pellets")) == "table"
		then
			return v
		end
	end
	return nil
end

local function findRenderTable()
	for _, v in getgc(true) do
		if
			type(v) == "table"
			and type(rawget(v, "_cellDraws")) == "table"
			and type(rawget(v, "_cellGuis")) == "table"
			and type(rawget(v, "_camera")) == "table"
			and rawget(v, "_gui") ~= nil
		then
			return v
		end
	end
	return nil
end

local function resolveState()
	State.game = State.game or findGameTable()
	State.render = State.render or findRenderTable()
	State.lastResolve = os.clock()
end

resolveState()

-- the renderer swaps its ScreenGui on respawn; re-resolve if it went stale
local function stateUsable()
	local r = State.render
	local g = State.game
	if not r or not g then
		return false
	end
	local gui = r._gui
	if not gui or not gui.Parent then
		return false
	end
	return true
end

----------------------------------------------------------------
-- Overlay GUI (DisplayOrder 400 — under the EZ window at 500)
----------------------------------------------------------------

local Overlay = {
	gui = nil,
	worldLayer = nil,
	mapPanel = nil,
	delta = function()
		return Vector2.zero
	end,
}

-- Origin of the game's world space expressed in OUR overlay's local pixels.
-- The game draws a world point at  gameGui.Abs + gameGui.Size/2 + (w - camera) * scale,
-- and our frames live inside a layer at ourGui.Abs, so the gui origin cancels out and
-- only the inset difference (Overlay.delta) survives.
local function cameraTransform()
	local r = State.render
	local cam = r._camera
	local gui = r._gui
	local origin = gui.AbsoluteSize * 0.5 - Vector2.new(cam.x, cam.y) * cam.scale
	origin = origin - Overlay.delta()
	return origin, cam.scale
end

local function make(className, props)
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function makeCircle(parent, zIndex)
	local f = make("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = zIndex,
		Parent = parent,
	})
	make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = f })
	return f
end

local function makeRing(parent, zIndex)
	local f = make("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = zIndex,
		Parent = parent,
	})
	make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = f })
	make("UIStroke", { Thickness = 1.5, Color = Color3.new(1, 1, 1), Parent = f })
	return f
end

local function makeLabel(parent, zIndex)
	local t = make("TextLabel", {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = zIndex,
		Text = "",
		Parent = parent,
	})
	make("UIStroke", { Thickness = 1.5, Color = Color3.new(0, 0, 0), Parent = t })
	return t
end

local UI = {
	dragHandle = nil,
	header = nil,
	headerLabel = nil,
	collapseBtn = nil,
	map = nil,
	mapBounds = nil,
	layers = {},
}

do
	local gui = make("ScreenGui", {
		Name = "CellularFinderOverlay",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ScreenInsets = Enum.ScreenInsets.None,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 400,
		Parent = LocalPlayer:WaitForChild("PlayerGui"),
	})
	Overlay.gui = gui

	-- tracers live here, sized to the full screen so lines can run off-edge
	local worldLayer = make("Frame", {
		Name = "World",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = false,
		ZIndex = 1,
		Parent = gui,
	})
	Overlay.worldLayer = worldLayer

	local HEADER_H = 22
	local PAD = 6
	local panelW = 300

	local panel = make("Frame", {
		Name = "MinimapPanel",
		BackgroundColor3 = Color3.fromRGB(12, 14, 20),
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(panelW, HEADER_H + (panelW - PAD * 2) + PAD),
		Position = UDim2.fromOffset(24, 150),
		ZIndex = 1,
		Parent = gui,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 10), Parent = panel })
	make("UIStroke", {
		Thickness = 1,
		Color = Color3.fromRGB(70, 78, 100),
		Transparency = 0.25,
		Parent = panel,
	})
	Overlay.mapPanel = panel

	local header = make("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, HEADER_H),
		Active = true,
		ZIndex = 2,
		Parent = panel,
	})
	UI.dragHandle = header

	make("TextLabel", {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = Color3.fromRGB(190, 200, 225),
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(9, 0),
		Size = UDim2.new(1, -40, 1, 0),
		Text = "CELLULAR FINDER",
		ZIndex = 3,
		Parent = header,
	})

	UI.headerLabel = make("TextLabel", {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = Color3.fromRGB(120, 200, 140),
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0, 0, 0, 0),
		Size = UDim2.new(1, -28, 1, 0),
		Text = "",
		ZIndex = 3,
		Parent = header,
	})

	local collapse = make("TextButton", {
		Name = "Collapse",
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(150, 160, 185),
		Text = "–",
		Size = UDim2.fromOffset(20, HEADER_H),
		Position = UDim2.new(1, -22, 0, 0),
		ZIndex = 3,
		Parent = header,
	})
	UI.collapseBtn = collapse

	local map = make("Frame", {
		Name = "Map",
		BackgroundColor3 = Color3.fromRGB(6, 7, 11),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(PAD, HEADER_H),
		Size = UDim2.fromOffset(panelW - PAD * 2, panelW - PAD * 2),
		ZIndex = 1,
		Parent = panel,
	})
	UI.map = map

	UI.layers.grid = make("Frame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = map,
	})

	-- the world's outer edge, so zooming out past the map is legible
	UI.mapBounds = make("Frame", {
		Name = "MapBounds",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
		Parent = UI.layers.grid,
	})
	make("UIStroke", {
		Thickness = 1,
		Color = Color3.fromRGB(96, 112, 150),
		Transparency = 0.15,
		Parent = UI.mapBounds,
	})
	UI.layers.pellets = make("Frame", {
		Name = "Pellets",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = map,
	})
	UI.layers.viruses = make("Frame", {
		Name = "Viruses",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Parent = map,
	})
	UI.layers.cells = make("Frame", {
		Name = "Cells",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = map,
	})
	UI.layers.labels = make("Frame", {
		Name = "Labels",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 5,
		Parent = map,
	})

	Overlay.delta = function()
		local r = State.render
		if not r or not r._gui or not r._gui.Parent then
			return Vector2.zero
		end
		return gui.AbsolutePosition - r._gui.AbsolutePosition
	end

	-- drag the panel by its header
	local dragging, dragStart, startPos = false, nil, nil
	header.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			dragStart = input.Position
			startPos = panel.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if
			dragging
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			local d = input.Position - dragStart
			panel.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + d.X,
				startPos.Y.Scale,
				startPos.Y.Offset + d.Y
			)
		end
	end)
end

----------------------------------------------------------------
-- Config (read straight from EZ.Flags so the UI is the single source of truth)
----------------------------------------------------------------

local EZ = nil

local DEFAULTS = {
	ShowMinimap = true,
	MapSize = 300,
	ZoomLevel = 50,
	Follow = true,
	TrueScale = true,
	MinDot = 2,
	ShowPlayers = true,
	ShowBots = true,
	ShowViruses = true,
	ShowPellets = false,
	ShowLabels = true,
	HideOverlappingLabels = true,
	ShowGrid = false,

	TracersEnabled = true,
	TrackAllPlayers = false,
	TrackAllBots = false,
	NearestBots = 0,
	TracerColor = Color3.fromRGB(255, 210, 80),
	Thickness = 2,
	MaxTracers = 20,
	ShowRing = true,
	ShowInfo = true,
	OriginMode = "Nearest cell",

	-- gameplay
	UnlimitedZoom = true,
	ZoomOut = 1,
	FeedEnabled = true,
	FeedRate = 30,
	FeedLatch = false,
}

local function F(id)
	local v = EZ and EZ.Flags[id]
	if v == nil then
		return DEFAULTS[id]
	end
	return v
end

-- ZoomLevel is a log slider: 50 = exactly the whole map, 1 = ~30x further out,
-- 100 = 32x in. Every 10 steps is a doubling, so the low end stays controllable.
local function zoomFactor()
	local step = math.clamp(tonumber(F("ZoomLevel")) or 50, 1, 100)
	return 2 ^ ((step - 50) / 10)
end

----------------------------------------------------------------
-- Target selection
----------------------------------------------------------------

local TargetState = {
	selectorHandle = nil,
	players = {}, -- [userId] = Player
	refreshedAt = 0,
	rosterKey = false,
}

local function playerRoster()
	local names = {}
	for _, p in Players:GetPlayers() do
		if p.UserId ~= LocalPlayer.UserId then
			names[#names + 1] = p.Name
		end
	end
	table.sort(names)
	return names
end

local function refreshSelectedPlayers()
	local names = playerRoster()
	local key = table.concat(names, "\1")
	if key ~= TargetState.rosterKey then
		TargetState.rosterKey = key
		local h = TargetState.selectorHandle
		if h then
			-- Refresh keeps the existing selection, so a join/leave does not wipe it
			pcall(function()
				h:Refresh(names)
			end)
		end
	end

	-- Multi dropdowns store a { [name] = true } map, so resolve names back to players
	local set = {}
	local sel = EZ and EZ.Flags.TrackPlayers
	if type(sel) == "table" then
		for name, on in sel do
			if on then
				local p = Players:FindFirstChild(name)
				if p and p.UserId ~= LocalPlayer.UserId then
					set[p.UserId] = p
				end
			end
		end
	elseif type(sel) == "string" then
		local p = Players:FindFirstChild(sel)
		if p and p.UserId ~= LocalPlayer.UserId then
			set[p.UserId] = p
		end
	end
	TargetState.players = set
	TargetState.refreshedAt = os.clock()
end

----------------------------------------------------------------
-- Snapshot view: one consistent read of the game's live state
----------------------------------------------------------------

local View = {
	cells = {}, -- array of {id, owner, x, y, mass}
	cellCount = 0,
	byOwner = {}, -- [owner] = {n = count, x, y, mass}  (mass-weighted)
	myCells = {},
	myCentroid = Vector2.new(MAP_SIZE / 2, MAP_SIZE / 2),
	myMass = 0,
	myMaxMass = 0,
	viruses = {},
	alive = false,
	snap = nil,
	scale = 1,
}

local function rebuildView()
	local g = State.game
	local r = State.render
	local snap = g.currSnap
	View.snap = snap

	table.clear(View.cells)
	table.clear(View.byOwner)
	table.clear(View.myCells)
	table.clear(View.viruses)
	View.cellCount = 0
	View.alive = false
	View.myMass = 0
	View.myMaxMass = 0

	if not snap then
		return
	end

	local cells = snap.cells
	local n = #cells.ids
	local draws = r._cellDraws
	local myId = g.myId
	local sumX, sumY = 0, 0

	for i = 1, n do
		local id, owner, x, y, mass
		local d = draws[i]
		if d and d.id == cells.ids[i] then
			id, owner, x, y, mass = d.id, d.owner, d.x, d.y, d.mass
		else
			id, owner, x, y, mass = cells.ids[i], cells.owners[i], cells.xs[i], cells.ys[i], cells.masses[i]
		end

		local cell = { id = id, owner = owner, x = x, y = y, mass = mass }
		View.cellCount = View.cellCount + 1
		View.cells[View.cellCount] = cell

		local agg = View.byOwner[owner]
		if not agg then
			agg = { owner = owner, n = 0, mass = 0, x = 0, y = 0 }
			View.byOwner[owner] = agg
		end
		agg.n = agg.n + 1
		agg.mass = agg.mass + mass
		agg.x = agg.x + x * mass
		agg.y = agg.y + y * mass

		if owner == myId then
			View.myCells[#View.myCells + 1] = cell
			View.myMass = View.myMass + mass
			if mass > View.myMaxMass then
				View.myMaxMass = mass
			end
			sumX = sumX + x * mass
			sumY = sumY + y * mass
		end
	end

	for _, agg in View.byOwner do
		if agg.mass > 0 then
			agg.x = agg.x / agg.mass
			agg.y = agg.y / agg.mass
		end
	end

	if View.myMass > 0 then
		View.alive = true
		View.myCentroid = Vector2.new(sumX / View.myMass, sumY / View.myMass)
	elseif View.cellCount > 0 then
		-- dead / spectating: keep a sane centre so the map does not jump
		View.myCentroid = Vector2.new(MAP_SIZE / 2, MAP_SIZE / 2)
	end

	local viruses = snap.viruses
	if viruses then
		for i = 1, #viruses.ids do
			View.viruses[i] = {
				id = viruses.ids[i],
				x = viruses.xs[i],
				y = viruses.ys[i],
				mass = viruses.masses[i],
			}
		end
	end

	local cam = r._camera
	View.scale = cam.scale
end

local function entityOf(owner)
	local g = State.game
	return g.entities[owner]
end

local function entityName(owner)
	local e = entityOf(owner)
	if e and type(e.name) == "string" then
		return e.name
	end
	if owner == State.game.myId then
		return LocalPlayer.Name
	end
	return "?"
end

----------------------------------------------------------------
-- Tracked targets (shared by the minimap highlight and the tracers)
----------------------------------------------------------------

local TracerState = {
	trackedOwners = {},
	targets = {},
	lines = {},
	rings = {},
	labels = {},
	lastCount = 0,
}

----------------------------------------------------------------
-- Minimap
----------------------------------------------------------------

local MapState = {
	cellFrames = {},
	cellRings = {},
	virusFrames = {},
	pelletFrames = {},
	gridFrames = {},
	labels = {},
	scratch = {}, -- per-drawn-cell record reused by the label pass
	placed = {}, -- label rectangles already committed this frame
	order = {}, -- label ordering scratch
	center = Vector2.new(MAP_SIZE / 2, MAP_SIZE / 2),
	viewSize = MAP_SIZE,
	scale = 1,
	collapsed = false,
}

local MAP_PAD = 6
local MAP_HEADER_H = 22

local function layoutPanel(w)
	local panel = Overlay.mapPanel
	local map = UI.map
	if MapState.collapsed then
		map.Visible = false
		UI.collapseBtn.Text = "+"
		panel.Size = UDim2.fromOffset(w, MAP_HEADER_H)
	else
		map.Visible = true
		UI.collapseBtn.Text = "–"
		local side = w - MAP_PAD * 2
		map.Size = UDim2.fromOffset(side, side)
		panel.Size = UDim2.fromOffset(w, MAP_HEADER_H + side + MAP_PAD)
	end
end

UI.collapseBtn.MouseButton1Click:Connect(function()
	MapState.collapsed = not MapState.collapsed
	layoutPanel(Overlay.mapPanel.AbsoluteSize.X)
end)

local function updateMinimap()
	local panel = Overlay.mapPanel
	panel.Visible = F("ShowMinimap") ~= false
	if not panel.Visible then
		return
	end

	local desired = math.clamp(math.floor(tonumber(F("MapSize")) or 300), 150, 600)
	if math.abs(panel.AbsoluteSize.X - desired) > 0.5 then
		layoutPanel(desired)
	end

	if MapState.collapsed then
		return
	end

	local map = UI.map
	local side = map.AbsoluteSize.X
	if side < 8 then
		return
	end

	local zoom = zoomFactor()
	local viewSize = MAP_SIZE / zoom
	MapState.viewSize = viewSize
	local scale = side / viewSize
	MapState.scale = scale

	-- centre: follow my blob, clamped so the window never leaves the map
	local cx, cy
	if F("Follow") and View.alive then
		cx, cy = View.myCentroid.X, View.myCentroid.Y
	else
		cx, cy = MapState.center.X, MapState.center.Y
	end
	if viewSize >= MAP_SIZE then
		cx, cy = MAP_SIZE / 2, MAP_SIZE / 2
	else
		local half = viewSize / 2
		cx = math.clamp(cx, half, MAP_SIZE - half)
		cy = math.clamp(cy, half, MAP_SIZE - half)
	end
	MapState.center = Vector2.new(cx, cy)

	local halfSide = side / 2
	local minDot = math.clamp(tonumber(F("MinDot")) or 2, 0, 12)
	local trueScale = F("TrueScale") ~= false
	local showLabels = F("ShowLabels") ~= false
	local myId = State.game.myId

	local function toMap(x, y)
		return (x - cx) * scale + halfSide, (y - cy) * scale + halfSide
	end

	local function sizeFor(mass)
		local r = massToRadius(mass) * scale
		if trueScale then
			r = math.max(r, minDot / 2)
		else
			r = math.max(math.min(r, 40), minDot / 2)
		end
		return r * 2
	end

	local function onScreen(px, py, pad)
		pad = pad or 48
		return px >= -pad and px <= side + pad and py >= -pad and py <= side + pad
	end

	-- grid ---------------------------------------------------------------
	do
		local want = F("ShowGrid") and true or false
		local lines = MapState.gridFrames
		local used = 0
		if want then
			local step = viewSize / 8
			local startGX = math.floor((cx - halfSide / scale) / step) * step
			for gx = startGX, cx + halfSide / scale, step do
				local px = (gx - cx) * scale + halfSide
				used = used + 1
				local line = lines[used]
				if not line then
					line = make("Frame", {
						BackgroundColor3 = Color3.fromRGB(90, 100, 130),
						BackgroundTransparency = 0.78,
						BorderSizePixel = 0,
						ZIndex = 1,
						Parent = UI.layers.grid,
					})
					lines[used] = line
				end
				line.Visible = true
				line.Size = UDim2.fromOffset(1, side)
				line.Position = UDim2.fromOffset(math.floor(px), 0)
			end
			local startGY = math.floor((cy - halfSide / scale) / step) * step
			for gy = startGY, cy + halfSide / scale, step do
				local py = (gy - cy) * scale + halfSide
				used = used + 1
				local line = lines[used]
				if not line then
					line = make("Frame", {
						BackgroundColor3 = Color3.fromRGB(90, 100, 130),
						BackgroundTransparency = 0.78,
						BorderSizePixel = 0,
						ZIndex = 1,
						Parent = UI.layers.grid,
					})
					lines[used] = line
				end
				line.Visible = true
				line.Size = UDim2.fromOffset(side, 1)
				line.Position = UDim2.fromOffset(0, math.floor(py))
			end
		end
		for i = used + 1, #lines do
			lines[i].Visible = false
		end
	end

	-- world edge ---------------------------------------------------------
	do
		local bx, by = toMap(MAP_SIZE / 2, MAP_SIZE / 2)
		local boundsSize = math.floor(MAP_SIZE * scale)
		local b = UI.mapBounds
		b.Size = UDim2.fromOffset(boundsSize, boundsSize)
		b.Position = UDim2.fromOffset(math.floor(bx), math.floor(by))
	end

	-- pellets ------------------------------------------------------------
	do
		local show = F("ShowPellets") and true or false
		local frames = MapState.pelletFrames
		local used = 0
		if show then
			local pelletR = math.max(PELLET_VISUAL_RADIUS * scale, 1)
			for id, p in State.game.pellets do
				if used >= 1400 then
					break
				end
				local px, py = toMap(p.x, p.y)
				if onScreen(px, py, 4) then
					used = used + 1
					local f = frames[used]
					if not f then
						f = make("Frame", {
							BorderSizePixel = 0,
							AnchorPoint = Vector2.new(0.5, 0.5),
							BackgroundTransparency = 0.45,
							ZIndex = 2,
							Parent = UI.layers.pellets,
						})
						frames[used] = f
					end
					f.Visible = true
					f.Size = UDim2.fromOffset(pelletR * 2, pelletR * 2)
					f.Position = UDim2.fromOffset(math.floor(px), math.floor(py))
					f.BackgroundColor3 = paletteColor(p.colorIndex)
					f.BackgroundTransparency = 0.45
				end
			end
		end
		for i = used + 1, #frames do
			frames[i].Visible = false
		end
	end

	-- viruses ------------------------------------------------------------
	do
		local show = F("ShowViruses") and true or false
		local frames = MapState.virusFrames
		local used = 0
		if show then
			for i, v in View.viruses do
				local px, py = toMap(v.x, v.y)
				local d = math.max(sizeFor(v.mass), 3)
				if onScreen(px, py, d) then
					used = used + 1
					local f = frames[used]
					if not f then
						f = makeCircle(UI.layers.viruses, 3)
						frames[used] = f
					end
					f.Visible = true
					f.BackgroundColor3 = Color3.fromRGB(51, 219, 51)
					f.Size = UDim2.fromOffset(d, d)
					f.Position = UDim2.fromOffset(math.floor(px), math.floor(py))
				end
			end
		end
		for i = used + 1, #frames do
			frames[i].Visible = false
		end
	end

	-- cells --------------------------------------------------------------
	local showPlayers = F("ShowPlayers") ~= false
	local showBots = F("ShowBots") ~= false
	local tracked = TracerState.trackedOwners

	do
		local frames = MapState.cellFrames
		local rings = MapState.cellRings
		local labels = MapState.labels
		local scratch = MapState.scratch
		local usedCells, usedRings, usedLabels = 0, 0, 0

		for i = 1, View.cellCount do
			local cell = View.cells[i]
			local owner = cell.owner
			local ent = entityOf(owner)
			local isBot = ent and ent.isBot and true or false
			local isMe = owner == myId
			local isTracked = tracked[owner] and true or false

			if isMe or isTracked or (isBot and showBots) or ((not isBot) and showPlayers) then
				local px, py = toMap(cell.x, cell.y)
				local d = sizeFor(cell.mass)
				if onScreen(px, py, d + 40) then
					usedCells = usedCells + 1
					local f = frames[usedCells]
					if not f then
						f = makeCircle(UI.layers.cells, 4)
						frames[usedCells] = f
					end
					f.Visible = true
					f.Size = UDim2.fromOffset(d, d)
					f.Position = UDim2.fromOffset(math.floor(px), math.floor(py))
					local col = paletteColor(ent and ent.colorIndex)
					if isBot and not isMe then
						col = col:Lerp(Color3.new(0, 0, 0), 0.45)
					end
					f.BackgroundColor3 = col
					f.BackgroundTransparency = isMe and 0.2 or 0
					f.ZIndex = isMe and 7 or (isTracked and 6 or 4)

					if isMe or isTracked then
						usedRings = usedRings + 1
						local ring = rings[usedRings]
						if not ring then
							ring = makeRing(UI.layers.cells, 8)
							rings[usedRings] = ring
						end
						ring.Visible = true
						ring.Size = UDim2.fromOffset(math.max(d + 3, 6), math.max(d + 3, 6))
						ring.Position = UDim2.fromOffset(math.floor(px), math.floor(py))
						local stroke = ring:FindFirstChildOfClass("UIStroke")
						if stroke then
							stroke.Color = isMe and Color3.fromRGB(255, 255, 255) or paletteColor(0)
							stroke.Thickness = isMe and 2 or 1.5
						end
						ring.ZIndex = isMe and 9 or 8
					end

					-- remember the draw so the label pass can reuse it
					local s = scratch[usedCells]
					if not s then
						s = {}
						scratch[usedCells] = s
					end
					s.name = entityName(owner)
					s.mass = cell.mass
					s.px = px
					s.py = py
					s.d = d
					s.isMe = isMe
					s.isTracked = isTracked
					s.color = isMe and Color3.fromRGB(255, 255, 255)
						or (isTracked and Color3.fromRGB(255, 225, 130) or Color3.fromRGB(170, 180, 200))
				end
			end
		end

		-- labels: every drawn blob, yours and tracked ones first so they win
		-- the overlap cull, then the rest by whatever room is left.
		-- A blob with room for two readable lines gets the text centred inside it,
		-- the way the game itself draws it; anything smaller falls back to a
		-- single line beside the dot.
		if showLabels then
			local avoid = F("HideOverlappingLabels") ~= false
			local placed = MapState.placed
			table.clear(placed)

			local function tryLabel(i)
				local s = scratch[i]
				if not s then
					return
				end
				local massText = tostring(math.floor(s.mass))
				local maxLen = math.max(#s.name, #massText)
				local ts = math.min(
					(s.d * 0.8) / math.max(maxLen * 0.62, 1),
					(s.d * 0.8) / 2.4
				)

				local text, x0, x1, y0, y1
				local centred = ts >= 6
				if centred then
					-- centred inside the blob
					ts = math.min(ts, 22)
					text = s.name .. "\n" .. massText
					local w = maxLen * ts * 0.66 + 4
					local h = 2.4 * ts + 4
					x0, x1 = s.px - w / 2, s.px + w / 2
					y0, y1 = s.py - h / 2, s.py + h / 2
				else
					-- beside the blob
					ts = 10
					text = s.name .. " " .. massText
					local w = #text * 5.8 + 4
					x0 = s.px + s.d / 2 + 3
					x1 = x0 + w
					y0, y1 = s.py - 6, s.py + 6
				end

				if avoid then
					for _, r in placed do
						if x0 < r[2] and r[1] < x1 and y0 < r[4] and r[3] < y1 then
							return
						end
					end
				end
				placed[#placed + 1] = { x0, x1, y0, y1 }

				usedLabels = usedLabels + 1
				local lbl = labels[usedLabels]
				if not lbl then
					lbl = makeLabel(UI.layers.labels, 10)
					labels[usedLabels] = lbl
				end
				lbl.Visible = true
				if lbl.Text ~= text then
					lbl.Text = text
				end
				lbl.TextColor3 = s.color
				lbl.TextSize = ts
				lbl.TextXAlignment = centred and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left
				lbl.Size = UDim2.fromOffset(x1 - x0, y1 - y0)
				lbl.Position = UDim2.fromOffset(math.floor(x0), math.floor((y0 + y1) / 2))
				local stroke = lbl:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke.Thickness = math.max(1, ts * 0.12)
				end
			end

			-- yours and tracked targets always get first claim on space
			for i = 1, usedCells do
				local s = scratch[i]
				if s and (s.isMe or s.isTracked) then
					tryLabel(i)
				end
			end

			-- then everyone else, biggest blob first, so a large cell keeps its
			-- centred label instead of losing it to a neighbour's side label
			local order = MapState.order
			local n = 0
			for i = 1, usedCells do
				local s = scratch[i]
				if s and not (s.isMe or s.isTracked) then
					n = n + 1
					order[n] = i
				end
			end
			for i = n + 1, #order do
				order[i] = nil
			end
			table.sort(order, function(a, b)
				return scratch[a].d > scratch[b].d
			end)
			for i = 1, n do
				tryLabel(order[i])
			end
		end

		for i = usedCells + 1, #frames do
			frames[i].Visible = false
		end
		for i = usedRings + 1, #rings do
			rings[i].Visible = false
		end
		for i = usedLabels + 1, #labels do
			labels[i].Visible = false
		end
	end

	-- header readout
	local function fmtWorld(n)
		if n >= 1000 then
			return string.format("%.1fk", n / 1000)
		end
		return string.format("%.0f", n)
	end
	local zoomText = zoom <= 1.001 and "whole map" or ("view " .. fmtWorld(viewSize) .. "u")
	local status
	if not View.alive then
		status = "dead · " .. zoomText
	else
		status = string.format("%d mass · %d cell%s · %s", math.floor(View.myMass),
			#View.myCells, #View.myCells == 1 and "" or "s", zoomText)
	end
	UI.headerLabel.Text = status
end

----------------------------------------------------------------
-- Tracers
----------------------------------------------------------------

local function collectTargets()
	local g = State.game
	local myId = g.myId
	local want = {}

	if F("TracersEnabled") == false then
		table.clear(TracerState.trackedOwners)
		TracerState.targets = {}
		TracerState.lastCount = 0
		return {}
	end

	if F("TrackAllPlayers") then
		for _, p in Players:GetPlayers() do
			if p.UserId ~= myId then
				want[p.UserId] = true
			end
		end
	end

	for userId in TargetState.players do
		if userId ~= myId then
			want[userId] = true
		end
	end

	if F("TrackAllBots") then
		for owner in View.byOwner do
			local e = entityOf(owner)
			if e and e.isBot then
				want[owner] = true
			end
		end
	end

	local nearest = math.clamp(math.floor(tonumber(F("NearestBots")) or 0), 0, 60)
	if nearest > 0 then
		local bots = {}
		for owner, agg in View.byOwner do
			local e = entityOf(owner)
			if e and e.isBot then
				local d = (Vector2.new(agg.x, agg.y) - View.myCentroid).Magnitude
				bots[#bots + 1] = { owner = owner, d = d }
			end
		end
		table.sort(bots, function(a, b)
			return a.d < b.d
		end)
		for i = 1, math.min(nearest, #bots) do
			want[bots[i].owner] = true
		end
	end

	-- resolve to targets, nearest first. A split owner gets one tracer anchored to
	-- whichever of their cells is closest to us, so the line and ring land on a real blob.
	local rep = {}
	for i = 1, View.cellCount do
		local c = View.cells[i]
		if want[c.owner] then
			local d = (Vector2.new(c.x, c.y) - View.myCentroid).Magnitude
			local cur = rep[c.owner]
			if not cur or d < cur.d then
				rep[c.owner] = { cell = c, d = d }
			end
		end
	end

	local list = {}
	for owner, r in rep do
		local agg = View.byOwner[owner]
		if agg then
			list[#list + 1] = {
				owner = owner,
				agg = agg,
				cell = r.cell,
				d = r.d,
			}
		end
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)

	local cap = math.clamp(math.floor(tonumber(F("MaxTracers")) or 20), 1, 80)
	while #list > cap do
		table.remove(list)
	end

	table.clear(TracerState.trackedOwners)
	for _, t in list do
		TracerState.trackedOwners[t.owner] = true
	end
	TracerState.targets = list
	TracerState.lastCount = #list
	return list
end

local function nearestMyCell(x, y)
	local best, bestD
	for _, c in View.myCells do
		local dx, dy = c.x - x, c.y - y
		local d = dx * dx + dy * dy
		if not bestD or d < bestD then
			best, bestD = c, d
		end
	end
	return best
end

local function updateTracers()
	local layer = Overlay.worldLayer
	local enabled = F("TracersEnabled") ~= false and View.alive

	local targets = TracerState.targets

	local origin, scale = cameraTransform()
	local color = F("TracerColor") or DEFAULTS.TracerColor
	local thickness = math.clamp(tonumber(F("Thickness")) or 2, 1, 6)
	local showRing = F("ShowRing") ~= false
	local showInfo = F("ShowInfo") ~= false
	local originMode = F("OriginMode") or DEFAULTS.OriginMode

	local usedLines, usedRings, usedLabels = 0, 0, 0

	if enabled and #targets > 0 then
		for _, t in targets do
			local agg = t.agg
			local cell = t.cell
			local tgt = Vector2.new(cell.x, cell.y)

			local fromWorld
			if originMode == "Screen center" then
				fromWorld = nil
			elseif originMode == "Centroid" then
				fromWorld = View.myCentroid
			else
				local c = nearestMyCell(tgt.X, tgt.Y)
				fromWorld = c and Vector2.new(c.x, c.y) or View.myCentroid
			end

			local to = origin + tgt * scale
			local from
			if fromWorld then
				from = origin + fromWorld * scale
			else
				from = Overlay.gui.AbsoluteSize * 0.5
			end

			usedLines = usedLines + 1
			local line = TracerState.lines[usedLines]
			if not line then
				line = make("Frame", {
					BackgroundColor3 = color,
					BorderSizePixel = 0,
					AnchorPoint = Vector2.new(0, 0.5),
					ZIndex = 2,
					Parent = layer,
				})
				TracerState.lines[usedLines] = line
			end
			local d = to - from
			local len = d.Magnitude
			line.Visible = true
			line.BackgroundColor3 = color
			line.Size = UDim2.fromOffset(math.max(len, 1), thickness)
			line.Position = UDim2.fromOffset(math.floor(from.X), math.floor(from.Y))
			line.Rotation = math.deg(math.atan2(d.Y, d.X))

			local dia = massToRadius(cell.mass) * 2 * scale
			if showRing and dia >= 3 then
				usedRings = usedRings + 1
				local ring = TracerState.rings[usedRings]
				if not ring then
					ring = makeRing(layer, 3)
					TracerState.rings[usedRings] = ring
				end
				ring.Visible = true
				ring.Size = UDim2.fromOffset(dia, dia)
				ring.Position = UDim2.fromOffset(math.floor(to.X), math.floor(to.Y))
				local stroke = ring:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke.Color = color
					stroke.Thickness = 2
				end
			end

			if showInfo then
				usedLabels = usedLabels + 1
				local lbl = TracerState.labels[usedLabels]
				if not lbl then
					lbl = makeLabel(layer, 4)
					TracerState.labels[usedLabels] = lbl
				end
				local ent = entityOf(t.owner)
				local name = entityName(t.owner)
				if ent and ent.isBot then
					name = name .. " [bot]"
				end
				lbl.Visible = true
				local massText = math.floor(cell.mass)
				if agg.n > 1 then
					massText = string.format("%d/%d", math.floor(cell.mass), math.floor(agg.mass))
				end
				lbl.Text = string.format("%s  %s  %.0fm", name, massText, t.d)
				lbl.TextColor3 = color
				lbl.Position = UDim2.fromOffset(math.floor(to.X + math.max(dia, 6) / 2 + 4), math.floor(to.Y))
			end
		end
	end

	for i = usedLines + 1, #TracerState.lines do
		TracerState.lines[i].Visible = false
	end
	for i = usedRings + 1, #TracerState.rings do
		TracerState.rings[i].Visible = false
	end
	for i = usedLabels + 1, #TracerState.labels do
		TracerState.labels[i].Visible = false
	end
end

----------------------------------------------------------------
-- Gameplay: unlimited camera zoom-out
----------------------------------------------------------------

-- The renderer rebuilds _camera.scale every frame in _updateCamera and clamps the
-- wheel zoom to [_zoomFloor, CAMERA_MAX_ZOOM] (0.5 .. 2). Wrapping that call and
-- scaling its result is the only way past the floor short of re-implementing the
-- whole camera function.
--
-- _updateCamera smooths _camera.scale toward a target each frame, so the value we
-- hand back is stashed and restored before the next call. Without that, our
-- multiplier feeds back into the game's own lerp and the zoom drifts away from
-- whatever the slider says.
local Camera = {
	render = nil,
	original = nil,
	slider = nil,
	level = 1, -- what we are applying right now (chased, not snapped)
	patched = false,
	holdOut = false,
	holdIn = false,
	stepAccum = 0,
}

local ZOOM_OUT_STEP = 17.5 -- slider units per doubling of the zoom-out factor

local function zoomOutMultiplier()
	local v = math.clamp(tonumber(F("ZoomOut")) or 1, 1, 100)
	return 2 ^ (-(v - 1) / ZOOM_OUT_STEP)
end

local function applyCameraZoom(self)
	local mult = Camera.level
	local cam = self._camera
	if mult >= 0.999 or not self._world or not self._worldScale then
		return
	end
	cam._cfPrev = cam.scale
	cam.scale = cam.scale * mult

	-- _updateCamera already positioned the world from the unscaled value, so redo it
	local vpX = math.max(cam.viewport.X, 1)
	local vpY = math.max(cam.viewport.Y, 1)
	self._world.Position = UDim2.fromScale(
		(vpX / 2 - cam.x * cam.scale) / vpX,
		(vpY / 2 - cam.y * cam.scale) / vpY
	)
	self._worldScale.Scale = cam.scale / 8
end

local function cameraWrapper(self, dt, draws, count)
	local cam = self._camera
	if cam and cam._cfPrev then
		cam.scale = cam._cfPrev
		cam._cfPrev = nil
	end
	Camera.original(self, dt, draws, count)
	pcall(applyCameraZoom, self)
end

local function patchCamera()
	local r = State.render
	if not r or Camera.patched then
		return
	end
	local orig = r._updateCamera
	if type(orig) ~= "function" then
		return
	end
	Camera.render = r
	Camera.original = orig
	r._updateCamera = cameraWrapper
	Camera.patched = true
end

local function unpatchCamera()
	local r = Camera.render
	if r and Camera.original and r._updateCamera == cameraWrapper then
		r._updateCamera = Camera.original
		local cam = r._camera
		if cam and cam._cfPrev then
			cam.scale = cam._cfPrev
			cam._cfPrev = nil
		end
	end
	Camera.patched = false
end

local function updateCameraZoom(dt)
	-- hold-to-ramp keys nudge the slider, so there is only one source of truth
	if Camera.holdOut or Camera.holdIn then
		Camera.stepAccum = Camera.stepAccum + dt
		local step = 0
		while Camera.stepAccum >= 0.05 do
			Camera.stepAccum = Camera.stepAccum - 0.05
			step = step + ((Camera.holdOut and 1) or 0) - ((Camera.holdIn and 1) or 0)
		end
		if step ~= 0 and Camera.slider then
			local cur = math.clamp(tonumber(F("ZoomOut")) or 1, 1, 100)
			pcall(function()
				Camera.slider:Set(math.clamp(cur + step, 1, 100), true)
			end)
		end
	end

	local target = zoomOutMultiplier()
	if F("UnlimitedZoom") == false then
		target = 1
	end
	if math.abs(Camera.level - target) < 0.0015 then
		Camera.level = target
	else
		Camera.level = Camera.level + (target - Camera.level) * (1 - math.exp(-dt * 14))
	end
end

----------------------------------------------------------------
-- Gameplay: fast feed
----------------------------------------------------------------

-- GameController:eject() fires the "eject" remote straight through Networker with
-- no client-side cooldown, and the game's own feed key only manages ~8/s
-- (task.wait(0.12) in InputController.startEjecting). Everything else - the mass
-- cost, the 35-mass floor, whether a request is honoured at all - is the server's
-- call, so this just raises the request rate and lets the server arbitrate.
local Feed = {
	active = false,
	accum = 0,
	fired = 0,
}

local function updateFeed(dt)
	local g = State.game
	if not Feed.active or F("FeedEnabled") == false or not g or not g.alive then
		Feed.accum = 0
		return
	end

	local rate = math.clamp(tonumber(F("FeedRate")) or 30, 1, 120)
	local interval = 1 / rate
	Feed.accum = Feed.accum + dt

	-- cap per frame so a hitch cannot dump a burst of ejects all at once
	local budget = 0
	while Feed.accum >= interval and budget < 4 do
		Feed.accum = Feed.accum - interval
		budget = budget + 1
		Feed.fired = Feed.fired + 1
		g:eject()
	end
	if budget >= 4 then
		Feed.accum = 0
	end
end

----------------------------------------------------------------
-- UI
----------------------------------------------------------------

local Log = {
	lines = {},
	handle = nil,
}

local function log(kind, text)
	Log.lines[#Log.lines + 1] = ("[%s] %s"):format(kind, text)
	if #Log.lines > 40 then
		table.remove(Log.lines, 1)
	end
	if Log.handle then
		pcall(function()
			if kind == "error" then
				Log.handle:Error(text)
			elseif kind == "warn" then
				Log.handle:Warn(text)
			else
				Log.handle:Info(text)
			end
		end)
	end
	print(("[CellFinder %s] %s"):format(kind, text))
end

local Handles = {}

local function buildUI()
	local ok, lib = pcall(function()
		return loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Library.lua"))()
	end)
	if not ok or type(lib) ~= "table" then
		return nil, tostring(lib)
	end
	EZ = lib

	local Window = EZ:CreateWindow({
		Title = "Cellular Finder",
		SubTitle = "minimap + tracers",
		Width = 600,
		Height = 470,
		ToggleKey = Enum.KeyCode.RightShift,
	})

	-- Minimap tab ------------------------------------------------------
	local tabMap = Window:AddTab("Minimap", "map")
	local secPanel = tabMap:AddSection("Panel")
	secPanel:AddToggle("ShowMinimap", {
		Text = "Show minimap",
		Default = DEFAULTS.ShowMinimap,
		Tooltip = "Draggable panel. Header shows your mass and the current scale.",
		Callback = function()
			layoutPanel(Overlay.mapPanel.AbsoluteSize.X)
		end,
	})
	secPanel:AddSlider("MapSize", {
		Text = "Panel size",
		Min = 150,
		Max = 600,
		Increment = 10,
		Suffix = " px",
		Default = DEFAULTS.MapSize,
	})
	secPanel:AddSlider("ZoomLevel", {
		Text = "Zoom",
		Min = 1,
		Max = 100,
		Increment = 1,
		Default = DEFAULTS.ZoomLevel,
		Display = function(v)
			local z = 2 ^ ((v - 50) / 10)
			if math.abs(z - 1) < 0.005 then
				return "whole map"
			elseif z < 1 then
				return string.format("%.0f%% of map", z * 100)
			end
			return string.format("%.1fx", z)
		end,
		Tooltip = "50 = the whole 11000x11000 map at 1:1. Drag left to zoom out past the map, right to zoom in.",
	})
	secPanel:AddToggle("Follow", {
		Text = "Follow my blob(s)",
		Default = DEFAULTS.Follow,
		Tooltip = "Off = the view stays where it is; use it to park the map on a quadrant.",
	})
	secPanel:AddToggle("TrueScale", {
		Text = "True blob size",
		Default = DEFAULTS.TrueScale,
		Tooltip = "Draw every blob at its real radius relative to the map. The minimum dot size below still applies.",
	})
	secPanel:AddSlider("MinDot", {
		Text = "Minimum dot size",
		Min = 0,
		Max = 12,
		Increment = 1,
		Suffix = " px",
		Default = DEFAULTS.MinDot,
		Tooltip = "Keeps tiny blobs visible. Set to 0 for a strictly exact scale.",
	})
	secPanel:AddButton({
		Text = "Reset panel position",
		Callback = function()
			Overlay.mapPanel.Position = UDim2.fromOffset(24, 150)
		end,
	})

	local secLayers = tabMap:AddSection("Layers")
	secLayers:AddToggle("ShowPlayers", { Text = "Show real players", Default = DEFAULTS.ShowPlayers })
	secLayers:AddToggle("ShowBots", { Text = "Show bots", Default = DEFAULTS.ShowBots })
	secLayers:AddToggle("ShowViruses", { Text = "Show viruses", Default = DEFAULTS.ShowViruses })
	secLayers:AddToggle("ShowPellets", {
		Text = "Show mass dots",
		Default = DEFAULTS.ShowPellets,
		Tooltip = "Only pellets the client already knows about. Heavy at low zoom.",
	})
	secLayers:AddToggle("ShowLabels", {
		Text = "Name + mass labels",
		Default = DEFAULTS.ShowLabels,
		Tooltip = "Labels every blob the map is drawing.",
	})
	secLayers:AddToggle("HideOverlappingLabels", {
		Text = "Hide labels that collide",
		Default = DEFAULTS.HideOverlappingLabels,
		VisibleWhen = "ShowLabels",
		Tooltip = "~100 blobs on a 300px map means labels pile up. This keeps the ones that fit, yours and tracked first. Turn off to force every label.",
	})
	secLayers:AddToggle("ShowGrid", { Text = "Show grid", Default = DEFAULTS.ShowGrid })

	-- Tracers tab ------------------------------------------------------
	local tabTrace = Window:AddTab("Tracers", "crosshair")
	local secTargets = tabTrace:AddSection("Targets")

	-- AddDropdown rather than AddPlayerSelector: the selector wrapper does not
	-- forward Searchable, and with a full server the list needs a search box
	Handles.selector = secTargets:AddDropdown("TrackPlayers", {
		Text = "Teammates to trace",
		Multi = true,
		Searchable = true,
		Values = playerRoster(),
		VisibleItems = 10,
		AllowEmptySelection = true,
		Tooltip = "Search by name. Refreshes as players join and leave.",
		Callback = function()
			refreshSelectedPlayers()
		end,
	})
	refreshSelectedPlayers()

	secTargets:AddToggle("TrackAllPlayers", {
		Text = "Trace every real player",
		Default = DEFAULTS.TrackAllPlayers,
	})
	secTargets:AddToggle("TrackAllBots", {
		Text = "Trace every bot",
		Default = DEFAULTS.TrackAllBots,
		Tooltip = "This server runs ~85 bots, so pair it with the tracer cap.",
	})
	secTargets:AddSlider("NearestBots", {
		Text = "Also trace nearest bots",
		Min = 0,
		Max = 40,
		Increment = 1,
		Default = DEFAULTS.NearestBots,
	})
	Handles.targetsLabel = secTargets:AddLabel({ Text = "Tracking 0 targets", DoesWrap = true })

	local secStyle = tabTrace:AddSection("Style")
	Handles.tracersToggle = secStyle:AddToggle("TracersEnabled", {
		Text = "Tracers enabled",
		Default = DEFAULTS.TracersEnabled,
	})
	secStyle:AddDropdown("OriginMode", {
		Text = "Line origin",
		Values = { "Nearest cell", "Centroid", "Screen center" },
		Default = DEFAULTS.OriginMode,
		Tooltip = "Nearest cell keeps each line tied to whichever of your blobs is closest.",
	})
	secStyle:AddColorPicker("TracerColor", {
		Text = "Tracer colour",
		Default = DEFAULTS.TracerColor,
	})
	secStyle:AddSlider("Thickness", {
		Text = "Line thickness",
		Min = 1,
		Max = 6,
		Increment = 1,
		Suffix = " px",
		Default = DEFAULTS.Thickness,
	})
	secStyle:AddSlider("MaxTracers", {
		Text = "Max tracers",
		Min = 1,
		Max = 80,
		Increment = 1,
		Default = DEFAULTS.MaxTracers,
		Tooltip = "Closest targets win. Keep it modest for frame rate.",
	})
	secStyle:AddToggle("ShowRing", {
		Text = "Ring around targets",
		Default = DEFAULTS.ShowRing,
		Tooltip = "Matches the target's real on-screen size.",
	})
	secStyle:AddToggle("ShowInfo", {
		Text = "Name / mass / distance",
		Default = DEFAULTS.ShowInfo,
	})
	Handles.traceKey = secStyle:AddKeybind("ToggleTracersKey", {
		Mode = "Toggle",
		-- EnumItem, not "J": the library's string path resolves through an enum
		-- index that throws, so a string default silently lands on "None"
		Default = Enum.KeyCode.J,
		Text = "Toggle tracers",
		Callback = function(active)
			if Handles.tracersToggle then
				Handles.tracersToggle:Set(active and true or false)
			end
		end,
	})

	-- Gameplay tab ------------------------------------------------------
	local tabPlay = Window:AddTab("Gameplay", "gamepad-2")

	local secCam = tabPlay:AddSection("Camera zoom")
	secCam:AddToggle("UnlimitedZoom", {
		Text = "Unlimited zoom out",
		Default = DEFAULTS.UnlimitedZoom,
		Tooltip = "Lets the camera pull back past the game's own floor (0.5x). Your mouse wheel still works normally on top of this.",
	})
	Camera.slider = secCam:AddSlider("ZoomOut", {
		Text = "Zoom out",
		Min = 1,
		Max = 100,
		Increment = 1,
		Default = DEFAULTS.ZoomOut,
		Display = function(v)
			if v <= 1 then
				return "game default"
			end
			return string.format("%.1fx out", 2 ^ ((v - 1) / ZOOM_OUT_STEP))
		end,
		Tooltip = "How far past the game's limit the camera may pull back. ~10x is already the whole map on screen.",
	})
	Handles.zoomOutKey = secCam:AddKeybind("ZoomOutKey", {
		Mode = "Hold",
		Default = Enum.KeyCode.LeftBracket,
		Text = "Hold to zoom out",
		Callback = function(active)
			Camera.holdOut = active
		end,
	})
	Handles.zoomInKey = secCam:AddKeybind("ZoomInKey", {
		Mode = "Hold",
		Default = Enum.KeyCode.RightBracket,
		Text = "Hold to zoom in",
		Callback = function(active)
			Camera.holdIn = active
		end,
	})
	secCam:AddButton({
		Text = "Reset camera zoom",
		Callback = function()
			Camera.holdOut, Camera.holdIn = false, false
			if Camera.slider then
				Camera.slider:Set(1)
			end
		end,
	})

	local secFeed = tabPlay:AddSection("Fast feed")
	secFeed:AddToggle("FeedEnabled", {
		Text = "Fast feed enabled",
		Default = DEFAULTS.FeedEnabled,
	})
	secFeed:AddSlider("FeedRate", {
		Text = "Ejects per second",
		Min = 5,
		Max = 120,
		Increment = 5,
		Default = DEFAULTS.FeedRate,
		Tooltip = "The game's own feed key runs at ~8/s. 18 mass leaves per eject, so 60/s drains ~1080 mass a second.",
	})
	Handles.feedKey = secFeed:AddKeybind("FeedKey", {
		Mode = "Hold",
		Default = Enum.KeyCode.F,
		Text = "Fast feed",
		Callback = function(active)
			if F("FeedLatch") then
				if active then
					Feed.active = not Feed.active
				end
			else
				Feed.active = active
			end
		end,
	})
	secFeed:AddToggle("FeedLatch", {
		Text = "Latch the feed key",
		Default = DEFAULTS.FeedLatch,
		Tooltip = "On = tap to start and tap to stop. Off = feed only while the key is held.",
	})
	Handles.feedStatus = secFeed:AddLabel({ Text = "idle" })

	-- Info tab ---------------------------------------------------------
	local tabInfo = Window:AddTab("Info", "info")
	local secStatus = tabInfo:AddSection("Live status")
	Handles.status = secStatus:AddParagraph({
		Title = "Status",
		Content = "Waiting for the game state...",
	})
	Handles.nearest = secStatus:AddLabel({ Text = "", DoesWrap = true })
	Handles.log = tabInfo:AddSection("Log"):AddLog({ MaxLines = 60, Height = 130 })
	Log.handle = Handles.log

	local secActions = tabInfo:AddSection("Actions")
	secActions:AddButton({
		Text = "Refresh player list",
		Callback = function()
			refreshSelectedPlayers()
		end,
	})
	secActions:AddButton({
		Text = "Clear tracked teammates",
		Callback = function()
			if Handles.selector then
				Handles.selector:Set({})
			end
			refreshSelectedPlayers()
		end,
	})

	layoutPanel(Overlay.mapPanel.AbsoluteSize.X)
	return Window
end

----------------------------------------------------------------
-- Loop
----------------------------------------------------------------

local lastUiTick = 0
local lastResolveCheck = 0
local errorCount = 0

local function updateInfoPanel()
	if not Handles.status then
		return
	end
	local g = State.game
	local ents = 0
	local bots = 0
	local real = 0
	for _, e in g.entities do
		ents = ents + 1
		if e.isBot then
			bots = bots + 1
		else
			real = real + 1
		end
	end

	pcall(function()
		Handles.status:Set(
			string.format(
				"alive: %s\nmy mass: %d  (%d cells, biggest %d)\nposition: %.0f, %.0f\nentities: %d  (%d players / %d bots)\ncells in view: %d\nviruses: %d\nscreen scale: %.3f",
				tostring(View.alive),
				math.floor(View.myMass),
				#View.myCells,
				math.floor(View.myMaxMass),
				View.myCentroid.X,
				View.myCentroid.Y,
				ents,
				real,
				bots,
				View.cellCount,
				#View.viruses,
				View.scale
			)
		)
	end)

	if Handles.targetsLabel then
		pcall(function()
			Handles.targetsLabel:Set(string.format("Tracking %d targets", TracerState.lastCount))
		end)
	end

	if Handles.feedStatus then
		local camText = Camera.level >= 0.999 and "default" or string.format("%.1fx out", 1 / Camera.level)
		local feedText = "idle"
		if Feed.active then
			feedText = string.format("FEEDING · %d ejects sent", Feed.fired)
		end
		pcall(function()
			Handles.feedStatus:Set(string.format("camera: %s   |   %s", camText, feedText))
		end)
	end

	local parts = {}
	for i = 1, math.min(6, #TracerState.targets) do
		local t = TracerState.targets[i]
		local ent = entityOf(t.owner)
		local tag = ent and ent.isBot and "bot" or "player"
		parts[#parts + 1] = string.format("%s (%s) %d mass · %dm", entityName(t.owner), tag, math.floor(t.cell.mass), t.d)
	end
	if Handles.nearest then
		pcall(function()
			Handles.nearest:Set(#parts > 0 and ("Nearest targets:\n" .. table.concat(parts, "\n")) or "No targets tracked.")
		end)
	end
end

local function step(dt)
	if os.clock() - lastResolveCheck > 1 then
		lastResolveCheck = os.clock()
		if not stateUsable() then
			State.game, State.render = nil, nil
			resolveState()
			if not State.game or not State.render then
				State.failStreak = State.failStreak + 1
			else
				State.failStreak = 0
			end
		else
			State.failStreak = 0
		end
	end

	if not State.game or not State.render or not stateUsable() then
		return
	end

	-- keep the camera wrapper on whichever renderer table is live
	if not Camera.patched or Camera.render ~= State.render then
		unpatchCamera()
		patchCamera()
	end

	rebuildView()
	collectTargets()

	if os.clock() - TargetState.refreshedAt > 0.25 then
		refreshSelectedPlayers()
	end

	updateCameraZoom(dt)
	updateFeed(dt)
	updateMinimap()
	updateTracers()

	if os.clock() - lastUiTick > 0.5 then
		lastUiTick = os.clock()
		updateInfoPanel()
	end
end

----------------------------------------------------------------
-- Boot
----------------------------------------------------------------

local window, err = buildUI()
if not window then
	log("error", "EZ-UI failed to load: " .. tostring(err))
	return
end

do
	local ok, cfg = pcall(function()
		local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
		local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
		SaveManager:Bind(EZ, "CellularFinderConfigs")
		return SaveManager
	end)
	if ok and cfg then
		pcall(function()
			cfg:LoadAutoloadConfig()
		end)
	end
end

local conn = RunService.RenderStepped:Connect(function(dt)
	local ok, e = pcall(step, dt)
	if not ok then
		errorCount = errorCount + 1
		if errorCount <= 3 then
			log("error", tostring(e))
		end
	end
end)

log("info", "loaded — " .. #View.cells .. " cells visible, " .. MAP_SIZE .. "x" .. MAP_SIZE .. " world")

genv.CellularFinder = {
	destroy = function()
		pcall(function()
			conn:Disconnect()
		end)
		pcall(function()
			Feed.active = false
			unpatchCamera()
		end)
		pcall(function()
			if Overlay.gui then
				Overlay.gui:Destroy()
			end
		end)
		pcall(function()
			if EZ then
				EZ:Destroy()
			end
		end)
		genv.CellularFinder = nil
	end,
	state = State,
	view = View,
	ez = EZ,
	camera = Camera,
	feed = Feed,
	flags = function()
		return EZ and EZ.Flags
	end,
}
