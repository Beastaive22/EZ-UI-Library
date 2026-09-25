-- Game guard: this module only runs in its own game.
-- game.GameId is the universe id (10766047255), so every place in that
-- game matches. Anywhere else (autoexec, a shared hub, a wrong map
-- entry) it exits before touching anything.
if game.GameId ~= 10766047255 then return end

--[[
    Slam-A-Winner Autoplay
    Built on EZ-UI-Library (https://github.com/Beastaive22/EZ-UI-Library)
    Executor: Potassium / sUNC

    All actions drive the game through its own UI button connections
    (getconnections(btn.Activated):Fire()) — the same signals a real click fires.
    Server-side validation still applies, so every action is legit-shaped.

    Toggle UI: RightShift
]]

local game = game
local getgenv = getgenv

print("[SLAM-AUTOPLAY] starting")
if getgenv().__SLAM_AUTOPLAY_LOADED then
    pcall(function() getgenv().__SLAM_AUTOPLAY_DESTROY() end)
end

----------------------------------------------------------------
-- Library (canonical EZ-UI-Library setup)
----------------------------------------------------------------
local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local EZ = loadstring(game:HttpGet(repo .. "Library.lua"))()
local Icons = loadstring(game:HttpGet(repo .. "addons/Icons.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local QuickBar = loadstring(game:HttpGet(repo .. "addons/QuickBar.lua"))()
local NotifHistory = loadstring(game:HttpGet(repo .. "addons/NotificationHistory.lua"))()

EZ:SetIcons(Icons)
SaveManager:Bind(EZ, "SlamAutoplayConfigs")
ThemeManager:Bind(EZ, { File = "SlamAutoplay_Theme.txt" })
ThemeManager:LoadSaved() -- apply saved theme before the window builds: no colour flash
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

----------------------------------------------------------------
-- Runtime handles
----------------------------------------------------------------
local Players = game:GetService("Players")
local lp = Players.LocalPlayer
local UI = lp:WaitForChild("PlayerGui"):WaitForChild("SlamAWinnerUI")
local HUD = UI:WaitForChild("HUD")
local Nav = HUD:WaitForChild("Navigation")
local Dock = HUD:WaitForChild("ActionDock")
local Rack = HUD:WaitForChild("SpecialRollRack")

local RUNNING = true
local log -- assigned once the Stats tab builds its log console

local function fire(btn)
    if not btn then return false end
    local ok = false
    for _, c in ipairs(getconnections(btn.Activated)) do
        local okF = pcall(function() c:Fire() end)
        ok = ok or okF
    end
    return ok
end

local SUFFIX = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, Qa = 1e15, Qi = 1e18,
    Sx = 1e21, Sp = 1e24, Oc = 1e27, No = 1e30, Dc = 1e33 }

local function parseMoney(text) -- parses "$775K" / "$10B" style costs; requires the $ sign
    if type(text) ~= "string" then return nil end
    local num, suf = text:match("%$([%d%.]+)%s*(%a*)")
    if not num then return nil end
    local v = tonumber(num)
    if not v then return nil end
    if suf and suf ~= "" and SUFFIX[suf] then v = v * SUFFIX[suf] end
    return v
end

local function parseCount(text) -- "x31" -> 31
    local n = type(text) == "string" and text:match("x(%d+)") or nil
    return n and tonumber(n) or 0
end

local function money() return lp.leaderstats and lp.leaderstats.Money.Value or 0 end
local function gems() return lp.leaderstats and lp.leaderstats.Gems.Value or 0 end

-- Shared money-savings state: pauses cash spenders when close to affording the next zone
local ZoneSaving = { active = false, name = nil, price = nil, etaMin = nil, since = nil }
local MoneyPerMin = 0 -- net rate (profit meter; informational)
local GrossMoneyPerMin = 0 -- GROSS income from the game's "Total money earned" stat — spending-independent, used for ETA

-- Bot activity registry: loops report what they're doing; Main tab renders it live
local Bot = { last = {} }
local function botActivity(key, text)
    Bot.last[key] = { text = text, t = os.clock() }
end

-- All overlays pre-build their content at startup; every button below is fired
-- while hidden (verified). One-time init cycles each overlay once so content is
-- guaranteed to exist even on a brand-new session, then we never open UIs again.
local function initOverlay(navBtn, overlayName)
    local overlay = UI:FindFirstChild(overlayName)
    if not overlay then return end
    if #overlay:GetDescendants() > 8 then return end -- already built
    fire(navBtn)
    task.wait(0.4)
    local card = overlay:FindFirstChild("Card")
    fire(card and card:FindFirstChild("Close") or overlay:FindFirstChild("Close"))
    task.wait(0.2)
end

task.spawn(function()
    while RUNNING do
        local ok = pcall(function()
            initOverlay(Nav.Zones, "ZonesOverlay")
            initOverlay(Nav.Balls, "InventoryOverlay")
            initOverlay(Nav.Index, "IndexOverlay")
            initOverlay(Nav.Achievements, "AchievementsOverlay")
            -- CommunityOverlay: the Arcade panel only exists after the ArcadeTab is opened once
            local cov = UI:FindFirstChild("CommunityOverlay")
            if cov and cov:FindFirstChild("Card") then
                local body = cov.Card:FindFirstChild("Body")
                local arcade = body and body:FindFirstChild("Arcade")
                if not arcade or not arcade:FindFirstChild("TimingGame") then
                    fire(Nav.Community)
                    task.wait(0.4)
                    for _, d in ipairs(cov.Card:GetChildren()) do
                        if d:IsA("TextButton") and d.Name == "ArcadeTab" then fire(d) break end
                    end
                    task.wait(0.4)
                    local close = cov.Card:FindFirstChild("Close")
                    if close then fire(close) end
                    task.wait(0.2)
                end
            end
        end)
        if ok then break end
        task.wait(2)
    end
end)

----------------------------------------------------------------
-- Player state (replicated table kept fresh by the game client)
----------------------------------------------------------------
local State = {}
do
    local lastScan = 0
    function State.refresh()
        local now = os.clock()
        if now - lastScan < 2.5 then return end
        lastScan = now
        local best, seen
        local ok, res = pcall(filtergc, "table", { keys = { "UnlockedZones" } }, false)
        if ok and type(res) == "table" then
            for _, t in ipairs(res) do
                if type(t) == "table" and type(t.UnlockedZones) == "number"
                    and type(t.OwnedBalls) == "table" and type(t.LastSeen) == "number" then
                    if not seen or t.LastSeen > seen then seen = t.LastSeen; best = t end
                end
            end
        end
        State.s = best
    end
end

----------------------------------------------------------------
-- Window
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "Slam-A-Winner Autoplay",
    SubTitle = "kizzyskrim",
    ToggleKey = Enum.KeyCode.RightShift,
    Width = 680,
    Height = 480,
})

QuickBar:Bind(EZ, Window)
NotifHistory:Bind(EZ, Window)

local TabMain = Window:AddTab("Main", "gauge")
local TabFarm = Window:AddTab("Farming", "coins")
local TabEconomy = Window:AddTab("Economy", "banknote")
local TabEquip = Window:AddTab("Equip", "package")
local TabClaims = Window:AddTab("Claims", "gift")
local TabArcade = Window:AddTab("Arcade", "gamepad")
local TabStats = Window:AddTab("Stats", "chart-line")

----------------------------------------------------------------
-- MAIN tab — live bot dashboard
----------------------------------------------------------------
local secBot = TabMain:AddSection("Bot Activity")
local activityP = secBot:AddParagraph({ Title = "Currently", Content = "starting up..." })
local featuresP = secBot:AddParagraph({ Title = "Feature States", Content = "-" })

local secMain = TabMain:AddSection("Currencies & Zone")
local stMoney, stGems, stDrops, stZone, stBall, stMult
stMoney = secMain:AddParagraph({ Title = "Money", Content = "-" })
stGems = secMain:AddParagraph({ Title = "Gems", Content = "-" })
stDrops = secMain:AddParagraph({ Title = "Drops / Jackpots", Content = "-" })
stZone = secMain:AddParagraph({ Title = "Zone", Content = "-" })
stBall = secMain:AddParagraph({ Title = "Equipped Ball", Content = "-" })
stMult = secMain:AddParagraph({ Title = "Money Multiplier", Content = "-" })

local secCtl = TabMain:AddSection("Control")

-- Anti-AFK: block Roblox's 20-minute idle kick by disabling Idled connections
local idledConnections = {}
local function setAntiAFK(enabled)
    if enabled then
        for _, conn in ipairs(getconnections(lp.Idled)) do
            if conn.Enabled then
                conn:Disable()
                table.insert(idledConnections, conn)
            end
        end
        if log then log.Info("Anti-AFK: idle kick blocked (" .. #idledConnections .. " handler(s))") end
    else
        for _, conn in ipairs(idledConnections) do
            pcall(function() conn:Enable() end)
        end
        idledConnections = {}
        if log then log.Info("Anti-AFK: disabled — Roblox idle kick restored") end
    end
end

secCtl:AddToggle("AntiAFK", {
    Text = "Anti-AFK (never kicked for idling)",
    Default = true,
    Callback = setAntiAFK,
})
if EZ.Flags.AntiAFK then setAntiAFK(true) end

secCtl:AddButton({
    Text = "Unload",
    Callback = function() EZ:Destroy() end,
})

----------------------------------------------------------------
-- FARMING tab
----------------------------------------------------------------
local secDrop = TabFarm:AddSection("Ball Drops")
local dropHandle
dropHandle = secDrop:AddToggle("AutoDrop", {
    Text = "Auto Drop Ball",
    Default = false,
    Callback = function(v)
        if log then log.Info("Auto Drop " .. (v and "ON" or "OFF")) end
    end,
})
secDrop:AddSlider("DropDelay", {
    Text = "Drop Delay",
    Min = 0.15, Max = 2, Default = 0.35, Increment = 0.05, Suffix = "s",
})

local secSpin = TabFarm:AddSection("Ball Rolls")
local spinHandle
spinHandle = secSpin:AddToggle("AutoSpin", {
    Text = "Auto Spin Ball",
    Default = false,
})
secSpin:AddSlider("SpinDelay", {
    Text = "Spin Delay",
    Min = 0.4, Max = 5, Default = 1.05, Increment = 0.05, Suffix = "s",
})

local secSpecial = TabFarm:AddSection("Special Rolls")
secSpecial:AddToggle("AutoSolar", { Text = "Auto Solar Roll (100x)", Default = false })
secSpecial:AddToggle("AutoVoid", { Text = "Auto Void Roll (500x)", Default = false })
secSpecial:AddToggle("AutoInfinity", { Text = "Auto Infinity Roll (2,500x)", Default = false })
secSpecial:AddToggle("AutoCelestial", { Text = "Auto Celestial Roll (10,000x)", Default = false })
secSpecial:AddDropdown("SpecialsTiming", {
    Text = "When to burn rolls",
    Values = { "Any time", "Luck events only", "Smart save (tier-based)" },
    Default = "Any time",
    Tooltip = "Smart: Solar anytime, Void needs 2x+, Infinity needs 4x+, Celestial needs 6x+ (LuckyPot stacks to 10x)",
})

local SPECIALS = { { "AutoSolar", "Solar" }, { "AutoVoid", "Void" }, { "AutoInfinity", "Infinity" }, { "AutoCelestial", "Celestial" } }

local secKeys = TabFarm:AddSection("Keybinds")
secKeys:AddKeybind("KeyFarm", {
    Text = "Farm Toggle (drop + spin)",
    Default = Enum.KeyCode.F,
    Mode = "Toggle",
    Callback = function(active)
        -- writes via handles so the UI toggles move too (never write EZ.Flags directly)
        dropHandle:Set(active)
        spinHandle:Set(active)
        if log then log.Info("Farm keybind: " .. (active and "ON" or "OFF")) end
    end,
})
secKeys:AddKeybind("KeySpecials", {
    Text = "Use One Of Each Special Roll",
    Default = Enum.KeyCode.G,
    Mode = "Toggle",
    Callback = function(active)
        if not active then return end
        for _, pair in ipairs(SPECIALS) do
            local row = Rack:FindFirstChild(pair[2])
            if row and row:FindFirstChild("Count") and parseCount(row.Count.Text) > 0 then
                pcall(fire, row)
                task.wait(1.2)
            end
        end
    end,
})

----------------------------------------------------------------
-- ECONOMY tab
----------------------------------------------------------------
local secZone = TabEconomy:AddSection("Zones")
secZone:AddToggle("AutoBuyZone", { Text = "Auto Buy Next Zone", Default = false })
secZone:AddToggle("AutoBestZone", { Text = "Auto Select Best Zone", Default = false })
secZone:AddToggle("SaveForNextZone", {
    Text = "Save For Next Zone (pause cash spenders near goal)",
    Default = false,
    Tooltip = "Uses your live money/min to stop upgrades + potion buys once the next zone is within reach",
})
secZone:AddSlider("ZoneSaveMinutes", {
    Text = "Start saving within",
    Min = 1, Max = 30, Default = 5, Increment = 1, Suffix = " min",
})
local zoneStatus = secZone:AddParagraph({ Title = "Next Zone", Content = "waiting for scan..." })

local secUpg = TabEconomy:AddSection("Upgrades")
secUpg:AddToggle("AutoUpgrade", { Text = "Auto Upgrade All (upgrades tab)", Default = false })
secUpg:AddToggle("SmartUpgrades", {
    Text = "Smart Priority (droppers/gems/jackpot first)",
    Default = true,
    Tooltip = "Fires Second Dropper, Third Dropper, Shard Finder, Jackpot Value, Double Money before everything else",
})

local secPotion = TabEconomy:AddSection("Potions")
secPotion:AddToggle("AutoBuyPotions", { Text = "Auto Buy Potions (BUY ALL)", Default = false })
secPotion:AddToggle("AutoUsePotions", { Text = "Auto Use Potions (USE ALL)", Default = false })

local secEgg = TabEconomy:AddSection("Pets")
secEgg:AddToggle("AutoEgg", { Text = "Auto Open Nova Pet Egg", Default = false })

local secMastery = TabEconomy:AddSection("Zone Mastery")
secMastery:AddToggle("AutoSpendMastery", { Text = "Auto Spend Mastery Points (cheapest first)", Default = false })

----------------------------------------------------------------
-- ARCADE tab (CommunityOverlay minigames)
----------------------------------------------------------------
local secDrop = TabArcade:AddSection("Precision Drop")
secDrop:AddToggle("AutoPrecision", {
    Text = "Auto Precision Drop (75 gems + 10% boost)",
    Default = false,
    Tooltip = "Stops the light dead-center in the bright zone; ~4.5 min cooldown per challenge",
})

local secMole = TabArcade:AddSection("Nova Whack-a-Mole")
secMole:AddToggle("AutoMole", {
    Text = "Auto Whack-a-Mole (join + hit everything)",
    Default = false,
    Tooltip = "Joins every global round (every 15 min) and whacks lit cells; 8 hits = 150 gems, 16 = 300 gems + Solar roll",
})

local secVault = TabEconomy:AddSection("Ball Vault")
secVault:AddToggle("AutoVaultRolls", {
    Text = "Auto Vault Rolls (25 gems each)",
    Default = false,
    Tooltip = "Converts gems into high-tier balls — pity guarantees Rare+ every 30, Legendary+ every 150",
})
secVault:AddSlider("VaultGemReserve", {
    Text = "Keep gems in reserve",
    Min = 0, Max = 25000, Default = 0, Increment = 25, Suffix = " gems",
})

----------------------------------------------------------------
-- EQUIP tab
----------------------------------------------------------------
local secEq = TabEquip:AddSection("Auto Equip")
secEq:AddToggle("AutoEquipBall", { Text = "Auto Equip Best Ball", Default = false })
secEq:AddToggle("AutoEquipPets", { Text = "Auto Equip Best Pets", Default = false })

local secTitle = TabEquip:AddSection("Titles")
secTitle:AddToggle("AutoRollTitles", { Text = "Auto Roll Titles (native)", Default = false })
secTitle:AddToggle("AutoBestTitle", { Text = "Auto Pick Best Title", Default = false })

----------------------------------------------------------------
-- CLAIMS tab
----------------------------------------------------------------
local secCl = TabClaims:AddSection("Auto Claim")
secCl:AddToggle("ClaimCalendar", { Text = "Auto Claim Calendar (login + playtime)", Default = false })
secCl:AddToggle("ClaimAchievements", { Text = "Auto Claim Achievements + Quests", Default = false })
secCl:AddToggle("ClaimIndex", { Text = "Auto Claim Index Rewards", Default = false })
secCl:AddToggle("AutoLuckyWheel", { Text = "Auto Lucky Wheel (claim + spin)", Default = false })

----------------------------------------------------------------
-- STATS tab
----------------------------------------------------------------
local secLog = TabStats:AddSection("Activity")
log = secLog:AddLog({ Height = 120, MaxLines = 60 })
log.Info("Slam-A-Winner Autoplay loaded")

local secLive = TabStats:AddSection("Live State")
local live = secLive:AddParagraph({ Title = "Snapshot", Content = "waiting for data..." })

local secProfit = TabStats:AddSection("Profit Meter")
local profit = secProfit:AddParagraph({ Title = "Rates", Content = "collecting samples..." })
local secEvents = TabStats:AddSection("Active Events")
local eventsP = secEvents:AddParagraph({ Title = "Event Windows", Content = "none active" })
local secGameStats = TabStats:AddSection("Game Stats (mirrored)")
local gameStatsP = secGameStats:AddParagraph({ Title = "From the game's Statistics tab", Content = "waiting..." })

----------------------------------------------------------------
-- Feature loops
----------------------------------------------------------------

-- Auto drop
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoDrop then
            pcall(fire, Dock.Drop)
        end
        task.wait(math.max(0.15, (EZ.Flags.DropDelay or 0.35)))
    end
end)

-- Auto spin
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoSpin then
            pcall(fire, Dock.Roll)
        end
        task.wait(math.max(0.4, (EZ.Flags.SpinDelay or 1.05)))
    end
end)

-- Event luck detection: what luck multiplier is the server currently giving rolls?
-- Sources: 2x LUCK rotation event, LuckyPot rotation event (stacks 2x-10x via milestones),
-- and admin/global luck multipliers that overlap anything.
local LUCK_2X_EVENT = 2
local function luckEventActive()
    local now = os.time()
    local ls = workspace:GetAttribute("SlamEvent_LuckStartsAt")
    local le = workspace:GetAttribute("SlamEvent_LuckEndsAt")
    if ls and le and now >= ls and now < le then return true end
    State.refresh()
    local gl = State.s and State.s.GlobalLuck
    if gl then
        if type(gl.AdminMultiplier) == "number" and gl.AdminMultiplier > 1
            and type(gl.AdminExpiresAt) == "number" and now < gl.AdminExpiresAt then return true end
        if type(gl.Multiplier) == "number" and gl.Multiplier > 1
            and type(gl.ExpiresAt) == "number" and now < gl.ExpiresAt then return true end
    end
    return false
end

-- Returns the current event luck multiplier (>= 1)
local function currentEventLuck()
    local luck = 1
    if luckEventActive() then luck = LUCK_2X_EVENT end
    State.refresh()
    local pot = State.s and State.s.LuckyPot
    if pot and type(pot.Multiplier) == "number" and pot.Multiplier > 1 then
        local active = true
        local now = os.time()
        if pot.RewardEndsAt and now >= pot.RewardEndsAt then active = false end
        if active and pot.Multiplier > luck then luck = pot.Multiplier end
    end
    return luck
end

-- Per-tier minimum event luck for Smart mode
local TIER_MIN_LUCK = { Solar = 1, Void = 2, Infinity = 4, Celestial = 6 }

-- Special rolls
task.spawn(function()
    local waitingLogged = {}
    while RUNNING do
        if EZ.Flags.AutoSolar or EZ.Flags.AutoVoid or EZ.Flags.AutoInfinity or EZ.Flags.AutoCelestial then
            local mode = EZ.Flags.SpecialsTiming or "Any time"
            local eventLuck = (mode ~= "Any time") and currentEventLuck() or 1
            local rolled = 0
            for _, pair in ipairs(SPECIALS) do
                local flag, name = pair[1], pair[2]
                if EZ.Flags[flag] then
                    local row = Rack:FindFirstChild(name)
                    if row and row:FindFirstChild("Count") and parseCount(row.Count.Text) > 0 then
                        local allowed
                        if mode == "Any time" then
                            allowed = true
                        elseif mode == "Luck events only" then
                            allowed = eventLuck >= 2
                        else -- Smart save (tier-based)
                            allowed = eventLuck >= (TIER_MIN_LUCK[name] or 2)
                        end
                        if allowed then
                            if waitingLogged[name] and log then
                                log.Success(name .. " roll: luck window live (" .. tostring(eventLuck) .. "x) — burning tokens")
                                waitingLogged[name] = nil
                            end
                            botActivity("specials", "burning " .. name .. " roll (luck " .. tostring(eventLuck) .. "x)")
                            pcall(fire, row)
                            rolled = rolled + 1
                            task.wait(1.2)
                        elseif not waitingLogged[name] and log then
                            log.Info(name .. " roll: saving tokens (luck " .. tostring(eventLuck) .. "x, want " .. tostring(TIER_MIN_LUCK[name] or 2) .. "x+)")
                            waitingLogged[name] = true
                        end
                        if not allowed then
                            botActivity("specials", "saving " .. name .. " (luck " .. tostring(eventLuck) .. "x, want " .. tostring(TIER_MIN_LUCK[name] or 2) .. "x+)")
                        end
                    end
                end
            end
            if rolled == 0 then task.wait(3) end
        end
        task.wait(1.5)
    end
end)

-- Zones: buy next (native button) + select best + savings logic — all fired hidden
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoBuyZone or EZ.Flags.AutoBestZone or EZ.Flags.SaveForNextZone then
            pcall(function()
                local list = UI.ZonesOverlay.Card.ZoneList
                local ladder = {}
                for _, z in ipairs(list:GetChildren()) do
                    if z:IsA("Frame") then table.insert(ladder, z) end
                end
                if EZ.Flags.AutoBuyZone then
                    for _, z in ipairs(ladder) do
                        local req = z:FindFirstChild("Requirement")
                        if req and (req.Text == "READY TO UNLOCK" or req.Text == "MONEY NEEDED") then
                            local price = parseMoney(z:FindFirstChild("Price") and z.Price.Text or "")
                            if price and money() >= price then
                                fire(Nav.PurchaseNextZone) -- native button
                                task.wait(0.5)
                                -- fallback: card action if nav button missed it
                                local req2 = z:FindFirstChild("Requirement")
                                if req2 and (req2.Text == "READY TO UNLOCK" or req2.Text == "MONEY NEEDED") and money() >= price then
                                    fire(z:FindFirstChild("Action"))
                                end
                                local zname = z:FindFirstChild("Name") and z.Name.Text or z.Name
                                log.Success("Bought next zone: " .. zname)
                                botActivity("zones", "Bought zone: " .. zname)
                            end
                            break -- only the first ready zone (linear ladder)
                        end
                    end
                end
                if EZ.Flags.AutoBestZone then
                    -- highest owned zone = last card whose Action is SELECT/SELECTED
                    for i = #ladder, 1, -1 do
                        local z = ladder[i]
                        local req = z:FindFirstChild("Requirement")
                        local act = z:FindFirstChild("Action")
                        if req and act and (req.Text == "PURCHASED" or req.Text == "CURRENT ZONE") then
                            if act.Text == "SELECT" then
                                fire(act)
                                log.Success("Selected best zone: " .. (z:FindFirstChild("Name") and z.Name.Text or z.Name))
                            end
                            break
                        end
                    end
                end
                -- savings-mode: ETA from GROSS income (spend-independent) so spending itself
                -- can't mask the time-to-zone. Deadlock guard auto-resumes after 3x threshold.
                ZoneSaving.active = false
                ZoneSaving.name, ZoneSaving.price, ZoneSaving.etaMin = nil, nil, nil
                for _, z in ipairs(ladder) do
                    local req = z:FindFirstChild("Requirement")
                    if req and (req.Text == "READY TO UNLOCK" or req.Text == "MONEY NEEDED") then
                        local name = z:FindFirstChild("Name") and z.Name.Text or z.Name
                        local price = parseMoney(z:FindFirstChild("Price") and z.Price.Text or "")
                        if price then
                            local have = money()
                            local rate = GrossMoneyPerMin
                            if have >= price then
                                botActivity("zones", name .. " affordable — buying now")
                                zoneStatus:Set(string.format("%s — affordable NOW ($%s)", name, tostring(price)))
                            elseif rate > 0 then
                                local etaMin = (price - have) / rate
                                ZoneSaving.name, ZoneSaving.price, ZoneSaving.etaMin = name, price, etaMin
                                local threshold = EZ.Flags.ZoneSaveMinutes or 5
                                if etaMin <= threshold then
                                    ZoneSaving.active = true
                                    if not ZoneSaving.since then ZoneSaving.since = os.clock() end
                                    -- deadlock guard: if saving way longer than it should take, resume spending
                                    if os.clock() - ZoneSaving.since > threshold * 180 then
                                        ZoneSaving.active = false
                                        ZoneSaving.since = nil
                                        botActivity("zones", "savings stalled — resuming spending")
                                        zoneStatus:Set(string.format(
                                            "savings stalled for %s (income dropped) — resuming spending",
                                            name))
                                    else
                                        botActivity("zones", string.format("SAVING for %s — %.1f min left (spenders paused)", name, etaMin))
                                        zoneStatus:Set(string.format(
                                            "SAVING for %s\n$%s / have $%s\n%.1f min at %s/min gross — upgrades + potion buys paused",
                                            name, tostring(price), tostring(have), etaMin, tostring(math.floor(rate))))
                                    end
                                else
                                    ZoneSaving.since = nil
                                    botActivity("zones", string.format("next zone %s in %.1f min — spending freely", name, etaMin))
                                    zoneStatus:Set(string.format(
                                        "%s\n$%s / have $%s (%.1f min at %s/min gross) — spending freely",
                                        name, tostring(price), tostring(have), etaMin, tostring(math.floor(rate))))
                                end
                            else
                                botActivity("zones", "measuring income before zone savings...")
                                zoneStatus:Set(string.format("%s — $%s (measuring income...)", name, tostring(price)))
                            end
                        end
                        break
                    end
                end
                if not ZoneSaving.name and not ZoneSaving.active then
                    ZoneSaving.since = nil
                    zoneStatus:Set("no locked zone ready — spending freely")
                end
            end)
        else
            ZoneSaving.active = false
        end
        task.wait(10)
    end
end)

-- Auto upgrade all: fire every non-maxed, affordable node (server validates cost)
-- Smart priority: droppers + gem income + jackpot first, then the rest
local UPGRADE_PRIORITY = {
    "DualDropper", "ThirdDropper", "GemChance", "JackpotValue", "DoubleMoney",
    "ShinyChance", "HugeChance", "RadiantChance", "BallValue", "Luck", "DropSpeed", "RollSpeed",
}
local function nodePriority(name)
    for i, prefix in ipairs(UPGRADE_PRIORITY) do
        if name:sub(1, #prefix) == prefix then return i end
    end
    return 999
end

-- Nodes carry their own price label ("<NodeName>Price"): "$244.14T" or "Gems 7.5K"
local function nodeAffordable(node)
    local priceLabel = node:FindFirstChild(node.Name .. "Price")
    if not priceLabel then
        for _, c in ipairs(node:GetChildren()) do
            if c:IsA("TextLabel") and c.Name:match("Price$") then priceLabel = c break end
        end
    end
    if not priceLabel then return true end -- can't tell; let the server decide
    local text = priceLabel.Text
    if text:find("MAX") then return false end
    local gnum, gsuf = text:match("Gems%s+([%d%.]+)%s*(%a*)")
    if gnum then
        local v = tonumber(gnum) or 0
        if gsuf and SUFFIX[gsuf] then v = v * SUFFIX[gsuf] end
        return gems() >= v
    end
    local cash = parseMoney(text)
    if cash then return money() >= cash end
    return true
end

task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoUpgrade and not ZoneSaving.active then
            pcall(function()
                local canvas = HUD.UpgradeTree.TreeViewport.Canvas
                local info = HUD.UpgradeTree:FindFirstChild("NodeInfo", true)
                local nodes = {}
                for _, node in ipairs(canvas:GetChildren()) do
                    if node:IsA("TextButton") then
                        local lvl = node:FindFirstChild("Level", true)
                        local go = true
                        if lvl then
                            local a, b = lvl.Text:match("^(%d+)/(%d+)$")
                            if a and b then go = tonumber(a) < tonumber(b) end
                            if lvl.Text:find("MAX") then go = false end
                        end
                        if go and nodeAffordable(node) then table.insert(nodes, node) end
                    end
                end
                if EZ.Flags.SmartUpgrades then
                    table.sort(nodes, function(a, b) return nodePriority(a.Name) < nodePriority(b.Name) end)
                end
                for _, node in ipairs(nodes) do
                    pcall(fire, node)
                end
                if #nodes > 0 then
                    botActivity("upgrades", "fired " .. #nodes .. " upgrade node(s)" .. (#nodes > 0 and (" — priority: " .. nodes[1].Name) or ""))
                else
                    botActivity("upgrades", "no affordable upgrades right now")
                end
            end)
        end
        task.wait(6)
    end
end)

-- Keep upgrade popups hidden while auto-upgrading: the NodeInfo card AND the game's
-- UpgradeHelp tips ("Potion Extension — Gems 10K...") which pop on first touch of each node type
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoUpgrade then
            pcall(function()
                local info = HUD.UpgradeTree:FindFirstChild("NodeInfo", true)
                if info and info.Visible then info.Visible = false end
                -- UpgradeHelpOverlay is a sibling of SlamAWinnerUI (directly under PlayerGui)
                local help = lp.PlayerGui:FindFirstChild("UpgradeHelpOverlay")
                if help then
                    if help.Enabled then help.Enabled = false end
                    local tip = help:FindFirstChild("UpgradeTip", true)
                    if tip and tip.Visible then tip.Visible = false end
                end
            end)
        end
        task.wait(0.15)
    end
end)

-- Lazy access: the Arcade panel only exists after the Community overlay's ArcadeTab opened once
local function ensureArcade()
    local cov = UI:FindFirstChild("CommunityOverlay")
    if not cov or not cov:FindFirstChild("Card") then return nil end
    local body = cov.Card:FindFirstChild("Body")
    local arcade = body and body:FindFirstChild("Arcade")
    if not arcade or not arcade:FindFirstChild("TimingGame") then
        fire(Nav.Community)
        task.wait(0.4)
        cov = UI:FindFirstChild("CommunityOverlay")
        if cov and cov:FindFirstChild("Card") then
            for _, d in ipairs(cov.Card:GetChildren()) do
                if d:IsA("TextButton") and d.Name == "ArcadeTab" then fire(d) break end
            end
        end
        task.wait(0.4)
        body = cov.Card:FindFirstChild("Body")
        arcade = body and body:FindFirstChild("Arcade")
    end
    return arcade
end

-- Auto Precision Drop: strict state machine — one challenge at a time, no spam
task.spawn(function()
    local phase = "idle"
    while RUNNING do
        if EZ.Flags.AutoPrecision then
            pcall(function()
                local arcade = ensureArcade()
                if not arcade then return end
                local tg = arcade:FindFirstChild("TimingGame")
                local action = tg and tg:FindFirstChild("TimingAction")
                if not action then return end
                local txt = action.Text
                local track, light, target = tg.TimingTrack, tg.TimingTrack.Light, tg.TimingTrack.Target
                local tStart, tSize = target.Position.X.Scale, target.Size.X.Scale

                if txt:find("READY IN") then
                    phase = "idle"
                    botActivity("precision", "cooldown: " .. txt)
                    return
                end
                if txt:find("GET READY") or txt:find("STOP") then
                    -- challenge in flight (ours or manual) — follow the sweep
                    if phase ~= "sweep" then phase = "sweep" end
                    local deadline = os.clock() + 12
                    local hit = false
                    local lastS, lastT, speed = nil, nil, 0.8
                    while os.clock() < deadline and RUNNING do
                        local t = action.Text
                        if t:find("READY IN") then break end -- challenge ended (someone else finished it)
                        local s = light.Position.X.Scale
                        local now = os.clock()
                        if lastS then
                            speed = speed * 0.5 + (math.abs(s - lastS) / math.max(now - lastT, 0.016)) * 0.5
                        end
                        lastS, lastT = s, now
                        -- fire once: projected into zone center, or edge-save before exiting
                        if (s + speed * 0.06 >= tStart + tSize * 0.5 and s >= tStart)
                            or (s >= tStart + tSize * 0.8 and s <= tStart + tSize) then
                            fire(action)
                            hit = true
                            botActivity("precision", "stopped the light in the zone — reward incoming")
                            log.Success("Precision Drop: stopped in the bright zone")
                            break
                        end
                        task.wait()
                    end
                    phase = "cooldown-wait"
                    -- wait for cooldown text (max 20s) so we never double-fire
                    local w = 0
                    while w < 20 and RUNNING do
                        if action.Text:find("READY IN") then break end
                        task.wait(0.5); w = w + 0.5
                    end
                    phase = "idle"
                    if not hit then botActivity("precision", "challenge ended without our stop") end
                    return
                end
                -- ready state (whatever the label is): start the challenge
                fire(action)
                botActivity("precision", "challenge started — waiting for sweep")
                task.wait(1.5) -- GET READY phase; loop continues into the sweep branch next tick
            end)
            task.wait(0.5)
        else
            if phase ~= "idle" then phase = "idle" end
            task.wait(2)
        end
    end
end)

-- Auto Whack-a-Mole: "WAITING FOR NEXT ROUND" IS the join button (fire it to queue),
-- and during a live round every cell press is token-gated server-side, so pressing
-- all 9 cells is safe: the game only scores the one that's actually lit.
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoMole then
            pcall(function()
                local arcade = ensureArcade()
                if not arcade then return end
                local mg = arcade:FindFirstChild("MoleGame")
                local enter = mg:FindFirstChild("EnterRound")
                local grid = mg:FindFirstChild("MoleGrid")
                local invite = lp.PlayerGui:FindFirstChild("ArcadeInvite")
                if not enter or not grid then return end
                local txt = enter.Text
                local joined = txt:find("ROUND JOINED") ~= nil
                local roundLive = (invite and invite.Visible)
                    or (mg.RoundInfo.Text:find("NEXT GLOBAL ROUND") == nil)
                -- AUTO-JOIN: press join whenever we're not queued and no round is live
                if not joined and not roundLive then
                    fire(enter)
                    botActivity("mole", "joining the next round...")
                    task.wait(1)
                    -- recheck: press once more if the first didn't stick
                    if mg.EnterRound.Text:find("ROUND JOINED") == nil then
                        fire(mg.EnterRound)
                        task.wait(1)
                    end
                    return
                end
                -- WHACK: only while queued, only while a live-round signal is present
                if joined and roundLive then
                    local pressed = 0
                    for i = 1, 9 do
                        local cell = grid:FindFirstChild("Cell" .. i)
                        if cell then
                            fire(cell)
                            pressed = pressed + 1
                        end
                    end
                    if pressed > 0 then
                        botActivity("mole", "round live — pressing all cells (" .. (mg.Score and mg.Score.Text or "?") .. ")")
                    end
                elseif joined then
                    botActivity("mole", "queued — waiting for round (" .. mg.RoundInfo.Text .. ")")
                end
            end)
            task.wait(0.15) -- fast poll while rounds run
        else
            task.wait(2)
        end
    end
end)

-- Auto vault rolls: convert gems into high-tier balls
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoVaultRolls then
            pcall(function()
                local vault = HUD.CategoryPanel.Content.Shop.ShopList.BallVault
                local open = vault and vault:FindFirstChild("Open")
                local reserve = EZ.Flags.VaultGemReserve or 0
                local rolls = 0
                while gems() >= 25 + reserve and rolls < 10 do
                    fire(open)
                    rolls = rolls + 1
                    task.wait(1.5)
                end
                if rolls > 0 then
                    log.Success("Vault: " .. rolls .. " roll(s) opened")
                    botActivity("vault", "rolled vault x" .. rolls .. " (gems left: " .. gems() .. ")")
                else
                    botActivity("vault", "waiting for gems (" .. gems() .. "/25)")
                end
            end)
        end
        task.wait(5)
    end
end)

-- Auto buy potions (BUY ALL when affordable)
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoBuyPotions and not ZoneSaving.active then
            pcall(function()
                local shop = HUD.PotionShop
                local buyAll = shop:FindFirstChild("BuyAll")
                if buyAll then
                    local cost = parseMoney(buyAll.Text) -- "BUY ALL (5) • $775K"
                    if cost and money() >= cost then
                        fire(buyAll)
                        botActivity("potions", "bought potion offers ($" .. tostring(cost) .. ")")
                        log.Info("Bought potion offers ($" .. tostring(cost) .. ")")
                    else
                        botActivity("potions", ZoneSaving.active and "paused for zone savings" or "waiting — offers cost $" .. tostring(cost or "?"))
                    end
                end
            end)
        end
        task.wait(15)
    end
end)

-- Auto use potions (USE ALL, hidden fire)
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoUsePotions then
            pcall(function()
                fire(UI.InventoryOverlay.Card:FindFirstChild("UseAllPotions"))
                botActivity("usepotions", "used all usable potions")
            end)
        end
        task.wait(20)
    end
end)

-- Auto open nova eggs
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoEgg then
            pcall(function()
                local count = Dock.NovaPetEgg:FindFirstChild("Count")
                if count and parseCount(count.Text) > 0 then
                    fire(HUD.NovaEggMenu:FindFirstChild("Hatch", true))
                    botActivity("egg", "hatched Nova egg (" .. count.Text .. " left)")
                end
            end)
        end
        task.wait(2)
    end
end)

-- Auto equip best ball (hidden fire)
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoEquipBall then
            pcall(function()
                fire(UI.InventoryOverlay.Card:FindFirstChild("EquipBest"))
            end)
        end
        task.wait(6)
    end
end)

-- Auto equip best pets: click "EQUIP SLOT n" on the highest-multiplier owned card (hidden fire)
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoEquipPets then
            pcall(function()
                local pets = UI.InventoryOverlay.Card:FindFirstChild("Pets")
                if not pets then return end
                -- switch to pets tab so card state is fresh (hidden)
                for _, d in ipairs(UI.InventoryOverlay.Card:GetChildren()) do
                    if d:IsA("TextButton") and d.Name == "PetsTab" then fire(d) break end
                end
                task.wait(0.25)
                -- rank cards by their "1.75× Money" bonus
                local cards = {}
                for _, c in ipairs(pets:GetChildren()) do
                    if c:IsA("Frame") then
                        local bonus = c:FindFirstChild("Bonus", true)
                        local mult = bonus and tonumber(bonus.Text:match("([%d%.]+)%s*×%s*Money") or bonus.Text:match("([%d%.]+)%s*%*%s*Money")) or 0
                        table.insert(cards, { card = c, mult = mult })
                    end
                end
                table.sort(cards, function(a, b) return a.mult > b.mult end)
                for slot = 1, 2 do
                    for _, entry in ipairs(cards) do
                        local eq = entry.card:FindFirstChild("Equip")
                        if eq and eq.Text == "EQUIP SLOT " .. slot then
                            fire(eq)
                            log.Success("Equipped pet (" .. tostring(entry.mult) .. "x) to slot " .. slot)
                            break
                        end
                    end
                end
            end)
        end
        task.wait(10)
    end
end)

-- Titles: native auto-roll + best-title equip
local function titleBonusSum(text)
    local sum = 0
    for pct in type(text) == "string" and text:gmatch("(%d+)%%") or function() end do
        sum = sum + tonumber(pct)
    end
    return sum
end

task.spawn(function()
    while RUNNING do
        pcall(function()
            local tc = HUD.TitleCollection
            local autoRoll = tc.RollStage:FindFirstChild("AutoRoll")
            if autoRoll then
                local isOn = autoRoll.Text:find("ON") ~= nil
                if EZ.Flags.AutoRollTitles ~= isOn then fire(autoRoll) end
            end
        end)
        task.wait(2)
    end
end)

task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoBestTitle then
            pcall(function()
                local tc = HUD.TitleCollection
                local rollStage, list = tc.RollStage, tc.TitleList
                -- rank owned title cards by total bonus %
                local cards = {}
                for _, c in ipairs(list:GetChildren()) do
                    if c:IsA("Frame") then
                        local bonus = c:FindFirstChild("Bonus")
                        local eq = c:FindFirstChild("Equip")
                        if bonus and eq then
                            table.insert(cards, { card = c, score = titleBonusSum(bonus.Text) })
                        end
                    end
                end
                table.sort(cards, function(a, b) return a.score > b.score end)
                -- equip best remaining title into each unlocked slot
                for slot = 1, 3 do
                    local slotBtn = rollStage:FindFirstChild("TitleSlot" .. slot)
                    if slotBtn and not slotBtn.Text:find("LOCKED") and slotBtn.Text ~= "" then
                        fire(slotBtn) -- select slot
                        task.wait(0.15)
                        for _, entry in ipairs(cards) do
                            local eq = entry.card:FindFirstChild("Equip")
                            if eq and eq.Text ~= "EQUIPPED" and entry.score > 0 then
                                fire(eq)
                                log.Success("Equipped title (" .. entry.score .. "%) to slot " .. slot)
                                break
                            end
                        end
                    end
                end
            end)
        end
        task.wait(15)
    end
end)

-- Claims: calendar (login + playtime), achievements/quests, index rewards
-- All fired hidden; each claim is retried once if the button text doesn't flip.
local function claimByText(root, exact)
    local n = 0
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("TextButton") and d.Name == "Claim" then
            if d.Text == (exact or "CLAIM") then
                if pcall(fire, d) then n = n + 1 end
            end
        end
    end
    return n
end

local function claimWithRetry(root)
    local first = claimByText(root, "CLAIM")
    if first > 0 then
        task.wait(0.5)
        -- retry whatever didn't flip
        local again = claimByText(root, "CLAIM")
        return first, again
    end
    return 0, 0
end

task.spawn(function()
    while RUNNING do
        if EZ.Flags.ClaimCalendar then
            pcall(function()
                local n = claimByText(HUD.CalendarMenu, "CLAIM")
                if n > 0 then
                    task.wait(0.5)
                    claimByText(HUD.CalendarMenu, "CLAIM")
                    log.Success("Calendar: claimed " .. n .. " reward(s)")
                    botActivity("claims", "claimed " .. n .. " calendar reward(s)")
                end
            end)
        end
        task.wait(20)
    end
end)

task.spawn(function()
    while RUNNING do
        if EZ.Flags.ClaimAchievements then
            pcall(function()
                local ov = UI.AchievementsOverlay
                -- visit every tab so its claim rows refresh, claiming as we go (hidden)
                for _, d in ipairs(ov.Card:GetDescendants()) do
                    if d:IsA("TextButton") and d.Name:match("Tab$") then fire(d) end
                end
                task.wait(0.3)
                local n = claimByText(ov, "CLAIM")
                if n > 0 then
                    task.wait(0.5)
                    claimByText(ov, "CLAIM")
                    log.Success("Achievements: claimed " .. n)
                    botActivity("claims", "claimed " .. n .. " achievement/quest reward(s)")
                end
            end)
        end
        task.wait(30)
    end
end)

task.spawn(function()
    while RUNNING do
        if EZ.Flags.ClaimIndex then
            pcall(function()
                -- Index claimables read "CLAIM BOOSTS" (higher set bonus), not "CLAIM".
                -- "COMPLETE SET" rows are INCOMPLETE sets (instruction, nothing to claim).
                for _, d in ipairs(UI.IndexOverlay.Card:GetChildren()) do
                    if d:IsA("TextButton") and (d.Name == "RewardsTab" or d.Name == "CompletedTab") then fire(d) end
                end
                task.wait(0.3)
                local function claimAll()
                    local n = 0
                    for _, d in ipairs(UI.IndexOverlay:GetDescendants()) do
                        if d:IsA("TextButton") and d.Name == "Claim" then
                            local t = d.Text
                            if t ~= "" and t ~= "Already Claimed" and t ~= "COMPLETE SET" and t ~= "LOCKED" then
                                if pcall(fire, d) then n = n + 1 end
                            end
                        end
                    end
                    return n
                end
                local n = claimAll()
                if n > 0 then
                    task.wait(0.8)
                    claimAll() -- retry pass for anything that didn't flip
                    log.Success("Index: claimed " .. n .. " reward set(s) (+2% perm luck & money each)")
                    botActivity("claims", "claimed " .. n .. " index reward set(s)")
                end
            end)
        end
        task.wait(40)
    end
end)

-- Live state monitor
task.spawn(function()
    while RUNNING do
        State.refresh()
        local s = State.s
        if s then
            local tokens = {}
            for _, name in ipairs({ "Solar", "Void", "Infinity", "Celestial" }) do
                local row = Rack:FindFirstChild(name)
                if row then tokens[#tokens + 1] = name:sub(1, 3) .. " " .. tostring(parseCount(row.Count.Text)) end
            end
            live:Set(string.format(
                "Money: %d\nGems: %d\nDrops: %d\nJackpots: %d\nZone: %s (unlocked %d)\nBall: %s\nMultiplier: x%.1f\nBest odds: 1 / %.2e\nRolls: %d\nTokens: %s",
                tonumber(s.Money) or money(), tonumber(s.Gems) or gems(),
                tonumber(s.Drops) or 0, tonumber(s.Jackpots) or 0,
                tostring(s.Zone), tonumber(s.UnlockedZones) or 0,
                tostring(s.EquippedBall), tonumber(s.TotalMoneyMultiplier) or 0,
                tonumber(s.BestRollOdds) or 0, tonumber(s.RngRolls) or 0,
                table.concat(tokens, "  ")
            ))
        end
        stMoney:Set("Money: " .. tostring(money()))
        stGems:Set("Gems: " .. tostring(gems()))
        task.wait(3)
    end
end)

-- Auto lucky wheel: claim earned spins, then spin
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoLuckyWheel then
            pcall(function()
                State.refresh()
                local lw = State.s and State.s.LuckyWheel
                local overlay = lp.PlayerGui:FindFirstChild("LuckyWheelOverlay")
                if not overlay then return end
                local claimBtn = overlay:GetDescendants() and (function()
                    for _, d in ipairs(overlay:GetDescendants()) do
                        if d:IsA("TextButton") and d.Name == "ClaimSpins" then return d end
                    end
                end)()
                local spinBtn
                for _, d in ipairs(overlay:GetDescendants()) do
                    if d:IsA("TextButton") and d.Name == "Spin" then spinBtn = d break end
                end
                if lw and type(lw.Ready) == "number" and lw.Ready > 0 and claimBtn then
                    fire(claimBtn)
                    log.Success("Lucky wheel: claimed spins")
                    task.wait(1)
                end
                if lw and type(lw.Spins) == "number" and lw.Spins > 0 and spinBtn then
                    fire(spinBtn)
                    log.Info("Lucky wheel: spinning")
                    task.wait(5) -- wheel animation
                end
            end)
        end
        task.wait(10)
    end
end)

-- Auto spend mastery points (cheapest first)
task.spawn(function()
    while RUNNING do
        if EZ.Flags.AutoSpendMastery then
            pcall(function()
                local zm = HUD:FindFirstChild("ZoneMasteryMenu")
                if not zm then return end
                local value = zm:FindFirstChild("Value", true)
                local spent = 0
                for _ = 1, 40 do -- safety cap
                    local pts = value and tonumber(value.Text:match("(%d+)%s*POINTS")) or nil
                    if not pts or pts <= 0 then break end
                    -- collect affordable buy buttons, cheapest first
                    local buys = {}
                    for _, b in ipairs(zm:GetDescendants()) do
                        if b:IsA("TextButton") and b.Name == "Buy" then
                            local cost = tonumber(b.Text:match("(%d+)%s*PT"))
                            if cost and cost <= pts then table.insert(buys, { btn = b, cost = cost }) end
                        end
                    end
                    if #buys == 0 then break end
                    table.sort(buys, function(a, b2) return a.cost < b2.cost end)
                    fire(buys[1].btn)
                    spent = spent + 1
                    task.wait(0.8)
                end
                if spent > 0 then log.Success("Mastery: bought " .. spent .. " upgrade(s)") end
            end)
        end
        task.wait(30)
    end
end)

-- Event watcher: workspace attributes carry server event windows
do
    local lastIds = {}
    task.spawn(function()
        while RUNNING do
            local active = {}
            local now = os.time()
            pcall(function()
                local found = {}
                for k, v in pairs(workspace:GetAttributes()) do
                    local ev, kind = k:match("^SlamEvent_(%w+)(StartsAt)$")
                    if ev and kind then found[ev] = { start = v } end
                end
                for ev, t in pairs(found) do
                    local endsAt = workspace:GetAttribute("SlamEvent_" .. ev .. "EndsAt")
                    local id = workspace:GetAttribute("SlamEvent_" .. ev .. "Id")
                    if endsAt and now < endsAt and now >= (t.start or 0) then
                        local mins = math.floor((endsAt - now) / 60)
                        active[#active+1] = ev .. " (" .. math.floor(mins / 60) .. "h " .. (mins % 60) .. "m left)"
                        if lastIds[ev] ~= id then
                            lastIds[ev] = id
                            EZ:Notify({ Title = ev .. " event started!", Content = "Active for the next window — farm now.", Duration = 6, Type = "success" })
                        end
                    end
                end
                -- global money multiplier
                local gmMult = workspace:GetAttribute("SlamGlobalMoneyMultiplier")
                local gmExp = workspace:GetAttribute("SlamGlobalMoneyExpiresAt")
                if gmMult and gmExp and now < gmExp then
                    active[#active+1] = "Global " .. tostring(gmMult) .. "x Money (" .. math.floor((gmExp - now) / 60) .. "m left)"
                end
                -- LuckyPot: rotation event, server pot stacks to 10x
                State.refresh()
                local pot = State.s and State.s.LuckyPot
                if pot then
                    local potNow = os.time()
                    local potEnd = pot.RewardEndsAt or pot.EndsAt
                    local within = not potEnd or potNow < potEnd
                    if within and type(pot.Multiplier) == "number" and pot.Multiplier > 1 then
                        active[#active+1] = "LUCKY POT " .. tostring(pot.Multiplier) .. "x luck"
                        if lastIds.__luckyPot ~= pot.Id then
                            lastIds.__luckyPot = pot.Id
                            EZ:Notify({ Title = "Lucky Pot is building!", Content = "Pot luck at " .. tostring(pot.Multiplier) .. "x — save Infinity/Celestial rolls.", Duration = 6, Type = "info" })
                        end
                    end
                end
            end)
            eventsP:Set(#active > 0 and table.concat(active, "\n") or "none active")
            task.wait(5)
        end
    end)
end

-- Profit meter: rolling money/drop rates
task.spawn(function()
    local last = nil
    while RUNNING do
        pcall(function()
            local now = os.clock()
            local sample = {
                t = now,
                money = money(),
                drops = lp.leaderstats and lp.leaderstats.Drops.Value or 0,
            }
            if last and now - last.t >= 5 then
                local dt = now - last.t
                local mRate = (sample.money - last.money) / dt * 60
                local dRate = (sample.drops - last.drops) / dt * 60
                if mRate >= 0 then
                    MoneyPerMin = MoneyPerMin > 0 and (MoneyPerMin * 0.5 + mRate * 0.5) or mRate
                end
                profit:Set(string.format(
                    "Money: %s/min\nDrops: %.1f/min\nLast window: +%s over %ds",
                    (mRate >= 0 and "+" or "") .. tostring(math.floor(mRate)),
                    dRate,
                    tostring(math.floor(sample.money - last.money)),
                    math.floor(dt)
                ))
                last = sample
            elseif not last then
                last = sample
            end
        end)
        task.wait(15)
    end
end)

-- Game statistics mirror: read the game's own live Statistics overlay values
-- Also derives GROSS money/min from "Total money earned" (lifetime, unaffected by spending)
do
    local lastGross = nil -- {t, total}
    local function parseTotal(text)
        if type(text) ~= "string" then return nil end
        local num = text:gsub("[,%$]", "")
        return tonumber(num)
    end
    task.spawn(function()
        while RUNNING do
            pcall(function()
                local ov = UI.StatisticsOverlay
                local pairsFound = {}
                local lifetimeText = nil
                for _, d in ipairs(ov:GetDescendants()) do
                    if d:IsA("TextLabel") and d.Name == "Label" then
                        local val = d.Parent and d.Parent:FindFirstChild("Value")
                        if val and val:IsA("TextLabel") then
                            pairsFound[#pairsFound+1] = d.Text:gsub("\n", " ") .. ": " .. val.Text:gsub("\n", " ")
                            if d.Text == "Total money earned" then lifetimeText = val.Text end
                        end
                    end
                end
                if #pairsFound > 0 then
                    gameStatsP:Set(table.concat(pairsFound, "\n"))
                end
                if lifetimeText then
                    local total = parseTotal(lifetimeText)
                    if total then
                        local now = os.clock()
                        if lastGross and now - lastGross.t >= 15 then
                            local rate = (total - lastGross.total) / (now - lastGross.t) * 60
                            if rate >= 0 then
                                GrossMoneyPerMin = GrossMoneyPerMin > 0 and (GrossMoneyPerMin * 0.4 + rate * 0.6) or rate
                            end
                            lastGross = { t = now, total = total }
                        elseif not lastGross or now - lastGross.t > 60 then
                            lastGross = { t = now, total = total }
                        end
                    end
                end
            end)
            task.wait(5)
        end
    end)
end

-- Main dashboard renderer: live "what is the bot doing" + per-feature states
task.spawn(function()
    while RUNNING do
        pcall(function()
            -- current action = freshest activity entry
            local best, bestT, bestKey = nil, 0, nil
            for key, e in pairs(Bot.last) do
                if e.t > bestT then best, bestT, bestKey = e, e.t, key end
            end
            if best then
                activityP:Set(best.text .. "\n(" .. math.max(0, math.floor(os.clock() - best.t)) .. "s ago — " .. bestKey .. ")")
            else
                activityP:Set("idle — waiting for targets")
            end
            -- feature states
            local function st(flag, onText, offText, detail)
                if EZ.Flags[flag] then
                    return onText .. (detail and (" — " .. detail) or "")
                end
                return offText or "off"
            end
            local lines = {}
            lines[#lines+1] = "Drop: " .. st("AutoDrop", "ON", nil, "every " .. string.format("%.2f", EZ.Flags.DropDelay or 0.35) .. "s")
            lines[#lines+1] = "Spin: " .. st("AutoSpin", "ON", nil, "every " .. string.format("%.2f", EZ.Flags.SpinDelay or 1.05) .. "s")
            local spParts = {}
            for _, pair in ipairs(SPECIALS) do
                if EZ.Flags[pair[1]] then spParts[#spParts+1] = pair[2] end
            end
            if #spParts > 0 then
                local mode = EZ.Flags.SpecialsTiming or "Any time"
                local detail = Bot.last.specials and Bot.last.specials.text or mode
                lines[#lines+1] = "Specials (" .. table.concat(spParts, "/") .. "): ON — " .. detail
            else
                lines[#lines+1] = "Specials: off"
            end
            lines[#lines+1] = "Upgrades: " .. st("AutoUpgrade", "ON" .. (EZ.Flags.SmartUpgrades and " (smart)" or ""), nil,
                ZoneSaving.active and "PAUSED — saving for zone" or (Bot.last.upgrades and Bot.last.upgrades.text or "scanning"))
            lines[#lines+1] = "Buy Potions: " .. st("AutoBuyPotions", "ON", nil,
                ZoneSaving.active and "PAUSED — saving for zone" or (Bot.last.potions and Bot.last.potions.text or "watching shop"))
            lines[#lines+1] = "Use Potions: " .. st("AutoUsePotions", "ON", nil, Bot.last.usepotions and Bot.last.usepotions.text or "watching inventory")
            lines[#lines+1] = "Vault: " .. st("AutoVaultRolls", "ON", nil, Bot.last.vault and Bot.last.vault.text or "watching gems")
            lines[#lines+1] = "Nova Eggs: " .. st("AutoEgg", "ON", nil, Bot.last.egg and Bot.last.egg.text or "watching eggs")
            lines[#lines+1] = "Zones: " .. st("AutoBuyZone", "ON", nil, Bot.last.zones and Bot.last.zones.text or "scanning")
            lines[#lines+1] = "Best Zone Select: " .. st("AutoBestZone", "ON")
            lines[#lines+1] = "Equip Ball: " .. st("AutoEquipBall", "ON")
            lines[#lines+1] = "Equip Pets: " .. st("AutoEquipPets", "ON")
            lines[#lines+1] = "Title Roll: " .. st("AutoRollTitles", "ON")
            lines[#lines+1] = "Best Title: " .. st("AutoBestTitle", "ON")
            lines[#lines+1] = "Calendar: " .. st("ClaimCalendar", "ON")
            lines[#lines+1] = "Achievements: " .. st("ClaimAchievements", "ON")
            lines[#lines+1] = "Index: " .. st("ClaimIndex", "ON")
            lines[#lines+1] = "Lucky Wheel: " .. st("AutoLuckyWheel", "ON")
            lines[#lines+1] = "Mastery: " .. st("AutoSpendMastery", "ON")
            lines[#lines+1] = "Precision Drop: " .. st("AutoPrecision", "ON", nil, Bot.last.precision and Bot.last.precision.text or "watching cooldown")
            lines[#lines+1] = "Whack-a-Mole: " .. st("AutoMole", "ON", nil, Bot.last.mole and Bot.last.mole.text or "waiting for round")
            lines[#lines+1] = "Anti-AFK: " .. st("AntiAFK", "ON")
            featuresP:Set(table.concat(lines, "\n"))
        end)
        task.wait(0.5)
    end
end)

----------------------------------------------------------------
-- Final wiring (AFTER every element exists)
----------------------------------------------------------------
-- QuickBar: floating dock with your most-used toggles, visible while the window is hidden
pcall(function()
    QuickBar:Pin("AutoDrop", { Icon = "crosshair" })
    QuickBar:Pin("AutoSpin", { Icon = "target" })
    QuickBar:Pin("AutoPrecision", { Icon = "crosshair" })
    QuickBar:Pin("AutoMole", { Icon = "hammer" })
    QuickBar:PinButton("Panic Off", { Icon = "octagon-x", Callback = function()
        EZ:SetPanic(false)
    end })
end)

-- Config autoload: restores your saved toggles/configs on launch
pcall(function() SaveManager:LoadAutoloadConfig() end)

----------------------------------------------------------------
-- Shutdown
----------------------------------------------------------------
EZ:OnDestroy(function()
    RUNNING = false
    setAntiAFK(false) -- restore idle kick handlers on unload
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHistory:Destroy() end)
end)
getgenv().__SLAM_AUTOPLAY_LOADED = true
getgenv().__SLAM_AUTOPLAY_EZ = EZ
getgenv().__SLAM_AUTOPLAY_DESTROY = function() pcall(function() EZ:Destroy() end) end
