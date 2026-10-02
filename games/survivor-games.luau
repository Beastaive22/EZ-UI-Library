-- Survivor Games autofarm — EZ Hub game module (see loader.lua).
-- Game guard first: game.GameId is the universe id (10120569105), so every
-- place in Survivor Games matches — the lobby (75853422134229) and each map
-- place (e.g. 95198514615945 "HG Grass Map 2"). Anywhere else this exits
-- before touching anything, even if someone runs the file directly.
if game.GameId ~= 10120569105 then return end

--[[
    Survivor Games Autofarm
    Built on EZ-UI-Library (https://github.com/Beastaive22/EZ-UI-Library)
    Executor: Potassium / sUNC

    Hunter mode: kill players first, anywhere on the map, and only take the
    gear that is an upgrade — a better axe/sword/bow, a better armor piece,
    food, arrows while a bow is carried. Everything else stays on the floor,
    and anything already carried that is no longer an upgrade gets thrown out
    through the game's own DropInventoryItem.

    All of it goes through the game's own client entry points, verified live
    on the client before this was written:

      attacks/eating  PlayerScripts.Input.ClientUseRouter.BuildContext("Primary")
                      -> Remotes.UseSelectedItem:FireServer({InputType, Context})
                      — the exact call the game's own click handler makes.
      chests          the chest's Core.ProximityPrompt (E, hold 0s, range 12);
                      the server then pushes ChestSnapshot and the client sets
                      LP attributes ChestOpen/OpenChestId. Chest contents are
                      read from ClientInventoryView.GetChestSnapshot() and only
                      wanted slots are quick-moved.
      drops           workspace.ItemDrops.Drop_<ItemId>. The Handle is
                      CanTouch = false and ItemDropVisuals only renders them:
                      pickup is a server-side proximity check, so the bot
                      stands ON the drop and waits for it to fly in.
      weapons         Remotes.SelectHotbarSlot + ClientInventoryView.GetSnapshot()
                      (live ItemId per slot — no image-asset-id guessing).
      junk            Remotes.DropInventoryItem:FireServer({FromSlot, Count}) —
                      the same call the game's own inventory drag-out makes.
      requeue         Remotes.Match.EndScreenAction:FireServer("PlayAgain") —
                      the same call the end screen's button makes.
      lobby           Remotes.Matchmaking.ToggleQueueRequest:FireServer(mode).
      match state     ReplicatedStorage.Shared.Match.MatchState attributes
                      (Phase/PlayersAlive) + Shared.GameMode.IsMatch().

    Two things need the game's numbers, not guesses: a chest prompt holds for
    0 s but only triggers within 12 studs, and every attack is aimed by the
    camera (the context's AimCFrame comes from CurrentCamera), so the camera
    is pointed at the target for the instant the swing is built and put back
    in the same frame — the player keeps their own camera, and CameraType is
    never switched.

    While the master toggle is off this script is inert: it builds the window
    and idles. Arming it queues the hub loader via queue_on_teleport so the
    next place change (lobby -> match, match -> lobby) re-runs the module by
    itself, and an intent file carries the on/off state across that hop —
    without it, a place change destroys the script and the farm plays exactly
    one match. getgenv().SurvivorRearm overrides the queued code for testing
    an edited file before it is pushed.

    Toggle UI: RightShift
]]

local getgenv = getgenv

print("[SURVIVOR] starting")

-- A previous injection in this place owns connections, a window and possibly
-- a Scriptable camera. Stop it, but keep the intent file untouched: this
-- instance is about to read it.
local function previousInstance()
    local g = getgenv and getgenv()
    if g and g.__SURVIVOR_FARM_DESTROY then
        pcall(g.__SURVIVOR_FARM_DESTROY, true)
    end
end
previousInstance()

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
SaveManager:Bind(EZ, "SurvivorAutofarmConfigs")
ThemeManager:Bind(EZ, { File = "SurvivorAutofarm_Theme.txt" })
ThemeManager:LoadSaved()
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

----------------------------------------------------------------
-- Runtime
----------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- queue_on_teleport runs this code the moment the next place loads, which is
-- before the player object exists. Wait for LocalPlayer (loading off disk
-- does not have this problem, a teleport does).
local lp = Players.LocalPlayer
if not lp then
    for _ = 1, 200 do
        task.wait(0.1)
        lp = Players.LocalPlayer
        if lp then break end
    end
end
if not lp then return end

local PlayerGui = lp:WaitForChild("PlayerGui", 30)
if not PlayerGui then return end

local RUNNING = true
local Conns = {}
local function track(conn)
    Conns[#Conns + 1] = conn
    return conn
end

-- WaitForChild with a timeout, then fall back to a plain FindFirstChild: the
-- lobby and the maps do not share an identical tree, and a bare WaitForChild
-- would hang on everything the other place lacks.
local function find(parent, name, timeout)
    if not parent then return nil end
    local ok, child = pcall(function() return parent:WaitForChild(name, timeout or 5) end)
    if ok and child then return child end
    return parent:FindFirstChild(name)
end

----------------------------------------------------------------
-- Game handles
----------------------------------------------------------------
local RemotesFolder = find(ReplicatedStorage, "Remotes", 30)

local function remote(...)
    local node = RemotesFolder
    for _, name in ipairs({ ... }) do
        node = find(node, name, 2)
        if not node then return nil end
    end
    return node
end

local UseSelectedItem = remote("UseSelectedItem")
local SelectHotbarSlot = remote("SelectHotbarSlot")
local MoveChestItem = remote("MoveChestItem")
local CloseChestRequest = remote("CloseChestRequest")
local MoveBackpackToHotbar = remote("MoveBackpackToHotbar")
local DropInventoryItem = remote("DropInventoryItem")
local EndScreenAction = remote("Match", "EndScreenAction")
local ToggleQueueRequest = remote("Matchmaking", "ToggleQueueRequest")

local Shared = find(ReplicatedStorage, "Shared", 30)

local function requireAt(parent, name)
    local inst = find(parent, name, 5)
    if not inst then return nil end
    local ok, module = pcall(require, inst)
    if ok and module ~= nil then return module end
    return nil
end

local ItemsFolder = find(Shared, "Items", 10)
local CombatFolder = find(Shared, "Combat", 10)
local ItemCatalog = requireAt(ItemsFolder, "ItemCatalog")
local InventoryConfig = requireAt(ItemsFolder, "InventoryConfig")
local WeaponConfig = requireAt(CombatFolder, "WeaponConfig")
local GameMode = requireAt(Shared, "GameMode")

local PlayerScripts = find(lp, "PlayerScripts", 20)
local UIFolder = find(PlayerScripts, "UI", 10)
local Inventory = requireAt(UIFolder, "ClientInventoryView")
local Router = requireAt(find(PlayerScripts, "Input", 10), "ClientUseRouter")

-- Cheap, non-yielding lookups: these are called from the 10 Hz loop, where a
-- WaitForChild timeout would stall the whole farm for seconds.
local function matchState()
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local match = shared and shared:FindFirstChild("Match")
    return match and match:FindFirstChild("MatchState") or nil
end
local function matchPhase()
    local state = matchState()
    return state and state:GetAttribute("Phase") or nil
end
local function isInMatch()
    if GameMode and type(GameMode.IsMatch) == "function" then
        local ok, result = pcall(GameMode.IsMatch)
        if ok and type(result) == "boolean" then return result end
    end
    return matchState() ~= nil
end

----------------------------------------------------------------
-- Surviving a teleport
----------------------------------------------------------------
-- A place change destroys the script outright. Arming queues the hub loader,
-- so the next place re-runs this module; the intent file below carries the
-- on/off state across the hop.
local REARM_CODE = [[loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/loader.lua"))()]]

local function rearmAfterTeleport()
    local code = REARM_CODE
    local g = getgenv and getgenv()
    local override = g and g.SurvivorRearm
    if type(override) == "string" and #override > 0 then code = override end

    local fn
    if type(queue_on_teleport) == "function" then
        fn = queue_on_teleport
    elseif type(queueonteleport) == "function" then
        fn = queueonteleport
    end
    if not fn then return false end
    return (pcall(fn, code))
end

-- The farm's on/off has to outlive the teleport, and the EZ config autoload
-- is only restored if the user set it up. One small file carries it instead.
--
-- `ok` separates "the file says off" from "the file could not be read": with
-- both reading as false, one transient failure would look like a real "off"
-- and the loop would not resume. (That exact bug bit the CO-OP module in this
-- repo — see its commit — so this version keeps the distinction.)
local INTENT_FILE = "survivor-games-intent.txt"

local function readIntent()
    local out = { enabled = false, mode = nil, ok = false }
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return out end

    local okCall, exists = pcall(isfile, INTENT_FILE)
    if not okCall then return out end
    if not exists then
        out.ok = true -- no file at all is a real answer: never armed
        return out
    end

    local okRead, text = pcall(readfile, INTENT_FILE)
    if not okRead or type(text) ~= "string" then return out end
    out.ok = true
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key == "enabled" then
            out.enabled = value == "1" or value == "true"
        elseif key == "mode" then
            if value == "Solo" or value == "Duos" or value == "Squads" then
                out.mode = value
            end
        end
    end
    return out
end

local function writeIntent(enabled, mode)
    if type(writefile) ~= "function" then return false end
    local text = string.format("enabled=%d\nmode=%s\n", enabled and 1 or 0, tostring(mode or "Solo"))
    return (pcall(writefile, INTENT_FILE, text))
end

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local S = {
    status = "Idle",
    armed = false,
    dead = false,
    attackInterval = 0.45,
    lastAttack = 0,
    lastPivot = 0,
    lastQueue = 0,
    queueFired = false,
    lastRequeue = 0,
    requeueAttempts = 0,
    lastEquipCheck = 0,
    lastSweep = 0,
    lastTargetSeen = 0,
    lastPatrol = 0,
    target = nil,
    targetPosition = nil,
    lootUntil = 0,
    lootPosition = nil,
    rearmWarned = false,
}
local stats = { chests = 0, drops = 0, attacks = 0, eats = 0, requeues = 0, deaths = 0, junk = 0 }

local statusLabel, statsPara, logConsole, modeDropdown, masterToggle

local function flag(id, default)
    local value = EZ.Flags and EZ.Flags[id]
    if value == nil then return default end
    return value
end

local lastStatusText
local function setStatus(text)
    S.status = text
    if statusLabel and text ~= lastStatusText then
        lastStatusText = text
        pcall(function() statusLabel:Set(text) end)
    end
end

local function note(text, kind)
    if not logConsole then return end
    pcall(function()
        if kind == "Warn" then
            logConsole:Warn(text)
        elseif kind == "Error" then
            logConsole:Error(text)
        else
            logConsole:Info(text)
        end
    end)
end

----------------------------------------------------------------
-- Movement
----------------------------------------------------------------
local SAFE_Y = 10

local function getRoot()
    local character = lp.Character
    if not character then return nil end
    return character.PrimaryPart
        or character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("UpperTorso")
        or character:FindFirstChild("Torso")
end

local function getHumanoid()
    local character = lp.Character
    return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function zeroVelocity(root)
    if root then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
end

-- Fall damage is ON in this game (workspace.FallHeightEnabled is true) and
-- there is void below the map, so every computed teleport lands on the ground
-- under (x, z) instead of at a guessed height — and is skipped entirely when
-- there is no ground to land on.
local rayParams
local function groundBelow(origin, depth)
    if not rayParams then
        rayParams = RaycastParams.new()
        rayParams.FilterType = Enum.RaycastFilterType.Exclude
    end
    rayParams.FilterDescendantsInstances = { lp.Character }
    local hit = workspace:Raycast(origin, Vector3.new(0, -(depth or 400), 0), rayParams)
    return hit and hit.Position or nil
end

local function safeSpot(x, z, fallbackY)
    return groundBelow(Vector3.new(x, (fallbackY or SAFE_Y) + 200, z), 500)
end

-- The camera belongs to the player. Swings need it only for the instant the
-- attack context is built (AimCFrame comes from CurrentCamera), so aiming
-- happens inside firePrimaryAt() and the camera is put straight back —
-- no Scriptable mode is ever left behind.

-- Rate-limited teleport. The game is client-authoritative about where the
-- character stands, so this is just the character's own PivotTo — but at
-- 10-15 Hz rather than every Heartbeat, which is both plenty and quieter.
-- hoverOverride replaces the hover-height setting (drops want the robot
-- standing IN them, not above them).
local function pivotTo(position, lookAt, hoverOverride, force)
    if not RUNNING then return false end
    local rate = math.clamp(tonumber(flag("SurvivorPositionRate", 15)) or 15, 5, 30)
    local now = os.clock()
    if not force and now - S.lastPivot < 1 / rate then return false end

    local character = lp.Character
    local root = getRoot()
    if not character or not root then return false end

    local hover = hoverOverride or tonumber(flag("SurvivorHoverHeight", 3.5)) or 3.5
    local target = position + Vector3.new(0, hover, 0)
    if target.Y < SAFE_Y then
        target = Vector3.new(target.X, SAFE_Y, target.Z)
    end

    local pivot
    if lookAt then
        local flat = Vector3.new(lookAt.X, target.Y, lookAt.Z)
        if (flat - target).Magnitude > 0.1 then
            pivot = CFrame.lookAt(target, flat)
        end
    end
    if not pivot then pivot = CFrame.new(target) end

    S.lastPivot = now
    pcall(function() character:PivotTo(pivot) end)
    zeroVelocity(root)
    return true
end

----------------------------------------------------------------
-- Zone (the storm)
----------------------------------------------------------------
local function zoneInfo()
    local state = workspace:FindFirstChild("ZoneState")
    if not state then return nil end
    local radius = state:GetAttribute("Radius")
    local cx = state:GetAttribute("CenterX")
    local cz = state:GetAttribute("CenterZ")
    if type(radius) ~= "number" or type(cx) ~= "number" or type(cz) ~= "number" then return nil end
    return { radius = radius, cx = cx, cz = cz }
end

-- margin > 0 means "this far inside", margin < 0 allows that far outside.
local function insideZone(position, margin)
    local zone = zoneInfo()
    if not zone then return true end
    margin = margin or 0
    local dx = position.X - zone.cx
    local dz = position.Z - zone.cz
    local limit = zone.radius - margin
    if limit < 0 then return false end
    return (dx * dx + dz * dz) <= limit * limit
end

local function zoneCenter()
    local markers = workspace:FindFirstChild("WorldMarkers")
    local marker = markers and markers:FindFirstChild("ZoneCenter")
    if marker and marker:IsA("BasePart") then return marker.Position end
    local zone = zoneInfo()
    if zone then
        -- No marker: land on the ground under the centre rather than at a
        -- guessed height (this map sits at Y ~126, nowhere near SAFE_Y).
        return groundBelow(Vector3.new(zone.cx, 400, zone.cz), 1000)
    end
    return nil
end

----------------------------------------------------------------
-- Inventory (live snapshot from the game's own client view)
----------------------------------------------------------------
local HOTBAR_SLOTS = (InventoryConfig and tonumber(InventoryConfig.HOTBAR_SLOTS)) or 8
local TOTAL_SLOTS = (InventoryConfig and tonumber(InventoryConfig.TOTAL_SLOTS)) or 28
-- The chest container is backpack-sized, not 12: the game builds the chest
-- grid from InventoryConfig.BACKPACK_SLOTS (20 slots, verified live in
-- ChestGui's ChestGrid) and its own quick-move handler fires FromSlot 1..20.
-- The old 12-slot cap silently skipped chest slots 13..20 — that is why
-- higher-tier loot was "not being picked up".
local CHEST_SLOTS = (InventoryConfig and tonumber(InventoryConfig.BACKPACK_SLOTS)) or 20

local function getSnapshot()
    if not Inventory or type(Inventory.GetSnapshot) ~= "function" then return nil end
    local ok, snapshot = pcall(Inventory.GetSnapshot)
    if ok and type(snapshot) == "table" then return snapshot end
    return nil
end

local function getChestSnapshot()
    if not Inventory or type(Inventory.GetChestSnapshot) ~= "function" then return nil end
    local ok, snapshot = pcall(Inventory.GetChestSnapshot)
    if ok and type(snapshot) == "table" then return snapshot end
    return nil
end

-- The client keeps the last chest's contents after it closes (verified live:
-- GetChestSnapshot returned a closed chest's Slots). Reading it blindly while
-- another chest opens is how the wrong slots get moved. This waits for the
-- snapshot that carries the id of the chest that is open right now.
local function waitForChestSnapshot(chestId, timeout)
    local deadline = os.clock() + (timeout or 0.5)
    local last
    while true do
        last = getChestSnapshot()
        if last and last.Slots and (last.ChestId == nil or last.ChestId == chestId) then
            return last
        end
        if os.clock() >= deadline then return last end
        task.wait(0.02)
    end
end

local function slotEntry(snapshot, slot)
    if not snapshot or not snapshot.Slots then return nil end
    return snapshot.Slots[tostring(slot)]
end

local function itemInfo(itemId)
    if type(itemId) ~= "string" then return nil end
    if not ItemCatalog or type(ItemCatalog.Get) ~= "function" then return nil end
    local ok, item = pcall(ItemCatalog.Get, itemId)
    if ok and type(item) == "table" then return item end
    return nil
end

-- The catalog is missing entries for some ids — verified live: StoneAxe,
-- StoneHelmet and CrossBow all error out of ItemCatalog.Get. Requiring a
-- catalog hit therefore made every stone-tier drop invisible to the filter.
-- Fall back to the name so those items are classified (and upgraded) too.
local function itemKind(itemId, item)
    local itemType = item and item.ItemType
    if type(itemType) == "string" then return itemType end
    if itemId:find("Helmet", 1, true) or itemId:find("Chestplate", 1, true)
        or itemId:find("Boots", 1, true) then
        return "Armor"
    end
    if itemId == "Bow" or itemId == "CrossBow" or itemId:find("Sword", 1, true)
        or itemId:find("Axe", 1, true) or itemId:find("Pickaxe", 1, true) then
        return "Weapon"
    end
    return nil
end

-- Ranking is by the game's own numbers, not by the material's name — the two
-- disagree, and the game is right:
--   weapons  WeaponConfig damage: gold axe 40 < iron axe 50, gold sword = iron
--            sword = 30. ItemCatalog PowerRank encodes the same order
--            (GoldAxe 2 < IronAxe 3), so it is the ordinal fallback.
--   armor    ItemCatalog ArmorStats.ArmorPoints: gold helmet 2.5 > iron 2, so
--            here gold really is the upgrade (wood < stone < iron < gold <
--            diamond), which is what MATERIAL_TIER encodes.
-- Stone pieces are missing from the catalog entirely (Get errors), hence the
-- material-name fallbacks; ArmorPoints/PowerRank win wherever they exist.
local MATERIAL_TIER = { Wood = 1, Stone = 2, Iron = 3, Gold = 4, Diamond = 5, Netherite = 6 }
local WEAPON_TIER = { Wood = 1, Gold = 2, Stone = 2.5, Iron = 3, Diamond = 4, Netherite = 5 }

-- Higher is better within a class or an armor slot. nil for things that are
-- not gear at all (food, materials, blocks).
local function itemPower(itemId, item)
    local kind = itemKind(itemId, item)
    local material = MATERIAL_TIER[itemId:match("^(%a+)") or ""]
    if kind == "Weapon" or kind == "Tool" then
        local rank = item and tonumber(item.PowerRank)
        if rank then return rank end
        return WEAPON_TIER[itemId:match("^(%a+)") or ""] or 1
    end
    if kind == "Armor" then
        local stats = item and item.ArmorStats
        local points = stats and tonumber(stats.ArmorPoints)
        if points then return points end
        return material or 1
    end
    return nil
end

local function weaponClassOf(itemId, item)
    local weaponId = (item and item.WeaponId) or itemId
    if WeaponConfig and type(WeaponConfig.GetWeapon) == "function" then
        local ok, weapon = pcall(WeaponConfig.GetWeapon, weaponId)
        if ok and type(weapon) == "table" and type(weapon.WeaponType) == "string" then
            return weapon.WeaponType
        end
    end
    local class = item and item.ToolClass
    if class == "Sword" or class == "Axe" or class == "Bow" or class == "Pickaxe" then return class end
    if itemId == "Bow" or itemId == "CrossBow" then return "Bow" end
    if itemId:find("Sword", 1, true) then return "Sword" end
    if itemId:find("Axe", 1, true) then return "Axe" end
    if itemId:find("Pickaxe", 1, true) then return "Pickaxe" end
    return nil
end

local function armorSlotOf(itemId, item)
    if ItemCatalog and type(ItemCatalog.GetArmorSlot) == "function" then
        local ok, slot = pcall(ItemCatalog.GetArmorSlot, itemId)
        if ok and type(slot) == "string" then return slot end
    end
    if itemId:find("Helmet", 1, true) then return "Helmet" end
    if itemId:find("Chestplate", 1, true) then return "Chestplate" end
    if itemId:find("Boots", 1, true) then return "Boots" end
    return nil
end

-- What is the best thing we already own, per weapon class and armor slot?
-- Equipped armor counts: carrying a WoodHelmet while wearing a DiamondHelmet
-- means the WoodHelmet is junk, and a WoodHelmet on the floor is not worth a
-- detour.
-- Food is counted for the "only carry a few meals" cap: apples, bread, meat
-- and the golden apple. Everything else consumable (potions, telepearls) is
-- not capped.
local FOOD_IDS = { Apple = true, Bread = true, Meat = true, GoldApple = true, GoldenApple = true }

local function isFood(itemId, item)
    if FOOD_IDS[itemId] then return true end
    local heal = item and tonumber(item.HealAmount)
    return heal ~= nil and heal > 0
end

local function foodTarget()
    return math.max(1, math.floor(tonumber(flag("SurvivorFoodTarget", 4)) or 4))
end

local function ownedBest(snapshot)
    local owned = { weapons = {}, armor = {}, equipped = {}, foodCount = 0, arrows = 0 }
    if not snapshot then return owned end

    local function considerArmor(itemId)
        local item = itemInfo(itemId)
        local slot = armorSlotOf(itemId, item)
        if not slot then return end
        local tier = itemPower(itemId, item)
        if not owned.armor[slot] or tier > owned.armor[slot] then
            owned.armor[slot] = tier
        end
    end

    -- Worn armor is tracked separately from carried armor: "is this drop an
    -- upgrade" looks at everything owned, but the junk sweep may only throw a
    -- piece away when the WORN armor already beats it.
    if snapshot.Armor then
        for _, entry in pairs(snapshot.Armor) do
            local itemId = entry and entry.ItemId
            if type(itemId) == "string" then
                local item = itemInfo(itemId)
                local slot = armorSlotOf(itemId, item)
                if slot then
                    local tier = itemPower(itemId, item)
                    if not owned.equipped[slot] or tier > owned.equipped[slot] then
                        owned.equipped[slot] = tier
                    end
                end
                considerArmor(itemId)
            end
        end
    end

    for slot = 1, TOTAL_SLOTS do
        local entry = slotEntry(snapshot, slot)
        local itemId = entry and entry.ItemId
        if type(itemId) == "string" then
            local item = itemInfo(itemId)
            local itemType = itemKind(itemId, item)
            if itemType == "Weapon" or itemType == "Tool" then
                local class = weaponClassOf(itemId, item)
                if class then
                    local tier = itemPower(itemId, item)
                    if not owned.weapons[class] or tier > owned.weapons[class] then
                        owned.weapons[class] = tier
                    end
                end
            elseif itemType == "Armor" then
                considerArmor(itemId)
            elseif itemType == "Consumable" and isFood(itemId, item) then
                owned.foodCount = owned.foodCount + (tonumber(entry.Count) or 1)
            elseif itemId == "Arrow" then
                owned.arrows = owned.arrows + (tonumber(entry.Count) or 1)
            end
        end
    end
    return owned
end

-- The whole loot policy lives here: upgrades and food only. Arrows are only
-- worth carrying while a bow is, and blocks/materials are not chased at all.
local function wantsItem(itemId, owned)
    if type(itemId) ~= "string" then return false end
    if itemId == "Arrow" then
        -- a stack is plenty: without the cap the bot would chase every arrow
        -- on the map between fights
        return owned ~= nil and owned.weapons.Bow ~= nil and owned.arrows < 64
    end
    if itemId == "Diamond" then
        return true -- raw diamonds are crafting currency; never walk past one
    end

    local item = itemInfo(itemId)
    local itemType = itemKind(itemId, item)

    -- Wooden gear is never wanted: stone is everywhere and every chest has
    -- better. This keeps wooden items in chests and off the floor, and stops
    -- a wooden drop from ever costing a trip.
    if itemId:match("^Wood") then
        local kind = itemKind(itemId, item)
        if kind == "Weapon" or kind == "Armor" or kind == "Tool" then
            return false
        end
    end

    if itemType == "Consumable" then
        -- Meals are capped: the farm wants a few, not a pantry, so past the
        -- cap it stops chasing meat (and stops farming animals for it).
        if isFood(itemId, item) and owned then
            return owned.foodCount < foodTarget()
        end
        return true
    end

    if itemType == "Weapon" or itemType == "Tool" then
        local class = weaponClassOf(itemId, item)
        if not class then return false end
        if not owned then return true end
        local have = owned.weapons[class]
        return have == nil or itemPower(itemId, item) > have
    end

    if itemType == "Armor" then
        local slot = armorSlotOf(itemId, item)
        if not slot then return false end
        if not owned then return true end
        local have = owned.armor[slot]
        return have == nil or itemPower(itemId, item) > have
    end

    return false
end

-- Equipping: material tier first, then the axe/sword preference. The live
-- numbers: per hit axe 35/40/50/60 vs sword 20/30/35/40, but swords swing at
-- 0.25 s against the axe's 0.95 s, so the two are a real trade-off.
local function weaponScore(itemId)
    local item = itemInfo(itemId)
    local class = weaponClassOf(itemId, item)
    if not class then return nil end
    local tier = itemPower(itemId, item)
    local preferAxe = flag("SurvivorPreferAxe", true) == true
    local classWeight = ((class == "Axe") and (preferAxe and 1 or 0)) or ((class == "Sword") and (preferAxe and 0 or 1)) or 0
    return tier * 10 + classWeight
end

local function bestWeapon(snapshot, hotbarOnly)
    local limit = hotbarOnly and HOTBAR_SLOTS or TOTAL_SLOTS
    local bestId, bestScore, bestSlot
    for slot = 1, limit do
        local entry = slotEntry(snapshot, slot)
        local id = entry and entry.ItemId
        local score = id and weaponScore(id)
        if score and (not bestScore or score > bestScore) then
            bestId, bestScore, bestSlot = id, score, slot
        end
    end
    return bestId, bestSlot
end

local FOOD_RANK = { GoldApple = 5, Meat = 4, Bread = 3, Apple = 2 }

local function bestFood(snapshot)
    local bestId, bestRank, bestSlot
    for slot = 1, TOTAL_SLOTS do
        local entry = slotEntry(snapshot, slot)
        local id = entry and entry.ItemId
        if id then
            local rank = FOOD_RANK[id]
            if not rank then
                local item = itemInfo(id)
                if item and item.ItemType == "Consumable" then rank = 1 end
            end
            if rank and (not bestRank or rank > bestRank) then
                bestId, bestRank, bestSlot = id, rank, slot
            end
        end
    end
    return bestId, bestSlot
end

local function selectHotbar(slot)
    if not SelectHotbarSlot or type(slot) ~= "number" then return false end
    pcall(function() SelectHotbarSlot:FireServer(slot) end)
    local deadline = os.clock() + 0.8
    while os.clock() < deadline do
        local snapshot = getSnapshot()
        if not snapshot then return true end -- cannot verify; trust the server
        if snapshot.SelectedHotbarSlot == slot then return true end
        task.wait(0.05)
    end
    return false
end

-- Refreshes the swing cadence from the weapon the server considers equipped
-- (sword 0.25 s, axe 0.95 s). Faster than that is rejected anyway.
local function refreshAttackInterval(itemId)
    local cooldown = 0.45
    if itemId and WeaponConfig and type(WeaponConfig.GetWeapon) == "function" then
        local ok, weapon = pcall(WeaponConfig.GetWeapon, itemId)
        if ok and type(weapon) == "table" and tonumber(weapon.AttackCooldown) then
            cooldown = math.max(0.25, tonumber(weapon.AttackCooldown))
        end
    end
    S.attackInterval = cooldown + 0.05
end

local moveAttemptAt = {}

local function ensureBestWeapon()
    if flag("SurvivorAutoUpgrade", true) ~= true then return end
    local snapshot = getSnapshot()
    if not snapshot then return end

    local id, slot = bestWeapon(snapshot, false)
    if not id then return end

    if slot > HOTBAR_SLOTS then
        -- The game auto-slots pickups (AutoSlotsEnabled), so a weapon in the
        -- backpack is usually temporary. Try once every few seconds to bring
        -- it forward; if that fails, use the best one already in the hotbar.
        local now = os.clock()
        if MoveBackpackToHotbar and (moveAttemptAt[id] or 0) + 5 < now then
            moveAttemptAt[id] = now
            pcall(function() MoveBackpackToHotbar:FireServer(slot) end)
            task.wait(0.2)
            snapshot = getSnapshot() or snapshot
            local movedId, movedSlot = bestWeapon(snapshot, true)
            if movedId == id then
                slot = movedSlot
            else
                slot = nil
            end
        else
            slot = nil
        end
    end

    if not slot or slot > HOTBAR_SLOTS then
        local hotbarId, hotbarSlot = bestWeapon(snapshot, true)
        if hotbarId then id, slot = hotbarId, hotbarSlot else return end
    end

    if snapshot.SelectedHotbarSlot ~= slot then
        selectHotbar(slot)
    end
    refreshAttackInterval(id)
end

-- nil when the inventory view is unavailable; used to refuse to swing with a
-- block or a sandwich selected.
local function equippedClass()
    local snapshot = getSnapshot()
    if not snapshot then return nil end
    local entry = slotEntry(snapshot, snapshot.SelectedHotbarSlot)
    return entry and entry.ItemId and weaponClassOf(entry.ItemId, itemInfo(entry.ItemId)) or nil
end

----------------------------------------------------------------
-- Junk sweep (needs the live inventory; breaks nothing when unavailable)
----------------------------------------------------------------
-- Keeps exactly one of each weapon class and the best of each armor slot,
-- comparing against equipped armor too, and drops the rest through the game's
-- own DropInventoryItem. The selected hotbar slot is never touched.
local function sweepInventory(snapshot)
    if flag("SurvivorDropJunk", true) ~= true then return end
    if not snapshot or not DropInventoryItem then return end
    if lp:GetAttribute("ChestOpen") == true then return end

    local owned = ownedBest(snapshot)
    local entries = {}
    for slot = 1, TOTAL_SLOTS do
        local entry = slotEntry(snapshot, slot)
        local itemId = entry and entry.ItemId
        if type(itemId) == "string" then
            local item = itemInfo(itemId)
            local itemType = itemKind(itemId, item)
            local key, tier
            if itemType == "Weapon" or itemType == "Tool" then
                local class = weaponClassOf(itemId, item)
                if class then
                    key, tier = "w:" .. class, itemPower(itemId, item)
                end
            elseif itemType == "Armor" then
                local armorSlot = armorSlotOf(itemId, item)
                if armorSlot then
                    key, tier = "a:" .. armorSlot, itemPower(itemId, item)
                end
            end
            if key then
                entries[#entries + 1] = { slot = slot, key = key, tier = tier, count = tonumber(entry.Count) or 1 }
            end
        end
    end

    -- keeper per key: highest tier, and on a tie the currently held one
    local keeper = {}
    for _, info in ipairs(entries) do
        local current = keeper[info.key]
        if not current or info.tier > current.tier
            or (info.tier == current.tier and info.slot == snapshot.SelectedHotbarSlot) then
            keeper[info.key] = info
        end
    end

    local dropped = 0
    for _, info in ipairs(entries) do
        local keep = keeper[info.key]
        local floor
        if info.key:sub(1, 2) == "a:" then
            -- Only WORN armor justifies throwing a piece away. Using the
            -- carried best here made the sweep drop the very upgrade it had
            -- just picked up (diamond helmet in, diamond helmet straight out).
            floor = owned.equipped[info.key:sub(3)]
        end
        local junk = (info ~= keep) or (floor ~= nil and floor >= info.tier)
        if junk and info.slot ~= snapshot.SelectedHotbarSlot then
            pcall(function()
                DropInventoryItem:FireServer({ FromSlot = info.slot, Count = info.count })
            end)
            dropped = dropped + 1
            task.wait(0.05)
        end
    end
    if dropped > 0 then
        stats.junk = stats.junk + dropped
        note(string.format("Dropped %d junk item(s)", dropped))
    end
end

----------------------------------------------------------------
-- Targets
----------------------------------------------------------------
local function targetRoot(entity)
    if not entity or not entity.Parent then return nil end
    if entity:IsA("BasePart") then return entity end
    return entity.PrimaryPart
        or entity:FindFirstChild("HumanoidRootPart")
        or entity:FindFirstChild("RootPart")
        or entity:FindFirstChildWhichIsA("BasePart")
end

local function entityAlive(entity)
    if not entity or not entity.Parent then return false end
    local humanoid = entity:FindFirstChildOfClass("Humanoid")
    if humanoid then return humanoid.Health > 0 end
    local health = entity:GetAttribute("Health")
    if type(health) == "number" then return health > 0 end
    return true
end

local function entityName(entity)
    local player = Players:GetPlayerFromCharacter(entity)
    if player then return player.DisplayName end
    return entity:GetAttribute("MobName") or entity.Name
end

local function entityHealthPercent(entity)
    local humanoid = entity:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.MaxHealth > 0 then
        return humanoid.Health / humanoid.MaxHealth * 100
    end
    local health = entity:GetAttribute("Health")
    local maxHealth = entity:GetAttribute("MaxHealth")
    if type(health) == "number" and type(maxHealth) == "number" and maxHealth > 0 then
        return health / maxHealth * 100
    end
    return nil
end

local function sameGroup(player)
    if player.Team and lp.Team and player.Team == lp.Team then return true end
    local mine = lp:GetAttribute("PartyId")
    local theirs = player:GetAttribute("PartyId")
    return mine ~= nil and mine == theirs
end

local function nearestPlayer(range)
    local root = getRoot()
    if not root then return nil end
    local best, bestDistance
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and player.Character and not sameGroup(player)
            and player:GetAttribute("Spectating") ~= true then
            local part = targetRoot(player.Character)
            if part and entityAlive(player.Character) then
                local distance = (part.Position - root.Position).Magnitude
                if distance <= range and (not bestDistance or distance < bestDistance) then
                    best, bestDistance = player.Character, distance
                end
            end
        end
    end
    return best, bestDistance
end

-- The game's AI fighters live in workspace.Bots as Models with a Humanoid
-- (attributes: TeamId, BotLoot, Targetable, ...). They are the ones carrying
-- the gear the farm is after, so they are hunted exactly like players.
local function nearestBot(range)
    local root = getRoot()
    if not root then return nil end
    local folder = workspace:FindFirstChild("Bots")
    if not folder then return nil end
    local myTeam = lp:GetAttribute("TeamId")
    local best, bestDistance
    for _, bot in ipairs(folder:GetChildren()) do
        if bot:IsA("Model") then
            local teamId = bot:GetAttribute("TeamId")
            if not (teamId ~= nil and myTeam ~= nil and teamId == myTeam) then
                local part = targetRoot(bot)
                if part and entityAlive(bot) then
                    local distance = (part.Position - root.Position).Magnitude
                    if distance <= range and (not bestDistance or distance < bestDistance) then
                        best, bestDistance = bot, distance
                    end
                end
            end
        end
    end
    return best, bestDistance
end

local function nearestEnemy(range)
    local player, playerDistance = nearestPlayer(range)
    local bot, botDistance = nearestBot(range)
    if not player then return bot, botDistance end
    if not bot then return player, playerDistance end
    if botDistance < playerDistance then return bot, botDistance end
    return player, playerDistance
end

local HUNT_MOBS = { Cow = true, Chicken = true }

local function nearestMob(range)
    local root = getRoot()
    if not root then return nil end
    local best, bestDistance
    for _, child in ipairs(workspace:GetChildren()) do
        if child:IsA("Model") and HUNT_MOBS[child.Name] then
            local part = targetRoot(child)
            local health = child:GetAttribute("Health")
            if part and (type(health) ~= "number" or health > 0) then
                local distance = (part.Position - root.Position).Magnitude
                if distance <= range and (not bestDistance or distance < bestDistance) then
                    best, bestDistance = child, distance
                end
            end
        end
    end
    return best, bestDistance
end

----------------------------------------------------------------
-- Chests
----------------------------------------------------------------
local chestSkip = {}
local chestCache = { at = -99, list = {} }

local function chestKey(chest)
    return chest:GetAttribute("__chestUid") or chest:GetAttribute("ChestId") or chest.Name
end

local function markChestSkip(chest, seconds)
    chestSkip[chestKey(chest)] = os.clock() + seconds
end

local function chestSpent(chest)
    if chest:GetAttribute("IsOpen") == true then return true end
    if chest:GetAttribute("BotEmptied") == true then return true end
    local key = chestKey(chest)
    if chestSkip[key] and chestSkip[key] > os.clock() then return true end
    return false
end

-- The chest list is rebuilt every few seconds instead of every tick: Outer
-- alone carries 130+ chests and the loop runs at 10 Hz.
local function chestList()
    if os.clock() - chestCache.at < 3 then return chestCache.list end
    chestCache.at = os.clock()
    local list = {}
    local matchChests = workspace:FindFirstChild("MatchChests")
    if matchChests then
        for _, region in ipairs(matchChests:GetChildren()) do
            for _, chest in ipairs(region:GetChildren()) do
                if chest:IsA("Model") then list[#list + 1] = chest end
            end
        end
    end
    chestCache.list = list
    return list
end

local function nearestChest(range)
    local root = getRoot()
    if not root then return nil end
    local best, bestDistance
    for _, chest in ipairs(chestList()) do
        if chest.Parent and not chestSpent(chest) then
            local core = chest:FindFirstChild("Core")
            if core and core:IsA("BasePart") then
                local distance = (core.Position - root.Position).Magnitude
                if distance <= range and (not bestDistance or distance < bestDistance)
                    and insideZone(core.Position, -25) then
                    best, bestDistance = chest, distance
                end
            end
        end
    end
    return best, bestDistance
end

local function waitForChestOpen(timeout)
    local deadline = os.clock() + timeout
    while os.clock() < deadline do
        if lp:GetAttribute("OpenChestId") then return true end
        task.wait(0.02)
    end
    return lp:GetAttribute("OpenChestId") ~= nil
end

local function lootChest(chest)
    local core = chest:FindFirstChild("Core")
    local prompt = core and core:FindFirstChildWhichIsA("ProximityPrompt")
    if not prompt then
        markChestSkip(chest, 120)
        return false
    end

    -- Speed matters here (the start freeze is short): land, open, move the
    -- wanted slots, close, leave. Every wait below is the minimum that still
    -- lets the server round-trip land.
    pivotTo(core.Position, core.Position, nil, true)
    task.wait(0.03)

    local root = getRoot()
    if not root or (core.Position - root.Position).Magnitude > 10 then
        return false -- still on the way; try again next tick
    end

    -- The prompt holds for 0 s, so begin/end back to back is enough. The
    -- server answers with ChestSnapshot, and the game's ChestClient then sets
    -- OpenChestId — that attribute is the real "it opened" signal.
    pcall(function() prompt:InputHoldBegin() end)
    task.wait(math.max(0.02, (prompt.HoldDuration or 0) + 0.02))
    pcall(function() prompt:InputHoldEnd() end)

    if not waitForChestOpen(0.8) then
        if type(fireproximityprompt) == "function" then
            pcall(fireproximityprompt, prompt)
        end
        if not waitForChestOpen(0.6) then
            markChestSkip(chest, 20)
            return false
        end
    end

    local chestId = lp:GetAttribute("OpenChestId")
    if not chestId then
        markChestSkip(chest, 20)
        return false
    end

    -- Read what is actually inside before moving anything: only wanted slots
    -- get quick-moved, and only from a snapshot that belongs to THIS chest (the
    -- previous chest's contents linger in the client view otherwise). A
    -- snapshot that cannot be read means take-everything rather than no loot.
    local chestSnapshot = waitForChestSnapshot(chestId)
    local readable = chestSnapshot ~= nil and chestSnapshot.Slots ~= nil
        and (chestSnapshot.ChestId == nil or chestSnapshot.ChestId == chestId)
    local owned = ownedBest(getSnapshot())
    for slot = 1, CHEST_SLOTS do
        if not RUNNING or not S.armed then break end
        local take = not readable
        if readable then
            local entry = chestSnapshot.Slots[tostring(slot)]
            local itemId = entry and entry.ItemId
            take = type(itemId) == "string" and wantsItem(itemId, owned)
        end
        if take and MoveChestItem then
            pcall(function()
                MoveChestItem:FireServer({
                    Action = "QuickMove",
                    FromContainer = "Chest",
                    ChestId = chestId,
                    FromSlot = slot,
                })
            end)
        end
        task.wait(0.005)
    end
    task.wait(0.03)
    if CloseChestRequest then
        pcall(function() CloseChestRequest:FireServer() end)
    end

    -- Do not sit on the close: the attribute clears on its own, and the next
    -- chest is worth more than the confirmation.
    local deadline = os.clock() + 0.15
    while os.clock() < deadline and lp:GetAttribute("OpenChestId") do task.wait(0.02) end

    stats.chests = stats.chests + 1
    markChestSkip(chest, 90)
    note(string.format("Chest %s looted", tostring(chestId)))
    return true
end

----------------------------------------------------------------
-- Ground drops
----------------------------------------------------------------
-- Drops are server-side proximity pickups rendered by ItemDropVisuals: the
-- Handle is CanTouch = false, so there is no touch signal to fire at all —
-- walking into them is what works, and standing on one is the bot equivalent.
local dropSkip = {}

local function dropKey(drop)
    return drop:GetAttribute("DropGuid") or drop.Name
end

-- No search radius: scan the whole ItemDrops folder for wanted items and take
-- the nearest one to `origin` (or to the character). The folder is small and
-- "walk to it" is a teleport anyway, so distance is just a travel-order hint.
local function nearestWantedDrop(origin, owned)
    local folder = workspace:FindFirstChild("ItemDrops")
    if not folder then return nil end

    local from = origin
    if not from then
        local root = getRoot()
        if not root then return nil end
        from = root.Position
    end

    local best, bestDistance
    for _, drop in ipairs(folder:GetChildren()) do
        local key = dropKey(drop)
        if not (dropSkip[key] and dropSkip[key] > os.clock()) then
            local handle = drop:FindFirstChild("Handle") or drop:FindFirstChildWhichIsA("BasePart")
            local itemId = drop:GetAttribute("ItemId")
            if handle and handle:IsA("BasePart") and type(itemId) == "string"
                and wantsItem(itemId, owned) and insideZone(handle.Position, -40) then
                local distance = (handle.Position - from).Magnitude
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = drop, distance
                end
            end
        end
    end
    return best, bestDistance
end

local function collectDrop(drop)
    local handle = drop:FindFirstChild("Handle") or drop:FindFirstChildWhichIsA("BasePart")
    if not (handle and handle:IsA("BasePart")) then return false end

    local root = getRoot()
    if not root then return false end

    if (handle.Position - root.Position).Magnitude > 1.5 then
        pivotTo(handle.Position, handle.Position, 1)
        root = getRoot()
        if not root then return false end
        if (handle.Position - root.Position).Magnitude > 1.5 then
            return false -- still moving in; try again next tick
        end
    end

    -- Stay on it: the pickup is a server-side proximity check, so the bot has
    -- to be physically on the drop and remain there until the server flies it
    -- in. Two attempts; an enemy walking in is never treated as a failure.
    local function waitForPickup(seconds)
        local deadline = os.clock() + seconds
        while os.clock() < deadline do
            if drop.Parent == nil then
                stats.drops = stats.drops + 1
                return true
            end
            if nearestEnemy(35) then
                return nil -- interrupted: do not blacklist
            end
            task.wait(0.1)
        end
        return false
    end

    local first = waitForPickup(2.0)
    if first then return true end
    if first == nil then return false end

    -- Second attempt from a fresh, closer pivot: the first spot can be
    -- slightly off (the hover, or a rate-limited pivot that did not land).
    if getRoot() then
        pivotTo(handle.Position, handle.Position, 0.5, true)
        task.wait(0.15)
    end
    local second = waitForPickup(1.6)
    if second then return true end
    if second == nil then return false end

    dropSkip[dropKey(drop)] = os.clock() + 15
    note("Drop " .. tostring(drop:GetAttribute("ItemId") or drop.Name) .. " would not pick up", "Warn")
    return true
end

----------------------------------------------------------------
-- Combat and food
----------------------------------------------------------------
local function firePrimary()
    if not (Router and UseSelectedItem) then return false end
    local ok, item, context, canUse = pcall(Router.BuildContext, "Primary")
    if not ok or not item or not canUse then return false end
    return (pcall(function()
        UseSelectedItem:FireServer({ InputType = "Primary", Context = context })
    end))
end

-- One aimed swing. The camera is pointed at the target for the instant the
-- context is built and restored in the same frame, so the player's camera is
-- never actually taken over — it is a synchronous block, nothing renders in
-- between, and no Scriptable mode is left behind.
local function firePrimaryAt(position)
    if not (Router and UseSelectedItem) then return false end

    local camera = workspace.CurrentCamera
    local savedCFrame = camera and camera.CFrame
    if camera and position then
        pcall(function()
            local root = getRoot()
            local origin = root and (root.Position + Vector3.new(0, 1.5, 0)) or savedCFrame.Position
            camera.CFrame = CFrame.lookAt(origin, position)
        end)
    end

    local ok, item, context, canUse = pcall(Router.BuildContext, "Primary")
    local fired = false
    if ok and item and canUse then
        fired = pcall(function()
            UseSelectedItem:FireServer({ InputType = "Primary", Context = context })
        end)
    end

    if camera and savedCFrame then
        pcall(function() camera.CFrame = savedCFrame end)
    end
    return fired
end

-- Put distance between us and a threat, without leaving the zone and without
-- dropping through the map. This also runs while eating: standing still to
-- heal is how the farm dies.
local function retreatFrom(enemy)
    local root = getRoot()
    if not root then return end
    local enemyPart = enemy and targetRoot(enemy)
    if not enemyPart then return end

    local safeDistance = tonumber(flag("SurvivorSafeDistance", 200)) or 200
    local away = root.Position - enemyPart.Position
    away = Vector3.new(away.X, 0, away.Z)
    if away.Magnitude < 0.1 then
        away = Vector3.new(1, 0, 0) -- degenerate: pick any direction
    end

    -- Stand on the safety circle around the enemy rather than "somewhere far
    -- away": once we are at the distance the spot stops moving, so the bot
    -- cannot ping-pong across the map.
    local dest = enemyPart.Position + away.Unit * safeDistance
    local center = zoneCenter()
    if center then
        dest = dest:Lerp(Vector3.new(center.X, dest.Y, center.Z), 0.25)
    end

    local spot = safeSpot(dest.X, dest.Z, root.Position.Y)
    if spot then
        pivotTo(spot, enemyPart.Position, nil, true)
    end
end

local function tryEat()
    if flag("SurvivorEatFood", true) ~= true then return false end
    local snapshot = getSnapshot()
    if not snapshot then return false end

    local foodId, slot = bestFood(snapshot)
    if not foodId then return false end

    if slot > HOTBAR_SLOTS then
        if MoveBackpackToHotbar then
            pcall(function() MoveBackpackToHotbar:FireServer(slot) end)
            task.wait(0.2)
            local _, movedSlot = bestFood(getSnapshot() or snapshot)
            slot = movedSlot
        else
            slot = nil
        end
    end
    if not slot or slot > HOTBAR_SLOTS then return false end
    if not selectHotbar(slot) then return false end

    setStatus("Eating " .. tostring(foodId))
    local used = firePrimary()

    -- Eating takes 1.6 s and walking is allowed during it (WalkMultiplier
    -- 0.55), so keep escaping for the whole meal: the bot must never stand
    -- still within reach of a player.
    local deadline = os.clock() + 1.9
    while os.clock() < deadline do
        local enemy, distance = nearestEnemy(600)
        local safeDistance = tonumber(flag("SurvivorSafeDistance", 200)) or 200
        if enemy and (not distance or distance < safeDistance) then
            retreatFrom(enemy)
        else
            local root = getRoot()
            if root and flag("SurvivorStayInZone", true) == true
                and not insideZone(root.Position, 25) then
                local center = zoneCenter()
                if center then
                    local spot = safeSpot(center.X, center.Z, root.Position.Y)
                    if spot then pivotTo(spot, spot, nil, true) end
                end
            end
        end
        task.wait(0.1)
    end

    if used then stats.eats = stats.eats + 1 end
    -- Put the weapon back in hand so the next tick can fight immediately.
    ensureBestWeapon()
    return true
end

local function engage(target)
    local part = targetRoot(target)
    if not part or not entityAlive(target) then return end

    if Inventory then
        local class = equippedClass()
        if not class then
            ensureBestWeapon()
            class = equippedClass()
        end
        if not class then
            setStatus("No weapon selected")
            return
        end
    end

    local root = getRoot()
    if not root then return end

    local follow = tonumber(flag("SurvivorFollowDistance", 5)) or 5

    -- Snap to the target's back on every tick, and again right before the
    -- swing. The target never gets to face us, so its swings have nothing to
    -- aim at — that is what makes these kills damage-free.
    local function snapBehind()
        local current = targetRoot(target)
        if not current then return nil end
        local spot = current.CFrame * CFrame.new(0, 0, follow)
        pivotTo(spot.Position, current.Position, nil, true)
        return current.Position
    end

    local aimPosition = snapBehind() or part.Position

    local now = os.clock()
    if now - S.lastAttack >= S.attackInterval then
        S.lastAttack = now
        aimPosition = snapBehind() or aimPosition
        if firePrimaryAt(aimPosition) then stats.attacks = stats.attacks + 1 end
    end

    S.target = target
    S.targetPosition = aimPosition
    S.lastTargetSeen = now

    local hp = entityHealthPercent(target)
    setStatus(string.format("Attacking %s%s", entityName(target),
        hp and string.format(" (%.0f%%)", hp) or ""))
end

local function flee()
    local enemy = nearestEnemy(600)
    if enemy then
        retreatFrom(enemy)
    else
        local center = zoneCenter()
        if center then
            local root = getRoot()
            local spot = safeSpot(center.X, center.Z, root and root.Position.Y or center.Y)
            if spot then pivotTo(spot, spot, nil, true) end
        end
    end
    setStatus("Retreating")
end

-- With StreamingEnabled on (it is on here), distant players are not
-- replicated at all — there is no position to teleport to. So "infinite
-- range" hunting means moving through the zone until someone streams in:
-- the storm keeps the survivors pulling toward the middle anyway.
local function patrolStep()
    local root = getRoot()
    if not root then return end
    if os.clock() - (S.lastPatrol or 0) < 1.5 then return end
    S.lastPatrol = os.clock()

    local x, z
    local zone = zoneInfo()
    if zone then
        local angle = math.random() * math.pi * 2
        local radius = zone.radius * (0.2 + math.random() * 0.55)
        x = zone.cx + math.cos(angle) * radius
        z = zone.cz + math.sin(angle) * radius
    else
        x = root.Position.X + math.random(-150, 150)
        z = root.Position.Z + math.random(-150, 150)
    end

    -- Land on the ground. A guessed height here used to drop the character
    -- under the map, and fall damage is on.
    local spot = safeSpot(x, z, root.Position.Y)
    setStatus("Patrolling for players")
    if spot then pivotTo(spot, spot) end
end

----------------------------------------------------------------
-- Match flow
----------------------------------------------------------------

-- A requeue search in progress: the end screen's Play Again label flips to
-- "CANCEL" (WinScreenClient drives it from the ReQueue attribute) and the
-- search frame counts up. Firing PlayAgain in that state CANCELS the search —
-- the start/stop matchmaking loop — so this must be checked first.
local function requeueSearchActive()
    if lp:GetAttribute("ReQueue") == true or lp:GetAttribute("ReQueueFound") == true then
        return true
    end
    local hotbar = PlayerGui:FindFirstChild("HotbarGui")
    local buttons = hotbar and hotbar:FindFirstChild("EndScreenButtons")
    local playAgain = buttons and buttons:FindFirstChild("PlayAgainButton")
    if playAgain then
        for _, descendant in ipairs(playAgain:GetDescendants()) do
            if descendant:IsA("TextLabel")
                and string.find(string.upper(descendant.Text), "CANCEL", 1, true) then
                return true
            end
        end
    end
    return false
end

local function tryRequeue(reason)
    if flag("SurvivorAutoRequeue", true) ~= true then
        setStatus("Match over - requeue is off")
        return false
    end
    if requeueSearchActive() then
        S.requeueAttempts = 0
        setStatus("Searching for a match")
        return false
    end
    -- PlayAgain is a nudge, not a metronome: the server resets the match on
    -- its own. Hammering it is how the client ends up flipping matchmaking
    -- on and off, so: a few spaced attempts per match, then wait quietly.
    if (S.requeueAttempts or 0) >= 3 then
        setStatus("Match over - waiting for the server")
        return false
    end
    if os.clock() - (S.lastRequeue or 0) < 15 then return false end
    S.lastRequeue = os.clock()
    S.requeueAttempts = (S.requeueAttempts or 0) + 1

    if EndScreenAction then
        pcall(function() EndScreenAction:FireServer("PlayAgain") end)
        stats.requeues = stats.requeues + 1
        note(string.format("PlayAgain sent (%s, attempt %d)", tostring(reason), S.requeueAttempts))
    end
    setStatus("Requeueing...")
    return true
end

local function endButtonsVisible()
    local hotbar = PlayerGui:FindFirstChild("HotbarGui")
    local buttons = hotbar and hotbar:FindFirstChild("EndScreenButtons")
    return buttons ~= nil and buttons.Visible == true
end

-- Phases seen live: "Waiting" (pre-match), "Starting" (cages), "Active"
-- (playing). PlayAgain is only worth firing once the phase stops being one of
-- those — verified live: fires while spectating an Active match changed
-- nothing, and firing during "Waiting" is even more pointless.
local function matchOver()
    local phase = matchPhase()
    if phase == nil then return true end
    return phase ~= "Waiting" and phase ~= "Starting" and phase ~= "Active"
end

local function checkRequeue()
    if S.dead or lp:GetAttribute("Spectating") == true or endButtonsVisible() then
        if matchOver() then
            tryRequeue(S.dead and "eliminated" or "end screen")
        else
            setStatus("Eliminated - waiting for the match to end")
        end
        return true
    end
    return false
end

local function tryQueue()
    if flag("SurvivorAutoQueue", false) ~= true then return end

    -- Same rule as the end screen: while the game is searching, touching the
    -- queue at all would cancel it.
    if requeueSearchActive() or lp:GetAttribute("InQueue") == true then
        S.queueFired = false
        setStatus("Queued - waiting for a match")
        return
    end

    -- ToggleQueueRequest is a TOGGLE. Firing it again while the game is
    -- already searching cancels the search — that is the start/stop loop:
    -- PlayAgain re-queues us, this cancels it, this starts it again. One
    -- attempt per lobby visit, then a slow retry only if nothing took.
    if S.queueFired and os.clock() - (S.lastQueue or 0) < 90 then
        setStatus("Waiting for matchmaking")
        return
    end
    if os.clock() - (S.lastQueue or 0) < 10 then return end
    S.lastQueue = os.clock()
    S.queueFired = true

    if not ToggleQueueRequest then
        setStatus("Queue remote missing")
        return
    end
    local mode = modeDropdown and modeDropdown:Get() or "Solo"
    pcall(function() ToggleQueueRequest:FireServer(mode) end)
    setStatus("Queued " .. tostring(mode))
end

----------------------------------------------------------------
-- The loop
----------------------------------------------------------------
local function enemyRange()
    if flag("SurvivorLimitRange", false) == true then
        return tonumber(flag("SurvivorTargetRange", 250)) or 250
    end
    return math.huge -- hunt anywhere on the map
end

local function stepFarm()
    local humanoid = getHumanoid()
    local root = getRoot()
    if not (humanoid and root) then
        -- Eliminated and spectating, or between respawns. The requeue logic
        -- still applies here — parking on this branch is how the loop goes
        -- quiet with the end screen already up.
        if isInMatch() == true then
            local phase = matchPhase()
            if phase == "Starting" then
                -- Cage phase: no character yet on purpose. PlayAgain here
                -- would be noise, not a requeue.
                setStatus("Waiting for the match to start...")
            elseif checkRequeue() then
                return
            elseif lp:GetAttribute("Spectating") == true then
                setStatus("Eliminated - spectating")
            else
                setStatus("Waiting for character...")
            end
        else
            setStatus("In lobby")
            tryQueue()
        end
        return
    end
    zeroVelocity(root)

    if isInMatch() ~= true then
        setStatus("In lobby")
        tryQueue()
        return
    end

    -- Safety net: a bad teleport must never leave the character falling in
    -- the void (fall damage is enabled and this map has void below it).
    if humanoid:GetState() == Enum.HumanoidStateType.Freefall
        and not groundBelow(root.Position, 500) then
        local center = zoneCenter()
        if center then
            setStatus("Rescuing from a fall")
            local spot = safeSpot(center.X, center.Z, center.Y)
            if spot then pivotTo(spot, nil, nil, true) end
            return
        end
    end

    if humanoid.Health <= 0 then return end

    local phase = matchPhase()
    if phase == nil or phase == "Waiting" or phase == "Starting" or phase == "Active" then
        S.requeueAttempts = 0 -- a live match: the next end screen gets fresh attempts
    else
        tryRequeue("phase " .. tostring(phase))
        return
    end

    -- Pre-match freeze: everyone is caged, so this is free real estate — go
    -- empty the chests before anybody can move. This runs BEFORE the
    -- eliminated/end-screen check on purpose: right after the hop into a new
    -- match those flags are still set from the previous one, and they used to
    -- stall the raid until the countdown had already finished.
    if phase == "Waiting" or phase == "Starting" or lp:GetAttribute("CanDealDamage") == false then
        if flag("SurvivorPreMatchLoot", true) == true then
            local chest = nearestChest(3000)
            if chest then
                setStatus("Pre-match chest run")
                if lootChest(chest) then return end
            end
        end
        setStatus("Waiting for the match to start...")
        return
    end

    if checkRequeue() then return end

    -- gear hygiene runs everywhere, including mid-fight (throttled)
    if os.clock() - S.lastSweep > 4 then
        S.lastSweep = os.clock()
        sweepInventory(getSnapshot())
    end

    if flag("SurvivorStayInZone", true) == true and not insideZone(root.Position, 25) then
        -- chase fights win over running back; only head for the centre when
        -- nobody is on screen
        if not nearestEnemy(220) then
            local center = zoneCenter()
            if center then
                setStatus("Storm - moving to the zone")
                pivotTo(center, center)
            end
            return
        end
    end

    -- Keep the best weapon selected between everything else (throttled: the
    -- snapshot read and the select round-trip are not free).
    if os.clock() - S.lastEquipCheck > 1.5 then
        S.lastEquipCheck = os.clock()
        ensureBestWeapon()
    end

    local snapshot = getSnapshot()
    local owned = ownedBest(snapshot)

    local hp = humanoid.MaxHealth > 0 and (humanoid.Health / humanoid.MaxHealth * 100) or 100
    local hunger = lp:GetAttribute("Hunger")
    local eatBelow = tonumber(flag("SurvivorEatBelowHp", 65)) or 65
    local retreatBelow = tonumber(flag("SurvivorRetreatBelowHp", 35)) or 35
    local lowHunger = type(hunger) == "number" and hunger < 6
    local hurt = hp < retreatBelow

    -- The player or animal we were fighting is gone: its gear (or its meat)
    -- is on the floor right there. Remember where, so the drop gets picked up
    -- even while retreating — that is how a hurt run eats again.
    if S.target and not entityAlive(S.target) then
        if S.targetPosition then
            S.lootUntil = os.clock() + 8
            S.lootPosition = S.targetPosition
        end
        S.target = nil
    end

    local function collectKillDrop()
        if os.clock() >= (S.lootUntil or 0) or not S.lootPosition then return false end
        local drop = nearestWantedDrop(S.lootPosition, owned)
        if not drop then
            S.lootUntil = 0
            return false
        end
        setStatus("Looting the kill")
        collectDrop(drop)
        return true
    end

    if flag("SurvivorEatFood", true) == true and (hp < eatBelow or lowHunger) then
        if tryEat() then return end
    end

    if hurt then
        -- Distance is life: move away first, then heal while running (tryEat
        -- keeps escaping for the whole meal), and only pick a fight with an
        -- animal once nobody is inside the safety distance.
        local enemy, enemyDistance = nearestEnemy(600)
        if enemy then retreatFrom(enemy) end

        if collectKillDrop() then return end
        if flag("SurvivorEatFood", true) == true and tryEat() then return end

        local safeDistance = tonumber(flag("SurvivorSafeDistance", 200)) or 200
        local safeFromPlayers = not enemy or (enemyDistance or 0) >= safeDistance
        if safeFromPlayers and flag("SurvivorHuntMobs", true) == true
            and owned.foodCount < foodTarget() then
            local mob = nearestMob(300)
            if mob then
                engage(mob)
                return
            end
        end
        if not enemy then
            flee()
        end
        return
    end

    if collectKillDrop() then return end

    -- Upgrades outrank fights: a Diamond axe or a better armor piece on the
    -- floor is the whole point of the loot filter, and going to get it is one
    -- teleport. collectDrop only bails out if someone is already on top of us.
    local drop = nearestWantedDrop(nil, owned)
    if drop then
        setStatus("Collecting a drop")
        if collectDrop(drop) then return end
    end

    -- Hunters next: players and bots anywhere on the map.
    local enemy = flag("SurvivorTargetPlayers", true) == true and nearestEnemy(enemyRange()) or nil
    if enemy then
        engage(enemy)
        return
    end

    if flag("SurvivorLootChests", false) == true and not nearestEnemy(45) then
        local chest = nearestChest(tonumber(flag("SurvivorChestRange", 320)) or 320)
        if chest then
            setStatus("Looting a chest")
            if lootChest(chest) then return end
        end
    end

    -- Animals stop being interesting once the pantry is stocked.
    if flag("SurvivorHuntMobs", true) == true and owned.foodCount < foodTarget() then
        local mob = nearestMob(math.min(enemyRange(), 300))
        if mob then
            engage(mob)
            return
        end
    end

    -- Nothing visible: hunt the map instead of idling.
    if os.clock() - S.lastTargetSeen > 2 then
        patrolStep()
    else
        setStatus("Scanning for targets...")
    end
end

local lastStatsAt = 0
local function mainLoop()
    while RUNNING do
        -- 20 Hz: an attack loop that re-positions behind the target needs to
        -- keep up with it, not lag a heartbeat behind.
        task.wait(0.05)
        if S.armed then
            local ok, err = pcall(stepFarm)
            if not ok then note("step: " .. tostring(err), "Warn") end
        end
        if os.clock() - lastStatsAt > 1 and statsPara then
            lastStatsAt = os.clock()
            pcall(function()
                statsPara:Set(string.format(
                    "chests %d  |  drops %d  |  attacks %d  |  eats %d  |  junk %d  |  requeues %d",
                    stats.chests, stats.drops, stats.attacks, stats.eats, stats.junk, stats.requeues))
            end)
        end
    end
end

----------------------------------------------------------------
-- Arm / disarm
----------------------------------------------------------------
local function setArmed(value)
    value = value == true
    local was = S.armed
    S.armed = value

    if value then
        if not rearmAfterTeleport() and not S.rearmWarned then
            S.rearmWarned = true
            note("No queue_on_teleport here - the farm stops at the next place change", "Warn")
        end
        writeIntent(true, modeDropdown and modeDropdown:Get() or "Solo")
        if not was then
            note("Armed")
            EZ:Notify({
                Title = "Autofarm armed",
                Content = "Hunting players; upgrades, food and arrows get picked up.",
                Type = "success",
                Duration = 4,
            })
        end
    else
        writeIntent(false, modeDropdown and modeDropdown:Get() or "Solo")
        setStatus("Idle")
        if was then
            note("Disarmed")
            EZ:Notify({
                Title = "Autofarm stopped",
                Content = "Idle until the master toggle is on again.",
                Type = "info",
                Duration = 3,
            })
        end
    end
end

----------------------------------------------------------------
-- Character hooks
----------------------------------------------------------------
local function onCharacterAdded(character)
    S.dead = false
    S.lastRequeue = 0
    S.requeueAttempts = 0
    S.lastAttack = 0
    S.target = nil
    S.lootUntil = 0

    local humanoid = find(character, "Humanoid", 5)
    if not humanoid then return end
    track(humanoid.Died:Connect(function()
        if not S.armed then return end
        S.dead = true
        stats.deaths = stats.deaths + 1
        note("Died")
    end))
end

track(lp.CharacterAdded:Connect(onCharacterAdded))
if lp.Character then
    task.spawn(onCharacterAdded, lp.Character)
end

----------------------------------------------------------------
-- UI
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "Survivor Games",
    SubTitle = "hunter mode",
    ToggleKey = Enum.KeyCode.RightShift,
    ToggleIcon = "swords",
})
QuickBar:Bind(EZ, Window)
NotifHistory:Bind(EZ, Window)

local mainTab = Window:AddTab("Farm", "target")
local masterBox = mainTab:AddLeftGroupbox("Master", "power")
local loopBox = mainTab:AddRightGroupbox("Match loop", "repeat")

masterToggle = masterBox:AddToggle("SurvivorMaster", {
    Text = "Enable Auto Farm",
    Description = "Hunts players, takes only upgrades, requeues itself.",
    Default = false,
    Callback = function(value) setArmed(value) end,
})

statusLabel = masterBox:AddLabel("Idle")
masterBox:AddDivider("Session")
statsPara = masterBox:AddParagraph({
    Title = "Counters",
    Content = "chests 0  |  drops 0  |  attacks 0",
})

loopBox:AddToggle("SurvivorAutoQueue", {
    Text = "Auto queue from the lobby",
    Description = "Only needed if rematching ever stalls: PlayAgain already re-queues. The remote toggles, so this fires once and waits rather than flipping it.",
    Default = false,
})
modeDropdown = loopBox:AddDropdown("SurvivorMode", {
    Text = "Queue mode",
    Values = { "Solo", "Duos", "Squads" },
    Default = "Solo",
    Callback = function(value)
        if S.armed then writeIntent(true, value) end
    end,
})
loopBox:AddToggle("SurvivorAutoRequeue", {
    Text = "Auto requeue after death or victory",
    Description = "Sends the end screen's PlayAgain action.",
    Default = true,
})

local combatTab = Window:AddTab("Combat", "crosshair")
local targetBox = combatTab:AddLeftGroupbox("Targets", "users")
local weaponBox = combatTab:AddRightGroupbox("Weapon", "sword")

targetBox:AddToggle("SurvivorTargetPlayers", {
    Text = "Attack other players",
    Default = true,
})
targetBox:AddToggle("SurvivorLimitRange", {
    Text = "Limit target range",
    Description = "Off = hunt players anywhere on the map (recommended).",
    Default = false,
})
targetBox:AddSlider("SurvivorTargetRange", {
    Text = "Target range",
    Min = 40, Max = 600, Increment = 10, Default = 250,
    Suffix = " studs",
    VisibleWhen = "SurvivorLimitRange",
})
targetBox:AddSlider("SurvivorFollowDistance", {
    Text = "Follow distance",
    Min = 2, Max = 12, Increment = 0.5, Default = 5,
    Suffix = " studs",
})

weaponBox:AddToggle("SurvivorAutoUpgrade", {
    Text = "Auto-equip the best weapon",
    Description = "Reads the live inventory (ClientInventoryView), not the hotbar images.",
    Default = true,
})
weaponBox:AddToggle("SurvivorPreferAxe", {
    Text = "Prefer the axe on equal tier",
    Description = "Axes hit harder per swing; swords swing roughly four times as fast.",
    Default = true,
})

local lootTab = Window:AddTab("Loot", "package")
local chestBox = lootTab:AddLeftGroupbox("Chests", "box")
local dropBox = lootTab:AddRightGroupbox("Drops and cleanup", "gem")

chestBox:AddToggle("SurvivorLootChests", {
    Text = "Open and loot chests",
    Description = "Off by default: kills carry better gear than chests. Filtered when on.",
    Default = false,
})
chestBox:AddToggle("SurvivorPreMatchLoot", {
    Text = "Loot chests during the start freeze",
    Description = "Everyone is caged before the match — empty chests while nobody can move.",
    Default = true,
})
chestBox:AddSlider("SurvivorChestRange", {
    Text = "Chest search range",
    Min = 50, Max = 600, Increment = 10, Default = 320,
    Suffix = " studs",
    VisibleWhen = "SurvivorLootChests",
})

dropBox:AddToggle("SurvivorCollectDrops", {
    Text = "Collect wanted ground drops",
    Description = "Scans workspace.ItemDrops anywhere on the map and teleports to upgrades.",
    Default = true,
})
dropBox:AddToggle("SurvivorDropJunk", {
    Text = "Throw out junk gear",
    Description = "Drops lower-tier armor, duplicate weapons and outclassed bows.",
    Default = true,
})

local survivalTab = Window:AddTab("Survival", "heart")
local foodBox = survivalTab:AddLeftGroupbox("Food", "apple")
local zoneBox = survivalTab:AddRightGroupbox("Safety", "shield")

foodBox:AddToggle("SurvivorEatFood", {
    Text = "Eat food to heal",
    Description = "Meat heals 25, GoldApple 40; also feeds the hunger bar.",
    Default = true,
})
foodBox:AddSlider("SurvivorEatBelowHp", {
    Text = "Eat below HP",
    Min = 0, Max = 100, Increment = 5, Default = 65,
    Suffix = "%",
})
foodBox:AddSlider("SurvivorRetreatBelowHp", {
    Text = "Retreat below HP",
    Min = 0, Max = 100, Increment = 5, Default = 35,
    Suffix = "%",
})
foodBox:AddSlider("SurvivorFoodTarget", {
    Text = "Keep food stocked at",
    Min = 1, Max = 12, Increment = 1, Default = 4,
    Tooltip = "Meals to carry. At or above this, meat on the floor is ignored and animals stop being hunted.",
})
foodBox:AddToggle("SurvivorHuntMobs", {
    Text = "Hunt cows and chickens",
    Description = "Food mobs: workspace.Cow / workspace.Chicken, killed for Meat.",
    Default = true,
})

zoneBox:AddToggle("SurvivorStayInZone", {
    Text = "Stay inside the closing zone",
    Description = "Reads workspace.ZoneState; fights still win over running back.",
    Default = true,
})
zoneBox:AddSlider("SurvivorSafeDistance", {
    Text = "Safety distance",
    Min = 50, Max = 600, Increment = 10, Default = 200,
    Suffix = " studs",
    Tooltip = "While hurt or eating, the bot keeps at least this much space from the nearest player.",
})

local movementTab = Window:AddTab("Movement", "move")
local movementBox = movementTab:AddLeftGroupbox("Teleport pacing", "gauge")
movementBox:AddSlider("SurvivorPositionRate", {
    Text = "Position updates",
    Min = 5, Max = 30, Increment = 1, Default = 15,
    Suffix = " Hz",
})
movementBox:AddSlider("SurvivorHoverHeight", {
    Text = "Hover height",
    Min = 1, Max = 8, Increment = 0.5, Default = 3.5,
    Suffix = " studs",
})

local infoTab = Window:AddTab("Info", "info")
local howBox = infoTab:AddLeftGroupbox("How it works", "book-open")
local diagBox = infoTab:AddRightGroupbox("Diagnostics", "activity")

howBox:AddParagraph({
    Title = "Hunter first",
    Content = "Players are hunted anywhere on the map — no range limit. After a kill the bot "
        .. "loots the body for a few seconds, because the gear that player carried is on the "
        .. "floor right there, then moves on to the next fight.",
})
howBox:AddParagraph({
    Title = "Upgrades only",
    Content = "A drop or chest slot is only taken when it beats what is already carried: a "
        .. "higher-tier axe/sword/bow, a better armor piece, food, and arrows while a bow is "
        .. "held. Lower-tier armor, duplicate weapons and outclassed bows are thrown out with "
        .. "the game's own DropInventoryItem.",
})
howBox:AddParagraph({
    Title = "Across teleports",
    Content = "queue_on_teleport re-runs the hub loader in the next place, and survivor-games-intent.txt "
        .. "remembers whether the farm was on. The master toggle writes that file; closing the window "
        .. "only stops the current instance.",
})
howBox:AddParagraph({
    Title = "Debugging a local edit",
    Content = 'getgenv().SurvivorRearm = [[...]] replaces the queued code, so an edited file can '
        .. "be tested across a teleport before it is pushed.",
})

diagBox:AddButton({
    Text = "Copy status as text",
    Callback = function()
        local state = matchState()
        local snapshot = getSnapshot()
        local text = table.concat({
            "status=" .. tostring(S.status),
            "armed=" .. tostring(S.armed),
            "inMatch=" .. tostring(isInMatch()),
            "phase=" .. tostring(state and state:GetAttribute("Phase") or "?"),
            "playersAlive=" .. tostring(state and state:GetAttribute("PlayersAlive") or "?"),
            "selectedSlot=" .. tostring(snapshot and snapshot.SelectedHotbarSlot or "?"),
            "attackInterval=" .. string.format("%.2f", S.attackInterval),
            "chests=" .. stats.chests,
            "drops=" .. stats.drops,
            "attacks=" .. stats.attacks,
            "eats=" .. stats.eats,
            "junk=" .. stats.junk,
            "requeues=" .. stats.requeues,
            "deaths=" .. stats.deaths,
        }, "\n")
        if type(setclipboard) == "function" then pcall(setclipboard, text) end
        EZ:Notify({ Title = "Copied", Content = "Status copied to the clipboard.", Type = "success" })
    end,
})
logConsole = diagBox:AddLog({ MaxLines = 120, Height = 220 })

QuickBar:Pin("SurvivorMaster", { Icon = "target" })

SaveManager:LoadAutoloadConfig()

-- Resume from the last session. `ok` guards against a failed read being
-- treated as "off" and then written back (see the intent file note above).
local intent = readIntent()
if intent.ok then
    if intent.mode then
        pcall(function() modeDropdown:Set(intent.mode) end)
    end
    if intent.enabled then
        note("Resuming armed from the last session")
        pcall(function() masterToggle:Set(true) end)
    end
end

EZ:SetAntiAFK(true)
note("Ready - flip the master toggle to start")

----------------------------------------------------------------
-- Diagnostics + teardown
----------------------------------------------------------------
local function destroy(keepIntent)
    if not RUNNING then return end
    RUNNING = false
    if S.armed then
        S.armed = false
        if not keepIntent then
            writeIntent(false, modeDropdown and modeDropdown:Get() or "Solo")
        end
    end
    for _, conn in ipairs(Conns) do
        pcall(function() conn:Disconnect() end)
    end
    Conns = {}
    local g = getgenv and getgenv()
    if g and g.__SURVIVOR_FARM then
        g.__SURVIVOR_FARM = nil
    end
end

local handle = {
    status = function() return S.status, S.armed end,
    debug = function()
        local owned = ownedBest(getSnapshot())
        return string.format(
            "status=%s armed=%s chests=%d drops=%d attacks=%d eats=%d junk=%d requeues=%d deaths=%d food=%d",
            tostring(S.status), tostring(S.armed), stats.chests, stats.drops, stats.attacks,
            stats.eats, stats.junk, stats.requeues, stats.deaths, owned.foodCount)
    end,
    arm = function(value) masterToggle:Set(value and true or false) end,
    stop = function() destroy(false) end,
}

local g = getgenv and getgenv()
if g then
    g.__SURVIVOR_FARM = handle
    g.__SURVIVOR_FARM_DESTROY = destroy
end

EZ:OnDestroy(function()
    -- keepIntent: a teardown is often external (another script loading the
    -- library, the loader's catalog fallback), and it must not flip the farm
    -- to "off" in the intent file. Only the toggle and handle.stop() do that.
    pcall(destroy, true)
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHistory:Destroy() end)
end)

task.spawn(mainLoop)
