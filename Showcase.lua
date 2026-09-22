--[[
    Example script for the EZ UI Library, in the style of Obsidian's Example.lua.
    Walk it top to bottom: every element has a "-- Groupbox:AddX" header, an
    "-- Arguments:" line, and inline comments for each option.

    Run it:
        loadstring(game:HttpGet(
            "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Showcase.lua"
        ))()

    Recommended reading order in the window:
        Main          - every element, one groupbox per family
        UI Settings   - the persistence wiring (EZ can also auto-attach this)
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

-- Bind the addons BEFORE CreateWindow so AutoSettings adopts your names.
SaveManager:Bind(EZ, "EZExample")
ThemeManager:Bind(EZ, { File = "EZExample_Theme.txt" })
ThemeManager:LoadSaved() -- apply the saved theme before the window builds (no colour flash)
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
    SubTitle = "in the style of Obsidian's Example.lua",
    GeometryId = "ezexample",

    ToggleKey = Enum.KeyCode.RightShift, -- keyboard key or Enum.UserInputType.MouseButton1/2/3
    ToggleIcon = "sparkles",             -- Lucide name for the minimize dock's Open tile
    Icon = "sparkles",                   -- v4.3: header icon (replaces the logo dot)
    Footer = "EZ Example | v" .. EZ._version, -- v4.3: centered footer bar

    -- Width = 620, Height = 440,        -- defaults (mobile clamps smaller)
    -- TabWidth = 150,                   -- sidebar width
    -- Scale = 1,                        -- 0.5 - 2
    -- SidebarToggle = true,             -- show the sidebar-collapse button
    -- Gestures = true,                  -- mobile swipe-to-switch-tabs
    AutoSettings = false,                -- THIS example builds its own UI Settings tab below;
                                         -- remove this line to let the library attach one for you
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
    ["UI Settings"] = Window:AddTab("UI Settings", "settings"),
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
TabBox.Tabs["Tab 1"]:AddSlider("Tab1Slider", { Text = "control in Tab 1", Min = 0, Max = 100, Default = 40 })
TabBox.Tabs["Tab 2"]:AddToggle("Tab2Toggle", { Text = "control in Tab 2" })

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
--  UI SETTINGS TAB  (what AutoSettings builds for you automatically)
-- =========================================================================

local UISettingsTab = Tabs["UI Settings"]

local MenuGroup = UISettingsTab:AddGroupbox("left", "Menu", "wrench")

-- Groupbox:AddKeybind rebinding the window hotkey
local menuBind = MenuGroup:AddKeybind("MenuKeybind", {
    Text = "Menu bind",
    Default = Enum.KeyCode.RightShift,
})
menuBind:OnChanged(function(k)
    if typeof(k) == "EnumItem" then Window:SetToggleKey(k) end
end)

MenuGroup:AddToggle("AntiAFKToggle", {
    Text = "Anti-AFK",
    Description = "prevents the ~20 min idle kick",
    Default = false,
    Callback = function(v) EZ:SetAntiAFK(v) end,
})

MenuGroup:AddButton({ Text = "Toggle panic", Callback = function() EZ:TogglePanic() end })
MenuGroup:AddButton({ Text = "Unload", Callback = function() EZ:Destroy() end })

-- Themes: switch live; ThemeManager persists the choice per brand
UISettingsTab:AddGroupbox("left", "Themes", "palette"):AddDropdown("ThemeList", {
    Text = "Theme",
    Values = ThemeManager:GetThemes(),
    Default = ThemeManager.Current,
    Callback = function(v) ThemeManager:SetTheme(v) end,
})

-- Configuration: the full config manager UI (create/load/delete/autoload/JSON)
SaveManager:BuildConfigSection(UISettingsTab:AddGroupbox("right", "Configuration", "folder-cog"), Window)
-- Profiles are opt-in:
-- SaveManager:BuildProfileUI(UISettingsTab:AddGroupbox("right", "Profiles", "users"), Window)

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
    EZ:Notify({ Title = "EZ Example", Content = "every element, documented in code - read the comments",
        Duration = 4, Type = "success" })
end)

return EZ
