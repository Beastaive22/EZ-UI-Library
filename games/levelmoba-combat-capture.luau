-- Game guard: this module only runs in its own game.
-- game.GameId is the universe id (9410753415), so every place in that
-- game matches. Anywhere else (autoexec, a shared hub, a wrong map
-- entry) it exits before touching anything.
if game.GameId ~= 9410753415 then return end

-- Passive combat capture for LevelMoba. Read-only: forwards everything, stores payloads.
-- v2: NO namecall hook. Incoming remote listeners + enemy HP-diff watcher only.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local G = getgenv()
if G.LevelMobaCombatCapture and G.LevelMobaCombatCapture.unhook then
	pcall(G.LevelMobaCombatCapture.unhook)
end

local CAP_IN, CAP_HP = {}, {}
local MAX = 160

local function now()
	return os.clock()
end

local function compact(v, depth)
	depth = depth or 0
	if depth > 3 then return "..." end
	local t = typeof(v)
	if t == "Vector3" then return { __v3 = { v.X, v.Y, v.Z } }
	elseif t == "CFrame" then return { __cf = { v.X, v.Y, v.Z } }
	elseif t == "Instance" then return v:GetFullName()
	elseif t == "table" then
		local out = {}
		local n = 0
		for k, val in pairs(v) do
			n = n + 1
			if n > 24 then out.__more = true break end
			out[tostring(k)] = compact(val, depth + 1)
		end
		return out
	elseif t == "string" then
		if #v > 120 then return v:sub(1, 117) .. "..." end
		return v
	else
		return v
	end
end

local function push(list, entry)
	table.insert(list, entry)
	while #list > MAX do table.remove(list, 1) end
end

local IN_NAMES = {
	"FloatingText", "StatsSnapshot", "DamageStatsSnapshot", "ProjectileReplicate",
	"ProjectileAimLocked", "ReleaseAnticipatedProjectile", "PlayClientVfx", "PlayChainVfx",
	"ShowEnemyStatusModelVfx", "ShowClientIndicator", "CooldownAdjustment", "StructuresSync",
	"EnemyDespawnFade", "ShowClientToast", "SystemMessage", "AuraVfxEvent"
}
local conns = {}
for _, name in ipairs(IN_NAMES) do
	local ok, remote = pcall(function() return Remotes.GetRemoteEvent(RemoteNames[name]) end)
	if ok and remote then
		local c = remote.OnClientEvent:Connect(function(...)
			local args = table.pack(...)
			local packed = {}
			for i = 1, args.n do packed[i] = compact(args[i]) end
			push(CAP_IN, { t = now(), remote = name, args = packed })
		end)
		table.insert(conns, c)
	end
end

local known = {}
local hpConn = RunService.Heartbeat:Connect(function()
	local Enemies = workspace:FindFirstChild("Enemies")
	if not Enemies then return end
	for _, model in ipairs(Enemies:GetChildren()) do
		local rs = model:FindFirstChild("RuntimeState")
		if rs then
			local hp = rs:GetAttribute("HP")
			local k = known[model]
			if hp and k and k ~= hp then
				local d = {
					DamageAt = rs:GetAttribute("DamageAt"),
					DamageUser = rs:GetAttribute("DamageUser"),
					DamageEnemy = rs:GetAttribute("DamageEnemy"),
					DamageSource = rs:GetAttribute("DamageSource"),
					DamageType = rs:GetAttribute("DamageType"),
				}
				local ds = model:FindFirstChild("DamageState")
				if ds then
					for k2, v2 in pairs(ds:GetAttributes()) do
						if d[k2] == nil then d[k2] = v2 end
					end
				end
				push(CAP_HP, {
					t = now(), enemy = model.Name,
					hp = { from = k, to = hp }, delta = hp - k,
					maxHP = rs:GetAttribute("MaxHP"), dmg = d,
				})
			end
			known[model] = hp
		end
	end
	for m in pairs(known) do
		if not m.Parent then known[m] = nil end
	end
end)

G.LevelMobaCombatCapture = {
	get = function()
		return { in_ = CAP_IN, hp = CAP_HP }
	end,
	unhook = function()
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		pcall(function() hpConn:Disconnect() end)
		G.LevelMobaCombatCapture = nil
	end,
}
print("[capture v2] armed (no hooks): " .. #IN_NAMES .. " incoming remotes + HP watcher")