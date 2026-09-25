-- Game guard: this bot only runs inside Total Conquest.
-- GameId 10591363798 — lobby "[medal] Total Conquest [Beta]" = 131530256182298,
-- War match place = 121112783648487. Anywhere else (other games via autoexec):
-- exit silently before touching anything.
if game.GameId ~= 10591363798 and game.PlaceId ~= 131530256182298 and game.PlaceId ~= 121112783648487 then
	return
end

--[[
	Total Conquest Autoplay (sUNC / Potassium)
	- Claims neutral nodes, punishes weak neighbors, defends borders, upgrades production, casts skills
	- EZ-UI-Library panel + live log + watermark (watch it play live)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local RS = game:GetService("ReplicatedStorage") -- attribute diagnostics channel

local genv = getgenv()

if genv.TC_QUEUE_MARK then
	local dt = os.clock() - genv.TC_QUEUE_MARK
	genv.TC_QUEUE_MARK = nil
	print(("[TCAuto] [loop] teleport reboot fired (queued %.1fs ago)"):format(dt))
end

if genv.TCAutoplay then
	pcall(function() genv.TCAutoplay.stop() end)
	genv.TCAutoplay = nil
end

----------------------------------------------------------------
-- Config
----------------------------------------------------------------

local CFG = {
	tickSeconds = 1.0,
	sendCooldown = 3.0,        -- per (source,target) pair — claims must be snappy
	nodeActionCooldown = 2.0,  -- per source node
	claimCooldown = 5.0,       -- per target node after a rejected claim
	attackThreshold = 1.15,    -- attack enemy if myCount > enemyCount * this
	defenseRatio = 1.0,        -- border garrison: match the incoming force
	garrisonMin = 12,          -- team borders never hold less than this
	garrisonCap = 60,          -- borders may stack this much to tank a push
	defendFloor = 18,          -- DEFEND mode: border garrison floor
	stagingReserve = 6,        -- ring behind the front stages this much
	evacuationBuffer = 60,     -- evacuate only when threat > count*2 + this
	garrisonReserve = 0.15,    -- fraction of source troops kept home
	freeGarrisonBuffer = 2,    -- extra troops to land on a claimed free node
	upgradeReserve = 10,       -- troops kept after paying an upgrade
	skillEnergyReserve = 2,    -- energy kept when casting skills
	maxSendsPerTick = 6,
	waveInterval = 7.0,        -- seconds between All-Rear waves
	unitCommandInterval = 5.0, -- seconds between special-unit orders
	trumpetEdge = 0.75,        -- horn center offset: radius * this back from target
	trumpetRadius = 15,        -- from Skill_10005 config (all levels)
}

-- Lane graph + node coords. Loaded from the live map config when a match
-- starts (rebuildGraph below) — Map60001 differs from 60002/60003: 28 nodes /
-- 36 lanes. FALLBACK_EDGES is the verified 60002/60003 graph (34 nodes/45
-- edges, RMS 0.01 vs world coords) for when no config can be required.
local EDGES, MAPPOS, ADJ = {}, {}, {}
local currentMapId = nil

local FALLBACK_EDGES = {
	{"1_1","1_2"},{"1_1","1_3"},{"1_2","1_3"},{"1_3","Wai_1"},
	{"2_1","2_2"},{"2_1","2_3"},{"2_2","2_3"},{"2_3","Wai_2"},
	{"3_1","3_2"},{"3_1","3_3"},{"3_2","3_3"},{"3_3","Wai_3"},
	{"4_1","4_2"},{"4_1","4_3"},{"4_2","4_3"},{"4_3","Wai_4"},
	{"5_1","5_2"},{"5_1","5_3"},{"5_2","5_3"},{"5_3","Wai_5"},
	{"6_1","6_2"},{"6_1","6_3"},{"6_2","6_3"},{"6_3","Wai_6"},
	{"HeXin_1","Nei_1"},{"HeXin_1","Nei_2"},{"HeXin_1","Nei_3"},
	{"HeXin_1","Nei_4"},{"HeXin_1","Nei_5"},{"HeXin_1","Nei_6"},
	{"Wai_1","Nei_1"},{"Wai_1","Zhong_1"},{"Wai_2","Nei_2"},{"Wai_2","Wai_3"},
	{"Wai_3","Nei_3"},{"Wai_3","Zhong_2"},{"Wai_4","Nei_4"},{"Wai_4","Wai_5"},
	{"Wai_5","Nei_5"},{"Wai_5","Zhong_3"},{"Wai_6","Nei_6"},{"Wai_6","Wai_1"},
	{"Zhong_1","Wai_2"},{"Zhong_2","Wai_4"},{"Zhong_3","Wai_6"},
}

local function mapPointOf(nodeId)
	local p = MAPPOS[nodeId]
	if p then
		return { kind = "MapPoint", position = { x = p.x, y = p.y } }
	end
	return nil
end

-- ArenaBuildingAssetKey -> production per sec
--  "Lv0" = road (0.5); "Lv1/Lv2/Lv3" = upgradable home family (0.4/0.8/1.2)
--  "Pao0..3" = towers (no production); "Center1" = 1.0 (Center2 also gives +20% aura)
local function assetProduction(asset)
	local lvl = tonumber(asset:match("^Lv(%d+)$"))
	if lvl == 0 then return 0.5 end
	if lvl then return ({ [1] = 0.4, [2] = 0.8, [3] = 1.2 })[lvl] or 0.4 end
	if asset == "Center1" or asset == "Center2" then return 1.0 end
	return 0
end

-- skill id -> behavior
local SKILL_SUMMON = { ["10002"] = true, ["10003"] = true, ["20002"] = true, ["20005"] = true, ["20006"] = true, ["20009"] = true }
local SKILL_NUKE = { ["10001"] = true, ["20001"] = true }
local SKILL_TRUMPET = { ["10005"] = true }
local SKILL_SHIELD = { ["10004"] = true, ["20008"] = true }
local SKILL_CLONE = { ["20004"] = true }      -- OwnedNodesInArea: multiply our city troops
local SKILL_GLOBAL = { ["20007"] = true }     -- Conscription: +troops every city, no target

----------------------------------------------------------------
-- State
----------------------------------------------------------------

local running = true
local loopThread
local mySlot, arenaId = nil, "match"
-- behavior flags live in a plain table (defaults work headless — UI only writes)
local Flags = {
	Master = true,
	Aggressive = true,
	WaveMode = true,
	UseSkills = true,
	CommandUnits = true,
	AutoUpgrade = true,
	AutoStart = true,
	VeteranQueue = false,
	AutoBuyCommand = true,
	AutoUpgradeCommands = true,
	AutoLeave = true,
	BuySupers = true,
	UseNuke = false,
}
local watermarkHandle = nil
local handles = {}
local stats = { nodes = 0, troops = 0, energy = 0, enemies = 0, sends = 0, skills = 0, upgrades = 0, units = 0, since = os.clock() }

local zapOK, zap = pcall(function() return require(ReplicatedStorage.Game.Arena.zap.client) end)
local reqId = 0

local sendPairCd = {}   -- ["src>tgt"] = clock
local nodeCd = {}       -- nodeId = clock
local claimCd = {}      -- nodeId = clock
local skillCd = {}      -- skillId = clock (rejection backoff)
local unitCd = {}       -- specialUnitId = clock
local nextWaveAt = 0    -- All-Rear wave cadence
local medallionMode = false -- veteran matches (Map60003): upgrades paid with medallions
local lastOwners = {}   -- nodeId -> last seen owner (false = grey), for fresh-capture detection
local inboundDiag = 0   -- counts radar ticks that saw groups but resolved no headings
local upgradeMaxed = {} -- nodeId = true (server rejected: BuildingAtMaxLevel)
local upgradeTryCd = {} -- nodeId = clock (throttle attempts / builds in progress)
local slotReal = nil    -- slot_x -> is a real player (troop-bar headshot seated in game.Players)
local lastNodeCounts = {} -- nodeId -> last tick garrison (overspend detection)
local lastTruckCommand = nil -- { nodeId, power, at } — recent truck commit, counts toward wave power
local unitClaimTargets = {} -- nodeId -> clock of a recent command-unit claim (plot troops stand down)
local mapTeams = nil -- map config team list (2v2v2: {a,f},{b,c},{d,e}) — nil on 1v1 maps
local campaign = { nodeId = nil, since = 0 } -- mid-game: concentrate waves on one axis
local waveFailStreak = 0 -- consecutive wave scans with nothing viable (pacing)
local adaptive = { ease = 0, defBoost = 0, caps = 0, losses = 0, windowStart = 0, lastThr = 0, lastDef = 0 }

local logFn = function(kind, text)
	print(("[TCAuto %s] %s"):format(kind, text))
end

-- Toast notifications through EZ (no-ops when the UI is closed/failed) —
-- the important events deserve to reach you while the window is hidden
local function notify(etype, title, content)
	local ez = handles.EZ
	if ez and ez.Notify then
		pcall(function()
			ez.Notify({ Title = title, Content = content, Type = etype, Duration = 5 })
		end)
	end
end

local function rebuildGraph(mapId)
	if mapId == currentMapId then return end
	currentMapId = mapId
	table.clear(EDGES)
	table.clear(MAPPOS)

	local folder = game.ReplicatedStorage:FindFirstChild("StudioContent")
	folder = folder and folder:FindFirstChild("Config")
	folder = folder and folder:FindFirstChild("Arena")
	folder = folder and folder:FindFirstChild("Maps")
	local loaded = false
	-- cfg is read again at line 211, after the `if mod then` block closes, so
	-- it has to be declared out here. As a `local ok, cfg` inside that block
	-- it went out of scope, and the read below hit the global (nil) instead —
	-- "attempt to index nil with 'teams'" on every map whose config loaded.
	local cfg
	local mod = folder and folder:FindFirstChild(mapId)
	if mod then
		local ok
		ok, cfg = pcall(require, mod)
		if ok and type(cfg) == "table" and type(cfg.nodes) == "table" then
			-- nodeId -> map coords, for skill MapPoint targets and the troop radar
			for _, n in ipairs(cfg.nodes) do
				if type(n.nodeId) == "string" and type(n.position) == "table" and n.position.x and n.position.y then
					MAPPOS[n.nodeId] = { x = n.position.x, y = n.position.y }
				end
			end
			if type(cfg.lanes) == "table" then
				local seen = {}
				for _, lane in ipairs(cfg.lanes) do
					local a, b = lane.fromNodeId, lane.toNodeId
					if MAPPOS[a] and MAPPOS[b] and not seen[a .. "|" .. b] then
						seen[a .. "|" .. b] = true
						seen[b .. "|" .. a] = true
						table.insert(EDGES, { a, b })
					end
				end
				loaded = #EDGES > 0
			end
		end
	end
	-- 2v2v2 maps pin the teams in config ({a,f},{b,c},{d,e}); 1v1 maps have none
	mapTeams = (loaded and cfg ~= nil and type(cfg.teams) == "table") and cfg.teams or nil
	if not loaded then
		for _, e in ipairs(FALLBACK_EDGES) do table.insert(EDGES, e) end
		for _, name in ipairs({ "Map60002", "Map60003" }) do
			local m = folder and folder:FindFirstChild(name)
			if m then
				local ok, cfg = pcall(require, m)
				if ok and type(cfg) == "table" and type(cfg.nodes) == "table" then
					for _, n in ipairs(cfg.nodes) do
						if type(n.nodeId) == "string" and type(n.position) == "table" then
							MAPPOS[n.nodeId] = { x = n.position.x, y = n.position.y }
						end
					end
					break
				end
			end
		end
		logFn("warn", ("[graph] config for %s unavailable — fallback graph active"):format(tostring(mapId)))
	end

	table.clear(ADJ)
	for _, e in ipairs(EDGES) do
		ADJ[e[1]] = ADJ[e[1]] or {}
		ADJ[e[2]] = ADJ[e[2]] or {}
		table.insert(ADJ[e[1]], e[2])
		table.insert(ADJ[e[2]], e[1])
	end
	local nodeCount = 0
	for _ in pairs(MAPPOS) do nodeCount += 1 end
	logFn("info", ("[graph] %s: %d nodes, %d lanes"):format(tostring(mapId), nodeCount, #EDGES))
end

local function nextReq()
	reqId += 1
	return ("tc_%d_%d"):format(reqId, math.floor(os.clock() * 1000))
end

local function sendCommand(kind, payload)
	if not zapOK then return false, "no zap" end
	local packed = table.pack(zap.ArenaCommandChannel.Call({
		commandKind = kind,
		clientRequestId = nextReq(),
		payload = payload,
	}))
	-- Call returns (transportAck, resultTable); the result carries the real ok
	local res = (packed.n >= 2 and type(packed[2]) == "table") and packed[2] or nil
	local ok = (res ~= nil and res.ok == true)
	return ok, res
end

local function sendTroops(source, target, ratio)
	local now = os.clock()
	if (sendPairCd[source .. ">" .. target] or 0) > now then return false end
	if (nodeCd[source] or 0) > now then return false end
	if (claimCd[target] or 0) > now then return false end
	local ok, res = sendCommand("SendTroops", {
		arenaId = arenaId,
		ownerSlotId = mySlot,
		sourceNodeId = source,
		targetNodeId = target,
		sendRatio = ratio,
	})
	if ok == true then
		sendPairCd[source .. ">" .. target] = now + CFG.sendCooldown
		nodeCd[source] = now + CFG.nodeActionCooldown
		stats.sends += 1
		return true
	else
		logFn("warn", ("send %s>%s rejected (%s)"):format(source, target, tostring(type(res) == "table" and res.errorCode or res)))
		claimCd[target] = now + CFG.claimCooldown
		return false
	end
end

local function upgradeBuilding(nodeId)
	-- the server owns the truth: the real cost/level chain lives in its
	-- building catalog (asset keys are off-by-one from levels — "Lv0" IS the
	-- level-1 home, "Pao0" the level-1 tower), so we attempt and learn from
	-- the rejection codes instead of a hardcoded cost table
	if upgradeMaxed[nodeId] then return false end
	if (upgradeTryCd[nodeId] or 0) > os.clock() then return false end
	local ok, res = sendCommand("UpgradeBuilding", {
		arenaId = arenaId,
		ownerSlotId = mySlot,
		nodeId = nodeId,
	})
	if ok == true then
		upgradeTryCd[nodeId] = os.clock() + 12 -- builds run ~10-20s
		return true
	end
	local code = type(res) == "table" and res.errorCode or nil
	if code == "BuildingAtMaxLevel" then
		upgradeMaxed[nodeId] = true
	elseif code == "BuildingAlreadyUpgrading" then
		upgradeTryCd[nodeId] = os.clock() + 12
	elseif code == "NotEnoughMatchCurrency" then
		upgradeTryCd[nodeId] = os.clock() + 10 -- retry when currency recovers
		return "poor"
	elseif code == "NotEnoughTroops" then
		upgradeTryCd[nodeId] = os.clock() + 8
		return "poor"
	else
		upgradeTryCd[nodeId] = os.clock() + 6
	end
	return false
end

local function sendWave(targetId, sourceIds, ratio)
	local now = os.clock()
	local ok, res = sendCommand("SendTroopsBatch", {
		selectionKind = "SelectAll",
		arenaId = arenaId,
		ownerSlotId = mySlot,
		sourceNodeIds = sourceIds,
		targetNodeId = targetId,
		sendRatio = ratio,
	})
	if ok == true then
		for _, src in ipairs(sourceIds) do
			nodeCd[src] = now + CFG.nodeActionCooldown
			sendPairCd[src .. ">" .. targetId] = now + CFG.sendCooldown
		end
		stats.sends += #sourceIds
		return true
	end
	claimCd[targetId] = now + CFG.claimCooldown
	logFn("warn", ("wave %s rejected (%s)"):format(targetId, tostring(type(res) == "table" and res.errorCode or res)))
	return false
end

local function castSkill(skillId, target, cost)
	if (skillCd[skillId] or 0) > os.clock() then return false, "cooldown" end
	if (stats.energy or 0) - (cost or 1) < CFG.skillEnergyReserve then return false, "energy" end
	local payload = {
		arenaId = arenaId,
		ownerSlotId = mySlot,
		skillId = skillId,
	}
	if target ~= nil then payload.target = target end
	local ok, res = sendCommand("CastSkill", payload)
	if ok == true then
		stats.skills += 1
		skillCd[skillId] = os.clock() + 4
		return true
	end
	skillCd[skillId] = os.clock() + (type(res) == "table" and res.errorCode == "SkillOnCooldown" and 2 or 5)
	logFn("warn", ("skill %s rejected (%s)"):format(skillId, tostring(type(res) == "table" and res.errorCode or res)))
	return false, res
end

----------------------------------------------------------------
-- Board reading
----------------------------------------------------------------

local readInbound -- forward decl: readBoard calls it, defined below

local function readCount(nodeModel)
	local slot = nodeModel:FindFirstChild("buildingSlot", true)
	local b = slot and slot:FindFirstChild("ArenaBuilding")
	if not b then return nil end
	local anchor = b:FindFirstChild("billboardAnchor")
	local gui = anchor and anchor:FindFirstChild("NodeBillboard")
	local frame = gui and gui:FindFirstChild("Frame")
	local tf = frame and frame:FindFirstChild("Troops")
	local tc = tf and tf:FindFirstChild("TroopCount")
	return b, tonumber(tc and tc.Text) or 0
end

local function readBoard()
	local map = Workspace:FindFirstChild("MatchMap")
	if not map then return nil end
	local nodesFolder = map:FindFirstChild("Nodes")
	if not nodesFolder then return nil end

	local board = { mine = {}, enemy = {}, free = {}, all = {}, byId = {}, allies = {} }
	local troopsTotal, enemyNodes = 0, 0
	-- 2v2v2 team awareness: the map config pins the teams — our teammate is the
	-- other member of our pair. Ally tiles are never enemies, never threats,
	-- and their territory is friendly ground for our units.
	board.ally = {}
	if mapTeams and mySlot then
		for _, team in ipairs(mapTeams) do
			if table.find(team.slotIds or {}, mySlot) then
				for _, s in ipairs(team.slotIds) do
					if s ~= mySlot then board.ally[s] = true end
				end
				break
			end
		end
	end
	for _, n in ipairs(nodesFolder:GetChildren()) do
		local b, count = readCount(n)
		if b then
			local owner = b:GetAttribute("ArenaOwnerSlotId")
			local asset = b:GetAttribute("ArenaBuildingAssetKey") or ""
			local info = { id = n.Name, owner = owner, asset = asset, count = count, model = n, building = b }
			board.byId[n.Name] = info
			table.insert(board.all, info)
			if owner == mySlot then
				table.insert(board.mine, info)
				troopsTotal += count
			elseif owner ~= nil and board.ally[owner] then
				table.insert(board.allies, info)
			elseif owner ~= nil then
				table.insert(board.enemy, info)
				enemyNodes += 1
			else
				table.insert(board.free, info)
			end
		end
	end
	stats.nodes = #board.mine
	stats.troops = troopsTotal
	stats.enemies = enemyNodes

	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local hud = pg and pg.AppGui and pg.AppGui.Main and pg.AppGui.Main:FindFirstChild("ArenaMatchHud")
	local energyVal = hud and hud.EnergyBar and hud.EnergyBar:FindFirstChild("EnergyValue")
	stats.energy = (energyVal and tonumber(energyVal.Text)) or 0

	local skills = {}
	local sb = hud and hud:FindFirstChild("SkillBar")
	if sb then
		for _, btn in ipairs(sb:GetChildren()) do
			local id = btn.Name:match("^SkillButton_(%d+)$")
			if id then
				local name = btn:FindFirstChild("NameLabel")
				local cd = btn:FindFirstChild("CooldownLabel")
				local cost = btn:FindFirstChild("EnergyCost")
				local cv = cost and cost:FindFirstChild("EnergyCostValue")
				local left = 0
				if cd then
					local t = tonumber(cd.Text:match("^(%d+)")) or tonumber(cd.Text)
					left = t or 0
				end
				skills[id] = { name = (name and name.Text) or id, cost = (cv and tonumber(cv.Text)) or 1, cd = left }
			end
		end
	end
	board.specials = {}
	local suFolder = map:FindFirstChild("ArenaSpecialUnits")
	if suFolder then
		for _, s in ipairs(suFolder:GetChildren()) do
			if s:GetAttribute("ArenaOwnerSlotId") == mySlot then
				local uid = s:GetAttribute("ArenaSpecialUnitId") or s.Name
				local skillId = uid:match("_(%d+)$")
				-- unit's current node: nearest map node to its model position
				-- (MoveToNode is 1-hop from wherever the unit stands)
				local curNode, bestD2
				local okP, cf = pcall(function() return s:GetPivot() end)
				if okP and cf then
					local x, z = cf.Position.X, cf.Position.Z
					for nid, p in pairs(MAPPOS) do
						local dx, dz = p.x - x, p.y - z
						local d2 = dx * dx + dz * dz
						if bestD2 == nil or d2 < bestD2 then
							bestD2 = d2
							curNode = nid
						end
					end
				end
				table.insert(board.specials, {
					id = uid,
					kind = (skillId == "20006") and "truck" or "combat",
					hp = s:GetAttribute("ArenaSpecialUnitHp") or 0,
					maxHp = s:GetAttribute("ArenaSpecialUnitMaxHp") or 0,
					curNode = curNode,
					moving = bestD2 ~= nil and bestD2 > 900, -- >30 units from any node = mid-lane
				})
			end
		end
	end
	board.inbound = readInbound(map, board.ally)
	board.bots = {}
	if slotReal then
		for s, real in pairs(slotReal) do
			if not real then board.bots[s] = true end
		end
	end
	board.captured, board.lost = {}, {}
	for _, info in ipairs(board.all) do
		local prev = lastOwners[info.id]
		local allyNow = info.owner ~= nil and board.ally[info.owner] == true
		if prev ~= nil and prev ~= mySlot and info.owner == mySlot then
			board.captured[info.id] = true
		elseif prev == mySlot and info.owner ~= mySlot and not allyNow then
			board.lost[info.id] = true -- ally handovers are not losses
		end
		lastOwners[info.id] = info.owner or false
	end
	-- overspend radar: an enemy node whose garrison just collapsed (they
	-- marched out) is a counter-attack window for the next ~20s
	board.overspent = {}
	for _, info in ipairs(board.all) do
		local prev = lastNodeCounts[info.id]
		if prev ~= nil and info.owner and info.owner ~= mySlot and not board.ally[info.owner] and prev - info.count >= 15 then
			board.overspent[info.id] = true
		end
		lastNodeCounts[info.id] = info.count
	end
	return board, skills
end

----------------------------------------------------------------
-- Inbound troop radar
----------------------------------------------------------------

-- Soldier models carry their group's troop count + owner, but the group's
-- source/target only exists inside the client projection — so we match each
-- group to its nearest lane by centroid position and read direction off the
-- soldiers' facing (LookVector projected onto the lane).
function readInbound(map, allySlots)
	local inbound = { mine = {}, enemy = {} }
	local folder = map:FindFirstChild("ArenaMovingTroops")
	if not folder then return inbound end

	local groups = {} -- groupKey -> { owner, troops, x, z, lx, lz, n }
	for _, inst in ipairs(folder:GetDescendants()) do
		if inst:GetAttribute("ArenaTroopGroupId") ~= nil then
			local owner = inst:GetAttribute("ArenaOwnerSlotId")
			if owner then
				local pos, look
				if inst:IsA("BasePart") then
					pos, look = inst.Position, inst.CFrame.LookVector
				elseif inst:IsA("Model") then
					local cf = inst:GetPivot()
					pos, look = cf.Position, cf.LookVector
				end
				if pos then
					local key = tostring(inst:GetAttribute("ArenaTroopGroupId"))
					local g = groups[key]
					if not g then
						g = { owner = owner, troops = tonumber(inst:GetAttribute("ArenaTroopCount")) or 0, x = 0, z = 0, lx = 0, lz = 0, n = 0 }
						groups[key] = g
					end
					g.x += pos.X
					g.z += pos.Z
					g.lx += look.X
					g.lz += look.Z
					g.n += 1
				end
			end
		end
	end

	local matched = 0
	for _, g in pairs(groups) do
		local ll = math.sqrt(g.lx * g.lx + g.lz * g.lz)
		if ll > 0.001 then
			local cx, cz = g.x / g.n, g.z / g.n
			local bestLane, bestDist = nil, math.huge
			for _, e in ipairs(EDGES) do
				local a, b = MAPPOS[e[1]], MAPPOS[e[2]]
				if a and b then
					local abx, abz = b.x - a.x, b.y - a.y -- map y == world Z
					local apx, apz = cx - a.x, cz - a.y
					local len2 = abx * abx + abz * abz
					if len2 > 1e-6 then
						local t = math.clamp((apx * abx + apz * abz) / len2, 0, 1)
						local dx, dz = cx - (a.x + abx * t), cz - (a.y + abz * t)
						local d2 = dx * dx + dz * dz
						if d2 < bestDist then
							bestDist = d2
							bestLane = e
						end
					end
				end
			end
			if bestLane and bestDist < 625 then
				local a, b = MAPPOS[bestLane[1]], MAPPOS[bestLane[2]]
				local abx, abz = b.x - a.x, b.y - a.y
				local alen = math.sqrt(abx * abx + abz * abz)
				if alen > 0.001 then
					local heading = (g.lx / ll) * (abx / alen) + (g.lz / ll) * (abz / alen)
					local target
					if heading > 0.3 then
						target = bestLane[2]
					elseif heading < -0.3 then
						target = bestLane[1]
					end
					if target then
						matched += 1
						local bucket
						if g.owner == mySlot then
							bucket = inbound.mine
						elseif not (allySlots and allySlots[g.owner]) then
							bucket = inbound.enemy -- ally troops are their business
						end
						if bucket then
							bucket[target] = (bucket[target] or 0) + (g.troops > 0 and g.troops or g.n)
						end
					end
				end
			end
		end
	end

	if next(groups) ~= nil and matched == 0 then
		inboundDiag += 1
		if inboundDiag == 5 then
			logFn("warn", "inbound radar: groups visible but no headings resolved — facing assumption may be wrong")
		end
	else
		inboundDiag = 0
	end
	return inbound
end

----------------------------------------------------------------
-- Decision engine
----------------------------------------------------------------

local function threatAt(board, nodeId)
	local maxEnemy, maxTwoHop = 0, 0
	for _, adjId in ipairs(ADJ[nodeId] or {}) do
		local info = board.byId[adjId]
		if info and info.owner and info.owner ~= mySlot and not (board.ally and board.ally[info.owner]) then
			-- doctrine: bots are weak (discount their stacks), real players
			-- demand respect (weigh theirs up); allies are never threats
			local w = (board.bots and board.bots[info.owner]) and 0.7 or 1.25
			local v = info.count * w
			if v > maxEnemy then
				maxEnemy = v
			end
			-- 2-hop foresight: a mass two lanes away is coming NEXT — pre-stack
			-- before it arrives instead of reacting on impact
			for _, hop2 in ipairs(ADJ[adjId] or {}) do
				if hop2 ~= nodeId then
					local info2 = board.byId[hop2]
					if info2 and info2.owner and info2.owner ~= mySlot and not (board.ally and board.ally[info2.owner]) then
						local v2 = info2.count * w * 0.5
						if v2 > maxTwoHop then
							maxTwoHop = v2
						end
					end
				end
			end
		end
	end
	-- troops already marching at this node count as threat the moment they spawn
	return maxEnemy + maxTwoHop + ((board.inbound and board.inbound.enemy[nodeId]) or 0)
end

-- every node of ours that can path to targetId through our claimed chain
-- (troops route through owned plots, so sources are not just direct neighbors)
local function sourcesForTarget(board, targetId)
	local seen, queue, sources = {}, {}, {}
	for _, adjId in ipairs(ADJ[targetId] or {}) do
		local m = board.byId[adjId]
		if m and m.owner == mySlot and not seen[adjId] then
			seen[adjId] = true
			table.insert(sources, adjId)
			table.insert(queue, adjId)
		end
	end
	while #queue > 0 do
		local cur = table.remove(queue)
		for _, adjId in ipairs(ADJ[cur] or {}) do
			if not seen[adjId] then
				local m = board.byId[adjId]
				if m and m.owner == mySlot then
					seen[adjId] = true
					table.insert(sources, adjId)
					table.insert(queue, adjId)
				end
			end
		end
	end
	return sources
end

local function isFrontier(board, nodeId)
	for _, adjId in ipairs(ADJ[nodeId] or {}) do
		local info = board.byId[adjId]
		if info and info.owner ~= mySlot then
			return true
		end
	end
	return false
end

-- bordering an actual hostile TEAM (owned node) vs just grey/free plots —
-- our teammate's frontier is friendly, not a hostile border
local function bordersTeam(board, nodeId)
	for _, adjId in ipairs(ADJ[nodeId] or {}) do
		local info = board.byId[adjId]
		if info and info.owner ~= nil and info.owner ~= mySlot and not (board.ally and board.ally[info.owner]) then
			return true
		end
	end
	return false
end

-- the ring behind the front: touches one of our team-facing frontiers
local function touchesFrontier(board, nodeId)
	for _, adjId in ipairs(ADJ[nodeId] or {}) do
		local info = board.byId[adjId]
		if info and info.owner == mySlot and bordersTeam(board, adjId) then
			return true
		end
	end
	return false
end

local function nodeDistance(aId, bId)
	local a, b = MAPPOS[aId], MAPPOS[bId]
	if a and b then
		local dx, dy = a.x - b.x, a.y - b.y
		return math.sqrt(dx * dx + dy * dy)
	end
	return math.huge
end

-- effective capture power of a special unit vs a city garrison
local function unitCaptureValue(u)
	if u.kind == "truck" then
		return u.hp * 2 -- damageMultiplier from KaChe_20006 config
	end
	return math.floor(u.hp * 0.8) -- combat units trade hp into the garrison
end

-- horn center: edge of the radius clips the target, bulk covers the approach
local function trumpetPoint(targetId, sourceIds)
	local tp = MAPPOS[targetId]
	if not tp then return nil end
	local sx, sy, n = 0, 0, 0
	for _, srcId in ipairs(sourceIds) do
		local sp = MAPPOS[srcId]
		if sp then
			sx += sp.x
			sy += sp.y
			n += 1
		end
	end
	if n == 0 then return nil end
	local dx, dy = tp.x - sx / n, tp.y - sy / n
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.001 then return { kind = "MapPoint", position = { x = tp.x, y = tp.y } } end
	local off = CFG.trumpetRadius * CFG.trumpetEdge
	local cx = tp.x - dx / len * off
	local cy = tp.y - dy / len * off
	return { kind = "MapPoint", position = { x = cx, y = cy } }
end

local lastDefendMode = nil

-- what the whole neighborhood is worth if we break through here — mid-game is
-- won by taking clusters (Center ring), not lone weak nodes
local function clusterValue(board, nodeId, depth)
	local total, seen, queue = 0, { [nodeId] = true }, { nodeId }
	for _ = 1, depth do
		local nextQ = {}
		for _, cur in ipairs(queue) do
			for _, adjId in ipairs(ADJ[cur] or {}) do
				if not seen[adjId] then
					seen[adjId] = true
					local info = board.byId[adjId]
					if info then
						total += assetProduction(info.asset) * 8 + #(ADJ[adjId] or {})
					end
					table.insert(nextQ, adjId)
				end
			end
		end
		queue = nextQ
	end
	return total
end

-- master's spend order: Centers compound (production + 20% aura), towers
-- shoot (attack speed/range exactly where attackers bleed), then the
-- cheapest/earliest homes first — hot borders bump their towers up the list
local function upgradePriority(board, mine)
	if mine.asset == "Center1" or mine.asset == "Center2" then return 100 end
	if mine.asset:find("^Pao") then return 60 + math.min(threatAt(board, mine.id), 30) end
	if mine.asset:find("^Lv") then return 40 - (tonumber(mine.asset:match("^Lv(%d+)")) or 0) end
	return 0
end

local function decide(board, skills)
	local actions = {}

	-- Coordination: attack when the balance favors us, turtle when it doesn't.
	-- Compare against the strongest single enemy slot — summing every enemy
	-- guarantees permanent DEFEND in 5-slot lobbies. Hysteresis keeps us
	-- committed to a mode until the balance clearly flips, so a couple of
	-- wandering troops don't flip-flop the whole front.
	local myTotal, strongestEnemy, strongestReal = 0, 0, 0
	for _, mine in ipairs(board.mine) do myTotal += mine.count end
	for _, e in ipairs(board.enemy) do
		strongestEnemy = math.max(strongestEnemy, e.count)
		if not (board.bots and board.bots[e.owner]) then
			strongestReal = math.max(strongestReal, e.count)
		end
	end
	-- doctrine: DEFEND posture keys off REAL players — backfill bots are prey,
	-- not a reason to turtle
	local defending
	if lastDefendMode == nil then
		defending = myTotal < strongestReal * 0.9
	elseif myTotal < strongestReal * 0.85 then
		defending = true
	elseif myTotal > strongestReal * 1.1 then
		defending = false
	else
		defending = lastDefendMode
	end
	if defending ~= lastDefendMode then
		logFn("info", ("[mode] %s (us %d vs real %d / strongest any %d)"):format(defending and "DEFEND" or "ATTACK", myTotal, strongestReal, strongestEnemy))
		lastDefendMode = defending
	end

	-- Adaptive layer: thresholds shift with recent outcomes (tuned in
	-- adaptiveUpdate) — bleeding fronts harden, stalled offenses ease.
	local thr = CFG.attackThreshold - adaptive.ease
	local dr = CFG.defenseRatio + adaptive.defBoost
	adaptive.lastThr, adaptive.lastDef = thr, dr

	-- CHOKED IN: if we just lost a node adjacent to our remaining cluster,
	-- reopening that lane outranks every other wave decision this tick.
	local emergencyTarget
	for lostId in pairs(board.lost or {}) do
		local info = board.byId[lostId]
		if info == nil or info.owner ~= mySlot then
			for _, adjId in ipairs(ADJ[lostId] or {}) do
				if board.byId[adjId] and board.byId[adjId].owner == mySlot then
					-- if an ALLY holds the lost exit now, it is friendly ground —
					-- no retake needed, we can move through it
					local holder = board.byId[lostId] and board.byId[lostId].owner
					if holder == nil or not (board.ally and board.ally[holder]) then
						emergencyTarget = lostId
					end
					break
				end
			end
		end
		if emergencyTarget then break end
	end
	if emergencyTarget then
		logFn("warn", ("[emergency] lost exit %s — concentrating everything on retaking it"):format(emergencyTarget))
		notify("warning", "Emergency retake", ("Lost exit lane %s — all-in retake ordered"):format(emergencyTarget))
		nextWaveAt = 0 -- fire now, don't wait out the wave cadence
	end

	-- Mid-game concentration: stay on one breaking axis until it falls or we
	-- go 60s without progress, then re-pick.
	if campaign.nodeId then
		local info = board.byId[campaign.nodeId]
		if info == nil or info.owner == mySlot or os.clock() - campaign.since > 60 then
			if info and info.owner == mySlot then
				logFn("success", ("[campaign] axis %s taken — picking the next one"):format(campaign.nodeId))
			end
			campaign.nodeId = nil
		end
	end

	-- Border-first garrison: frontiers TANK — a threatened border holds up to
	-- the incoming force (radar inbound included) instead of yielding the inner
	-- producing plots. Interiors hold almost nothing and feed the front; the
	-- ring just behind a team-facing frontier stages a small reserve so support
	-- marches stay short. Surplus = what may leave.
	local garrisonNeeded, surplus = {}, {}
	for _, mine in ipairs(board.mine) do
		local t = threatAt(board, mine.id)
		local want
		if t > 0 then
			want = math.min(math.max(math.ceil(t * dr), CFG.garrisonMin), CFG.garrisonCap)
		elseif bordersTeam(board, mine.id) then
			want = CFG.garrisonMin
		elseif touchesFrontier(board, mine.id) then
			want = CFG.stagingReserve
		else
			want = 1 -- grey frontier: claim instantly, hold a single troop
		end
		if defending then
			want = math.min(math.max(want, CFG.defendFloor), CFG.garrisonCap)
		end
		-- truly hopeless border: fall back LATERALLY to the safest adjacent plot
		-- so the troops stay at the front — never march them deep into the base
		if t > mine.count * 2 + CFG.evacuationBuffer then
			local fallback, fallbackThreat
			for _, adjId in ipairs(ADJ[mine.id] or {}) do
				local info = board.byId[adjId]
				if info and info.owner == mySlot then
					local at = threatAt(board, adjId)
					if at < t and (fallbackThreat == nil or at < fallbackThreat) then
						fallback, fallbackThreat = info, at
					end
				end
			end
			if fallback and mine.count > 3 then
				table.insert(actions, { kind = "send", src = mine.id, tgt = fallback.id, ratio = 1.0, why = ("fallback %s (overrun by %d) -> %s (threat %d)"):format(mine.id, t, fallback.id, fallbackThreat or 0) })
				surplus[mine.id] = 0
				continue
			end
		end
		garrisonNeeded[mine.id] = want
		surplus[mine.id] = mine.count - want
	end

	-- 0b) INSTANT SUMMONS: cast the moment the cooldown ends — units spawn at
	--     our nearest city and start fighting, and the CD restarts immediately.
	--     Clone (24% troops to a claimed tile, OP per doctrine) pumps the
	--     biggest stack on cooldown. (Trumpet stays wave-paired; it is a timed
	--     buff, not a spawner.)
	if Flags and Flags.UseSkills then
		local biggestOwned
		for _, mine in ipairs(board.mine) do
			if biggestOwned == nil or mine.count > biggestOwned.count then biggestOwned = mine end
		end
		local anchor = biggestOwned and mapPointOf(biggestOwned.id)
		if anchor then
			for id, sk in pairs(skills) do
				if SKILL_SUMMON[id] and sk.cd <= 0 and (skillCd[id] or 0) <= os.clock() then
					table.insert(actions, { kind = "skill", id = id, cost = sk.cost, target = anchor, why = ("%s instant at %s"):format(sk.name, biggestOwned.id) })
					break
				end
			end
			for id, sk in pairs(skills) do
				if SKILL_CLONE[id] and sk.cd <= 0 and (skillCd[id] or 0) <= os.clock() then
					table.insert(actions, { kind = "skill", id = id, cost = sk.cost, target = anchor, why = ("%s +24%% troops at %s (x%d stack)"):format(sk.name, biggestOwned.id, biggestOwned.count) })
					break
				end
			end
		end
	end

	-- 1) DEFENSE: keep borders at garrison, pulling from quiet interiors.
	--    Assemble from several donors when no single one covers the need.
	for _, mine in ipairs(board.mine) do
		if mine.count < garrisonNeeded[mine.id] then
			local need = garrisonNeeded[mine.id] - mine.count
			local donors = {}
			for _, donor in ipairs(board.mine) do
				if donor.id ~= mine.id and (surplus[donor.id] or 0) > 1 then
					table.insert(donors, donor)
				end
			end
			-- donors that can cover the whole need first, nearest of those first —
			-- keeps support marches short instead of dragging the center forward
			local req = need
			table.sort(donors, function(a, b)
				local sa, sb = surplus[a.id] or 0, surplus[b.id] or 0
				local ca, cb = sa >= req, sb >= req
				if ca ~= cb then return ca end
				if ca then return nodeDistance(a.id, mine.id) < nodeDistance(b.id, mine.id) end
				return sa > sb
			end)
			for _, donor in ipairs(donors) do
				if need <= 0 then break end
				local give = math.min(surplus[donor.id], need)
				table.insert(actions, { kind = "send", src = donor.id, tgt = mine.id, ratio = math.min(give / donor.count, 0.9), why = ("defend %s (threat %d, has %d)"):format(mine.id, threatAt(board, mine.id), mine.count) })
				surplus[donor.id] -= give
				need -= give
			end
		end
	end

	-- 2) DEFENSIVE ABILITIES: drop summons/nukes on our most exposed node
	if Flags and Flags.UseSkills then
		local hotNode, hotThreat
		for _, mine in ipairs(board.mine) do
			local t = threatAt(board, mine.id)
			if t > 0 and (hotThreat == nil or t > hotThreat) then
				hotThreat, hotNode = t, mine
			end
		end
		if hotNode and hotNode.count < hotThreat * 1.5 then
			local anchor = mapPointOf(hotNode.id)
			if anchor then
				for id, sk in pairs(skills) do
					if sk.cd <= 0 and (skillCd[id] or 0) <= os.clock() and (SKILL_SUMMON[id] or SKILL_NUKE[id] or SKILL_SHIELD[id]) then
						table.insert(actions, { kind = "skill", id = id, cost = sk.cost, target = anchor, why = ("%s defends %s (threat %d)"):format(sk.name, hotNode.id, hotThreat) })
						break
					end
				end
			end
		end
	end

	-- 2b) ALWAYS-ON GLOBALS: Conscription is free troops every cooldown
	if Flags and Flags.UseSkills then
		for id, sk in pairs(skills) do
			if SKILL_GLOBAL[id] and sk.cd <= 0 and (skillCd[id] or 0) <= os.clock() then
				table.insert(actions, { kind = "skill", id = id, cost = sk.cost, target = nil, why = ("%s (all cities +troops)"):format(sk.name) })
				break
			end
		end
	end

	-- 3) All-Rear wave through our claimed chain (sources can be far back)
	local waveFired = false
	if Flags and Flags.WaveMode and os.clock() >= nextWaveAt then
		local candidates = {}
		for _, tgt in ipairs(board.all) do
			local isFree = tgt.owner == nil
			-- allies own nothing we attack; their tiles are friendly ground
			local isEnemy = tgt.owner ~= nil and tgt.owner ~= mySlot and not (board.ally and board.ally[tgt.owner])
			local isEmergency = emergencyTarget ~= nil and tgt.id == emergencyTarget
			-- a command unit is already claiming this grey tile — don't wave over it
			local unitClaimed = isFree and unitClaimTargets[tgt.id] ~= nil and (os.clock() - unitClaimTargets[tgt.id]) < 12
			if (isFree or (isEnemy and Flags.Aggressive) or isEmergency) and not unitClaimed and ((claimCd[tgt.id] or 0) <= os.clock() or isEmergency) then
				local backing, srcIds = 0, {}
				for _, srcId in ipairs(sourcesForTarget(board, tgt.id)) do
					table.insert(srcIds, srcId)
					backing += math.max((surplus[srcId] or 0), 0)
				end
				if #srcIds > 0 then
					table.insert(candidates, { tgt = tgt, backing = backing, srcIds = srcIds, isFree = isFree, isEmergency = isEmergency })
				end
			end
		end
		-- Score targets instead of blindly taking the weakest: production plots
		-- and chokepoints are worth more, troops already en route reduce the
		-- need, and a target sitting next to a bigger enemy stack just gets
		-- retaken — that guard check keeps waves honest.
		local bestC, bestNeed, bestValue
		for _, c in ipairs(candidates) do
			-- a lost exit lane is existential: parity + buffer, ignore the
			-- retake-guard — everything else waits
			if c.isEmergency then
				local eNeed = c.tgt.count + CFG.freeGarrisonBuffer + 2
				if c.backing > eNeed * 0.8 then
					bestC, bestNeed, bestValue = c, eNeed, math.huge
					break
				end
			else
			local myIn = (board.inbound and board.inbound.mine[c.tgt.id]) or 0
			local botTarget = c.tgt.owner ~= nil and (board.bots and board.bots[c.tgt.owner]) or false
			-- a truck committed within the last 20s is already marching at this
			-- tile with 2x structure damage — count it toward the push
			local truckIn = (lastTruckCommand and lastTruckCommand.nodeId == c.tgt.id and os.clock() - lastTruckCommand.at < 20) and lastTruckCommand.power or 0
			local need = (c.isFree and (c.tgt.count + CFG.freeGarrisonBuffer + 2) or (c.tgt.count * (botTarget and thr * 0.6 or thr) + 4)) * (defending and 1.3 or 1.0)
			need = math.max(1, need - myIn - truckIn)
			if c.backing > need then
				local guard = 0
				for _, adjId in ipairs(ADJ[c.tgt.id] or {}) do
					local info = board.byId[adjId]
					if info and info.owner and info.owner ~= mySlot and not (board.ally and board.ally[info.owner]) and info.count > guard then
						guard = info.count
					end
				end
				if c.isFree or guard <= c.backing then
					-- cluster worth beats lone-node worth; sticking to a breaking
					-- axis is worth more than re-scanning every wave. Bots are
					-- prey (doctrine); the veteran Center pays +20% spawns.
					local isCenter = c.tgt.asset == "Center1" or c.tgt.asset == "Center2"
					local value = clusterValue(board, c.tgt.id, 2) * 0.4 + assetProduction(c.tgt.asset) * 8 + #(ADJ[c.tgt.id] or {}) + (c.isFree and 3 or 0) - guard * 0.15
					if botTarget then value += 8 end
					if isCenter then value += 6 end
					if board.overspent and board.overspent[c.tgt.id] then value += 6 end
					if campaign.nodeId == c.tgt.id then
						value += value * 0.35
					end
					if bestValue == nil or value > bestValue then
						bestC, bestNeed, bestValue = c, need, value
					end
				end
			end
			end
		end
		if bestC then
			local c = bestC
			local need = bestNeed
				if Flags.UseSkills then
					-- summons anchor at our biggest stack (server snaps to nearest
					-- owned node); horn/nuke center on the wave target itself
					local biggestOwned
					for _, srcId in ipairs(c.srcIds) do
						local mine = board.byId[srcId]
						if mine and (biggestOwned == nil or mine.count > biggestOwned.count) then
							biggestOwned = mine
						end
					end
					local summonAnchor = biggestOwned and mapPointOf(biggestOwned.id)
					local targetPoint = mapPointOf(c.tgt.id)
					local hornPoint = trumpetPoint(c.tgt.id, c.srcIds)
					for id, sk in pairs(skills) do
						if sk.cd <= 0 and (skillCd[id] or 0) <= os.clock() then
							if SKILL_SUMMON[id] and summonAnchor then
								table.insert(actions, { kind = "skill", id = id, cost = sk.cost, target = summonAnchor, why = ("%s joins the push on %s"):format(sk.name, c.tgt.id) })
							elseif SKILL_NUKE[id] and targetPoint then
								table.insert(actions, { kind = "skill", id = id, cost = sk.cost, target = targetPoint, why = ("%s at %s (wave support)"):format(sk.name, c.tgt.id) })
							elseif SKILL_TRUMPET[id] and hornPoint then
								table.insert(actions, { kind = "skill", id = id, cost = sk.cost, target = hornPoint, why = ("%s covering the approach to %s (edge on tower)"):format(sk.name, c.tgt.id) })
							elseif SKILL_CLONE[id] and summonAnchor then
								table.insert(actions, { kind = "skill", id = id, cost = sk.cost, target = summonAnchor, why = ("%s before the push on %s"):format(sk.name, c.tgt.id) })
							end
						end
					end
				end
				-- batch ratio applies per-source full count; cap it so no source
				-- dips below its garrison
				local maxFraction = 1
				for _, srcId in ipairs(c.srcIds) do
					local mine = board.byId[srcId]
					if mine and mine.count > 0 then
						maxFraction = math.min(maxFraction, math.max((surplus[srcId] or 0) / mine.count, 0))
					end
				end
				local ratio = math.clamp(need * 1.15 / math.max(c.backing, 1), 0.3, 0.85)
				ratio = math.min(ratio, maxFraction)
				if ratio >= 0.1 then
					table.insert(actions, { kind = "wave", target = c.tgt.id, sourceIds = c.srcIds, ratio = ratio, why = ("all-rear -> %s (%s x%d, %d surplus)%s"):format(c.tgt.id, c.isFree and "free" or c.tgt.owner, c.tgt.count, c.backing, campaign.nodeId == c.tgt.id and " [campaign]" or "") })
					campaign.nodeId = c.tgt.id
					campaign.since = os.clock()
					nextWaveAt = os.clock() + CFG.waveInterval
					waveFired = true
				else
					nextWaveAt = os.clock() + 5 -- garrisons too tight, back off
				end
		end
		if waveFired then
			waveFailStreak = 0
		elseif os.clock() >= nextWaveAt then
			-- nothing viable: back off progressively instead of churning sends
			waveFailStreak += 1
			nextWaveAt = os.clock() + math.min(3 + waveFailStreak * 2, 15)
		end
	end

	-- 4) Claims: instant — attackers >= defenders goes immediately (send
	--    everything above a single troop). Every reachable source counts, and
	--    troops already en route toward the claim count toward it.
	for _, tgt in ipairs(board.free) do
		if (claimCd[tgt.id] or 0) <= os.clock() then
			-- a command unit is claiming this — plot troops stay home (doctrine:
			-- early expansion rides on commands, troops save for defense)
			if unitClaimTargets[tgt.id] and (os.clock() - unitClaimTargets[tgt.id]) < 12 then
				-- skip
			else
			local srcIds = sourcesForTarget(board, tgt.id)
			local myIn = (board.inbound and board.inbound.mine[tgt.id]) or 0
			local enIn = (board.inbound and board.inbound.enemy[tgt.id]) or 0
			if enIn > tgt.count + 5 then
				-- an enemy wave is already taking this — don't feed troops in
				claimCd[tgt.id] = os.clock() + 4
			else
				local need = math.max(0, tgt.count + enIn - myIn)
				local donors, backing = {}, 0
				for _, srcId in ipairs(srcIds) do
					local mine = board.byId[srcId]
					if mine and (surplus[srcId] or 0) > 1 then
						table.insert(donors, srcId)
						backing += surplus[srcId]
					end
				end
				-- covering sources first, nearest of those first (short marches)
				local req = need
				table.sort(donors, function(a, b)
					local sa, sb = surplus[a.id] or 0, surplus[b.id] or 0
					local ca, cb = sa >= req, sb >= req
					if ca ~= cb then return ca end
					if ca then return nodeDistance(a.id, tgt.id) < nodeDistance(b.id, tgt.id) end
					return sa > sb
				end)
				if backing >= need then
					local wantLeft = need
					for _, srcId in ipairs(donors) do
						if wantLeft <= 0 then break end
						local mine = board.byId[srcId]
						local want = math.min(surplus[srcId], wantLeft)
						if want > 0 then
							table.insert(actions, { kind = "send", src = srcId, tgt = tgt.id, ratio = want / mine.count, why = ("claim %s (%d defenders) via %s"):format(tgt.id, tgt.count + enIn, srcId) })
							surplus[srcId] -= want
							wantLeft -= want
						end
					end
				end
			end
			end
		end
	end

	-- 5) Punish weak neighbors from surplus. ATTACK mode raids freely; DEFEND
	--    mode still counter-punches from fresh captures and crushing local
	--    superiority instead of sitting on the surplus.
	if Flags and Flags.Aggressive then
		for _, mine in ipairs(board.mine) do
			local fresh = board.captured and board.captured[mine.id]
			local pool = surplus[mine.id] or 0
			if pool >= (defending and (fresh and 1 or 20) or 12) then
				local best, bestScore
				for _, adjId in ipairs(ADJ[mine.id] or {}) do
					local tgt = board.byId[adjId]
					if tgt and tgt.owner and tgt.owner ~= mySlot and not (board.ally and board.ally[tgt.owner]) and (claimCd[adjId] or 0) <= os.clock() then
						local ovr = board.overspent and board.overspent[adjId]
						local gate = ovr and (tgt.count + 3) or (tgt.count * thr + 3)
						if pool > gate then
							-- bots first (doctrine); overspent tiles are windows
							local score = tgt.count - ((board.bots and board.bots[tgt.owner]) and 20 or 0) - (ovr and 10 or 0)
							if bestScore == nil or score < bestScore then
								best, bestScore = tgt, score
							end
						end
					end
				end
				if best and ((not defending) or fresh or pool > best.count * 2 + 10) then
					table.insert(actions, { kind = "send", src = mine.id, tgt = best.id, ratio = math.min(pool / mine.count, 0.9), why = ("%s %s (%s x%d)"):format(fresh and "counter-punch" or "raid", best.id, best.owner, best.count) })
					surplus[mine.id] = 0
				end
			end
		end
	end

	-- 6) Upgrades — in medallion mode the tick-level spender handles this
	--    (troops stay free for expansion); otherwise pay with surplus troops.
	--    Towers first (auto-shoot attackers), then homes; the server enforces
	--    the real cost, we just order candidates and keep a surplus floor.
	if Flags and Flags.AutoUpgrade and not medallionMode then
		local candidates = {}
		for _, mine in ipairs(board.mine) do
			if not upgradeMaxed[mine.id] and (surplus[mine.id] or 0) >= 16 then
				table.insert(candidates, { id = mine.id, pri = upgradePriority(board, mine), why = ("upgrade %s (x%d surplus %d)"):format(mine.id, mine.count, surplus[mine.id]) })
			end
		end
		table.sort(candidates, function(a, b) return a.pri > b.pri end)
		for i, c in ipairs(candidates) do
			if i > 3 then break end
			table.insert(actions, { kind = "upgrade", node = c.id, why = c.why })
		end
	end

	-- 7) SPECIAL UNITS as a capture force. SERVER RULE (verified live): a unit
	--    moves ONE HOP per command — the target must be adjacent to the unit's
	--    current node, and an enemy tile is enterable only if the unit outguns
	--    its garrison (else NoSpecialUnitRoute). So the commander targets
	--    adjacent tiles only and MARCHES hop-by-hop toward the objective.
	--    Units never idle: captures > marching. Wounded units are spent on the
	--    weakest adjacent useful tile.
	if Flags and Flags.CommandUnits then
		for _, u in ipairs(board.specials or {}) do
			if u.moving then
				-- en route — commanding mid-lane just gets rejected
				continue
			end
			if (unitCd[u.id] or 0) <= os.clock() and u.curNode then
				local function unitScore(tgt, isFree)
					return tgt.count
						- ((tgt.owner and board.bots and board.bots[tgt.owner]) and 25 or 0)
						- (isFree and 5 or 0)
				end
				local function commitUnit(tgt, power, why)
					table.insert(actions, { kind = "unit", unitId = u.id, action = "MoveToNode", nodeId = tgt.id, why = why })
					stats.units += 1
					unitCd[u.id] = os.clock() + (tgt.owner == nil and 3 or CFG.unitCommandInterval)
					claimCd[tgt.id] = os.clock() + 4
					if tgt.owner == nil then
						unitClaimTargets[tgt.id] = os.clock() -- plot troops stand down here
					end
					if u.kind == "truck" then
						lastTruckCommand = { nodeId = tgt.id, power = power, at = os.clock() }
					end
				end
				local power = unitCaptureValue(u)
				local cur = u.curNode
				-- capture candidates: ADJACENT tiles only, enemy must be beatable
				local candidates = {}
				for _, adjId in ipairs(ADJ[cur] or {}) do
					local tgt = board.byId[adjId]
					if tgt and (claimCd[adjId] or 0) <= os.clock() then
						local isFree = tgt.owner == nil
						local isEnemy = tgt.owner ~= nil and tgt.owner ~= mySlot and not (board.ally and board.ally[tgt.owner])
						if isFree and not (unitClaimTargets[adjId] and (os.clock() - unitClaimTargets[adjId]) < 12) then
							table.insert(candidates, { tgt = tgt, isFree = true })
						elseif isEnemy and power > tgt.count then
							table.insert(candidates, { tgt = tgt, isFree = false })
						end
					end
				end
				table.sort(candidates, function(a, b)
					return unitScore(a.tgt, a.isFree) < unitScore(b.tgt, b.isFree)
				end)
				local committed = false
				local wounded = u.maxHp > 0 and u.hp < u.maxHp * 0.4
				if candidates[1] then
					local c = candidates[1]
					commitUnit(c.tgt, power, ("%s %s %s (power %d vs %d garrison)%s"):format(
						u.id, wounded and "spends itself on" or "captures", c.tgt.id, power, c.tgt.count,
						wounded and (" — %d/%d hp left"):format(u.hp, u.maxHp) or ""))
					committed = true
				end
				if not committed and not wounded then
					-- MARCH: next hop toward the objective (active campaign, else
					-- the hottest enemy border) through enterable tiles
					local objective = campaign.nodeId
					if objective == nil or board.byId[objective] == nil or board.byId[objective].owner == mySlot then
						local hotScore = -1
						for _, mine in ipairs(board.mine) do
							for _, adjId in ipairs(ADJ[mine.id] or {}) do
								local info = board.byId[adjId]
								if info and info.owner and info.owner ~= mySlot then
									local s = threatAt(board, mine.id)
									if s > hotScore then
										hotScore = s
										objective = adjId
									end
								end
							end
						end
					end
					if objective then
						local dist = { [objective] = 0 }
						local queue = { objective }
						while #queue > 0 do
							local n = table.remove(queue, 1)
							for _, adjId in ipairs(ADJ[n] or {}) do
								if dist[adjId] == nil then
									dist[adjId] = dist[n] + 1
									table.insert(queue, adjId)
								end
							end
						end
						local hop, bestD
						for _, adjId in ipairs(ADJ[cur] or {}) do
							local d = dist[adjId]
							if d ~= nil then
								local info = board.byId[adjId]
								-- allied territory is friendly ground (2v2v2 rule:
								-- you can move onto claimed teammate tiles)
								local enterable = info.owner == nil or info.owner == mySlot or (board.ally and board.ally[info.owner]) or power > info.count
								if enterable and (bestD == nil or d < bestD) then
									hop, bestD = adjId, d
								end
							end
						end
						local info = hop and board.byId[hop]
						if info and dist[hop] > 0 and (claimCd[hop] or 0) <= os.clock() then
							commitUnit(info, power, ("%s marches toward %s via %s"):format(u.id, objective, hop))
							committed = true
						end
					end
				end
				if not committed and wounded then
					-- nothing worth hitting adjacent: fall back to our lines
					local home
					for _, adjId in ipairs(ADJ[cur] or {}) do
						local info = board.byId[adjId]
						if info and info.owner == mySlot then home = info break end
					end
					if home then
						table.insert(actions, { kind = "unit", unitId = u.id, action = "Retreat", nodeId = home.id, why = ("retreat %s (%d/%d hp)"):format(u.id, u.hp, u.maxHp) })
						unitCd[u.id] = os.clock() + CFG.unitCommandInterval
					end
				end
			end
		end
	end

	return actions
end

----------------------------------------------------------------
-- UI (EZ-UI-Library)
----------------------------------------------------------------

local function applyLogFn()
	if handles.log then
		logFn = function(kind, text)
			local m = { info = "Info", warn = "Warn", error = "Error", success = "Success" }
			pcall(function() handles.log[m[kind] or "Print"](text) end)
			print(("[TCAuto %s] %s"):format(kind, text))
		end
	end
end

local function buildUI()
	local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
	local ok, EZ = pcall(function()
		local lib = loadstring(game:HttpGet(repo .. "Library.lua"))()
		local okI, Icons = pcall(function() return loadstring(game:HttpGet(repo .. "addons/Icons.lua"))() end)
		if okI and Icons and lib.SetIcons then pcall(function() lib:SetIcons(Icons) end) end
		return lib
	end)
	if not ok or type(EZ) ~= "table" then
		logFn("warn", "EZ-UI failed to load: " .. tostring(EZ))
		return false
	end
	handles.EZ = EZ

	-- persistence + theme addons: configs are namespaced per game (v3.7), so
	-- Total Conquest settings never collide with other hubs
	local saveMgr, themeMgr, quickBar, notifHist
	pcall(function()
		saveMgr = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
		themeMgr = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
	end)
	if saveMgr then pcall(function() saveMgr:Bind(EZ, "TCAutoplay") end) end
	if themeMgr then
		pcall(function() themeMgr:Bind(EZ, { File = "TCAutoTheme.txt" }) end)
		pcall(function() themeMgr:LoadSaved() end) -- before the window: no colour flash
	end

	local Window = EZ:CreateWindow({
		Title = "TC Autoplay",
		SubTitle = "node-war bot · 2v2v2 ready",
		ToggleKey = Enum.KeyCode.RightShift,
		ToggleIcon = "sparkles",
	})

	local function bindToggle(id)
		return function(v) Flags[id] = v end
	end

	local ctl = Window:AddTab("Autoplay", "swords")
	local colL = ctl:AddLeftGroupbox("Command", "crosshair")
	local colR = ctl:AddRightGroupbox("Match flow", "rocket")

	colL:AddToggle("Master", {
		Text = "Autoplay enabled",
		Description = "Master switch — pauses every action",
		Default = Flags.Master,
		Callback = function(v)
			Flags.Master = v
			running = v
			logFn(v and "success" or "warn", v and "Autoplay ON" or "Autoplay PAUSED")
		end,
	})
	colL:AddToggle("Aggressive", { Text = "Attack enemies", Description = "Punish weak/overspent neighbours", Default = Flags.Aggressive, Callback = bindToggle("Aggressive") })
	colL:AddToggle("WaveMode", { Text = "All-Rear waves", Description = "Batch sends on a cadence", Default = Flags.WaveMode, Callback = bindToggle("WaveMode") })
	colL:AddToggle("UseSkills", { Text = "Auto-cast skills", Description = "Summons, clone, bombs", Default = Flags.UseSkills, Callback = bindToggle("UseSkills") })
	colL:AddToggle("CommandUnits", { Text = "Command units (never idle)", Description = "Trucks bomb towers, units claim", Default = Flags.CommandUnits, Callback = bindToggle("CommandUnits") })
	colL:AddToggle("AutoUpgrade", { Text = "Auto-upgrade production", Description = "Centers first, hot Pao towers next", Default = Flags.AutoUpgrade, Callback = bindToggle("AutoUpgrade") })

	colR:AddToggle("AutoStart", { Text = "Auto-start in lobby", Description = "Queues directly, no mode modal", Default = Flags.AutoStart, Callback = bindToggle("AutoStart") })
	colR:AddToggle("VeteranQueue", { Text = "Queue veteran mode", Description = "Veteran pair queue (needs 1 win)", Default = Flags.VeteranQueue, Callback = bindToggle("VeteranQueue") })
	colR:AddToggle("AutoBuyCommand", { Text = "Auto-buy command rolls", Description = "600 coins per roll while in lobby", Default = Flags.AutoBuyCommand, Callback = bindToggle("AutoBuyCommand") })
	colR:AddToggle("AutoUpgradeCommands", { Text = "Auto-upgrade commands", Description = "Dupe/exp economy", Default = Flags.AutoUpgradeCommands, Callback = bindToggle("AutoUpgradeCommands") })
	colR:AddToggle("AutoLeave", { Text = "Auto-leave on result", Description = "Victory/defeat screens", Default = Flags.AutoLeave, Callback = bindToggle("AutoLeave") })

	local colSL = ctl:AddLeftGroupbox("Super commands", "gem")
	local colSR = ctl:AddRightGroupbox("Tuning", "sliders-horizontal")
	colSL:AddToggle("BuySupers", { Text = "Auto-buy super commands", Description = "Holds a 300-medallion reserve", Default = Flags.BuySupers, Callback = bindToggle("BuySupers") })
	colSL:AddToggle("UseNuke", { Text = "Allow Super Nuke", Description = "400 meds — raises reserve to 400", Default = Flags.UseNuke, Callback = bindToggle("UseNuke") })

	colSR:AddSlider("AttackThr", {
		Text = "Attack threshold", Description = "Attack when my stack > theirs × this", Tooltip = "Lower = more aggressive",
		Min = 1, Max = 2, Default = CFG.attackThreshold, Increment = 0.05, Suffix = "x",
		Callback = function(v) CFG.attackThreshold = v end,
	})
	colSR:AddSlider("DefenseRatio", {
		Text = "Defense ratio", Description = "Garrison vs incoming force", Tooltip = "1.0 = match the threat",
		Min = 0.5, Max = 2, Default = CFG.defenseRatio, Increment = 0.05, Suffix = "x",
		Callback = function(v) CFG.defenseRatio = v end,
	})
	colSR:AddSlider("GarrisonCap", {
		Text = "Border garrison cap", Description = "Max troops parked on one border",
		Min = 10, Max = 100, Default = CFG.garrisonCap, Increment = 5, Suffix = " max",
		Callback = function(v) CFG.garrisonCap = v end,
	})
	colSR:AddSlider("StagingReserve", {
		Text = "Staging ring reserve", Description = "Troops held one tile behind the front",
		Min = 0, Max = 30, Default = CFG.stagingReserve, Increment = 1,
		Callback = function(v) CFG.stagingReserve = v end,
	})
	colSR:AddSlider("EvacBuffer", {
		Text = "Evacuation buffer", Description = "Fallback when threat > 2×garrison + this",
		Min = 20, Max = 150, Default = CFG.evacuationBuffer, Increment = 5,
		Callback = function(v) CFG.evacuationBuffer = v end,
	})

	local mon = Window:AddTab("Monitor", "activity")
	local secStats = mon:AddSection("Live stats")
	handles.nodes = secStats:AddLabel("Nodes: -")
	handles.troops = secStats:AddLabel("Troops: -")
	handles.energy = secStats:AddLabel("Energy: -")
	handles.enemies = secStats:AddLabel("Enemy nodes: -")
	handles.inbound = secStats:AddLabel("Inbound: -")
	handles.adapt = secStats:AddLabel("Adapt: -")
	handles.actions = secStats:AddLabel("Actions: 0 sends / 0 skills / 0 upgrades / 0 unit cmds")
	local secLog = mon:AddSection("Action log")
	handles.log = secLog:AddLog({ Height = 190, MaxLines = 60 })

	applyLogFn()

	pcall(function()
		watermarkHandle = EZ:CreateWatermark({
			Text = "TC-Auto | {fps} fps | {ping} ms | Master {flag:Master}",
		})
		watermarkHandle:Show()
	end)

	-- unload path: a destructive action gets a confirm dialog (EZ convention)
	local btnSec = mon:AddSection("Danger zone")
	btnSec:AddButton({
		Text = "Stop bot & unload UI",
		Callback = function()
			Window:AddDialog("DlgUnload", {
				Title = "Stop the bot?",
				Description = "The loop stops and the UI unloads. Active matches continue without automation.",
				FooterButtons = {
					{ Title = "Cancel", Variant = "Ghost" },
					{ Title = "Stop bot", Variant = "Destructive", Order = 1, Callback = function()
			if genv.TCAutoplay then pcall(function() genv.TCAutoplay.stop() end) end
					end },
				},
			})
		end,
	})

	-- shutdown wiring: the X button runs a full EZ:Destroy — detach handles so
	-- the bot keeps playing headless instead of poking dead UI objects
	EZ:OnDestroy(function()
		for k in pairs(handles) do handles[k] = nil end
		watermarkHandle = nil
		applyLogFn()
		print("[TCAutoplay] UI closed — bot keeps playing headless (re-inject or rejoin lobby for UI)")
	end)
	pcall(function()
		quickBar = loadstring(game:HttpGet(repo .. "addons/QuickBar.lua"))()
		notifHist = loadstring(game:HttpGet(repo .. "addons/NotificationHistory.lua"))()
	end)
	if quickBar then pcall(function() quickBar:Bind(EZ, Window) end) end
	if notifHist then pcall(function() notifHist:Bind(EZ, Window) end) end
	if saveMgr then pcall(function() saveMgr:LoadAutoloadConfig() end) end -- LAST

	logFn("success", "EZ-UI ready — RightShift hides/shows, configs persist per game")
	return true
end

----------------------------------------------------------------
-- Lobby automation (gacha, upgrades, queue)
----------------------------------------------------------------

local lobbyRegistry = nil -- ClientFacades registry, only valid in lobby place

local function enterLobbyMode()
	local ok, CF = pcall(function() return require(game.ReplicatedStorage.Game.ClientFacades) end)
	if ok and type(CF) == "table" then
		local ok2, reg = pcall(function() return CF.initAll() end)
		if ok2 and type(reg) == "table" then
			lobbyRegistry = reg
			return true
		end
	end
	lobbyRegistry = nil
	return false
end

local function readCoins()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local lobby = pg and pg.AppGui and pg.AppGui.Main and pg.AppGui.Main:FindFirstChild("LobbyHud")
	local amt = lobby and lobby.CurrencyPanel and lobby.CurrencyPanel:FindFirstChild("AmountLabel")
	-- the HUD abbreviates big balances ("8.64K") — tonumber() reads nil and
	-- the buy gate never opened
	local text = amt and amt.Text or ""
	local mult = 1
	local s = text:gsub(",", "")
	local suffix = s:match("([KkMmBb])%s*$")
	if suffix then
		mult = (suffix:lower() == "k" and 1000) or (suffix:lower() == "m" and 1000000) or 1000000000
		s = s:gsub("[KkMmBb]%s*$", "")
	end
	return (tonumber(s) or 0) * mult
end

local DRAW_COST = 600

local function fireModeCard(preferVeteran)
	-- last-resort UI path: pick a mode card inside an already-open ModeSelect
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local modal = pg and pg.AppGui and pg.AppGui:FindFirstChild("Modal")
	local root = modal and modal:FindFirstChild("ModeSelect", true)
	if not root then return false end
	local card = root:FindFirstChild(preferVeteran and "ModeB" or "ModeA", true)
		or root:FindFirstChild(preferVeteran and "ModeA" or "ModeB", true)
	if card and card:IsA("GuiButton") then
		return pcall(function() firesignal(card.Activated) end)
	end
	return false
end

local function lobbyTick()
	-- heartbeat via game attribute (cross-context visibility)
	pcall(function() RS:SetAttribute("TCAutoLobbyBeat", os.clock()) end)
	-- 1) Auto-start FIRST: queue directly through the matchmaking client so
	--    the mode-select modal never opens (firing QueuePanel.PlayButton only
	--    toggles that modal — it never queues). UI clicks are fallback only.
	if Flags and Flags.AutoStart then
		local pg = LocalPlayer:FindFirstChild("PlayerGui")
		local lobby = pg and pg.AppGui and pg.AppGui.Main and pg.AppGui.Main:FindFirstChild("LobbyHud")
		local qp = lobby and lobby:FindFirstChild("QueuePanel")
		local playBtn = qp and qp:FindFirstChild("PlayButton")
		local info = qp and qp:FindFirstChild("QueueInfo")
		if playBtn and playBtn.Visible and not (info and info.Visible) then
			local modeId = (Flags.VeteranQueue and "nodewar_veteran_1v1") or "nodewar_1v1"
			local reg = lobbyRegistry
			if not reg then
				enterLobbyMode()
				reg = lobbyRegistry
			end
			local okQ, res
			if reg then
				local mm = reg._instances["LobbyMatchmakingClient"]
				if mm then
					okQ, res = pcall(function() return mm:quickJoinMode(modeId) end)
				end
			end
			if okQ and type(res) == "table" and res.ok then
				logFn("success", ("[lobby] queued %s (direct, no modal)"):format(modeId))
			elseif pcall(function() firesignal(playBtn.Activated) end) then
				logFn("warn", ("[lobby] matchmaking client unavailable — UI fallback for %s"):format(modeId))
				local wantVeteran = Flags.VeteranQueue and true or false
				task.delay(0.7, function() fireModeCard(wantVeteran) end)
			else
				RS:SetAttribute("TCAutoLobbyErr", "firesignal unavailable")
			end
		end
	end

	-- The mode-select modal must never linger: a stray open modal (left over
	-- from a fallback click or a previous session) gets closed immediately.
	do
		local pg = LocalPlayer:FindFirstChild("PlayerGui")
		local modal = pg and pg.AppGui and pg.AppGui:FindFirstChild("Modal")
		local ms = modal and modal:FindFirstChild("ModeSelect", true)
		if ms and ms:IsA("GuiObject") and ms.Visible then
			local cb = ms:FindFirstChild("CloseButton", true)
			if cb and cb:IsA("GuiButton") then
				pcall(function() firesignal(cb.Activated) end)
			end
		end
	end

	local reg = lobbyRegistry
	if not reg then
		if not enterLobbyMode() then
			logFn("info", "lobby: registry unavailable, retrying...")
			RS:SetAttribute("TCAutoLobbyErr", "registry unavailable")
			return
		end
		reg = lobbyRegistry
	end

	-- auto-upgrade commands (duplicate/exp economy)
	if Flags and Flags.AutoUpgradeCommands then
		local okI, inv = pcall(function() return reg._instances["SkillInventoryClient"] end)
		if okI and inv then
			local okP, proj = pcall(function() return inv:getProjection() end)
			if okP and type(proj) == "table" and proj.skills then
				for id, s in pairs(proj.skills) do
					if s.canUpgrade and s.isOwned then
						local okU, res = pcall(function() return inv:upgradeSkill(id, s.level) end)
						if okU and type(res) == "table" and res.ok then
							logFn("success", ("[lobby] upgraded %s -> L%s (exp left %s)"):format(id, tostring(res.level), tostring(res.remainingExp)))
						end
						break -- one per tick
					end
				end
			end
		end
	end

	-- auto-buy commands (600 coins per roll, single draws)
	if Flags and Flags.AutoBuyCommand then
		local coins = readCoins()
		if coins >= DRAW_COST then
			local okG, gacha = pcall(function() return reg._instances["SkillGachaClient"] end)
			if okG and gacha then
				local okD, resD = pcall(function() return gacha:draw("normal", "single") end)
				if okD then
					logFn("info", ("[lobby] bought a command roll (600) — %.2fK left"):format(readCoins() / 1000))
				else
					RS:SetAttribute("TCAutoLobbyErr", "draw failed: " .. tostring(resD))
					logFn("warn", "[lobby] command roll failed: " .. tostring(resD))
				end
			end
		end
	end

	-- auto-start runs at the top of the tick (registry-first, modal-free)
end

----------------------------------------------------------------
-- Match: result auto-leave + super commands (match currency)
----------------------------------------------------------------

local function readMatchCurrency()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local hud = pg and pg.AppGui and pg.AppGui.Main and pg.AppGui.Main:FindFirstChild("ArenaMatchHud")
	-- MatchHudView nests/creates these elements — search recursively like the
	-- game's own syncMatchCurrency does (a direct-child find reads nil -> 0)
	local mc = hud and hud:FindFirstChild("MatchCurrency", true)
	local label = (mc and mc:FindFirstChild("MatchCurrencyLabel", true)) or (hud and hud:FindFirstChild("MatchCurrencyLabel", true))
	local text = label and label.Text or ""
	local value = tonumber(text)
	if not value then
		-- tolerate K/M abbreviations just in case
		local mult = text:find("[Kk]") and 1000 or (text:find("[Mm]") and 1000000 or 1)
		value = (tonumber(text:match("([%d%.]+)")) or 0) * mult
	end
	return math.floor(value)
end

local function readSuperCards()
	local cards = {}
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local hud = pg and pg.AppGui and pg.AppGui.Main and pg.AppGui.Main:FindFirstChild("ArenaMatchHud")
	local bar = hud and hud:FindFirstChild("SuperCommandBar")
	local list = bar and bar:FindFirstChild("List")
	if list then
		for _, card in ipairs(list:GetChildren()) do
			local id = card.Name:match("^Card_(%d+)$")
			local price = card:FindFirstChild("Price")
			local pl = price and price:FindFirstChild("PriceLabel")
			if id and pl then cards[id] = tonumber(pl.Text) or 0 end
		end
	end
	return cards
end

local function medallionUpgradeTick(board)
	if not medallionMode then return end
	if not (Flags and Flags.AutoUpgrade) then return end
	-- doctrine: hold a medallion reserve so supers can actually fire — UFO at
	-- 300 is the late-game trump card, 400 if nukes are enabled
	local reserve = (Flags and Flags.UseNuke and 400) or (Flags and Flags.BuySupers and 300) or 0
	if readMatchCurrency() - reserve < 15 then return end
	local candidates = {}
	for _, mine in ipairs(board.mine) do
		if not upgradeMaxed[mine.id] then
			table.insert(candidates, { id = mine.id, pri = upgradePriority(board, mine) })
		end
	end
	table.sort(candidates, function(a, b) return a.pri > b.pri end)
	local count = 0
	for _, c in ipairs(candidates) do
		local r = upgradeBuilding(c.id)
		if r == "poor" then continue end -- pricier pick — still try cheaper ones
		if r == true then
			count += 1
			stats.upgrades += 1
			if count >= 8 then break end
		end
	end
	if count > 0 then
		logFn("success", ("[medallion] %d upgrade(s) started (%d left)"):format(count, readMatchCurrency()))
	end
end

local function superCommandTick(board)
	if not (Flags and Flags.BuySupers) then return end
	local currency = readMatchCurrency()
	local cards = readSuperCards()

	local enemyMax, myMin = 0, math.huge
	for _, e in ipairs(board.enemy) do enemyMax = math.max(enemyMax, e.count) end
	for _, m in ipairs(board.mine) do myMin = math.min(myMin, m.count) end

	-- Super UFO (90002, 300 meds): steals the highest-trooped base and swaps
	-- it with our lowest — the anti-stockpile nuke of tempo. Fire when a
	-- stockpile gap is juicy.
	if cards["90002"] and currency >= cards["90002"] and enemyMax - myMin > 40 then
		local ok = sendCommand("BuySuperCommandUse", { arenaId = arenaId, ownerSlotId = mySlot, skillId = "90002" })
		if ok == true then
			logFn("success", ("[super] bought UFO (%d) — swapping their %d-troop base for our %d"):format(cards["90002"], enemyMax, myMin))
			castSkill("90002", nil, 0)
			return
		end
	end

	-- Super Turret (90003, 200 meds): emergency defense — buy it only when a
	-- border is actually about to fall, it is too expensive to idle in a lane
	local hotNode, hotThreat
	for _, mine in ipairs(board.mine) do
		local t = threatAt(board, mine.id)
		if t > 0 and (hotThreat == nil or t > hotThreat) then
			hotThreat, hotNode = t, mine
		end
	end
	if cards["90003"] and currency >= cards["90003"] and hotThreat and hotThreat > 25 and hotNode and hotNode.count < hotThreat then
		local anchor = mapPointOf(hotNode.id)
		if anchor then
			local ok = sendCommand("BuySuperCommandUse", { arenaId = arenaId, ownerSlotId = mySlot, skillId = "90003" })
			if ok == true then
				logFn("success", ("[super] bought Turret (%d) at %s — losing it (%d vs %d threat)"):format(cards["90003"], hotNode.id, hotNode.count, hotThreat))
				castSkill("90003", anchor, 0)
				return
			end
		end
	end

	-- Super Nuke (90001, 400 meds): halves the troops in the space it covers —
	-- only on explicit toggle and only against a real stockpile
	if Flags and Flags.UseNuke and cards["90001"] and currency >= cards["90001"] and enemyMax > 100 then
		local ok = sendCommand("BuySuperCommandUse", { arenaId = arenaId, ownerSlotId = mySlot, skillId = "90001" })
		if ok == true then
			logFn("success", ("[super] bought Nuke (%d) on a %d-troop stockpile"):format(cards["90001"], enemyMax))
			castSkill("90001", nil, 0)
		end
	end
end

-- The learning loop: watch captures/losses per 45s window and shift the
-- thresholds — harden when bleeding, ease when the offense stalls, decay back
-- toward base values when things flow. Log every shift so it's watchable.
local function adaptiveUpdate(board)
	local now = os.clock()
	if adaptive.windowStart == 0 then adaptive.windowStart = now end
	for _ in pairs(board.captured or {}) do adaptive.caps += 1 end
	for _ in pairs(board.lost or {}) do adaptive.losses += 1 end
	if now - adaptive.windowStart >= 45 then
		if adaptive.losses >= 2 then
			local before = adaptive.defBoost
			adaptive.defBoost = math.min(adaptive.defBoost + 0.15, 0.4)
			if adaptive.defBoost ~= before then
				logFn("warn", ("[adapt] bleeding (%d losses/window) -> defense +%d%%"):format(adaptive.losses, math.floor(adaptive.defBoost * 100)))
			end
		elseif adaptive.caps == 0 then
			-- stalled offense (even while trading losses) — ease the thresholds
			local before = adaptive.ease
			adaptive.ease = math.min(adaptive.ease + 0.05, 0.15)
			if adaptive.ease ~= before then
				logFn("info", ("[adapt] stalled offense -> attack threshold eased to %.2f"):format(CFG.attackThreshold - adaptive.ease))
			end
		elseif adaptive.caps >= 2 then
			adaptive.ease *= 0.5
			adaptive.defBoost *= 0.7
		end
		adaptive.caps, adaptive.losses = 0, 0
		adaptive.windowStart = now
	end
end

local function tryAutoLeave()	if not (Flags and Flags.AutoLeave) then return false end
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local modal = pg and pg.AppGui and pg.AppGui:FindFirstChild("Modal")
	if not modal then return false end
	for _, m in ipairs(modal:GetChildren()) do
		if m:IsA("Frame") and m.Visible and (m.Name == "EliminateResult" or m.Name == "ArenaResult") then
			local eb = m:FindFirstChild("ExitButton", true)
			if eb and (eb:IsA("TextButton") or eb:IsA("ImageButton")) then
				pcall(function() firesignal(eb.Activated) end)
				logFn("success", ("[match] result screen up (%s) — leaving"):format(m.Name))
				return true
			end
		end
	end
	return false
end

----------------------------------------------------------------
-- Main loop
----------------------------------------------------------------

local function tick()
	local mapProbe = Workspace:FindFirstChild("MatchMap")
	do
		-- medallion mode: the HUD shows the MatchCurrency panel exactly when
		-- matchCurrency.enabled — map id is only a fallback
		local pg = LocalPlayer:FindFirstChild("PlayerGui")
		local hud = pg and pg.AppGui and pg.AppGui.Main and pg.AppGui.Main:FindFirstChild("ArenaMatchHud")
		local mc = hud and hud:FindFirstChild("MatchCurrency", true)
		local mcVisible = (mc and mc:IsA("GuiObject") and mc.Visible) or false
		medallionMode = mcVisible or (mapProbe and mapProbe:GetAttribute("MatchMapId")) == "Map60003"
	end
	if mapProbe then
		rebuildGraph(mapProbe:GetAttribute("MatchMapId") or "Map60002")
	end
	pcall(function() RS:SetAttribute("TCAutoMatchBeat", os.clock()) end)
	local board, skills = readBoard()
	if not board then
		logFn("info", "no MatchMap — waiting for match...")
		return
	end
	if not running then return end

	local actions = decide(board, skills)
	local done = 0
	for _, a in ipairs(actions) do
		if done >= CFG.maxSendsPerTick then break end
		if a.kind == "send" then
			if sendTroops(a.src, a.tgt, a.ratio) then
				done += 1
				logFn("info", "[send] " .. a.why)
			end
		elseif a.kind == "upgrade" then
			if upgradeBuilding(a.node) then
				done += 1
				stats.upgrades += 1
				logFn("success", "[upgrade] " .. a.why)
			end
		elseif a.kind == "wave" then
			if sendWave(a.target, a.sourceIds, a.ratio) then
				done += 1
				logFn("success", "[wave] " .. a.why)
			end
		elseif a.kind == "unit" then
			local ok = sendCommand("ControlSpecialUnit", {
				arenaId = arenaId,
				ownerSlotId = mySlot,
				specialUnitId = a.unitId,
				actionKind = a.action,
				target = { kind = "Node", nodeId = a.nodeId },
			})
			if ok then
				logFn("info", "[unit] " .. a.why)
			else
				unitCd[a.unitId] = os.clock() + 3
			end
		elseif a.kind == "skill" then
			if castSkill(a.id, a.target, a.cost) then
				logFn("success", "[skill] " .. a.why)
			end
		end
	end

	if handles.nodes then
		local mins = math.max((os.clock() - stats.since) / 60, 0.01)
		handles.nodes:Set(("Nodes: %d / %d"):format(stats.nodes, #board.all))
		handles.troops:Set(("Troops: %d (+%.1f/s est)"):format(stats.troops, (function()
			local total = 0
			for _, info in ipairs(board.mine) do total += assetProduction(info.asset) end
			return total
		end)()))
		handles.energy:Set("Energy: " .. tostring(stats.energy))
		handles.enemies:Set("Enemy nodes: " .. tostring(stats.enemies))
		if handles.inbound then
			local inbTotal = 0
			for _, v in pairs(board.inbound and board.inbound.enemy or {}) do inbTotal += v end
			handles.inbound:Set("Inbound: " .. tostring(inbTotal))
		end
		if handles.adapt then
			handles.adapt:Set(("Adapt: thr %.2f | def %.2f"):format(adaptive.lastThr, adaptive.lastDef))
		end
		handles.actions:Set(("Actions: %d sends / %d skills / %d upgrades / %d unit cmds (%.1f sends/min)"):format(stats.sends, stats.skills, stats.upgrades, stats.units, stats.sends / mins))
	end
	if watermarkHandle then
		pcall(function()
			watermarkHandle:SetText(("TC-Auto | nodes %d | troops %d | energy %d | enemies %d | {flag:Master}"):format(stats.nodes, stats.troops, stats.energy, stats.enemies))
		end)
	end

	superCommandTick(board)
	medallionUpgradeTick(board)
	adaptiveUpdate(board)
	tryAutoLeave()
end

local function readSlots()
	-- one troop-bar scan: my identity + bot detection. Real players carry an
	-- rbxthumb AvatarHeadShot whose id seats in game.Players; backfill bots
	-- either show a static rbxassetid face or an avatar id with no seat.
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local hud = pg and pg.AppGui and pg.AppGui.Main and pg.AppGui.Main:FindFirstChild("ArenaMatchHud")
	local track = hud and hud.TopBar and hud.TopBar:FindFirstChild("TroopBarTrack")
	if not track then return nil end
	local known = {}
	for _, p in ipairs(Players:GetPlayers()) do known[p.UserId] = true end
	local kinds, mine = {}, nil
	for _, slot in ipairs(track:GetChildren()) do
		local letter = slot.Name:match("^TroopBarSlot([A-F])$")
		local head = letter and slot:FindFirstChild("Head")
		local img = head and tostring(head.Image) or ""
		local uid = tonumber(img:match("id=(%d+)"))
		if letter then
			local real = uid ~= nil and known[uid] == true
			kinds["slot_" .. letter:lower()] = real
			if real and uid == LocalPlayer.UserId then mine = "slot_" .. letter:lower() end
		end
	end
	return kinds, mine
end

local function detectMySlot()
	local kinds, mine = readSlots()
	slotReal = kinds
	return mine
end

local function main()
	-- in the lobby we skip identity entirely (no match HUD yet)
	if Workspace:FindFirstChild("MatchMap") then
		-- stale GC tables from previous matches make getgc identity unreliable;
		-- resolve from the HUD headshot, retrying until the troop bar renders
		local deadline = os.clock() + 30
		while mySlot == nil and os.clock() < deadline do
			mySlot = detectMySlot()
			if mySlot then break end
			task.wait(1)
		end
		if not mySlot then
			-- last resort: GC scan (may hit stale matches — headshot above is preferred)
			local g = (getgc and getgc(true)) or {}
			for _, obj in ipairs(g) do
				if type(obj) == "table" and not getmetatable(obj) then
					local ok, v = pcall(function() return obj.playerSlotId end)
					if ok and type(v) == "string" and v:sub(1, 5) == "slot_" then
						mySlot = v
						local ok2, aid = pcall(function() return obj.arenaId end)
						if ok2 and type(aid) == "string" then arenaId = aid end
						break
					end
				end
			end
		end
	end
	mySlot = mySlot or "slot_a"
	logFn("info", ("identity: %s @ %s (zap=%s)"):format(mySlot, arenaId, tostring(zapOK)))

	local uiOK = buildUI()
	if not uiOK then
		logFn("warn", "running headless (console only)")
	end

	while running ~= nil do
		if running then
			local inMatch = Workspace:FindFirstChild("MatchMap") ~= nil
			if inMatch then
				local fresh = detectMySlot()
				if fresh and fresh ~= mySlot then
					logFn("warn", ("identity corrected %s -> %s"):format(mySlot, fresh))
					mySlot = fresh
					table.clear(sendPairCd)
					table.clear(nodeCd)
				end
				local ok, err = pcall(tick)
				if not ok then logFn("error", "tick error: " .. tostring(err)) end
			else
				-- lobby: economy automation + auto-queue
				table.clear(lastOwners)
				local ok, err = pcall(lobbyTick)
				if not ok then
					logFn("error", "lobby error: " .. tostring(err))
					pcall(function() RS:SetAttribute("TCAutoLobbyErr", tostring(err)) end)
				end
			end
		end
		task.wait(CFG.tickSeconds)
	end
end

genv.TCAutoplay = {
	stop = function()
		running = false
		if loopThread then pcall(function() task.cancel(loopThread) end) end
		if watermarkHandle then pcall(function() watermarkHandle:Destroy() end) end
		if handles.EZ then pcall(function() handles.EZ:Destroy() end) end
		genv.TCAutoplay = nil
	end,
	getStats = function() return stats end,
	getConfig = function() return CFG end,
}

loopThread = task.spawn(main)
print("[TCAutoplay] loaded — RightShift toggles UI, getgenv().TCAutoplay.stop() to unload")
