--[[
    EZ UI Library - showcase / element tour.

    Every element the library has, documented in code: each one carries a
    "-- Groupbox:AddX" header, an "-- Arguments:" line and inline comments for
    each option. Read it top to bottom and you have read the whole API.

    Run it:
        loadstring(game:HttpGet(
            "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Showcase.lua"
        ))()

    Tabs in the window:
        Main    - every element, one groupbox per family
        Layout  - scale / window-size lab, for judging the UI at other ratios
        Settings- attached BY THE LIBRARY (AutoSettings). Menu + Themes +
                  Configuration, including DPI Scale, corner radius, anti-afk.
                  This file does not build it - see the note at the bottom.
]]

local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local EZ           = loadstring(game:HttpGet(repo .. "Library.lua"))()
local Icons        = loadstring(game:HttpGet(repo .. "addons/Icons.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager  = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local QuickBar     = loadstring(game:HttpGet(repo .. "addons/QuickBar.lua"))()
local NotifHistory = loadstring(game:HttpGet(repo .. "addons/NotificationHistory.lua"))()

local Flags = EZ.Flags -- every element writes its value here: Flags.MyToggle

EZ.ForceCheckbox = false              -- true makes AddToggle render as a checkbox everywhere
EZ.ShowToggleFrameInKeybinds = true   -- tap-toggles inside the floating keybind menu (default true)

-- Bind the addons BEFORE CreateWindow: the auto-attached Settings tab reads
-- these names, and the theme is applied before the window builds (no flash).
SaveManager:Bind(EZ, "EZExample")
ThemeManager:Bind(EZ, { File = "EZExample_Theme.txt" })
ThemeManager:LoadSaved()
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

EZ:SetIcons(Icons) -- after this, every icon slot accepts Lucide names

-- Re-running the example replaces the previous copy instead of stacking windows.
local stale = {}
for _, w in EZ.Windows do
    if w.Title == "EZ Example" then stale[#stale + 1] = w end
end
for _, w in stale do pcall(function() w:Destroy() end) end

local Window = EZ:CreateWindow({
    -- Title keys the geometry file; GeometryId overrides that key when the
    -- title contains punctuation or two scripts share a name.
    Title = "EZ Example",
    SubTitle = "every element + the default Settings tab",
    GeometryId = "ezexample",

    ToggleKey = Enum.KeyCode.RightShift, -- keyboard key or Enum.UserInputType.MouseButton1/2/3
    ToggleIcon = "sparkles",             -- Lucide name for the minimize dock's Open tile
    -- EZ Hub logo in the header: ImageManager downloads assets/logo.png once
    -- via getcustomasset; on executors without it the logo dot stays
    Icon = EZ.ImageManager.AddAsset("ez_logo", nil, repo .. "assets/logo.png"),
    Footer = "EZ Example | v" .. EZ._version, -- centered footer bar

    -- Width = 620, Height = 440,        -- defaults (mobile clamps smaller)
    -- TabWidth = 150,                   -- sidebar width
    -- Scale = 1,                        -- 0.5 - 2, live-sweepable in the Layout tab
    -- SidebarToggle = true,             -- show the sidebar-collapse button
    -- Gestures = true,                  -- mobile swipe-to-switch-tabs

    AutoSettings = true,                 -- the library attaches its own Settings tab
                                         -- (Menu / Themes / Configuration, DPI scale,
                                         --  corner radius, anti-afk). Pass false to
                                         -- build your own - see the bottom of this file.
    -- CloseBehavior = "library",        -- X = full EZ:Destroy() (default); "window" closes just this window
})

--[[
CALLBACK NOTE:
Passing Callback = function(Value) ... in the element options works fine.
The recommended pattern is to create the UI first, then attach logic later:

    local toggle = Groupbox:AddToggle("MyToggle", { Text = "..." })
    toggle:OnChanged(function(Value) print(Value) end)
    -- or globally: EZ:OnFlagChanged("MyToggle", function(Value) end)

Every element also has: :Set(v[, silent]) / :Get() / :SetText(t) /
:SetVisible(bool) / :SetDisabled(bool) / :Destroy().
]]

-- You do not have to structure tabs this way, it is just a preference.
-- Icons: https://lucide.dev - any name from the pack works after SetIcons.
local Tabs = {
    Main = Window:AddTab("Main", "user"),
    Layout = Window:AddTab("Layout", "ruler"),
}

-- Groupboxes come in left/right pairs that share one row (Obsidian-style).
-- Signature: Tab:AddGroupbox(side, name, icon?, description?)
local LeftGroupBox = Tabs.Main:AddGroupbox("left", "Left Groupbox", "boxes", "two-column layout")
-- You can also use the helpers:
-- local RightGroupBox = Tabs.Main:AddRightGroupbox("Right Groupbox", "boxes", "description")
local RightGroupBox = Tabs.Main:AddGroupbox("right", "Right Groupbox", "boxes", "elements line up across")

-- =========================================================================
--  TOGGLES
-- =========================================================================

-- Groupbox:AddToggle
-- Arguments: (id, opts)
LeftGroupBox:AddToggle("MyToggle", {
    Text = "This is a toggle",              -- row label (defaults to the id)
    Description = "a muted second line",    -- optional explainer under the label
    Tooltip = "shown when you hover the row",
    Default = true,                          -- true / false
    -- VisibleWhen = "OtherFlag",            -- row only exists while that flag is ON
    Callback = function(Value)
        print("[cb] MyToggle changed to:", Value)
    end,
})

-- Groupbox:AddCheckbox - same handle, square visual (or set EZ.ForceCheckbox = true)
LeftGroupBox:AddCheckbox("MyCheckbox", {
    Text = "This is a checkbox",
    Default = true,
})

-- Groupbox:AddButton
-- Arguments: (opts)
LeftGroupBox:AddButton({
    Text = "This is a button",
    Tooltip = "buttons are for actions, not settings",
    Callback = function()
        EZ:Notify({ Title = "EZ", Content = "button pressed", Duration = 2 })
    end,
})

-- =========================================================================
--  SLIDERS
-- =========================================================================

-- Groupbox:AddSlider
-- Arguments: (id, opts)
LeftGroupBox:AddSlider("MySlider", {
    Text = "This is a slider",
    Min = 0,
    Max = 100,
    Default = 50,
    Increment = 5,        -- step size (decimals allowed: 0.05)
    Suffix = "%",         -- rendered after the value
    -- Prefix = "$",      -- rendered before the value  ->  "$50%"
    Tooltip = "click the value label to type an exact number",
    Callback = function(Value)
        print("[cb] MySlider changed to:", Value)
    end,
})

-- Handle methods (v3.9): :SetMin(n) / :SetMax(n) re-range live, :SetPrefix(t),
-- :SetText(t). The handle is the return value:
local ranged = LeftGroupBox:AddSlider("RangedSlider", { Text = "Range demo", Min = 0, Max = 10, Default = 5 })
ranged:SetMin(2)
ranged:SetMax(8)

-- =========================================================================
--  DROPDOWNS
-- =========================================================================

-- Groupbox:AddDropdown
-- Arguments: (id, opts)
RightGroupBox:AddDropdown("MyDropdown", {
    Text = "This is a dropdown",
    Values = { "This", "is", "a", "dropdown" }, -- array = stored and shown
    Default = "This",
    -- Multi = true,         -- flag becomes { value = true }
    -- Searchable = true,    -- search box inside the open list
    -- VisibleItems = 6,     -- cap visible rows before scrolling
    -- Height = 180,         -- or fix the list height outright
    -- AllowEmptySelection = true, -- single: click the selected value to clear it
    Callback = function(Value)
        print("[cb] MyDropdown changed to:", Value)
    end,
})

-- Dictionary values: the KEY is stored, the label is shown.
-- Use it when your code needs stable ids but users see pretty names.
RightGroupBox:AddDropdown("DictionaryDropdown", {
    Text = "Dictionary values + locked entry",
    Values = { item01 = "Excalibur", item05 = "Aegis Shield", legacy = "Legacy (locked)" },
    Disabled = { legacy = true }, -- dimmed + unclickable
    Default = "item01",
})

-- v3.9 methods on the returned handle:
--   dd:AddValues({...})            append without wiping
--   dd:SetValues({...})            replace (alias of :Refresh)
--   dd:SetDisabledValues({...})    lock/unlock entries
--   dd:SetValueImages({ A = "sword" })  icons per option
--   dd:SetDragSelect(true)         sweep-select rows
--   dd:GetActiveValues(true)       count of selections
local rich = RightGroupBox:AddDropdown("RichDropdown", {
    Text = "Value images + drag select",
    Values = { sword = "Sword", shield = "Shield", potion = "Potion" },
    ValueImages = { sword = "sword", shield = "shield", potion = "flask-round" },
    Multi = true,
    Default = { "sword" },
})
rich:SetDragSelect(true)

-- Groupbox:AddInput
-- Arguments: (id, opts)
RightGroupBox:AddInput("MyInput", {
    Text = "This is an input",
    Placeholder = "Type here...",
    Default = "",
    Callback = function(Text, EnterPressed)
        print("[cb] MyInput:", Text, "| entered:", EnterPressed)
    end,
})

-- Groupbox:AddPlayerSelector - dropdown preloaded with players
-- Arguments: (id, opts)
RightGroupBox:AddPlayerSelector("MyTarget", {
    Text = "This is a player selector",
    ExcludeSelf = true, -- false adds "@me"
})
-- Resolve the selection with: EZ._elements.MyTarget:GetPlayers()

-- =========================================================================
--  KEYBINDS
-- =========================================================================

local KeybindsGroup = Tabs.Main:AddGroupbox("left", "Keybinds", "keyboard")

-- Groupbox:AddKeybind
-- Arguments: (id, opts)
KeybindsGroup:AddKeybind("MyKeybind", {
    Text = "This is a keybind",
    Default = Enum.KeyCode.G,   -- or Enum.UserInputType.MouseButton1/2/3, or "G"
    Mode = "Toggle",             -- "Toggle" flips a state, "Hold" is while-pressed
    -- Modifiers = { Ctrl = true }, -- or { "ctrl" }; either physical key counts
    Callback = function(IsActive)
        print("[cb] MyKeybind active:", IsActive)
    end,
})

local comboBind = KeybindsGroup:AddKeybind("ComboKeybind", {
    Text = "Ctrl + X chord",
    Default = Enum.KeyCode.X,
    Modifiers = { Ctrl = true },
})
-- Programmatic rebind + state:
KeybindsGroup:AddButton({
    Text = "Rebind to Ctrl+H (Hold)",
    Callback = function()
        comboBind:Configure({ Key = Enum.KeyCode.H, Mode = "Hold", Modifiers = { Ctrl = true } })
    end,
})

KeybindsGroup:AddButton({
    Text = "Show the keybind menu",
    Tooltip = "floating cheatsheet of every bind; tap-toggles for Toggle binds",
    Callback = function() EZ:ToggleKeybindMenu() end,
})

-- =========================================================================
--  COLOURS, PROGRESS, TEXT
-- =========================================================================

local VisualsGroup = Tabs.Main:AddGroupbox("right", "Visuals", "palette")

-- Groupbox:AddColorPicker
-- Arguments: (id, opts)
VisualsGroup:AddColorPicker("MyColorPicker", {
    Text = "This is a colour picker",
    Default = Color3.fromRGB(124, 92, 252),
    Transparency = 0,        -- 0-1, adds the alpha ramp
    -- Palette = { Color3.fromRGB(255, 90, 90), Color3.fromRGB(90, 200, 255) },
    -- ^ v3.6: preset swatches + last-6 session recents
    Callback = function(Color)
        print("[cb] MyColorPicker:", Color)
    end,
})

-- Groupbox:AddProgressBar
-- Arguments: (id, opts)   NOTE: no Callback option - drive it with :Set
local progress = VisualsGroup:AddProgressBar("MyProgress", {
    Text = "This is a progress bar",
    Max = 100,
    Default = 35,
    -- Color = Color3.fromRGB(120, 200, 255),
})
VisualsGroup:AddButton({
    Text = "+10 progress",
    Callback = function()
        progress:Set((progress:Get() + 10) % 110)
    end,
})

-- Groupbox:AddLog - scrolling console with helper methods
-- Arguments: (opts)
local log = VisualsGroup:AddLog({ Height = 100, MaxLines = 40 })
log:Success("log ready - :Info / :Warn / :Error / :Success / :Print(t, c) / :Clear()")

-- Groupbox:AddLabel / AddDivider / AddParagraph
VisualsGroup:AddDivider("Text elements")
VisualsGroup:AddLabel("This is a label")            -- or { Text = ..., DoesWrap = true, RichText = true, Size = 14 }
VisualsGroup:AddParagraph({
    Title = "This is a paragraph",
    Content = "Wrapped body text, updatable later with :Set(text).",
})

-- =========================================================================
--  TABBOXES
-- =========================================================================

-- Tabboxes are their own structure (v4.3): Tab:AddLeftTabbox() / AddRightTabbox()
-- places one directly in the column layout - they are NOT meant to live inside
-- groupboxes. Each tab inside is a full section.
local TabBox = Tabs.Main:AddLeftTabbox({ Tabs = { "Tab 1", "Tab 2" } })

-- You can now call AddToggle, etc on the tabs you added to the Tabbox:
-- (each tab acts like a nested groupbox - its own controls, own state)
TabBox.Tabs["Tab 1"]:AddSlider("Tab1Slider", { Text = "control in Tab 1", Min = 0, Max = 100, Default = 40 })
TabBox.Tabs["Tab 1"]:AddToggle("Tab1Toggle", { Text = "independent tab state", Default = true })
TabBox.Tabs["Tab 1"]:AddButton({ Text = "button inside Tab 1", Callback = function()
    EZ:Notify({ Title = "Tabbox", Content = "each tab is a full section", Duration = 2 })
end })
TabBox.Tabs["Tab 2"]:AddToggle("Tab2Toggle", { Text = "control in Tab 2" })
TabBox.Tabs["Tab 2"]:AddDropdown("Tab2Dropdown", {
    Text = "dropdown in Tab 2",
    Values = { "Alpha", "Beta" },
    Default = "Alpha",
})
TabBox:Select("Tab 1")

-- v3.9: tabs can be added at runtime (with an icon); the segments re-layout.
Tabs.Main:AddGroupbox("right", "More elements", "puzzle"):AddButton({
    Text = "Tabbox:AddTab('Third', 'star')",
    Callback = function()
        local third = TabBox:AddTab("Third", "star")
        third:AddLabel("added at runtime")
        TabBox:Select("Third")
    end,
})

-- =========================================================================
--  EMBEDS (3D + your own GUI)
-- =========================================================================

local EmbedGroup = Tabs.Main:AddGroupbox("right", "Embeds", "box", "3D and passthrough")

-- Groupbox:AddViewport  (v4.1) - ViewportFrame + WorldModel; the object is cloned in
-- Arguments: (id, opts)
local demoPart = Instance.new("Part")
demoPart.Shape = Enum.PartType.Ball
demoPart.Material = Enum.Material.Neon
demoPart.Color = Color3.fromRGB(124, 92, 252)
EmbedGroup:AddViewport("MyViewport", {
    Object = demoPart,
    Height = 140,
    -- Interactive = true,  -- drag to orbit, wheel/pinch to zoom (default true)
    -- AutoFocus = true,    -- camera fits via GetBoundingBox (default true)
})

-- Groupbox:AddUIPassthrough  (v4.1) - embed any GuiBase2d in the layout
-- Arguments: (id, opts)
local customFrame = Instance.new("Frame")
customFrame.BackgroundColor3 = Color3.fromRGB(24, 22, 36)
local customLabel = Instance.new("TextLabel")
customLabel.Size = UDim2.fromScale(1, 1)
customLabel.BackgroundTransparency = 1
customLabel.Text = "your own GuiBase2d"
customLabel.TextColor3 = Color3.fromRGB(200, 200, 220)
customLabel.Parent = customFrame
EmbedGroup:AddUIPassthrough("MyPassthrough", {
    Instance = customFrame,
    Height = 48,
})
-- :Destroy() hands the instance back to its original parent.

-- =========================================================================
--  NEW IN 4.3
-- =========================================================================

local New43 = Tabs.Main:AddGroupbox("left", "New in 4.3", "sparkles", "parity additions")

-- Buttons: Sub = compact secondary style; Disabled = starts locked
New43:AddButton({ Text = "Button", Callback = function() end })
New43:AddButton({ Text = "Sub button", Sub = true, Callback = function() end })
New43:AddButton({ Text = "Disabled button", Disabled = true, Callback = function() end })

New43:AddDivider("Labels")

-- Label family: plain / wrapping / multi-line (no wrap) / exposed to EZ.Labels
New43:AddLabel("This is a label")
New43:AddLabel({ Text = "This is a label that wraps its text!", DoesWrap = true })
New43:AddLabel("Line one\nLine two (no wrap, explicit newlines)")
local exposed = New43:AddLabel("MyExposedLabel", { Text = "Exposed to EZ.Labels.MyExposedLabel" })
New43:AddButton({
    Text = "SetText the exposed label",
    Callback = function()
        EZ.Labels.MyExposedLabel:SetText("updated at " .. os.date("%H:%M:%S"))
    end,
})

New43:AddDivider("Custom display slider")

-- Sliders: Display(value) -> string replaces the default number rendering
New43:AddSlider("CustomDisplaySlider", {
    Text = "This is my custom display slider!",
    Min = 1, Max = 5, Default = 3, Increment = 1,
    Display = function(v) return v .. "/5" end,
})

New43:AddDivider("Keybind modes")

-- Keybinds: Toggle / Hold / Press (Press fires on every keydown, no state)
New43:AddKeybind("PressKeybind", {
    Text = "Press keybind (fires each press)",
    Default = Enum.KeyCode.Y,
    Mode = "Press",
    Callback = function() print("[cb] PressKeybind fired") end,
})

New43:AddButton({
    Text = "Spawn a draggable label",
    Tooltip = "v4.3: EZ:CreateDraggableLabel - floats on screen, drag it anywhere",
    Callback = function()
        local dl = EZ:CreateDraggableLabel("This is a Draggable Label")
        task.delay(8, function() pcall(function() dl:Destroy() end) end)
    end,
})

New43:AddDivider("Pop-out")

-- v4.4: drag any groupbox HEADER out of the window to float it; drag it back
-- and release over the window to dock. Tabboxes use the grip on their strip.
New43:AddButton({
    Text = "Pop this groupbox out / dock",
    Tooltip = "same as dragging the header out of the window and back",
    Callback = function() New43:TogglePoppedOut() end,
})
New43:AddLabel({ DoesWrap = true,
    Text = "TabBoxes float too: drag the grip chip at the right of the tab strip." })

-- =========================================================================
--  NOTIFICATIONS & DIALOGS
-- =========================================================================

local FeedbackGroup = Tabs.Main:AddGroupbox("left", "Feedback", "bell")

-- EZ:Notify - transient toasts; Type = info / success / warning / error
FeedbackGroup:AddButton({
    Text = "Notify (with action buttons)",
    Callback = function()
        EZ:Notify({
            Title = "Save layout?",
            Content = "the card carries its own buttons",
            Type = "warning",
            Duration = 12,
            Buttons = {
                { Text = "Save", Callback = function() end },
                { Text = "Later", Callback = function() end },
            },
        })
    end,
})

-- v4.0: persistent + progress notifications return a handle
FeedbackGroup:AddButton({
    Text = "Persistent progress notification",
    Callback = function()
        local n = EZ:Notify({
            Title = "Installing", Content = "0%",
            Duration = false,          -- stays until :Dismiss() / :Destroy()
            TotalSteps = 4,
            SoundId = 12221967, Volume = 0.15,
        })
        for step = 1, 4 do
            task.wait(0.5)
            n:ChangeStep(step)
            n:ChangeDescription(("%d%%"):format(step * 25))
        end
        n:ChangeTitle("Done")
    end,
})

-- Window:AddDialog - blocking confirmation; Variants: Ghost / Primary / Destructive
FeedbackGroup:AddButton({
    Text = "Confirm dialog",
    Callback = function()
        Window:AddDialog("MyDialog", {
            Title = "Delete everything?",
            Description = "Destructive actions should always confirm first.",
            -- AutoDismiss = false, -- forced choice
            FooterButtons = {
                { Title = "Cancel", Variant = "Ghost", Order = 1 },
                { Title = "Delete", Variant = "Destructive", Order = 2, Callback = function(d)
                    d:Dismiss()
                end },
            },
        })
    end,
})

-- =========================================================================
--  LAYOUT TAB - judge the UI at other ratios
--
--  The Settings tab (attached by AutoSettings) already has a DPI Scale
--  dropdown with the same 9 presets. This tab exists to go further:
--  sweep every value in between, resize the window, and see how the rows
--  below hold up while you do it.
-- =========================================================================

local ScaleGroup = Tabs.Layout:AddGroupbox("left", "UI Scale", "ruler", "same control as Settings > DPI Scale")

-- Percent -> scale, without the gsub-returns-two-values trap:
-- tonumber(s:gsub(...)) would feed the replacement count in as a base.
local function setScalePct(pct)
    local n = tonumber((tostring(pct):gsub("%%", ""))) or 100
    Window:SetScale(n / 100)
end

-- Groupbox:AddSlider - live sweep. The dropdown jumps between presets; this
-- shows every value in between, which is how you find where a layout breaks.
local scaleSlider = ScaleGroup:AddSlider("LayoutScale", {
    Text = "Window scale",
    Min = 50, Max = 200, Default = 100, Increment = 5,
    Suffix = "%",
    Tooltip = "50% - 200%, applied live",
    Callback = function(v) Window:SetScale(v / 100) end,
})

ScaleGroup:AddDropdown("LayoutScalePreset", {
    Text = "Preset",
    Values = { "50%", "75%", "90%", "100%", "110%", "125%", "150%", "175%", "200%" },
    Default = "100%",
    Callback = setScalePct,
})

-- Live readout. Polls the window rather than tracking its own state, so it
-- stays honest when you change the scale from the Settings tab instead.
local readout = ScaleGroup:AddLabel("LayoutReadout", { Text = "scale 100%  -  window 620x440" })

ScaleGroup:AddDivider("Window size")

-- v4.5: Window:SetSize(w, h) / Window:GetSize() - same clamps as the corner
-- grip, so presets behave exactly like a drag.
local function sizeBtn(text, w, h)
    ScaleGroup:AddButton({
        Text = text,
        Sub = true,
        Callback = function() Window:SetSize(w, h) end,
    })
end
sizeBtn("Compact - 460x360", 460, 360)
sizeBtn("Default - 620x440", 620, 440)
sizeBtn("Wide - 900x520", 900, 520)
sizeBtn("Tall - 620x720", 620, 720)

local WhatGroup = Tabs.Layout:AddGroupbox("right", "What to check", "eye", "at each ratio")

WhatGroup:AddLabel({ DoesWrap = true, Text =
    "Rows are laid out from fixed pixel offsets, so a scale that is too small "
    .. "starts to crowd text against icons, and one that is too large wastes "
    .. "the window. Sweep the slider and watch these four things." })
WhatGroup:AddDivider("1 - Header")
WhatGroup:AddLabel({ DoesWrap = true, Text =
    "The brand icon, title and subtitle are centred as one block. They should "
    .. "stay centred, and the subtitle should stay readable rather than "
    .. "blurring into the background." })
WhatGroup:AddDivider("2 - Sidebar")
WhatGroup:AddLabel({ DoesWrap = true, Text =
    "The selected tab carries an accent wash, an accent icon, a brighter "
    .. "label and the accent bar on its left edge. Hovering another tab should "
    .. "wash it, and never look the same as the selected one." })
WhatGroup:AddDivider("3 - Rows")
WhatGroup:AddLabel({ DoesWrap = true, Text =
    "Labels, values and controls share a baseline. The value column should "
    .. "stay aligned down the whole groupbox at every scale." })
WhatGroup:AddDivider("4 - Scroll")
WhatGroup:AddLabel({ DoesWrap = true, Text =
    "At 150%+ a long groupbox should scroll, not clip or overlap the footer. "
    .. "Shrink the window to 460x360 and confirm the same thing." })

-- Density sample: one row of each family, so the four checks above have
-- something to be judged against.
local DensityGroup = Tabs.Layout:AddGroupbox("left", "Density sample", "list", "one of each family")

DensityGroup:AddToggle("LayoutSampleToggle", { Text = "Toggle row", Default = true })
DensityGroup:AddSlider("LayoutSampleSlider", { Text = "Slider row", Min = 0, Max = 100, Default = 65, Suffix = "%" })
DensityGroup:AddDropdown("LayoutSampleDropdown", { Text = "Dropdown row", Values = { "One", "Two", "Three" }, Default = "One" })
DensityGroup:AddInput("LayoutSampleInput", { Text = "Input row", Placeholder = "type here", Default = "" })
DensityGroup:AddButton({ Text = "Button row", Callback = function() end })
DensityGroup:AddDivider("Divider row")
DensityGroup:AddLabel("Label row")

-- Keep the slider and the readout in step with the real window scale, whoever
-- changed it. :Set(v, true) is the silent form, so this cannot re-fire the
-- callback and fight whoever moved the scale.
task.spawn(function()
    while Window and not Window._destroyed do
        local ok, scale, size = pcall(function()
            return Window:GetScale(), Window:GetSize()
        end)
        if ok and scale then
            local pct = math.floor(scale * 100 + 0.5)
            readout:SetText(("scale %d%%  -  window %dx%d"):format(pct, size.X, size.Y))
            if math.abs(scaleSlider:Get() - pct) >= 1 then scaleSlider:Set(pct, true) end
        end
        task.wait(0.25)
    end
end)

-- =========================================================================
--  WIRING (bottom of the file, after every element exists)
-- =========================================================================

QuickBar:Bind(EZ, Window, { MaxPins = 6 })   -- floating pins while the window is hidden
NotifHistory:Bind(EZ, Window)                -- bell + notification history in the header

EZ:OnDestroy(function()
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHistory:Destroy() end)
end)

-- Pins must come after the elements they reference exist
QuickBar:Pin("MyToggle", { Icon = "sparkles" })
QuickBar:Pin("MySlider", { Icon = "sliders-horizontal" })

EZ:CreateWatermark({
    Text = "EZ Example | {fps} fps | {ping} ms | toggle={flag:MyToggle}",
})

-- Autoload LAST: restored values are pushed into elements that now exist.
SaveManager:LoadAutoloadConfig()

task.defer(function()
    EZ:Notify({ Title = "EZ Example", Content = "Main = every element, Layout = scale lab, Settings = the library's own tab",
        Duration = 5, Type = "success" })
end)

--[[
BUILDING YOUR OWN SETTINGS TAB

AutoSettings = true (the default) is what put the Settings tab in this window.
If a script needs a different arrangement, pass AutoSettings = false and build
the same content by hand - every piece of it is public API:

    local SettingsTab = Window:AddTab("Settings", "settings")

    -- Menu: hotkey rebind, anti-afk, panic, unload
    local MenuGroup = SettingsTab:AddGroupbox("left", "Menu", "wrench")
    local menuBind = MenuGroup:AddKeybind("MenuKeybind", { Text = "Menu bind",
        Default = Enum.KeyCode.RightShift })
    menuBind:OnChanged(function(k)
        if typeof(k) == "EnumItem" then Window:SetToggleKey(k) end
    end)
    MenuGroup:AddToggle("AntiAFKToggle", { Text = "Anti-AFK", Default = false,
        Callback = function(v) EZ:SetAntiAFK(v) end })
    MenuGroup:AddButton({ Text = "Toggle panic", Callback = function() EZ:TogglePanic() end })
    MenuGroup:AddButton({ Text = "Unload", Callback = function() EZ:Destroy() end })

    -- Themes: live switch, persisted by ThemeManager
    SettingsTab:AddGroupbox("left", "Themes", "palette"):AddDropdown("ThemeList", {
        Text = "Theme", Values = ThemeManager:GetThemes(), Default = ThemeManager.Current,
        Callback = function(v) ThemeManager:SetTheme(v) end })

    -- Configuration: the full config manager (create/load/delete/autoload/JSON)
    SaveManager:BuildConfigSection(
        SettingsTab:AddGroupbox("right", "Configuration", "folder-cog"), Window)
    -- Profiles are opt-in:
    -- SaveManager:BuildProfileUI(SettingsTab:AddGroupbox("right", "Profiles", "users"), Window)

The one-call version is Window:AddSettingsTab({ Title = "Settings", Icon = "settings",
Menu = true, Themes = true, Configs = true, Profiles = false }) - it reads the
addons registered on :Bind() and skips whatever is missing.
]]

return EZ
