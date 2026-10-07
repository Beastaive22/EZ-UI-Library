-- Game guard: this module only runs in "MOO Survival" (universe 10769210355).
if game.GameId ~= 10769210355 then return end

--!nocheck
-- moo-survival.luau — MOO Survival aura suite (farm · heal · axe · spike).
-- Executor: Potassium / sUNC. Control surface: getgenv().MooAuras
--
-- SAFETY: everything replays the game's own client protocol. The server is
-- authoritative (harvest hits, placement validity, heals), so the auras only
-- ever send what a real client could send, at the real client's own rates:
--   axe swings  — HarvestHit:FireServer(LookVector), 0.46s gate (shared with
--                 manual clicks via a namecall hook — total rate can never
--                 exceed a legit client's max)
--   spike traps — ItemAction:FireServer("use", pivot) at 0.3s, gated on the
--                 real costs (20 wood + 5 stone) and the 20-spike limit; the
--                 server validates spots for free before charging resources
--   healing     — ItemAction:FireServer("quickheal") when HP < max and food >= 10
-- Never fire ReplicatedStorage.AdminCommand — admin-only honeypot (hard-gated
-- to UserId 442902764; the panel script returns early for everyone else).
--
-- Target filters (axe + spike): skip tribemates, dead players, GodMode admins.
-- Priority spike > axe > farm via render-step order (Camera+2 farm, Camera+3
-- combat); the axe aura suspends the farm aura while engaged.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local G = getgenv()
-- take over any standalone instances from earlier sessions
pcall(function() if G.MooFarmAura and G.MooFarmAura.Unload then G.MooFarmAura.Unload() end end)
pcall(function() if G.MooCombatAuras and G.MooCombatAuras.Unload then G.MooCombatAuras.Unload() end end)
pcall(function() if G.MooAuras and G.MooAuras.Unload then G.MooAuras.Unload() end end)
G.MooEngineGen = (G.MooEngineGen or 0) + 1
local engineGen = G.MooEngineGen
-- a previous run may have died mid-build leaving its render steps bound
pcall(function() RunService:UnbindFromRenderStep("MooFarmAura") end)
pcall(function() RunService:UnbindFromRenderStep("MooCombatAuras") end)

local HarvestHit = ReplicatedStorage:WaitForChild("HarvestHit")
local ItemAction = ReplicatedStorage:WaitForChild("ItemAction")
local ResourceGeometry = require(ReplicatedStorage:WaitForChild("ResourceGeometry"))
local SwingAnimator = require(ReplicatedStorage:WaitForChild("SwingAnimator"))
local Predict = require(ReplicatedStorage:WaitForChild("Predict"))
local EquipClient = require(ReplicatedStorage:WaitForChild("EquipClient"))

local TribeWorld = workspace:WaitForChild("TribeWorld")
local ResourceNodes = TribeWorld:WaitForChild("ResourceNodes")

local SWING_GATE = 0.46
local HEAL_GATE = 0.6
local SPIKE_GATE = 0.3
local EQUIP_GATE = 0.4
local SPIKE_WOOD = 20
local SPIKE_STONE = 5
local SPIKE_LIMIT = 20
local SPIKE_REACH = 3.8
local HIT_RANGE = 7.5
local MAX_Y_DROP = 8
local CONE_DOT = 0.2
local PROXIMITY_EXTRA = 10
local MAX_CANDIDATES = 24

local cfg = {
	farm = false,
	heal = true,
	axe = false,
	spike = false,
	spikeMode = "reach",
	axeRange = 7.5,
	spikeRange = 5,
}

local stats = { swings = 0, heals = 0, spikes = 0 }
local suspended = false
local lastHarvestFire, lastHeal, lastSpike, lastEquip = 0, 0, 0, 0
local aimDir, hadTargets = nil, false
local axeTarget, spikeTarget = nil, nil
local hadAxe, hadSpike = false, false
local gateActive, gateOwner = false, false
local uiAlive = true
local connections = {}

---------------------------------------------------------------- farm aura --

local nodeCache = {}

local function captureNode(inst)
	if inst:GetAttribute("Resource") then
		nodeCache[#nodeCache + 1] = {
			inst = inst,
			radius = inst:GetAttribute("HarvestRadius") or 5,
			pos = inst:GetPivot().Position,
		}
	end
end

for _, inst in ipairs(ResourceNodes:GetChildren()) do
	captureNode(inst)
end

table.insert(connections, ResourceNodes.ChildAdded:Connect(function(inst)
	task.delay(0.5, function()
		if inst.Parent == ResourceNodes then
			captureNode(inst)
		end
	end)
end))

table.insert(connections, ResourceNodes.ChildRemoved:Connect(function(inst)
	for i = 1, #nodeCache do
		if nodeCache[i].inst == inst then
			nodeCache[i] = nodeCache[#nodeCache]
			nodeCache[#nodeCache] = nil
			break
		end
	end
end))

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function refreshExclude()
	rayParams.FilterDescendantsInstances = {
		LocalPlayer.Character,
		ResourceNodes,
		TribeWorld:FindFirstChild("CentralGoldRock"),
	}
end

table.insert(connections, LocalPlayer.CharacterAdded:Connect(function()
	task.defer(refreshExclude)
end))
refreshExclude()

local function qualifies(entry, hrpPos, dir)
	if entry.inst.Parent == nil then
		return false, nil
	end
	if (entry.pos - hrpPos).Magnitude >= entry.radius + PROXIMITY_EXTRA then
		return false, nil
	end
	local ok, closest = pcall(ResourceGeometry.Closest, entry.inst, hrpPos)
	if not ok or typeof(closest) ~= "Vector3" then
		return false, nil
	end
	local to = closest - hrpPos
	local flat = Vector3.new(to.X, 0, to.Z)
	local flatMag = flat.Magnitude
	if flatMag > HIT_RANGE or math.abs(to.Y) >= MAX_Y_DROP then
		return false, nil
	end
	if flatMag >= 1.5 and dir and dir:Dot(flat.Unit) < CONE_DOT then
		return false, nil
	end
	if workspace:Raycast(hrpPos, to, rayParams) then
		return false, nil
	end
	return true, (flatMag >= 1.5 and flat.Unit or nil)
end

local function scan(hrpPos, dir)
	local list = {}
	for i = 1, #nodeCache do
		local hit, flatDir = qualifies(nodeCache[i], hrpPos, dir)
		if hit then
			list[#list + 1] = flatDir
		end
	end
	return list
end

local function bestDirection(list, hrp)
	if #list == 0 then
		return nil
	end
	local sum = Vector3.zero
	local anyDir = false
	for i = 1, #list do
		if list[i] then
			sum = sum + list[i]
			anyDir = true
		end
	end
	local candidates = {}
	if anyDir and sum.Magnitude > 0.01 then
		candidates[#candidates + 1] = sum.Unit
	end
	for i = 1, #list do
		if list[i] and #candidates < MAX_CANDIDATES then
			candidates[#candidates + 1] = list[i]
		end
	end
	if #candidates == 0 then
		local look = hrp.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.01 then
			return flat.Unit
		end
		return Vector3.zAxis
	end
	local bestDir, bestCount = nil, -1
	for i = 1, #candidates do
		local dir = candidates[i]
		local count = 0
		for j = 1, #list do
			if not list[j] or dir:Dot(list[j]) >= CONE_DOT then
				count = count + 1
			end
		end
		if count > bestCount then
			bestCount = count
			bestDir = dir
		end
	end
	return bestDir
end

------------------------------------------------------------- combat auras --

local function alive()
	local c = LocalPlayer.Character
	if not c then
		return nil
	end
	local h = c:FindFirstChildOfClass("Humanoid")
	local r = c:FindFirstChild("HumanoidRootPart")
	if not (h and r) or h.Health <= 0 then
		return nil
	end
	return c, h, r
end

local function sameTribe(p)
	local mine = LocalPlayer:GetAttribute("Tribe")
	return mine ~= nil and p:GetAttribute("Tribe") == mine
end

local function validTarget(p)
	if p == LocalPlayer or sameTribe(p) then
		return false
	end
	if p:GetAttribute("IsDead") == true or p:GetAttribute("GodMode") == true then
		return false
	end
	local c = p.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local r = c and c:FindFirstChild("HumanoidRootPart")
	return (c and h and r) ~= nil and h.Health > 0
end

local function distanceTo(p, myPos)
	local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
	return r and (r.Position - myPos).Magnitude or math.huge
end

local function pickTarget(current, acquireRange, keepRange)
	local c, _, r = alive()
	if not c then
		return nil
	end
	if current and validTarget(current) and distanceTo(current, r.Position) <= keepRange then
		return current
	end
	local best, bestDist = nil, acquireRange
	for _, p in ipairs(Players:GetPlayers()) do
		if validTarget(p) then
			local d = distanceTo(p, r.Position)
			if d <= bestDist then
				best, bestDist = p, d
			end
		end
	end
	return best
end

local function faceAt(hrp, pos)
	local delta = pos - hrp.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < 0.05 then
		return nil
	end
	hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + flat.Unit)
	return flat.Unit
end

local function spikePivot(hrp, hum)
	return hrp.CFrame * CFrame.new(0, -(hum.HipHeight + hrp.Size.Y / 2), -(SPIKE_REACH * LocalPlayer.Character:GetScale()))
end

local function spikeAffordable()
	return (LocalPlayer:GetAttribute("Wood") or 0) >= SPIKE_WOOD
		and (LocalPlayer:GetAttribute("Stone") or 0) >= SPIKE_STONE
		and (LocalPlayer:GetAttribute("PlacedSpike") or 0) < SPIKE_LIMIT
end

local function equip(slot, now)
	if now - lastEquip >= EQUIP_GATE then
		EquipClient.select(slot, true)
		lastEquip = now
	end
end

local function farmSuspend(on)
	suspended = on == true
	if suspended then
		aimDir = nil
		hadTargets = false
	end
end

------------------------------------------------------------------- steps --

local function farmStep()
	local character = LocalPlayer.Character
	if not cfg.farm or suspended or not character then
		aimDir = nil
		hadTargets = false
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not (hrp and hum) or hum.Health <= 0 then
		return
	end
	if LocalPlayer:GetAttribute("IsDead") or LocalPlayer:GetAttribute("StructureModalOpen") then
		aimDir = nil
		hadTargets = false
		return
	end
	if (LocalPlayer:GetAttribute("EquippedSlot") or 1) ~= 1 then
		aimDir = nil
		hadTargets = false
		return
	end

	local now = os.clock()
	local hrpPos = hrp.Position

	if now - lastHarvestFire >= SWING_GATE then
		local list = scan(hrpPos, nil)
		if #list == 0 then
			aimDir = nil
			hadTargets = false
			return
		end
		local dir = bestDirection(list, hrp)
		if not dir then
			return
		end
		aimDir = dir
		hadTargets = true
		hrp.CFrame = CFrame.lookAt(hrpPos, hrpPos + dir)
		HarvestHit:FireServer(hrp.CFrame.LookVector)
		SwingAnimator.Play(character)
		Predict.swing(hrp, dir)
		lastHarvestFire = os.clock()
		stats.swings = stats.swings + 1
	elseif hadTargets and aimDir then
		hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + aimDir)
	end
end

local function combatStep()
	if not (cfg.axe or cfg.spike) then
		return
	end
	local c, h, r = alive()
	if not c or LocalPlayer:GetAttribute("StructureModalOpen") then
		return
	end
	local now = os.clock()

	if cfg.spike and spikeAffordable() then
		spikeTarget = pickTarget(spikeTarget, cfg.spikeRange, cfg.spikeRange + 1)
		if spikeTarget then
			hadSpike = true
			local trp = spikeTarget.Character.HumanoidRootPart
			faceAt(r, trp.Position)
			if (LocalPlayer:GetAttribute("EquippedSlot") or 1) ~= 3 then
				equip(3, now)
			elseif now - lastSpike >= SPIKE_GATE then
				local pivot
				if cfg.spikeMode == "direct" then
					pivot = CFrame.new(trp.Position - Vector3.new(0, trp.Size.Y / 2, 0))
				else
					pivot = spikePivot(r, h)
				end
				Predict.place(3, pivot)
				ItemAction:FireServer("use", pivot)
				lastSpike = now
				stats.spikes = stats.spikes + 1
			end
			return
		end
	end
	if hadSpike then
		hadSpike = false
		spikeTarget = nil
		if (LocalPlayer:GetAttribute("EquippedSlot") or 1) == 3 then
			equip(1, now)
		end
	end

	if cfg.axe then
		axeTarget = pickTarget(axeTarget, cfg.axeRange, cfg.axeRange + 1)
		if axeTarget then
			if not hadAxe then
				hadAxe = true
				farmSuspend(true)
			end
			local trp = axeTarget.Character.HumanoidRootPart
			local dir = faceAt(r, trp.Position)
			if dir and (LocalPlayer:GetAttribute("EquippedSlot") or 1) == 1 and now - lastHarvestFire >= SWING_GATE then
				HarvestHit:FireServer(r.CFrame.LookVector)
				SwingAnimator.Play(c)
				Predict.swing(r, dir)
				lastHarvestFire = now
				stats.swings = stats.swings + 1
			end
			return
		end
	end
	if hadAxe then
		hadAxe = false
		axeTarget = nil
		farmSuspend(false)
	end
end

RunService:BindToRenderStep("MooFarmAura", Enum.RenderPriority.Camera.Value + 2, farmStep)
RunService:BindToRenderStep("MooCombatAuras", Enum.RenderPriority.Camera.Value + 3, combatStep)

task.spawn(function()
	while uiAlive and engineGen == G.MooEngineGen do
		task.wait(0.2)
		if cfg.heal then
			local c, h = alive()
			if c and h and h.Health < h.MaxHealth and (LocalPlayer:GetAttribute("Food") or 0) >= 10 then
				local now = os.clock()
				if now - lastHeal >= HEAL_GATE then
					ItemAction:FireServer("quickheal")
					lastHeal = now
					stats.heals = stats.heals + 1
				end
			end
		end
	end
end)

if not G.MooHarvestGate then
	pcall(function()
		local original
		original = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			if gateActive and self == HarvestHit and getnamecallmethod() == "FireServer" then
				local now = os.clock()
				if now - lastHarvestFire < SWING_GATE then
					return nil
				end
				lastHarvestFire = now
			end
			return original(self, ...)
		end))
		if typeof(original) == "function" then
			gateActive = true
			gateOwner = true
			G.MooHarvestGate = true
		end
	end)
end

local function setState(key, on)
	if key == "farm" then
		cfg.farm = on == true
		if cfg.farm then
			if (LocalPlayer:GetAttribute("EquippedSlot") or 1) ~= 1 then
				EquipClient.select(1, true)
			end
		end
	elseif key == "heal" then
		cfg.heal = on == true
	elseif key == "axe" then
		cfg.axe = on == true
		if not cfg.axe then
			farmSuspend(false)
		end
	elseif key == "spike" then
		cfg.spike = on == true
	end
end

local function unloadEngine()
	uiAlive = false
	farmSuspend(false)
	pcall(function()
		RunService:UnbindFromRenderStep("MooFarmAura")
	end)
	pcall(function()
		RunService:UnbindFromRenderStep("MooCombatAuras")
	end)
	for i = 1, #connections do
		pcall(function()
			connections[i]:Disconnect()
		end)
	end
	table.clear(connections)
	gateActive = false
	if gateOwner then
		G.MooHarvestGate = nil
	end
	G.MooAuras = nil
end

-- engine-only fallback handle: a re-run (or the hub loader) can always stop
-- the engine even if the UI half never finished building
G.MooAuras = { Unload = function() unloadEngine() end }

-------------------------------------------------------------- EZ window --

local REPO = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local okLib, EZ = pcall(function()
	return loadstring(game:HttpGet(REPO .. "Library.lua"))()
end)
if not okLib or not EZ then
	warn("[MooSurvival] EZ UI Library failed to load: " .. tostring(EZ))
	return
end

local okIcons, Icons = pcall(function()
	return loadstring(game:HttpGet(REPO .. "addons/Icons.lua"))()
end)
if okIcons and Icons then
	EZ:SetIcons(Icons)
end

local okSave, SaveManager = pcall(function()
	return loadstring(game:HttpGet(REPO .. "addons/SaveManager.lua"))()
end)
local okTheme, ThemeManager = pcall(function()
	return loadstring(game:HttpGet(REPO .. "addons/ThemeManager.lua"))()
end)
local okQuick, QuickBar = pcall(function()
	return loadstring(game:HttpGet(REPO .. "addons/QuickBar.lua"))()
end)
local okNotif, NotifHistory = pcall(function()
	return loadstring(game:HttpGet(REPO .. "addons/NotificationHistory.lua"))()
end)

if okSave and SaveManager then
	SaveManager:Bind(EZ, "MooSurvivalConfigs")
end
if okTheme and ThemeManager then
	ThemeManager:Bind(EZ, { File = "MooSurvival_Theme.txt" })
	ThemeManager:LoadSaved()
	for name, tbl in EZ.Themes do
		ThemeManager:AddTheme(name, tbl)
	end
end

local Window = EZ:CreateWindow({
	Title = "MOO Survival",
	SubTitle = "farm · heal · combat",
	ToggleIcon = "wheat",
	GeometryId = "moo-survival",
})
if okQuick and QuickBar then
	QuickBar:Bind(EZ, Window)
end
if okNotif and NotifHistory then
	NotifHistory:Bind(EZ, Window)
end

local Tab = Window:AddTab("Auras", "zap")
local InfoTab = Window:AddTab("Reference", "info")

local statusSection = Tab:AddSection("Live status", "server resources + aura counters, refreshes every 0.4s")
local labelVitals = statusSection:AddLabel({ Text = "HP — · Food —" })
local labelRes = statusSection:AddLabel({ Text = "Wood — · Stone — · Gold —" })
local labelAction = statusSection:AddLabel({ Text = "Swings 0 · Heals 0 · Spikes 0" })

local left = Tab:AddLeftGroupbox("Farming", "wheat")
local right = Tab:AddRightGroupbox("Combat", "swords")

local farmToggle = left:AddToggle("FarmAura", {
	Text = "Farm aura",
	Description = "auto-faces the densest node cluster and swings at the client's own 0.46s cadence",
	Default = true,
	Callback = function(v)
		setState("farm", v)
	end,
	Tooltip = "auto-equips the axe; pauses while an axe/spike target is engaged",
})
left:AddKeybind("FarmKey", {
	Mode = "Toggle",
	Default = Enum.KeyCode.G,
	Text = "Farm aura key",
	Callback = function(active)
		farmToggle:Set(active)
	end,
})

local healToggle = right:AddToggle("AutoHeal", {
	Text = "Auto heal",
	Description = "fires quickheal whenever HP drops and food >= 10",
	Default = true,
	Callback = function(v)
		setState("heal", v)
	end,
})
local axeToggle = right:AddToggle("AxeAura", {
	Text = "Axe aura",
	Description = "faces the nearest valid player in range and swings (20 dmg/hit)",
	Default = false,
	Callback = function(v)
		setState("axe", v)
	end,
	Tooltip = "skips tribemates, dead players and GodMode admins",
})
right:AddSlider("AxeRange", {
	Text = "Axe engage range",
	Min = 3,
	Max = 12,
	Increment = 0.5,
	Default = 7.5,
	Suffix = " studs",
	Callback = function(v)
		cfg.axeRange = v
	end,
})
local spikeToggle = right:AddToggle("SpikeAura", {
	Text = "Spike aura",
	Description = "engages nearby players and places 45-damage spikes at them",
	Default = false,
	Callback = function(v)
		setState("spike", v)
	end,
	Tooltip = "needs 20 wood + 5 stone per spike, limit 20 placed",
})
right:AddDropdown("SpikeMode", {
	Text = "Spike placement",
	Values = { "reach", "direct" },
	Default = "reach",
	Callback = function(v)
		cfg.spikeMode = v
	end,
	Tooltip = "reach = 3.8 studs ahead of you (authentic) · direct = right at the target",
})
right:AddSlider("SpikeRange", {
	Text = "Spike engage range",
	Min = 2,
	Max = 8,
	Increment = 0.5,
	Default = 5,
	Suffix = " studs",
	Callback = function(v)
		cfg.spikeRange = v
	end,
})
right:AddKeybind("HealKey", {
	Mode = "Toggle",
	Default = Enum.KeyCode.H,
	Text = "Auto heal key",
	Callback = function(active)
		healToggle:Set(active)
	end,
})
right:AddKeybind("AxeKey", {
	Mode = "Toggle",
	Default = Enum.KeyCode.J,
	Text = "Axe aura key",
	Callback = function(active)
		axeToggle:Set(active)
	end,
})
right:AddKeybind("SpikeKey", {
	Mode = "Toggle",
	Default = Enum.KeyCode.K,
	Text = "Spike aura key",
	Callback = function(active)
		spikeToggle:Set(active)
	end,
})

local toggleHandles = { farm = farmToggle, heal = healToggle, axe = axeToggle, spike = spikeToggle }

local refSection = InfoTab:AddSection("Safety notes")
refSection:AddParagraph({
	Title = "How the auras stay safe",
	Content = "The server re-validates everything, so the auras only replay the exact client protocol at the exact client rates.\n\nAxe swing = HarvestHit(LookVector), 0.46s gate shared with your own clicks via a namecall hook — total swing rate can never exceed a legit client.\n\nSpike = ItemAction('use', pivot) gated on the real costs (20 wood + 5 stone, limit 20). The server validates spots for free before charging resources.\n\nHeal = ItemAction('quickheal') when HP < max and food >= 10.\n\nAxe = 20 dmg/hit · spike contact = 45 dmg · player HP 100.",
})
refSection:AddParagraph({
	Title = "Never touch",
	Content = "ReplicatedStorage.AdminCommand is an admin-only honeypot (hard-gated to UserId 442902764). Firing it as a normal player is an instant flag.\n\nAnti-cheat is server-side: speed and no-clip are compared against your expected movement — these auras never touch WalkSpeed, position, or hitboxes.",
})

if okQuick and QuickBar then
	QuickBar:Pin("FarmAura", { Icon = "wheat" })
	QuickBar:Pin("AutoHeal", { Icon = "heart-pulse" })
	QuickBar:Pin("AxeAura", { Icon = "axe" })
	QuickBar:Pin("SpikeAura", { Icon = "skull" })
end

-- keybind toggles + configs drive the engine through these handles
local function syncFromUI()
	setState("farm", toggleHandles.farm:Get())
	setState("heal", toggleHandles.heal:Get())
	setState("axe", toggleHandles.axe:Get())
	setState("spike", toggleHandles.spike:Get())
end

EZ:OnDestroy(function()
	unloadEngine()
	pcall(function()
		if QuickBar then
			QuickBar:Destroy()
		end
	end)
	pcall(function()
		if NotifHistory then
			NotifHistory:Destroy()
		end
	end)
end)

task.spawn(function()
	while uiAlive and engineGen == G.MooEngineGen do
		task.wait(0.4)
		local c = LocalPlayer.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		labelVitals:Set(string.format(
			"HP %s/%s · Food %s",
			h and math.floor(h.Health) or "—",
			h and math.floor(h.MaxHealth) or "—",
			tostring(LocalPlayer:GetAttribute("Food") or 0)
		))
		labelRes:Set(string.format(
			"Wood %s · Stone %s · Gold %s",
			tostring(LocalPlayer:GetAttribute("Wood") or 0),
			tostring(LocalPlayer:GetAttribute("Stone") or 0),
			tostring(LocalPlayer:GetAttribute("Gold") or 0)
		))
		labelAction:Set(string.format(
			"Swings %d · Heals %d · Spikes %d · Score %s",
			stats.swings, stats.heals, stats.spikes,
			tostring(LocalPlayer:GetAttribute("Score") or 0)
		))
	end
end)

if okSave and SaveManager then
	SaveManager:LoadAutoloadConfig()
end
-- saved configs restore via handles (callbacks fire); this sync also covers
-- the no-config case where Default=true never fired the callback
syncFromUI()

G.MooAuras = {
	Window = Window,
	EZ = EZ,
	Set = setState,
	Toggle = function(key)
		local handle = toggleHandles[key]
		if handle then
			handle:Set(not handle:Get())
		end
	end,
	State = function()
		return {
			farm = cfg.farm, heal = cfg.heal, axe = cfg.axe, spike = cfg.spike,
			spikeMode = cfg.spikeMode, axeRange = cfg.axeRange, spikeRange = cfg.spikeRange,
		}
	end,
	Stats = function()
		return stats
	end,
	Unload = function()
		EZ:Destroy()
	end,
}

EZ:Notify({
	Title = "MOO Survival",
	Content = "Farm aura + auto heal armed · axe (J) / spike (K) in the Auras tab",
	Type = "success",
	Duration = 6,
})

print("[MooSurvival] loaded — EZ window via RightShift")