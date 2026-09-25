-- Game guard: this module only runs in its own game.
-- game.GameId is the universe id (88070565), so every place in that
-- game matches. Anywhere else (autoexec, a shared hub, a wrong map
-- entry) it exits before touching anything.
if game.GameId ~= 88070565 then return end

-- BloxBurg | Auto Farm (EZ UI) — hairdresser logic + stats dashboard
-- Every job in the game is listed; only jobs with implemented logic can farm.

local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local EZ           = loadstring(game:HttpGet(repo .. "Library.lua"))()
local Icons        = loadstring(game:HttpGet(repo .. "addons/Icons.lua"))()
local SaveManager  = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()

EZ:SetIcons(Icons)
SaveManager:Bind(EZ, "BBFarmConfigs")
ThemeManager:Bind(EZ, { File = "BBFarm_Theme.txt" })
ThemeManager:LoadSaved()
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local SHUTDOWN = false
EZ:OnDestroy(function() SHUTDOWN = true end)

-- // Job registry ------------------------------------------------------------
-- Display names shown in the dropdown; flag stores the display string.
local JOBS = {
	"Stylez Hairdresser",
	"Bens Ice Cream Seller",
	"BloxBurgers Employee",
	"Cave Miner",
	"High School Teacher",
	"Hut Fisherman",
	"Lumber Woodcutter",
	"Mike's Mechanic",
	"Pizza Planet Baker",
	"Pizza Planet Delivery",
	"School Janitor",
	"Supermarket Cashier",
	"Supermarket Stocker",
	"Taxi Driver",
}
local LOGIC = { ["Stylez Hairdresser"] = true } -- jobs with working autofarm logic

local DISPLAY = {}
for _, name in ipairs(JOBS) do
	DISPLAY[#DISPLAY + 1] = LOGIC[name] and name or (name .. "  (no logic)")
end

-- // Session stats -----------------------------------------------------------
local Money = game:GetService("ReplicatedStorage"):WaitForChild("Stats"):WaitForChild(LocalPlayer.Name):WaitForChild("Money", 30)
local S = { start = os.clock(), served = 0, rejected = 0, earned = 0, last = "-" }
local STATUS = "Idle"

local function fmt(n)
	local s = tostring(math.floor(n))
	return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function hms(sec)
	sec = math.floor(sec + 0.5)
	return ("%02d:%02d:%02d"):format(sec // 3600, (sec // 60) % 60, sec % 60)
end

local function shiftEarnings()
	local ok, v = pcall(function()
		return Money.Parent.Job:FindFirstChild("ShiftEarnings")
	end)
	if ok and v then return v.Value end
	return nil
end

local function efficiency()
	local ok, v = pcall(function()
		return Money.Parent.Job:FindFirstChild("Efficiency")
	end)
	if ok and v then return math.floor(v.Value * 100 + 0.5) .. "%" end
	return "-"
end

local function resetSession()
	S.start = os.clock()
	S.served, S.rejected, S.earned, S.last = 0, 0, 0, "-"
end

-- // Window ------------------------------------------------------------------
local Window = EZ:CreateWindow({
	Title = "BloxBurg Auto Farm",
	ToggleKey = Enum.KeyCode.RightShift,
	ToggleIcon = "briefcase-business",
})

local MainTab = Window:AddTab("Main", "activity")
local FarmTab = Window:AddTab("Auto Farm", "zap")

local StatsBox = MainTab:AddLeftGroupbox("Session", "activity", "Live stats for the running autofarm session")
local StatsPara = StatsBox:AddParagraph({ Content = "starting..." })

local LogBox = MainTab:AddRightGroupbox("Activity", "scroll-text", "What the farm did")
local EngineLog = LogBox:AddLog({ MaxLines = 60, Height = 140 })

local FarmSection = FarmTab:AddSection("Farm", "Pick a job, then flip the toggle. Jobs marked (no logic) aren't implemented yet.")
FarmSection:AddDropdown("FarmJob", {
	Text = "Job to farm",
	Values = DISPLAY,
	Default = "Stylez Hairdresser",
	Tooltip = "Jobs marked (no logic) have no autofarm implementation yet",
	Callback = function(job)
		pcall(function() SaveManager:SaveAutoloadConfig("default") end)
		if not LOGIC[job] then
			EZ:Notify({ Title = "Auto Farm", Content = (job:gsub("%s*%(no logic%)", "")) .. " has no autofarm logic yet.", Type = "warning" })
		end
	end,
})

local FarmToggle
FarmToggle = FarmSection:AddToggle("AutoFarmEnabled", {
	Text = "Enable Auto Farm",
	Description = "Automatically serves customers for the selected job",
	Default = false,
	Callback = function(on)
		pcall(function() SaveManager:SaveAutoloadConfig("default") end)
		if not on then
			STATUS = "Idle"
			EZ:Notify({ Title = "Auto Farm", Content = "Auto farm stopped.", Type = "info" })
			return
		end
		if not LOGIC[EZ.Flags.FarmJob] then
			FarmToggle:Set(false, true)
			EZ:Notify({ Title = "Auto Farm", Content = "This job has no autofarm logic yet.", Type = "error" })
			return
		end
		EZ:Notify({ Title = "Auto Farm", Content = "Farming " .. (EZ.Flags.FarmJob:gsub("%s*%(no logic%)", "")) .. "...", Type = "success" })
	end,
})

FarmSection:AddButton({
	Text = "Reset Session",
	Callback = function()
		resetSession()
		EngineLog:Info("Session reset")
	end,
})

-- // Farm engine (verified hairdresser logic) ---------------------------------
local function waitForChain(root, ...)
	local obj = root
	for _, name in ipairs({ ... }) do
		obj = obj:WaitForChild(name, 30)
		if not obj then error("missing " .. tostring(name)) end
	end
	return obj
end

local function resolveRemote()
	local candidates = {
		waitForChain(LocalPlayer, "PlayerScripts", "Modules", "JobHandler", "StylezHairdresser"),
		waitForChain(LocalPlayer, "PlayerScripts", "Modules", "JobHandler"),
	}
	for _, mod in ipairs(candidates) do
		local okMod, sh = pcall(require, mod)
		if okMod and typeof(sh) == "table" then
			local t = sh
			for _ = 1, 3 do
				local mt = getmetatable(t)
				t = mt and mt.__index
				if not t or typeof(t) ~= "table" then break end
				local net = rawget(t, "net")
				if typeof(net) == "table" and net.InvokeServer then
					local okUps, ups = pcall(getupvalues, net.InvokeServer)
					if okUps and ups then
						local order = { 5 }
						for i = #ups, 1, -1 do
							if i ~= 5 and i ~= 1 and i ~= 2 then order[#order + 1] = i end
						end
						for _, i in ipairs(order) do
							local v = ups[i]
							if typeof(v) == "function" then
								local ok, res = pcall(v, "JobCompleted")
								if ok and typeof(res) == "Instance" and res:IsA("RemoteEvent") then
									return res
								end
							end
						end
					end
				end
			end
		end
	end
	error("could not resolve JobCompleted remote")
end

local function getWorkstations()
	local env = workspace:FindFirstChild("Environment")
	local locs = env and env:FindFirstChild("Locations")
	local city = locs and (locs:FindFirstChild("City") or locs:GetChildren()[1])
	local studio = city and city:FindFirstChild("StylezHairStudio")
	local wss = studio and studio.Interior and studio.Interior:FindFirstChild("HairdresserWorkstations")
	if wss then return wss end
	if locs then
		for _, d in ipairs(locs:GetDescendants()) do
			if d.Name == "HairdresserWorkstations" then return d end
		end
	end
	return nil
end

local function getActive(wss)
	for _, w in ipairs(wss:GetChildren()) do
		if w:IsA("Model") and w:FindFirstChild("Occupied") then
			local cust = w.Occupied.Value
			if cust and cust:FindFirstChild("Order") and cust.Order.Value == "" then
				local s = cust.Order:FindFirstChild("Style")
				local c = cust.Order:FindFirstChild("Color")
				if s and c and s.Value ~= "" and c.Value ~= "" then
					return w, s.Value, c.Value, cust.Order
				end
			end
		end
	end
	return nil
end

task.spawn(function()
	local remote, firedFor
	local retryCount = {}
	while not SHUTDOWN do
		local ok, err = pcall(function()
			local flags = EZ and EZ.Flags
			local enabled = flags and flags.AutoFarmEnabled and LOGIC[flags.FarmJob]
			if not enabled then
				STATUS = "Idle (toggle off)"
				task.wait(0.5)
				return
			end
			STATUS = "Waiting for customer"
			local wss = getWorkstations()
			if not wss then
				STATUS = "Waiting for map load"
				task.wait(2)
				return
			end
			local w, style, color, order = getActive(wss)
			if w and order ~= firedFor then
				firedFor = order
				remote = remote or resolveRemote()
				STATUS = "Serving " .. style .. " / " .. color
				remote:FireServer({ Workstation = w, Order = { style, color } })
				-- bounded wait for the verdict; never block forever
				local decided, served
				for _ = 1, 48 do -- ~12s
					task.wait(0.3)
					if order.Value ~= "" then
						decided = true
						served = order.Value == "true"
						break
					end
					if not order.Parent then break end -- customer despawned
				end
				if served then
					S.served += 1
					S.last = style .. " / " .. color
					EngineLog:Success(("Served %s / %s"):format(style, color))
				elseif decided then
					S.rejected += 1
					EngineLog:Error(("Rejected %s / %s"):format(style, color))
				else
					-- no verdict (customer left / lag): allow a bounded retry
					retryCount[order] = (retryCount[order] or 0) + 1
					if retryCount[order] >= 3 then
						EngineLog:Warn(("Gave up on %s / %s"):format(style, color))
					else
						firedFor = nil -- refire next loop
					end
					EngineLog:Warn(("No verdict for %s / %s"):format(style, color))
					task.wait(1)
				end
				task.wait(0.3)
			else
				task.wait(0.5)
			end
		end)
		if not ok then
			STATUS = "Error, retrying..."
			if not SHUTDOWN then EngineLog:Warn(tostring(err)) end
			remote = nil
			task.wait(2)
		end
	end
end)

-- // Stats updater ------------------------------------------------------------
local lastShiftEarn
task.spawn(function()
	local lastTxt
	while not SHUTDOWN do
		local flags = (EZ and EZ.Flags) or {}
		local job = flags.FarmJob or "-"
		local elapsed = os.clock() - S.start
		local hours = elapsed / 3600
		local rate = hours > 0.001 and (S.earned / hours) or 0
		local running = flags.AutoFarmEnabled and LOGIC[flags.FarmJob]
		-- accumulate shift-earnings increases only while the farm is running
		local cur = shiftEarnings()
		if cur then
			if lastShiftEarn == nil then
				lastShiftEarn = cur
			elseif cur > lastShiftEarn and running then
				S.earned += cur - lastShiftEarn
				lastShiftEarn = cur
			elseif cur <= lastShiftEarn then
				lastShiftEarn = cur -- new shift / payout taken
			end
		end
		local earn = shiftEarnings()
		local txt = table.concat({
			"Status:         " .. (running and STATUS or "Idle (toggle off)"),
			"Job:            " .. job:gsub("%s*%(no logic%)", ""),
			"Session time:   " .. hms(elapsed),
			"Customers:      " .. S.served .. " served, " .. S.rejected .. " rejected",
			"Earned:         $" .. fmt(S.earned),
			"Avg/serve:      $" .. fmt(S.served > 0 and S.earned / S.served or 0),
			"Rate:           $" .. fmt(rate) .. " / hour",
			"Shift earnings: " .. (earn and ("$" .. fmt(earn)) or "- (not on shift)"),
			"Efficiency:     " .. efficiency(),
			"Wallet:         $" .. fmt(Money.Value),
			"Last order:     " .. S.last,
		}, "\n")
		if txt ~= lastTxt then
			lastTxt = txt
			StatsPara:Set(txt)
		end
		task.wait(1)
	end
end)

SaveManager:LoadAutoloadConfig()
EngineLog:Info("Loaded — enable Auto Farm in the Auto Farm tab")
