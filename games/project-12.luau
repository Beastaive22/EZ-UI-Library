-- Game guard: this module only runs in its own game.
-- game.GameId is the universe id (9286558970), so every place in that
-- game matches. Anywhere else (autoexec, a shared hub, a wrong map
-- entry) it exits before touching anything.
if game.GameId ~= 9286558970 then return end

--[[
    Project 12 Hub - game script built on EZ UI Library
    Target game: "Project 12 [BODY CAM!]" (place 79966250354565)

    Load:
        loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/games/Project12.lua"))()

    Features
        - Vehicle tuner: engine, traction, steering, suspension + presets (live-apply)
        - Fast melee: zero cooldowns + custom windup/swing speed, restore support
        - Gun/taser tuner: fire rate + reload time
        - Live telemetry: speed bar, gear, engine speed
        - Auto re-tune: reapplies your tune if the server respawns the vehicle
    Every element registers a flag, so the built-in SaveManager persists all of it.
]]

local EZ
local __ok, __err = pcall(function()
local base = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local EZ0       = loadstring(game:HttpGet(base .. "Library.lua"))()
local Icons     = loadstring(game:HttpGet(base .. "addons/Icons.lua"))()
local ThemeMgr  = loadstring(game:HttpGet(base .. "addons/ThemeManager.lua"))()
local SaveMgr   = loadstring(game:HttpGet(base .. "addons/SaveManager.lua"))()
local QuickBar  = loadstring(game:HttpGet(base .. "addons/QuickBar.lua"))()
local NotifHist = loadstring(game:HttpGet(base .. "addons/NotificationHistory.lua"))()
EZ = EZ0

EZ:SetIcons(Icons)
SaveMgr:Bind(EZ, "P12Configs")
ThemeMgr:Bind(EZ, { File = "P12_Theme.txt" })

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------------
-- GAME STATE
----------------------------------------------------------------
local vehicleIndex = {}   -- dropdown key -> Model
local stock = {}          -- model -> {motors = {...}, wheels = {...}, susp = {...}, roll = {...}}
local lastTune = nil      -- table of applied values (for auto re-tune)

local melee = {
    originalExecute = nil,
    originalCooldowns = nil,
    lastTrack = nil,
    lastSide = "Left",
    windup = 0.05,
    swingSpeed = 2.5,
    patched = false,
}


local sliderHandles = {}
local meleeStatusText = "Fast melee: OFF"

local function notify(title, content, kind)
    EZ:Notify({ Title = title, Content = content, Duration = 3, Type = kind or "info" })
end

local function find_vehicles()
    local ws = workspace:FindFirstChild("Vehicles")
    return ws and ws:GetChildren() or {}
end

local function build_vehicle_values()
    vehicleIndex = {}
    local values, order = {}, {}
    for _, v in find_vehicles() do
        if v:IsA("Model") and v:FindFirstChild("Motors") then
            local owner = v:GetAttribute("OwnerUserId")
            local key = v.Name .. ":" .. tostring(owner)
            local tag = (owner == LocalPlayer.UserId) and " (yours)" or ""
            vehicleIndex[key] = v
            values[key] = v.Name .. tag
            table.insert(order, key)
        end
    end
    -- dictionary form is fine for dropdown Refresh/Values
    return values
end

local function get_selected(key)
    return key and vehicleIndex[key] or nil
end

local function remember_stock(model)
    if stock[model] then return end
    local entry = { motors = {}, wheels = {}, susp = {}, roll = {} }
    local m = model:FindFirstChild("Motors")
    if m then
        for _, k in { "forwardMaxSpeed", "reverseMaxSpeed", "acceleration", "minSpeedTorque",
                      "maxSpeedTorque", "braking", "handBrakeTorque", "deceleration" } do
            entry.motors[k] = m:GetAttribute(k)
        end
    end
    local w = model:FindFirstChild("Wheels")
    if w then
        entry.wheels.slipThreshold = w:GetAttribute("slipThreshold")
        entry.wheels.staticFriction = w:GetAttribute("staticFriction")
        entry.wheels.kineticFriction = w:GetAttribute("kineticFriction")
        for _, p in w:GetChildren() do
            if p:IsA("BasePart") then entry.wheels[p] = p:GetAttribute("FrictionMultiplier") end
        end
    end
    local s, r = model:FindFirstChild("Suspension"), model:FindFirstChild("AntiRoll")
    if s then
        entry.susp.stiffness = s:GetAttribute("frontSuspensionStiffness")
        entry.susp.damping = s:GetAttribute("frontSuspensionDamping")
    end
    if r then
        entry.roll.stiffness = r:GetAttribute("frontAntiRollBarStiffness")
        entry.roll.damping = r:GetAttribute("frontAntiRollBarDamping")
    end
    local st = model:FindFirstChild("Steering")
    if st then entry.steeringReduction = st:GetAttribute("steeringReduction") end
    entry.rideOffset = 0
    stock[model] = entry
end

local function apply_motors(model, vals)
    local m = model and model:FindFirstChild("Motors")
    if not m then return false end
    remember_stock(model)
    for k, v in pairs(vals) do
        m:SetAttribute(k, v)
    end
    lastTune = lastTune or {}
    for k, v in pairs(vals) do lastTune[k] = v end
    return true
end

local function apply_grip(model, mult, slip)
    local w = model and model:FindFirstChild("Wheels")
    if not w then return false end
    remember_stock(model)
    if slip then w:SetAttribute("slipThreshold", slip) end
    -- narrow the static/kinetic friction gap: the client controller rewrites wheel
    -- friction every frame and flips between these two when slip crosses the
    -- threshold - a big gap makes the tires visibly vibrate at the boundary
    w:SetAttribute("staticFriction", 1.1)
    w:SetAttribute("kineticFriction", 1.05)
    if mult then
        for _, p in w:GetChildren() do
            if p:IsA("BasePart") then p:SetAttribute("FrictionMultiplier", mult) end
        end
    end
    return true
end

local function apply_steering(model, reduction, rackSpeed, rackForce)
    local st = model and model:FindFirstChild("Steering")
    if not st then return false end
    remember_stock(model)
    if reduction then st:SetAttribute("steeringReduction", reduction) end
    local rack = st:FindFirstChild("Rack") or st:FindFirstChild("Hinge")
    if rack then
        if rackSpeed then rack.Speed = rackSpeed end
        if rackForce and rack.MotorMaxForce then rack.MotorMaxForce = rackForce end
    end
    return true
end

local function apply_suspension(model, stiffness, damping, rollStiffness, rollDamping, freeLength)
    local s = model and model:FindFirstChild("Suspension")
    local r = model and model:FindFirstChild("AntiRoll")
    if not (s or r) then return false end
    remember_stock(model)
    if s then
        local base = stock[model] and stock[model].rideOffset or 0
        for _, c in s:GetChildren() do
            if c:IsA("SpringConstraint") then
                if stiffness then c.Stiffness = stiffness end
                if damping then c.Damping = damping end
                if freeLength and c.FreeLength then c.FreeLength = c.FreeLength + (freeLength - base) end
            end
        end
        if stiffness then
            s:SetAttribute("frontSuspensionStiffness", stiffness)
            s:SetAttribute("rearSuspensionStiffness", stiffness)
        end
        if damping then
            s:SetAttribute("frontSuspensionDamping", damping)
            s:SetAttribute("rearSuspensionDamping", damping)
        end
        if freeLength and stock[model] then stock[model].rideOffset = freeLength end
    end
    if r then
        for _, c in r:GetChildren() do
            if c:IsA("SpringConstraint") then
                if rollStiffness then c.Stiffness = rollStiffness end
                if rollDamping then c.Damping = rollDamping end
            end
        end
        if rollStiffness then
            r:SetAttribute("frontAntiRollBarStiffness", rollStiffness)
            r:SetAttribute("rearAntiRollBarStiffness", rollStiffness)
        end
        if rollDamping then
            r:SetAttribute("frontAntiRollBarDamping", rollDamping)
            r:SetAttribute("rearAntiRollBarDamping", rollDamping)
        end
    end
    return true
end

local function apply_full_tune(model, t)
    apply_motors(model, {
        forwardMaxSpeed = t.topSpeed,
        reverseMaxSpeed = t.reverse,
        acceleration = t.accel,
        minSpeedTorque = t.minTorque,
        maxSpeedTorque = t.maxTorque,
        braking = t.braking,
    })
    apply_grip(model, t.friction, t.slip)
    apply_steering(model, t.reduction, t.rackSpeed, t.rackForce)
    apply_suspension(model, t.spring, t.suspDamping, t.rollStiff, t.rollDamp, t.rideHeight)
end

----------------------------------------------------------------
-- WINDOW + TABS
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "Project 12",
    SubTitle = "vehicle + combat hub",
    ToggleKey = Enum.KeyCode.RightShift,
    ToggleIcon = "car",
})

QuickBar:Bind(EZ, Window)
NotifHist:Bind(EZ, Window)
EZ:OnDestroy(function()
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHist:Destroy() end)
    RunService:UnbindFromRenderStep("P12_Telemetry")
end)

local VehTab  = Window:AddTab("Vehicle", "car")
local ComTab  = Window:AddTab("Combat", "swords")
local TeleTab = Window:AddTab("Telemetry", "gauge")

----------------------------------------------------------------
-- VEHICLE TAB
----------------------------------------------------------------
local VehSelect = VehTab:AddSection("Vehicle")

local selectedVehicleKey = nil

local vehDropdown = VehSelect:AddDropdown("veh_select", {
    Text = "Target vehicle",
    Values = build_vehicle_values(),
    Searchable = true,
    Callback = function(v) selectedVehicleKey = v end,
})

local function target_model()
    local model = get_selected(selectedVehicleKey)
    if not model or not model.Parent then
        notify("Vehicle", "Select a vehicle first", "warning")
        return nil
    end
    return model
end

VehSelect:AddButton({
    Text = "Refresh vehicle list",
    Tooltip = "Re-scan workspace for spawnable/owned vehicles",
    Callback = function()
        vehDropdown:Refresh(build_vehicle_values())
        notify("Vehicle", "List refreshed")
    end,
})

local Engine = VehTab:AddLeftGroupbox("Engine", "rocket")
local Grip   = VehTab:AddLeftGroupbox("Traction", "target")
local Steer  = VehTab:AddRightGroupbox("Steering", "compass")
local Susp   = VehTab:AddRightGroupbox("Suspension", "activity")

local tune = {
    topSpeed = 160, reverse = 40, accel = 28,
    minTorque = 45000, maxTorque = 12000, braking = 16000,
    friction = 1.5, slip = 10,
    reduction = 0.05, rackSpeed = 10, rackForce = 500000,
    -- suspension defaults to STOCK: dev-tuned springs are the stable baseline,
    -- only touch these if you specifically want a different ride
    spring = 15000, suspDamping = 300, rollStiff = 16000, rollDamp = 100, rideHeight = 0,
}

local function mslider(section, id, text, min, max, default, suffix, applyKey)
    sliderHandles[id] = section:AddSlider(id, {
        Text = text, Min = min, Max = max, Default = default,
        Increment = (max - min) > 1000 and 500 or (max <= 60 and 0.5 or 1),
        Suffix = suffix,
        Callback = function(v)
            tune[applyKey] = v
            local model = get_selected(selectedVehicleKey)
            if model then apply_full_tune(model, tune) end
        end,
    })
    return sliderHandles[id]
end

mslider(Engine, "v_topSpeed", "Top speed", 10, 400, tune.topSpeed, " mph", "topSpeed")
mslider(Engine, "v_reverse", "Reverse speed", 5, 120, tune.reverse, " mph", "reverse")
mslider(Engine, "v_accel", "Acceleration", 5, 100, tune.accel, "", "accel")
mslider(Engine, "v_minTorque", "Launch torque", 1000, 200000, tune.minTorque, "", "minTorque")
mslider(Engine, "v_maxTorque", "Top torque", 1000, 60000, tune.maxTorque, "", "maxTorque")
mslider(Engine, "v_braking", "Braking", 1000, 50000, tune.braking, "", "braking")

mslider(Grip, "v_friction", "Wheel grip multiplier", 0.5, 3, tune.friction, "x", "friction")
mslider(Grip, "v_slip", "Slip threshold", 0, 50, tune.slip, "", "slip")

mslider(Steer, "v_reduction", "High-speed steering cut", 0, 0.6, tune.reduction, "", "reduction")
mslider(Steer, "v_rackSpeed", "Steering rack speed", 4, 25, tune.rackSpeed, "", "rackSpeed")
mslider(Steer, "v_rackForce", "Steering rack force", 100000, 1500000, tune.rackForce, "", "rackForce")

mslider(Susp, "v_spring", "Spring stiffness", 5000, 80000, tune.spring, "", "spring")
mslider(Susp, "v_suspDamp", "Spring damping", 100, 2000, tune.suspDamping, "", "suspDamping")
mslider(Susp, "v_rollStiff", "Anti-roll stiffness", 5000, 120000, tune.rollStiff, "", "rollStiff")
mslider(Susp, "v_rollDamp", "Anti-roll damping", 50, 1500, tune.rollDamp, "", "rollDamp")
sliderHandles.v_ride = Susp:AddSlider("v_ride", {
    Text = "Ride height offset", Min = -1, Max = 1, Default = 0, Increment = 0.05, Suffix = "",
    Callback = function(v)
        tune.rideHeight = v
        local model = get_selected(selectedVehicleKey)
        if model then apply_full_tune(model, tune) end
    end,
})

local Presets = VehTab:AddRightGroupbox("Presets", "sparkles")

local presets = {
    Stock    = { topSpeed = nil, useStock = true },
    Sport    = { topSpeed = 160, reverse = 40, accel = 28, minTorque = 45000, maxTorque = 12000, braking = 16000, friction = 1.5, slip = 10, reduction = 0.05, rackSpeed = 10, rackForce = 500000, spring = 15000, suspDamping = 300, rollStiff = 16000, rollDamp = 100 },
    Drag     = { topSpeed = 220, reverse = 40, accel = 45, minTorque = 90000, maxTorque = 22000, braking = 20000, friction = 1.6, slip = 20, reduction = 0.02, rackSpeed = 10, rackForce = 600000, spring = 15000, suspDamping = 300, rollStiff = 16000, rollDamp = 100 },
    Drift    = { topSpeed = 150, reverse = 40, accel = 30, minTorque = 60000, maxTorque = 14000, braking = 14000, friction = 1.1, slip = 25, reduction = 0.15, rackSpeed = 12, rackForce = 500000, spring = 15000, suspDamping = 300, rollStiff = 16000, rollDamp = 100 },
    Offroad  = { topSpeed = 110, reverse = 40, accel = 32, minTorque = 70000, maxTorque = 16000, braking = 18000, friction = 1.7, slip = 15, reduction = 0.2, rackSpeed = 10, rackForce = 500000, spring = 15000, suspDamping = 300, rollStiff = 16000, rollDamp = 100 },
}

local function push_tune_to_sliders(t)
    local map = {
        v_topSpeed = "topSpeed", v_reverse = "reverse", v_accel = "accel",
        v_minTorque = "minTorque", v_maxTorque = "maxTorque", v_braking = "braking",
        v_friction = "friction", v_slip = "slip", v_reduction = "reduction",
        v_rackSpeed = "rackSpeed", v_rackForce = "rackForce", v_spring = "spring",
        v_suspDamp = "suspDamping", v_rollStiff = "rollStiff", v_rollDamp = "rollDamp",
    }
    for id, key in map do
        local handle = sliderHandles[id]
        if t[key] and handle then
            handle:Set(t[key], true)
        end
    end
end

for name, p in presets do
    Presets:AddButton({
        Text = "Apply " .. name,
        Tooltip = name == "Stock" and "Restore the vehicle's untouched values" or nil,
        Callback = function()
            local model = target_model()
            if not model then return end
            if p.useStock then
                local s = stock[model]
                if not s then
                    notify("Vehicle", "No changes made to this vehicle yet", "warning")
                    return
                end
                apply_motors(model, s.motors)
                apply_grip(model, nil, s.wheels.slipThreshold)
                -- restore the original friction pair (apply_grip narrows it)
                local w = model:FindFirstChild("Wheels")
                if w then
                    if s.wheels.staticFriction then w:SetAttribute("staticFriction", s.wheels.staticFriction) end
                    if s.wheels.kineticFriction then w:SetAttribute("kineticFriction", s.wheels.kineticFriction) end
                end
                for wheel, mult in s.wheels do
                    if typeof(wheel) == "Instance" then wheel:SetAttribute("FrictionMultiplier", mult) end
                end
                apply_suspension(model, s.susp.stiffness, s.susp.damping, s.roll.stiffness, s.roll.damping)
                apply_steering(model, s.steeringReduction)
                lastTune = nil
                notify("Vehicle", model.Name .. " restored to stock", "success")
                return
            end
            for k, v in p do tune[k] = v end
            push_tune_to_sliders(p)
            apply_full_tune(model, tune)
            notify("Vehicle", name .. " preset applied to " .. model.Name, "success")
        end,
    })
end

----------------------------------------------------------------
-- COMBAT TAB
----------------------------------------------------------------
local MeleeSec = ComTab:AddSection("Melee")

local statusLabel = MeleeSec:AddLabel(meleeStatusText)

local function patch_melee()
    local Attacks = game:GetService("ReplicatedStorage").Modules.Game.Melee.Attacks
    if not melee.originalCooldowns then
        melee.originalCooldowns = {}
        for _, mod in Attacks:GetChildren() do
            local ok, t = pcall(require, mod)
            if ok and type(t) == "table" then
                melee.originalCooldowns[mod] = t.cooldown
            end
        end
    end
    for mod, cd in melee.originalCooldowns do
        local ok, t = pcall(require, mod)
        if ok then t.cooldown = 0 end
    end

    local ok, fists = pcall(require, Attacks:FindFirstChild("Fists"))
    if ok and type(fists) == "table" then
        if not melee.originalExecute then
            melee.originalExecute = fists.execute
        end
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local MeleeClient = require(ReplicatedStorage.Modules.Game.Melee.MeleeClient)
        local Char = require(ReplicatedStorage.Modules.Core.Char)
        local Audio = require(ReplicatedStorage.Modules.Core.Audio)
        local Util = require(ReplicatedStorage.Modules.Core.Util)
        local RagdollClient = require(ReplicatedStorage.Modules.Game.Character.Mechanics.RagdollClient)
        local offset = CFrame.new(0, -1.5, -2)

        fists.execute = function(p3)
            local char = Char.current_char.get()
            if not char then return end
            local instance = p3.instance
            local anims = instance:FindFirstChild("AttackAnimations", true)
            local target = MeleeClient.find_nearest_target(10, 60, { include_downed = true, flat_angle_check = true })
            local tchar = target and target.Character or nil

            local atype = melee.lastSide
            if tchar then
                local dist = (char:GetPivot().Position - tchar:GetPivot().Position).Magnitude
                if RagdollClient.is_ragdolled(tchar) then
                    atype = (char:GetPivot().Position.Y - tchar:GetPivot().Position.Y > 2) and "Sweep Kick" or "Kick"
                elseif dist < 3 then
                    atype = math.random(1, 2) == 1 and "Headbutt" or "Push"
                end
            end
            if atype == "Left" then melee.lastSide = "Right"
            elseif atype == "Right" then melee.lastSide = "Left" end

            Audio.play(103153652977838, 0.5, Util.rand(0.9, 1.1), char.PrimaryPart, 0.15)
            if melee.lastTrack then
                melee.lastTrack:Stop(0.05)
                melee.lastTrack = nil
            end
            if anims then
                local a = anims:FindFirstChild(atype)
                if a and a:IsA("Animation") then
                    local track = Char.anim(a.AnimationId, false, false, Enum.AnimationPriority.Action4)
                    track:Play(0.05, 1, melee.swingSpeed)
                    melee.lastTrack = track
                end
            end
            task.wait(melee.windup)
            MeleeClient.send(MeleeClient.box_cast(Vector3.new(5, 7, 8), offset), {
                melee_type = atype,
                direction = char:GetPivot().LookVector,
            })
            MeleeClient.reset_locomotion_tracks()
        end
        melee.patched = true
        return true
    end
    return false
end

local function restore_melee()
    local Attacks = game:GetService("ReplicatedStorage").Modules.Game.Melee.Attacks
    for mod, cd in melee.originalCooldowns or {} do
        local ok, t = pcall(require, mod)
        if ok then t.cooldown = cd end
    end
    if melee.originalExecute then
        local ok, fists = pcall(require, Attacks:FindFirstChild("Fists"))
        if ok then fists.execute = melee.originalExecute end
    end
    melee.patched = false
end

MeleeSec:AddToggle("melee_fast", {
    Text = "Fast melee (all weapons)",
    Default = false,
    Callback = function(v)
        if v then
            local ok = patch_melee()
            meleeStatusText = ok and ("Fast melee: ON (windup " .. melee.windup .. "s)") or "Fast melee: failed to patch"
            statusLabel:Set(meleeStatusText)
            notify("Combat", ok and "Melee cooldowns zeroed + fast fists armed" or "Patch failed", ok and "success" or "error")
        else
            restore_melee()
            meleeStatusText = "Fast melee: OFF"
            statusLabel:Set(meleeStatusText)
            notify("Combat", "Melee restored to stock", "info")
        end
    end,
})

MeleeSec:AddSlider("melee_windup", {
    Text = "Fist windup", Min = 0.02, Max = 0.5, Default = 0.05, Increment = 0.01, Suffix = "s",
    Callback = function(v)
        melee.windup = v
        if melee.patched then
            meleeStatusText = "Fast melee: ON (windup " .. v .. "s)"
            statusLabel:Set(meleeStatusText)
        end
    end,
})

MeleeSec:AddSlider("melee_swing", {
    Text = "Swing animation speed", Min = 1, Max = 4, Default = 2.5, Increment = 0.1, Suffix = "x",
    Callback = function(v) melee.swingSpeed = v end,
})

local GunSec = ComTab:AddSection("Guns / Taser")

local gunIndex = {}
local selectedGunName = nil

local gunDropdown = GunSec:AddDropdown("gun_select", {
    Text = "Gun (in backpack / hand)",
    Values = {},
    Searchable = true,
    Callback = function(v) selectedGunName = v end,
})

local function list_guns()
    gunIndex = {}
    local values = {}
    local function scan(container)
        for _, t in container:GetChildren() do
            if t:IsA("Tool") and t:GetAttribute("ItemType") == "Gun" then
                gunIndex[t.Name] = t
                values[t.Name] = t.Name
            end
        end
    end
    scan(LocalPlayer.Backpack)
    if LocalPlayer.Character then scan(LocalPlayer.Character) end
    return values
end

GunSec:AddButton({
    Text = "Refresh gun list",
    Callback = function() gunDropdown:Refresh(list_guns()) end,
})

GunSec:AddSlider("gun_fireRate", {
    Text = "Fire rate (set, then re-equip)", Min = 60, Max = 1200, Default = 370, Increment = 10, Suffix = " rpm",
})
GunSec:AddSlider("gun_reload", {
    Text = "Reload time", Min = 0.1, Max = 5, Default = 2.7, Increment = 0.1, Suffix = "s",
})

GunSec:AddButton({
    Text = "Apply to selected gun",
    Callback = function()
        local tool = selectedGunName and gunIndex[selectedGunName]
        if not tool or not tool.Parent then
            notify("Guns", "Pick a gun from the list first", "warning")
            return
        end
        tool:SetAttribute("FireRate", EZ.Flags.gun_fireRate or 370)
        tool:SetAttribute("ReloadTime", EZ.Flags.gun_reload or 2.7)
        notify("Guns", selectedGunName .. " tuned - re-equip once to pick up the new fire rate", "success")
    end,
})

GunSec:AddParagraph({
    Title = "Note",
    Content = "Fire rate is captured when the gun is equipped - re-equip after applying. Reload time is read live every reload.",
})

----------------------------------------------------------------
-- TELEMETRY TAB
----------------------------------------------------------------
local TeleSec = TeleTab:AddSection("Live telemetry")

local speedBar = TeleSec:AddProgressBar("tele_speed", {
    Text = "Speed",
    Default = 0,
    Max = 250,
    ShowText = true,
})

local infoLabel = TeleSec:AddLabel("vehicle: -")
local gearLabel = TeleSec:AddLabel("gear: -")

TeleSec:AddToggle("tele_live", {
    Text = "Live readout",
    Default = false,
    Callback = function(v)
        if not v then
            pcall(function() RunService:UnbindFromRenderStep("P12_Telemetry") end)
            return
        end
        local acc = 0
        RunService:BindToRenderStep("P12_Telemetry", Enum.RenderPriority.Last.Value + 1, function(dt)
            acc += dt
            if acc < 0.2 then return end
            acc = 0
            local model = get_selected(selectedVehicleKey)
            local chassis = model and model:FindFirstChild("Chassis")
            local m = model and model:FindFirstChild("Motors")
            if not chassis then
                speedBar:Set(0)
                infoLabel:Set("vehicle: -")
                gearLabel:Set("gear: -")
                return
            end
            local vel = chassis.AssemblyLinearVelocity
            local mph = Vector3.new(vel.X, 0, vel.Z).Magnitude / 1.6
            speedBar:Set(math.floor(mph))
            local maxSpeed = m and m:GetAttribute("forwardMaxSpeed")
            if maxSpeed then speedBar:SetMax(maxSpeed) end
            infoLabel:Set("vehicle: " .. model.Name)
            gearLabel:Set(("gear: %s   engine: %s mph"):format(
                tostring(m and m:GetAttribute("_gear") or "?"),
                tostring(m and m:GetAttribute("_speed") and math.floor(m:GetAttribute("_speed")) or "?")))
        end)
    end,
})

----------------------------------------------------------------
-- AUTO RE-TUNE
----------------------------------------------------------------
local MiscSec = TeleTab:AddSection("Persistence")

MiscSec:AddToggle("auto_retune", {
    Text = "Auto re-tune after vehicle respawn",
    Default = false,
    Callback = function(v)
        if v then lastTune = lastTune or tune end
        notify("Vehicle", v and "Auto re-tune armed" or "Auto re-tune off")
    end,
})

task.spawn(function()
    while true do
        task.wait(5)
        if EZ.Flags.auto_retune and lastTune then
            local key = selectedVehicleKey
            local model = get_selected(key)
            if model and model.Parent and model:FindFirstChild("Motors") then
                local current = model.Motors:GetAttribute("forwardMaxSpeed")
                if current and lastTune.topSpeed and math.abs(current - lastTune.topSpeed) > 1 then
                    apply_full_tune(model, lastTune)
                    notify("Vehicle", "Re-applied tune after respawn", "success")
                end
            end
        end
        if EZ.Flags.melee_fast and not melee.patched then
            patch_melee()
        end
    end
end)

QuickBar:Pin("melee_fast", { Icon = "sword" })

notify("Project 12", "Hub loaded - RightShift to toggle", "success")
end)
if not __ok then
    warn("[P12] load error: " .. tostring(__err))
    _G.P12_ERR = tostring(__err)
end
return EZ
