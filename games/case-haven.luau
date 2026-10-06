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
    steps down to a cheaper crate. Nothing else.

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