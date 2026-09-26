-- Game guard: this module only runs in its own game.
-- game.GameId is the universe id (9410753415), so every place in that
-- game matches. Anywhere else (autoexec, a shared hub, a wrong map
-- entry) it exits before touching anything.
if game.GameId ~= 9410753415 then return end

-- LevelMoba Aura Suite — attack aura + skill aura (all granted tracks on own cooldowns) + EZ UI
-- Server remains authority: damage/cooldowns/range validated server-side. This automates valid casts.
-- Controls: getgenv().LevelMobaAura.Stop() | UI: RightShift hide/show | RightControl master toggle
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local cloneref = cloneref or function(x) return x end

local G = getgenv()
if G.LevelMobaAura and G.LevelMobaAura.Stop then pcall(G.LevelMobaAura.Stop) end
if G.LevelMobaKillAura and G.LevelMobaKillAura.Stop then pcall(G.LevelMobaKillAura.Stop) end

local LocalPlayer = cloneref(Players.LocalPlayer)
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local DataRegistry = require(Shared:WaitForChild("Registry"):WaitForChild("DataRegistry"))
local StatApplier = require(Shared:WaitForChild("Stats"):WaitForChild("StatApplier"))
local StatsClient = require(Shared:WaitForChild("Stats"):WaitForChild("StatsClient"))
local CombatantAttributes = require(Shared:WaitForChild("Combat"):WaitForChild("CombatantAttributes"))
local LevelContext = require(Shared:WaitForChild("LevelContext"))
local EquipmentGrantResolver = require(Shared:WaitForChild("Items"):WaitForChild("EquipmentGrantResolver"))
local RunUpgradeResolver = require(Shared:WaitForChild("Gameplay"):WaitForChild("RunUpgradeResolver"))
local AbilityDataResolver = require(Shared:WaitForChild("Gameplay"):WaitForChild("Combat"):WaitForChild("AbilityDataResolver"))
local AbilityLevelResolver = require(Shared:WaitForChild("Gameplay"):WaitForChild("Abilities"):WaitForChild("AbilityLevelResolver"))
local PlayerAbilityUtils = require(game:GetService("StarterPlayer").StarterCharacterScripts:WaitForChild("gameplay"):WaitForChild("PlayerAbilityUtils"))
local RunStateClient = require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client"):WaitForChild("Run"):WaitForChild("RunStateClient"))
local InventoryClient = require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client"):WaitForChild("Inventory"):WaitForChild("InventoryClient"))

-- ============ flags (UI writes here; loop reads) ============
local Flags = {
	Master = true,
	AttackAura = true,
	SkillAura = true,
	PassiveAura = true,
	DashAura = false,
	Interval = 0, -- 0 = every heartbeat (max rate)
}

-- ============ EZ UI ============
local EZ, Window
local weaponLabel, tracksLabel, perfLabel
local combatLog
do
	local ok, result = pcall(function()
		return loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Library.lua"))()
	end)
	if ok and result then
		EZ = result
		Window = EZ:CreateWindow({
			Title = "LevelMoba Aura",
			SubTitle = "attack + skill automation",
			ToggleKey = Enum.KeyCode.RightShift,
		})

		local combatTab = Window:AddTab("Combat", "swords")
		local leftGB = combatTab:AddLeftGroupbox("Attack Aura", "zap")
		leftGB:AddToggle("AttackAura", { Text = "Weapon auto-cast", Default = true, Callback = function(v) Flags.AttackAura = v end })
		weaponLabel = leftGB:AddLabel("Weapon: ...")

		local rightGB = combatTab:AddRightGroupbox("Skill Aura", "sparkles")
		rightGB:AddToggle("SkillAura", { Text = "Skills auto-cast", Default = true, Callback = function(v) Flags.SkillAura = v end })
		rightGB:AddToggle("PassiveAura", { Text = "Passive procs auto-cast", Default = true, Callback = function(v) Flags.PassiveAura = v end })
		rightGB:AddToggle("DashAura", { Text = "Dash on cooldown", Default = false, Callback = function(v) Flags.DashAura = v end })
		tracksLabel = rightGB:AddLabel("Tracks: 0")

		local perfGB = combatTab:AddLeftGroupbox("Pacing", "gauge")
		perfGB:AddSlider("Interval", {
			Text = "Cast interval", Min = 0, Max = 2, Default = 0, Increment = 0.05, Suffix = "s",
			Tooltip = "0 = every heartbeat (max rate). ~0.65s blends in with legit traffic.",
			Callback = function(v) Flags.Interval = v end,
		})
		perfGB:AddToggle("Master", { Text = "Master enable", Default = true, Callback = function(v) Flags.Master = v end })

		local statusTab = Window:AddTab("Status", "activity")
		local logGB = statusTab:AddLeftGroupbox("Damage feed", "scroll-text")
		combatLog = logGB:AddLog({ Height = 200, MaxLines = 60 })
		perfLabel = logGB:AddLabel("Casts: 0 | Landed/min: 0")

		EZ:Notify({ Title = "LevelMoba Aura", Content = "Loaded. RightShift = UI, RightControl = master.", Duration = 4, Type = "success" })
	else
		warn("[Aura] EZ-UI failed to load — running headless (RightControl toggles master)")
	end
end

-- ============ landed-hit tracking (FloatingText) ============
local stats = { casts = 0, landed = 0, landedWindow = {} }
local hitConn = Remotes.GetRemoteEvent(RemoteNames.FloatingText).OnClientEvent:Connect(function(...)
	local args = table.pack(...)
	local entries = {}
	for i = 1, args.n do
		local a = args[i]
		if typeof(a) == "table" then
			if a.kind ~= nil then
				table.insert(entries, a)
			else
				for _, sub in pairs(a) do
					if typeof(sub) == "table" and sub.kind ~= nil then table.insert(entries, sub) end
				end
			end
		end
	end
	for _, text in ipairs(entries) do
		if text.kind ~= "damage" then continue end
		if text.soundPlayerUserId ~= nil and text.soundPlayerUserId ~= LocalPlayer.UserId then continue end
		stats.landed += 1
		table.insert(stats.landedWindow, os.clock())
		local cut = os.clock() - 60
		while #stats.landedWindow > 0 and stats.landedWindow[1] < cut do table.remove(stats.landedWindow, 1) end
		if combatLog then
			local enemyName = "enemy"
			pcall(function()
				if typeof(text.adornee) == "string" then
					enemyName = text.adornee:match("Enemies%.([^%.]+)") or enemyName
				end
			end)
			pcall(function() combatLog:Info(("%s  -%s"):format(enemyName, tostring(text.text))) end)
		end
	end
end)

-- ============ ability enumeration ============
local weaponAbility, weaponData = nil, nil
local skillTracks = {} -- abilityId -> {data=..., baseCooldown=..., nextFire=0, kind="skill"|"passive"}

local function resolveWeapon()
	local ok, abilityId = pcall(function()
		local equip = InventoryClient.GetHeroEquipment()
		local weapon = equip and equip.weapon
		if not weapon then return nil end
		return DataRegistry.GetItems().items[weapon.id].attackAbilityId
	end)
	if ok and abilityId and abilityId ~= "" and abilityId ~= weaponAbility then
		weaponAbility = abilityId
		weaponData = DataRegistry.GetAbilityData(abilityId)
	end
end

local function addTrack(list, abilityId, baseCooldown, kind)
	if not abilityId or abilityId == "" then return end
	if list[abilityId] then return end
	local ok, data = pcall(function() return DataRegistry.GetAbilityData(abilityId) end)
	if not ok or not data then return end
	list[abilityId] = {
		data = data,
		baseCooldown = baseCooldown or (data.attack and data.attack.cooldown) or 10,
		nextFire = 0,
		kind = kind,
	}
end

local function refreshTracks()
	resolveWeapon()
	local newList = {}
	pcall(function()
		for _, entry in ipairs(EquipmentGrantResolver.GetManualAbilityEntries(InventoryClient.GetHeroEquipment(), LocalPlayer)) do
			addTrack(newList, entry.abilityId, entry.baseCooldown, "skill")
		end
	end)
	pcall(function()
		for _, entry in ipairs(RunUpgradeResolver.GetManualAbilityEntries(RunStateClient.GetState())) do
			addTrack(newList, entry.abilityId, entry.baseCooldown, "skill")
		end
	end)
	if Flags.PassiveAura then
		pcall(function()
			local seen = {}
			local passives = DataRegistry.GetPassives().passives
			local function addPassives(ids)
				for _, pid in ipairs(ids) do
					if not seen[pid] then
						seen[pid] = true
						local passive = passives and passives[pid]
						if passive and typeof(passive.autoCastAbilityId) == "string" and passive.autoCastAbilityId ~= "" then
							addTrack(newList, passive.autoCastAbilityId, nil, "passive")
						end
					end
				end
			end
			addPassives(RunStateClient.GetPassiveIds())
			addPassives(EquipmentGrantResolver.GetPassiveIds(InventoryClient.GetHeroEquipment()))
		end)
	end
	skillTracks = newList
end

-- ============ targeting ============
local function pickTarget(range)
	local Enemies = workspace:FindFirstChild("Enemies")
	if not Enemies then return nil end
	local ch = LocalPlayer.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	local pos = hrp.Position
	local best, bestScore = nil, math.huge
	for _, m in ipairs(Enemies:GetChildren()) do
		if CombatantAttributes.IsTargetAllowed(m) and m:GetAttribute("IsDormant") ~= true then
			local rs = m:FindFirstChild("RuntimeState")
			local hp = rs and rs:GetAttribute("HP")
			local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
			if typeof(hp) == "number" and hp > 0 and root then
				local v = root.Position - pos
				local planar = math.sqrt(v.X * v.X + v.Z * v.Z)
				if planar <= range then
					local score = hp + planar * 0.25
					if score < bestScore then bestScore, best = score, m end
				end
			end
		end
	end
	return best
end

-- ============ cooldown math (mirrors the game) ============
local function getCooldown(track)
	local data = track.data
	if not data then return 1 end
	local okStats, statsTable = pcall(function() return StatsClient.GetStats() end)
	if data.abilityType == "attack" then
		local ok, result = pcall(function()
			local wc = StatApplier.GetWeaponCooldown(data.attack and data.attack.cooldown or track.baseCooldown, statsTable)
			local rate = StatApplier.GetAttackRate(1 / wc, statsTable)
			return rate > 0 and 1 / rate or wc
		end)
		if ok and typeof(result) == "number" then return result end
	else
		local ok, result = pcall(function()
			return StatApplier.GetAbilityCooldown(track.baseCooldown or 10, statsTable, data.abilityType)
		end)
		if ok and typeof(result) == "number" then return result end
	end
	return track.baseCooldown or 1
end

-- ============ casting ============
local function castTrack(track)
	local data = track.data
	if not data then return false end
	local level = 1
	pcall(function()
		level = AbilityLevelResolver.GetAbilityLevelForItem(RunStateClient.GetCoreLevel(), nil) or 1
	end)
	local atk = data.attack
	local cooldown = getCooldown(track)
	local opts = { abilityLevel = level }
	if atk then
		local count = atk.attackCount or atk.targetCount or 1
		pcall(function()
			opts.multiAttackDelay = AbilityDataResolver.GetMultiAttackDelay(atk, count, cooldown)
		end)
		if atk.requiresTarget then
			local target = pickTarget(atk.range or 30)
			if not target then return false end
			opts.target = target
		end
	end
	local ok, fired = pcall(function()
		return PlayerAbilityUtils.FireAbility(data, opts)
	end)
	stats.casts += 1
	return ok and fired == true
end

-- ============ main loop ============
local running = true
local hbConn, inputConn
local nextRefresh = 0
local attackNext = 0

hbConn = RunService.Heartbeat:Connect(function()
	if not Flags.Master then return end
	local ok, err = pcall(function()
		if LevelContext.IsHometown() then return end
		local now = os.clock()

		if now >= nextRefresh then
			nextRefresh = now + 3
			refreshTracks()
		end

		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp or not CombatantAttributes.CanAttack(ch, false) then return end

		-- attack track (weapon): pace to the server's own cooldown clock — flooding gets rate-locked
		if Flags.AttackAura and weaponData and weaponData.attack and now >= attackNext then
			local target = pickTarget(weaponData.attack.range or 60)
			if target then
				stats.casts += 1
				task.spawn(function()
					pcall(function() PlayerAbilityUtils.FireAbility(weaponData, { target = target }) end)
				end)
				attackNext = now + math.max(Flags.Interval, getCooldown({ data = weaponData, baseCooldown = weaponData.attack.cooldown }) * 0.98)
			end
		end

		-- skill tracks: fire when own cooldown frees; pace to real cooldown after success
		if Flags.SkillAura then
			for abilityId, track in pairs(skillTracks) do
				local data = track.data
				if data and now >= track.nextFire then
					if data.abilityType == "dash" and not Flags.DashAura then
						track.nextFire = now + 1
					else
						local fired = castTrack(track)
						if fired then
							track.nextFire = now + math.max(Flags.Interval, getCooldown(track) * 0.98)
						else
							-- failed (no target / rejected): back off, never flood
							track.nextFire = now + math.max(Flags.Interval, 0.5)
						end
					end
				end
			end
		end
	end)
	if not ok then
		-- avoid log spam: only surface once per second
		if os.clock() - (G._auraLastErrorAt or 0) > 1 then
			G._auraLastErrorAt = os.clock()
			warn("[Aura] loop error:", err)
		end
	end
end)

inputConn = UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.RightControl then
		Flags.Master = not Flags.Master
		if combatLog then pcall(function() combatLog:Print("master " .. (Flags.Master and "ON" or "OFF")) end) end
		print("[Aura] master:", Flags.Master)
	end
end)

-- ============ status updater ============
task.spawn(function()
	while running do
		task.wait(1)
		local cut = os.clock() - 60
		while #stats.landedWindow > 0 and stats.landedWindow[1] < cut do table.remove(stats.landedWindow, 1) end
		local tracks = 0
		for _ in pairs(skillTracks) do tracks += 1 end
		if weaponLabel then pcall(function() weaponLabel:Set("Weapon: " .. tostring(weaponAbility or "none")) end) end
		if tracksLabel then pcall(function() tracksLabel:Set("Tracks: " .. tracks) end) end
		if perfLabel then pcall(function() perfLabel:Set(("Casts: %d | Landed/min: %d"):format(stats.casts, #stats.landedWindow)) end) end
	end
end)

-- ============ lifecycle ============
local function stop()
	running = false
	pcall(function() hitConn:Disconnect() end)
	pcall(function() hbConn:Disconnect() end)
	pcall(function() inputConn:Disconnect() end)
	if Window then pcall(function() Window:Destroy() end) end
	G.LevelMobaAura = nil
	print("[Aura] stopped. casts:", stats.casts, "landed:", stats.landed)
end

G.LevelMobaAura = {
	Flags = Flags,
	GetStats = function()
		local tracks = 0
		for _ in pairs(skillTracks) do tracks += 1 end
		return { casts = stats.casts, landed = stats.landed, hitsPerMin = #stats.landedWindow, tracks = tracks, weapon = weaponAbility }
	end,
	Stop = stop,
}

refreshTracks()
local trackCount = 0
for _ in pairs(skillTracks) do trackCount += 1 end
print("[Aura] armed | weapon:", tostring(weaponAbility), "| tracks:", trackCount)