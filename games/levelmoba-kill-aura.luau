-- Game guard: this module only runs in its own game.
-- game.GameId is the universe id (9410753415), so every place in that
-- game matches. Anywhere else (autoexec, a shared hub, a wrong map
-- entry) it exits before touching anything.
if game.GameId ~= 9410753415 then return end

-- LevelMoba KillAura — MAX RATE mode: fires every Heartbeat, no client pacing.
-- Server remains authority (it lands what it accepts at its own cooldown clock).
-- Controls: getgenv().LevelMobaKillAura.SetEnabled(bool) | .SetInterval(sec) | .Stop() | RightControl toggles
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local cloneref = cloneref or function(x) return x end

local G = getgenv()
if G.LevelMobaKillAura and G.LevelMobaKillAura.Stop then
	pcall(G.LevelMobaKillAura.Stop)
end

local LocalPlayer = cloneref(Players.LocalPlayer)
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local DataRegistry = require(Shared:WaitForChild("Registry"):WaitForChild("DataRegistry"))
local CombatantAttributes = require(Shared:WaitForChild("Combat"):WaitForChild("CombatantAttributes"))
local LevelContext = require(Shared:WaitForChild("LevelContext"))
local CastRequest = Remotes.GetRemoteEvent(RemoteNames.AbilityCastRequest)

local state = {
	enabled = true,
	interval = 0, -- 0 = every Heartbeat
	nextFire = 0,
	abilityId = nil,
	abilityData = nil,
	equipCheckAt = 0,
	casts = 0,
}

local function resolveWeaponAbility()
	local ok, item = pcall(function()
		local InventoryClient = require(LocalPlayer.PlayerScripts.Client.Inventory.InventoryClient)
		local equip = InventoryClient.GetHeroEquipment()
		local weapon = equip and equip.weapon
		if not weapon then return nil end
		return DataRegistry.GetItems().items[weapon.id]
	end)
	if ok and item and item.attackAbilityId ~= "" then
		return item.attackAbilityId
	end
	return nil
end

local function refreshAbility()
	local id = resolveWeaponAbility()
	if id and id ~= state.abilityId then
		state.abilityId = id
		state.abilityData = DataRegistry.GetAbilityData(id)
		print("[KillAura] weapon ability ->", id)
	end
end

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
					if score < bestScore then
						bestScore, best = score, m
					end
				end
			end
		end
	end
	return best
end

local function fireCast(targetModel, sourcePos)
	local id = (tonumber(LocalPlayer:GetAttribute("ClientAbilityCastId")) or 0) + 1
	LocalPlayer:SetAttribute("ClientAbilityCastId", id)
	CastRequest:FireServer({
		castId = id,
		abilityId = state.abilityId,
		target = targetModel,
		targets = { targetModel },
		sourcePosition = sourcePos,
	})
	state.casts = state.casts + 1
end

local hbConn, inputConn
local function stop()
	if hbConn then pcall(function() hbConn:Disconnect() end) end
	if inputConn then pcall(function() inputConn:Disconnect() end) end
	G.LevelMobaKillAura = nil
	print("[KillAura] stopped after " .. state.casts .. " casts")
end

hbConn = RunService.Heartbeat:Connect(function()
	if not state.enabled then return end
	pcall(function()
		if os.clock() < state.nextFire then return end
		if LevelContext.IsHometown() then return end

		if os.clock() >= state.equipCheckAt then
			state.equipCheckAt = os.clock() + 3
			refreshAbility()
		end

		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp or not CombatantAttributes.CanAttack(ch, false) then return end

		local atk = state.abilityData and state.abilityData.attack
		if not atk or not state.abilityId then return end

		local target = pickTarget(atk.range or 60)
		if not target then return end

		fireCast(target, hrp.Position)

		if state.interval > 0 then
			state.nextFire = os.clock() + state.interval
		end
	end)
end)

inputConn = UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.RightControl then
		state.enabled = not state.enabled
		print("[KillAura] " .. (state.enabled and "ENABLED" or "PAUSED"))
	end
end)

refreshAbility()
G.LevelMobaKillAura = {
	SetEnabled = function(v) state.enabled = v == true end,
	IsEnabled = function() return state.enabled end,
	SetInterval = function(sec) state.interval = tonumber(sec) or 0; state.nextFire = 0 end,
	GetStats = function() return { casts = state.casts, abilityId = state.abilityId, interval = state.interval } end,
	Stop = stop,
}
print("[KillAura] MAX RATE armed: " .. tostring(state.abilityId) .. " | every Heartbeat | RightControl toggles | .Stop() unloads")