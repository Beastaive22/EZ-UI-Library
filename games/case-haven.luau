-- Game guard: this module only runs in its own game.
-- game.GameId is the universe id (10141042381), so every place in that
-- game matches. Anywhere else (autoexec, a shared hub, a wrong map
-- entry) it exits before touching anything.
if game.GameId ~= 10141042381 then return end

--[[
    Case Haven Auto Spin
    Built on EZ-UI-Library (https://github.com/Beastaive22/EZ-UI-Library)
    Executor: Potassium / sUNC

    Case Haven is a CS:GO-style case opening game. Every crate in the game
    is a StringValue under ReplicatedStorage.Cases (97 of them at the time
    of writing, from "Free Case" to "Katowice 2014 Legends Capsule"), and
    rolling one is a single call to the game's main remote:

        Remotes.MainEvent:FireServer("OpenCase", <case name>, <amount>)

    This is exactly what the game's own client sends —
    MainEvent:FireServer("OpenCase", OpenCase.Case.Value, OpenCase.Amount.Value)
    — with amount 1.

    The script shows every case in one searchable multi-select dropdown
    (read live from the Cases folder, so new cases show up on their own),
    sorted by price, cheapest first. Select the cases you want and the
    loop rolls each of them once per delay tick, `amount` copies per fire
    — the amount slider sets the number at the end of the OpenCase
    payload, and the game's own client sends the same field (its
    OpenCase.Amount). A main toggle arms rolling: nothing is sent while
    it is off. A separate toggle also rolls the highest Level N Case your
    level has unlocked (the level crates unlock at level N; the game's
    own active-case tracker matches the same rule). Another toggle rolls
    the most expensive crate the wallet covers at the current amount
    (price * amount <= wallet), so raising the amount automatically
    steps down to a cheaper crate. The Zones tab auto-buys the next
    zone: it watches the player's Zones BoolValues for the lowest
    unowned zone, reads its price from the streamed zone part
    (workspace.Zones.<n>.Cost, cached once the part streams in) and
    fires BuyZone the moment the wallet covers it. The same tab can
    auto-teleport to the highest owned zone (on enable and whenever a
    better zone unlocks). A Claims tab auto-claims daily quests (ready
    ones via CHDailyQuestRequest), case masteries (via the game's own
    CHCaseMasteryConfig.CanClaim check) and time rewards (TodaysItems
    past their 6-minute mark). An Upgrades tab auto-buys available
    upgrade-tree nodes straight through MainFunction:InvokeServer (the
    exact call the tree's buy buttons make) - no menu opening, camera
    movement or game UI effects; priority upgrades selected in a
    searchable dropdown are bought first, the rest cheapest first.
    Nothing else.

    A case's cost is the Price NumberValue on its StringValue; prices are
    formatted with the game's own MoneyFormatter module (K/M/B/T compact
    notation, two decimals below 1000).

    The server still enforces what it always enforced — a roll on a case
    you cannot afford or with a full inventory is refused on the server
    side (the game's own client shows "Not Enough Money!" / "Inventory
    Full!"), so a selected case you cannot afford simply does nothing.

    Nothing is selected by default and the main toggle defaults off, so
    loading the script is inert until you arm it and pick cases.

    Toggle UI: RightShift
]]

local game = game
local getgenv = getgenv

print("[CH-AUTOSPIN] starting")
if getgenv().__CH_AUTOSPIN_LOADED then
    pcall(function() getgenv().__CH_AUTOSPIN_DESTROY() end)
end

----------------------------------------------------------------
-- Library (canonical EZ-UI-Library setup)
----------------------------------------------------------------
local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local EZ = loadstring(game:HttpGet(repo .. "Library.lua"))()
local Icons = loadstring(game:HttpGet(repo .. "addons/Icons.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()

EZ:SetIcons(Icons)
SaveManager:Bind(EZ, "CaseHavenAutoSpinConfigs")
ThemeManager:Bind(EZ, { File = "CaseHavenAutoSpin_Theme.txt" })
ThemeManager:LoadSaved() -- apply saved theme before the window builds: no colour flash
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

----------------------------------------------------------------
-- Runtime handles
----------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cases = ReplicatedStorage:WaitForChild("Cases")
local MainEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MainEvent")
local lp = game:GetService("Players").LocalPlayer
local PlayerZones = lp:WaitForChild("Zones")      -- BoolValue per zone: true = owned
local ZoneParts = workspace:WaitForChild("Zones") -- streamed zone parts carrying Cost/Luck
local CHDailyQuestRequest = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CHDailyQuestRequest")
local CHCaseMasteryRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CHCaseMasteryRemote")
local QuestFolder = lp:WaitForChild("DailyQuests"):WaitForChild("Quests")
local ClaimedMasteries = lp:WaitForChild("ClaimedCaseMasteries")

-- The game's own eligibility logic for case mastery claims (which cases
-- count, which are excluded); used verbatim so the script never claims
-- something the game's UI would refuse.
local MasteryConfig
pcall(function() MasteryConfig = require(ReplicatedStorage.Modules.CHCaseMasteryConfig) end)

local MainFunction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MainFunction")
local RsUpgrades = ReplicatedStorage:WaitForChild("Upgrades")
local PlayerUpgrades = lp:WaitForChild("Upgrades")

local RUNNING = true
local enabled = {} -- [case name] = true for every case selected in the dropdown

-- Price formatting: prefer the game's own MoneyFormatter, fall back to a
-- minimal K/M/B/T compactor with the same shape.
local Formatter
pcall(function() Formatter = require(ReplicatedStorage.Modules.MoneyFormatter) end)

local function fmtPrice(n)
    if n == math.huge then return "?" end
    if Formatter then
        -- MoneyFormatter.Format is a method: Format(self, number)
        local ok, s = pcall(function() return Formatter:Format(n) end)
        if ok and type(s) == "string" then return s end
    end
    if n >= 1e12 then
        return string.format("%.2fT", n / 1e12)
    elseif n >= 1e9 then
        return string.format("%.2fB", n / 1e9)
    elseif n >= 1e6 then
        return string.format("%.2fM", n / 1e6)
    elseif n >= 1000 then
        return string.format("%.2fK", n / 1000)
    end
    return string.format("%.2f", n)
end

----------------------------------------------------------------
-- Level crates (unlock as you level)
----------------------------------------------------------------
-- "Level N Case" crates unlock at level N: the game's own active-case
-- tracker matches the highest N <= your level (level 65 -> "Level 60
-- Case"). Collected live so new level crates show up on their own.
local levelCrates = {}
for _, case in ipairs(Cases:GetChildren()) do
    local lvl = case.Name:match("^Level (%d+) Case$")
    if lvl then
        levelCrates[#levelCrates + 1] = { level = tonumber(lvl), name = case.Name }
    end
end
table.sort(levelCrates, function(a, b) return a.level < b.level end)

local function highestUnlockedLevelCrate()
    local levelChild = lp:FindFirstChild("Level")
    local level = levelChild and levelChild:IsA("NumberValue") and levelChild.Value
    if type(level) ~= "number" then return nil end
    local best
    for _, row in ipairs(levelCrates) do
        if row.level <= level then best = row end
    end
    return best
end

-- Most expensive crate the wallet can cover at the current amount: the
-- rule is price * amount <= wallet, so with amount 4 and $100 the $25
-- crate wins, not the $100 one. Prices are read live every call (this
-- game drifts them); the Free Case (price 0) is the natural fallback.
local function mostExpensiveAffordable(amount)
    local walletChild = lp:FindFirstChild("Wallet")
    local wallet = walletChild and walletChild:IsA("NumberValue") and walletChild.Value
    if type(wallet) ~= "number" then return nil end
    local best
    for _, case in ipairs(Cases:GetChildren()) do
        if case:IsA("StringValue") then
            local priceChild = case:FindFirstChild("Price")
            local price = priceChild and priceChild:IsA("NumberValue") and priceChild.Value
            if type(price) == "number" and price * amount <= wallet then
                if not best or price > best.price then
                    best = { name = case.Name, price = price }
                end
            end
        end
    end
    return best
end

----------------------------------------------------------------
-- Window
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "Case Haven Auto Spin",
    ToggleKey = Enum.KeyCode.RightShift,
})

local Tab = Window:AddTab("Cases", "package")

----------------------------------------------------------------
-- Cases dropdown (sorted by price) + delay slider
----------------------------------------------------------------
-- Every case is a StringValue under ReplicatedStorage.Cases and its cost
-- is the Price NumberValue on it. The list is read live so it follows the
-- game; a case with no Price sorts to the end.
local rows = {}
for i, case in ipairs(Cases:GetChildren()) do
    if case:IsA("StringValue") then
        local priceChild = case:FindFirstChild("Price")
        rows[#rows + 1] = {
            name = case.Name,
            price = (priceChild and priceChild:IsA("NumberValue") and priceChild.Value) or math.huge,
            order = i,
        }
    end
end
table.sort(rows, function(a, b)
    if a.price ~= b.price then return a.price < b.price end
    return a.order < b.order
end)

-- Dropdown values carry "name ($price)" so the search matches on both;
-- the display string maps back to the case name for the loop.
local displays = {}
local names = {}
local displayToName = {}
for i, row in ipairs(rows) do
    displays[i] = row.name .. " ($" .. fmtPrice(row.price) .. ")"
    names[i] = row.name
    displayToName[displays[i]] = row.name
end

local secSpin = Tab:AddSection("Auto Spin")

secSpin:AddToggle("MainRoll", {
    Text = "MAIN ROLL (nothing rolls while this is off)",
    Default = false,
    Tooltip = "Master switch. Cases still need to be selected in the dropdown below.",
})

local function setSelected(v)
    table.clear(enabled)
    if type(v) ~= "table" then return end
    if type(v[1]) == "string" then
        for _, display in ipairs(v) do
            if displayToName[display] then
                enabled[displayToName[display]] = true
            end
        end
    else
        for display, on in pairs(v) do
            if on == true and displayToName[display] then
                enabled[displayToName[display]] = true
            end
        end
    end
end

secSpin:AddDropdown("SpinCases", {
    Text = "Cases to auto spin",
    Values = displays,
    Multi = true,
    Searchable = true,
    VisibleItems = 10,
    Tooltip = "Every case in the game, sorted by price (cheapest first). Search by name or price.",
    Callback = setSelected,
})

secSpin:AddToggle("LevelCase", {
    Text = "Also roll highest unlocked level crate",
    Default = false,
    Tooltip = "Each tick also rolls the highest Level N Case your level has unlocked (Level 60 Case at level 65, next at 70). Shares the amount and delay sliders; if that crate is also picked in the dropdown it rolls twice.",
})

secSpin:AddToggle("ExpensiveCase", {
    Text = "Also roll most expensive affordable crate",
    Default = false,
    Tooltip = "Each tick also rolls the priciest crate the wallet covers at the current amount: price x amount <= wallet. With amount 4 and $100 that is the $25 crate, not the $100 one. Falls back to the Free Case when nothing else fits; if it is also picked in the dropdown it rolls twice.",
})

secSpin:AddSlider("SpinAmount", {
    Text = "Amount per roll",
    Min = 1, Max = 10, Default = 1, Increment = 1,
    Tooltip = "How many copies each fire rolls - the number at the end of the OpenCase payload. Click the value label to type an exact number. The game only accepts up to your unlocked Case Slots (2 by default, raised by the Case Slot upgrades); higher values are refused, so those fires just do nothing.",
})

secSpin:AddSlider("SpinDelay", {
    Text = "Delay between rolls",
    Min = 0.1, Max = 5, Default = 1, Increment = 0.1, Suffix = "s",
    Tooltip = "Every selected case rolls once per tick. Each tick waits this long before the next one.",
})

----------------------------------------------------------------
-- Auto spin loop
----------------------------------------------------------------
-- One tick per delay: every selected case fires its roll (in price
-- order), then the loop sleeps. Nothing is sent unless the main toggle
-- is on; the amount is the slider value (the same field the game's own
-- client sends as OpenCase.Amount).
task.spawn(function()
    while RUNNING do
        local gap = math.clamp(tonumber(EZ.Flags.SpinDelay) or 1, 0.1, 60)
        if EZ.Flags.MainRoll == true then
            local amount = math.floor(math.clamp(tonumber(EZ.Flags.SpinAmount) or 1, 1, 10))
            for _, name in ipairs(names) do
                if enabled[name] then
                    pcall(function()
                        MainEvent:FireServer("OpenCase", name, amount)
                    end)
                end
            end
            if EZ.Flags.LevelCase == true then
                local best = highestUnlockedLevelCrate()
                if best then
                    pcall(function()
                        MainEvent:FireServer("OpenCase", best.name, amount)
                    end)
                end
            end
            if EZ.Flags.ExpensiveCase == true then
                local pick = mostExpensiveAffordable(amount)
                if pick then
                    pcall(function()
                        MainEvent:FireServer("OpenCase", pick.name, amount)
                    end)
                end
            end
        end
        task.wait(gap)
    end
end)

----------------------------------------------------------------
-- Zones tab: auto buy next zone
----------------------------------------------------------------
-- Ownership lives on the player as BoolValues ("1".."16", true = owned);
-- the next zone is the lowest number not owned. Prices live on the
-- streamed zone parts (workspace.Zones.<n>.Cost) — those only exist
-- while you are near the zone, so each seen price is cached and the buy
-- waits until a price is known. The game's own BuyZoneClient fires the
-- same call: MainEvent:FireServer("BuyZone", <zone name>).
local TabZones = Window:AddTab("Zones", "map-pin")

local secZone = TabZones:AddSection("Auto Buy Zone")
secZone:AddToggle("AutoZone", {
    Text = "Auto buy next zone",
    Default = false,
    Tooltip = "Watches the lowest zone you do not own and buys it the moment the wallet covers its price. Zone prices are only visible while their part is streamed in, so the first tick may need you near the zone boundary.",
})
local zoneStatusP = secZone:AddParagraph({ Title = "Status", Content = "off" })

secZone:AddToggle("AutoTeleport", {
    Text = "Auto teleport to best unlocked zone",
    Default = false,
    Tooltip = "Teleports to the highest zone you own the moment this turns on, and again every time a better zone unlocks (pairs with auto buy next zone). Fires the same Teleport call the TeleportFrame buttons make.",
})
local teleportStatusP = secZone:AddParagraph({ Title = "Teleport Status", Content = "off" })

local zoneCostCache = {} -- [zone number] = last seen Cost
local lastZoneBuyAt = {} -- [zone number] = os.clock() of the last BuyZone fire
local lastTeleportedZone -- best zone already teleported to

local function nextUnownedZone()
    local best
    for _, v in ipairs(PlayerZones:GetChildren()) do
        local n = tonumber(v.Name)
        if n and not v.Value and (not best or n < best) then
            best = n
        end
    end
    return best
end

local function zoneCost(n)
    local part = ZoneParts:FindFirstChild(tostring(n))
    if part then
        local cost = part:FindFirstChild("Cost")
        if cost and cost:IsA("NumberValue") then
            zoneCostCache[n] = cost.Value
        end
    end
    return zoneCostCache[n]
end

task.spawn(function()
    while RUNNING do
        pcall(function()
            -- auto buy next zone
            if EZ.Flags.AutoZone ~= true then
                zoneStatusP:Set("off")
            else
                local nextZone = nextUnownedZone()
                if not nextZone then
                    zoneStatusP:Set("Every zone with a known price is owned.")
                else
                    local cost = zoneCost(nextZone)
                    local walletChild = lp:FindFirstChild("Wallet")
                    local wallet = walletChild and walletChild:IsA("NumberValue") and walletChild.Value or 0
                    if not cost then
                        zoneStatusP:Set(string.format(
                            "Next zone: %d - price unknown\nWalk near the zone boundary so its part streams in.\nWallet: $%s",
                            nextZone, fmtPrice(wallet)))
                    elseif wallet >= cost then
                        if os.clock() - (lastZoneBuyAt[nextZone] or 0) > 2 then
                            lastZoneBuyAt[nextZone] = os.clock()
                            pcall(function()
                                MainEvent:FireServer("BuyZone", tostring(nextZone))
                            end)
                            EZ:Notify({
                                Title = "Case Haven Auto Spin",
                                Content = "Bought zone " .. nextZone .. " for $" .. fmtPrice(cost),
                                Duration = 6,
                                Type = "success",
                            })
                            zoneStatusP:Set(string.format("Bought zone %d for $%s", nextZone, fmtPrice(cost)))
                        end
                    else
                        zoneStatusP:Set(string.format(
                            "Next zone: %d - costs $%s\nWallet: $%s (need $%s more)",
                            nextZone, fmtPrice(cost), fmtPrice(wallet), fmtPrice(cost - wallet)))
                    end
                end
            end

            -- auto teleport to best owned zone
            if EZ.Flags.AutoTeleport ~= true then
                lastTeleportedZone = nil
                teleportStatusP:Set("off")
            else
                local best
                for _, v in ipairs(PlayerZones:GetChildren()) do
                    local n = tonumber(v.Name)
                    if n and v.Value and (not best or n > best) then
                        best = n
                    end
                end
                if not best then
                    teleportStatusP:Set("No zones owned yet.")
                elseif best ~= lastTeleportedZone then
                    lastTeleportedZone = best
                    pcall(function()
                        MainEvent:FireServer("Teleport", tostring(best))
                    end)
                    teleportStatusP:Set("Teleported to zone " .. best)
                end
            end
        end)
        task.wait(0.5)
    end
end)

----------------------------------------------------------------
-- Claims tab: quests / case mastery / time rewards
----------------------------------------------------------------
-- All three claims reuse the game's own client entry points and gates:
--   quests:       CHDailyQuestRequest:InvokeServer("Claim", id) when
--                 Progress >= Goal and not Claimed (mirrors the quest UI)
--   mastery:      CHCaseMasteryRemote:FireServer("Claim", case) when the
--                 game's own CHCaseMasteryConfig.CanClaim says so and the
--                 case is not claimed yet
--   time rewards: MainEvent:FireServer("ClaimReward", <order>) for
--                 TodaysItems past their Order*6min mark with inventory
--                 space (mirrors the game's own claim button handler)
local TabClaims = Window:AddTab("Claims", "gift")

local secClaims = TabClaims:AddSection("Auto Claim")
secClaims:AddToggle("AutoQuests", {
    Text = "Auto claim quests",
    Default = false,
    Tooltip = "Claims every daily quest whose Progress has reached its Goal. Quests are read from DailyQuests.Quests, so nothing is claimed early or twice.",
})
secClaims:AddToggle("AutoMastery", {
    Text = "Auto claim case mastery",
    Default = false,
    Tooltip = "Claims case mastery for every case where all items are discovered, using the game's own CHCaseMasteryConfig.CanClaim check. VIP/Puzzle and excluded cases are skipped the same way the game skips them.",
})
secClaims:AddToggle("AutoTimeRewards", {
    Text = "Auto claim time rewards",
    Default = false,
    Tooltip = "Claims TodaysItems rewards once you have been in the game past their mark (order x 6 minutes). Skips when the inventory is full, like the game's own claim button does.",
})

local lastClaimAt = {} -- [key] = os.clock() of the last claim fire

local function claimReady(key, cooldown)
    local now = os.clock()
    if now - (lastClaimAt[key] or 0) < cooldown then
        return false
    end
    lastClaimAt[key] = now
    return true
end

task.spawn(function()
    while RUNNING do
        pcall(function()
            if EZ.Flags.AutoQuests == true then
                for _, quest in ipairs(QuestFolder:GetChildren()) do
                    local progress = quest:FindFirstChild("Progress")
                    local goal = quest:FindFirstChild("Goal")
                    local claimed = quest:FindFirstChild("Claimed")
                    if claimed and claimed:IsA("BoolValue") and claimed.Value == false
                        and progress and goal
                        and progress:IsA("NumberValue") and goal:IsA("NumberValue")
                        and progress.Value >= goal.Value
                        and claimReady("quest:" .. quest.Name, 3) then
                        pcall(function()
                            CHDailyQuestRequest:InvokeServer("Claim", quest.Name)
                        end)
                        task.wait(0.3)
                    end
                end
            end

            if EZ.Flags.AutoMastery == true and MasteryConfig then
                for _, case in ipairs(MasteryConfig.GetCases()) do
                    local claimed = ClaimedMasteries:FindFirstChild(case.Name)
                    if (not claimed or claimed.Value ~= true)
                        and MasteryConfig.CanClaim(lp, case.Name)
                        and claimReady("mastery:" .. case.Name, 3) then
                        pcall(function()
                            CHCaseMasteryRemote:FireServer("Claim", case.Name)
                        end)
                        task.wait(0.3)
                    end
                end
            end

            if EZ.Flags.AutoTimeRewards == true then
                local inventorySize = lp.InventorySize and lp.InventorySize.Value or 0
                for _, item in ipairs(lp.TodaysItems:GetChildren()) do
                    local order = item:FindFirstChild("Order")
                    if item.Value == false and order and order:IsA("NumberValue")
                        and lp.TimeToday.Value > order.Value * 6 * 60
                        and #lp.Inventory:GetChildren() + 1 <= inventorySize
                        and claimReady("reward:" .. tostring(order.Value), 3) then
                        pcall(function()
                            MainEvent:FireServer("ClaimReward", tostring(order.Value))
                        end)
                        task.wait(0.3)
                    end
                end
            end
        end)
        task.wait(1)
    end
end)

----------------------------------------------------------------
-- Upgrades tab: auto buy upgrade-tree nodes
----------------------------------------------------------------
-- Pure remote path: MainFunction:InvokeServer("Upgrade", name) is the
-- exact call the upgrade tree's buy buttons make (MainGui.Mainscript).
-- Nothing here opens the tree GUI, moves the camera or touches game UI.
-- Availability mirrors the game's own UpgradeModule.isKnown: a node is
-- buyable once its first Parent is owned (root nodes are always known).
local TabUpgrades = Window:AddTab("Upgrades", "trending-up")

local secUp = TabUpgrades:AddSection("Auto Upgrade")
secUp:AddToggle("AutoUpgrades", {
    Text = "Auto buy upgrades",
    Default = false,
    Tooltip = "Buys one available upgrade per tick from the upgrade tree, fired straight through the game's own remote. No menu opening, camera movement or UI effects. Priority upgrades below are bought first; everything else cheapest first.",
})

local upgradeRows = {}
for _, def in ipairs(RsUpgrades:GetChildren()) do
    if def:IsA("NumberValue") then
        local costChild = def:FindFirstChild("Cost")
        upgradeRows[#upgradeRows + 1] = {
            name = def.Name,
            cost = costChild and costChild:IsA("NumberValue") and costChild.Value or math.huge,
        }
    end
end
table.sort(upgradeRows, function(a, b)
    if a.cost ~= b.cost then return a.cost < b.cost end
    return a.name < b.name
end)

local upgradeDisplays = {}
local upgradeDisplayToName = {}
for i, row in ipairs(upgradeRows) do
    upgradeDisplays[i] = row.name .. " ($" .. fmtPrice(row.cost) .. ")"
    upgradeDisplayToName[upgradeDisplays[i]] = row.name
end

local upgradePreferred = {}
local function setUpgradePreferred(v)
    table.clear(upgradePreferred)
    if type(v) ~= "table" then return end
    if type(v[1]) == "string" then
        for _, display in ipairs(v) do
            if upgradeDisplayToName[display] then
                upgradePreferred[upgradeDisplayToName[display]] = true
            end
        end
    else
        for display, on in pairs(v) do
            if on == true and upgradeDisplayToName[display] then
                upgradePreferred[upgradeDisplayToName[display]] = true
            end
        end
    end
end

secUp:AddDropdown("UpgradePriority", {
    Text = "Priority upgrades (bought first)",
    Values = upgradeDisplays,
    Multi = true,
    Searchable = true,
    VisibleItems = 10,
    Tooltip = "Selected upgrades are bought before everything else (cheapest first among them). Leave empty to buy everything cheapest first.",
    Callback = setUpgradePreferred,
})

local upgradeStatusP = secUp:AddParagraph({ Title = "Status", Content = "off" })

local lastUpgradeTryAt = {} -- [name] = os.clock() of the last refused try

local function playerOwnsUpgrade(name)
    local v = PlayerUpgrades:FindFirstChild(name)
    return v ~= nil and v.Value > 0
end

local function upgradeCandidates()
    local preferred, rest = {}, {}
    for _, def in ipairs(RsUpgrades:GetChildren()) do
        if def:IsA("NumberValue") and not playerOwnsUpgrade(def.Name) then
            local parents = def:FindFirstChild("Parents")
            local first = parents and parents:GetChildren()[1]
            if not first or playerOwnsUpgrade(first.Name) then
                local costChild = def:FindFirstChild("Cost")
                local row = {
                    name = def.Name,
                    cost = costChild and costChild:IsA("NumberValue") and costChild.Value or math.huge,
                }
                if upgradePreferred[def.Name] then
                    preferred[#preferred + 1] = row
                else
                    rest[#rest + 1] = row
                end
            end
        end
    end
    table.sort(preferred, function(a, b) return a.cost < b.cost end)
    table.sort(rest, function(a, b) return a.cost < b.cost end)
    local all = {}
    for _, row in ipairs(preferred) do all[#all + 1] = row end
    for _, row in ipairs(rest) do all[#all + 1] = row end
    return all
end

task.spawn(function()
    while RUNNING do
        pcall(function()
            if EZ.Flags.AutoUpgrades ~= true then
                upgradeStatusP:Set("off")
                return
            end
            local walletChild = lp:FindFirstChild("Wallet")
            local wallet = walletChild and walletChild:IsA("NumberValue") and walletChild.Value or 0
            local candidates = upgradeCandidates()
            local pick
            for _, row in ipairs(candidates) do
                if row.cost <= wallet and os.clock() - (lastUpgradeTryAt[row.name] or 0) > 3 then
                    pick = row
                    break
                end
            end
            if not pick then
                if candidates[1] then
                    upgradeStatusP:Set(string.format(
                        "Waiting for money - cheapest available: %s ($%s)\nWallet: $%s",
                        candidates[1].name, fmtPrice(candidates[1].cost), fmtPrice(wallet)))
                else
                    upgradeStatusP:Set("No available upgrades (all owned or locked behind unowned prerequisites).")
                end
                return
            end
            local ok, res = pcall(function()
                return MainFunction:InvokeServer("Upgrade", pick.name)
            end)
            if ok and res ~= nil then
                EZ:Notify({
                    Title = "Case Haven Auto Spin",
                    Content = "Bought upgrade: " .. pick.name .. " ($" .. fmtPrice(pick.cost) .. ")",
                    Duration = 5,
                    Type = "success",
                })
                upgradeStatusP:Set(string.format("Bought %s for $%s", pick.name, fmtPrice(pick.cost)))
            else
                lastUpgradeTryAt[pick.name] = os.clock()
                upgradeStatusP:Set(string.format("Server refused %s - retrying in a few seconds", pick.name))
            end
        end)
        task.wait(1)
    end
end)

----------------------------------------------------------------
-- Final wiring (AFTER every element exists)
----------------------------------------------------------------
pcall(function() SaveManager:LoadAutoloadConfig() end)

EZ:Notify({
    Title = "Case Haven Auto Spin",
    Content = #names .. " cases loaded - arm MAIN ROLL and pick cases",
    Duration = 6,
    Type = "info",
})

----------------------------------------------------------------
-- Shutdown
----------------------------------------------------------------
EZ:OnDestroy(function()
    RUNNING = false
end)

getgenv().__CH_AUTOSPIN_LOADED = true
getgenv().__CH_AUTOSPIN_EZ = EZ
getgenv().__CH_AUTOSPIN_DESTROY = function() pcall(function() EZ:Destroy() end) end
-- live handles for inspection from another script/console
getgenv().__CH_AUTOSPIN_STATE = {
    enabled = enabled,
    names = names,       -- price order, cheapest first
    displays = displays, -- dropdown values ("name ($price)")
}