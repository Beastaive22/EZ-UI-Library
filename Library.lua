--[[
    EZ Hub UI Library
    Premium dark glassmorphism UI for Roblox
    PC + Mobile 
]]

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Release identity: powers the update checker and AutoSettings' addon fetches.
-- Change these two lines when rebranding the library under a new repository.
local REPO_SLUG = "Beastaive22/EZ-UI-Library"
local REPO_RAW = "https://raw.githubusercontent.com/" .. REPO_SLUG .. "/main/"

-- Kill the PREVIOUS load of this library before building a new one. Re-running
-- an executor script leaves the old copy's UserInputService / keybind
-- connections rooted in Roblox signals - destroying its ScreenGuis (the
-- cleanup block below) cannot reach them, so old hotkeys kept firing into dead
-- UI. A shared token hands each load the power to tear down its predecessor.
local TEARDOWN_KEY = "EZ_TEARDOWN_" .. REPO_SLUG
pcall(function()
    local prev = getgenv and getgenv()[TEARDOWN_KEY]
    if type(prev) == "function" then pcall(prev) end
end)

local EZ = {
    Flags = {},
    Windows = {},
    Notifications = {},
    Theme = nil,
    _connections = {},
    _listeners = {},
    _elements = {},
    _errorLog = {},
    _onError = nil,
    _activeDrag = nil, -- mutex so picker drag doesn't bleed into slider
    _destroyed = false,
    -- anti-afk: answers LocalPlayer.Idled with a virtual input so the
    -- ~20-minute idle kick never fires; see EZ:SetAntiAFK
    _antiAFK = false,
    _antiAFKCount = 0,
    -- most notification cards on screen at once; the holder is a fixed column
    MaxNotifications = 5,
    _version = "4.2.0"
}

-- defaults
local DEFAULT_THEME = {
    Name = "Midnight",
    Base = Color3.fromRGB(10, 10, 14),
    Surface = Color3.fromRGB(18, 18, 26),
    Panel = Color3.fromRGB(24, 24, 36),
    Border = Color3.fromRGB(45, 45, 65),
    Accent = Color3.fromRGB(124, 92, 252),
    AccentDark = Color3.fromRGB(90, 65, 200),
    Text = Color3.fromRGB(232, 232, 240),
    TextDim = Color3.fromRGB(136, 136, 170),
    TextMuted = Color3.fromRGB(80, 80, 110),
    Success = Color3.fromRGB(80, 220, 120),
    Warning = Color3.fromRGB(255, 180, 50),
    Error = Color3.fromRGB(255, 80, 80),
    Info = Color3.fromRGB(80, 160, 255),
}

local function cloneTheme(theme)
    local copy = {}
    for k, v in theme do copy[k] = v end
    return copy
end

EZ.Theme = cloneTheme(DEFAULT_THEME)

-- Track every RBXScriptConnection created by the library so EZ:Destroy()
-- can reliably disconnect callbacks, including global UserInputService
-- and Players connections.
local function trackConnection(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(EZ._connections, connection)

    -- During CreateWindow, also associate the connection with that window so
    -- window:Destroy() can clean up only its own callbacks.
    local owner = EZ._connectionOwner
    if owner then
        owner._connections = owner._connections or {}
        table.insert(owner._connections, connection)
    end

    return connection
end

local function disconnectConnection(connection)
    if not connection then return end
    pcall(function() connection:Disconnect() end)

    for i = #EZ._connections, 1, -1 do
        if EZ._connections[i] == connection then
            table.remove(EZ._connections, i)
            break
        end
    end
end

-- preset themes (devs love these)
EZ.Themes = {
    Midnight = DEFAULT_THEME,

    Catppuccin = {
        Name = "Catppuccin",
        Base = Color3.fromRGB(24, 24, 37),
        Surface = Color3.fromRGB(30, 30, 46),
        Panel = Color3.fromRGB(49, 50, 68),
        Border = Color3.fromRGB(69, 71, 90),
        Accent = Color3.fromRGB(203, 166, 247),
        AccentDark = Color3.fromRGB(166, 132, 213),
        Text = Color3.fromRGB(205, 214, 244),
        TextDim = Color3.fromRGB(166, 173, 200),
        TextMuted = Color3.fromRGB(108, 112, 134),
        Success = Color3.fromRGB(166, 227, 161),
        Warning = Color3.fromRGB(249, 226, 175),
        Error = Color3.fromRGB(243, 139, 168),
        Info = Color3.fromRGB(137, 180, 250),
    },

    TokyoNight = {
        Name = "Tokyo Night",
        Base = Color3.fromRGB(26, 27, 38),
        Surface = Color3.fromRGB(36, 40, 59),
        Panel = Color3.fromRGB(41, 46, 66),
        Border = Color3.fromRGB(65, 72, 104),
        Accent = Color3.fromRGB(125, 207, 255),
        AccentDark = Color3.fromRGB(86, 154, 200),
        Text = Color3.fromRGB(192, 202, 245),
        TextDim = Color3.fromRGB(154, 165, 206),
        TextMuted = Color3.fromRGB(86, 95, 137),
        Success = Color3.fromRGB(158, 206, 106),
        Warning = Color3.fromRGB(224, 175, 104),
        Error = Color3.fromRGB(247, 118, 142),
        Info = Color3.fromRGB(122, 162, 247),
    },

    Dracula = {
        Name = "Dracula",
        Base = Color3.fromRGB(40, 42, 54),
        Surface = Color3.fromRGB(52, 54, 70),
        Panel = Color3.fromRGB(68, 71, 90),
        Border = Color3.fromRGB(98, 114, 164),
        Accent = Color3.fromRGB(189, 147, 249),
        AccentDark = Color3.fromRGB(150, 110, 210),
        Text = Color3.fromRGB(248, 248, 242),
        TextDim = Color3.fromRGB(180, 180, 190),
        TextMuted = Color3.fromRGB(98, 114, 164),
        Success = Color3.fromRGB(80, 250, 123),
        Warning = Color3.fromRGB(241, 250, 140),
        Error = Color3.fromRGB(255, 85, 85),
        Info = Color3.fromRGB(139, 233, 253),
    },

    Nord = {
        Name = "Nord",
        Base = Color3.fromRGB(46, 52, 64),
        Surface = Color3.fromRGB(59, 66, 82),
        Panel = Color3.fromRGB(67, 76, 94),
        Border = Color3.fromRGB(76, 86, 106),
        Accent = Color3.fromRGB(136, 192, 208),
        AccentDark = Color3.fromRGB(94, 129, 172),
        Text = Color3.fromRGB(236, 239, 244),
        TextDim = Color3.fromRGB(216, 222, 233),
        TextMuted = Color3.fromRGB(129, 161, 193),
        Success = Color3.fromRGB(163, 190, 140),
        Warning = Color3.fromRGB(235, 203, 139),
        Error = Color3.fromRGB(191, 97, 106),
        Info = Color3.fromRGB(129, 161, 193),
    },

    Rose = {
        Name = "Rose Pine",
        Base = Color3.fromRGB(25, 23, 36),
        Surface = Color3.fromRGB(38, 35, 58),
        Panel = Color3.fromRGB(49, 46, 77),
        Border = Color3.fromRGB(64, 61, 82),
        Accent = Color3.fromRGB(235, 188, 186),
        AccentDark = Color3.fromRGB(196, 167, 231),
        Text = Color3.fromRGB(224, 222, 244),
        TextDim = Color3.fromRGB(144, 140, 170),
        TextMuted = Color3.fromRGB(110, 106, 134),
        Success = Color3.fromRGB(156, 207, 216),
        Warning = Color3.fromRGB(246, 193, 119),
        Error = Color3.fromRGB(235, 111, 146),
        Info = Color3.fromRGB(196, 167, 231),
    },

    Cyberpunk = {
        Name = "Cyberpunk",
        Base = Color3.fromRGB(13, 13, 20),
        Surface = Color3.fromRGB(20, 20, 35),
        Panel = Color3.fromRGB(28, 28, 48),
        Border = Color3.fromRGB(255, 0, 128),
        Accent = Color3.fromRGB(0, 255, 200),
        AccentDark = Color3.fromRGB(0, 180, 150),
        Text = Color3.fromRGB(240, 240, 255),
        TextDim = Color3.fromRGB(180, 180, 220),
        TextMuted = Color3.fromRGB(120, 100, 180),
        Success = Color3.fromRGB(0, 255, 150),
        Warning = Color3.fromRGB(255, 200, 0),
        Error = Color3.fromRGB(255, 50, 100),
        Info = Color3.fromRGB(100, 200, 255),
    },

    Monochrome = {
        Name = "Monochrome",
        Base = Color3.fromRGB(15, 15, 15),
        Surface = Color3.fromRGB(22, 22, 22),
        Panel = Color3.fromRGB(32, 32, 32),
        Border = Color3.fromRGB(60, 60, 60),
        Accent = Color3.fromRGB(230, 230, 230),
        AccentDark = Color3.fromRGB(180, 180, 180),
        Text = Color3.fromRGB(245, 245, 245),
        TextDim = Color3.fromRGB(170, 170, 170),
        TextMuted = Color3.fromRGB(110, 110, 110),
        Success = Color3.fromRGB(200, 200, 200),
        Warning = Color3.fromRGB(220, 220, 220),
        Error = Color3.fromRGB(255, 100, 100),
        Info = Color3.fromRGB(180, 180, 180),
    },
}

-- utils
local function tween(obj, props, dur, style)
    local tw = TweenService:Create(obj, TweenInfo.new(dur or 0.22, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
    tw:Play()
    return tw
end

local function create(cls, props)
    local inst = Instance.new(cls)
    for k, v in props do
        if k ~= "Parent" and k ~= "Children" then
            inst[k] = v
        end
    end
    -- global font override (Settings > Font Face) applies to new elements too
    if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
        if EZ._fontOverride then
            pcall(function() inst.TextFont = EZ._fontOverride end)
        elseif EZ._fontEnumOverride then
            inst.Font = EZ._fontEnumOverride
        end
    end
    if props.Children then
        for _, child in props.Children do
            child.Parent = inst
        end
    end
    if props.Parent then
        inst.Parent = props.Parent
    end
    return inst
end

-- module-local insert counter for addCorner's periodic prune
local cornerAdds = 0

local function addCorner(parent, radius)
    -- Registered so Settings > Corner Radius can retune every corner live.
    -- The designed radius stays as the fallback when the override is off.
    local r = EZ._cornerRadiusOverride or radius or 8
    local c = create("UICorner", { CornerRadius = UDim.new(0, r), Parent = parent })
    EZ._cornerRegistry = EZ._cornerRegistry or {}
    cornerAdds = cornerAdds + 1
    if cornerAdds % 200 == 0 then
        -- drop entries whose instance was destroyed with its window so the
        -- registry cannot grow without bound (same alive-filter SetCornerRadius uses)
        for i = #EZ._cornerRegistry, 1, -1 do
            if EZ._cornerRegistry[i].inst.Parent == nil then
                table.remove(EZ._cornerRegistry, i)
            end
        end
    end
    table.insert(EZ._cornerRegistry, { inst = c, fallback = radius or 8 })
    return c
end

local function addStroke(parent, color, thickness, transparency)
    return create("UIStroke", {
        Color = color or EZ.Theme.Border,
        Thickness = thickness or 1,
        Transparency = transparency or 0.5,
        Parent = parent
    })
end

local function isMobile()
    return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function getScreenSize()
    local cam = workspace.CurrentCamera
    return cam and cam.ViewportSize or Vector2.new(1920, 1080)
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function round(v, inc)
    inc = inc or 1
    return math.floor(v / inc + 0.5) * inc
end

local function color3ToHex(c)
    return string.format("#%02X%02X%02X", math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255))
end

local function hexToColor3(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("#", "")
    if #hex ~= 6 or not hex:match("^[%x]+$") then return nil end

    local r = tonumber(hex:sub(1,2), 16)
    local g = tonumber(hex:sub(3,4), 16)
    local b = tonumber(hex:sub(5,6), 16)
    if not r or not g or not b then return nil end
    return Color3.fromRGB(r, g, b)
end

-- error handling
local function EZError(source, err)
    local trace = debug.traceback(tostring(err), 3)
    local entry = {
        source = source,
        message = tostring(err),
        traceback = trace,
        time = os.clock(),
    }
    table.insert(EZ._errorLog, entry)
    if #EZ._errorLog > 50 then table.remove(EZ._errorLog, 1) end

    warn(`[EZ] {source}: {err}`)

    if EZ._onError then
        pcall(EZ._onError, entry)
    end

    -- show notification if Notify is available
    pcall(function()
        EZ:Notify({
            Title = "EZ Error",
            Content = source .. ": " .. tostring(err):sub(1, 120),
            Duration = 5,
            Type = "error",
        })
    end)
end

local function safecall(source, fn, ...)
    local args = table.pack(...)
    task.spawn(function()
        local ok, err = pcall(fn, table.unpack(args, 1, args.n))
        if not ok then EZError(source, err) end
    end)
end

function EZ:OnError(fn)
    self._onError = fn
end

function EZ:GetErrors()
    return self._errorLog
end

-- flag listener system
function EZ:OnFlagChanged(id, fn)
    if not self._listeners[id] then self._listeners[id] = {} end
    table.insert(self._listeners[id], fn)
end

function EZ:OffFlagChanged(id, fn)
    local cbs = self._listeners[id]
    if not cbs then return end
    for i = #cbs, 1, -1 do
        if cbs[i] == fn then table.remove(cbs, i) end
    end
    if #cbs == 0 then self._listeners[id] = nil end
end

local function fireListeners(id, val)
    local cbs = EZ._listeners[id]
    if cbs then
        -- iterate a snapshot: a listener removing itself (or another) mid-run
        -- shifts indices under a live generic-for and skips its neighbours.
        -- Short lists just walk backwards (already-visited indices are the
        -- only ones a removal can shift); cloning is reserved for the rare
        -- many-listener case where that guarantee is not enough.
        if #cbs > 4 then
            for _, fn in table.clone(cbs) do safecall(`Listener:{id}`, fn, val) end
        else
            for i = #cbs, 1, -1 do
                local fn = cbs[i]
                if fn then safecall(`Listener:{id}`, fn, val) end
            end
        end
    end
end

-- Central element registry. Config save/load, the floating keybind menu and
-- QuickBar all resolve ids through this one table, so a duplicate id silently
-- orphaned whichever element registered first (only the last got saved).
local function registerElement(id, elem)
    local prev = EZ._elements[id]
    if prev ~= nil and prev ~= elem then
        warn(`[EZ] duplicate element id "{id}" - the earlier element no longer receives config save/load`)
    end
    EZ._elements[id] = elem
end

-- v3.9: element :Destroy() removes it from the registry so SaveManager, the
-- panic snapshot and the keybind menu stop seeing a dead handle.
local function unregisterElement(id)
    if id ~= nil then
        EZ._elements[id] = nil
        EZ.Flags[id] = nil
    end
end

local function tagSearch(frame, text)
    if not frame or not text then return end
    frame:SetAttribute("EZSearch", string.lower(text))
end

-- Conditional visibility, the header search filter and the element's own
-- :SetVisible() all want to own frame.Visible. Each records its own verdict in
-- an attribute and the frame is shown only when none of them wants it hidden,
-- so clearing a search no longer reveals elements whose VisibleWhen dependency
-- is still off (and SetVisible doesn't fight VisibleWhen).
local function applyElementVisibility(frame)
    frame.Visible = not frame:GetAttribute("EZCondHidden")
        and not frame:GetAttribute("EZSearchHidden")
        and not frame:GetAttribute("EZUserHidden")
end

local function setupVisibility(elem, frame, opts)
    if not opts.VisibleWhen then return end
    local depId = opts.VisibleWhen
    local function check(v)
        -- the listener outlives its window (listeners are only wiped by
        -- EZ:Destroy); once the frame is gone just idle instead of writing
        -- attributes into a destroyed tree
        if not frame.Parent then return end
        frame:SetAttribute("EZCondHidden", not v) -- truthy check
        applyElementVisibility(frame)
    end
    -- initial state (a missing dependency flag counts as off)
    check(EZ.Flags[depId])
    EZ:OnFlagChanged(depId, check)
end

-- attach OnChanged to element objects
local function attachOnChanged(elem, id)
    function elem:OnChanged(fn)
        EZ:OnFlagChanged(id, fn)
        return self
    end
end

-- wire tooltip if opts.Tooltip is set
local function setupTooltip(frame, opts)
    if not opts or not opts.Tooltip then return end
    if EZ.AttachTooltip then
        pcall(function() EZ:AttachTooltip(frame, opts.Tooltip) end)
    end
end

-- ~~ v3.9 uniform element-handle plumbing ~~
-- Every element handle gets .Frame, :SetVisible, :SetDisabled/:IsDisabled and
-- :Destroy. Interaction guards read the EZDisabled attribute (builders check
-- it in their input handlers); SetVisible composes with VisibleWhen + search
-- through the attribute system instead of fighting them for frame.Visible.
local function isElementDisabled(frame)
    return frame ~= nil and frame:GetAttribute("EZDisabled") == true
end

local function finishElement(handle, frame, id, section)
    handle.Frame = frame
    function handle:SetVisible(v)
        frame:SetAttribute("EZUserHidden", v == false)
        applyElementVisibility(frame)
        return self
    end
    function handle:SetDisabled(disabled)
        frame:SetAttribute("EZDisabled", disabled == true)
        return self
    end
    function handle:IsDisabled()
        return frame:GetAttribute("EZDisabled") == true
    end
    function handle:Destroy()
        if id ~= nil then unregisterElement(id) end
        if section ~= nil then
            for i, el in section.Elements do
                if el == handle then
                    table.remove(section.Elements, i)
                    break
                end
            end
        end
        frame:Destroy()
    end
    return handle
end

-- cleanup old gui(s) from a previous library load. Prefer the executor UI
-- container when available, otherwise fall back to PlayerGui. EZQuickBar is
-- included because the QuickBar addon owns a sibling ScreenGui; leaving it
-- alive stacked a dead dock on every re-execute.
pcall(function()
    local parent = (gethui and gethui()) or Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if parent then
        for _, name in {"EZUI", "EZNotifs", "EZQuickBar", "EZCursor", "EZLoading"} do
            local old = parent:FindFirstChild(name)
            if old then old:Destroy() end
        end
    end
end)

-- root gui
local gui = create("ScreenGui", {
    Name = "EZUI",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset = true,
    DisplayOrder = 500
})
pcall(function() gui.Parent = gethui() end)
if not gui.Parent then
    gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- notifications live in a separate screengui so they always float above the window
local notifGui = create("ScreenGui", {
    Name = "EZNotifs",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset = true,
    DisplayOrder = 10000,
})
pcall(function() notifGui.Parent = gethui() end)
if not notifGui.Parent then
    notifGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- notification container (top right). Built on demand because EZ:Destroy()
-- empties the notification ScreenGui: without rebuilding it, every later
-- Notify() would parent its card to a destroyed frame and render nothing.
local notifHolder
local function ensureNotifHolder()
    if notifHolder and notifHolder.Parent then return notifHolder end
    notifHolder = create("Frame", {
        Name = "Notifications",
        Size = UDim2.new(0, 300, 1, 0),
        Position = UDim2.new(1, -310, 0, 10),
        BackgroundTransparency = 1,
        Parent = notifGui,
        Children = {
            create("UIListLayout", {
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 6),
                VerticalAlignment = Enum.VerticalAlignment.Top,
                HorizontalAlignment = Enum.HorizontalAlignment.Center,
            })
        }
    })
    return notifHolder
end
ensureNotifHolder()

-- ~~
-- ICON RESOLVER
-- accepts: rbxassetid://..., plain number id, "rbxassetid://12345",
-- or a lucide icon name ("sword", "heart", "arrow-left") if icons are bound
-- ~~
function EZ:SetIcons(iconPack)
    self._icons = iconPack
end

function EZ:ResolveIcon(ref)
    if not ref then return nil end
    if type(ref) == "number" then return "rbxassetid://" .. ref end
    if type(ref) ~= "string" then return nil end
    -- already an asset url
    if ref:find("rbxassetid://") or ref:find("rbxthumb://") or ref:find("rbxgameasset://") or ref:find("http") then
        return ref
    end
    -- numeric string
    if tonumber(ref) then return "rbxassetid://" .. ref end
    -- lucide name via bound icon pack
    if self._icons then
        local id
        pcall(function()
            if type(self._icons.Get) == "function" then
                id = self._icons:Get(ref)
            end
            if not id and type(self._icons.Fuzzy) == "function" then
                id = self._icons:Fuzzy(ref)
            end
        end)
        if id then return id end
    end
    return nil
end

function EZ:Notify(opts)
    opts = opts or {}
    local title = opts.Title or "EZ"
    local content = opts.Content or ""
    -- v4.0: Duration = false (or math.huge) keeps the notification on screen
    -- until :Dismiss()/:Destroy() or an action button dismisses it
    local persistent = opts.Duration == false or opts.Duration == math.huge
    local dur = persistent and nil or (opts.Duration or 4)
    local ntype = opts.Type or "info"
    if self._notifHook then pcall(self._notifHook, opts) end
    local theme = self.Theme

    local accentColor = ({
        info = theme.Info,
        success = theme.Success,
        warning = theme.Warning,
        error = theme.Error,
    })[ntype] or theme.Accent

    local card = create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        BackgroundColor3 = theme.Surface,
        BackgroundTransparency = 0.1,
        ClipsDescendants = true,
        Parent = ensureNotifHolder()
    })
    addCorner(card, 10)
    -- neutral border: the notification type shows as a small dot next to the
    -- title instead of a colored edge (the old accent bar read as a bolt-on)
    addStroke(card, theme.Border, 1, 0.5)

    -- type indicator: a Lucide icon when the icon pack resolves one for the
    -- type, else the small colored dot. The type also shows via color either way.
    local typeIconCandidates = {
        info = { "info", "circle-info" },
        success = { "circle-check", "check-circle", "check" },
        warning = { "triangle-alert", "alert-triangle", "alert" },
        error = { "octagon-x", "x-octagon", "circle-x", "x-circle" },
    }
    local typeAsset
    if self.ResolveIcon then
        for _, cand in (typeIconCandidates[ntype] or typeIconCandidates.info) do
            typeAsset = self:ResolveIcon(cand)
            if typeAsset then break end
        end
    end

    -- type icon/dot + title on one row
    local titleRow = create("Frame", {
        Size = UDim2.new(1, -24, 0, 18),
        Position = UDim2.new(0, 12, 0, 8),
        BackgroundTransparency = 1,
        Parent = card,
        Children = {
            create("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                VerticalAlignment = Enum.VerticalAlignment.Center,
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 6),
            }),
        }
    })

    if typeAsset then
        create("ImageLabel", {
            Size = UDim2.new(0, 13, 0, 13),
            BackgroundTransparency = 1,
            Image = typeAsset,
            ImageColor3 = accentColor,
            ScaleType = Enum.ScaleType.Fit,
            LayoutOrder = 1,
            ZIndex = 1,
            Parent = titleRow,
        })
    else
        create("Frame", {
            Size = UDim2.new(0, 6, 0, 6),
            BackgroundColor3 = accentColor,
            BorderSizePixel = 0,
            LayoutOrder = 1,
            ZIndex = 1,
            Parent = titleRow,
            Children = { create("UICorner", { CornerRadius = UDim.new(1, 0) }) }
        })
    end

    local titleLbl = create("TextLabel", {
        Size = UDim2.new(1, -12, 0, 18),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = theme.Text,
        TextSize = 13,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        LayoutOrder = 2,
        Parent = titleRow
    })

    local contentLbl = create("TextLabel", {
        Size = UDim2.new(1, -24, 0, 0),
        Position = UDim2.new(0, 12, 0, 28),
        BackgroundTransparency = 1,
        Text = content,
        TextColor3 = theme.TextDim,
        TextSize = 12,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        AutomaticSize = Enum.AutomaticSize.Y,
        Parent = card
    })

    -- v4.0: step/progress notifications (TotalSteps + :ChangeStep)
    local totalSteps = (type(opts.TotalSteps) == "number" and opts.TotalSteps > 0) and opts.TotalSteps or nil
    local stepRow, stepFill, stepLbl
    local currentStep = math.max(0, tonumber(opts.CurrentStep) or 0)
    if totalSteps then
        stepRow = create("Frame", {
            Size = UDim2.new(1, -24, 0, 8),
            Position = UDim2.new(0, 12, 0, 0),
            BackgroundColor3 = theme.Panel,
            BackgroundTransparency = 0.2,
            BorderSizePixel = 0,
            Parent = card,
        })
        addCorner(stepRow, 4)
        stepFill = create("Frame", {
            Size = UDim2.new(0, 0, 1, 0),
            BackgroundColor3 = accentColor,
            BorderSizePixel = 0,
            ZIndex = 1,
            Parent = stepRow,
        })
        addCorner(stepFill, 4)
        stepLbl = create("TextLabel", {
            Size = UDim2.new(1, -24, 0, 12),
            Position = UDim2.new(0, 12, 0, 10),
            BackgroundTransparency = 1,
            Text = ("0/%d"):format(totalSteps),
            TextColor3 = theme.TextMuted,
            TextSize = 10,
            Font = Enum.Font.GothamMedium,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = card,
        })
    end

    -- shared dismiss used by auto-expiry and action buttons alike
    local function dismissCard()
        tween(card, {Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1}, 0.25)
        task.delay(0.3, function()
            local idx = table.find(EZ.Notifications, card)
            if idx then table.remove(EZ.Notifications, idx) end
            pcall(function() card:Destroy() end)
        end)
    end

    -- optional action buttons (opts.Buttons = { {Text = "Open", Callback = fn} })
    -- Taking an action dismisses the card; the callbacks safecall like
    -- every other user callback.
    local actionRow
    if type(opts.Buttons) == "table" and #opts.Buttons > 0 then
        actionRow = create("Frame", {
            Size = UDim2.new(1, -24, 0, 22),
            BackgroundTransparency = 1,
            Parent = card,
            Children = {
                create("UIListLayout", {
                    FillDirection = Enum.FillDirection.Horizontal,
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    Padding = UDim.new(0, 6),
                }),
            }
        })
        for _, btn in opts.Buttons do
            if type(btn) == "table" and btn.Text then
                local b = create("TextButton", {
                    AutomaticSize = Enum.AutomaticSize.X,
                    Size = UDim2.new(0, 0, 1, 0),
                    BackgroundColor3 = theme.Panel,
                    BackgroundTransparency = 0.35,
                    Text = tostring(btn.Text),
                    TextColor3 = theme.Text,
                    TextSize = 11,
                    Font = Enum.Font.Gotham,
                    AutoButtonColor = false,
                    BorderSizePixel = 0,
                    LayoutOrder = #actionRow:GetChildren(),
                    Parent = actionRow,
                    Children = {
                        create("UICorner", { CornerRadius = UDim.new(0, 6) }),
                        create("UIPadding", {
                            PaddingLeft = UDim.new(0, 8),
                            PaddingRight = UDim.new(0, 8),
                        }),
                    }
                })
                b.MouseButton1Click:Connect(function()
                    safecall("NotifyAction", btn.Callback or function() end)
                    dismissCard()
                end)
            end
        end
    end

    table.insert(self.Notifications, card)

    -- Cap what is on screen. The holder is a fixed-width column driven by a
    -- list layout, so a burst simply ran off the bottom of the display.
    local maxVisible = math.max(1, tonumber(self.MaxNotifications) or 5)
    while #self.Notifications > maxVisible do
        local oldest = table.remove(self.Notifications, 1)
        if oldest then
            tween(oldest, {Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1}, 0.2)
            task.delay(0.25, function() pcall(function() oldest:Destroy() end) end)
        end
    end

    -- Animate in on the next frame. TextBounds is still empty on the frame the
    -- label is created, so measuring immediately clipped every wrapped line.
    -- Extracted so :ChangeDescription/:ChangeStep can re-measure live.
    local function relayout()
        if not card.Parent then return end
        local textH = math.max(contentLbl.TextBounds.Y, contentLbl.AbsoluteSize.Y, 14)
        local cursorY = 28 + textH + 6
        if stepRow then
            stepRow.Position = UDim2.new(0, 12, 0, cursorY)
            stepLbl.Position = UDim2.new(0, 12, 0, cursorY + 10)
            cursorY += 26
        end
        if actionRow then
            actionRow.Position = UDim2.new(0, 12, 0, cursorY)
        end
        local cardH = 30 + textH + (stepRow and 26 or 0) + (actionRow and 28 or 0) + 10
        tween(card, {Size = UDim2.new(1, 0, 0, cardH)}, 0.3)
    end
    task.defer(relayout)

    -- v4.0: step progress (TotalSteps + :ChangeStep)
    local function setStep(n)
        if not totalSteps then return end
        currentStep = math.clamp(tonumber(n) or 0, 0, totalSteps)
        local pct = currentStep / totalSteps
        if stepFill then tween(stepFill, {Size = UDim2.new(pct, 0, 1, 0)}, 0.2) end
        if stepLbl then stepLbl.Text = ("%d/%d"):format(currentStep, totalSteps) end
        task.defer(function() relayout() end)
    end
    if totalSteps and currentStep > 0 then
        task.defer(function() setStep(currentStep) end)
    end

    -- v4.0: optional notification sound (SoundId = asset id, Volume default 3)
    if opts.SoundId then
        pcall(function()
            local sound = Instance.new("Sound")
            sound.SoundId = (type(opts.SoundId) == "number")
                and ("rbxassetid://" .. opts.SoundId) or tostring(opts.SoundId)
            sound.Volume = tonumber(opts.Volume) or 3
            sound.Parent = card
            sound:Play()
        end)
    end

    -- auto dismiss (skipped for persistent notifications)
    if not persistent then
        task.delay(dur, dismissCard)
    end

    -- v4.0: notification handle. Forwarding metatable keeps old frame-style
    -- usage working (handle.Size etc. read/write the card) while adding
    -- ChangeTitle / ChangeDescription / ChangeStep / Dismiss / Destroy.
    local handle
    handle = setmetatable({
        Frame = card,
        ChangeTitle = function(_, t)
            titleLbl.Text = tostring(t)
            return handle
        end,
        ChangeDescription = function(_, t)
            contentLbl.Text = tostring(t)
            task.defer(function() relayout() end)
            return handle
        end,
        ChangeStep = function(_, n)
            setStep(n)
            return handle
        end,
        Dismiss = function() dismissCard() end,
        Destroy = function() dismissCard() end,
    }, {
        __index = function(_, k) return card[k] end,
        __newindex = function(_, k, v) card[k] = v end,
    })

    return handle
end

-- ~~---------
-- WINDOW
-- ~~---------
-- ~~---------
-- KEY SYSTEM
-- ~~---------
function EZ:KeySystem(opts)
    opts = opts or {}
    local title = opts.Title or "Key System"
    local subtitle = opts.SubTitle or "Enter your key to continue"
    local keys = opts.Keys or {}
    local hashedKeys = opts.HashedKeys -- optional: pre-hashed sha256 keys (recommended)
    local saveName = opts.SaveKey or "EZKey.txt"
    local cb = opts.Callback or function() end
    local maxAttempts = opts.MaxAttempts or 5
    local theme = self.Theme
    local mobile = isMobile()

    -- hash helper (SHA-256 with HWID salt for binding)
    local function hwidSalt()
        local h
        pcall(function() h = (gethwid and gethwid()) or "" end)
        return tostring(h or "")
    end

    local hashAvailable = false
    pcall(function()
        hashAvailable = crypt ~= nil and type(crypt.hash) == "function"
    end)

    if not hashAvailable then
        warn("[EZ] KeySystem: crypt.hash unavailable on this executor - keys are compared and stored in PLAINTEXT")
    end

    local function hashKey(k)
        if not hashAvailable then return k end
        local ok, out = pcall(crypt.hash, k .. "::EZ::" .. hwidSalt(), "sha256")
        return ok and out or k
    end

    -- valid hash list
    local validHashes = {}
    if hashedKeys then
        for _, h in hashedKeys do validHashes[h] = true end
    else
        for _, k in keys do validHashes[hashKey(k)] = true end
    end

    local function checkKey(input)
        return validHashes[hashKey(input)] == true
    end

    -- check saved key first (file stores HWID-bound hash, not raw key)
    local savedHash = nil
    pcall(function()
        if isfile and isfile(saveName) then savedHash = readfile(saveName) end
    end)
    if savedHash and validHashes[savedHash] then
        safecall("KeySystem", cb, true)
        return true
    end

    -- attempt counter (in-memory, persists for session)
    local attempts = 0

    local passed = false
    local keyGui = create("Frame", {
        Name = "EZKeySystem",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.4,
        ZIndex = 200,
        Parent = gui
    })

    local card = create("Frame", {
        Size = UDim2.new(0, mobile and 320 or 340, 0, 0),
        Position = UDim2.new(0.5, mobile and -160 or -170, 0.5, 0),
        BackgroundColor3 = theme.Base,
        ClipsDescendants = true,
        ZIndex = 201,
        Parent = keyGui
    })
    addCorner(card, 14)
    addStroke(card, theme.Border, 1, 0.3)

    -- accent line
    create("Frame", {
        Size = UDim2.new(0, 40, 0, 2),
        Position = UDim2.new(0.5, -20, 0, 0),
        BackgroundColor3 = theme.Accent,
        BorderSizePixel = 0,
        ZIndex = 210,
        Parent = card
    })

    -- title
    create("TextLabel", {
        Size = UDim2.new(1, -40, 0, 20),
        Position = UDim2.new(0, 20, 0, 20),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = theme.Text,
        TextSize = 16,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = 210,
        Parent = card
    })

    create("TextLabel", {
        Size = UDim2.new(1, -40, 0, 14),
        Position = UDim2.new(0, 20, 0, 42),
        BackgroundTransparency = 1,
        Text = subtitle,
        TextColor3 = theme.TextMuted,
        TextSize = 11,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = 210,
        Parent = card
    })

    -- input
    local inputBg = create("Frame", {
        Size = UDim2.new(1, -40, 0, 38),
        Position = UDim2.new(0, 20, 0, 68),
        BackgroundColor3 = theme.Surface,
        BorderSizePixel = 0,
        ZIndex = 210,
        Parent = card
    })
    addCorner(inputBg, 8)
    local keyStroke = addStroke(inputBg, theme.Border, 1, 0.5)

    local keyInput = create("TextBox", {
        Size = UDim2.new(1, -16, 1, 0),
        Position = UDim2.new(0, 8, 0, 0),
        BackgroundTransparency = 1,
        Text = "",
        PlaceholderText = "Enter key...",
        TextColor3 = theme.Text,
        PlaceholderColor3 = theme.TextMuted,
        TextSize = 13,
        Font = Enum.Font.Code,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        ZIndex = 211,
        Parent = inputBg
    })

    trackConnection(keyInput.Focused, function()
        tween(keyStroke, {Color = theme.Accent, Transparency = 0}, 0.15)
    end)
    trackConnection(keyInput.FocusLost, function()
        tween(keyStroke, {Color = theme.Border, Transparency = 0.5}, 0.15)
    end)

    -- status label
    local statusLabel = create("TextLabel", {
        Size = UDim2.new(1, -40, 0, 14),
        Position = UDim2.new(0, 20, 0, 112),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = theme.Error,
        TextSize = 11,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = 210,
        Parent = card
    })

    -- submit button
    local submitBtn = create("TextButton", {
        Size = UDim2.new(1, -40, 0, 36),
        Position = UDim2.new(0, 20, 0, 130),
        BackgroundColor3 = theme.Accent,
        Text = "",
        BorderSizePixel = 0,
        AutoButtonColor = false,
        ZIndex = 210,
        Parent = card
    })
    addCorner(submitBtn, 8)

    create("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "Verify",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 13,
        Font = Enum.Font.GothamBold,
        ZIndex = 211,
        Parent = submitBtn
    })

    trackConnection(submitBtn.MouseEnter, function()
        tween(submitBtn, {BackgroundColor3 = theme.AccentDark}, 0.15)
    end)
    trackConnection(submitBtn.MouseLeave, function()
        tween(submitBtn, {BackgroundColor3 = theme.Accent}, 0.15)
    end)

    -- get key link (styled, secondary button below verify)
    if opts.GetKeyLink then
        local linkBtn = create("TextButton", {
            Size = UDim2.new(1, -40, 0, mobile and 36 or 32),
            Position = UDim2.new(0, 20, 0, 176),
            BackgroundColor3 = theme.Surface,
            BackgroundTransparency = 0.2,
            Text = "",
            BorderSizePixel = 0,
            AutoButtonColor = false,
            ZIndex = 210,
            Parent = card
        })
        addCorner(linkBtn, 8)
        local linkStroke = addStroke(linkBtn, theme.Border, 1, 0.5)

        -- icon + text together
        local row = create("Frame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            ZIndex = 211,
            Parent = linkBtn
        })
        create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding = UDim.new(0, 6),
            Parent = row
        })

        -- ResolveIcon goes through the pack's own API. Indexing _icons
        -- directly never matched, because the pack keeps its table private.
        local iconImg = EZ:ResolveIcon("external-link") or "rbxassetid://104262388679305"
        create("ImageLabel", {
            Size = UDim2.new(0, 14, 0, 14),
            BackgroundTransparency = 1,
            Image = iconImg,
            ImageColor3 = theme.Accent,
            ZIndex = 212,
            LayoutOrder = 1,
            Parent = row
        })
        local linkLbl = create("TextLabel", {
            AutomaticSize = Enum.AutomaticSize.X,
            Size = UDim2.new(0, 0, 1, 0),
            BackgroundTransparency = 1,
            Text = opts.GetKeyText or "Get Key",
            TextColor3 = theme.Text,
            TextSize = 12,
            Font = Enum.Font.GothamMedium,
            ZIndex = 212,
            LayoutOrder = 2,
            Parent = row
        })

        trackConnection(linkBtn.MouseEnter, function()
            tween(linkBtn, {BackgroundTransparency = 0.05}, 0.15)
            tween(linkStroke, {Color = theme.Accent, Transparency = 0.2}, 0.15)
        end)
        trackConnection(linkBtn.MouseLeave, function()
            tween(linkBtn, {BackgroundTransparency = 0.2}, 0.15)
            tween(linkStroke, {Color = theme.Border, Transparency = 0.5}, 0.15)
        end)
        trackConnection(linkBtn.MouseButton1Click, function()
            pcall(function() setclipboard(opts.GetKeyLink) end)
            linkLbl.Text = "Link copied!"
            linkLbl.TextColor3 = theme.Success
            task.delay(1.5, function()
                if linkLbl.Parent then
                    linkLbl.Text = opts.GetKeyText or "Get Key"
                    linkLbl.TextColor3 = theme.Text
                end
            end)
        end)
    end

    local cardH = opts.GetKeyLink and (mobile and 226 or 222) or 180

    -- animate in
    tween(card, {
        Size = UDim2.new(0, mobile and 320 or 340, 0, cardH),
        Position = UDim2.new(0.5, mobile and -160 or -170, 0.5, -cardH/2),
    }, 0.3)

    -- verify
    local locked = false
    local function tryKey()
        if locked then return end
        local input = keyInput.Text
        if input == "" then
            statusLabel.Text = "Enter a key first"
            statusLabel.TextColor3 = theme.Warning
            return
        end

        if checkKey(input) then
            statusLabel.Text = "Key accepted!"
            statusLabel.TextColor3 = theme.Success
            -- store hash, not the raw key (file leak doesn't expose key)
            pcall(function() writefile(saveName, hashKey(input)) end)
            passed = true
            tween(card, {
                Size = UDim2.new(0, mobile and 320 or 340, 0, 0),
                Position = UDim2.new(0.5, mobile and -160 or -170, 0.5, 0),
            }, 0.25)
            tween(keyGui, {BackgroundTransparency = 1}, 0.3)
            task.delay(0.3, function()
                pcall(function() keyGui:Destroy() end)
                safecall("KeySystem", cb, true)
            end)
        else
            attempts = attempts + 1
            if attempts >= maxAttempts then
                locked = true
                statusLabel.Text = `Too many attempts. Locked.`
                statusLabel.TextColor3 = theme.Error
                keyInput.TextEditable = false
                submitBtn.Active = false
                tween(submitBtn, {BackgroundTransparency = 0.6}, 0.2)
                if opts.OnLockout then pcall(opts.OnLockout) end
                return
            end
            statusLabel.Text = `Invalid key ({attempts}/{maxAttempts})`
            statusLabel.TextColor3 = theme.Error
            -- shake
            local orig = card.Position
            for i = 1, 3 do
                tween(card, {Position = orig + UDim2.new(0, 8, 0, 0)}, 0.04)
                task.wait(0.04)
                tween(card, {Position = orig + UDim2.new(0, -8, 0, 0)}, 0.04)
                task.wait(0.04)
            end
            tween(card, {Position = orig}, 0.04)
        end
    end

    trackConnection(submitBtn.MouseButton1Click, tryKey)
    trackConnection(keyInput.FocusLost, function(enter)
        if enter then tryKey() end
    end)

    -- Pre-hashed keys can only be checked where the executor exposes
    -- crypt.hash. Without it every input hashes to itself and can never match
    -- any sha256 digest, so fail loudly instead of letting the user guess
    -- against a gate that cannot open.
    if hashedKeys and not hashAvailable then
        locked = true
        statusLabel.Text = "Key check unsupported on this executor"
        statusLabel.TextColor3 = theme.Error
        keyInput.TextEditable = false
        submitBtn.Active = false
        tween(submitBtn, {BackgroundTransparency = 0.6}, 0.2)
        EZError("KeySystem", "HashedKeys needs crypt.hash, which this executor does not expose")
    end

    -- yield current thread until user passes or hits lockout
    -- (so caller can do `if not EZ:KeySystem(...) then return end` synchronously)
    while not passed and not locked do task.wait() end
    return passed
end

-- ~~
-- AUTO SETTINGS
-- Zero-wiring persistence for every window: fetches (or reuses) the
-- ThemeManager/SaveManager addons and attaches a Settings tab with a theme
-- picker, config save/load/autoload and profiles. Hosts opt out with
-- CreateWindow({ AutoSettings = false }).
-- ~~
local function ensureAddon(name)
    -- hosts that loadstring the addons themselves can pre-register them here,
    -- which skips the HTTP fetch entirely
    EZ._addonCache = EZ._addonCache or {}
    local cached = EZ._addonCache[name]
    if cached ~= nil then return cached or nil end

    local ok, mod = pcall(function()
        local src = game:HttpGet(REPO_RAW .. "addons/" .. name .. ".lua")
        if not src then return nil end
        local fn = loadstring(src)
        return typeof(fn) == "function" and fn() or nil
    end)
    if not ok or not mod then
        warn(`[EZ] AutoSettings: failed to load addon "{name}" - {tostring(mod)}`)
        EZ._addonCache[name] = false -- don't retry every window
        return nil
    end

    EZ._addonCache[name] = mod
    return mod
end

-- Shared Settings-tab content (used by AutoSettings and AddSettingsTab).
-- Mirrors Obsidian's layout: Menu + Themes groupboxes down the left column,
-- Configuration down the right. Profiles stay available manually via
-- SaveManager:BuildProfileUI, or opt back in with opts.Profiles = true.
local function buildSettingsContent(window, tab, tm, sm, opts)
    opts = opts or {}
    local wantMenu = opts.Menu ~= false
    local wantThemes = (opts.Themes ~= false) and (opts.Theme ~= false)
    local wantConfigs = opts.Configs ~= false

    local function notify(content, ntype)
        pcall(function()
            EZ:Notify({ Title = "Settings", Content = content, Duration = 2, Type = ntype or "info" })
        end)
    end

    local function trimmedFlag(id)
        local v = EZ.Flags[id]
        if type(v) ~= "string" then return nil end
        v = v:gsub("^%s+", ""):gsub("%s+$", "")
        return v ~= "" and v or nil
    end

    -- ~~ Menu (left) ~~
    if wantMenu then
        local gb = tab:AddLeftGroupbox("Menu", "wrench")

        gb:AddToggle("_EZKeybindMenu", {
            Text = "Open Keybind Menu",
            Default = (EZ._keybindMenu and EZ._keybindMenu.frame and EZ._keybindMenu.frame.Visible) or false,
            Callback = function(v)
                if v then EZ:ShowKeybindMenu() else EZ:HideKeybindMenu() end
            end,
        })

        gb:AddDropdown("_EZKeybindMenuPos", {
            Text = "Keybind Menu Position",
            Values = { "Top Left", "Top Right", "Bottom Left", "Bottom Right" },
            Default = EZ:GetKeybindMenuAnchor(),
            Callback = function(v)
                -- extra parens: dropdown may hand back (value, ...) pairs
                EZ:SetKeybindMenuAnchor(v)
            end,
        })

        gb:AddToggle("_EZCustomCursor", {
            Text = "Custom Cursor",
            Default = EZ._cursorEnabled == true,
            Callback = function(v) EZ:SetCursorEnabled(v) end,
        })

        gb:AddToggle("_EZAlwaysOnTop", {
            Text = "Always On Top",
            Default = false,
            Callback = function(v)
                -- capped above notifications (10000) so Always On Top cannot
                -- dethrone them; 500 is the library default
                gui.DisplayOrder = v and 25000 or 500
            end,
        })

        gb:AddToggle("_EZAntiAFK", {
            Text = "Anti-AFK",
            Description = "prevents the ~20 min idle kick",
            Default = EZ._antiAFK == true,
            Tooltip = "answers the idle event with a virtual controller press",
            Callback = function(v) EZ:SetAntiAFK(v) end,
        })

        gb:AddDropdown("_EZNotifSide", {
            Text = "Notification Side",
            Values = { "Left", "Right" },
            Default = EZ._notifSide or "Right",
            Callback = function(v) EZ:SetNotificationSide(v) end,
        })

        gb:AddDropdown("_EZDPIScale", {
            Text = "DPI Scale",
            Values = { "50%", "75%", "90%", "100%", "110%", "125%", "150%", "175%", "200%" },
            Default = tostring(math.floor((window:GetScale() or 1) * 100 + 0.5)) .. "%",
            Callback = function(v)
                -- extra parens: gsub returns (str, count) and a bare call
                -- would feed the count into tonumber's base argument
                local n = tonumber((tostring(v):gsub("%%", ""))) or 100
                window:SetScale(n / 100)
            end,
        })

        gb:AddSlider("_EZCornerRadius", {
            Text = "Corner Radius",
            Min = 0, Max = 20, Increment = 1,
            Default = EZ._cornerRadiusOverride or 14,
            Suffix = "/20",
            Callback = function(v) EZ:SetCornerRadius(v) end,
        })

        -- Rebinding here moves the window hotkey itself; the keybind does not
        -- toggle anything on its own, so the hotkey never double-fires.
        local menuBind = gb:AddKeybind("_EZMenuBind", {
            Text = "Menu bind",
            Default = window.GetToggleKey and window:GetToggleKey() or Enum.KeyCode.RightShift,
            Mode = "Toggle",
        })
        menuBind:OnChanged(function(k)
            if typeof(k) == "EnumItem" and window.SetToggleKey then
                window:SetToggleKey(k)
            end
        end)

        gb:AddButton({
            Text = "Toggle panic (all scripts)",
            Callback = function() EZ:TogglePanic() end,
        })

        gb:AddButton({
            Text = "Unload",
            Callback = function() EZ:Destroy() end,
        })
    end

    -- ~~ Themes (left) ~~
    if wantThemes and tm then
        local gb = tab:AddLeftGroupbox("Themes", "palette")

        local function rolePicker(id, text, role)
            gb:AddColorPicker(id, {
                Text = text,
                Default = EZ.Theme[role],
                Callback = function(c) EZ:SetTheme({ [role] = c }) end,
            })
        end
        rolePicker("_EZColBackground", "Background color", "Base")
        rolePicker("_EZColMain", "Main color", "Surface")
        rolePicker("_EZColAccent", "Accent color", "Accent")
        rolePicker("_EZColOutline", "Outline color", "Border")
        rolePicker("_EZColFont", "Font color", "Text")

        gb:AddDropdown("_EZFontFace", {
            Text = "Font Face",
            Values = EZ.FONT_FAMILIES,
            Default = "Default",
            Callback = function(v) EZ:SetFont(v) end,
        })

        gb:AddInput("_EZBgImage", {
            Text = "Background Image",
            Placeholder = "rbxassetid://...",
            Callback = function(v)
                if window.SetBackgroundImage then window:SetBackgroundImage(v) end
            end,
        })

        -- forward-declared so refreshThemeLists closes over the real handles
        local themeDD
        local customDD
        local function refreshThemeLists()
            if themeDD then themeDD:Refresh(tm:GetThemes()) end
            if customDD and customDD.Refresh then
                local names = tm.GetCustomThemeNames and tm:GetCustomThemeNames() or {}
                customDD:Refresh(#names > 0 and names or { "---" })
            end
        end

        themeDD = gb:AddDropdown("_EZTheme", {
            Text = "Theme list",
            Values = tm:GetThemes(),
            Default = tm.Current,
            Callback = function(v) tm:SetTheme(v) end,
        })

        gb:AddButton({
            Text = "Set as default",
            Callback = function()
                local v = EZ.Flags._EZTheme
                if type(v) == "string" then tm:SetTheme(v) end
            end,
        })

        gb:AddInput("_EZCustomThemeName", {
            Text = "Custom theme name",
            Placeholder = "my-theme",
        })

        gb:AddButton({
            Text = "Create theme",
            Callback = function()
                local name = trimmedFlag("_EZCustomThemeName")
                if not name then
                    notify("Type a name in 'Custom theme name' first", "warning")
                    return
                end
                if typeof(tm.AddCustomTheme) ~= "function" then
                    notify("ThemeManager addon is outdated - update it", "error")
                    return
                end
                local snapshot = {}
                for _, role in { "Base", "Surface", "Panel", "Border", "Accent", "AccentDark",
                    "Text", "TextDim", "TextMuted", "Success", "Warning", "Error", "Info" } do
                    snapshot[role] = EZ.Theme[role]
                end
                tm:AddCustomTheme(name, snapshot)
                refreshThemeLists()
                pcall(function() customDD:Set(name, true) end)
                notify(`Created theme "{name}"`, "success")
            end,
        })

        customDD = gb:AddDropdown("_EZCustomThemeList", {
            Text = "Custom themes",
            Values = (#(tm.GetCustomThemeNames and tm:GetCustomThemeNames() or {})) > 0
                and tm:GetCustomThemeNames() or { "---" },
            Default = "---",
        })

        local function selectedCustom()
            local v = EZ.Flags._EZCustomThemeList
            if type(v) ~= "string" or v == "---" then return nil end
            return v
        end

        gb:AddButton({ Text = "Load theme", Callback = function()
            local name = selectedCustom()
            if name then tm:SetTheme(name) end
        end })

        gb:AddButton({ Text = "Overwrite theme", Callback = function()
            local name = selectedCustom()
            if not name then
                notify("Select a custom theme first", "warning")
                return
            end
            if typeof(tm.AddCustomTheme) == "function" then
                local snapshot = {}
                for _, role in { "Base", "Surface", "Panel", "Border", "Accent", "AccentDark",
                    "Text", "TextDim", "TextMuted", "Success", "Warning", "Error", "Info" } do
                    snapshot[role] = EZ.Theme[role]
                end
                tm:AddCustomTheme(name, snapshot)
                notify(`Overwrote theme "{name}"`, "success")
            end
        end })

        gb:AddButton({ Text = "Delete theme", Callback = function()
            local name = selectedCustom()
            if not name then
                notify("Select a custom theme first", "warning")
                return
            end
            local ok, err = tm.DeleteTheme and tm:DeleteTheme(name)
            refreshThemeLists()
            if ok then
                notify(`Deleted theme "{name}"`, "success")
            else
                notify(tostring(err or "Delete failed"), "error")
            end
        end })

        gb:AddButton({ Text = "Refresh list", Callback = refreshThemeLists })

        gb:AddButton({ Text = "Set as default", Callback = function()
            local name = selectedCustom()
            if name then tm:SetTheme(name) end
        end })

        gb:AddButton({ Text = "Reset default", Callback = function()
            if tm.ResetDefault then tm:ResetDefault() end
            refreshThemeLists()
            pcall(function() themeDD:Set(tm.Current, true) end)
        end })

        local defaultLbl = gb:AddLabel("Current default theme: " .. tostring(tm.Current or "none"))
        local function syncDefaultLabel()
            defaultLbl:Set("Current default theme: " .. tostring(tm.Current or "none"))
        end
        EZ:OnFlagChanged("_EZTheme", syncDefaultLabel)

        gb:AddInput("_EZThemeJSON", {
            Text = "Theme JSON",
            Placeholder = "paste json",
        })

        gb:AddButton({ Text = "Import theme", Callback = function()
            local json = trimmedFlag("_EZThemeJSON")
            if not json then
                notify("Paste theme JSON into the box first", "warning")
                return
            end
            if typeof(tm.ImportTheme) ~= "function" then
                notify("ThemeManager addon is outdated - update it", "error")
                return
            end
            local ok, err = tm:ImportTheme(json, trimmedFlag("_EZCustomThemeName"))
            if ok then
                refreshThemeLists()
                syncDefaultLabel()
            end
            notify(ok and "Theme imported" or tostring(err or "Import failed"),
                ok and "success" or "error")
        end })

        gb:AddButton({ Text = "Export current theme", Callback = function()
            if typeof(tm.ExportTheme) ~= "function" then
                notify("ThemeManager addon is outdated - update it", "error")
                return
            end
            local json = tm:ExportTheme(tm.Current)
            if json then
                pcall(function() setclipboard(json) end)
                notify("Theme JSON copied to clipboard", "success")
            else
                notify("Export failed", "error")
            end
        end })
    end

    -- ~~ Configuration (right) ~~
    if wantConfigs and sm then
        local gb = tab:AddRightGroupbox("Configuration", "folder-cog")
        sm:BuildConfigSection(gb, window)
    end

    -- ~~ Profiles (right, opt-in only) ~~
    if opts.Profiles and sm then
        local gb = tab:AddRightGroupbox("Profiles", "users")
        sm:BuildProfileUI(gb, window)
    end
end

local function buildAutoSettings(window)
    local ThemeManager = ensureAddon("ThemeManager")
    local SaveManager = ensureAddon("SaveManager")
    if not ThemeManager or not SaveManager then return end

    -- adopt existing bindings instead of rebinding over the host's choices
    if ThemeManager.Library ~= EZ then ThemeManager:Bind(EZ) end
    if SaveManager.Library ~= EZ then
        SaveManager:SetLibrary(EZ)
        SaveManager:BuildFolderTree()
    end

    ThemeManager:LoadSaved()
    for name, tbl in EZ.Themes do
        ThemeManager:AddTheme(name, tbl)
    end

    -- a host-built Settings tab wins; we only add autoload on top
    for _, t in window.Tabs do
        if t.Name == "Settings" then
            if not EZ._autoloadRan then
                EZ._autoloadRan = true
                task.defer(function() SaveManager:LoadAutoloadConfig() end)
            end
            return
        end
    end

    local tab = window:AddTab("Settings", "settings")

    -- Pin the Settings button to the bottom of the sidebar. UIListLayout
    -- sorts by LayoutOrder and every user tab defaults to 0, so this keeps
    -- Settings last even when a host adds tabs after this deferred build.
    if tab._btn then tab._btn.LayoutOrder = 1e9 end

    buildSettingsContent(window, tab, ThemeManager, SaveManager)

    -- deferred so it runs after the host finished adding its own tabs;
    -- restoring earlier would silently skip not-yet-created elements
    if not EZ._autoloadRan then
        EZ._autoloadRan = true
        task.defer(function()
            SaveManager:LoadAutoloadConfig()
        end)
    end
end

function EZ:CreateWindow(opts)
    self._destroyed = false
    opts = opts or {}
    local theme = self.Theme
    local mobile = isMobile()
    local screen = getScreenSize()

    local winW = opts.Width or (mobile and math.min(screen.X - 20, 380) or 620)
    local winH = opts.Height or (mobile and math.min(screen.Y - 80, 420) or 440)
    local tabW = opts.TabWidth or (mobile and 52 or 150)

    -- Restore last session's window geometry (position + size). Keyed by
    -- title so parallel scripts don't fight over one file; titles that
    -- differ only in punctuation would collide, so hosts can pass their
    -- own GeometryId instead. The dock file follows the same key.
    local geomKey = type(opts.GeometryId) == "string" and string.gsub(opts.GeometryId, "[^%w%-_]", "") or ""
    if geomKey == "" then
        geomKey = string.gsub(string.lower(string.gsub(opts.Title or "window", "[^%w]", "")), "^$", "window")
    end
    local geomFile = "EZGeom_" .. geomKey .. ".txt"
    local dockFile = "EZDockPos_" .. geomKey .. ".txt"
    local savedPos
    if opts.PersistGeometry ~= false and not mobile then
        pcall(function()
            if isfile and readfile and isfile(geomFile) then
                local raw = readfile(geomFile)
                if type(raw) == "string" then
                    local px, py = raw:match("pos=(%-?%d+),(%-?%d+)")
                    local sw, sh = raw:match("size=(%d+),(%d+)")
                    if px and py then
                        -- clamp against the current viewport so a saved
                        -- position from a bigger screen cannot strand the
                        -- window off-screen
                        local sx = math.max(80, screen.X - 80)
                        local sy = math.max(46, screen.Y - 46)
                        savedPos = UDim2.fromOffset(clamp(tonumber(px), 0, sx), clamp(tonumber(py), 0, sy))
                    end
                    if sw and sh then
                        local w, h = tonumber(sw), tonumber(sh)
                        if w >= 460 and h >= 360 then
                            winW = math.min(w, math.max(460, screen.X - 20))
                            winH = math.min(h, math.max(360, screen.Y - 40))
                        end
                    end
                end
            end
        end)
    end

    local window = {
        Tabs = {},
        ActiveTab = nil,
        Visible = true,
        Title = opts.Title or "EZ",
        _flags = self.Flags,
        _theme = theme,
        _connections = {},
        _popups = {},
        _destroyed = false,
    }

    -- All connections created synchronously while building this window are
    -- associated with it. Restore any previous owner before returning.
    local previousConnectionOwner = EZ._connectionOwner
    EZ._connectionOwner = window

    -- Tabs, sections and elements are built long after CreateWindow() returns,
    -- when the global owner is no longer set. Wrapping each builder re-asserts
    -- this window for the duration of the call, so window:Destroy() really does
    -- disconnect the global input hooks its keybinds/sliders/pickers created.
    local function owned(fn)
        return function(...)
            local prev = EZ._connectionOwner
            EZ._connectionOwner = window
            local ok, result = pcall(fn, ...)
            EZ._connectionOwner = prev
            if not ok then error(result, 0) end
            return result
        end
    end

    -- Popups (colour pickers) are parented to the root ScreenGui so section
    -- clipping cannot cut them off. That also means this window has to close
    -- and destroy them itself, or they outlive it on screen.
    local function registerPopup(frame, close)
        table.insert(window._popups, { frame = frame, close = close })
    end

    local function closePopups()
        for _, popup in window._popups do
            if popup.close then pcall(popup.close, true) end
        end
    end

    -- Only one dropdown may be open at a time, and clicking anywhere else
    -- dismisses it. Previously an open list stayed up indefinitely, covering
    -- whatever sat below it, and two lists could overlap each other.
    local activeDropdown = nil
    local function closeActiveDropdown()
        local d = activeDropdown
        activeDropdown = nil
        if d then pcall(d.close) end
    end
    local function setActiveDropdown(entry)
        if activeDropdown and activeDropdown ~= entry then closeActiveDropdown() end
        activeDropdown = entry
    end
    local function clearActiveDropdown(entry)
        if activeDropdown == entry then activeDropdown = nil end
    end

    local function pointInside(obj, pos)
        if not obj or not obj.Parent or not obj.Visible then return false end
        local p, sz = obj.AbsolutePosition, obj.AbsoluteSize
        return pos.X >= p.X and pos.X <= p.X + sz.X
            and pos.Y >= p.Y and pos.Y <= p.Y + sz.Y
    end

    -- main frame
    local main = create("Frame", {
        Name = "EZWindow",
        Size = UDim2.new(0, winW, 0, winH),
        Position = savedPos or UDim2.new(0.5, -winW/2, 0.5, -winH/2),
        BackgroundColor3 = theme.Base,
        BackgroundTransparency = 0.02,
        ClipsDescendants = true,
        Parent = gui
    })
    addCorner(main, 14)
    addStroke(main, theme.Border, 1, 0.25)
    -- subtle accent ambient (premium glow)
    local glowStroke = create("UIStroke", {
        Color = theme.Accent,
        Thickness = 2,
        Transparency = 0.85,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = main
    })
    window._glowStroke = glowStroke
    window._main = main

    -- ui scale (global multiplier for everything inside the window)
    local uiScale = create("UIScale", {
        Scale = opts.Scale or 1,
        Parent = main,
    })
    function window:SetScale(s)
        uiScale.Scale = math.clamp(s, 0.5, 2)
    end
    function window:GetScale() return uiScale.Scale end

    -- Optional background image layer (Settings > Background Image).
    -- Accepts rbxassetid:// urls, plain numeric ids, or "" / nil to clear.
    local bgImage
    function window:SetBackgroundImage(asset)
        local url = EZ:ResolveIcon(asset)
        if not url then
            if bgImage then
                pcall(function() bgImage:Destroy() end)
                bgImage = nil
            end
            return
        end
        if not bgImage or not bgImage.Parent then
            bgImage = create("ImageLabel", {
                Name = "EZBgImage",
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                ImageTransparency = 0.82,
                ScaleType = Enum.ScaleType.Fit,
                ZIndex = 0,
                Parent = main,
            })
        end
        bgImage.Image = url
    end

    -- glass overlay
    local glass = create("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = theme.Surface,
        BackgroundTransparency = 0.7,
        BorderSizePixel = 0,
        ZIndex = 1,
        Parent = main
    })
    addCorner(glass, 14)

    -- top accent line (gradient-faded edges so it feels like a glow strip)
    local accentLine = create("Frame", {
        Size = UDim2.new(0, 80, 0, 2),
        Position = UDim2.new(0.5, -40, 0, 0),
        BackgroundColor3 = theme.Accent,
        BorderSizePixel = 0,
        ZIndex = 10,
        Parent = main
    })
    create("UIGradient", {
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.5, 0),
            NumberSequenceKeypoint.new(1, 1),
        }),
        Parent = accentLine
    })

    -- header
    local header = create("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, 46),
        BackgroundColor3 = theme.Base,
        BackgroundTransparency = 0.1,
        BorderSizePixel = 0,
        ZIndex = 5,
        Parent = main
    })
    addCorner(header, 14)
    
    -- logo dot (gently pulses so window feels "alive")
    local logoDot = create("Frame", {
        Size = UDim2.new(0, 7, 0, 7),
        Position = UDim2.new(0, 16, 0.5, -3),
        BackgroundColor3 = theme.Accent,
        BorderSizePixel = 0,
        ZIndex = 6,
        Parent = header
    })
    addCorner(logoDot, 4)
    -- pulse halo
    local logoHalo = create("Frame", {
        Size = UDim2.new(0, 7, 0, 7),
        Position = UDim2.new(0, 16, 0.5, -3),
        BackgroundColor3 = theme.Accent,
        BackgroundTransparency = 0.6,
        BorderSizePixel = 0,
        ZIndex = 5,
        Parent = header,
    })
    addCorner(logoHalo, 4)
    -- pulse only while the window is actually on screen; the old loop kept
    -- queueing tweens for a hidden/minimized window forever
    task.spawn(function()
        while logoHalo.Parent do
            if main.Visible then
                tween(logoHalo, {Size = UDim2.new(0, 16, 0, 16), Position = UDim2.new(0, 12, 0.5, -8), BackgroundTransparency = 1}, 1.4, Enum.EasingStyle.Sine)
                task.wait(1.4)
                if not logoHalo.Parent then break end
                logoHalo.Size = UDim2.new(0, 7, 0, 7)
                logoHalo.Position = UDim2.new(0, 16, 0.5, -3)
                logoHalo.BackgroundTransparency = 0.6
                task.wait(0.4)
            else
                task.wait(0.5)
            end
        end
    end)

    -- title
    create("TextLabel", {
        Size = UDim2.new(0, 200, 0, 16),
        Position = UDim2.new(0, 30, 0, 8),
        BackgroundTransparency = 1,
        Text = opts.Title or "EZ",
        TextColor3 = theme.Text,
        TextSize = 14,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 6,
        Parent = header
    })

    -- subtitle
    if opts.SubTitle then
        create("TextLabel", {
            Size = UDim2.new(0, 200, 0, 12),
            Position = UDim2.new(0, 30, 0, 24),
            BackgroundTransparency = 1,
            Text = opts.SubTitle,
            TextColor3 = theme.TextMuted,
            TextSize = 10,
            Font = Enum.Font.Gotham,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 6,
            Parent = header
        })
    end

    -- search bar (header right, before the 3 buttons; collapses to icon on mobile)
    local searchBarW = mobile and 28 or 160
    local searchBar = create("Frame", {
        Name = "EZSearchBar",
        Size = UDim2.new(0, searchBarW, 0, 26),
        Position = UDim2.new(1, -(110 + searchBarW + 6), 0.5, -13),
        BackgroundColor3 = theme.Surface,
        BackgroundTransparency = mobile and 0.4 or 0.1,
        BorderSizePixel = 0,
        ZIndex = 7,
        Parent = header,
    })
    addCorner(searchBar, 6)
    local searchStroke = addStroke(searchBar, theme.Border, 1, 0.5)

    -- search icon
    create("ImageLabel", {
        Size = UDim2.new(0, 14, 0, 14),
        Position = UDim2.new(0, 6, 0.5, -7),
        BackgroundTransparency = 1,
        Image = "rbxassetid://121018724060431",
        ImageColor3 = theme.TextMuted,
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 8,
        Parent = searchBar,
    })

    local searchBox = create("TextBox", {
        Size = UDim2.new(1, -28, 1, 0),
        Position = UDim2.new(0, 24, 0, 0),
        BackgroundTransparency = 1,
        Text = "",
        PlaceholderText = "Search...",
        TextColor3 = theme.Text,
        PlaceholderColor3 = theme.TextMuted,
        TextSize = 12,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        ZIndex = 8,
        Parent = searchBar,
        Visible = not mobile,
    })

    trackConnection(searchBox.Focused, function()
        tween(searchStroke, {Color = theme.Accent, Transparency = 0.2}, 0.15)
    end)
    trackConnection(searchBox.FocusLost, function()
        tween(searchStroke, {Color = theme.Border, Transparency = 0.5}, 0.15)
    end)

    -- Dedicated drag handle. Keeping controls outside this hit area prevents
    -- minimize/close/search clicks from also starting a window drag.
    local dragHandle = create("TextButton", {
        Name = "EZDragHandle",
        Size = UDim2.new(1, -(110 + searchBarW + 12), 1, 0),
        Position = UDim2.new(0, 0, 0, 0),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 6,
        Parent = header,
    })

    -- mobile: tap icon to expand. expanded bar sits ABOVE the buttons row
    -- (full width minus padding) so it doesnt clip the close/min/toggle.
    -- a small × at the right of the expanded bar lets users collapse it.
    local mobileExpanded = false
    local searchCloseBtn
    -- Where the collapsed bar sits. Recorded rather than recomputed so an
    -- addon that shifts the bar (NotificationHistory adds a header bell)
    -- does not get snapped back the first time the user collapses it.
    local searchCollapsedPos = searchBar.Position
    -- mirrored onto the window so addons that shift the bar (NotificationHistory)
    -- can keep the collapse target honest
    window._searchCollapsedPos = searchCollapsedPos
    if mobile then
        local tapBtn = create("TextButton", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = "",
            ZIndex = 9,
            Parent = searchBar,
        })

        -- close icon that appears only when expanded, used to collapse
        searchCloseBtn = create("TextButton", {
            Size = UDim2.new(0, 22, 1, 0),
            Position = UDim2.new(1, -22, 0, 0),
            BackgroundTransparency = 1,
            Text = "",
            ZIndex = 10,
            Visible = false,
            Parent = searchBar,
        })
        create("ImageLabel", {
            Size = UDim2.new(0, 12, 0, 12),
            Position = UDim2.new(0.5, -6, 0.5, -6),
            BackgroundTransparency = 1,
            Image = "rbxassetid://110786993356448",
            ImageColor3 = theme.TextMuted,
            ScaleType = Enum.ScaleType.Fit,
            ZIndex = 11,
            Parent = searchCloseBtn,
        })

        local function collapse()
            mobileExpanded = false
            searchBox.Text = ""
            searchBox.Visible = false
            searchCloseBtn.Visible = false
            local home = window._searchCollapsedPos or searchCollapsedPos
            tween(searchBar, {Size = UDim2.new(0, 28, 0, 26), Position = home, BackgroundTransparency = 0.4}, 0.2)
            if window._applySearch then window:_applySearch("") end
        end

        trackConnection(tapBtn.MouseButton1Click, function()
            if mobileExpanded then return end
            searchCollapsedPos = searchBar.Position
            window._searchCollapsedPos = searchCollapsedPos
            mobileExpanded = true
            searchBox.Visible = true
            -- shrink box width to leave room for × button
            searchBox.Size = UDim2.new(1, -52, 1, 0)
            -- Place the expanded bar near the right edge but stop short of the
            -- action buttons. The reserve covers collapse/minimize/close plus
            -- the optional NotificationHistory bell, which sits at -126.
            tween(searchBar, {Size = UDim2.new(1, -160, 0, 26), Position = UDim2.new(0, 12, 0.5, -13), BackgroundTransparency = 0}, 0.2)
            searchCloseBtn.Visible = true
            task.delay(0.22, function()
                if mobileExpanded then searchBox:CaptureFocus() end
            end)
        end)

        trackConnection(searchCloseBtn.MouseButton1Click, collapse)
        -- also collapse if user taps elsewhere & box loses focus with no text
        trackConnection(searchBox.FocusLost, function()
            if mobileExpanded and searchBox.Text == "" then
                task.wait(0.1)
                if mobileExpanded and searchBox.Text == "" then collapse() end
            end
        end)
    end

    -- core filter, walks every elem frame's EZSearch attr
    function window:_applySearch(q)
        q = string.lower(q or "")
        local searching = q ~= ""

        -- returns true when the section still has something worth showing
        local function filterSection(secFrame)
            local anyVisible = false
            for _, child in secFrame:GetDescendants() do
                if child:IsA("GuiObject") then
                    local s = child:GetAttribute("EZSearch")
                    if s then
                        local match = not searching or string.find(s, q, 1, true) ~= nil
                        child:SetAttribute("EZSearchHidden", not match)
                        applyElementVisibility(child)
                        if child.Visible then anyVisible = true end
                    end
                end
            end
            -- hide whole section if nothing matches and there's a query
            secFrame.Visible = not searching or anyVisible
            return secFrame.Visible
        end

        for _, t in self.Tabs do
            local content = t._content
            if content then
                -- sections parented straight to the tab
                for _, secFrame in content:GetChildren() do
                    if secFrame:IsA("Frame")
                        and not secFrame:GetAttribute("EZSubRow")
                        and not secFrame:GetAttribute("EZSubContainer")
                        and not secFrame:GetAttribute("EZGroupRow")
                    then
                        filterSection(secFrame)
                    end
                end

                -- groupbox columns: each box inside a column filters like a
                -- normal section; the columns themselves stay put
                for _, col in t._groupCols or {} do
                    for _, secFrame in col:GetChildren() do
                        if secFrame:IsA("Frame") then
                            filterSection(secFrame)
                        end
                    end
                end

                -- Sections that live inside a sub-tab. The container visibility
                -- belongs to the sub-tab selection, so it is only borrowed
                -- while a query is active and handed straight back afterwards
                -- instead of leaving every sub-tab showing at once.
                for _, sub in t.SubTabs or {} do
                    local container = sub._container
                    if container then
                        local anyVisible = false
                        for _, secFrame in container:GetChildren() do
                            if secFrame:IsA("Frame") and filterSection(secFrame) then
                                anyVisible = true
                            end
                        end
                        if searching then
                            container.Visible = anyVisible
                        else
                            container.Visible = t._activeSub == sub
                        end
                    end
                end
            end
        end
    end

    -- coalesce keystrokes: the _applySearch descendant walk runs at most
    -- once per frame instead of once per character typed
    local searchScheduled = false
    trackConnection(searchBox:GetPropertyChangedSignal("Text"), function()
        if searchScheduled then return end
        searchScheduled = true
        task.defer(function()
            searchScheduled = false
            window:_applySearch(searchBox.Text)
        end)
    end)

    -- close button
    local windowCloseBtn = create("TextButton", {
        Name = "EZCloseBtn",
        Size = UDim2.new(0, 24, 0, 24),
        Position = UDim2.new(1, -36, 0.5, -12),
        BackgroundColor3 = theme.Panel,
        BackgroundTransparency = 0.15,
        Text = "",
        BorderSizePixel = 0,
        ZIndex = 7,
        AutoButtonColor = false,
        Parent = header
    })
    addCorner(windowCloseBtn, 8)
    addStroke(windowCloseBtn, theme.Border, 1, 0.35)
    
    create("ImageLabel", {
        Size = UDim2.new(0, 12, 0, 12),
        Position = UDim2.new(0.5, -6, 0.5, -6),
        BackgroundTransparency = 1,
        Image = "rbxassetid://110786993356448",
        ImageColor3 = theme.Text,
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 8,
        Parent = windowCloseBtn,
    })
    
    trackConnection(windowCloseBtn.MouseEnter, function()
        tween(windowCloseBtn, {BackgroundColor3 = theme.Accent, BackgroundTransparency = 0}, 0.15)
    end)
    trackConnection(windowCloseBtn.MouseLeave, function()
        tween(windowCloseBtn, {BackgroundColor3 = theme.Panel, BackgroundTransparency = 0.15}, 0.15)
    end)

    -- minimize button
    local minBtn = create("TextButton", {
        Size = UDim2.new(0, 24, 0, 24),
        Position = UDim2.new(1, -66, 0.5, -12),
        BackgroundColor3 = theme.Panel,
        BackgroundTransparency = 0.15,
        Text = "",
        BorderSizePixel = 0,
        ZIndex = 7,
        AutoButtonColor = false,
        Parent = header
    })
    create("ImageLabel", {
        Size = UDim2.new(0, 12, 0, 12),
        Position = UDim2.new(0.5, -6, 0.5, -6),
        BackgroundTransparency = 1,
        Image = "rbxassetid://118026365011536",
        ImageColor3 = theme.Text,
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 8,
        Parent = minBtn,
    })
    addCorner(minBtn, 8)
    addStroke(minBtn, theme.Border, 1, 0.35)

    trackConnection(minBtn.MouseEnter, function()
        tween(minBtn, {BackgroundColor3 = theme.Accent, BackgroundTransparency = 0}, 0.15)
    end)
    trackConnection(minBtn.MouseLeave, function()
        tween(minBtn, {BackgroundColor3 = theme.Panel, BackgroundTransparency = 0.15}, 0.15)
    end)

    -- tab sidebar
    local sidebar = create("Frame", {
        Name = "Sidebar",
        Size = UDim2.new(0, tabW, 1, -48),
        Position = UDim2.new(0, 0, 0, 48),
        BackgroundColor3 = theme.Panel,
        BackgroundTransparency = 0.15,
        BorderSizePixel = 0,
        ZIndex = 4,
        ClipsDescendants = true,
        Parent = main
    })
    -- Round the sidebar to match the window corner. ClipsDescendants only
    -- clips to rectangular bounds, so a square-cornered panel pokes visibly
    -- past the window's rounded bottom-left corner.
    addCorner(sidebar, 14)

    -- sidebar separator
    -- starts/stops 14px from the edges so its square ends stay inside the
    -- sidebar's rounded corner arcs (UICorner does not clip children)
    create("Frame", {
        Size = UDim2.new(0, 1, 1, -28),
        Position = UDim2.new(1, 0, 0, 14),
        BackgroundColor3 = theme.Border,
        BackgroundTransparency = 0.5,
        BorderSizePixel = 0,
        ZIndex = 5,
        Parent = sidebar
    })

    local tabList = create("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, -6),
        Position = UDim2.new(0, 0, 0, 6),
        BackgroundTransparency = 1,
        ScrollBarThickness = 0,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ZIndex = 5,
        Parent = sidebar,
        Children = {
            create("UIListLayout", {
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 2),
            }),
            create("UIPadding", {
                PaddingTop = UDim.new(0, 2),
                PaddingLeft = UDim.new(0, 4),
                PaddingRight = UDim.new(0, 4),
            })
        }
    })

    -- active tab indicator (height adapts to tab content)
    local indicatorH = mobile and 28 or 18
    local tabIndicator = create("Frame", {
        Size = UDim2.new(0, 3, 0, indicatorH),
        Position = UDim2.new(0, 2, 0, 8),
        BackgroundColor3 = theme.Accent,
        BorderSizePixel = 0,
        ZIndex = 7,
        Parent = sidebar
    })
    addCorner(tabIndicator, 2)

    -- content area
    local contentArea = create("Frame", {
        Name = "Content",
        Size = UDim2.new(1, -(tabW + 2), 1, -48),
        Position = UDim2.new(0, tabW + 2, 0, 48),
        BackgroundTransparency = 1,
        ZIndex = 3,
        ClipsDescendants = true,
        Parent = main
    })

    -- UserInputService fires ahead of the GUI click events, so a click on the
    -- dropdown itself is recognised here and left alone.
    trackConnection(UserInputService.InputBegan, function(inp)
        if not activeDropdown then return end
        if inp.UserInputType == Enum.UserInputType.MouseWheel then
            -- scrolling away must not leave the list floating detached
            closeActiveDropdown()
            return
        end
        if inp.UserInputType ~= Enum.UserInputType.MouseButton1
            and inp.UserInputType ~= Enum.UserInputType.Touch then return end
        local pos = Vector2.new(inp.Position.X, inp.Position.Y)
        if pointInside(activeDropdown.list, pos) or pointInside(activeDropdown.header, pos) then
            return
        end
        closeActiveDropdown()
    end)

    -- dragging
    local dragging, dragStart, dragOrigin = false, nil, nil

    local function beginDrag(pos)
        dragging = true
        dragStart = pos
        dragOrigin = main.AbsolutePosition
    end
    local function updateDrag(pos)
        if not dragging then return end
        -- Clamp so the window can never be lost off-screen: at least 80px of
        -- width and the full header height stay inside the viewport.
        local screen = getScreenSize()
        local size = main.AbsoluteSize
        local target = dragOrigin + (pos - dragStart)
        local nx = clamp(target.X, -(size.X - 80), math.max(0, screen.X - 80))
        local ny = clamp(target.Y, 0, math.max(0, screen.Y - 46))
        main.Position = UDim2.fromOffset(nx, ny)
    end
    local function endDrag() dragging = false end

    -- persist position+size so the window reopens where the user left it
    local minimized = false
    local restorePosition = main.Position
    local restoreSize = main.Size
    local function saveGeometry()
        pcall(function()
            if writefile then
                writefile(geomFile, ("pos=%d,%d\nsize=%d,%d"):format(
                    math.floor(main.Position.X.Offset + 0.5),
                    math.floor(main.Position.Y.Offset + 0.5),
                    math.floor(main.Size.X.Offset + 0.5),
                    math.floor(main.Size.Y.Offset + 0.5)))
            end
        end)
    end

    trackConnection(dragHandle.InputBegan, function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            beginDrag(Vector2.new(inp.Position.X, inp.Position.Y))
        end
    end)
    trackConnection(UserInputService.InputChanged, function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then
            updateDrag(Vector2.new(inp.Position.X, inp.Position.Y))
        end
    end)
    trackConnection(UserInputService.InputEnded, function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if dragging then
                dragging = false
                saveGeometry()
            end
        end
    end)

    -- ~~--------
    -- RESIZE GRIP (bottom-right corner drag; Obsidian-style)
    -- ~~--------
    -- never larger than the created window: on small/mobile screens the old
    -- fixed 460x360 minimum exceeded the default size itself
    local MIN_W, MIN_H = math.min(460, winW), math.min(360, winH)
    local resizing = false
    local resizeStart, startSize

    local resizeGrip = create("TextButton", {
        Name = "EZResizeGrip",
        Size = UDim2.new(0, 18, 0, 18),
        Position = UDim2.new(1, -20, 1, -20),
        BackgroundColor3 = theme.Surface,
        BackgroundTransparency = 1,
        Text = "",
        BorderSizePixel = 0,
        AutoButtonColor = false,
        ZIndex = 60,
        Parent = main
    })
    trackConnection(resizeGrip.InputBegan, function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            resizing = true
            resizeStart = Vector2.new(inp.Position.X, inp.Position.Y)
            startSize = Vector2.new(main.Size.X.Offset, main.Size.Y.Offset)
        end
    end)
    trackConnection(UserInputService.InputChanged, function(inp)
        if not resizing then return end
        if inp.UserInputType ~= Enum.UserInputType.MouseMovement
            and inp.UserInputType ~= Enum.UserInputType.Touch then return end
        -- divide by UIScale so the drag distance matches on-screen pixels
        local scale = uiScale.Scale > 0 and uiScale.Scale or 1
        local delta = (Vector2.new(inp.Position.X, inp.Position.Y) - resizeStart) / scale
        local screen = getScreenSize()
        local newW = clamp(startSize.X + delta.X, MIN_W, math.max(MIN_W, screen.X - 20))
        local newH = clamp(startSize.Y + delta.Y, MIN_H, math.max(MIN_H, screen.Y - 40))
        main.Size = UDim2.new(0, math.floor(newW), 0, math.floor(newH))
        -- keep hide/show restores consistent with the new size
        restoreSize = main.Size
    end)
    trackConnection(UserInputService.InputEnded, function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if resizing then
                resizing = false
                saveGeometry()
            end
        end
    end)
    trackConnection(resizeGrip.MouseEnter, function()
        tween(resizeGrip, {BackgroundTransparency = 0.35}, 0.15)
    end)
    trackConnection(resizeGrip.MouseLeave, function()
        tween(resizeGrip, {BackgroundTransparency = 1}, 0.15)
    end)

    -- floating minimize dock: Open / Panic / Keybinds tiles instead of the
    -- old single plain pill. Whole dock stays draggable; QuickBar keeps
    -- working because it drives this frame through window._togglePill.
    local resolvedToggleIcon = EZ:ResolveIcon(opts.ToggleIcon)
    local pillText = opts.ToggleText or "V"
    local tileS = mobile and 40 or 34
    local dockPad = mobile and 6 or 5
    local dockGap = 5
    local dockTiles = 3
    local pillH = tileS + dockPad * 2
    local pillW = dockPad * 2 + dockTiles * tileS + (dockTiles - 1) * dockGap

    -- restore last dock position (per-window file so parallel scripts and
    -- multi-window hosts don't fight over one spot; falls back to the
    -- pre-3.6 shared EZDockPos.txt so existing users keep their parked dock)
    local dockSavedPos
    pcall(function()
        local raw
        if isfile and readfile then
            if isfile(dockFile) then
                raw = readfile(dockFile)
            elseif isfile("EZDockPos.txt") then
                raw = readfile("EZDockPos.txt")
            end
        end
        if raw then
            local px, py = tostring(raw):match("pos=(%-?%d+),(%-?%d+)")
            if px and py then dockSavedPos = UDim2.fromOffset(tonumber(px), tonumber(py)) end
        end
    end)
    -- once the user parks the dock themselves (this session or a past one),
    -- minimize must leave it exactly there instead of snapping to the window
    local dockHasCustomPos = dockSavedPos ~= nil

    local togglePill = create("Frame", {
        Name = "EZToggle",
        Size = UDim2.new(0, pillW, 0, pillH),
        Position = dockSavedPos or UDim2.new(0, 12, 0.5, -pillH / 2),
        BackgroundColor3 = theme.Base,
        BackgroundTransparency = 0.05,
        BorderSizePixel = 0,
        Active = true,
        ZIndex = 100,
        Visible = false,
        Parent = gui,
        Children = {
            create("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                HorizontalAlignment = Enum.HorizontalAlignment.Center,
                VerticalAlignment = Enum.VerticalAlignment.Center,
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, dockGap),
            }),
            create("UIPadding", {
                PaddingTop = UDim.new(0, dockPad),
                PaddingBottom = UDim.new(0, dockPad),
                PaddingLeft = UDim.new(0, dockPad),
                PaddingRight = UDim.new(0, dockPad),
            }),
        }
    })
    addCorner(togglePill, pillH / 2)
    addStroke(togglePill, theme.Border, 1, 0.4)

    local function dockTile(order, accent)
        return create("TextButton", {
            Size = UDim2.new(0, tileS, 0, tileS),
            BackgroundColor3 = accent and theme.Accent or theme.Surface,
            BackgroundTransparency = accent and 0.1 or 0.2,
            Text = "",
            BorderSizePixel = 0,
            AutoButtonColor = false,
            LayoutOrder = order,
            ZIndex = 101,
            Parent = togglePill
        })
    end

    local function tileIcon(parent, asset, fallbackText, color)
        if asset then
            return create("ImageLabel", {
                Size = UDim2.new(0, mobile and 20 or 16, 0, mobile and 20 or 16),
                Position = UDim2.new(0.5, -(mobile and 10 or 8), 0.5, -(mobile and 10 or 8)),
                BackgroundTransparency = 1,
                Image = asset,
                ImageColor3 = color or theme.Text,
                ScaleType = Enum.ScaleType.Fit,
                ZIndex = 102,
                Parent = parent
            })
        end
        return create("TextLabel", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = fallbackText,
            TextColor3 = color or theme.Text,
            TextSize = mobile and 16 or 13,
            Font = Enum.Font.GothamBold,
            ZIndex = 102,
            Parent = parent
        })
    end

    -- tile 1: open window
    local openTile = dockTile(1, true)
    addCorner(openTile, tileS / 2 - 3)
    tileIcon(openTile, resolvedToggleIcon, pillText, Color3.new(1, 1, 1))

    -- tile 2: panic (suspends / restores every toggle + active keybind)
    local panicTile = dockTile(2, false)
    addCorner(panicTile, 10)
    local panicIconAsset = EZ:ResolveIcon("zap-off")
    local panicIcon = tileIcon(panicTile, panicIconAsset, "!", theme.TextDim)
    EZ._panicTiles = EZ._panicTiles or {}
    -- filter out entries whose window died first, mirroring the corner
    -- registry prune, so destroyed windows cannot leave stale tiles behind
    for i = #EZ._panicTiles, 1, -1 do
        local t = EZ._panicTiles[i]
        if not t.frame or t.frame.Parent == nil then
            table.remove(EZ._panicTiles, i)
        end
    end
    table.insert(EZ._panicTiles, { frame = panicTile, icon = panicIcon })

    -- tile 3: floating keybind menu
    local bindsTile = dockTile(3, false)
    addCorner(bindsTile, 10)
    tileIcon(bindsTile, EZ:ResolveIcon("keyboard"), "K", theme.TextDim)

    -- pill drag (tiles handle their own clicks; the dock only moves)
    local pillDrag, pillDragStart, pillStartPos = false, nil, nil
    local pillMoved = false

    local function saveDockPos()
        pcall(function()
            if writefile then
                writefile(dockFile, ("pos=%d,%d"):format(
                    math.floor(togglePill.Position.X.Offset + 0.5),
                    math.floor(togglePill.Position.Y.Offset + 0.5)))
            end
        end)
    end

    trackConnection(togglePill.InputBegan, function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            pillDrag = true
            pillMoved = false
            pillDragStart = Vector2.new(inp.Position.X, inp.Position.Y)
            pillStartPos = togglePill.Position
        end
    end)
    trackConnection(UserInputService.InputChanged, function(inp)
        if not pillDrag then return end
        if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then
            local pos = Vector2.new(inp.Position.X, inp.Position.Y)
            local delta = pos - pillDragStart
            if delta.Magnitude > 5 then pillMoved = true end
            togglePill.Position = UDim2.new(pillStartPos.X.Scale, pillStartPos.X.Offset + delta.X, pillStartPos.Y.Scale, pillStartPos.Y.Offset + delta.Y)
        end
    end)
    trackConnection(UserInputService.InputEnded, function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if pillDrag and pillMoved then
                saveDockPos()
                dockHasCustomPos = true
            end
            pillDrag = false
        end
    end)

    local function tilePress(tile, fn)
        -- Single deterministic path: press + release on the tile itself
        -- (the same InputBegan/InputEnded pattern the old pill used and the
        -- one every executor handles reliably). No MouseButton1Click, so
        -- there is nothing to double-fire or get eaten.
        --
        -- The press position is recorded instead of killing the dock drag
        -- immediately: grabbing a tile must still move the dock. Only
        -- movement past QuickBar's 6px _dragMoved threshold turns the press
        -- into a drag.
        local pressPos = nil
        trackConnection(tile.InputBegan, function(inp)
            if inp.UserInputType == Enum.UserInputType.MouseButton1
                or inp.UserInputType == Enum.UserInputType.Touch then
                pressPos = Vector2.new(inp.Position.X, inp.Position.Y)
                pillMoved = false
            end
        end)
        trackConnection(tile.InputEnded, function(inp)
            if inp.UserInputType == Enum.UserInputType.MouseButton1
                or inp.UserInputType == Enum.UserInputType.Touch then
                local start = pressPos
                pressPos = nil
                if not start then return end

                local pos = Vector2.new(inp.Position.X, inp.Position.Y)
                if (pos - start).Magnitude > 6 then
                    -- dragged, not tapped; the dock's own InputEnded saves it
                    pillMoved = true
                    return
                end

                -- release must still land on the tile (+8px tolerance), or
                -- the pointer slid off and the tap is cancelled
                local p, sz = tile.AbsolutePosition, tile.AbsoluteSize
                if pos.X < p.X - 8 or pos.X > p.X + sz.X + 8
                    or pos.Y < p.Y - 8 or pos.Y > p.Y + sz.Y + 8 then
                    return
                end

                fn()
            end
        end)
    end
    tilePress(openTile, function() window:Show() end)
    tilePress(panicTile, function() EZ:TogglePanic() end)
    tilePress(bindsTile, function() EZ:ToggleKeybindMenu() end)

    -- hover glow on dock
    trackConnection(togglePill.MouseEnter, function()
        tween(togglePill, {BackgroundTransparency = 0}, 0.15)
    end)
    trackConnection(togglePill.MouseLeave, function()
        tween(togglePill, {BackgroundTransparency = 0.05}, 0.15)
    end)

    window._togglePill = togglePill

    -- show/hide (minimized/restorePosition/restoreSize are declared with
    -- saveGeometry above so the resize grip can keep restoreSize in sync)
    function window:Show()
        if self._destroyed then return end
        if self.Visible and not minimized then return end

        minimized = false
        self.Visible = true
        main.Visible = true
        togglePill.Visible = false

        -- Restore the exact position/size from before minimizing, re-clamped
        -- against the current viewport (the resolution may have changed or
        -- the saved position may predate it).
        local screen = getScreenSize()
        local sx = math.max(80, screen.X - 80)
        local sy = math.max(46, screen.Y - 46)
        restorePosition = UDim2.fromOffset(
            clamp(restorePosition.X.Offset, 0, sx),
            clamp(restorePosition.Y.Offset, 0, sy))
        main.Position = restorePosition
        main.Size = UDim2.new(0, math.max(1, restoreSize.X.Offset * 0.9), 0, math.max(1, restoreSize.Y.Offset * 0.9))
        main.BackgroundTransparency = 0.5

        tween(main, {
            Size = restoreSize,
            BackgroundTransparency = 0.02
        }, 0.3)
    end

    function window:Hide()
        if self._destroyed then return end
        if not self.Visible or minimized then return end

        minimized = true
        self.Visible = false
        closeActiveDropdown()
        closePopups()
        restorePosition = main.Position
        saveGeometry()
        -- Only trust the live size when no expand/collapse tween is running.
        -- Sampling mid-animation (hide pressed right after show) shrank the
        -- window ~10% every rapid hide/show cycle.
        if math.abs(main.Size.X.Offset - restoreSize.X.Offset) <= 1
            and math.abs(main.Size.Y.Offset - restoreSize.Y.Offset) <= 1 then
            restoreSize = main.Size
        end

        -- First-ever minimize only: park the pill at the window's center.
        -- Once the user has moved the dock anywhere themselves it stays
        -- exactly where they left it.
        if not dockHasCustomPos then
            local center = main.AbsolutePosition + (main.AbsoluteSize / 2)
            local screen = getScreenSize()
            local x = clamp(center.X - pillW / 2, 6, math.max(6, screen.X - pillW - 6))
            local y = clamp(center.Y - pillH / 2, 6, math.max(6, screen.Y - pillH - 6))
            togglePill.Position = UDim2.fromOffset(x, y)
        end

        tween(main, {
            Size = UDim2.new(0, math.max(1, restoreSize.X.Offset * 0.9), 0, math.max(1, restoreSize.Y.Offset * 0.9)),
            BackgroundTransparency = 0.6
        }, 0.2)

        task.delay(0.22, function()
            if not minimized or self.Visible or not main.Parent then return end
            main.Visible = false
            if not self._pillSuppressed then
                togglePill.Visible = true
                tween(togglePill, {BackgroundTransparency = 0.15}, 0.2)
            else
                togglePill.Visible = false
            end
        end)
    end

    function window:Toggle()
        if self._destroyed then return end
        if minimized or not self.Visible then
            self:Show()
        else
            self:Hide()
        end
    end

    function window:Destroy()
        if self._destroyed then return end
        self._destroyed = true
        self.Visible = false

        -- an open dropdown list lives in the root gui, so close it before
        -- the window (and its elements) go away
        pcall(closeActiveDropdown)

        -- Disconnect only this window's callbacks. This prevents dead windows
        -- from continuing to react to global UserInputService events.
        for _, connection in ipairs(self._connections or {}) do
            disconnectConnection(connection)
        end
        table.clear(self._connections or {})

        -- popups sit outside main, so they need destroying by hand
        for _, popup in self._popups do
            pcall(function() popup.frame:Destroy() end)
        end
        table.clear(self._popups)

        pcall(function() main:Destroy() end)
        pcall(function() togglePill:Destroy() end)

        for i = #EZ.Windows, 1, -1 do
            if EZ.Windows[i] == self then
                table.remove(EZ.Windows, i)
                break
            end
        end
    end
    window.ScreenGui = gui

    -- close / minimize
    trackConnection(windowCloseBtn.MouseButton1Click, function()
        -- default (back-compat): the X is a full nuke — window + watermark +
        -- toggle pill + listeners + all EZ state. Hosts that want the X to
        -- close just this window opt into CloseBehavior = "window".
        if opts.CloseBehavior == "window" then
            window:Destroy()
        else
            EZ:Destroy()
        end
    end)
    trackConnection(minBtn.MouseButton1Click, function()
        window:Hide()
    end)

    -- Delegate instead of aliasing: addons (QuickBar) replace Show/Hide on the
    -- window after this point, and a captured reference would skip their hook.
    function window:Minimize(...) return self:Hide(...) end
    function window:Restore(...) return self:Show(...) end

    -- ~~--------
    -- DIALOGS (confirm/prompt modals)
    --
    -- window:AddDialog(id, {
    --     Title = "Delete config",
    --     Description = "This cannot be undone.",
    --     AutoDismiss = false,          -- clicking the dimmer dismisses when true
    --     FooterButtons = {             -- array OR map; sorted by Order
    --         { Title = "Cancel", Variant = "Ghost", Order = 1 },
    --         { Title = "Delete", Variant = "Destructive", Order = 2,
    --           Callback = function(dialog) dialog:Dismiss() ... end },
    --     },
    -- })
    -- Returns a handle with :Dismiss().
    -- ~~--------
    function window:AddDialog(_id, opts)
        if self._destroyed then return nil end
        opts = opts or {}

        closeActiveDropdown()
        closePopups()

        local dismissed = false
        local overlay = create("Frame", {
            Name = "EZDialog",
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = Color3.new(0, 0, 0),
            BackgroundTransparency = 0.45,
            Visible = false,
            -- above the window chrome and watermark, below tooltips; the
            -- notification ScreenGui sits on its own DisplayOrder anyway
            ZIndex = 220,
            Parent = gui
        })

        local cardW = math.min(getScreenSize().X - 40, 320)
        local card = create("Frame", {
            Size = UDim2.new(0, cardW, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            Position = UDim2.new(0.5, -cardW / 2, 0.5, -70),
            BackgroundColor3 = theme.Base,
            ClipsDescendants = true,
            ZIndex = 151,
            Parent = overlay,
            Children = {
                create("UIListLayout", {
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    Padding = UDim.new(0, 8),
                }),
                create("UIPadding", {
                    PaddingTop = UDim.new(0, 14),
                    PaddingBottom = UDim.new(0, 12),
                    PaddingLeft = UDim.new(0, 14),
                    PaddingRight = UDim.new(0, 14),
                }),
            }
        })
        addCorner(card, 12)
        addStroke(card, theme.Border, 1, 0.3)

        create("TextLabel", {
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 18),
            BackgroundTransparency = 1,
            Text = tostring(opts.Title or ""),
            TextColor3 = theme.Text,
            TextSize = 14,
            Font = Enum.Font.GothamBold,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            ZIndex = 152,
            Parent = card
        })

        create("TextLabel", {
            LayoutOrder = 2,
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Text = tostring(opts.Description or ""),
            TextColor3 = theme.TextDim,
            TextSize = 12,
            Font = Enum.Font.Gotham,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            ZIndex = 152,
            Parent = card
        })

        local dialog = {}
        local popupEntry = { frame = overlay }

        local function removePopupEntry()
            for i, entry in window._popups do
                if entry == popupEntry then
                    table.remove(window._popups, i)
                    break
                end
            end
        end

        function dialog:Dismiss()
            if dismissed then return end
            dismissed = true
            removePopupEntry()
            tween(overlay, {BackgroundTransparency = 1}, 0.15)
            tween(card, {BackgroundTransparency = 1}, 0.15)
            task.delay(0.17, function()
                pcall(function() overlay:Destroy() end)
            end)
        end

        -- footer buttons; accept Obsidian's map form and a plain array
        local buttons = {}
        for _, btn in opts.FooterButtons or {} do
            table.insert(buttons, btn)
        end
        table.sort(buttons, function(a, b)
            return (tonumber(a.Order) or 99) < (tonumber(b.Order) or 99)
        end)

        local btnRow = create("Frame", {
            LayoutOrder = 3,
            Size = UDim2.new(1, 0, 0, 30),
            BackgroundTransparency = 1,
            ZIndex = 152,
            Parent = card,
            Children = {
                create("UIListLayout", {
                    FillDirection = Enum.FillDirection.Horizontal,
                    HorizontalAlignment = Enum.HorizontalAlignment.Right,
                    VerticalAlignment = Enum.VerticalAlignment.Center,
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    Padding = UDim.new(0, 6),
                }),
            }
        })

        for _, btn in buttons do
            local variant = string.lower(tostring(btn.Variant or "ghost"))
            local bg = theme.Surface
            if variant == "destructive" then bg = theme.Error
            elseif variant == "primary" then bg = theme.Accent end

            local b = create("TextButton", {
                LayoutOrder = tonumber(btn.Order) or 99,
                Size = UDim2.new(0, math.max(64, #tostring(btn.Title or "?") * 7 + 24), 0, 28),
                AutomaticSize = Enum.AutomaticSize.X,
                BackgroundColor3 = bg,
                BackgroundTransparency = variant == "ghost" and 0.3 or 0,
                Text = tostring(btn.Title or "?"),
                TextColor3 = variant == "ghost" and theme.Text or Color3.new(1, 1, 1),
                TextSize = 12,
                Font = Enum.Font.GothamMedium,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                ZIndex = 153,
                Parent = btnRow
            })
            addCorner(b, 6)

            trackConnection(b.MouseButton1Click, function()
                local cb = btn.Callback
                if type(cb) == "function" then
                    safecall(`Dialog:{opts.Title}`, cb, dialog)
                else
                    dialog:Dismiss()
                end
            end)
        end

        -- dimmer click behaviour: clicking outside the card dismisses unless
        -- the caller opted out via AutoDismiss = false
        trackConnection(overlay.InputBegan, function(inp)
            if inp.UserInputType ~= Enum.UserInputType.MouseButton1
                and inp.UserInputType ~= Enum.UserInputType.Touch then return end
            if opts.AutoDismiss ~= false then
                local pos = Vector2.new(inp.Position.X, inp.Position.Y)
                if not pointInside(card, pos) then
                    dialog:Dismiss()
                end
            end
        end)

        registerPopup(overlay, function() dialog:Dismiss() end)

        -- animate in
        overlay.Visible = true
        card.BackgroundTransparency = 1
        tween(card, {BackgroundTransparency = 0}, 0.18)
        overlay.BackgroundTransparency = 0.7
        tween(overlay, {BackgroundTransparency = 0.45}, 0.18)

        return dialog
    end

    -- ~~--------
    -- SETTINGS TAB (one-call management UI)
    --
    -- window:AddSettingsTab({
    --     Title = "Settings", Icon = "settings",
    --     Menu = true,       -- keybind menu / cursor / on-top / notif side /
    --                        -- DPI scale / corner radius / menu bind / unload
    --     Themes = true,     -- colour pickers, font, bg image, theme CRUD
    --     Configs = true,    -- SaveManager config manager (needs :Bind)
    --     Profiles = false,  -- opt-in; SaveManager profiles groupbox
    -- })
    --
    -- Builds the Obsidian-style groupbox layout from whatever addons
    -- registered themselves on :Bind(); missing addons skip their box.
    -- Returns the tab so hosts can extend.
    -- ~~--------
    function window:AddSettingsTab(tabOpts)
        if self._destroyed then return nil end
        tabOpts = tabOpts or {}

        local sm = EZ._saveManager
        local tm = EZ._themeManager
        local tab = self:AddTab(tabOpts.Title or "Settings", tabOpts.Icon or "settings")
        if tab._btn then tab._btn.LayoutOrder = 1e9 end

        buildSettingsContent(self, tab, tm, sm, tabOpts)

        return tab
    end

    -- toggle key (rebindable at runtime via the Settings > Menu bind)
    local toggleKey = opts.ToggleKey or Enum.KeyCode.RightShift
    function window:SetToggleKey(key)
        -- keyboard keys and mouse buttons both work as the menu hotkey
        if typeof(key) ~= "EnumItem" then return end
        if key.EnumType == Enum.KeyCode
            or (key.EnumType == Enum.UserInputType and tostring(key):find("MouseButton")) then
            toggleKey = key
        end
    end
    function window:GetToggleKey() return toggleKey end
    trackConnection(UserInputService.InputBegan, function(inp, gpe)
        if typeof(toggleKey) ~= "EnumItem" then return end
        local match
        if toggleKey.EnumType == Enum.UserInputType then
            match = (inp.UserInputType == toggleKey)
        else
            match = (inp.KeyCode == toggleKey)
        end
        if not match then return end
        if gpe then return end
        window:Toggle()
    end)

    -- open animation
    main.Size = UDim2.new(0, winW * 0.8, 0, winH * 0.8)
    main.BackgroundTransparency = 0.5
    tween(main, {
        Size = UDim2.new(0, winW, 0, winH),
        BackgroundTransparency = 0.02
    }, 0.35)

    -- ~~--------
    -- SIDEBAR COLLAPSE (mobile or opt-in)
    -- ~~--------
    local sidebarCollapsed = false
    local collapsedW = 0
    local expandedW = tabW

    local function applySidebar()
        local w = sidebarCollapsed and collapsedW or expandedW
        tween(sidebar, {Size = UDim2.new(0, w, 1, -48)}, 0.22)
        tween(contentArea, {
            Size = UDim2.new(1, -(w + 2), 1, -48),
            Position = UDim2.new(0, w + 2, 0, 48),
        }, 0.22)
    end

    function window:ToggleSidebar()
        if self._destroyed then return end
        sidebarCollapsed = not sidebarCollapsed
        applySidebar()
    end

    -- collapse toggle button in header (right side, before minimize)
    local collapseBtn = create("TextButton", {
        Size = UDim2.new(0, 24, 0, 24),
        Position = UDim2.new(1, -96, 0.5, -12),
        BackgroundColor3 = theme.Panel,
        BackgroundTransparency = 0.15,
        Text = "",
        BorderSizePixel = 0,
        ZIndex = 7,
        AutoButtonColor = false,
        Parent = header
    })
    create("ImageLabel", {
        Size = UDim2.new(0, 12, 0, 12),
        Position = UDim2.new(0.5, -6, 0.5, -6),
        BackgroundTransparency = 1,
        Image = "rbxassetid://97419752870313",
        ImageColor3 = theme.Text,
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 8,
        Parent = collapseBtn,
    })
    addCorner(collapseBtn, 8)
    addStroke(collapseBtn, theme.Border, 1, 0.35)
    collapseBtn.Visible = opts.SidebarToggle ~= false
    trackConnection(collapseBtn.MouseButton1Click, function()
        window:ToggleSidebar()
    end)
    trackConnection(collapseBtn.MouseEnter, function()
        tween(collapseBtn, {BackgroundColor3 = theme.Accent, BackgroundTransparency = 0}, 0.15)
    end)
    trackConnection(collapseBtn.MouseLeave, function()
        tween(collapseBtn, {BackgroundColor3 = theme.Panel, BackgroundTransparency = 0.15}, 0.15)
    end)

    -- ~~--------
    -- GESTURE: swipe to switch tabs on mobile
    -- ~~--------
    if mobile and opts.Gestures ~= false then
        local swipeStart
        trackConnection(contentArea.InputBegan, function(inp)
            if inp.UserInputType == Enum.UserInputType.Touch then
                swipeStart = Vector2.new(inp.Position.X, inp.Position.Y)
            end
        end)
        trackConnection(contentArea.InputEnded, function(inp)
            if inp.UserInputType ~= Enum.UserInputType.Touch or not swipeStart then return end
            local endP = Vector2.new(inp.Position.X, inp.Position.Y)
            local delta = endP - swipeStart
            swipeStart = nil
            if math.abs(delta.X) < 80 or math.abs(delta.Y) > 60 then return end
            -- find active idx
            local curIdx
            for i, t in window.Tabs do
                if t == window.ActiveTab then curIdx = i break end
            end
            if not curIdx then return end
            local newIdx
            if delta.X < 0 then
                newIdx = curIdx + 1
            else
                newIdx = curIdx - 1
            end
            if newIdx < 1 or newIdx > #window.Tabs then return end
            local nt = window.Tabs[newIdx]
            if nt and nt._activate then
                -- haptic
                if EZ.Haptic then EZ:Haptic("light") end
                -- call the activator directly; firesignal() is executor-only
                -- and swiping silently did nothing wherever it is missing
                nt._activate()
            end
        end)
    end

    -- ~~--------
    -- TAB
    -- ~~--------
    function window:AddTab(name, icon)
        local tabIdx = #self.Tabs + 1
        local tab = {
            Name = name,
            Sections = {},
            _elements = {},
        }

        -- resolve icon (can be lucide name, asset id, or url)
        local iconUrl = EZ:ResolveIcon(icon)

        -- tab button
        local tabBtn = create("TextButton", {
            Size = UDim2.new(1, 0, 0, mobile and 44 or 32),
            BackgroundColor3 = theme.Panel,
            BackgroundTransparency = 1,
            Text = "",
            BorderSizePixel = 0,
            AutoButtonColor = false,
            ZIndex = 6,
            Parent = tabList
        })
        addCorner(tabBtn, 6)

        -- icon (if provided)
        local iconImg
        local iconSize = mobile and 20 or 14
        local textOffset = 10
        if iconUrl and mobile then
            -- mobile: icon centered top, text below
            iconImg = create("ImageLabel", {
                Size = UDim2.new(0, iconSize, 0, iconSize),
                Position = UDim2.new(0.5, -iconSize/2, 0, 4),
                BackgroundTransparency = 1,
                Image = iconUrl,
                ImageColor3 = theme.TextDim,
                ScaleType = Enum.ScaleType.Fit,
                ZIndex = 7,
                Parent = tabBtn,
            })
        elseif iconUrl then
            -- pc: icon left, text right
            iconImg = create("ImageLabel", {
                Size = UDim2.new(0, iconSize, 0, iconSize),
                Position = UDim2.new(0, 8, 0.5, -iconSize/2),
                BackgroundTransparency = 1,
                Image = iconUrl,
                ImageColor3 = theme.TextDim,
                ScaleType = Enum.ScaleType.Fit,
                ZIndex = 7,
                Parent = tabBtn,
            })
            textOffset = 8 + iconSize + 6
        end

        local tabLabel = create("TextLabel", {
            Size = mobile and UDim2.new(1, 0, 0, 12) or UDim2.new(1, -(textOffset + 4), 1, 0),
            Position = mobile and UDim2.new(0, 0, 1, -15) or UDim2.new(0, textOffset, 0, 0),
            BackgroundTransparency = 1,
            Text = mobile and name:sub(1, 3) or name,
            TextColor3 = theme.TextDim,
            TextSize = mobile and 9 or 12,
            Font = Enum.Font.GothamMedium,
            TextXAlignment = mobile and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left,
            ZIndex = 7,
            Parent = tabBtn
        })

        -- active toggle badge, top-right corner of tab btn
        local badge = create("Frame", {
            AnchorPoint = Vector2.new(1, 0),
            Size = UDim2.new(0, 14, 0, 14),
            Position = UDim2.new(1, -(mobile and 4 or 6), 0, mobile and 3 or 4),
            BackgroundColor3 = theme.Accent,
            BorderSizePixel = 0,
            Visible = false,
            ZIndex = 8,
            Parent = tabBtn,
        })
        addCorner(badge, 7)
        local badgeLbl = create("TextLabel", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = "0",
            TextColor3 = Color3.new(1, 1, 1),
            TextSize = 9,
            Font = Enum.Font.GothamBold,
            ZIndex = 9,
            Parent = badge,
        })
        tab._badge = badge
        tab._badgeLbl = badgeLbl
        function tab:_refreshBadge()
            local n = 0
            for _, tg in self._toggles or {} do
                -- only count toggles whose row is currently visible (skip VisibleWhen=false)
                local visible = (not tg._frame) or tg._frame.Visible
                if visible and tg.Get and tg:Get() then n = n + 1 end
            end
            if n > 0 then
                badge.Visible = true
                -- compact: 1234 -> 1.2k, 12345 -> 12k, 1234567 -> 1.2m
                local txt
                if n < 1000 then
                    txt = tostring(n)
                elseif n < 10000 then
                    txt = string.format("%.1fk", n/1000):gsub("%.0k$", "k")
                elseif n < 1000000 then
                    txt = string.format("%dk", math.floor(n/1000))
                elseif n < 10000000 then
                    txt = string.format("%.1fm", n/1000000):gsub("%.0m$", "m")
                else
                    txt = string.format("%dm", math.floor(n/1000000))
                end
                badgeLbl.Text = txt
                -- grow width with text length so it morphs from circle to pill
                local len = #txt
                local w = (len <= 1) and 14 or (10 + len * 5)
                tween(badge, {Size = UDim2.new(0, w, 0, 14)}, 0.18, Enum.EasingStyle.Back)
            else
                badge.Visible = false
            end
        end

        -- content scroll for this tab
        local tabContent = create("ScrollingFrame", {
            -- inset from the right/bottom edges so the 2px scrollbar never
            -- draws across the window's rounded corner arcs (ClipsDescendants
            -- only clips rectangles, it cannot hide an arc overlap)
            Size = UDim2.new(1, -18, 1, -20),
            BackgroundTransparency = 1,
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = theme.Accent,
            ScrollBarImageTransparency = 0.5,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Visible = false,
            ZIndex = 4,
            Parent = contentArea,
            Children = {
                create("UIListLayout", {
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    Padding = UDim.new(0, 6),
                }),
                create("UIPadding", {
                    PaddingTop = UDim.new(0, 6),
                    PaddingBottom = UDim.new(0, 10),
                    PaddingLeft = UDim.new(0, 8),
                    PaddingRight = UDim.new(0, 8),
                })
            }
        })
        tab._content = tabContent
        tab._btn = tabBtn
        tab._label = tabLabel
        tab._icon = iconImg

        local function activate()
            -- deactivate all
            for _, t in self.Tabs do
                t._content.Visible = false
                tween(t._label, {TextColor3 = theme.TextDim}, 0.15)
                tween(t._btn, {BackgroundTransparency = 1}, 0.15)
                if t._icon then tween(t._icon, {ImageColor3 = theme.TextDim}, 0.15) end
            end
            -- activate this
            tabContent.Visible = true
            tween(tabLabel, {TextColor3 = theme.Text}, 0.15)
            -- filled highlight so the selected tab reads clearly (Obsidian-style)
            tween(tabBtn, {BackgroundTransparency = 0.7}, 0.15)
            if iconImg then tween(iconImg, {ImageColor3 = theme.Text}, 0.15) end

            -- Move indicator, centre aligned to whatever the tab btn actually
            -- has (icon-only, text-only, or both). Prefer the button's real
            -- position: index arithmetic drifts as soon as the tab list has
            -- enough tabs to scroll. AbsolutePosition is in screen pixels, so
            -- divide out the window's UIScale to get the local offset back.
            local btnH = mobile and 44 or 32
            local centerY
            if tabBtn.AbsoluteSize.Y > 0 and uiScale.Scale > 0 then
                centerY = (tabBtn.AbsolutePosition.Y - sidebar.AbsolutePosition.Y) / uiScale.Scale
                    + btnH / 2
            else
                -- layout has not run yet, fall back to the nominal slot
                local slot = btnH + 2 -- list padding
                local listTop = 8 -- tabList offset (6) + padTop (2)
                centerY = listTop + (tabIdx - 1) * slot + btnH / 2
            end
            local yPos = centerY - indicatorH / 2
            tween(tabIndicator, {Position = UDim2.new(0, 2, 0, yPos)}, 0.32, Enum.EasingStyle.Back)

            self.ActiveTab = tab
        end

        tab._activate = activate
        trackConnection(tabBtn.MouseButton1Click, activate)

        -- hover
        trackConnection(tabBtn.MouseEnter, function()
            if self.ActiveTab ~= tab then
                tween(tabBtn, {BackgroundTransparency = 0.9}, 0.1)
            end
        end)
        trackConnection(tabBtn.MouseLeave, function()
            if self.ActiveTab ~= tab then
                tween(tabBtn, {BackgroundTransparency = 1}, 0.1)
            end
        end)

        table.insert(self.Tabs, tab)

        -- first tab auto-activate. Re-check inside the defer: two tabs added
        -- in the same tick both pass the outer check, and without the guard
        -- whichever defer ran last would win instead of the first.
        if tabIdx == 1 or not self.ActiveTab then
            task.defer(function()
                if not self.ActiveTab then activate() end
            end)
        end

        -- ~~----
        -- SUB-TABS (horizontal pill row inside a tab)
        -- ~~----
        tab.SubTabs = {}
        tab._activeSub = nil

        function tab:AddSubTab(subName)
            -- lazy init the sub-tab row
            if not tab._subRow then
                tab._subRow = create("Frame", {
                    Size = UDim2.new(1, 0, 0, mobile and 34 or 28),
                    BackgroundTransparency = 1,
                    LayoutOrder = -1,
                    ZIndex = 5,
                    Parent = tabContent,
                })
                tab._subRow:SetAttribute("EZSubRow", true)
                create("UIListLayout", {
                    FillDirection = Enum.FillDirection.Horizontal,
                    Padding = UDim.new(0, 4),
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    Parent = tab._subRow,
                })
            end

            local subIdx = #tab.SubTabs + 1
            local sub = { Name = subName, _sections = {} }

            local subBtn = create("TextButton", {
                Size = UDim2.new(0, 0, 1, -4),
                AutomaticSize = Enum.AutomaticSize.X,
                BackgroundColor3 = theme.Surface,
                BackgroundTransparency = 0.6,
                Text = "",
                BorderSizePixel = 0,
                AutoButtonColor = false,
                ZIndex = 6,
                LayoutOrder = subIdx,
                Parent = tab._subRow,
            })
            addCorner(subBtn, 6)
            create("UIPadding", {
                PaddingLeft = UDim.new(0, 10),
                PaddingRight = UDim.new(0, 10),
                Parent = subBtn,
            })
            local subLbl = create("TextLabel", {
                Size = UDim2.new(0, 0, 1, 0),
                AutomaticSize = Enum.AutomaticSize.X,
                BackgroundTransparency = 1,
                Text = subName,
                TextColor3 = theme.TextDim,
                TextSize = 11,
                Font = Enum.Font.GothamMedium,
                ZIndex = 7,
                Parent = subBtn,
            })

            -- container for this sub-tab's sections
            local subContainer = create("Frame", {
                Size = UDim2.new(1, 0, 0, 0),
                BackgroundTransparency = 1,
                AutomaticSize = Enum.AutomaticSize.Y,
                Visible = false,
                LayoutOrder = subIdx + 100,
                ZIndex = 4,
                Parent = tabContent,
            })
            create("UIListLayout", {
                Padding = UDim.new(0, 6),
                SortOrder = Enum.SortOrder.LayoutOrder,
                Parent = subContainer,
            })
            subContainer:SetAttribute("EZSubContainer", true)
            sub._container = subContainer

            local function activateSub()
                for _, s in tab.SubTabs do
                    if s._container then s._container.Visible = false end
                    if s._btn then
                        tween(s._btn, {BackgroundTransparency = 0.6}, 0.15)
                        tween(s._lbl, {TextColor3 = theme.TextDim}, 0.15)
                    end
                end
                subContainer.Visible = true
                tween(subBtn, {BackgroundTransparency = 0.1}, 0.15)
                tween(subLbl, {TextColor3 = theme.Text}, 0.15)
                tab._activeSub = sub
            end

            sub._btn = subBtn
            sub._lbl = subLbl
            trackConnection(subBtn.MouseButton1Click, activateSub)

            -- sections inside a subtab: proxy to container
            function sub:AddSection(name)
                -- build it against the tab, then move it into this sub-tab
                local s = tab:AddSection(name)
                if s and s.Frame then
                    s.Frame.Parent = subContainer
                end
                return s
            end

            table.insert(tab.SubTabs, sub)
            if subIdx == 1 then task.defer(activateSub) end
            return sub
        end

        -- ~~----
        -- SECTION / GROUPBOX
        -- One builder backs both: AddSection flows full-width, groupboxes
        -- (Obsidian-style two-column tabs) place the same section inside a
        -- left/right column so boxes line up symmetrically.
        -- ~~----
        -- chromeless: bare container for composite elements (TabBox tabs) -
        -- same builders, no section chrome
        local function createSection(sectionName, parentFrame, opts2)
            opts2 = opts2 or {}
            local chromeless = opts2.chromeless == true
            local section = { Elements = {} }

            local sectionFrame = create("Frame", {
                Size = UDim2.new(1, 0, 0, 0),
                BackgroundColor3 = theme.Panel,
                BackgroundTransparency = chromeless and 1 or 0.4,
                AutomaticSize = Enum.AutomaticSize.Y,
                ClipsDescendants = not chromeless,
                ZIndex = 5,
                Parent = parentFrame
            })
            section.Frame = sectionFrame

            -- elements container
            local sectionHeaderH = (not chromeless and opts2.Description ~= nil) and 44 or 30
            local elemContainer = create("Frame", {
                Size = UDim2.new(1, 0, 0, 0),
                Position = chromeless and UDim2.new(0, 0, 0, 0) or UDim2.new(0, 0, 0, sectionHeaderH),
                BackgroundTransparency = 1,
                AutomaticSize = Enum.AutomaticSize.Y,
                ZIndex = 5,
                Parent = sectionFrame,
                Children = {
                    create("UIListLayout", {
                        SortOrder = Enum.SortOrder.LayoutOrder,
                        Padding = UDim.new(0, 4),
                    }),
                    create("UIPadding", {
                        PaddingTop = UDim.new(0, chromeless and 0 or 2),
                        PaddingBottom = UDim.new(0, chromeless and 0 or 8),
                        PaddingLeft = UDim.new(0, chromeless and 0 or 10),
                        PaddingRight = UDim.new(0, chromeless and 0 or 10),
                    })
                }
            })
            section._container = elemContainer

            if not chromeless then
                addCorner(sectionFrame, 10)
                addStroke(sectionFrame, theme.Border, 1, 0.55)

                -- section header
                local sectionHeader = create("TextButton", {
                    Size = UDim2.new(1, 0, 0, sectionHeaderH),
                    BackgroundTransparency = 1,
                    Text = "",
                    ZIndex = 6,
                    Parent = sectionFrame
                })
                section._header = sectionHeader

                -- optional header icon (groupboxes pass one; Obsidian-style)
                local headerIcon
                local labelX = 10
                if opts2.icon then
                    local iconAsset = EZ:ResolveIcon(opts2.icon)
                    if iconAsset then
                        headerIcon = create("ImageLabel", {
                            Size = UDim2.new(0, 14, 0, 14),
                            Position = UDim2.new(0, 10, 0.5, -7),
                            BackgroundTransparency = 1,
                            Image = iconAsset,
                            ImageColor3 = theme.Accent,
                            ScaleType = Enum.ScaleType.Fit,
                            ZIndex = 7,
                            Parent = sectionHeader,
                        })
                        labelX = 30
                    end
                end

                create("TextLabel", {
                    Size = UDim2.new(1, -(labelX + 20), 0, 30),
                    Position = UDim2.new(0, labelX, 0, 0),
                    BackgroundTransparency = 1,
                    Text = sectionName or "Section",
                    TextColor3 = theme.TextDim,
                    TextSize = 11,
                    Font = Enum.Font.GothamBold,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ZIndex = 7,
                    Parent = sectionHeader
                })

                -- muted description line under the title (opts2.Description)
                local descLabel
                if opts2.Description then
                    descLabel = create("TextLabel", {
                        Size = UDim2.new(1, -(labelX + 20), 0, 12),
                        Position = UDim2.new(0, labelX, 0, 30),
                        BackgroundTransparency = 1,
                        Text = tostring(opts2.Description),
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        TextColor3 = theme.TextMuted,
                        TextSize = 10,
                        Font = Enum.Font.Gotham,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        ZIndex = 7,
                        Parent = sectionHeader
                    })
                end

                -- v3.9: post-creation description + visibility (Obsidian parity)
                function section:SetDescription(desc)
                    if desc == nil then
                        if descLabel then descLabel.Visible = false end
                        sectionHeader.Size = UDim2.new(1, 0, 0, 30)
                        elemContainer.Position = UDim2.new(0, 0, 0, 30)
                        return self
                    end
                    if descLabel == nil then
                        descLabel = create("TextLabel", {
                            Size = UDim2.new(1, -(labelX + 20), 0, 12),
                            Position = UDim2.new(0, labelX, 0, 30),
                            BackgroundTransparency = 1,
                            Text = tostring(desc),
                            TextTruncate = Enum.TextTruncate.AtEnd,
                            TextColor3 = theme.TextMuted,
                            TextSize = 10,
                            Font = Enum.Font.Gotham,
                            TextXAlignment = Enum.TextXAlignment.Left,
                            ZIndex = 7,
                            Parent = sectionHeader
                        })
                        sectionHeader.Size = UDim2.new(1, 0, 0, 44)
                        elemContainer.Position = UDim2.new(0, 0, 0, 44)
                    else
                        descLabel.Visible = true
                        descLabel.Text = tostring(desc)
                    end
                    return self
                end
                function section:SetVisible(v)
                    sectionFrame.Visible = v == true
                    return self
                end
                function section:Show() return section:SetVisible(true) end
                function section:Hide() return section:SetVisible(false) end

                -- v4.2: pop-out — undock the section into a floating panel.
                -- Simplified vs Obsidian: the whole section floats (grip-drag,
                -- width/height overrides, screen clamp) without a separate
                -- scrolling body.
                local popOutFrame, popOutW, popOutH
                local poDrag, poStart, poOrigin
                local dockedParent = sectionFrame.Parent
                local dockedOrder = sectionFrame.LayoutOrder
                local function clampPopOutPos(pos)
                    local screen = getScreenSize()
                    local w = (popOutFrame and popOutFrame.AbsoluteSize.X) or (popOutW or 300)
                    local h = (popOutFrame and popOutFrame.AbsoluteSize.Y) or 200
                    return UDim2.new(
                        0, clamp(pos.X.Offset, 0, math.max(0, screen.X - w)),
                        0, clamp(pos.Y.Offset, 0, math.max(0, screen.Y - h))
                    )
                end
                local function setPoppedOut(on, floatPos)
                    on = on == true
                    if on and not popOutFrame then
                        popOutFrame = create("Frame", {
                            Name = "EZPopOut",
                            Size = UDim2.new(
                                0, popOutW or math.max(sectionFrame.AbsoluteSize.X, 280),
                                0, popOutH or math.max(sectionFrame.AbsoluteSize.Y, 180)
                            ),
                            Position = floatPos or UDim2.new(0, 80, 0, 80),
                            BackgroundColor3 = theme.Base,
                            BackgroundTransparency = 0.05,
                            BorderSizePixel = 0,
                            ZIndex = 200,
                            Parent = gui,
                        })
                        addCorner(popOutFrame, 10)
                        addStroke(popOutFrame, theme.Border, 1, 0.35)
                        sectionFrame.Parent = popOutFrame
                        sectionFrame.Size = UDim2.fromScale(1, 1)
                        sectionFrame.BackgroundTransparency = 0.35
                        sectionFrame.ZIndex = 201

                        local grip = create("TextButton", {
                            Name = "EZPopOutGrip",
                            Size = UDim2.new(0, 14, 0, 14),
                            Position = UDim2.new(1, -40, 0.5, -7),
                            BackgroundTransparency = 1,
                            Text = "⠿",
                            TextColor3 = theme.TextMuted,
                            TextSize = 12,
                            AutoButtonColor = false,
                            ZIndex = 202,
                            Parent = sectionHeader,
                        })
                        grip.InputBegan:Connect(function(inp)
                            if inp.UserInputType == Enum.UserInputType.MouseButton1
                                or inp.UserInputType == Enum.UserInputType.Touch then
                                poDrag = true
                                poStart = Vector2.new(inp.Position.X, inp.Position.Y)
                                poOrigin = popOutFrame.Position
                            end
                        end)
                        if floatPos then
                            popOutFrame.Position = clampPopOutPos(floatPos)
                        end
                    elseif not on and popOutFrame then
                        local grip = sectionHeader:FindFirstChild("EZPopOutGrip")
                        if grip then grip:Destroy() end
                        sectionFrame.Parent = dockedParent
                        sectionFrame.Size = UDim2.new(1, 0, 0, 0)
                        sectionFrame.LayoutOrder = dockedOrder
                        sectionFrame.BackgroundTransparency = 0.4
                        sectionFrame.ZIndex = 5
                        popOutFrame:Destroy()
                        popOutFrame = nil
                    end
                    section._poppedOut = on
                    return section
                end
                function section:SetPoppedOut(on, floatPos) return setPoppedOut(on, floatPos) end
                function section:TogglePoppedOut() return setPoppedOut(popOutFrame == nil) end
                function section:IsPoppedOut() return popOutFrame ~= nil end
                function section:SetMaxPopOutHeight(h)
                    popOutH = tonumber(h)
                    if popOutFrame and popOutH then
                        popOutFrame.Size = UDim2.new(popOutFrame.Size.X.Scale, popOutFrame.Size.X.Offset, 0, popOutH)
                        sectionFrame.ClipsDescendants = true
                    end
                    return section
                end
                function section:SetPopOutWidth(w)
                    popOutW = tonumber(w)
                    if popOutFrame and popOutW then
                        popOutFrame.Size = UDim2.new(0, popOutW, popOutFrame.Size.Y.Scale, popOutFrame.Size.Y.Offset)
                    end
                    return section
                end
                trackConnection(UserInputService.InputChanged, function(inp)
                    if not poDrag or not popOutFrame then return end
                    if inp.UserInputType ~= Enum.UserInputType.MouseMovement
                        and inp.UserInputType ~= Enum.UserInputType.Touch then return end
                    local dx = inp.Position.X - poStart.X
                    local dy = inp.Position.Y - poStart.Y
                    popOutFrame.Position = clampPopOutPos(UDim2.new(0, poOrigin.X.Offset + dx, 0, poOrigin.Y.Offset + dy))
                end)
                trackConnection(UserInputService.InputEnded, function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1
                        or inp.UserInputType == Enum.UserInputType.Touch then
                        poDrag = false
                    end
                end)
                section._dockedParent = sectionFrame.Parent
                section._dockedOrder = sectionFrame.LayoutOrder

                -- arrow (chevron icon when an icon pack is bound, "v" fallback)
                local chevron = EZ:ResolveIcon("chevron-down")
                local arrow
                if chevron then
                    arrow = create("ImageLabel", {
                        Size = UDim2.new(0, 14, 0, 14),
                        Position = UDim2.new(1, -22, 0.5, -7),
                        BackgroundTransparency = 1,
                        Image = chevron,
                        ImageColor3 = theme.TextMuted,
                        ScaleType = Enum.ScaleType.Fit,
                        ZIndex = 7,
                        Parent = sectionHeader
                    })
                else
                    arrow = create("TextLabel", {
                        Size = UDim2.new(0, 20, 1, 0),
                        Position = UDim2.new(1, -24, 0, 0),
                        BackgroundTransparency = 1,
                        Text = "v",
                        TextColor3 = theme.TextMuted,
                        TextSize = 10,
                        Font = Enum.Font.GothamBold,
                        ZIndex = 7,
                        Parent = sectionHeader
                    })
                end

                local collapsed = false
                trackConnection(sectionHeader.MouseButton1Click, function()
                    collapsed = not collapsed
                    tween(arrow, {Rotation = collapsed and -90 or 0}, 0.2)
                    elemContainer.Visible = not collapsed
                end)
            end

            -- ===
            -- TOGGLE
            -- ===
            function section:AddToggle(id, opts)
                opts = opts or {}
                local value = opts.Default or false
                local cb = opts.Callback or function() end
                -- v3.9: checkbox visual variant (same handle, square + check)
                local checkboxStyle = opts.CheckboxStyle == true or EZ.ForceCheckbox == true

                local hasDesc = opts.Description ~= nil
                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, (mobile and 38 or 32) + (hasDesc and 13 or 0)),
                    BackgroundTransparency = 1,
                    ZIndex = 6,
                    Parent = elemContainer
                })

                local label = create("TextLabel", {
                    Size = UDim2.new(1, -56, 0, hasDesc and 16 or (mobile and 38 or 32)),
                    BackgroundTransparency = 1,
                    Text = opts.Text or id,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    TextColor3 = theme.Text,
                    TextSize = 12,
                    Font = Enum.Font.Gotham,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ZIndex = 7,
                    Parent = elem
                })

                -- muted second line under the label (opts.Description)
                if hasDesc then
                    create("TextLabel", {
                        Size = UDim2.new(1, -56, 0, 11),
                        Position = UDim2.new(0, 0, 0, 17),
                        BackgroundTransparency = 1,
                        Text = tostring(opts.Description),
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        TextColor3 = theme.TextDim,
                        TextSize = 10,
                        Font = Enum.Font.Gotham,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        ZIndex = 7,
                        Parent = elem
                    })
                end

                -- toggle visuals: pill track + thumb, or square + check mark
                local track, thumb, checkIcon, checkText
                if checkboxStyle then
                    track = create("Frame", {
                        Size = UDim2.new(0, 20, 0, 20),
                        Position = UDim2.new(1, -30, 0.5, -10),
                        BackgroundColor3 = theme.Surface,
                        BorderSizePixel = 0,
                        ZIndex = 7,
                        Parent = elem
                    })
                    addCorner(track, 4)
                    addStroke(track, theme.Border, 1, 0.5)
                    local iconAsset = (EZ.ResolveIcon ~= nil) and EZ:ResolveIcon("check")
                    if iconAsset then
                        checkIcon = create("ImageLabel", {
                            Size = UDim2.new(1, -6, 1, -6),
                            Position = UDim2.new(0, 3, 0, 3),
                            BackgroundTransparency = 1,
                            Image = iconAsset,
                            ImageColor3 = Color3.new(1, 1, 1),
                            ScaleType = Enum.ScaleType.Fit,
                            ImageTransparency = 1,
                            ZIndex = 8,
                            Parent = track
                        })
                    else
                        checkText = create("TextLabel", {
                            Size = UDim2.new(1, 0, 1, 0),
                            BackgroundTransparency = 1,
                            Text = "✓",
                            TextColor3 = Color3.new(1, 1, 1),
                            TextSize = 13,
                            Font = Enum.Font.GothamBold,
                            TextTransparency = 1,
                            ZIndex = 8,
                            Parent = track
                        })
                    end
                else
                    track = create("Frame", {
                        Size = UDim2.new(0, 40, 0, 20),
                        Position = UDim2.new(1, -44, 0.5, -10),
                        BackgroundColor3 = theme.Surface,
                        BorderSizePixel = 0,
                        ZIndex = 7,
                        Parent = elem
                    })
                    addCorner(track, 10)
                    addStroke(track, theme.Border, 1, 0.5)
                    thumb = create("Frame", {
                        Size = UDim2.new(0, 16, 0, 16),
                        Position = UDim2.new(0, 2, 0.5, -8),
                        BackgroundColor3 = theme.TextDim,
                        BorderSizePixel = 0,
                        ZIndex = 8,
                        Parent = track
                    })
                    addCorner(thumb, 8)
                end

                local toggle -- declared early so update() can sync .Value
                local function update(v, silent)
                    value = v
                    if toggle then toggle.Value = v end
                    if checkboxStyle then
                        tween(track, {BackgroundColor3 = v and theme.Accent or theme.Surface}, 0.2)
                        if checkIcon then
                            tween(checkIcon, {ImageTransparency = v and 0 or 1}, 0.15)
                        end
                        if checkText then
                            tween(checkText, {TextTransparency = v and 0 or 1}, 0.15)
                        end
                    elseif v then
                        tween(thumb, {Position = UDim2.new(0, 22, 0.5, -8), BackgroundColor3 = Color3.new(1,1,1)}, 0.28, Enum.EasingStyle.Back)
                        tween(track, {BackgroundColor3 = theme.Accent}, 0.2)
                    else
                        tween(thumb, {Position = UDim2.new(0, 2, 0.5, -8), BackgroundColor3 = theme.TextDim}, 0.22)
                        tween(track, {BackgroundColor3 = theme.Surface}, 0.2)
                    end
                    EZ.Flags[id] = v
                    fireListeners(id, v)
                    if not silent then safecall(`Toggle:{id}`, cb, v) end
                end

                -- click zone
                local clickBtn = create("TextButton", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundTransparency = 1,
                    Text = "",
                    ZIndex = 9,
                    Parent = elem
                })
                trackConnection(clickBtn.MouseButton1Click, function()
                    if isElementDisabled(elem) then return end
                    update(not value)
                end)

                update(value, true)

                toggle = { Value = value, _frame = elem, _type = "Toggle" }
                function toggle:Set(v) update(v) end
                function toggle:Get() return value end
                function toggle:SetText(t)
                    label.Text = t or id
                    tagSearch(elem, t or id)
                    return self
                end
                attachOnChanged(toggle, id)
                setupVisibility(toggle, elem, opts)
                setupTooltip(elem, opts)
                tagSearch(elem, opts.Text or id)
                finishElement(toggle, elem, id, section)

                registerElement(id, toggle)
                table.insert(section.Elements, toggle)
                -- track for tab badge count
                tab._toggles = tab._toggles or {}
                table.insert(tab._toggles, toggle)
                -- if this toggle has VisibleWhen, refresh badge when its visibility flips
                if opts.VisibleWhen then
                    EZ:OnFlagChanged(opts.VisibleWhen, function()
                        if tab._refreshBadge then tab:_refreshBadge() end
                    end)
                end
                EZ:OnFlagChanged(id, function() if tab._refreshBadge then tab:_refreshBadge() end end)
                if tab._refreshBadge then tab:_refreshBadge() end
                return toggle
            end

            -- v3.9: checkbox visual variant — square + check mark instead of
            -- the pill switch. Also enabled globally with EZ.ForceCheckbox.
            function section:AddCheckbox(id, opts)
                opts = opts or {}
                opts.CheckboxStyle = true
                return section:AddToggle(id, opts)
            end

            -- ===
            -- SLIDER
            -- ===
            function section:AddSlider(id, opts)
                opts = opts or {}
                local min = tonumber(opts.Min) or 0
                local max = tonumber(opts.Max) or 100
                if max < min then min, max = max, min end
                local inc = math.abs(tonumber(opts.Increment) or 1)
                if inc == 0 then inc = 1 end
                local suffix = opts.Suffix or ""
                local prefix = opts.Prefix or ""
                -- smallest decimal count that represents the increment, so a
                -- 0.05 step shows "1.25" instead of fp noise like
                -- "1.2500000000000002" from round(v, inc)
                local incDecimals = 6
                do
                    for d = 0, 6 do
                        local scaled = inc * 10 ^ d
                        if math.abs(scaled - math.floor(scaled + 0.5)) < 1e-6 then
                            incDecimals = d
                            break
                        end
                    end
                end
                local function fmtVal(x)
                    return string.format("%." .. incDecimals .. "f", x)
                end
                -- NaN survives `or` (it is truthy), so guard it explicitly
                -- or a NaN Default would clamp straight to Max
                local d = tonumber(opts.Default)
                local value = clamp((d == d and d) or min, min, max)
                local cb = opts.Callback or function() end

                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, mobile and 48 or 42),
                    BackgroundTransparency = 1,
                    ZIndex = 6,
                    Parent = elemContainer
                })

                local label = create("TextLabel", {
                    Size = UDim2.new(0.6, 0, 0, 16),
                    BackgroundTransparency = 1,
                    Text = opts.Text or id,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    TextColor3 = theme.Text,
                    TextSize = 12,
                    Font = Enum.Font.Gotham,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ZIndex = 7,
                    Parent = elem
                })

                -- value label doubles as a click-to-edit button (typed exact
                -- values commit through the same clamp/snap as dragging)
                local valLabel = create("TextButton", {
                    Name = "EZSliderValue",
                    Size = UDim2.new(0.4, 0, 0, 16),
                    Position = UDim2.new(0.6, 0, 0, 0),
                    BackgroundTransparency = 1,
                    Text = fmtVal(value) .. suffix,
                    TextColor3 = theme.Accent,
                    TextSize = 12,
                    Font = Enum.Font.GothamBold,
                    TextXAlignment = Enum.TextXAlignment.Right,
                    AutoButtonColor = false,
                    BorderSizePixel = 0,
                    ZIndex = 7,
                    Parent = elem
                })

                -- track
                local sliderTrack = create("Frame", {
                    Size = UDim2.new(1, 0, 0, 6),
                    Position = UDim2.new(0, 0, 0, mobile and 28 or 24),
                    BackgroundColor3 = theme.Surface,
                    BorderSizePixel = 0,
                    ZIndex = 7,
                    Parent = elem
                })
                addCorner(sliderTrack, 3)

                -- fill
                local fill = create("Frame", {
                    Size = UDim2.new(0, 0, 1, 0),
                    BackgroundColor3 = theme.Accent,
                    BorderSizePixel = 0,
                    ZIndex = 8,
                    Parent = sliderTrack
                })
                addCorner(fill, 3)

                -- thumb circle, hosted in an inset rail so it can never
                -- poke past either end of the track (it used to stick out
                -- half-clipped at 0% and 100%)
                local sliderRail = create("Frame", {
                    Size = UDim2.new(1, -14, 1, 0),
                    Position = UDim2.new(0, 7, 0, 0),
                    BackgroundTransparency = 1,
                    ZIndex = 9,
                    Parent = sliderTrack
                })
                local sliderThumb = create("Frame", {
                    Size = UDim2.new(0, 14, 0, 14),
                    Position = UDim2.new(0, 0, 0.5, -7),
                    BackgroundColor3 = Color3.new(1,1,1),
                    BorderSizePixel = 0,
                    ZIndex = 9,
                    Parent = sliderRail
                })
                addCorner(sliderThumb, 7)

                local slider -- declared early so update() can sync .Value
                local function update(v, silent)
                    v = round(clamp(v, min, max), inc)
                    value = v
                    if slider then slider.Value = v end
                    local range = max - min
                    local pct = range > 0 and ((v - min) / range) or 0
                    fill.Size = UDim2.new(pct, 0, 1, 0)
                    sliderThumb.Position = UDim2.new(pct, -7, 0.5, -7)
                    valLabel.Text = prefix .. fmtVal(v) .. suffix
                    EZ.Flags[id] = v
                    fireListeners(id, v)
                    if not silent then safecall(`Slider:{id}`, cb, v) end
                end

                -- interaction
                local sliding = false

                -- click the value label to type an exact value; Enter or
                -- clicking away commits through update() (clamp + snap +
                -- callback), unparseable input just restores the label
                local editing = false
                trackConnection(valLabel.MouseButton1Click, function()
                    if editing or sliding or isElementDisabled(elem) then return end
                    editing = true
                    local box = create("TextBox", {
                        Name = "EZSliderEdit",
                        Size = valLabel.Size,
                        Position = valLabel.Position,
                        BackgroundTransparency = 1,
                        Text = fmtVal(value),
                        PlaceholderText = ("%g-%g"):format(min, max),
                        TextColor3 = theme.Accent,
                        PlaceholderColor3 = theme.TextMuted,
                        TextSize = 12,
                        Font = Enum.Font.GothamBold,
                        TextXAlignment = Enum.TextXAlignment.Right,
                        ClearTextOnFocus = false,
                        ZIndex = 11,
                        Parent = elem
                    })
                    box:CaptureFocus()
                    local done = false
                    local armed = false
                    local function commit()
                        if done or not armed then return end
                        done = true
                        editing = false
                        local n = tonumber(box.Text)
                        box:Destroy()
                        if n then
                            update(n)
                        else
                            valLabel.Text = prefix .. fmtVal(value) .. suffix
                        end
                    end
                    -- the opening click steals focus for a beat; arm the
                    -- commit listener a frame later so the editor isn't
                    -- killed by its own opening click
                    task.defer(function()
                        if done or not box.Parent then return end
                        armed = true
                        box:CaptureFocus()
                    end)
                    trackConnection(box.FocusLost, commit)
                    box.Destroying:Connect(function()
                        done, editing = true, false
                    end)
                end)

                -- interaction (sliding declared before the editor above so
                -- the editor's click guard reads the real upvalue)
                local clickArea = create("TextButton", {
                    Size = UDim2.new(1, 0, 0, 20),
                    Position = UDim2.new(0, 0, 0, mobile and 20 or 16),
                    BackgroundTransparency = 1,
                    Text = "",
                    ZIndex = 10,
                    Parent = elem
                })

                trackConnection(clickArea.InputBegan, function(inp)
                    if isElementDisabled(elem) then return end
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                        if EZ._activeDrag and EZ._activeDrag ~= "slider" then return end
                        sliding = true
                        EZ._activeDrag = "slider"
                        -- Jump straight to the clicked position. A plain click
                        -- used to only arm dragging, so the thumb refused to
                        -- move until the pointer moved again.
                        local absPos = sliderTrack.AbsolutePosition.X
                        local absSize = sliderTrack.AbsoluteSize.X
                        if absSize > 0 then
                            local rel = clamp((inp.Position.X - absPos) / absSize, 0, 1)
                            update(min + (max - min) * rel)
                        end
                    end
                end)

                trackConnection(UserInputService.InputChanged, function(inp)
                    if not sliding then return end
                    if EZ._activeDrag ~= "slider" then return end
                    if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then
                        local absPos = sliderTrack.AbsolutePosition.X
                        local absSize = sliderTrack.AbsoluteSize.X
                        if absSize <= 0 then return end
                        local rel = clamp((inp.Position.X - absPos) / absSize, 0, 1)
                        update(min + (max - min) * rel)
                    end
                end)

                trackConnection(UserInputService.InputEnded, function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                        if sliding then
                            sliding = false
                            if EZ._activeDrag == "slider" then EZ._activeDrag = nil end
                        end
                    end
                end)

                update(value, true)

                slider = { Value = value, _type = "Slider" }
                function slider:Set(v) update(v) end
                function slider:Get() return value end
                function slider:SetText(t)
                    label.Text = t or id
                    tagSearch(elem, t or id)
                    return self
                end
                function slider:SetPrefix(p)
                    prefix = tostring(p or "")
                    update(value, true)
                    return self
                end
                function slider:SetMin(v)
                    min = tonumber(v) or min
                    if max < min then min, max = max, min end
                    update(value, true)
                    return self
                end
                function slider:SetMax(v)
                    max = tonumber(v) or max
                    if max < min then min, max = max, min end
                    update(value, true)
                    return self
                end
                attachOnChanged(slider, id)
                setupVisibility(slider, elem, opts)
                setupTooltip(elem, opts)
                tagSearch(elem, opts.Text or id)
                finishElement(slider, elem, id, section)

                registerElement(id, slider)
                table.insert(section.Elements, slider)
                return slider
            end

            -- ===
            -- BUTTON
            -- ===
            function section:AddButton(opts)
                opts = opts or {}
                local cb = opts.Callback or function() end

                local btn = create("TextButton", {
                    Size = UDim2.new(1, 0, 0, mobile and 38 or 32),
                    BackgroundColor3 = theme.Surface,
                    BackgroundTransparency = 0.3,
                    Text = "",
                    BorderSizePixel = 0,
                    AutoButtonColor = false,
                    ZIndex = 6,
                    Parent = elemContainer
                })
                addCorner(btn, 7)
                local btnStroke = addStroke(btn, theme.Border, 1, 0.55)

                create("TextLabel", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundTransparency = 1,
                    Text = opts.Text or "Button",
                    TextColor3 = theme.Text,
                    TextSize = 12,
                    Font = Enum.Font.GothamMedium,
                    ZIndex = 7,
                    Parent = btn
                })

                trackConnection(btn.MouseEnter, function()
                    if isElementDisabled(btn) then return end
                    tween(btn, {BackgroundTransparency = 0.08}, 0.15)
                    tween(btnStroke, {Color = theme.Accent, Transparency = 0.4}, 0.15)
                end)
                trackConnection(btn.MouseLeave, function()
                    tween(btn, {BackgroundTransparency = 0.3}, 0.15)
                    tween(btnStroke, {Color = theme.Border, Transparency = 0.55}, 0.15)
                end)
                trackConnection(btn.MouseButton1Click, function()
                    if isElementDisabled(btn) then return end
                    -- press flash + tiny scale pulse for haptic feel
                    tween(btn, {BackgroundColor3 = theme.Accent}, 0.08)
                    task.delay(0.12, function()
                        tween(btn, {BackgroundColor3 = theme.Surface}, 0.18)
                    end)
                    safecall(`Button:{opts.Text or "?"}`, cb)
                end)

                -- Buttons accept the same options as every other element, so
                -- wire up the shared behaviour. VisibleWhen and Tooltip were
                -- silently ignored here, and untagged buttons stayed on screen
                -- while the rest of their section was filtered away.
                setupVisibility(btn, btn, opts)
                setupTooltip(btn, opts)
                tagSearch(btn, opts.Text or "Button")

                table.insert(section.Elements, btn)
                return btn
            end

            -- ===
            -- DROPDOWN
            -- ===
            function section:AddDropdown(id, opts)
                opts = opts or {}
                local multi = opts.Multi or false
                local cb = opts.Callback or function() end
                local searchable = opts.Searchable == true

                -- Values accept an array {"A","B"} OR a dictionary
                -- {Key1 = "Display 1"} where the KEY is stored in the flag and
                -- the value is what renders. Disabled options are dimmed and
                -- unclickable: opts.Disabled = {["B"] = true} or {"B"}.
                local values, displayOf, disabledOf = {}, {}, {}
                local disabledSpec = opts.Disabled
                -- v3.9: value images (icons per option), drag multi-select,
                -- and empty selection for single dropdowns
                local imageOf = {}
                local dragSelectEnabled = false
                local dragSelecting = false
                local allowEmpty = opts.AllowEmptySelection == true
                -- shared Disabled parser: map form {B = true} or array {"B"}
                local function applyDisabled(d, into)
                    if typeof(d) ~= "table" then return end
                    for k, v in d do
                        if type(k) == "string" and v == true then into[k] = true
                        elseif v == true or v == nil then into[k] = true end
                    end
                    for _, v in d do
                        if type(v) ~= "boolean" then into[v] = true end
                    end
                end
                do
                    local src = opts.Values or {}
                    local isDict = false
                    for k in src do
                        if type(k) == "string" then isDict = true break end
                    end
                    if isDict then
                        for k, disp in src do
                            table.insert(values, k)
                            displayOf[k] = tostring(disp)
                        end
                        table.sort(values, function(a, b) return tostring(a) < tostring(b) end)
                    else
                        for _, v in src do table.insert(values, v) end
                    end
                    applyDisabled(disabledSpec, disabledOf)
                end

                local function displayOfVal(v)
                    return displayOf[v] or tostring(v)
                end

                -- multi selections are stored as a {key = true} map. Accept a
                -- map, an array of keys, or a bare scalar so :Set can never
                -- hand getDisplayText a string to iterate (it used to crash
                -- with "attempt to iterate over a string value").
                local function normalizeSelection(input)
                    if not multi then return input end
                    local map = {}
                    if type(input) ~= "table" then
                        if input ~= nil then map[input] = true end
                        return map
                    end
                    for k, v in input do
                        if type(k) == "number" then
                            if v ~= nil then map[v] = true end
                        elseif v == true then
                            map[k] = true
                        end
                    end
                    return map
                end

                local selected
                do
                    local def = opts.Default
                    if type(def) == "number" then def = values[def] end -- index form
                    if multi then
                        selected = normalizeSelection(def)
                    else
                        selected = def or (values[1] or "")
                    end
                end

                local hasTitle = opts.Text ~= nil
                local headerY = hasTitle and 16 or 0
                local elemH = (mobile and 38 or 32) + headerY

                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, elemH),
                    BackgroundTransparency = 1,
                    AutomaticSize = Enum.AutomaticSize.Y,
                    ZIndex = 6,
                    ClipsDescendants = false,
                    Parent = elemContainer
                })

                local header = create("TextButton", {
                    Size = UDim2.new(1, 0, 0, mobile and 38 or 32),
                    Position = UDim2.new(0, 0, 0, headerY),
                    BackgroundColor3 = theme.Surface,
                    BackgroundTransparency = 0.3,
                    Text = "",
                    BorderSizePixel = 0,
                    AutoButtonColor = false,
                    ZIndex = 7,
                    Parent = elem
                })
                addCorner(header, 6)
                addStroke(header, theme.Border, 1, 0.6)

                local function getDisplayText()
                    if multi then
                        local items = {}
                        for k, v in selected do
                            if v then table.insert(items, displayOfVal(k)) end
                        end
                        table.sort(items) -- deterministic label order
                        if #items == 0 then return opts.Text or "Select..." end
                        -- long selections collapse to "A, B +N more" so the
                        -- header stays readable
                        if #items > 2 then
                            return ("%s, %s +%d more"):format(items[1], items[2], #items - 2)
                        end
                        return table.concat(items, ", ")
                    else
                        return displayOfVal(selected)
                    end
                end

                local headerLabel = create("TextLabel", {
                    Size = UDim2.new(1, -30, 1, 0),
                    Position = UDim2.new(0, 10, 0, 0),
                    BackgroundTransparency = 1,
                    Text = getDisplayText(),
                    TextColor3 = theme.Text,
                    TextSize = 12,
                    Font = Enum.Font.Gotham,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    ZIndex = 8,
                    Parent = header
                })

                local titleLabel
                if hasTitle then
                    titleLabel = create("TextLabel", {
                        Size = UDim2.new(1, 0, 0, 14),
                        Position = UDim2.new(0, 0, 0, 0),
                        BackgroundTransparency = 1,
                        Text = opts.Text,
                        TextColor3 = theme.TextDim,
                        TextSize = 10,
                        Font = Enum.Font.GothamMedium,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        ZIndex = 7,
                        Parent = elem
                    })
                end

                -- chevron icon when an icon pack is bound, "v" text fallback
                local dropChevron = EZ:ResolveIcon("chevron-down")
                local dropArrow
                if dropChevron then
                    dropArrow = create("ImageLabel", {
                        Size = UDim2.new(0, 16, 0, 16),
                        -- parented to the header button, so no title offset here
                        Position = UDim2.new(1, -22, 0.5, -8),
                        BackgroundTransparency = 1,
                        Image = dropChevron,
                        ImageColor3 = theme.TextMuted,
                        ScaleType = Enum.ScaleType.Fit,
                        ZIndex = 8,
                        Parent = header
                    })
                else
                    dropArrow = create("TextLabel", {
                        Size = UDim2.new(0, 20, 1, 0),
                        Position = UDim2.new(1, -24, 0, 0),
                        BackgroundTransparency = 1,
                        Text = "v",
                        TextColor3 = theme.TextMuted,
                        TextSize = 10,
                        Font = Enum.Font.GothamBold,
                        ZIndex = 8,
                        Parent = header
                    })
                end

                -- dropdown list
                local dropFrame = create("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    Position = UDim2.new(0, 0, 0, headerY + (mobile and 42 or 36)),
                    BackgroundColor3 = theme.Surface,
                    BackgroundTransparency = 0.05,
                    ClipsDescendants = true,
                    Visible = false,
                    ZIndex = 90,
                    Parent = elem
                })
                addCorner(dropFrame, 6)
                addStroke(dropFrame, theme.Border, 1, 0.4)

                -- search box (Searchable = true) sits above the option list
                local searchTerm = ""
                local searchBox
                local listTop = 0
                if searchable then
                    listTop = 30
                    searchBox = create("TextBox", {
                        Size = UDim2.new(1, -8, 0, 24),
                        Position = UDim2.new(0, 4, 0, 3),
                        BackgroundColor3 = theme.Panel,
                        BackgroundTransparency = 0.2,
                        Text = "",
                        PlaceholderText = "Search...",
                        TextColor3 = theme.Text,
                        PlaceholderColor3 = theme.TextMuted,
                        TextSize = 12,
                        Font = Enum.Font.Gotham,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        ClearTextOnFocus = false,
                        ZIndex = 22,
                        Parent = dropFrame,
                    })
                    addCorner(searchBox, 4)
                    create("UIPadding", {
                        PaddingLeft = UDim.new(0, 8),
                        PaddingRight = UDim.new(0, 8),
                        Parent = searchBox,
                    })
                end

                local dropList = create("ScrollingFrame", {
                    Size = UDim2.new(1, 0, 1, -listTop),
                    Position = UDim2.new(0, 0, 0, listTop),
                    BackgroundTransparency = 1,
                    ScrollBarThickness = 2,
                    ScrollBarImageColor3 = theme.Accent,
                    CanvasSize = UDim2.new(0, 0, 0, 0),
                    AutomaticCanvasSize = Enum.AutomaticSize.Y,
                    ZIndex = 21,
                    Parent = dropFrame,
                    Children = {
                        create("UIListLayout", {
                            SortOrder = Enum.SortOrder.LayoutOrder,
                            Padding = UDim.new(0, 1),
                        }),
                        create("UIPadding", {
                            PaddingTop = UDim.new(0, 3),
                            PaddingBottom = UDim.new(0, 3),
                            PaddingLeft = UDim.new(0, 4),
                            PaddingRight = UDim.new(0, 4),
                        })
                    }
                })

                local open = false
                local dropdown -- declared early so item clicks can sync .Value
                local closeDrop -- declared early so refreshItems() can call it
                local ddEntry
                local scrollConn -- watches the page scroll while the list floats

                local function refreshItems()
                    -- rebuilding the rows resets CanvasPosition; remember and
                    -- restore it so multi-select taps don't jump the scroll.
                    -- TextButtons AND Frames are cleared: the bulk row below
                    -- is a Frame, so clearing buttons only used to stack a
                    -- fresh Select all/Clear row on every refresh.
                    local keepScroll = dropList.CanvasPosition
                    for _, c in dropList:GetChildren() do
                        if c:IsA("TextButton") or c:IsA("Frame") then c:Destroy() end
                    end

                    local term = string.lower(searchTerm or "")

                    -- multi dropdowns get a Select all / Clear row pinned to
                    -- the top of the open list (disabled values stay excluded)
                    if multi then
                        local bulk = create("Frame", {
                            Name = "EZBulkRow",
                            Size = UDim2.new(1, 0, 0, mobile and 30 or 24),
                            BackgroundTransparency = 1,
                            ZIndex = 22,
                            Parent = dropList,
                            Children = {
                                create("UIListLayout", {
                                    FillDirection = Enum.FillDirection.Horizontal,
                                    Padding = UDim.new(0, 4),
                                }),
                            }
                        })
                        local function bulkBtn(text, apply)
                            local b = create("TextButton", {
                                Size = UDim2.new(0.5, -2, 1, 0),
                                BackgroundColor3 = theme.Panel,
                                BackgroundTransparency = 0.75,
                                Text = text,
                                TextColor3 = theme.TextDim,
                                TextSize = 11,
                                Font = Enum.Font.Gotham,
                                AutoButtonColor = false,
                                BorderSizePixel = 0,
                                ZIndex = 23,
                                Parent = bulk
                            })
                            addCorner(b, 4)
                            -- rebuilt on every refresh like value rows, so
                            -- connect directly (see the note below)
                            b.MouseButton1Click:Connect(function()
                                apply()
                                headerLabel.Text = getDisplayText()
                                if dropdown then dropdown.Value = selected end
                                EZ.Flags[id] = selected
                                fireListeners(id, selected)
                                refreshItems()
                                safecall(`Dropdown:{id}`, cb, selected)
                            end)
                        end
                        bulkBtn("Select all", function()
                            for _, val in values do
                                if not disabledOf[val] then selected[val] = true end
                            end
                        end)
                        bulkBtn("Clear", function()
                            table.clear(selected)
                        end)
                    end

                    for _, val in values do
                        local display = displayOfVal(val)
                        if term == "" or string.find(string.lower(display), term, 1, true) ~= nil then
                            local isSelected = multi and selected[val] or (selected == val)
                            local isDisabled = disabledOf[val] == true
                            local item = create("TextButton", {
                                Size = UDim2.new(1, 0, 0, mobile and 32 or 26),
                                BackgroundColor3 = isSelected and theme.Accent or theme.Panel,
                                BackgroundTransparency = isSelected and 0.6 or 0.8,
                                Text = "",
                                BorderSizePixel = 0,
                                AutoButtonColor = false,
                                ZIndex = 22,
                                Parent = dropList
                            })
                            addCorner(item, 4)

                            -- v3.9: optional per-value icon (SetValueImages)
                            local imgAsset = imageOf[val] and EZ.ResolveIcon ~= nil and EZ:ResolveIcon(imageOf[val])
                            if imgAsset then
                                create("ImageLabel", {
                                    Size = UDim2.new(0, 16, 0, 16),
                                    Position = UDim2.new(0, 6, 0.5, -8),
                                    BackgroundTransparency = 1,
                                    Image = imgAsset,
                                    ImageColor3 = theme.Text,
                                    ScaleType = Enum.ScaleType.Fit,
                                    ZIndex = 23,
                                    Parent = item
                                })
                            end

                            create("TextLabel", {
                                Size = UDim2.new(1, imgAsset and -34 or -10, 1, 0),
                                Position = UDim2.new(0, imgAsset and 26 or 8, 0, 0),
                                BackgroundTransparency = 1,
                                Text = display,
                                TextColor3 = isSelected and theme.Text or theme.TextDim,
                                TextTransparency = isDisabled and 0.5 or 0,
                                TextSize = 12,
                                Font = Enum.Font.Gotham,
                                TextXAlignment = Enum.TextXAlignment.Left,
                                ZIndex = 23,
                                Parent = item
                            })

                            -- Connected directly rather than tracked: refreshItems()
                            -- rebuilds these rows on every open, and destroying an
                            -- item already drops its own connections. Tracking them
                            -- grew EZ._connections without bound.
                            item.InputBegan:Connect(function(inp)
                                -- v3.9 drag multi-select: press on a row, sweep
                                -- across rows to select each one entered
                                if dragSelectEnabled and multi and not isDisabled
                                    and (inp.UserInputType == Enum.UserInputType.MouseButton1
                                        or inp.UserInputType == Enum.UserInputType.Touch) then
                                    dragSelecting = true
                                end
                            end)
                            item.MouseEnter:Connect(function()
                                if dragSelectEnabled and dragSelecting and multi and not isDisabled and not selected[val] then
                                    selected[val] = true
                                    item.BackgroundColor3 = theme.Accent
                                    item.BackgroundTransparency = 0.6
                                    headerLabel.Text = getDisplayText()
                                    if dropdown then dropdown.Value = selected end
                                    EZ.Flags[id] = selected
                                    fireListeners(id, selected)
                                    safecall(`Dropdown:{id}`, cb, selected)
                                end
                                if not isDisabled then
                                    tween(item, {BackgroundTransparency = 0.5}, 0.1)
                                end
                            end)
                            item.MouseLeave:Connect(function()
                                local sel = multi and selected[val] or (selected == val)
                                tween(item, {BackgroundTransparency = sel and 0.6 or 0.8}, 0.1)
                            end)

                            item.MouseButton1Click:Connect(function()
                                if isDisabled then return end
                                if multi then
                                    selected[val] = not selected[val]
                                elseif allowEmpty and selected == val then
                                    selected = "" -- AllowEmptySelection: clear in place
                                else
                                    selected = val
                                    closeDrop()
                                end
                                headerLabel.Text = getDisplayText()
                                if dropdown then dropdown.Value = selected end
                                EZ.Flags[id] = selected
                                fireListeners(id, selected)
                                refreshItems()
                                safecall(`Dropdown:{id}`, cb, selected)
                            end)
                        end
                    end
                    dropList.CanvasPosition = keepScroll
                end

                if searchBox then
                    trackConnection(searchBox:GetPropertyChangedSignal("Text"), function()
                        searchTerm = searchBox.Text
                        refreshItems()
                    end)
                end

                -- v3.9: end drag-select on global release (builder-level, so
                -- the connection is tracked once instead of per rebuilt row)
                trackConnection(UserInputService.InputEnded, function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1
                        or inp.UserInputType == Enum.UserInputType.Touch then
                        dragSelecting = false
                    end
                end)

                local dropHomePos = dropFrame.Position

                closeDrop = function()
                    if not open then return end
                    open = false
                    if scrollConn then
                        scrollConn:Disconnect()
                        scrollConn = nil
                    end
                    clearActiveDropdown(ddEntry)
                    local wCur = dropFrame.Size.X.Offset
                    tween(dropFrame, {Size = UDim2.new(0, wCur, 0, 0)}, 0.2)
                    task.delay(0.22, function()
                        if open then return end
                        dropFrame.Visible = false
                        -- dock the list back inside its element; if the
                        -- element died while open, take the list with it
                        if elem and elem.Parent then
                            pcall(function()
                                dropFrame.Parent = elem
                                dropFrame.Position = dropHomePos
                                dropFrame.Size = UDim2.new(1, 0, 0, 0)
                            end)
                        else
                            pcall(function() dropFrame:Destroy() end)
                        end
                    end)
                    tween(dropArrow, {Rotation = 0}, 0.15)
                end
                ddEntry = { close = closeDrop, list = dropFrame, header = header }

                -- the open list is hosted in the root ScreenGui, so it must
                -- be registered like picker/dialog popups: on window Hide or
                -- Destroy, closePopups() docks (or destroys) it — an open
                -- list used to leak at the gui root if the window died while
                -- the dropdown was open, still showing its Select all/Clear
                -- row on top of whatever came next.
                registerPopup(dropFrame, closeDrop)

                trackConnection(header.MouseButton1Click, function()
                    if isElementDisabled(elem) then return end
                    if open then
                        closeDrop()
                        return
                    end
                    open = true
                    setActiveDropdown(ddEntry)
                    refreshItems()

                    -- Host the open list in the root ScreenGui. The section
                    -- frame ClipsDescendants, so a list opening near the
                    -- bottom of a section used to get chopped off mid-item.
                    local headAbs = header.AbsolutePosition
                    local headSz = header.AbsoluteSize
                    local guiAbs = gui.AbsolutePosition
                    local screen = getScreenSize()
                    local itemH = mobile and 32 or 26
                    local listW = math.max(headSz.X, 120)
                    -- v3.9: VisibleItems caps the row count, Height fixes the
                    -- list height outright
                    local h
                    if tonumber(opts.Height) then
                        h = tonumber(opts.Height)
                    else
                        local capH = tonumber(opts.VisibleItems) and (tonumber(opts.VisibleItems) * (itemH + 1) + 8 + listTop)
                        h = math.min(#values * (itemH + 1) + 8 + listTop, capH or 200)
                    end
                    if searchBox then
                        searchBox.Text = ""
                        searchTerm = ""
                        task.delay(0.22, function()
                            if open and searchBox then searchBox:CaptureFocus() end
                        end)
                    end
                    local px = clamp(headAbs.X - guiAbs.X, 4, math.max(4, screen.X - listW - 4))
                    local py = headAbs.Y - guiAbs.Y + headSz.Y + 2
                    if py + h > screen.Y - 6 then
                        py = math.max(4, headAbs.Y - guiAbs.Y - h - 2)
                    end

                    -- The list floats in the root gui, so if the page scrolls
                    -- out from under it (touch drags / scrollbar thumbs never
                    -- fire the MouseWheel close path above) it would hang
                    -- detached mid-air. Watch the owning ScrollingFrame and
                    -- close the instant the page moves.
                    local owner = header
                    while owner and not owner:IsA("ScrollingFrame") do
                        owner = owner.Parent
                    end
                    if owner then
                        scrollConn = owner:GetPropertyChangedSignal("CanvasPosition"):Connect(closeDrop)
                    end

                    dropFrame.Parent = gui
                    dropFrame.Position = UDim2.new(0, px, 0, py)
                    dropFrame.Size = UDim2.new(0, listW, 0, 0)
                    dropFrame.Visible = true
                    tween(dropFrame, {Size = UDim2.new(0, listW, 0, h)}, 0.2)
                    tween(dropArrow, {Rotation = 180}, 0.15)
                end)

                EZ.Flags[id] = selected
                refreshItems()

                dropdown = { Value = selected, _type = "Dropdown" }
                -- Fires the callback like every other :Set() does. Without it,
                -- loading a saved config updated the label but never told the
                -- script the value had changed.
                function dropdown:Set(v, silent)
                    selected = normalizeSelection(v)
                    self.Value = selected
                    headerLabel.Text = getDisplayText()
                    EZ.Flags[id] = selected
                    fireListeners(id, selected)
                    refreshItems()
                    if not silent then safecall(`Dropdown:{id}`, cb, selected) end
                end
                function dropdown:Refresh(newValues, newDisabled)
                    -- re-normalize so Refresh accepts arrays AND dictionaries,
                    -- matching the constructor. Previously requested Disabled
                    -- entries survive the refresh unless newDisabled replaces
                    -- them (the old behavior silently dropped them all).
                    values, displayOf, disabledOf = {}, {}, {}
                    local src = newValues or {}
                    local isDict = false
                    for k in src do
                        if type(k) == "string" then isDict = true break end
                    end
                    if isDict then
                        for k, disp in src do
                            table.insert(values, k)
                            displayOf[k] = tostring(disp)
                        end
                        table.sort(values, function(a, b) return tostring(a) < tostring(b) end)
                    else
                        for _, v in src do table.insert(values, v) end
                    end
                    applyDisabled(newDisabled or disabledSpec, disabledOf)
                    refreshItems()
                end
                function dropdown:Get() return selected end

                -- v3.9 Obsidian-parity methods --------------------------
                function dropdown:SetValues(newValues, newDisabled)
                    return dropdown:Refresh(newValues, newDisabled)
                end
                function dropdown:AddValues(newValues)
                    if typeof(newValues) ~= "table" then return dropdown end
                    local have = {}
                    for _, v in values do have[v] = true end
                    local isDict = false
                    for k in newValues do
                        if type(k) == "string" then isDict = true break end
                    end
                    if isDict then
                        for k, disp in newValues do
                            if not have[k] then
                                table.insert(values, k)
                                have[k] = true
                            end
                            displayOf[k] = tostring(disp)
                        end
                        table.sort(values, function(a, b) return tostring(a) < tostring(b) end)
                    else
                        for _, v in newValues do
                            if not have[v] then
                                table.insert(values, v)
                                have[v] = true
                            end
                        end
                    end
                    refreshItems()
                    return dropdown
                end
                function dropdown:SetDisabledValues(d)
                    disabledOf = {}
                    applyDisabled(d, disabledOf)
                    refreshItems()
                    return dropdown
                end
                function dropdown:AddDisabledValues(d)
                    applyDisabled(d, disabledOf)
                    refreshItems()
                    return dropdown
                end
                function dropdown:SetValueImages(m)
                    imageOf = {}
                    if typeof(m) == "table" then
                        for k, v in m do imageOf[k] = v end
                    end
                    refreshItems()
                    return dropdown
                end
                function dropdown:AddValueImages(m)
                    if typeof(m) == "table" then
                        for k, v in m do imageOf[k] = v end
                    end
                    refreshItems()
                    return dropdown
                end
                function dropdown:SetText(t)
                    if titleLabel then titleLabel.Text = tostring(t or "") end
                    return dropdown
                end
                function dropdown:SetDragSelect(enabled)
                    dragSelectEnabled = enabled == true
                    return dropdown
                end
                function dropdown:GetActiveValues(countOnly)
                    if multi then
                        local n, list = 0, {}
                        for k, v in selected do
                            if v then
                                n += 1
                                list[#list + 1] = k
                            end
                        end
                        return countOnly and n or list
                    end
                    local isSet = selected ~= nil and selected ~= ""
                    return countOnly and (isSet and 1 or 0) or { selected }
                end

                attachOnChanged(dropdown, id)
                setupVisibility(dropdown, elem, opts)
                setupTooltip(elem, opts)
                tagSearch(elem, opts.Text or id)
                finishElement(dropdown, elem, id, section)
                registerElement(id, dropdown)
                table.insert(section.Elements, dropdown)
                return dropdown
            end

            -- ===
            -- INPUT
            -- ===
            function section:AddInput(id, opts)
                opts = opts or {}
                local value = opts.Default or ""
                local cb = opts.Callback or function() end

                local boxH = mobile and 36 or 30
                local elemH = opts.Text and (boxH + 18) or boxH

                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, elemH),
                    BackgroundTransparency = 1,
                    ZIndex = 6,
                    Parent = elemContainer
                })

                local titleLabel
                if opts.Text then
                    titleLabel = create("TextLabel", {
                        Size = UDim2.new(1, 0, 0, 14),
                        BackgroundTransparency = 1,
                        Text = opts.Text,
                        TextColor3 = theme.TextDim,
                        TextSize = 10,
                        Font = Enum.Font.GothamMedium,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        ZIndex = 7,
                        Parent = elem
                    })
                end

                local inputBg = create("Frame", {
                    Size = UDim2.new(1, 0, 0, boxH),
                    Position = UDim2.new(0, 0, 0, opts.Text and 18 or 0),
                    BackgroundColor3 = theme.Surface,
                    BorderSizePixel = 0,
                    ZIndex = 7,
                    Parent = elem
                })
                addCorner(inputBg, 6)
                local inputStroke = addStroke(inputBg, theme.Border, 1, 0.5)

                local textBox = create("TextBox", {
                    Size = UDim2.new(1, -16, 1, 0),
                    Position = UDim2.new(0, 8, 0, 0),
                    BackgroundTransparency = 1,
                    Text = value,
                    PlaceholderText = opts.Placeholder or "Type here...",
                    TextColor3 = theme.Text,
                    PlaceholderColor3 = theme.TextMuted,
                    TextSize = 12,
                    Font = Enum.Font.Code,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    ClearTextOnFocus = false,
                    ZIndex = 8,
                    Parent = inputBg
                })

                trackConnection(textBox.Focused, function()
                    if isElementDisabled(elem) then return end
                    tween(inputStroke, {Color = theme.Accent, Transparency = 0}, 0.15)
                end)
                local input -- declared early so FocusLost can sync .Value

                trackConnection(textBox.FocusLost, function(enterPressed)
                    tween(inputStroke, {Color = theme.Border, Transparency = 0.5}, 0.15)
                    value = textBox.Text
                    if input then input.Value = value end
                    EZ.Flags[id] = value
                    fireListeners(id, value)
                    safecall(`Input:{id}`, cb, value, enterPressed)
                end)

                EZ.Flags[id] = value

                input = { Value = value, _type = "Input" }
                function input:Set(v, silent)
                    v = tostring(v)
                    textBox.Text = v
                    value = v
                    self.Value = v
                    EZ.Flags[id] = v
                    fireListeners(id, v)
                    if not silent then safecall(`Input:{id}`, cb, v, false) end
                end
                function input:Get() return value end

                attachOnChanged(input, id)
                setupVisibility(input, elem, opts)
                setupTooltip(elem, opts)
                tagSearch(elem, opts.Text or id)
                finishElement(input, elem, id, section)
                -- disable also blocks editing, not just interaction
                local baseSetDisabled = input.SetDisabled
                function input:SetDisabled(d)
                    textBox.TextEditable = d ~= true
                    return baseSetDisabled(d)
                end
                function input:SetText(t)
                    if titleLabel then titleLabel.Text = tostring(t or "") end
                    return self
                end
                registerElement(id, input)
                table.insert(section.Elements, input)
                return input
            end

            -- ===
            -- TABBOX (segmented "Tab 1 | Tab 2" control with per-tab content)
            -- local tb = section:AddTabBox("Mode", { Tabs = { "Tab 1", "Tab 2" } })
            -- tb.Tabs["Tab 1"]:AddToggle(...)   -- each tab is a full section
            -- tb:Select("Tab 2") / tb:Get() / tb:Set(name, silent?)
            -- ===
            function section:AddTabBox(id, opts)
                opts = opts or {}
                local tabNames = opts.Tabs or { "Tab 1", "Tab 2" }
                local cb = opts.Callback or function() end

                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    BackgroundTransparency = 1,
                    AutomaticSize = Enum.AutomaticSize.Y,
                    ZIndex = 6,
                    Parent = elemContainer
                })

                local pillRow = create("Frame", {
                    Size = UDim2.new(1, 0, 0, mobile and 30 or 26),
                    BackgroundTransparency = 1,
                    ZIndex = 7,
                    Parent = elem,
                    Children = {
                        create("UIListLayout", {
                            FillDirection = Enum.FillDirection.Horizontal,
                            SortOrder = Enum.SortOrder.LayoutOrder,
                            Padding = UDim.new(0, 4),
                        }),
                    }
                })

                local stack = create("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    Position = UDim2.new(0, 0, 0, mobile and 34 or 30),
                    BackgroundTransparency = 1,
                    AutomaticSize = Enum.AutomaticSize.Y,
                    ZIndex = 6,
                    Parent = elem,
                    Children = {
                        create("UIListLayout", {
                            SortOrder = Enum.SortOrder.LayoutOrder,
                            Padding = UDim.new(0, 4),
                        }),
                    }
                })

                local box = { Tabs = {}, Value = tabNames[1], _type = "TabBox" }
                local buttons = {}

                local function select(name, silent)
                    if box.Tabs[name] == nil then return end
                    box.Value = name
                    EZ.Flags[id] = name
                    for n, sec in box.Tabs do
                        sec.Frame.Visible = (n == name)
                    end
                    for n, btn in buttons do
                        local active = (n == name)
                        tween(btn, {
                            BackgroundTransparency = active and 0.15 or 0.6,
                        }, 0.15)
                        btn.TextColor3 = active and theme.Text or theme.TextDim
                        -- icon-tabs keep their name in a child label
                        for _, c in btn:GetChildren() do
                            if c:IsA("TextLabel") then
                                c.TextColor3 = active and theme.Text or theme.TextDim
                            end
                        end
                    end
                    fireListeners(id, name)
                    if not silent then safecall(`TabBox:{id}`, cb, name) end
                end

                -- v3.9: keep segments equal-width as tabs are added later
                local function relayout()
                    local total = 0
                    for _ in buttons do total += 1 end
                    total = math.max(1, total)
                    for _, btn in buttons do
                        btn.Size = UDim2.new(1 / total, -(4 * (total - 1)) / total, 1, 0)
                    end
                end

                local function addTab(name, icon)
                    name = tostring(name)
                    if box.Tabs[name] ~= nil then return box.Tabs[name] end
                    local idx = 0
                    for _ in buttons do idx += 1 end
                    idx += 1

                    local btn = create("TextButton", {
                        Size = UDim2.new(1 / idx, -(4 * (idx - 1)) / idx, 1, 0),
                        BackgroundColor3 = theme.Surface,
                        BackgroundTransparency = 0.6,
                        Text = icon and "" or name,
                        TextColor3 = theme.TextDim,
                        TextSize = 12,
                        Font = Enum.Font.GothamMedium,
                        BorderSizePixel = 0,
                        AutoButtonColor = false,
                        LayoutOrder = idx,
                        ZIndex = 8,
                        Parent = pillRow
                    })
                    addCorner(btn, 6)
                    if icon then
                        local asset = EZ.ResolveIcon ~= nil and EZ:ResolveIcon(icon)
                        if asset then
                            create("ImageLabel", {
                                Size = UDim2.new(0, 14, 0, 14),
                                Position = UDim2.new(0, 6, 0.5, -7),
                                BackgroundTransparency = 1,
                                Image = asset,
                                ImageColor3 = theme.TextDim,
                                ScaleType = Enum.ScaleType.Fit,
                                ZIndex = 9,
                                Parent = btn
                            })
                            create("TextLabel", {
                                Size = UDim2.new(1, -32, 1, 0),
                                Position = UDim2.new(0, 26, 0, 0),
                                BackgroundTransparency = 1,
                                Text = name,
                                TextColor3 = theme.TextDim,
                                TextSize = 12,
                                Font = Enum.Font.GothamMedium,
                                TextXAlignment = Enum.TextXAlignment.Left,
                                TextTruncate = Enum.TextTruncate.AtEnd,
                                ZIndex = 9,
                                Parent = btn
                            })
                        else
                            btn.Text = name
                        end
                    end
                    buttons[name] = btn
                    relayout()

                    local container = create("Frame", {
                        Size = UDim2.new(1, 0, 0, 0),
                        BackgroundTransparency = 1,
                        AutomaticSize = Enum.AutomaticSize.Y,
                        Visible = false,
                        LayoutOrder = idx,
                        ZIndex = 6,
                        Parent = stack,
                    })

                    -- chromeless section: full element builders, no box chrome
                    local subSec = createSection(name, container, { chromeless = true })
                    box.Tabs[name] = subSec

                    trackConnection(btn.MouseButton1Click, function()
                        if isElementDisabled(elem) then return end
                        select(name)
                    end)
                    if box.Value == name then
                        select(name, true)
                    end
                    return subSec
                end

                for _, name in tabNames do
                    addTab(name)
                end

                function box:Select(name) select(tostring(name)) end
                function box:Set(name, silent) select(tostring(name), silent) end
                function box:Get() return box.Value end
                -- v3.9: tabs can be added after creation (Obsidian Tabbox:AddTab)
                function box:AddTab(name, icon) return addTab(name, icon) end

                EZ.Flags[id] = box.Value
                -- show the first tab once layout exists
                task.defer(function()
                    if box.Tabs[box.Value] then
                        select(box.Value, true)
                    end
                end)

                attachOnChanged(box, id)
                setupVisibility(box, elem, opts)
                setupTooltip(elem, opts)
                tagSearch(elem, table.concat(tabNames, " "))
                finishElement(box, elem, id, section)
                registerElement(id, box)
                table.insert(section.Elements, box)
                return box
            end

            -- ===
            -- KEYBIND
            -- ===
            function section:AddKeybind(id, opts)
                opts = opts or {}
                local mode = opts.Mode or "Toggle"
                local cb = opts.Callback or function() end
                local active = false
                local listening = false

                -- modifier requirements; accepts { Ctrl = true } or {"ctrl"}.
                -- The flag stays a plain EnumItem (KeyCode for keys,
                -- UserInputType for mouse buttons) - modifiers live on the
                -- element so saved configs and old scripts stay compatible.
                local mods = { Ctrl = false, Alt = false, Shift = false }
                do
                    local m = opts.Modifiers
                    if typeof(m) == "table" then
                        for k, v in m do
                            if type(k) == "string" and mods[k] ~= nil then
                                mods[k] = (v == true)
                            elseif type(k) == "number" and type(v) == "string" then
                                local name = v:sub(1, 1):upper() .. v:sub(2):lower()
                                if mods[name] ~= nil then mods[name] = true end
                            end
                        end
                    end
                end

                -- Mouse buttons bind alongside keyboard keys: the stored
                -- EnumItem switches between EnumType containers.
                local MOUSE_BINDS = {
                    [Enum.UserInputType.MouseButton1] = true,
                    [Enum.UserInputType.MouseButton2] = true,
                    [Enum.UserInputType.MouseButton3] = true,
                }

                local function parseBind(v)
                    if typeof(v) == "EnumItem" then return v end
                    if type(v) ~= "string" or v == "" then return nil end
                    local ok, item = pcall(function()
                        if v:sub(1, 5) == "Enum." then
                            local parts = v:split(".")
                            return (#parts >= 3 and Enum[parts[2]] and Enum[parts[2]][parts[3]]) or nil
                        end
                        return Enum.UserInputType[v] or Enum.KeyCode[v]
                    end)
                    return (ok and typeof(item) == "EnumItem") and item or nil
                end

                local key = parseBind(opts.Default) or Enum.KeyCode.Unknown

                local function keyName(k)
                    if typeof(k) ~= "EnumItem" then return "None" end
                    if k.EnumType == Enum.UserInputType then
                        -- parentheses: gsub also returns the match count
                        return (k.Name:gsub("^MouseButton", "M")) -- M1 / M2 / M3
                    end
                    return k ~= Enum.KeyCode.Unknown and k.Name or "None"
                end

                local function inputMatches(inp)
                    if typeof(key) ~= "EnumItem" or key == Enum.KeyCode.Unknown then
                        return false
                    end
                    if key.EnumType == Enum.UserInputType then
                        return inp.UserInputType == key
                    end
                    return inp.KeyCode == key
                end

                local function modsMatch()
                    -- either physical key on each pair counts as held
                    local ctrlHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
                        or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
                    local altHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
                        or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
                    local shiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
                        or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
                    return mods.Ctrl == ctrlHeld
                        and mods.Alt == altHeld
                        and mods.Shift == shiftHeld
                end

                local function comboName()
                    local parts = {}
                    if mods.Ctrl then table.insert(parts, "Ctrl") end
                    if mods.Alt then table.insert(parts, "Alt") end
                    if mods.Shift then table.insert(parts, "Shift") end
                    table.insert(parts, keyName(key))
                    return table.concat(parts, "+")
                end

                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, mobile and 38 or 32),
                    BackgroundTransparency = 1,
                    ZIndex = 6,
                    Parent = elemContainer
                })

                local label = create("TextLabel", {
                    Size = UDim2.new(1, -96, 1, 0),
                    BackgroundTransparency = 1,
                    Text = opts.Text or id,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    TextColor3 = theme.Text,
                    TextSize = 12,
                    Font = Enum.Font.Gotham,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ZIndex = 7,
                    Parent = elem
                })

                local bindBtn = create("TextButton", {
                    Size = UDim2.new(0, 84, 0, 24),
                    Position = UDim2.new(1, -88, 0.5, -12),
                    BackgroundColor3 = theme.Surface,
                    BackgroundTransparency = 0.3,
                    Text = comboName(),
                    TextColor3 = theme.TextDim,
                    TextSize = 11,
                    Font = Enum.Font.Code,
                    BorderSizePixel = 0,
                    AutoButtonColor = false,
                    ZIndex = 8,
                    Parent = elem
                })
                addCorner(bindBtn, 4)
                addStroke(bindBtn, theme.Border, 1, 0.6)

                trackConnection(bindBtn.MouseButton1Click, function()
                    if isElementDisabled(elem) then return end
                    listening = true
                    bindBtn.Text = "..."
                    tween(bindBtn, {BackgroundColor3 = theme.Accent}, 0.15)
                end)

                local keybind -- declared early so the handlers can sync state

                trackConnection(UserInputService.InputBegan, function(inp, gpe)
                    if listening then
                        -- Escape cancels the capture instead of binding itself
                        if inp.UserInputType == Enum.UserInputType.Keyboard
                            and inp.KeyCode == Enum.KeyCode.Escape then
                            listening = false
                            bindBtn.Text = comboName()
                            tween(bindBtn, {BackgroundColor3 = theme.Surface}, 0.15)
                            return
                        end
                        -- accept a keyboard key OR a mouse button (M1-M3);
                        -- anything else keeps waiting
                        if inp.UserInputType == Enum.UserInputType.Keyboard then
                            key = inp.KeyCode
                        elseif MOUSE_BINDS[inp.UserInputType] then
                            key = inp.UserInputType
                        else
                            return
                        end
                        -- snapshot whichever modifiers were held during capture
                        mods.Ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
                            or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
                        mods.Alt = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
                            or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
                        mods.Shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
                            or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
                        bindBtn.Text = comboName()
                        listening = false
                        tween(bindBtn, {BackgroundColor3 = theme.Surface}, 0.15)
                        if keybind then keybind.Value = key end
                        EZ.Flags[id] = key
                        fireListeners(id, key)
                        return
                    end

                    if gpe then return end
                    if not inputMatches(inp) then return end
                    if not modsMatch() then return end

                    if mode == "Toggle" then
                        active = not active
                        if keybind then keybind.Active = active end
                        safecall(`Keybind:{id}`, cb, active)
                    elseif mode == "Hold" then
                        active = true
                        if keybind then keybind.Active = true end
                        safecall(`Keybind:{id}`, cb, true)
                    end
                end)

                trackConnection(UserInputService.InputEnded, function(inp)
                    -- No modsMatch here on purpose: releasing the modifier
                    -- BEFORE the key used to leave a Hold bind latched ON
                    -- until the combo was pressed again.
                    if mode == "Hold" and active and inputMatches(inp) then
                        active = false
                        if keybind then keybind.Active = false end
                        safecall(`Keybind:{id}`, cb, false)
                    end
                end)

                EZ.Flags[id] = key

                keybind = { Value = key, Active = active, _type = "Keybind", _windowTitle = window.Title or "EZ" }
                function keybind:Set(k)
                    -- accepts EnumItems and strings ("G", "MouseButton2",
                    -- "Enum.UserInputType.MouseButton1"); config restores can
                    -- hand back garbage, so parse instead of indexing .Name
                    local parsed = parseBind(k)
                    if not parsed or parsed == Enum.KeyCode.Unknown then return end
                    if parsed.EnumType == Enum.UserInputType and not MOUSE_BINDS[parsed] then return end
                    key = parsed
                    bindBtn.Text = comboName()
                    self.Value = key
                    EZ.Flags[id] = key
                    fireListeners(id, key)
                end
                function keybind:Get() return key end
                function keybind:IsActive() return active end
                -- programmatic activation (panic system uses this; scripts can too)
                function keybind:SetActive(v)
                    v = v == true
                    if v == active then return end
                    active = v
                    self.Active = active
                    safecall(`Keybind:{id}`, cb, active)
                end

                -- full-shape setter used by SaveManager restores; only the
                -- Key change fires the flag listener
                function keybind:Configure(cfg)
                    cfg = cfg or {}
                    local changed = false

                    local parsed = parseBind(cfg.Key)
                    if parsed and parsed ~= Enum.KeyCode.Unknown and parsed ~= key then
                        if parsed.EnumType ~= Enum.UserInputType or MOUSE_BINDS[parsed] then
                            key = parsed
                            changed = true
                        end
                    end
                    if cfg.Mode == "Toggle" or cfg.Mode == "Hold" then
                        mode = cfg.Mode
                    end
                    if typeof(cfg.Modifiers) == "table" then
                        for mk, mv in cfg.Modifiers do
                            if mods[mk] ~= nil then mods[mk] = (mv == true) end
                        end
                    end

                    bindBtn.Text = comboName()

                    if changed then
                        self.Value = key
                        EZ.Flags[id] = key
                        fireListeners(id, key)
                    end
                end
                function keybind:GetMode() return mode end
                function keybind:GetModifiers()
                    return { Ctrl = mods.Ctrl, Alt = mods.Alt, Shift = mods.Shift }
                end

                attachOnChanged(keybind, id)
                setupVisibility(keybind, elem, opts)
                setupTooltip(elem, opts)
                tagSearch(elem, opts.Text or id)
                finishElement(keybind, elem, id, section)
                function keybind:SetText(t)
                    label.Text = t or id
                    tagSearch(elem, t or id)
                    return self
                end
                registerElement(id, keybind)
                table.insert(section.Elements, keybind)
                return keybind
            end

            -- ===
            -- COLORPICKER
            -- ===
            function section:AddColorPicker(id, opts)
                opts = opts or {}
                local color = opts.Default or Color3.fromRGB(255, 255, 255)
                local cb = opts.Callback or function() end

                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, mobile and 38 or 32),
                    BackgroundTransparency = 1,
                    ZIndex = 6,
                    Parent = elemContainer
                })

                local label = create("TextLabel", {
                    Size = UDim2.new(1, -44, 1, 0),
                    BackgroundTransparency = 1,
                    Text = opts.Text or id,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    TextColor3 = theme.Text,
                    TextSize = 12,
                    Font = Enum.Font.Gotham,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ZIndex = 7,
                    Parent = elem
                })

                -- swatch preview
                local swatch = create("TextButton", {
                    Size = UDim2.new(0, 28, 0, 20),
                    Position = UDim2.new(1, -32, 0.5, -10),
                    BackgroundColor3 = color,
                    Text = "",
                    BorderSizePixel = 0,
                    AutoButtonColor = false,
                    ZIndex = 8,
                    Parent = elem
                })
                addCorner(swatch, 4)
                addStroke(swatch, theme.Border, 1, 0.4)

                -- picker popup (parented to gui so section ClipsDescendants doesn't clip it)
                local pickerOpen = false
                local pickerFrame = create("Frame", {
                    Size = UDim2.new(0, 180, 0, 0),
                    Position = UDim2.new(0, 0, 0, 0),
                    BackgroundColor3 = theme.Surface,
                    BackgroundTransparency = 0.05,
                    ClipsDescendants = true,
                    Visible = false,
                    ZIndex = 100,
                    Parent = gui
                })
                addCorner(pickerFrame, 8)
                addStroke(pickerFrame, theme.Border, 1, 0.3)

                -- hue/sat canvas
                local canvas = create("Frame", {
                    Size = UDim2.new(1, -16, 0, 120),
                    Position = UDim2.new(0, 8, 0, 8),
                    BackgroundColor3 = Color3.new(1, 0, 0),
                    BorderSizePixel = 0,
                    ZIndex = 31,
                    Parent = pickerFrame
                })
                addCorner(canvas, 4)

                -- sat overlay (white gradient left to right)
                create("Frame", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundColor3 = Color3.new(1, 1, 1),
                    BorderSizePixel = 0,
                    ZIndex = 32,
                    Parent = canvas,
                    Children = {
                        create("UICorner", {CornerRadius = UDim.new(0, 4)}),
                        create("UIGradient", {
                            Color = ColorSequence.new(Color3.new(1,1,1), Color3.new(1,1,1)),
                            Transparency = NumberSequence.new(0, 1),
                            Rotation = 0,
                        })
                    }
                })

                -- val overlay (black gradient top to bottom)
                create("Frame", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundColor3 = Color3.new(0, 0, 0),
                    BorderSizePixel = 0,
                    ZIndex = 33,
                    Parent = canvas,
                    Children = {
                        create("UICorner", {CornerRadius = UDim.new(0, 4)}),
                        create("UIGradient", {
                            Color = ColorSequence.new(Color3.new(0,0,0), Color3.new(0,0,0)),
                            Transparency = NumberSequence.new(1, 0),
                            Rotation = 90,
                        })
                    }
                })

                -- canvas cursor
                local cursor = create("Frame", {
                    Size = UDim2.new(0, 10, 0, 10),
                    BackgroundColor3 = Color3.new(1,1,1),
                    BorderSizePixel = 0,
                    ZIndex = 35,
                    Parent = canvas
                })
                addCorner(cursor, 5)
                addStroke(cursor, Color3.new(0,0,0), 1, 0)

                -- hue slider
                local hueBar = create("Frame", {
                    Size = UDim2.new(1, -16, 0, 12),
                    Position = UDim2.new(0, 8, 0, 124),
                    BackgroundColor3 = Color3.new(1,1,1),
                    BorderSizePixel = 0,
                    ZIndex = 31,
                    Parent = pickerFrame,
                    Children = {
                        create("UICorner", {CornerRadius = UDim.new(0, 6)}),
                        create("UIGradient", {
                            Color = ColorSequence.new({
                                ColorSequenceKeypoint.new(0, Color3.fromHSV(0,1,1)),
                                ColorSequenceKeypoint.new(0.167, Color3.fromHSV(0.167,1,1)),
                                ColorSequenceKeypoint.new(0.333, Color3.fromHSV(0.333,1,1)),
                                ColorSequenceKeypoint.new(0.5, Color3.fromHSV(0.5,1,1)),
                                ColorSequenceKeypoint.new(0.667, Color3.fromHSV(0.667,1,1)),
                                ColorSequenceKeypoint.new(0.833, Color3.fromHSV(0.833,1,1)),
                                ColorSequenceKeypoint.new(1, Color3.fromHSV(1,1,1)),
                            })
                        })
                    }
                })

                local hueThumb = create("Frame", {
                    Size = UDim2.new(0, 4, 1, 2),
                    Position = UDim2.new(0, 0, 0, -1),
                    BackgroundColor3 = Color3.new(1,1,1),
                    BorderSizePixel = 0,
                    ZIndex = 33,
                    Parent = hueBar
                })
                addCorner(hueThumb, 2)

                -- transparency ramp (left = opaque, right = clear); the flag
                -- stays a plain Color3 - transparency lives on the element as
                -- :GetTransparency()/:SetTransparency() so old scripts and old
                -- configs keep working untouched
                local transBar = create("Frame", {
                    Size = UDim2.new(1, -16, 0, 12),
                    Position = UDim2.new(0, 8, 0, 142),
                    BackgroundColor3 = theme.Panel,
                    BorderSizePixel = 0,
                    ZIndex = 31,
                    Parent = pickerFrame,
                    Children = {
                        create("UICorner", { CornerRadius = UDim.new(0, 6) }),
                        create("Frame", {
                            Size = UDim2.fromScale(1, 1),
                            BackgroundColor3 = Color3.fromRGB(215, 215, 228),
                            BorderSizePixel = 0,
                            ZIndex = 31,
                            Children = { create("UICorner", { CornerRadius = UDim.new(0, 6) }) }
                        }),
                        create("Frame", {
                            Size = UDim2.fromScale(1, 1),
                            BackgroundColor3 = Color3.new(1, 1, 1),
                            BorderSizePixel = 0,
                            ZIndex = 32,
                            Children = {
                                create("UIGradient", {
                                    Transparency = NumberSequence.new({
                                        NumberSequenceKeypoint.new(0, 0),
                                        NumberSequenceKeypoint.new(1, 1),
                                    }),
                                }),
                            }
                        }),
                    }
                })
                local transThumb = create("Frame", {
                    Size = UDim2.new(0, 4, 1, 2),
                    Position = UDim2.new(clamp(tonumber(opts.Transparency) or 0, 0, 1), -2, 0, -1),
                    BackgroundColor3 = Color3.new(1,1,1),
                    BorderSizePixel = 0,
                    ZIndex = 33,
                    Parent = transBar
                })
                addCorner(transThumb, 2)

                -- hex + rgb inputs (side by side, Obsidian-style)
                local hexBox = create("TextBox", {
                    Size = UDim2.new(0, 88, 0, 22),
                    Position = UDim2.new(0, 8, 0, 166),
                    BackgroundColor3 = theme.Panel,
                    Text = color3ToHex(color),
                    TextColor3 = theme.Text,
                    PlaceholderColor3 = theme.TextMuted,
                    PlaceholderText = "#hex",
                    TextSize = 11,
                    Font = Enum.Font.Code,
                    BorderSizePixel = 0,
                    ZIndex = 32,
                    Parent = pickerFrame
                })
                addCorner(hexBox, 4)

                local rgbBox = create("TextBox", {
                    Size = UDim2.new(0, 88, 0, 22),
                    Position = UDim2.new(0, 104, 0, 166),
                    BackgroundColor3 = theme.Panel,
                    Text = "",
                    TextColor3 = theme.Text,
                    PlaceholderColor3 = theme.TextMuted,
                    PlaceholderText = "r, g, b",
                    TextSize = 11,
                    Font = Enum.Font.Code,
                    BorderSizePixel = 0,
                    ZIndex = 32,
                    Parent = pickerFrame
                })
                addCorner(rgbBox, 4)

                -- copy / paste row
                local function pickerButton(text, x)
                    local b = create("TextButton", {
                        Size = UDim2.new(0, 88, 0, 22),
                        Position = UDim2.new(0, x, 0, 194),
                        BackgroundColor3 = theme.Panel,
                        BackgroundTransparency = 0.2,
                        Text = text,
                        TextColor3 = theme.TextDim,
                        TextSize = 11,
                        Font = Enum.Font.GothamMedium,
                        BorderSizePixel = 0,
                        AutoButtonColor = false,
                        ZIndex = 32,
                        Parent = pickerFrame
                    })
                    addCorner(b, 4)
                    return b
                end
                local copyBtn = pickerButton("Copy color", 8)
                local pasteBtn = pickerButton("Paste color", 104)

                -- state
                local h, s, v = Color3.toHSV(color)
                local transparency = clamp(tonumber(opts.Transparency) or 0, 0, 1)
                local picker -- declared early so updateColor() can sync .Value

                local function updateColor(silent)
                    color = Color3.fromHSV(h, s, v)
                    if picker then picker.Value = color end
                    swatch.BackgroundColor3 = color
                    swatch.BackgroundTransparency = transparency
                    canvas.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
                    cursor.Position = UDim2.new(s, -5, 1 - v, -5)
                    hueThumb.Position = UDim2.new(h, -2, 0, -1)
                    transThumb.Position = UDim2.new(transparency, -2, 0, -1)
                    hexBox.Text = color3ToHex(color)
                    rgbBox.Text = ("%d, %d, %d"):format(
                        math.floor(color.R * 255 + 0.5),
                        math.floor(color.G * 255 + 0.5),
                        math.floor(color.B * 255 + 0.5))
                    EZ.Flags[id] = color
                    fireListeners(id, color)
                    if not silent then safecall(`ColorPicker:{id}`, cb, color) end
                end

                -- preset palette (opts.Palette = {Color3, ...}) + session
                -- recents (last 6 deliberate picks; not persisted)
                local paletteColors = {}
                if type(opts.Palette) == "table" then
                    for _, c in opts.Palette do
                        if typeof(c) == "Color3" then table.insert(paletteColors, c) end
                    end
                end
                EZ._recentColors = EZ._recentColors or {}
                local function pushRecent(c)
                    local list = EZ._recentColors
                    for i = #list, 1, -1 do
                        if list[i] == c then table.remove(list, i) end
                    end
                    table.insert(list, 1, c)
                    if #list > 6 then table.remove(list) end
                end

                local function buildSwatchRow(y, colors)
                    if #colors == 0 then return 0 end
                    local row = create("Frame", {
                        Size = UDim2.new(1, -16, 0, 16),
                        Position = UDim2.new(0, 8, 0, y),
                        BackgroundTransparency = 1,
                        ZIndex = 32,
                        Parent = pickerFrame,
                        Children = {
                            create("UIListLayout", {
                                FillDirection = Enum.FillDirection.Horizontal,
                                Padding = UDim.new(0, 4),
                            }),
                        }
                    })
                    for _, c in colors do
                        local sw = create("TextButton", {
                            Size = UDim2.new(0, 16, 0, 16),
                            BackgroundColor3 = c,
                            Text = "",
                            BorderSizePixel = 0,
                            AutoButtonColor = false,
                            ZIndex = 33,
                            Parent = row,
                            Children = { create("UICorner", { CornerRadius = UDim.new(0, 4) }) }
                        })
                        addStroke(sw, theme.Border, 1, 0.5)
                        sw.MouseButton1Click:Connect(function()
                            h, s, v = Color3.toHSV(c)
                            updateColor()
                        end)
                    end
                    return 22
                end

                local palExtra = buildSwatchRow(222, paletteColors)
                local recentsRow
                if palExtra > 0 then
                    recentsRow = create("Frame", {
                        Name = "EZRecentColors",
                        Size = UDim2.new(1, -16, 0, 16),
                        Position = UDim2.new(0, 8, 0, 222 + palExtra),
                        BackgroundTransparency = 1,
                        ZIndex = 32,
                        Parent = pickerFrame,
                        Children = {
                            create("UIListLayout", {
                                FillDirection = Enum.FillDirection.Horizontal,
                                Padding = UDim.new(0, 4),
                            }),
                        }
                    })
                end
                local function refreshRecents()
                    if not recentsRow then return 0 end
                    for _, c in recentsRow:GetChildren() do
                        if c:IsA("TextButton") then c:Destroy() end
                    end
                    for _, c in EZ._recentColors do
                        local sw = create("TextButton", {
                            Size = UDim2.new(0, 16, 0, 16),
                            BackgroundColor3 = c,
                            Text = "",
                            BorderSizePixel = 0,
                            AutoButtonColor = false,
                            ZIndex = 33,
                            Parent = recentsRow,
                            Children = { create("UICorner", { CornerRadius = UDim.new(0, 4) }) }
                        })
                        addStroke(sw, theme.Border, 1, 0.5)
                        sw.MouseButton1Click:Connect(function()
                            h, s, v = Color3.toHSV(c)
                            updateColor()
                        end)
                    end
                    return #EZ._recentColors > 0 and 22 or 0
                end

                -- canvas drag (claims mutex so slider underneath stays still)
                local canvasDrag = false
                trackConnection(canvas.InputBegan, function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                        if EZ._activeDrag and EZ._activeDrag ~= "picker" then return end
                        canvasDrag = true
                        EZ._activeDrag = "picker"
                    end
                end)
                trackConnection(UserInputService.InputChanged, function(inp)
                    if not canvasDrag then return end
                    if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then
                        local pos = Vector2.new(inp.Position.X, inp.Position.Y)
                        local w, hgt = canvas.AbsoluteSize.X, canvas.AbsoluteSize.Y
                        if w <= 0 or hgt <= 0 then return end
                        s = clamp((pos.X - canvas.AbsolutePosition.X) / w, 0, 1)
                        v = 1 - clamp((pos.Y - canvas.AbsolutePosition.Y) / hgt, 0, 1)
                        updateColor()
                    end
                end)
                trackConnection(UserInputService.InputEnded, function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                        if canvasDrag then
                            canvasDrag = false
                            if EZ._activeDrag == "picker" then EZ._activeDrag = nil end
                        end
                    end
                end)

                -- hue drag
                local hueDrag = false
                trackConnection(hueBar.InputBegan, function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                        if EZ._activeDrag and EZ._activeDrag ~= "picker" then return end
                        hueDrag = true
                        EZ._activeDrag = "picker"
                    end
                end)
                trackConnection(UserInputService.InputChanged, function(inp)
                    if not hueDrag then return end
                    if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then
                        local width = hueBar.AbsoluteSize.X
                        if width <= 0 then return end
                        h = clamp((inp.Position.X - hueBar.AbsolutePosition.X) / width, 0, 1)
                        updateColor()
                    end
                end)
                trackConnection(UserInputService.InputEnded, function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                        if hueDrag then
                            hueDrag = false
                            if EZ._activeDrag == "picker" then EZ._activeDrag = nil end
                        end
                    end
                end)

                -- transparency drag (shares the picker mutex)
                local transDrag = false
                trackConnection(transBar.InputBegan, function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                        if EZ._activeDrag and EZ._activeDrag ~= "picker" then return end
                        transDrag = true
                        EZ._activeDrag = "picker"
                    end
                end)
                trackConnection(UserInputService.InputChanged, function(inp)
                    if not transDrag then return end
                    if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then
                        local width = transBar.AbsoluteSize.X
                        if width <= 0 then return end
                        transparency = clamp((inp.Position.X - transBar.AbsolutePosition.X) / width, 0, 1)
                        updateColor()
                    end
                end)
                trackConnection(UserInputService.InputEnded, function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                        if transDrag then
                            transDrag = false
                            if EZ._activeDrag == "picker" then EZ._activeDrag = nil end
                        end
                    end
                end)

                -- hex input
                trackConnection(hexBox.FocusLost, function()
                    local ok, c = pcall(hexToColor3, hexBox.Text)
                    if ok and c then
                        h, s, v = Color3.toHSV(c)
                        updateColor()
                    end
                end)

                -- rgb input ("255, 0, 0" / "255 0 0")
                trackConnection(rgbBox.FocusLost, function()
                    local nums = {}
                    for n in rgbBox.Text:gmatch("%d+") do
                        table.insert(nums, tonumber(n))
                        if #nums == 3 then break end
                    end
                    if #nums == 3 then
                        h, s, v = Color3.toHSV(Color3.fromRGB(nums[1], nums[2], nums[3]))
                        updateColor()
                    end
                end)

                -- copy / paste (hex; paste also understands "r, g, b")
                trackConnection(copyBtn.MouseButton1Click, function()
                    local text = color3ToHex(color)
                    pcall(function() setclipboard(text) end)
                    copyBtn.Text = "Copied!"
                    task.delay(0.9, function()
                        if copyBtn.Parent then copyBtn.Text = "Copy color" end
                    end)
                end)

                trackConnection(pasteBtn.MouseButton1Click, function()
                    local text
                    pcall(function() text = getclipboard and getclipboard() or nil end)
                    if type(text) ~= "string" or text == "" then return end
                    local c = hexToColor3(text)
                    if not c then
                        local nums = {}
                        for n in text:gmatch("%d+") do
                            table.insert(nums, tonumber(n))
                            if #nums == 3 then break end
                        end
                        if #nums == 3 then c = Color3.fromRGB(nums[1], nums[2], nums[3]) end
                    end
                    if c then
                        h, s, v = Color3.toHSV(c)
                        updateColor()
                        pasteBtn.Text = "Pasted!"
                        task.delay(0.9, function()
                            if pasteBtn.Parent then pasteBtn.Text = "Paste color" end
                        end)
                    end
                end)

                -- watches the page ScrollingFrame so the floating picker closes
                -- instead of hanging detached when the content scrolls away
                local pickerScrollConn

                local function closePicker(instant)
                    if not pickerOpen then return end
                    pickerOpen = false
                    pcall(pushRecent, color)
                    if pickerScrollConn then
                        pickerScrollConn:Disconnect()
                        pickerScrollConn = nil
                    end
                    if instant then
                        pickerFrame.Size = UDim2.new(0, 200, 0, 0)
                        pickerFrame.Visible = false
                        return
                    end
                    tween(pickerFrame, {Size = UDim2.new(0, 200, 0, 0)}, 0.15)
                    task.delay(0.15, function()
                        if not pickerOpen then pickerFrame.Visible = false end
                    end)
                end

                trackConnection(swatch.MouseButton1Click, function()
                    if isElementDisabled(elem) then return end
                    if pickerOpen then
                        closePicker()
                        return
                    end
                    pickerOpen = true
                    -- position next to swatch, kept fully on screen
                    local absPos = swatch.AbsolutePosition
                    local absSize = swatch.AbsoluteSize
                    local guiOff = gui.AbsolutePosition
                    local screenSize = getScreenSize()
                    local px = clamp(absPos.X - guiOff.X + absSize.X - 200, 4, math.max(4, screenSize.X - 204))
                    local py = clamp(absPos.Y - guiOff.Y + absSize.Y + 4, 4, math.max(4, screenSize.Y - 232))
                    pickerFrame.Position = UDim2.new(0, px, 0, py)
                    pickerFrame.Visible = true
                    local recentExtra = refreshRecents()
                    tween(pickerFrame, {Size = UDim2.new(0, 200, 0, 222 + palExtra + recentExtra)}, 0.2)

                    -- same scroll-away guard the floating dropdown lists use
                    local owner = swatch
                    while owner and not owner:IsA("ScrollingFrame") do
                        owner = owner.Parent
                    end
                    if owner then
                        pickerScrollConn = owner:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
                            closePicker()
                        end)
                    end
                end)

                -- The popup lives in the root ScreenGui so section clipping
                -- cannot cut it off, which means the window has to close and
                -- destroy it explicitly.
                registerPopup(pickerFrame, closePicker)

                -- click-outside dismisses, matching dropdown behaviour. The
                -- opening click is not caught because InputBegan fires before
                -- MouseButton1Click flips pickerOpen.
                trackConnection(UserInputService.InputBegan, function(inp)
                    if not pickerOpen then return end
                    local it = inp.UserInputType
                    if it ~= Enum.UserInputType.MouseButton1
                        and it ~= Enum.UserInputType.Touch then return end
                    local pos = Vector2.new(inp.Position.X, inp.Position.Y)
                    if pointInside(pickerFrame, pos) or pointInside(swatch, pos) then
                        return
                    end
                    closePicker()
                end)

                updateColor(true)

                picker = { Value = color, _type = "ColorPicker" }
                function picker:Set(c)
                    -- config restores can hand back garbage; indexing it in
                    -- toHSV would throw mid-restore
                    if typeof(c) ~= "Color3" then return end
                    h, s, v = Color3.toHSV(c)
                    updateColor()
                end
                function picker:Get() return color end

                -- transparency rides alongside the Color3 flag without
                -- changing its type; silent so config restores don't double-fire
                function picker:SetTransparency(t)
                    transparency = clamp(tonumber(t) or 0, 0, 1)
                    updateColor(true)
                end
                function picker:GetTransparency() return transparency end

                attachOnChanged(picker, id)
                setupVisibility(picker, elem, opts)
                setupTooltip(elem, opts)
                tagSearch(elem, opts.Text or id)
                finishElement(picker, elem, id, section)
                function picker:SetText(t)
                    label.Text = t or id
                    tagSearch(elem, t or id)
                    return self
                end
                registerElement(id, picker)
                table.insert(section.Elements, picker)
                return picker
            end

            -- ===
            -- LABEL
            -- ===
            function section:AddLabel(text)
                -- accept table form too: AddLabel({ Text = "...", Tooltip = ..., VisibleWhen = ..., DoesWrap = ..., RichText = ..., Size = 14 })
                local opts = (type(text) == "table") and text or nil
                if opts then text = opts.Text or opts.Title or "" end
                local doesWrap = opts ~= nil and opts.DoesWrap == true
                local lbl = create("TextLabel", {
                    Size = doesWrap and UDim2.new(1, 0, 0, 0) or UDim2.new(1, 0, 0, 18),
                    AutomaticSize = doesWrap and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
                    BackgroundTransparency = 1,
                    Text = tostring(text or ""),
                    RichText = opts and opts.RichText == true or false,
                    TextWrapped = doesWrap,
                    TextColor3 = theme.TextDim,
                    TextSize = (opts and tonumber(opts.Size)) or 11,
                    Font = Enum.Font.Gotham,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ZIndex = 7,
                    Parent = elemContainer
                })
                tagSearch(lbl, tostring(text or ""))
                if opts then
                    setupVisibility(lbl, lbl, opts)
                    setupTooltip(lbl, opts)
                end

                local label = {}
                function label:Set(t)
                    lbl.Text = tostring(t)
                    tagSearch(lbl, tostring(t))
                    return self
                end
                function label:SetText(t) return label:Set(t) end
                function label:SetSize(size)
                    lbl.TextSize = tonumber(size) or lbl.TextSize
                    return self
                end
                finishElement(label, lbl, nil, section)
                table.insert(section.Elements, label)
                return label
            end

            -- ===
            -- DIVIDER
            -- ===
            function section:AddDivider(textOrOpts)
                -- v3.9: optional centered text + margins.
                --   AddDivider()                    - plain hairline (as before)
                --   AddDivider("Section")            - hairline with centered text
                --   AddDivider({ Text = "...", MarginTop = 8, MarginBottom = 8 })
                local opts = (type(textOrOpts) == "table") and textOrOpts or nil
                local text = opts and opts.Text or (type(textOrOpts) == "string" and textOrOpts or nil)
                local marginTop = (opts and tonumber(opts.MarginTop)) or (text and 4 or 0)
                local marginBottom = (opts and tonumber(opts.MarginBottom)) or 0

                local row = create("Frame", {
                    Size = UDim2.new(1, 0, 0, marginTop + marginBottom + (text and 14 or 1)),
                    BackgroundTransparency = 1,
                    ZIndex = 6,
                    Parent = elemContainer
                })

                if text then
                    create("Frame", {
                        Size = UDim2.new(0.5, -22, 0, 1),
                        Position = UDim2.new(0, 0, 0, marginTop + 7),
                        BackgroundColor3 = theme.Border,
                        BackgroundTransparency = 0.5,
                        BorderSizePixel = 0,
                        ZIndex = 6,
                        Parent = row
                    })
                    create("TextLabel", {
                        Size = UDim2.new(0, 0, 0, 12),
                        Position = UDim2.new(0.5, 0, 0, marginTop + 1),
                        AnchorPoint = Vector2.new(0.5, 0),
                        AutomaticSize = Enum.AutomaticSize.X,
                        BackgroundTransparency = 1,
                        Text = tostring(text),
                        TextColor3 = theme.TextMuted,
                        TextSize = 10,
                        Font = Enum.Font.GothamMedium,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        ZIndex = 6,
                        Parent = row
                    })
                    create("Frame", {
                        Size = UDim2.new(0.5, -22, 0, 1),
                        Position = UDim2.new(0.5, 22, 0, marginTop + 7),
                        BackgroundColor3 = theme.Border,
                        BackgroundTransparency = 0.5,
                        BorderSizePixel = 0,
                        ZIndex = 6,
                        Parent = row
                    })
                else
                    create("Frame", {
                        Size = UDim2.new(1, 0, 0, 1),
                        Position = UDim2.new(0, 0, 0, marginTop),
                        BackgroundColor3 = theme.Border,
                        BackgroundTransparency = 0.5,
                        BorderSizePixel = 0,
                        ZIndex = 6,
                        Parent = row
                    })
                end

                local divider = {}
                finishElement(divider, row, nil, section)
                table.insert(section.Elements, divider)
                return divider
            end

            -- ===
            -- PARAGRAPH
            -- ===
            function section:AddParagraph(opts)
                opts = opts or {}
                local frame = create("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    BackgroundTransparency = 1,
                    AutomaticSize = Enum.AutomaticSize.Y,
                    ZIndex = 6,
                    Parent = elemContainer
                })

                if opts.Title then
                    create("TextLabel", {
                        Size = UDim2.new(1, 0, 0, 16),
                        BackgroundTransparency = 1,
                        Text = opts.Title,
                        TextColor3 = theme.Text,
                        TextSize = 12,
                        Font = Enum.Font.GothamBold,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        ZIndex = 7,
                        Parent = frame
                    })
                end

                local bodyLbl = create("TextLabel", {
                    Size = UDim2.new(1, 0, 0, 0),
                    Position = UDim2.new(0, 0, 0, opts.Title and 18 or 0),
                    BackgroundTransparency = 1,
                    Text = opts.Content or "",
                    RichText = opts.RichText == true,
                    TextColor3 = theme.TextDim,
                    TextSize = 11,
                    Font = Enum.Font.Gotham,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextWrapped = true,
                    AutomaticSize = Enum.AutomaticSize.Y,
                    ZIndex = 7,
                    Parent = frame
                })

                tagSearch(frame, (opts.Title or "") .. " " .. (opts.Content or ""))

                local para = {}
                setupVisibility(para, frame, opts)
                setupTooltip(frame, opts)
                function para:Set(txt)
                    bodyLbl.Text = tostring(txt)
                    tagSearch(frame, (opts.Title or "") .. " " .. tostring(txt))
                end
                finishElement(para, frame, nil, section)
                table.insert(section.Elements, para)
                return para
            end

            -- ===
            -- PROGRESS BAR
            -- ===
            function section:AddProgressBar(id, opts)
                opts = opts or {}
                local maxVal = tonumber(opts.Max) or 100
                if maxVal <= 0 then maxVal = 100 end
                local progress = clamp(tonumber(opts.Default) or 0, 0, maxVal)
                local showText = opts.ShowText ~= false

                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, 34),
                    BackgroundTransparency = 1,
                    ZIndex = 6,
                    Parent = elemContainer
                })

                local label = create("TextLabel", {
                    Size = UDim2.new(1, 0, 0, 14),
                    BackgroundTransparency = 1,
                    Text = opts.Text or id,
                    TextColor3 = theme.TextDim,
                    TextSize = 10,
                    Font = Enum.Font.GothamMedium,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ZIndex = 7,
                    Parent = elem
                })

                local barBg = create("Frame", {
                    Size = UDim2.new(1, 0, 0, 12),
                    Position = UDim2.new(0, 0, 0, 18),
                    BackgroundColor3 = theme.Surface,
                    BackgroundTransparency = 0.2,
                    BorderSizePixel = 0,
                    ClipsDescendants = true,
                    ZIndex = 7,
                    Parent = elem
                })
                addCorner(barBg, 4)
                addStroke(barBg, theme.Border, 1, 0.6)

                local fill = create("Frame", {
                    Size = UDim2.new(maxVal > 0 and math.clamp(progress / maxVal, 0, 1) or 0, 0, 1, 0),
                    BackgroundColor3 = opts.Color or theme.Accent,
                    BorderSizePixel = 0,
                    ZIndex = 8,
                    Parent = barBg
                })
                addCorner(fill, 4)

                local pctLbl
                if showText then
                    pctLbl = create("TextLabel", {
                        Size = UDim2.new(0, 50, 0, 14),
                        Position = UDim2.new(1, -50, 0, 0),
                        BackgroundTransparency = 1,
                        Text = tostring(math.floor(progress)) .. "/" .. tostring(maxVal),
                        TextColor3 = theme.TextDim,
                        TextSize = 10,
                        Font = Enum.Font.Code,
                        TextXAlignment = Enum.TextXAlignment.Right,
                        ZIndex = 7,
                        Parent = elem
                    })
                end

                EZ.Flags[id] = progress

                -- _type opts the handle into SaveManager's format-2 configs
                local bar = { Value = progress, _type = "Progress" }
                function bar:Set(v)
                    progress = math.clamp(tonumber(v) or 0, 0, maxVal)
                    self.Value = progress
                    local pct = maxVal > 0 and (progress / maxVal) or 0
                    tween(fill, {Size = UDim2.new(pct, 0, 1, 0)}, 0.12)
                    if pctLbl then pctLbl.Text = tostring(math.floor(progress)) .. "/" .. tostring(maxVal) end
                    EZ.Flags[id] = progress
                    fireListeners(id, progress)
                end
                function bar:SetMax(m)
                    maxVal = tonumber(m) or maxVal
                    if maxVal <= 0 then maxVal = 1 end
                    bar:Set(progress)
                end
                function bar:SetColor(c) fill.BackgroundColor3 = c end
                function bar:Get() return progress end

                attachOnChanged(bar, id)
                setupVisibility(bar, elem, opts)
                setupTooltip(elem, opts)
                tagSearch(elem, opts.Text or id)
                finishElement(bar, elem, id, section)
                function bar:SetText(t)
                    label.Text = t or id
                    tagSearch(elem, t or id)
                    return self
                end
                registerElement(id, bar)
                table.insert(section.Elements, bar)
                return bar
            end

            -- ===
            -- LOG / CONSOLE
            -- ===
            function section:AddLog(opts)
                opts = opts or {}
                local maxLines = math.max(1, tonumber(opts.MaxLines) or 50)
                local lines = {}

                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, opts.Height or 120),
                    BackgroundColor3 = theme.Surface,
                    BackgroundTransparency = 0.2,
                    BorderSizePixel = 0,
                    ZIndex = 6,
                    Parent = elemContainer
                })
                addCorner(elem, 4)
                addStroke(elem, theme.Border, 1, 0.6)

                local scroll = create("ScrollingFrame", {
                    Size = UDim2.new(1, -8, 1, -8),
                    Position = UDim2.new(0, 4, 0, 4),
                    BackgroundTransparency = 1,
                    BorderSizePixel = 0,
                    ScrollBarThickness = 2,
                    ScrollBarImageColor3 = theme.Border,
                    CanvasSize = UDim2.new(0, 0, 0, 0),
                    AutomaticCanvasSize = Enum.AutomaticSize.Y,
                    ScrollingDirection = Enum.ScrollingDirection.Y,
                    ZIndex = 7,
                    Parent = elem
                })

                create("UIListLayout", {
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    Padding = UDim.new(0, 1),
                    Parent = scroll
                })

                local log = {}
                -- monotonic: reusing #lines + 1 after a trim gave two live
                -- lines the same LayoutOrder and scrambled their order
                local lineSeq = 0
                local function append(txt, color)
                    if #lines >= maxLines then
                        local first = lines[1]
                        if first then first:Destroy() end
                        table.remove(lines, 1)
                    end
                    lineSeq = lineSeq + 1
                    local line = create("TextLabel", {
                        Size = UDim2.new(1, 0, 0, 14),
                        BackgroundTransparency = 1,
                        Text = txt,
                        TextColor3 = color or theme.TextDim,
                        TextSize = 11,
                        Font = Enum.Font.Code,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        LayoutOrder = lineSeq,
                        ZIndex = 8,
                        Parent = scroll
                    })
                    table.insert(lines, line)
                    task.defer(function()
                        scroll.CanvasPosition = Vector2.new(0, scroll.AbsoluteCanvasSize.Y)
                    end)
                end

                function log:Info(txt)  append("[i] " .. tostring(txt), theme.Text) end
                function log:Warn(txt)  append("[!] " .. tostring(txt), Color3.fromRGB(255, 200, 90)) end
                function log:Error(txt) append("[x] " .. tostring(txt), Color3.fromRGB(255, 90, 90)) end
                function log:Success(txt) append("[+] " .. tostring(txt), Color3.fromRGB(120, 230, 140)) end
                function log:Print(txt, color) append(tostring(txt), color) end
                function log:Clear()
                    for _, l in lines do l:Destroy() end
                    table.clear(lines)
                end

                -- Optional search tag; untagged rows stay visible inside
                -- matched sections, so hosts can opt in via AddLog({Text=...})
                if opts.Text then tagSearch(elem, opts.Text) end
                finishElement(log, elem, nil, section)
                table.insert(section.Elements, log)
                return log
            end

            -- ===
            -- PLAYER SELECTOR (dropdown preloaded with players + auto-refresh)
            -- ===
            function section:AddPlayerSelector(id, opts)
                opts = opts or {}
                local excludeSelf = opts.ExcludeSelf ~= false
                local multi = opts.Multi or false

                local function buildList()
                    local list = {}
                    if not excludeSelf then table.insert(list, "@me") end
                    table.insert(list, "@random")
                    table.insert(list, "@nearest")
                    for _, p in pairs(Players:GetPlayers()) do
                        if not excludeSelf or p ~= Players.LocalPlayer then
                            table.insert(list, p.Name)
                        end
                    end
                    return list
                end

                local dropOpts = {
                    Text = opts.Text or "Select Player",
                    Values = buildList(),
                    -- left nil on purpose so AddDropdown falls back to the
                    -- first entry; "" is truthy and left the selector blank
                    Default = opts.Default,
                    Multi = multi,
                    Callback = opts.Callback,
                    VisibleWhen = opts.VisibleWhen,
                }

                local dd = section:AddDropdown(id, dropOpts)

                -- auto-refresh on join/leave
                trackConnection(Players.PlayerAdded, function() dd:Refresh(buildList()) end)
                trackConnection(Players.PlayerRemoving, function() dd:Refresh(buildList()) end)

                function dd:GetPlayers()
                    local sel = dd:Get()
                    if type(sel) == "string" then
                        if sel == "@me" then return {Players.LocalPlayer}
                        elseif sel == "@random" then
                            local list = {}
                            for _, p in pairs(Players:GetPlayers()) do
                                if p ~= Players.LocalPlayer then table.insert(list, p) end
                            end
                            return #list > 0 and {list[math.random(1, #list)]} or {}
                        elseif sel == "@nearest" then
                            local lp = Players.LocalPlayer
                            local myChar = lp.Character
                            if not myChar or not myChar:FindFirstChild("HumanoidRootPart") then return {} end
                            local myPos = myChar.HumanoidRootPart.Position
                            local best, bd = nil, math.huge
                            for _, p in pairs(Players:GetPlayers()) do
                                if p ~= lp and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                                    local d = (p.Character.HumanoidRootPart.Position - myPos).Magnitude
                                    if d < bd then best, bd = p, d end
                                end
                            end
                            return best and {best} or {}
                        else
                            local p = Players:FindFirstChild(sel)
                            return p and {p} or {}
                        end
                    elseif type(sel) == "table" then
                        local out = {}
                        for name, on in pairs(sel) do
                            if on then
                                local p = Players:FindFirstChild(name)
                                if p then table.insert(out, p) end
                            end
                        end
                        return out
                    end
                    return {}
                end

                return dd
            end

            -- ===
            -- VIEWPORT (3D preview: ViewportFrame + WorldModel + orbit camera)
            -- ===
            function section:AddViewport(id, opts)
                opts = opts or {}
                local height = tonumber(opts.Height) or 180
                local interactive = opts.Interactive ~= false
                local autoFocus = opts.AutoFocus ~= false

                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, height),
                    BackgroundColor3 = theme.Base,
                    BackgroundTransparency = 0.1,
                    BorderSizePixel = 0,
                    ClipsDescendants = true,
                    ZIndex = 6,
                    Parent = elemContainer
                })
                addCorner(elem, 6)
                addStroke(elem, theme.Border, 1, 0.55)

                local viewport = create("ViewportFrame", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundTransparency = 1,
                    ImageTransparency = 1,
                    Ambient = theme.Text,
                    LightColor = theme.Text,
                    ZIndex = 7,
                    Parent = elem
                })
                local world = create("WorldModel", { Parent = viewport })
                local camera = create("Camera", { Parent = viewport })
                if typeof(opts.Camera) == "Instance" then camera = opts.Camera end
                viewport.CurrentCamera = camera

                local object
                local orbitYaw, orbitPitch, orbitDist = 0.6, 0.35, nil
                local center, radius = Vector3.zero, 1

                local function computeBounds()
                    if not object then return Vector3.zero, 1 end
                    local ok, cf, size = pcall(function() return object:GetBoundingBox() end)
                    if ok and cf and size then
                        return cf.Position, math.max(size.Magnitude / 2, 0.5)
                    end
                    local pos = object.Position or Vector3.zero
                    local sz = object.Size or Vector3.one
                    return pos, math.max(sz.Magnitude / 2, 0.5)
                end

                local function applyCamera()
                    center, radius = computeBounds()
                    orbitDist = orbitDist or radius * 3.2
                    local dir = Vector3.new(
                        math.cos(orbitPitch) * math.sin(orbitYaw),
                        math.sin(orbitPitch),
                        math.cos(orbitPitch) * math.cos(orbitYaw)
                    )
                    pcall(function()
                        camera.CFrame = CFrame.lookAt(center + dir * orbitDist, center)
                    end)
                end

                local function setObject(newObj)
                    if typeof(newObj) ~= "Instance" then return end
                    if object then pcall(function() object:Destroy() end) end
                    -- clone so the caller's instance stays theirs; if cloning
                    -- fails (uncloneable), parent it directly
                    local inst = newObj
                    local ok, c = pcall(function() return newObj:Clone() end)
                    if ok and c then inst = c end
                    inst.Parent = world
                    object = inst
                    orbitDist = nil
                    if autoFocus then applyCamera() end
                end
                if opts.Object then setObject(opts.Object) end

                local dragging = false
                trackConnection(viewport.InputBegan, function(inp)
                    if not interactive or isElementDisabled(elem) then return end
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                        if EZ._activeDrag and EZ._activeDrag ~= "viewport" then return end
                        dragging = true
                        EZ._activeDrag = "viewport"
                    end
                end)
                trackConnection(UserInputService.InputChanged, function(inp)
                    if not dragging or EZ._activeDrag ~= "viewport" then return end
                    if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then
                        orbitYaw -= inp.Delta.X * 0.01
                        orbitPitch = clamp(orbitPitch + inp.Delta.Y * 0.01, -1.2, 1.2)
                        applyCamera()
                    elseif inp.UserInputType == Enum.UserInputType.MouseWheel then
                        orbitDist = clamp((orbitDist or radius * 3.2) - inp.Position.Z * (radius * 0.4), radius * 1.2, radius * 12)
                        applyCamera()
                    end
                end)
                trackConnection(UserInputService.InputEnded, function(inp)
                    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                        if dragging then
                            dragging = false
                            if EZ._activeDrag == "viewport" then EZ._activeDrag = nil end
                        end
                    end
                end)

                local vh = {}
                function vh:SetObject(o) setObject(o) end
                function vh:GetObject() return object end
                function vh:SetCamera(cam)
                    if typeof(cam) ~= "Instance" then return end
                    camera = cam
                    pcall(function() viewport.CurrentCamera = cam end)
                    applyCamera()
                end
                function vh:SetInteractive(v) interactive = v ~= false end
                function vh:SetHeight(h)
                    height = tonumber(h) or height
                    elem.Size = UDim2.new(1, 0, 0, height)
                end
                function vh:Focus()
                    orbitDist = nil
                    applyCamera()
                end
                setupVisibility(vh, elem, opts)
                setupTooltip(elem, opts)
                tagSearch(elem, opts.Text or id)
                finishElement(vh, elem, nil, section)
                table.insert(section.Elements, vh)
                -- bounds need a frame of layout before they mean anything
                task.defer(function()
                    if elem.Parent then applyCamera() end
                end)
                return vh
            end

            -- ===
            -- UI PASSTHROUGH (embed any GuiBase2d inside the layout)
            -- ===
            function section:AddUIPassthrough(id, opts)
                opts = opts or {}
                local height = tonumber(opts.Height) or 120

                local elem = create("Frame", {
                    Size = UDim2.new(1, 0, 0, height),
                    BackgroundTransparency = 1,
                    ClipsDescendants = true,
                    ZIndex = 6,
                    Parent = elemContainer
                })

                local instance, origParent, origSize, origPos
                local function embed(newInst)
                    if instance then
                        pcall(function()
                            if instance.Parent == elem then
                                instance.Parent = origParent
                                instance.Size = origSize
                                instance.Position = origPos
                            end
                        end)
                    end
                    instance = newInst
                    if typeof(instance) ~= "Instance" then
                        instance = nil
                        return
                    end
                    origParent = instance.Parent
                    origSize = instance.Size
                    origPos = instance.Position
                    instance.Size = UDim2.fromScale(1, 1)
                    instance.Position = UDim2.new(0, 0, 0, 0)
                    instance.Parent = elem
                end
                if opts.Instance then embed(opts.Instance) end

                local pass = {}
                function pass:SetInstance(inst) embed(inst) end
                function pass:GetInstance() return instance end
                function pass:SetHeight(h)
                    height = tonumber(h) or height
                    elem.Size = UDim2.new(1, 0, 0, height)
                end
                setupVisibility(pass, elem, opts)
                setupTooltip(elem, opts)
                tagSearch(elem, opts.Text or id)
                finishElement(pass, elem, nil, section)
                -- Destroy hands the embedded instance back to its old parent
                local baseDestroy = pass.Destroy
                function pass:Destroy()
                    if instance then
                        pcall(function()
                            if instance.Parent == elem then
                                instance.Parent = origParent
                                instance.Size = origSize
                                instance.Position = origPos
                            end
                        end)
                    end
                    baseDestroy()
                end
                table.insert(section.Elements, pass)
                return pass
            end

            -- Same reason as owned() above: element builders run long after
            -- CreateWindow() returned, so each re-asserts the owner.
            local builders = {}
            for key, fn in section do
                if type(fn) == "function" then builders[key] = owned(fn) end
            end
            for key, fn in builders do section[key] = fn end

            table.insert(tab.Sections, section)
            return section
        end

        function tab:AddSection(sectionName, description)
            return createSection(sectionName, tabContent, { Description = description })
        end

        -- ~~----
        -- GROUPBOXES (two-column layout)
        -- tab:AddLeftGroupbox("Menu") / tab:AddRightGroupbox("Configuration")
        -- Both columns share one row so their tops always line up.
        -- ~~----
        local function ensureGroupColumns()
            if tab._groupCols then return end
            local row = create("Frame", {
                Name = "EZGroupColumns",
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
                LayoutOrder = 500,
                ZIndex = 5,
                Parent = tabContent,
                Children = {
                    create("UIListLayout", {
                        FillDirection = Enum.FillDirection.Horizontal,
                        SortOrder = Enum.SortOrder.LayoutOrder,
                        Padding = UDim.new(0, 8),
                    }),
                }
            })
            row:SetAttribute("EZGroupRow", true)
            local function makeColumn(order)
                return create("Frame", {
                    Size = UDim2.new(0.5, -4, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundTransparency = 1,
                    LayoutOrder = order,
                    ZIndex = 5,
                    Parent = row,
                    Children = {
                        create("UIListLayout", {
                            SortOrder = Enum.SortOrder.LayoutOrder,
                            Padding = UDim.new(0, 6),
                        }),
                    }
                })
            end
            tab._groupCols = { makeColumn(1), makeColumn(2) }
        end

        function tab:AddGroupbox(side, name, icon, description)
            side = string.lower(tostring(side or "left"))
            ensureGroupColumns()
            local col = (side == "right") and tab._groupCols[2] or tab._groupCols[1]
            return createSection(name, col, { icon = icon, Description = description })
        end
        function tab:AddLeftGroupbox(name, icon, description) return tab:AddGroupbox("left", name, icon, description) end
        function tab:AddRightGroupbox(name, icon, description) return tab:AddGroupbox("right", name, icon, description) end

        tab.AddSection = owned(tab.AddSection)
        tab.AddSubTab = owned(tab.AddSubTab)
        tab.AddGroupbox = owned(tab.AddGroupbox)
        tab.AddLeftGroupbox = owned(tab.AddLeftGroupbox)
        tab.AddRightGroupbox = owned(tab.AddRightGroupbox)
        return tab
    end

    window.AddTab = owned(window.AddTab)

    -- ~~--------
    -- AUTO SETTINGS
    -- On by default so scripts built on the library never have to think
    -- about persistence. Pass AutoSettings = false to opt out.
    -- ~~--------
    if opts.AutoSettings ~= false then
        -- Deferred so the host's own tabs are registered first. Built
        -- synchronously it became tab #1: top of the sidebar, and it stole
        -- the initial focus from the host's first real tab. The addon HTTP
        -- fetch also no longer stalls CreateWindow itself.
        task.defer(function()
            -- covers both this window being closed mid-frame and a full
            -- EZ:Destroy() before the deferred slot ever ran
            if window._destroyed or self._destroyed then return end
            local okAuto, errAuto = pcall(buildAutoSettings, window)
            if not okAuto then
                warn("[EZ] AutoSettings failed: " .. tostring(errAuto))
            end
        end)
    end

    table.insert(self.Windows, window)
    EZ._connectionOwner = previousConnectionOwner
    return window
end

-- Live recolouring works by matching an instance's current colour back to a
-- theme role. Several themes give two roles the same RGB (Dracula's Border and
-- TextMuted, Nord's TextMuted and Info), so a single flat colour->role map let
-- whichever role happened to hash last win: switching away from those themes
-- recoloured the wrong elements, and differently on each run. Two maps keyed by
-- how the colour is used, each filled in a fixed precedence order, keeps the
-- result both correct and deterministic.
local TEXT_ROLE_ORDER = {
    "Text", "TextDim", "TextMuted", "Accent", "AccentDark",
    "Success", "Warning", "Error", "Info", "Border", "Panel", "Surface", "Base",
}
local FILL_ROLE_ORDER = {
    "Base", "Surface", "Panel", "Border", "Accent", "AccentDark",
    "Success", "Warning", "Error", "Info", "Text", "TextDim", "TextMuted",
}
-- properties that carry a foreground colour; everything else reads the fill map
local TEXT_PROPS = { TextColor3 = true, PlaceholderColor3 = true, ImageColor3 = true }
local COLOR_PROPS = {
    "BackgroundColor3", "TextColor3", "PlaceholderColor3",
    "ImageColor3", "ScrollBarImageColor3",
}

local function colorKey(c)
    return string.format("%d_%d_%d",
        math.floor(c.R * 255 + .5), math.floor(c.G * 255 + .5), math.floor(c.B * 255 + .5))
end

-- theme setter with live recolor
function EZ:SetTheme(themeTable)
    themeTable = themeTable or {}

    -- Snapshot the old theme first. Updating self.Theme before collecting the
    -- old values made repeated theme changes unreliable.
    local oldTheme = {}
    for k, v in self.Theme do
        oldTheme[k] = v
    end

    local function buildMap(order)
        local map = {}
        for _, role in order do
            local old, new = oldTheme[role], themeTable[role]
            if typeof(old) == "Color3" and typeof(new) == "Color3" then
                local key = colorKey(old)
                if map[key] == nil then map[key] = new end -- earliest role wins
            end
        end
        return map
    end

    local textMap = buildMap(TEXT_ROLE_ORDER)
    local fillMap = buildMap(FILL_ROLE_ORDER)

    for k, v in themeTable do
        self.Theme[k] = v
    end

    local function recolor(desc)
        for _, prop in COLOR_PROPS do
            pcall(function()
                local cur = desc[prop]
                if typeof(cur) == "Color3" then
                    local repl = (TEXT_PROPS[prop] and textMap or fillMap)[colorKey(cur)]
                    if repl then desc[prop] = repl end
                end
            end)
        end
        -- UIStroke keeps its colour on .Color, and strokes are always fills
        if desc:IsA("UIStroke") then
            pcall(function()
                local repl = fillMap[colorKey(desc.Color)]
                if repl then desc.Color = repl end
            end)
        end
    end

    -- recolor all descendants of EZUI + EZNotifs
    local containers = {}
    if gui and gui.Parent then table.insert(containers, gui) end
    if notifGui and notifGui.Parent then table.insert(containers, notifGui) end

    pcall(function()
        local hui = (gethui and gethui()) or Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if hui then
            -- EZQuickBar is a sibling ScreenGui owned by the QuickBar addon;
            -- skipping it left the dock wearing the old theme after a switch
            for _, g in hui:GetChildren() do
                if (g.Name == "EZUI" or g.Name == "EZNotifs" or g.Name == "EZQuickBar")
                    and not table.find(containers, g)
                then
                    table.insert(containers, g)
                end
            end
        end
    end)

    -- The watermark normally lives inside gui and is covered by the sweep
    -- below. Only walk it separately if it was reparented somewhere else -
    -- visiting it twice could remap an already-updated colour a second time.
    if self._watermark and self._watermark.Parent
        and not table.find(containers, self._watermark.Parent)
    then
        table.insert(containers, self._watermark)
    end

    for _, container in containers do
        recolor(container)
        for _, desc in container:GetDescendants() do
            recolor(desc)
        end
    end
end

function EZ:GetTheme()
    return self.Theme
end

-- ~~
-- SETTINGS-DRIVEN APPEARANCE APIs
-- Backing the Settings tab (Menu / Themes groupboxes); all usable directly.
-- ~~

-- Move the notification column between screen edges.
function EZ:SetNotificationSide(side)
    side = (side == "Left") and "Left" or "Right"
    self._notifSide = side
    if notifHolder and notifHolder.Parent then
        notifHolder.Position = (side == "Left")
            and UDim2.new(0, 10, 0, 10)
            or UDim2.new(1, -310, 0, 10)
    end
end

-- Custom cursor. v4.0: two-layer overlay (crosshair + optional icon) that
-- follows the mouse every frame — Mouse.Icon can only ever show one image,
-- so colors/sizes/two layers need real gui. The old Mouse.Icon API
-- (SetCursorIcon/SetCursorEnabled) maps onto ChangeIcon/SetCursorEnabled.
function EZ:_ensureCursorGui()
    if self._cursorGui and self._cursorGui.Parent then return self._cursorGui end
    local ok, screenGui = pcall(function()
        local parent = (gethui and gethui()) or Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        return create("ScreenGui", {
            Name = "EZCursor",
            DisplayOrder = 30000, -- above notifications (10000) + always-on-top (25000)
            IgnoreGuiInset = true,
            ResetOnSpawn = false,
            ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
            Parent = parent,
        })
    end)
    if not ok or not screenGui then return nil end
    self._cursorGui = screenGui

    local cross = create("ImageLabel", {
        Name = "Cross",
        Size = UDim2.fromOffset(24, 24),
        BackgroundTransparency = 1,
        Image = (self.ResolveIcon ~= nil and self:ResolveIcon("crosshair")) or "",
        ImageColor3 = self._cursorCrossColor or Color3.new(1, 1, 1),
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 1,
        Parent = screenGui,
    })
    local icon = create("ImageLabel", {
        Name = "Icon",
        Size = self._cursorIconSize or UDim2.fromOffset(32, 32),
        BackgroundTransparency = 1,
        Image = (self._cursorIcon ~= nil and self:ResolveIcon(self._cursorIcon)) or "",
        ImageColor3 = self._cursorIconColor or Color3.new(1, 1, 1),
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 2,
        Parent = screenGui,
    })
    self._cursorCrossLabel = cross
    self._cursorIconLabel = icon

    trackConnection(RunService.RenderStepped, function()
        local pos = UserInputService:GetMouseLocation()
        cross.Position = UDim2.fromOffset(pos.X - cross.AbsoluteSize.X / 2, pos.Y - cross.AbsoluteSize.Y / 2)
        icon.Position = UDim2.fromOffset(pos.X - icon.AbsoluteSize.X / 2, pos.Y - icon.AbsoluteSize.Y / 2)
        -- the icon layer replaces the crosshair while it has an image
        cross.ImageTransparency = (icon.Image ~= "") and 1 or 0
    end)
    return screenGui
end

function EZ:_applyCursor()
    local gui2 = self._cursorEnabled and self:_ensureCursorGui() or nil
    if gui2 then
        local cross = self._cursorCrossLabel
        local icon = self._cursorIconLabel
        if cross then
            cross.ImageColor3 = self._cursorCrossColor or Color3.new(1, 1, 1)
        end
        if icon then
            icon.Image = (self._cursorIcon ~= nil and self:ResolveIcon(self._cursorIcon)) or ""
            icon.ImageColor3 = self._cursorIconColor or Color3.new(1, 1, 1)
            icon.Size = self._cursorIconSize or UDim2.fromOffset(32, 32)
        end
    end
end

function EZ:SetCursorIcon(asset)
    self:ChangeIcon(asset)
end

function EZ:SetCursorEnabled(on)
    self._cursorEnabled = on == true
    if self._cursorEnabled then
        if not self._cursorIcon and not self._cursorCrossColor then
            -- nothing to show yet; nudge once instead of silently doing nothing
            pcall(function()
                self:Notify({
                    Title = "EZ",
                    Content = "Set a cursor first: EZ.Cursor:ChangeIcon(\"crosshair\")",
                    Duration = 3,
                    Type = "warning",
                })
            end)
        end
        self:_applyCursor()
    else
        if self._cursorGui then
            pcall(function() self._cursorGui:Destroy() end)
            self._cursorGui = nil
            self._cursorCrossLabel = nil
            self._cursorIconLabel = nil
        end
    end
end

-- v4.0: Obsidian-style cursor API (two layers: crosshair + optional icon).
EZ.Cursor = {}
function EZ.Cursor:ChangeCrossColor(color)
    EZ._cursorCrossColor = color
    if EZ._cursorCrossLabel then EZ._cursorCrossLabel.ImageColor3 = color end
end
function EZ.Cursor:ResetCross()
    EZ._cursorCrossColor = Color3.new(1, 1, 1)
    if EZ._cursorCrossLabel then EZ._cursorCrossLabel.ImageColor3 = Color3.new(1, 1, 1) end
end
function EZ.Cursor:ChangeIcon(iconRef)
    if type(iconRef) == "number" then iconRef = "rbxassetid://" .. iconRef end
    if iconRef == nil or iconRef == "" then
        EZ._cursorIcon = nil
    else
        EZ._cursorIcon = iconRef
    end
    if EZ._cursorEnabled then EZ:_applyCursor() end
end
function EZ.Cursor:ChangeIconColor(color)
    EZ._cursorIconColor = color
    if EZ._cursorIconLabel then EZ._cursorIconLabel.ImageColor3 = color end
end
function EZ.Cursor:ChangeIconSize(size)
    EZ._cursorIconSize = size
    if EZ._cursorIconLabel then EZ._cursorIconLabel.Size = size end
end
function EZ.Cursor:ResetIcon()
    EZ._cursorIcon = nil
    EZ._cursorIconColor = Color3.new(1, 1, 1)
    EZ._cursorIconSize = UDim2.fromOffset(32, 32)
    if EZ._cursorEnabled then EZ:_applyCursor() end
end
function EZ.Cursor:ResetCursor()
    EZ.Cursor:ResetCross()
    EZ.Cursor:ResetIcon()
end

-- Curated font families (Settings ▸ Font Face). Enum-backed fonts resolve
-- through Font.fromEnum (always valid); extras use their documented
-- rbxasset family JSONs. Every apply falls back to the enum font if the
-- Font object is rejected, so a bad path can never silently do nothing.
EZ.FONT_FAMILIES = {
    "Default", "BuilderSans", "BuilderSansMedium", "BuilderSansBold",
    "Gotham", "GothamMedium", "GothamBold", "GothamBlack",
    "Roboto", "RobotoMono", "Code", "SourceSans", "Jura", "Montserrat", "Oswald",
}
local FONT_SOURCES = {
    Default           = { enum = Enum.Font.Gotham },
    BuilderSans       = { family = "BuilderSans", enum = Enum.Font.Gotham },
    BuilderSansMedium = { family = "BuilderSansMedium", enum = Enum.Font.GothamMedium },
    BuilderSansBold   = { family = "BuilderSansBold", enum = Enum.Font.GothamBold },
    Gotham            = { enum = Enum.Font.Gotham },
    GothamMedium      = { enum = Enum.Font.GothamMedium },
    GothamBold        = { enum = Enum.Font.GothamBold },
    GothamBlack       = { enum = Enum.Font.GothamBlack },
    Roboto            = { family = "Roboto", enum = Enum.Font.Roboto },
    RobotoMono        = { family = "RobotoMono", enum = Enum.Font.RobotoMono },
    Code              = { enum = Enum.Font.Code },
    SourceSans        = { enum = Enum.Font.SourceSans },
    Jura              = { family = "Jura" },
    Montserrat        = { family = "Montserrat" },
    Oswald            = { family = "Oswald" },
}

local function applyFontTo(inst, fontObj, enumFont)
    if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
        if fontObj then
            local ok = pcall(function() inst.TextFont = fontObj end)
            if not ok and enumFont then
                inst.Font = enumFont
            end
        elseif enumFont then
            inst.Font = enumFont
        else
            inst.Font = Enum.Font.Gotham
        end
    end
end

-- Global font face. Accepts a family name from EZ.FONT_FAMILIES, an
-- Enum.Font item (legacy path), or nil/"Default" to reset to the base look.
function EZ:SetFont(font)
    local fontObj, enumFont
    if typeof(font) == "EnumItem" and font.EnumType == Enum.Font then
        enumFont = font
    elseif type(font) == "string" and font ~= "" then
        local src = FONT_SOURCES[font]
        if src == nil and font ~= "Default" then
            src = { family = font } -- allow raw family names too
        end
        if src then
            enumFont = src.enum
            if src.family then
                -- extras (BuilderSans, Jura, ...) only exist as family JSONs
                local ok, f = pcall(function()
                    return Font.new("rbxasset://fonts/families/" .. src.family .. ".json")
                end)
                if ok and f then fontObj = f end
            elseif enumFont ~= nil and Font.fromEnum then
                -- enum-backed fonts: fromEnum is guaranteed-valid
                local ok, f = pcall(function() return Font.fromEnum(enumFont) end)
                if ok and f then fontObj = f end
            end
        end
    end
    self._fontOverride = fontObj
    self._fontEnumOverride = enumFont

    local containers = {}
    if gui and gui.Parent then table.insert(containers, gui) end
    if notifGui and notifGui.Parent then table.insert(containers, notifGui) end
    for _, container in containers do
        applyFontTo(container, fontObj, enumFont)
        for _, d in container:GetDescendants() do
            applyFontTo(d, fontObj, enumFont)
        end
    end
    -- the QuickBar dock lives in its own ScreenGui
    pcall(function()
        local hui = (gethui and gethui()) or Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if hui then
            for _, g in hui:GetChildren() do
                if g.Name == "EZQuickBar" then
                    applyFontTo(g, fontObj, enumFont)
                    for _, d in g:GetDescendants() do
                        applyFontTo(d, fontObj, enumFont)
                    end
                end
            end
        end
    end)
end

-- Live corner radius. 14 = the library's designed radius (per-element sizes);
-- anything else overrides every registered corner. Roblox clamps the radius
-- to half an element's shortest side, so small controls stay safe at 20.
function EZ:SetCornerRadius(n)
    n = clamp(tonumber(n) or 14, 0, 20)
    self._cornerRadiusOverride = (n ~= 14) and n or nil
    local alive = {}
    for _, entry in self._cornerRegistry or {} do
        local inst = entry.inst
        if inst and inst.Parent then
            inst.CornerRadius = UDim.new(0, self._cornerRadiusOverride or entry.fallback)
            table.insert(alive, entry)
        end
    end
    self._cornerRegistry = alive
end

-- ~~
-- PANIC (universal kill switch, dock tile + EZ:SetPanic)
-- ON: snapshots every toggle's state, switches them all off, and deactivates
-- every active keybind. OFF: restores the snapshotted states.
-- ~~
function EZ:SetPanic(on)
    on = on == true
    if self._panic == on then return end
    self._panic = on
    self.Flags._EZPanic = on

    if on then
        self._panicSnapshot = { toggles = {}, binds = {} }
        for id, el in self._elements do
            if el._type == "Toggle" and el.Get and el.Set then
                local v = el:Get() == true
                self._panicSnapshot.toggles[id] = v
                if v then el:Set(false) end
            elseif el._type == "Keybind" and el.IsActive and el.SetActive and el:IsActive() then
                self._panicSnapshot.binds[id] = true
                el:SetActive(false)
            end
        end
    else
        local snap = self._panicSnapshot or { toggles = {}, binds = {} }
        for id, el in self._elements do
            if el._type == "Toggle" and el.Set and snap.toggles[id] == true then
                el:Set(true)
            elseif el._type == "Keybind" and el.SetActive and snap.binds[id] == true then
                el:SetActive(true)
            end
        end
        self._panicSnapshot = nil
    end

    fireListeners("_EZPanic", on)

    -- recolor every dock's panic tile (all windows share the panic state)
    for _, tile in self._panicTiles or {} do
        pcall(function()
            if tile.frame and tile.frame.Parent then
                tile.frame.BackgroundColor3 = on and self.Theme.Error or self.Theme.Surface
                tile.frame.BackgroundTransparency = on and 0 or 0.2
                if tile.icon then
                    tile.icon.ImageColor3 = on and Color3.new(1, 1, 1) or self.Theme.TextDim
                    if tile.icon:IsA("TextLabel") then
                        tile.icon.TextColor3 = on and Color3.new(1, 1, 1) or self.Theme.TextDim
                    end
                end
            end
        end)
    end

    pcall(function()
        self:Notify({
            Title = on and "Panic enabled" or "Panic disabled",
            Content = on and "All toggles and keybinds suspended." or "Previous states restored.",
            Duration = 2,
            Type = on and "warning" or "success",
        })
    end)
end

function EZ:IsPanic()
    return self._panic == true
end

function EZ:TogglePanic()
    self:SetPanic(not self._panic)
end

-- ~~
-- WATERMARK / HUD
-- ~~
function EZ:CreateWatermark(opts)
    opts = opts or {}
    local theme = self.Theme

    -- kill old
    if self._watermark then
        pcall(function() self._watermark:Destroy() end)
    end

    local frame = create("Frame", {
        Name = "EZWatermark",
        Size = UDim2.new(0, 200, 0, 26),
        Position = opts.Position or UDim2.new(0, 12, 0, 12),
        BackgroundColor3 = theme.Base,
        BackgroundTransparency = 0.15,
        BorderSizePixel = 0,
        AutomaticSize = Enum.AutomaticSize.X,
        ZIndex = 200,
        Parent = gui
    })
    addCorner(frame, 6)
    addStroke(frame, theme.Accent, 1, 0.4)

    create("UIPadding", {
        PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10),
        Parent = frame,
    })

    local lbl = create("TextLabel", {
        Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        Text = opts.Text or "EZ | {fps} fps | {ping} ms",
        TextColor3 = theme.Text,
        TextSize = 11,
        Font = Enum.Font.Code,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 201,
        Parent = frame,
    })

    self._watermark = frame

    -- live update
    local template = opts.Text or "EZ | {fps} fps | {ping} ms"
    local lastTick = tick()
    local frames = 0
    local fps = 60

    local stats = game:GetService("Stats")
    local lp = Players.LocalPlayer

    local conn = trackConnection(RunService.RenderStepped, function()
        -- Sleep while hidden: skip the per-frame counting and the gsub-heavy
        -- template rebuild, and reset the counters so the first update after
        -- re-showing does not divide frames by the whole hidden duration.
        if not frame.Visible or not frame.Parent then
            frames = 0
            lastTick = tick()
            return
        end
        frames = frames + 1
        local now = tick()
        -- The string is rebuilt with several gsub passes and only changes on
        -- this cadence, so write it twice per second instead of every frame.
        if now - lastTick < 0.5 then return end
        fps = math.floor(frames / (now - lastTick))
        frames = 0
        lastTick = now

        local ping = 0
        pcall(function()
            ping = math.floor(stats.Network.ServerStatsItem["Data Ping"]:GetValue())
        end)

        local txt = template
        txt = txt:gsub("{fps}", tostring(fps))
        txt = txt:gsub("{ping}", tostring(ping))
        txt = txt:gsub("{time}", os.date("%H:%M:%S"))
        txt = txt:gsub("{user}", lp and lp.Name or "?")
        txt = txt:gsub("{place}", tostring(game.PlaceId))

        -- substitute flags
        -- NOTE: deliberately no %% escaping here - gsub applies % templates
        -- to STRING replacements only; a function's return value goes in
        -- verbatim. Escaping would visibly corrupt values ("50%" -> "50%%").
        txt = txt:gsub("{flag:([%w_]+)}", function(flag)
            local v = EZ.Flags[flag]
            if v == nil then return "?" end
            return tostring(v)
        end)

        lbl.Text = txt
    end)

    local watermark = {}
    function watermark:SetText(t) template = t end
    function watermark:SetPosition(p) frame.Position = p end
    function watermark:Destroy()
        -- disconnectConnection also drops it from EZ._connections
        disconnectConnection(conn)
        pcall(function() frame:Destroy() end)
        EZ._watermark = nil
    end
    function watermark:Show() frame.Visible = true end
    function watermark:Hide() frame.Visible = false end

    return watermark
end

-- ~~
-- KEYBIND MENU (Obsidian-parity floating bind list)
-- Lists every AddKeybind across all windows with its live combo, an active
-- dot for Toggle binds, drag-to-move, and persists position + visibility to
-- EZKeybindMenu.txt so it reopens exactly where it was.
-- ~~
local KEYBIND_MENU_FILE = "EZKeybindMenu.txt"
local KEYBIND_MENU_ANCHOR_FILE = "EZKeybindMenuAnchor.txt"

-- named screen corners the keybind menu can start in (Settings > Menu);
-- a dragged position still wins until the anchor is re-picked
local KEYBIND_MENU_ANCHORS = {
    ["Top Left"] = true,
    ["Top Right"] = true,
    ["Bottom Left"] = true,
    ["Bottom Right"] = true,
}

local function keybindMenuAnchorPosition(name, size)
    local s = getScreenSize()
    local pad = 12
    size = size and size.X > 40 and size or Vector2.new(230, 120)
    local x = string.find(name, "Right", 1, true)
        and math.max(pad, s.X - size.X - pad) or pad
    local y = string.find(name, "Bottom", 1, true)
        and math.max(pad, s.Y - size.Y - pad) or pad
    return UDim2.fromOffset(x, y)
end

function EZ:CreateKeybindMenu()
    -- Guard on the FRAME's parent, not the menu table: `.Parent` on the
    -- table was always nil, so every Show/Toggle spawned a brand-new menu
    -- and orphaned the old one (ghost menus stacking on screen).
    if self._keybindMenu and self._keybindMenu.frame and self._keybindMenu.frame.Parent then
        return self._keybindMenu
    end

    local theme = self.Theme
    local W = 230

    -- restore persisted geometry; a fresh start (no drag saved, or an anchor
    -- re-picked in Settings) opens at the configured screen corner instead
    local savedPos
    local startVisible = false
    pcall(function()
        if isfile and readfile and isfile(KEYBIND_MENU_FILE) then
            local raw = readfile(KEYBIND_MENU_FILE)
            if type(raw) == "string" then
                local px, py = raw:match("pos=(%-?%d+),(%-?%d+)")
                if px and py then savedPos = UDim2.fromOffset(tonumber(px), tonumber(py)) end
                startVisible = raw:match("visible=(1)") == "1"
            end
        end
    end)
    if not savedPos then
        savedPos = keybindMenuAnchorPosition(self:GetKeybindMenuAnchor(), Vector2.new(W, 120))
    end
    local frame = create("Frame", {
        Name = "EZKeybindMenu",
        Size = UDim2.new(0, W, 0, 30),
        AutomaticSize = Enum.AutomaticSize.Y,
        Position = savedPos,
        BackgroundColor3 = theme.Base,
        BackgroundTransparency = 0.05,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 180,
        Parent = gui
    })
    addCorner(frame, 10)
    addStroke(frame, theme.Border, 1, 0.35)

    local menu = { frame = frame, _conns = {}, _listeners = {} }
    self._keybindMenu = menu

    local function saveState()
        pcall(function()
            if writefile then
                writefile(KEYBIND_MENU_FILE,
                    ("pos=%d,%d\nvisible=%d"):format(
                        math.floor(frame.Position.X.Offset),
                        math.floor(frame.Position.Y.Offset),
                        frame.Visible and 1 or 0))
            end
        end)
    end

    -- header / drag handle
    local header = create("TextButton", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 181,
        Parent = frame
    })
    create("TextLabel", {
        Size = UDim2.new(1, -40, 1, 0),
        Position = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        Text = "Keybinds",
        TextColor3 = theme.TextDim,
        TextSize = 11,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 182,
        Parent = header
    })
    local closeBtn = create("TextButton", {
        Size = UDim2.new(0, 18, 0, 18),
        Position = UDim2.new(1, -22, 0.5, -9),
        BackgroundTransparency = 1,
        Text = "",
        ZIndex = 182,
        Parent = header
    })
    create("ImageLabel", {
        Size = UDim2.new(0, 10, 0, 10),
        Position = UDim2.new(0.5, -5, 0.5, -5),
        BackgroundTransparency = 1,
        Image = "rbxassetid://110786993356448",
        ImageColor3 = theme.TextMuted,
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 183,
        Parent = closeBtn
    })

    local rows = create("Frame", {
        Name = "Rows",
        Size = UDim2.new(1, 0, 0, 0),
        -- CRITICAL: sits below the 26px header. Without this offset the rows
        -- rendered ON TOP of the header - row 1 looked like garbled text
        -- ("Keybinds" title mashed into the first keybind's label).
        Position = UDim2.new(0, 0, 0, 26),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        ZIndex = 181,
        Parent = frame,
        Children = {
            create("UIListLayout", {
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 2),
            }),
            create("UIPadding", {
                PaddingTop = UDim.new(0, 2),
                PaddingBottom = UDim.new(0, 8),
                PaddingLeft = UDim.new(0, 8),
                PaddingRight = UDim.new(0, 8),
            }),
        }
    })

    local function disconnectAll()
        for _, c in menu._conns do
            pcall(function() c:Disconnect() end)
        end
        table.clear(menu._conns)
        for _, l in menu._listeners do
            pcall(function() EZ:OffFlagChanged(l.id, l.fn) end)
        end
        table.clear(menu._listeners)
    end

    local function comboOf(el)
        local k = el.Get and el.Get()
        if typeof(k) ~= "EnumItem" then return "?" end
        local m = el.GetModifiers and el:GetModifiers() or {}
        local parts = {}
        if m.Ctrl then table.insert(parts, "Ctrl") end
        if m.Alt then table.insert(parts, "Alt") end
        if m.Shift then table.insert(parts, "Shift") end
        if k == Enum.KeyCode.Unknown then
            table.insert(parts, "?")
        elseif k.EnumType == Enum.UserInputType then
            table.insert(parts, (k.Name:gsub("^MouseButton", "M")))
        else
            table.insert(parts, k.Name)
        end
        return table.concat(parts, "+")
    end

    function menu:_refresh()
        -- a queued refresh can land after the frame was destroyed
        if not rows.Parent then return end
        disconnectAll()

        for _, child in rows:GetChildren() do
            if child:IsA("Frame") then child:Destroy() end
        end

        -- group rows by the window that owns each keybind (single-window
        -- hosts see no headers); within a group, sorted by id
        local groups, order = {}, {}
        for id, el in EZ._elements do
            if el._type == "Keybind" then
                local g = el._windowTitle or "Keybinds"
                if not groups[g] then
                    groups[g] = {}
                    table.insert(order, g)
                end
                table.insert(groups[g], { id = id, el = el })
            end
        end
        table.sort(order, function(a, b) return a < b end)
        for _, g in order do
            table.sort(groups[g], function(a, b) return a.id < b.id end)
        end

        local rowIdx = 0
        local multiWindow = #order > 1
        for _, g in order do
            if multiWindow then
                rowIdx += 1
                create("TextLabel", {
                    LayoutOrder = rowIdx,
                    Size = UDim2.new(1, 0, 0, 18),
                    BackgroundTransparency = 1,
                    Text = tostring(g),
                    TextColor3 = theme.TextMuted,
                    TextSize = 10,
                    Font = Enum.Font.GothamBold,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ZIndex = 183,
                    Parent = rows
                })
            end
            for _, entry in groups[g] do
                rowIdx += 1
                local el = entry.el
                local id = entry.id
                local row = create("Frame", {
                    LayoutOrder = rowIdx,
                    Size = UDim2.new(1, 0, 0, 22),
                    BackgroundTransparency = 1,
                    ClipsDescendants = true,
                    ZIndex = 182,
                    Parent = rows
                })
            local isActive = el.IsActive and el:IsActive()
            -- v4.2: tap-friendly toggle checkbox in the menu (mobile parity;
            -- EZ.ShowToggleFrameInKeybinds = false hides it)
            if el.GetMode and el:GetMode() == "Toggle" and EZ.ShowToggleFrameInKeybinds ~= false then
                local box = create("TextButton", {
                    Size = UDim2.new(0, 14, 0, 14),
                    Position = UDim2.new(1, -114, 0.5, -7),
                    BackgroundColor3 = isActive and theme.Accent or theme.Surface,
                    BackgroundTransparency = isActive and 0 or 0.35,
                    Text = "",
                    BorderSizePixel = 0,
                    AutoButtonColor = false,
                    ZIndex = 183,
                    Parent = row,
                })
                addCorner(box, 3)
                addStroke(box, theme.Border, 1, 0.5)
                if isActive then
                    local check = EZ:ResolveIcon("check")
                    if check then
                        create("ImageLabel", {
                            Size = UDim2.new(1, -4, 1, -4),
                            Position = UDim2.new(0, 2, 0, 2),
                            BackgroundTransparency = 1,
                            Image = check,
                            ImageColor3 = Color3.new(1, 1, 1),
                            ScaleType = Enum.ScaleType.Fit,
                            ZIndex = 184,
                            Parent = box,
                        })
                    end
                end
                box.MouseButton1Click:Connect(function()
                    if el.SetActive and el.IsActive then
                        el:SetActive(not el:IsActive())
                    end
                end)
            end
            if el.GetMode and el:GetMode() == "Toggle" then
                create("Frame", {
                    Size = UDim2.new(0, 6, 0, 6),
                    Position = UDim2.new(0, 0, 0.5, -3),
                    BackgroundColor3 = isActive and theme.Success or theme.TextMuted,
                    BackgroundTransparency = isActive and 0 or 0.4,
                    BorderSizePixel = 0,
                    ZIndex = 183,
                    Parent = row,
                    Children = { create("UICorner", { CornerRadius = UDim.new(1, 0) }) }
                })
            end
            -- Cap the string in Lua instead of relying on TextTruncate:
            -- some executors render truncated labels as garbage (only the
            -- rows that actually truncate glitched). 16 chars fits the
            -- 104px label box at TextSize 11.
            local idText = tostring(id)
            if #idText > 16 then
                idText = idText:sub(1, 15) .. "…"
            end
            local labelW = (el.GetMode and el:GetMode() == "Toggle" and EZ.ShowToggleFrameInKeybinds ~= false) and -128 or -110
            create("TextLabel", {
                Size = UDim2.new(1, labelW, 1, 0),
                Position = UDim2.new(0, 12, 0, 0),
                BackgroundTransparency = 1,
                Text = idText,
                TextColor3 = theme.Text,
                TextSize = 11,
                Font = Enum.Font.GothamMedium,
                TextXAlignment = Enum.TextXAlignment.Left,
                ZIndex = 183,
                Parent = row
            })
            local comboText = comboOf(el)
            if #comboText > 12 then
                comboText = comboText:sub(1, 11) .. "…"
            end
            local comboChip = create("TextLabel", {
                Size = UDim2.new(0, 86, 0, 16),
                Position = UDim2.new(1, -90, 0.5, -8),
                BackgroundColor3 = theme.Surface,
                BackgroundTransparency = 0.4,
                Text = comboText,
                TextColor3 = theme.Accent,
                TextSize = 10,
                Font = Enum.Font.Code,
                TextXAlignment = Enum.TextXAlignment.Right,
                TextTruncate = Enum.TextTruncate.AtEnd,
                ZIndex = 183,
                Parent = row
            })
            addCorner(comboChip, 4)
            create("UIPadding", {
                PaddingRight = UDim.new(0, 6),
                Parent = comboChip,
            })

            -- live refresh while open; bounded by the number of keybinds
            local fn = function() task.defer(function() menu:_refresh() end) end
            EZ:OnFlagChanged(id, fn)
            table.insert(menu._listeners, { id = id, fn = fn })
            end
        end
    end

    function menu:Destroy()
        disconnectAll()
        pcall(function() frame:Destroy() end)
        if EZ._keybindMenu == menu then EZ._keybindMenu = nil end
    end

    function menu:SetAnchor(name)
        -- move the live menu to a named screen corner (Settings > Menu)
        if not KEYBIND_MENU_ANCHORS[name] then return end
        frame.Position = keybindMenuAnchorPosition(name, frame.AbsoluteSize)
        saveState()
    end

    function menu:SetVisible(v)
        v = v == true
        if v and not frame.Visible then
            menu:_refresh()
        end
        frame.Visible = v
        saveState()
    end

    trackConnection(closeBtn.MouseButton1Click, function()
        menu:SetVisible(false)
    end)

    -- drag by header
    local dragging, dragStart, dragOrigin = false, nil, nil
    local function beginDrag(inp)
        dragging = true
        dragStart = Vector2.new(inp.Position.X, inp.Position.Y)
        dragOrigin = frame.AbsolutePosition
    end
    trackConnection(header.InputBegan, function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch then
            beginDrag(inp)
        end
    end)
    trackConnection(UserInputService.InputChanged, function(inp)
        if not dragging then return end
        if inp.UserInputType ~= Enum.UserInputType.MouseMovement
            and inp.UserInputType ~= Enum.UserInputType.Touch then return end
        -- clamp so at least 30px of the menu stays reachable on every side
        local screen = getScreenSize()
        local size = frame.AbsoluteSize
        local target = dragOrigin + (Vector2.new(inp.Position.X, inp.Position.Y) - dragStart)
        local nx = clamp(target.X, -(size.X - 30), math.max(0, screen.X - 30))
        local ny = clamp(target.Y, 0, math.max(0, screen.Y - 30))
        frame.Position = UDim2.fromOffset(nx, ny)
    end)
    trackConnection(UserInputService.InputEnded, function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch then
            if dragging then
                dragging = false
                saveState()
            end
        end
    end)

    if startVisible then
        menu:SetVisible(true)
    end

    return menu
end

function EZ:ShowKeybindMenu()
    local m = self:CreateKeybindMenu()
    m:SetVisible(true)
end

function EZ:HideKeybindMenu()
    if self._keybindMenu then
        self._keybindMenu:SetVisible(false)
    end
end

function EZ:ToggleKeybindMenu()
    local m = self:CreateKeybindMenu()
    m:SetVisible(not m.frame.Visible)
end

-- Where the keybind menu starts on screen. Default "Top Right". A dragged
-- position still persists and wins until a different anchor is picked, which
-- moves the live menu immediately and forgets the dragged spot.
function EZ:SetKeybindMenuAnchor(name)
    if type(name) ~= "string" or not KEYBIND_MENU_ANCHORS[name] then return false end
    self._keybindMenuAnchor = name
    pcall(function()
        if writefile then writefile(KEYBIND_MENU_ANCHOR_FILE, name) end
    end)
    -- move the live menu first (it saves its new pose), THEN strip the
    -- persisted drag position so the anchor wins again on next launch
    if self._keybindMenu and self._keybindMenu.SetAnchor then
        pcall(function() self._keybindMenu:SetAnchor(name) end)
    end
    pcall(function()
        if isfile and readfile and isfile(KEYBIND_MENU_FILE) then
            local raw = readfile(KEYBIND_MENU_FILE)
            local vis = tostring(raw):match("visible=(1)") == "1"
            if writefile then writefile(KEYBIND_MENU_FILE, "visible=" .. (vis and 1 or 0)) end
        end
    end)
    return true
end

function EZ:GetKeybindMenuAnchor()
    -- cached after first read; falls back to Top Right for fresh installs
    if not self._keybindMenuAnchor then
        local name = "Top Right"
        pcall(function()
            if isfile and readfile and isfile(KEYBIND_MENU_ANCHOR_FILE) then
                local raw = readfile(KEYBIND_MENU_ANCHOR_FILE)
                if type(raw) == "string" and KEYBIND_MENU_ANCHORS[raw] then
                    name = raw
                end
            end
        end)
        self._keybindMenuAnchor = name
    end
    return self._keybindMenuAnchor
end

-- ~~
-- HAPTIC FEEDBACK
-- Gamepad rumble through HapticService. Roblox exposes no vibration API for
-- phones, so this is a no-op unless a controller is actually connected.
-- ~~
function EZ:Haptic(strength)
    -- strength: "light" | "medium" | "heavy"
    strength = strength or "light"
    local HapticService = game:GetService("HapticService")
    pcall(function()
        local motor = Enum.VibrationMotor.Large
        local amp = strength == "heavy" and 1 or strength == "medium" and 0.6 or 0.3
        for _, gp in pairs(Enum.UserInputType:GetEnumItems()) do
            if tostring(gp):find("Gamepad") then
                pcall(function()
                    -- skip slots with nothing plugged in rather than firing
                    -- SetMotor at every gamepad index on every call
                    local supported = true
                    pcall(function()
                        supported = HapticService:IsVibrationSupported(gp)
                    end)
                    if not supported then return end
                    HapticService:SetMotor(gp, motor, amp)
                    task.delay(0.05, function()
                        pcall(function() HapticService:SetMotor(gp, motor, 0) end)
                    end)
                end)
            end
        end
    end)
end

-- ~~
-- ANTI-AFK
-- Roblox kicks after roughly 20 minutes without input. The Idled event fires
-- just before that; answering it with a virtual controller press resets the
-- idle timer. VirtualUser is a plain Roblox service, so this works on any
-- executor; if a game blocks it, the fallback disables the game's Idled
-- connections directly (sUNC getconnections).
-- ~~
function EZ:SetAntiAFK(on)
    on = on == true
    if self._destroyed or self._antiAFK == on then return on end
    self._antiAFK = on

    if self._antiAFKConn then
        self._antiAFKConn:Disconnect()
        self._antiAFKConn = nil
    end

    if not on then
        -- fallback mode muted the game's Idled listeners; restore them
        for _, c in (self._antiAFKDisabled or {}) do
            pcall(function() c:Enable() end)
        end
        self._antiAFKDisabled = nil
    end

    if on then
        local okVu, VirtualUser = pcall(function()
            return game:GetService("VirtualUser")
        end)
        self._antiAFKConn = trackConnection(Players.LocalPlayer.Idled, function()
            if not self._antiAFK then return end
            self._antiAFKCount += 1
            local handled = false
            if VirtualUser then
                handled = pcall(function()
                    VirtualUser:CaptureController()
                    VirtualUser:ClickButton2(Vector2.new())
                end)
            end
            if not handled then
                -- fallback: mute the game's own idle listeners so the kick
                -- logic never runs (the sUNC anti-afk approach). Ours goes
                -- first; every muted connection is re-enabled on disable.
                pcall(function()
                    local toMute = {}
                    for _, c in getconnections(Players.LocalPlayer.Idled) do
                        toMute[#toMute + 1] = c
                    end
                    if self._antiAFKConn then
                        self._antiAFKConn:Disconnect()
                        self._antiAFKConn = nil
                    end
                    for _, c in toMute do
                        pcall(function()
                            c:Disable()
                            self._antiAFKDisabled[#self._antiAFKDisabled + 1] = c
                        end)
                    end
                end)
            end
            if self._antiAFKCount == 1 and self.Notify then
                pcall(self.Notify, self, {
                    Title = "Anti-AFK",
                    Content = "idle kick prevented — you can leave this open for hours",
                    Type = "success",
                    Duration = 3,
                })
            end
        end)
    end

    if self.Notify then
        pcall(self.Notify, self, {
            Title = "Anti-AFK",
            Content = on and "enabled — idle kick prevented" or "disabled",
            Type = on and "success" or "info",
            Duration = 2,
        })
    end
    return on
end

function EZ:IsAntiAFK()
    return self._antiAFK == true
end

-- ~~
-- PUBLIC UTILITIES (v4.1)
-- Obsidian-parity helpers: icon application, signal tracking, safe callbacks,
-- text measuring, colour math, and a download+cache ImageManager.
-- ~~
function EZ:GetIcon(ref)
    return self:ResolveIcon(ref)
end

function EZ:ApplyLucideIcon(imageGui, ref, rotation)
    if typeof(imageGui) ~= "Instance" then return false end
    if not (imageGui:IsA("ImageLabel") or imageGui:IsA("ImageButton")) then return false end
    local asset = self:ResolveIcon(ref)
    if not asset then return false end
    imageGui.Image = asset
    if type(rotation) == "number" then imageGui.Rotation = rotation end
    return true
end

-- register an existing connection for disconnect-on-EZ:Destroy
function EZ:GiveSignal(conn)
    if typeof(conn) ~= "RBXScriptConnection" then return conn end
    table.insert(self._connections, conn)
    local owner = self._connectionOwner
    if owner and owner._connections then
        table.insert(owner._connections, conn)
    end
    return conn
end

function EZ:SafeCallback(fn, ...)
    return safecall("SafeCallback", fn, ...)
end

function EZ:GetTextBounds(text, font, size, maxWidth)
    local TextService = game:GetService("TextService")
    local ok, bounds = pcall(function()
        return TextService:GetTextSize(
            tostring(text or ""),
            tonumber(size) or 14,
            font or Enum.Font.Gotham,
            Vector2.new(maxWidth or 1e6, 1e6)
        )
    end)
    if ok and bounds then return bounds.X, bounds.Y end
    return 0, 0
end

function EZ:GetBetterColor(color, amount)
    if typeof(color) ~= "Color3" then return color end
    local h, s, v = Color3.toHSV(color)
    v = clamp(v + (tonumber(amount) or 0), 0, 1)
    return Color3.fromHSV(h, s, v)
end
function EZ:GetLighterColor(color) return self:GetBetterColor(color, 0.08) end
function EZ:GetDarkerColor(color) return self:GetBetterColor(color, -0.08) end

-- ImageManager: download an image once, serve the cached custom asset, fall
-- back to the provided Roblox asset id when getcustomasset/filesystem are
-- unavailable. AddAsset(name, assetId, url?, forceRedownload?)
EZ.ImageManager = { _cache = {}, _folder = "EZImageCache" }

local function sanitizeAssetName(name)
    return (tostring(name or ""):gsub("[^%w_%-]", "_"))
end

function EZ.ImageManager.DownloadAsset(name, forceRedownload)
    name = sanitizeAssetName(name)
    local meta = EZ.ImageManager._cache[name]
    if not meta or not meta.url then return nil end
    local path = ("%s/%s.%s"):format(EZ.ImageManager._folder, name, meta.ext or "png")

    local haveFile = false
    pcall(function() haveFile = isfile and isfile(path) == true end)
    if haveFile and not forceRedownload then
        local ok, asset = pcall(function() return getcustomasset(path) end)
        if ok and asset then
            meta.custom = asset
            return asset
        end
    end

    local okDl, data = pcall(function() return game:HttpGet(meta.url) end)
    if not okDl or type(data) ~= "string" or data == "" then return nil end
    pcall(function()
        if makefolder and not (isfolder and isfolder(EZ.ImageManager._folder)) then
            makefolder(EZ.ImageManager._folder)
        end
        writefile(path, data)
    end)
    local ok, asset = pcall(function() return getcustomasset(path) end)
    if ok and asset then
        meta.custom = asset
        return asset
    end
    return nil
end

function EZ.ImageManager.AddAsset(name, assetId, url, forceRedownload)
    name = sanitizeAssetName(name)
    if name == "" then return nil end
    local ext = "png"
    if type(url) == "string" then
        local e = url:match("%.(%w+)$")
        if e then ext = e end
    end
    EZ.ImageManager._cache[name] = { id = tonumber(assetId), url = url, ext = ext }
    if url and getcustomasset ~= nil then
        EZ.ImageManager.DownloadAsset(name, forceRedownload)
    end
    return EZ.ImageManager.GetAsset(name)
end

function EZ.ImageManager.GetAsset(name)
    name = sanitizeAssetName(name)
    local meta = EZ.ImageManager._cache[name]
    if not meta then return nil end
    if meta.custom then return meta.custom end
    if meta.id then return "rbxassetid://" .. meta.id end
    return nil
end

-- ~~
-- LOADING SCREEN (v4.2)
-- Modal multi-stage loader: rotating icon, title, message + description,
-- progress bar with step counter, optional sidebar with EVERY element
-- builder, and an error page with footer-style buttons.
-- The sidebar borrows an invisible host window's section internally — that
-- is how it gets the full element set without duplicating the builders.
-- ~~
function EZ:CreateLoading(opts)
    opts = opts or {}
    local ez = self -- methods below take the handle as `self`; EZ lives here
    local theme = self.Theme
    local title = opts.Title or "Loading"
    local totalSteps = math.max(0, tonumber(opts.TotalSteps) or 0)
    local currentStep = 0
    local spinTime = tonumber(opts.IconTweenTime) or 1.6

    if self._loading then pcall(function() self._loading:Destroy() end) end

    local parent = (gethui and gethui()) or Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not parent then return nil end

    local screen = create("ScreenGui", {
        Name = "EZLoading",
        DisplayOrder = 20000,
        IgnoreGuiInset = true,
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = parent,
    })
    create("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = theme.Base,
        BackgroundTransparency = 0.25,
        BorderSizePixel = 0,
        Active = true, -- modal: swallow clicks behind the overlay
        ZIndex = 1,
        Parent = screen,
    })

    local cardW = 380
    local card = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(cardW, 172),
        BackgroundColor3 = theme.Surface,
        BackgroundTransparency = 0.05,
        BorderSizePixel = 0,
        ZIndex = 2,
        Parent = screen,
    })
    addCorner(card, 12)
    addStroke(card, theme.Border, 1, 0.4)

    local mainBox = create("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        ZIndex = 3,
        Parent = card,
    })

    local iconLabel = create("ImageLabel", {
        Size = UDim2.fromOffset(28, 28),
        Position = UDim2.new(0, 18, 0, 20),
        BackgroundTransparency = 1,
        Image = self:ResolveIcon(opts.Icon or "loader") or "",
        ImageColor3 = theme.Accent,
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 4,
        Parent = mainBox,
    })
    create("TextLabel", {
        Size = UDim2.new(1, -76, 0, 20),
        Position = UDim2.new(0, 56, 0, 24),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = theme.Text,
        TextSize = 14,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 4,
        Parent = mainBox,
    })
    local messageLbl = create("TextLabel", {
        Size = UDim2.new(1, -36, 0, 16),
        Position = UDim2.new(0, 18, 0, 58),
        BackgroundTransparency = 1,
        Text = opts.Message or "Starting...",
        TextColor3 = theme.TextDim,
        TextSize = 12,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 4,
        Parent = mainBox,
    })
    local descLbl = create("TextLabel", {
        Size = UDim2.new(1, -36, 0, 0),
        Position = UDim2.new(0, 18, 0, 76),
        BackgroundTransparency = 1,
        Text = opts.Description or "",
        TextColor3 = theme.TextMuted,
        TextSize = 11,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        AutomaticSize = Enum.AutomaticSize.Y,
        ZIndex = 4,
        Parent = mainBox,
    })
    local barBg = create("Frame", {
        Size = UDim2.new(1, -124, 0, 6),
        Position = UDim2.new(0, 18, 0, 112),
        BackgroundColor3 = theme.Panel,
        BackgroundTransparency = 0.2,
        BorderSizePixel = 0,
        ZIndex = 4,
        Parent = mainBox,
    })
    addCorner(barBg, 3)
    local barFill = create("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = theme.Accent,
        BorderSizePixel = 0,
        ZIndex = 5,
        Parent = barBg,
    })
    addCorner(barFill, 3)
    local stepLbl = create("TextLabel", {
        Size = UDim2.new(0, 90, 0, 14),
        Position = UDim2.new(1, -108, 0, 108),
        BackgroundTransparency = 1,
        Text = totalSteps > 0 and ("0/%d"):format(totalSteps) or "",
        TextColor3 = theme.TextMuted,
        TextSize = 10,
        Font = Enum.Font.GothamMedium,
        TextXAlignment = Enum.TextXAlignment.Right,
        ZIndex = 4,
        Parent = mainBox,
    })

    -- error page (hidden until ShowErrorPage(true))
    local errorPage = create("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Visible = false,
        ZIndex = 6,
        Parent = card,
    })
    local errorIcon = create("ImageLabel", {
        Size = UDim2.fromOffset(26, 26),
        Position = UDim2.new(0, 18, 0, 22),
        BackgroundTransparency = 1,
        Image = self:ResolveIcon("octagon-x") or self:ResolveIcon("triangle-alert") or "",
        ImageColor3 = theme.Error,
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 7,
        Parent = errorPage,
    })
    local errorLbl = create("TextLabel", {
        Size = UDim2.new(1, -36, 0, 0),
        Position = UDim2.new(0, 18, 0, 58),
        BackgroundTransparency = 1,
        Text = "Something went wrong.",
        TextColor3 = theme.Text,
        TextSize = 12,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        AutomaticSize = Enum.AutomaticSize.Y,
        ZIndex = 7,
        Parent = errorPage,
    })
    local errorBtnRow = create("Frame", {
        Size = UDim2.new(1, -36, 0, 24),
        Position = UDim2.new(0, 18, 0, 128),
        BackgroundTransparency = 1,
        ZIndex = 7,
        Parent = errorPage,
        Children = {
            create("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 6),
            }),
        },
    })

    -- sidebar: invisible host window -> its section becomes the sidebar body
    local sidebarBox = create("Frame", {
        Size = UDim2.new(0, 260, 1, -36),
        Position = UDim2.new(0, 400, 0, 18),
        BackgroundTransparency = 1,
        Visible = false,
        ZIndex = 3,
        Parent = card,
    })
    local sidebarDivider = create("Frame", {
        Size = UDim2.new(0, 1, 1, -36),
        Position = UDim2.new(0, 390, 0, 18),
        BackgroundColor3 = theme.Border,
        BackgroundTransparency = 0.5,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 3,
        Parent = card,
    })
    local sidebarHost = self:CreateWindow({
        Title = "EZ Loading",
        AutoSettings = false,
        Width = 280,
        Height = 420,
    })
    sidebarHost._pillSuppressed = true
    pcall(function() sidebarHost:Hide() end)
    local sidebarSection = sidebarHost:AddTab("Sidebar", "loader"):AddSection("Sidebar", "every element works here")
    pcall(function()
        sidebarSection.Frame.Parent = sidebarBox
        sidebarSection.Frame.Size = UDim2.new(1, 0, 0, 0)
    end)

    local spinConn
    local function applySpin()
        if spinConn then
            pcall(function() spinConn:Disconnect() end)
            spinConn = nil
        end
        if spinTime <= 0 then return end
        spinConn = RunService.RenderStepped:Connect(function(dt)
            if iconLabel.Parent then
                iconLabel.Rotation = (iconLabel.Rotation + (360 / spinTime) * dt) % 360
            end
        end)
        self:GiveSignal(spinConn)
    end
    applySpin()

    local loading
    loading = {
        Sidebar = sidebarSection,
        SetMessage = function(_, t)
            messageLbl.Text = tostring(t or "")
            return loading
        end,
        SetDescription = function(_, t)
            descLbl.Text = tostring(t or "")
            return loading
        end,
        SetCurrentStep = function(_, n)
            n = math.clamp(tonumber(n) or 0, 0, math.max(totalSteps, tonumber(n) or 0))
            currentStep = n
            if totalSteps > 0 then
                tween(barFill, {Size = UDim2.new(math.clamp(n / totalSteps, 0, 1), 0, 1, 0)}, 0.2)
            end
            stepLbl.Text = totalSteps > 0 and ("%d/%d"):format(n, totalSteps) or ""
            return loading
        end,
        SetTotalSteps = function(_, n)
            totalSteps = math.max(0, tonumber(n) or 0)
            stepLbl.Text = totalSteps > 0 and ("%d/%d"):format(currentStep, totalSteps) or ""
            return loading
        end,
        SetLoadingIcon = function(_, ref)
            local asset = self:ResolveIcon(ref)
            if asset then iconLabel.Image = asset end
            return loading
        end,
        SetLoadingIconTweenTime = function(_, t)
            spinTime = tonumber(t) or 0
            applySpin()
            return loading
        end,
        SetLoadingIconColor = function(_, c)
            if typeof(c) == "Color3" then iconLabel.ImageColor3 = c end
            return loading
        end,
        ShowSidebarPage = function(_, on)
            on = on == true
            sidebarBox.Visible = on
            sidebarDivider.Visible = on
            cardW = on and 660 or 380
            tween(card, {Size = UDim2.fromOffset(cardW, card.Size.Y.Offset)}, 0.2)
            return loading
        end,
        ShowErrorPage = function(_, on)
            on = on == true
            mainBox.Visible = not on
            errorPage.Visible = on
            return loading
        end,
        SetErrorMessage = function(_, t)
            errorLbl.Text = tostring(t or "")
            return loading
        end,
        SetErrorButtons = function(_, buttons)
            for _, child in errorBtnRow:GetChildren() do
                if child:IsA("TextButton") then child:Destroy() end
            end
            local order = 0
            local function addButton(btn)
                if type(btn) ~= "table" or not btn.Title then return end
                order += 1
                local variant = tostring(btn.Variant or "Ghost"):lower()
                local bg = (variant == "primary" and theme.Accent)
                    or (variant == "destructive" and theme.Error)
                    or theme.Panel
                local b = create("TextButton", {
                    AutomaticSize = Enum.AutomaticSize.X,
                    Size = UDim2.new(0, 0, 1, 0),
                    BackgroundColor3 = bg,
                    BackgroundTransparency = variant == "ghost" and 0.35 or 0.1,
                    Text = tostring(btn.Title),
                    TextColor3 = variant == "ghost" and theme.Text or Color3.new(1, 1, 1),
                    TextSize = 11,
                    Font = Enum.Font.Gotham,
                    AutoButtonColor = false,
                    BorderSizePixel = 0,
                    LayoutOrder = order,
                    Parent = errorBtnRow,
                    Children = {
                        create("UICorner", { CornerRadius = UDim.new(0, 6) }),
                        create("UIPadding", {
                            PaddingLeft = UDim.new(0, 10),
                            PaddingRight = UDim.new(0, 10),
                        }),
                    }
                })
                b.MouseButton1Click:Connect(function()
                    safecall("LoadingErrorButton", btn.Callback or function() end)
                end)
            end
            if typeof(buttons) == "table" then
                local isArray = #buttons > 0
                if isArray then
                    for _, btn in buttons do addButton(btn) end
                else
                    for _, btn in buttons do addButton(btn) end
                end
            end
            return loading
        end,
    }
    function loading:Destroy()
        if spinConn then
            pcall(function() spinConn:Disconnect() end)
            spinConn = nil
        end
        pcall(function() sidebarHost:Destroy() end)
        pcall(function() screen:Destroy() end)
        if ez._loading == loading then ez._loading = nil end
        -- hand the stage back to the main window when there is one
        local w = ez.Windows[1]
        if w and not w._destroyed then
            pcall(function() w:Show() end)
        end
    end
    loading.Continue = loading.Destroy

    ez._loading = loading
    return loading
end

-- ~~
-- AUTO-UPDATE CHECK (fetches latest tag from github)
-- ~~
function EZ:CheckForUpdate(repo)
    repo = repo or REPO_SLUG
    local url = "https://api.github.com/repos/" .. repo .. "/releases/latest"
    local ok, resp = pcall(function()
        if request then
            return request({Url = url, Method = "GET"})
        elseif http_request then
            return http_request({Url = url, Method = "GET"})
        end
    end)
    if not ok or not resp or not resp.Body then return nil end
    local okDec, data = pcall(function() return HttpService:JSONDecode(resp.Body) end)
    if not okDec or not data.tag_name then return nil end
    -- Release tags are conventionally prefixed ("v3.3.0") while _version is
    -- not. Compare numerically per component so 3.10.0 correctly outranks
    -- 3.9.0, and a locally-newer build no longer reports itself as outdated.
    local function splitVer(ver)
        local parts = {}
        for n in tostring(ver):gsub("^[vV]", ""):gmatch("%d+") do
            table.insert(parts, tonumber(n) or 0)
            if #parts >= 4 then break end
        end
        return parts
    end
    local function versionCompare(a, b) -- > 0 when a is newer than b
        local pa, pb = splitVer(a), splitVer(b)
        for i = 1, math.max(#pa, #pb) do
            local xa, xb = pa[i] or 0, pb[i] or 0
            if xa ~= xb then return xa - xb end
        end
        return 0
    end
    return {
        latest = data.tag_name,
        current = self._version,
        outdated = versionCompare(data.tag_name, self._version) > 0,
        url = data.html_url,
        body = data.body,
    }
end

-- ~~
-- TOOLTIP helper (attach to any GuiObject)
-- ~~
function EZ:AttachTooltip(guiObj, text)
    if not guiObj or not text then return end
    local theme = self.Theme
    local tip
    local function show()
        if tip then pcall(function() tip:Destroy() end) end
        tip = create("Frame", {
            Name = "EZTooltip",
            Size = UDim2.new(0, 0, 0, 22),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundColor3 = theme.Base,
            BackgroundTransparency = 0.05,
            BorderSizePixel = 0,
            ZIndex = 250,
            Parent = gui,
        })
        addCorner(tip, 4)
        addStroke(tip, theme.Border, 1, 0.5)
        create("UIPadding", {
            PaddingLeft = UDim.new(0, 8),
            PaddingRight = UDim.new(0, 8),
            Parent = tip,
        })
        create("TextLabel", {
            Size = UDim2.new(0, 0, 1, 0),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 1,
            Text = text,
            TextColor3 = theme.Text,
            TextSize = 11,
            Font = Enum.Font.Gotham,
            ZIndex = 251,
            Parent = tip,
        })
        -- keep it on screen; anchored blindly below the object it could sit
        -- off the bottom or right edge for anything near the border
        local pos = guiObj.AbsolutePosition
        local sz = guiObj.AbsoluteSize
        local screenSize = getScreenSize()
        local tipW = math.max(tip.AbsoluteSize.X, 80)
        local x = clamp(pos.X, 4, math.max(4, screenSize.X - tipW - 4))
        local y = pos.Y + sz.Y + 4
        if y + 26 > screenSize.Y then y = pos.Y - 26 end
        tip.Position = UDim2.new(0, x, 0, math.max(4, y))
    end
    local function hide()
        if tip then pcall(function() tip:Destroy() end) tip = nil end
    end
    trackConnection(guiObj.MouseEnter, show)
    trackConnection(guiObj.MouseLeave, hide)
    -- The tip is parented to the root gui, so it would survive its owner being
    -- destroyed mid-hover and stay stuck on screen.
    trackConnection(guiObj.AncestryChanged, function()
        if not guiObj.Parent then hide() end
    end)
    if guiObj:IsA("GuiButton") then
        trackConnection(guiObj.MouseButton1Click, hide)
    end
end

-- cleanup: destroy all EZ windows, clear listeners, disconnect everything
function EZ:Destroy()
    if self._destroyed then return end
    self._destroyed = true

    -- Notify registered cleanup handlers before removing the callbacks they
    -- may rely on. Never let one cleanup handler block the others.
    if self._onDestroy then
        for _, fn in self._onDestroy do pcall(fn) end
    end

    -- Disconnect every tracked connection, including window/global handlers.
    for _, c in ipairs(self._connections or {}) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(self._connections or {})
    self._connectionOwner = nil
    self._activeDrag = nil

    if self._watermark then
        pcall(function() self._watermark:Destroy() end)
        self._watermark = nil
    end

    -- the floating keybind menu owns flag listeners and a frame of its own
    if self._keybindMenu then
        pcall(function() self._keybindMenu:Destroy() end)
        self._keybindMenu = nil
    end

    -- v4.0: the cursor overlay is a separate ScreenGui — destroy it too
    if self._cursorGui then
        pcall(function() self._cursorGui:Destroy() end)
        self._cursorGui = nil
        self._cursorCrossLabel = nil
        self._cursorIconLabel = nil
    end
    self._antiAFK = false

    -- Keep the root ScreenGuis alive but empty. This makes EZ reusable after
    -- EZ:Destroy() / the close button instead of leaving dead ScreenGui
    -- references that CreateWindow() cannot parent into again.
    pcall(function()
        for _, child in gui:GetChildren() do
            child:Destroy()
        end
    end)
    pcall(function()
        for _, child in notifGui:GetChildren() do
            child:Destroy()
        end
    end)

    -- Mark every window dead first: their guards key off _destroyed, and a
    -- Show()/Hide() racing the teardown used to tween destroyed frames.
    for _, w in self.Windows do
        w._destroyed = true
    end
    -- loading screen: destroy after the windows are marked dead so its
    -- Destroy() cannot Show() a window mid-teardown
    if self._loading then
        pcall(function() self._loading:Destroy() end)
        self._loading = nil
    end
    self._panic = false
    self._panicSnapshot = nil
    self._panicTiles = nil
    self._antiAFK = false
    self._antiAFKCount = 0
    table.clear(self.Windows)
    table.clear(self.Notifications)
    table.clear(self.Flags)
    table.clear(self._listeners)
    table.clear(self._elements)
    self._onDestroy = nil
    self._autoloadRan = nil
end

function EZ:OnDestroy(fn)
    if not self._onDestroy then self._onDestroy = {} end
    table.insert(self._onDestroy, fn)
end

-- Hand the NEXT load of this library the power to tear this one down
-- (see the token consumption at the top of the file).
if getgenv then getgenv()[TEARDOWN_KEY] = function() pcall(function() EZ:Destroy() end) end end

return EZ
