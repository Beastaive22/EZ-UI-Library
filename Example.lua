--[[
    ============================================================================
    EZ UI LIBRARY - COMPLETE GUIDED TOUR
    ============================================================================

    This script is TWO things at once:

      1. A living reference. Nine tabs walk through EVERY element, EVERY
         window feature and EVERY addon. Each one is labelled, wired to a
         real callback, and explained in the comments right above it - read
         the code top-to-bottom while clicking through the UI.

      2. A starter template. Copy the LOAD / SETUP / WINDOW blocks, delete
         the tour tabs, and you have a production shell.

    MAP OF THE TOUR
      Welcome ............ what you are looking at + navigation controls
      Notifications ...... EZ:Notify, types, bursts, the history bell
      Elements ........... Toggle, Button, Label, Divider, Paragraph
      Inputs ............. Slider, Dropdown (single/multi), Textbox,
                           PlayerSelector
      Binds & Colors ..... Keybind (modes + modifiers), ColorPicker
                           (+ transparency), floating keybind menu
      Progress & Logs .... ProgressBar API + console-style Log
      Dialogs ............ window:AddDialog modals (all variants)
      Layout ............. sub-tabs, collapsible sections, the search filter
      Settings ........... themes, config profiles (SaveManager), scale,
                           sidebar, haptics, update check

    RUN IT: execute this file in your executor, or loadstring it from GitHub.
    ============================================================================
]]

----------------------------------------------------------------
-- 1. LOAD
-- One loadstring per file. Everything returns its handle directly.
----------------------------------------------------------------
local repo = "https://raw.githubusercontent.com/YourName/YourRepo/main/"

local EZ            = loadstring(game:HttpGet(repo .. "Library.lua"))()
local Icons         = loadstring(game:HttpGet(repo .. "addons/Icons.lua"))()
local SaveManager   = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local ThemeManager  = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local QuickBar      = loadstring(game:HttpGet(repo .. "addons/QuickBar.lua"))()
local NotifHistory  = loadstring(game:HttpGet(repo .. "addons/NotificationHistory.lua"))()

----------------------------------------------------------------
-- 2. SETUP
----------------------------------------------------------------
-- Give the library an icon pack: every place that accepts an icon
-- (tabs, toggle pill, QuickBar tiles...) then understands lucide names
-- like "sword", "eye", "settings". Raw rbxassetid:// urls work too.
EZ:SetIcons(Icons)

-- SaveManager owns configs + profiles on disk (folder: EZTour/).
SaveManager:Bind(EZ, "EZTour")

-- ThemeManager owns theme switching + persists your pick across runs.
ThemeManager:Bind(EZ)
ThemeManager:LoadSaved() -- apply before the window builds: no colour flash

-- The library ships 8 extra curated themes in EZ.Themes. Hand them to the
-- ThemeManager so they appear in ONE dropdown and persist like the rest
-- (calling raw EZ:SetTheme(tbl) works too, but skips saving the choice).
for name, tbl in EZ.Themes do
    ThemeManager:AddTheme(name, tbl)
end

----------------------------------------------------------------
-- 3. WINDOW
-- CreateWindow options (all optional):
--   Title/SubTitle  header text                ToggleKey     hide/show hotkey
--   ToggleIcon      lucide name for pill       ToggleText    ...or text
--   Width/Height    pixels (mobile auto-fit)   TabWidth      sidebar width
--   Scale           start UIScale              SidebarToggle show collapse btn
--   Gestures        mobile swipe tab-switch
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "EZ Tour",
    SubTitle = "every feature, explained",
    ToggleKey = Enum.KeyCode.RightShift,
    ToggleIcon = "sparkles",
})

----------------------------------------------------------------
-- 4. ADDON BINDS
-- QuickBar  : dock of pinned tiles shown while the window is HIDDEN
-- NotifHis. : bell in the header + scrollable notification history
----------------------------------------------------------------
QuickBar:Bind(EZ, Window, { MaxPins = 5 })
NotifHistory:Bind(EZ, Window)

--==================================================================--
--  TAB: WELCOME                                                     --
--==================================================================--
local Welcome = Window:AddTab("Welcome", "home")

local introSec = Welcome:AddSection("What is this?")
introSec:AddParagraph({
    Title = "Guided tour",
    Content = "Nine tabs, every element and addon, all live. Each control "
        .. "prints to Roblox's console (F9) so you can see exactly what the "
        .. "callbacks receive.",
})

introSec:AddParagraph({
    Title = "Navigate like this",
    Content = "RightShift hides/shows the window (a pill stays behind). "
        .. "Drag anywhere on the empty header to move. Type in the SEARCH "
        .. "bar to filter every element by name. The bell opens notification "
        .. "history. The chevron collapses the sidebar. Minimise/close live "
        .. "top-right. On phones: swipe horizontally to switch tabs.",
})

local liveSec = Welcome:AddSection("Live proof")
liveSec:AddParagraph({
    Title = "Flags are just a table",
    Content = "Every element writes its value into EZ.Flags[id]. Read it "
        -- IMPORTANT: write state with element:Set(); writing EZ.Flags.x
        -- directly updates the table but does NOT move the UI.
        .. "from your loops (EZ.Flags.HelloToggle). To CHANGE state from "
        .. "code always use the element handle's :Set().",
})

-- Basic toggle. Options: Text, Default, Tooltip, Callback, VisibleWhen.
-- Returns a handle: :Set(v) :Get() :OnChanged(fn).
liveSec:AddToggle("HelloToggle", {
    Text = "Flip me, watch the watermark",
    Default = false,
    Tooltip = "the watermark bottom-left prints this flag live",
    Callback = function(v)
        print("[Tour] HelloToggle =", v)
    end,
})

-- React to a flag from OUTSIDE the element: global listener.
EZ:OnFlagChanged("HelloToggle", function(v)
    EZ:Notify({
        Title = "Flag listener",
        Content = "HelloToggle is now " .. tostring(v),
        Duration = 2,
        Type = v and "success" or "info",
    })
end)

liveSec:AddButton({
    Text = "Ping!",
    Callback = function()
        EZ:Notify({ Title = "Pong", Content = "buttons can do anything", Duration = 2 })
    end,
})

--==================================================================--
--  TAB: NOTIFICATIONS                                               --
--==================================================================--
local Notifs = Window:AddTab("Notifs", "bell")

local nSec = Notifs:AddSection("Types")
nSec:AddParagraph({
    Title = "EZ:Notify(options)",
    Content = "Title, Content, Duration (seconds), Type. Types colour the "
        .. "accent edge: info / success / warning / error. Cards stack "
        .. "top-right, newest first; EZ.MaxNotifications caps how many are "
        .. "on screen at once (default 5, older ones pop off).",
})

for _, t in { "info", "success", "warning", "error" } do
    nSec:AddButton({
        Text = "Notify type: " .. t,
        Callback = function()
            EZ:Notify({
                Title = t:sub(1, 1):upper() .. t:sub(2),
                Content = "this is what a " .. t .. " looks like",
                Duration = 3,
                Type = t,
            })
        end,
    })
end

nSec:AddButton({
    Text = "Burst of 5 (tests the cap)",
    Callback = function()
        local kinds = { "info", "success", "warning", "error", "info" }
        for i = 1, 5 do
            task.delay(i * 0.12, function()
                EZ:Notify({ Title = "Burst #" .. i, Content = "stacked card", Type = kinds[i], Duration = 4 })
            end)
        end
    end,
})

local nSec2 = Notifs:AddSection("History")
nSec2:AddParagraph({
    Title = "Bell icon (header)",
    Content = "Every notification above was ALSO recorded by the "
        .. "NotificationHistory addon bound at the top. Open the bell: "
        .. "scrollable log, unread badge, Clear button. Nothing to wire - "
        .. "binding it once captures everything.",
})

--==================================================================--
--  TAB: ELEMENTS                                                    --
--==================================================================--
local Elements = Window:AddTab("Elements", "toggle-left")

local tSec = Elements:AddSection("Toggles")
tSec:AddParagraph({
    Title = "section:AddToggle(id, options)",
    Content = "id saves into EZ.Flags and configs. Options: Text (label), "
        .. "Default, Tooltip (hover me), Callback(value), VisibleWhen "
        .. "(flag id that must be ON to show this row).",
})

tSec:AddToggle("BasicToggle", {
    Text = "Basic toggle",
    Default = false,
    Callback = function(v) print("[Tour] BasicToggle =", v) end,
})

tSec:AddToggle("DefaultOn", {
    Text = "Starts enabled",
    Default = true,
})

tSec:AddToggle("TooltipDemo", {
    Text = "Hover me for a tooltip",
    Default = false,
    Tooltip = "Tooltips attach to ANY element via opts.Tooltip",
})

-- Conditional visibility: children stay hidden until MasterSwitch is on.
tSec:AddToggle("MasterSwitch", {
    Text = "Show advanced options (VisibleWhen)",
    Default = false,
    Tooltip = "unlocks the three rows below",
})

tSec:AddSlider("AdvSlider", {
    Text = "Advanced slider",
    Min = 0, Max = 100, Default = 50,
    VisibleWhen = "MasterSwitch",
    Tooltip = "only exists while MasterSwitch is on",
})

tSec:AddDropdown("AdvChoice", {
    Text = "Advanced choice",
    Values = { "Option A", "Option B", "Option C" },
    VisibleWhen = "MasterSwitch",
})

tSec:AddToggle("AdvExtra", {
    Text = "Advanced extra",
    VisibleWhen = "MasterSwitch",
})

local bSec = Elements:AddSection("Buttons")
bSec:AddParagraph({
    Title = "section:AddButton(options)",
    Content = "Just Text + Callback. Buttons also accept Tooltip and "
        .. "VisibleWhen, and are matched by the header search filter.",
})
bSec:AddButton({
    Text = "A normal button",
    Tooltip = "press flash + accent glow included",
    Callback = function() print("[Tour] button pressed") end,
})

local sSec = Elements:AddSection("Static text")
sSec:AddLabel("Labels are single-line muted text.")
sSec:AddLabel({ Text = "They also accept a table form." }) -- both forms work
sSec:AddDivider() -- hairline separator between rows
local para = sSec:AddParagraph({
    Title = "Paragraphs wrap long text",
    Content = "This body text is updatable: press the button below and "
        .. ":Set() swaps the content without rebuilding anything.",
})
sSec:AddButton({
    Text = "Update the paragraph above",
    Callback = function()
        para:Set("Updated at " .. os.date("%H:%M:%S") .. " - handles let you mutate elements later.")
    end,
})

--==================================================================--
--  TAB: INPUTS                                                      --
--==================================================================--
local Inputs = Window:AddTab("Inputs", "sliders-horizontal")

local slSec = Inputs:AddSection("Sliders")
slSec:AddParagraph({
    Title = "section:AddSlider(id, options)",
    Content = "Min, Max, Default, Increment, Suffix (label unit). Drag OR "
        .. "click anywhere on the rail. Increments snap; decimals render "
        .. "cleanly (try the 0.05-step slider below - no float noise).",
})

slSec:AddSlider("FOV", {
    Text = "Whole numbers",
    Min = 10, Max = 500, Default = 150, Increment = 5,
    Suffix = "px",
    Callback = function(v) print("[Tour] FOV =", v) end,
})

slSec:AddSlider("FineSlider", {
    Text = "Decimals (step 0.05)",
    Min = 0, Max = 2, Default = 1, Increment = 0.05,
    Suffix = "x",
})

slSec:AddButton({
    Text = "Read both sliders with :Get()",
    Callback = function()
        print("[Tour] FOV =", EZ.Flags.FOV, "| Fine =", EZ.Flags.FineSlider)
        EZ:Notify({
            Title = "Slider values",
            Content = "FOV " .. tostring(EZ.Flags.FOV) .. " - Fine " .. tostring(EZ.Flags.FineSlider),
            Duration = 2,
        })
    end,
})

local ddSec = Inputs:AddSection("Dropdowns")
ddSec:AddParagraph({
    Title = "section:AddDropdown(id, options)",
    Content = "Values list, Default, Multi. Lists open OUTSIDE their "
        .. "section (never clipped), close on outside click / scroll / "
        .. "minimise. Multi selections arrive as a {value=true} map.",
})

ddSec:AddDropdown("TargetPart", {
    Text = "Single select",
    Values = { "Head", "Torso", "HumanoidRootPart" },
    Default = "Head",
    Callback = function(v) print("[Tour] TargetPart =", v) end,
})

ddSec:AddDropdown("MultiPick", {
    Text = "Multi select",
    Values = { "Alpha", "Beta", "Gamma", "Delta" },
    Multi = true,
    Default = { "Alpha" }, -- array form; arrives back as {Alpha=true}
    Callback = function(sel)
        local on = {}
        for k, v in sel do if v then table.insert(on, k) end end
        print("[Tour] MultiPick:", table.concat(on, ", "))
    end,
})

local teamDD = ddSec:AddDropdown("Team", {
    Text = "Swap my list at runtime",
    Values = { "All", "Enemy", "Friendly" },
    Default = "All",
})

ddSec:AddButton({
    Text = "dropdown:Refresh(newList)",
    Callback = function()
        local swapped = EZ.Flags.Team == "Red"
        local next_ = swapped and { "All", "Enemy", "Friendly" } or { "Red", "Blue" }
        teamDD:Refresh(next_)
        teamDD:Set(next_[1], true) -- silent: no callback spam
    end,
})

local inSec = Inputs:AddSection("Text input")
inSec:AddParagraph({
    Title = "section:AddInput(id, options)",
    Content = "Placeholder + optional title. The callback fires on focus "
        -- second argument tells you Enter vs clicking away
        .. "loss and receives (text, enterPressed).",
})

inSec:AddInput("Webhook", {
    Text = "Webhook URL",
    Placeholder = "https://discord.com/api/webhooks/...",
    Callback = function(text, enter)
        print("[Tour] Webhook =", text, "| enter =", enter)
    end,
})

local plSec = Inputs:AddSection("Player selector")
plSec:AddParagraph({
    Title = "section:AddPlayerSelector(id, options)",
    Content = "A dropdown preloaded with every player plus @me / @random / "
        .. "@nearest shortcuts. Refreshes itself on join/leave. "
        .. "ExcludeSelf=false keeps your own name in the list.",
})

local targetSel = plSec:AddPlayerSelector("LockTarget", {
    Text = "Lock target",
    ExcludeSelf = true,
})

plSec:AddButton({
    Text = "Resolve with :GetPlayers()",
    Callback = function()
        local picked = targetSel:GetPlayers() -- @random/@nearest resolved here
        local names = {}
        for _, p in picked do table.insert(names, p.Name) end
        EZ:Notify({
            Title = "Resolved targets",
            Content = #names > 0 and table.concat(names, ", ") or "nobody in server matches",
            Duration = 3,
            Type = #names > 0 and "success" or "warning",
        })
    end,
})

--==================================================================--
--  TAB: BINDS & COLORS                                              --
--==================================================================--
local Binds = Window:AddTab("Binds", "keyboard")

local kbSec = Binds:AddSection("Keybinds")
kbSec:AddParagraph({
    Title = "section:AddKeybind(id, options)",
    Content = "Click the combo chip, press any key. Modes: \"Toggle\" flips "
        .. "active on each press, \"Hold\" is true while held. Modifiers "
        .. "require Ctrl/Alt/Shift ({Ctrl=true} or {\"ctrl\"}). Saved value "
        .. "stays a plain KeyCode in EZ.Flags - modifiers live on the handle.",
})

kbSec:AddKeybind("AimKey", {
    Text = "Toggle mode",
    Default = Enum.KeyCode.G,
    Mode = "Toggle",
    Callback = function(active) print("[Tour] AimKey active =", active) end,
})

kbSec:AddKeybind("SprintKey", {
    Text = "Hold mode",
    Default = Enum.KeyCode.LeftShift,
    Mode = "Hold",
    Callback = function(down) print("[Tour] SprintKey down =", down) end,
})

local comboBind = kbSec:AddKeybind("ComboKey", {
    Text = "Modifier combo",
    Default = Enum.KeyCode.X,
    Modifiers = { Ctrl = true }, -- or { "ctrl" }
    Mode = "Toggle",
})

kbSec:AddButton({
    Text = "Rebind programmatically (:Configure)",
    Callback = function()
        comboBind:Configure({
            Key = Enum.KeyCode.K,
            Mode = "Hold",
            Modifiers = { Ctrl = true },
        })
        EZ:Notify({ Title = "Keybind", Content = "now Ctrl+K (Hold)", Duration = 2, Type = "success" })
    end,
})

kbSec:AddButton({
    Text = "Floating keybind menu",
    Tooltip = "draggable panel listing every bind - position persists",
    Callback = function() EZ:ToggleKeybindMenu() end,
})

local cpSec = Binds:AddSection("Color pickers")
cpSec:AddParagraph({
    Title = "section:AddColorPicker(id, options)",
    Content = "HSV canvas, hue bar, HEX box. Transparency adds an alpha "
        -- invariant: the FLAG stays a plain Color3; alpha is element-side
        .. "ramp. EZ.Flags keeps a Color3; read alpha from the handle "
        .. "with :GetTransparency().",
})

cpSec:AddColorPicker("ESPColor", {
    Text = "Solid color",
    Default = Color3.fromRGB(255, 50, 50),
    Callback = function(c) print("[Tour] ESPColor =", c) end,
})

local ghostPicker = cpSec:AddColorPicker("GhostColor", {
    Text = "With transparency",
    Default = Color3.fromRGB(124, 92, 252),
    Transparency = 0.5,
})

local ghostLevel = 0
cpSec:AddButton({
    Text = "Cycle :SetTransparency()",
    Callback = function()
        local steps = { 0, 0.25, 0.5, 0.75, 1 }
        ghostLevel = (ghostLevel % #steps) + 1
        ghostPicker:SetTransparency(steps[ghostLevel])
        EZ:Notify({ Title = "Transparency", Content = tostring(steps[ghostLevel]), Duration = 1 })
    end,
})

--==================================================================--
--  TAB: PROGRESS & LOGS                                             --
--==================================================================--
local Stats = Window:AddTab("Progress", "activity")

local pbSec = Stats:AddSection("Progress bars")

local progMax = 100
local progBar = pbSec:AddProgressBar("XPBar", {
    Text = "XP progress",
    Default = 0,
    Max = progMax,
    Color = Color3.fromRGB(120, 200, 255),
})

pbSec:AddButton({
    Text = "+25 via :Set()",
    Callback = function()
        local v = math.min(progBar:Get() + 25, progMax)
        progBar:Set(v) -- animates the fill + updates the counter label
    end,
})

pbSec:AddButton({
    Text = ":SetMax(250) - rescale in place",
    Callback = function()
        progMax = 250
        progBar:SetMax(progMax)
        progBar:Set(125)
    end,
})

local pbColors = {
    { "Accent",  nil },
    { "Success", Color3.fromRGB(80, 220, 120) },
    { "Warning", Color3.fromRGB(255, 180, 50) },
    { "Error",   Color3.fromRGB(255, 80, 80) },
}
local pbColorIdx = 0
pbSec:AddButton({
    Text = ":SetColor(...) - cycle",
    Callback = function()
        pbColorIdx = (pbColorIdx % #pbColors) + 1
        local c = pbColors[pbColorIdx][2]
        if c then progBar:SetColor(c) else progBar:SetColor(EZ.Theme.Accent) end
    end,
})

local lgSec = Stats:AddSection("Console log")
lgSec:AddParagraph({
    Title = "section:AddLog(options)",
    Content = "Height, MaxLines (old lines fall off). Methods: :Info "
        .. ":Warn :Error :Success :Print(text, color) :Clear(). Order is "
        .. "monotonic - lines never scramble.",
})

local tourLog = lgSec:AddLog({ Height = 120, MaxLines = 40 })
tourLog:Success("tour console ready")

lgSec:AddToggle("AutoProgress", {
    Text = "Auto-fill the XP bar",
    Default = false,
    Tooltip = "a task.spawn loop reads EZ.Flags.AutoProgress",
})

-- :OnChanged chains a private listener onto the element handle.
local chainToggle = lgSec:AddToggle("ChainedToggle", { Text = "Chained toggle (OnChanged)" })
chainToggle:OnChanged(function(v)
    tourLog:Info("chained fired: " .. tostring(v))
end)

for _, method in { "Info", "Warn", "Error", "Success" } do
    lgSec:AddButton({
        Text = "log:" .. method .. "()",
        Callback = function()
            tourLog[method](tourLog, method .. " @ " .. os.date("%H:%M:%S"))
        end,
    })
end

lgSec:AddButton({
    Text = "log:Clear()",
    Callback = function() tourLog:Clear() end,
})

-- Demo driver: respects the toggle AND dies with the library.
task.spawn(function()
    while not EZ._destroyed do
        if EZ.Flags.AutoProgress then
            local v = progBar:Get() + 5
            progBar:Set(v >= progMax and 0 or v)
        end
        task.wait(0.15)
    end
end)

--==================================================================--
--  TAB: DIALOGS                                                     --
--==================================================================--
local Dialogs = Window:AddTab("Dialogs", "message-square")

local dgSec = Dialogs:AddSection("Modals")
dgSec:AddParagraph({
    Title = "window:AddDialog(id, options)",
    Content = "Dims the whole UI and floats a card. FooterButtons is an "
        .. "ARRAY (or map) of {Title, Variant, Order, Callback}; variants: "
        .. "Ghost / Primary / Destructive. AutoDismiss=false makes the dim "
        .. "background inert, forcing a button choice. Handles expose "
        .. ":Dismiss(). Destructive actions everywhere in EZ use this.",
})

dgSec:AddButton({
    Text = "Confirm something destructive",
    Callback = function()
        Window:AddDialog("DlgDelete", {
            Title = "Delete everything?",
            Description = "This cannot be undone. (Click outside the card "
                .. "to dismiss - AutoDismiss defaults to true.)",
            FooterButtons = {
                { Title = "Cancel", Variant = "Ghost", Order = 1 },
                { Title = "Delete", Variant = "Destructive", Order = 2,
                  Callback = function(d)
                      d:Dismiss()
                      EZ:Notify({ Title = "Deleted", Content = "(pretend)", Duration = 2, Type = "error" })
                  end },
            },
        })
    end,
})

dgSec:AddButton({
    Text = "Primary action variant",
    Callback = function()
        Window:AddDialog("DlgPrimary", {
            Title = "Apply preset?",
            Description = "Primary buttons render in the accent colour.",
            FooterButtons = {
                { Title = "Later", Variant = "Ghost", Order = 1 },
                { Title = "Apply", Variant = "Primary", Order = 2,
                  Callback = function(d)
                      d:Dismiss()
                      EZ:Notify({ Title = "Applied", Duration = 2, Type = "success" })
                  end },
            },
        })
    end,
})

dgSec:AddButton({
    Text = "Forced choice (AutoDismiss = false)",
    Callback = function()
        Window:AddDialog("DlgModal", {
            Title = "Accept the terms?",
            Description = "The dimmer ignores clicks now - Cancel/Agree "
                .. "are the only way out.",
            AutoDismiss = false,
            FooterButtons = {
                { Title = "Agree", Variant = "Primary", Order = 1,
                  Callback = function(d)
                      d:Dismiss()
                      tourLog:Success("terms accepted")
                  end },
                { Title = "Cancel", Variant = "Ghost", Order = 2 }, -- no cb = self-dismiss
            },
        })
    end,
})

--==================================================================--
--  TAB: LAYOUT                                                      --
--==================================================================--
local Layout = Window:AddTab("Layout", "layout-template")

-- Sections added THROUGH a sub-tab live inside it. The first sub-tab
-- activates automatically.
local subA = Layout:AddSubTab("Sub-tab A")
local subB = Layout:AddSubTab("Sub-tab B")

local secA = subA:AddSection("Inside sub-tab A")
secA:AddLabel("Only visible while Sub-tab A is selected.")
secA:AddToggle("SubAToggle", { Text = "A-only toggle" })

local secB = subB:AddSection("Inside sub-tab B")
secB:AddLabel("And this one belongs to B.")

Layout:AddSection("Notes"):AddParagraph({
    Title = "Building blocks",
    Content = "tab:AddSubTab(name) returns a horizontal pill row; "
        .. "sub:AddSection() nests sections under it. Plain sections are "
        .. "collapsible - tap a section TITLE to fold/unfold its rows. "
        .. "Everything stacks vertically with automatic sizing.",
})

Layout:AddSection("Search"):AddParagraph({
    Title = "How the search bar works",
    Content = "Typing filters EVERY registered element by its display text "
        .. "- rows fade, empty sections hide, sub-tabs hand visibility back "
        .. "when the query clears. Try 'fov', 'webhook' or 'combo'. Hidden "
        .. "rows (VisibleWhen) never leak back in. Keystrokes are coalesced "
        .. "to once per frame, so huge UIs stay smooth.",
})

--==================================================================--
--  TAB: SETTINGS                                                    --
--==================================================================--
local Settings = Window:AddTab("Settings", "settings")

local thSec = Settings:AddSection("Theme")
thSec:AddParagraph({
    Title = "ThemeManager",
    Content = "This dropdown lists the manager's five built-ins PLUS the "
        .. "library's eight presets (registered via AddTheme above). Your "
        .. "choice is saved to disk and restored on launch.",
})

thSec:AddDropdown("Theme", {
    Text = "Active theme",
    Values = ThemeManager:GetThemes(),
    Default = ThemeManager.Current,
    Callback = function(v)
        ThemeManager:SetTheme(v) -- live recolours EVERYTHING, addons included
        EZ:Notify({ Title = "Theme", Content = v, Duration = 2, Type = "success" })
    end,
})

thSec:AddLabel("Custom themes: ThemeManager:AddTheme(name, colorTable) then pick it here.")

local cfgSec = Settings:AddSection("Configs")
cfgSec:AddParagraph({
    Title = "SaveManager - configs",
    Content = "One-off snapshots of your current settings: create / list / "
        .. "load / overwrite / delete (destructive ones confirm via "
        .. "dialogs), Set as Autoload for launch restore, plus JSON "
        .. "import-export to the clipboard. Folder: EZTour/.",
})
SaveManager:BuildConfigSection(cfgSec, Window)

local prSec = Settings:AddSection("Profiles")
prSec:AddParagraph({
    Title = "Profiles",
    Content = "A CONFIG is a quick snapshot (and the thing Autoload "
        .. "restores on launch). A PROFILE is an extra named copy you flip "
        .. "between manually - handy for per-game or per-character setups. "
        .. "Loading one marks it Active; nothing here touches Autoload.",
})
SaveManager:BuildProfileUI(prSec, Window)

local uiSec = Settings:AddSection("UI & misc")

uiSec:AddSlider("UIScale", {
    Text = "UI scale (window:SetScale)",
    Min = 0.7, Max = 1.5, Default = 1, Increment = 0.05,
    Suffix = "x",
    Callback = function(v) Window:SetScale(v) end,
})

uiSec:AddButton({
    Text = "Toggle sidebar (or use the chevron)",
    Callback = function() Window:ToggleSidebar() end,
})

uiSec:AddButton({
    Text = "Haptic pulse (gamepads)",
    Callback = function() EZ:Haptic("heavy") end,
})

uiSec:AddButton({
    Text = "Check for update",
    Callback = function()
        local info = EZ:CheckForUpdate("YourName/YourRepo")
        if info then
            EZ:Notify({
                Title = "Update",
                Content = info.outdated
                    and ("new release: " .. info.latest)
                    or "up to date (" .. info.current .. ")",
                Duration = 4,
                Type = info.outdated and "info" or "success",
            })
        end
    end,
})

--==================================================================--
--  SHUTDOWN WIRING                                                  --
--  The header X calls EZ:Destroy(), which clears the library's OWN
--  ScreenGuis. Addons holding outside resources (QuickBar has its own
--  ScreenGui + Show/Hide hooks) must be torn down explicitly.
--==================================================================--
EZ:OnDestroy(function()
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHistory:Destroy() end)
end)

--==================================================================--
--  QUICKBAR PINS                                                    --
--  Must run AFTER the toggles exist: pins validate against live flags.
--  Hide the window (RightShift) to see the dock.
--==================================================================--
QuickBar:Pin("AutoProgress", { Icon = "activity" })
QuickBar:Pin("HelloToggle", { Icon = "sparkles" })
QuickBar:PinButton("Reset tour toggles", {
    Icon = "rotate-ccw",
    Callback = function()
        for id, elem in EZ._elements do
            if elem._type == "Toggle" and EZ.Flags[id] == true then
                elem:Set(false)
            end
        end
        EZ:Notify({ Title = "QuickBar", Content = "toggles reset", Duration = 2, Type = "info" })
    end,
})

--==================================================================--
--  AUTOLOAD PROFILE                                                 --
--  Profiles restore by pushing saved values INTO elements, so this has
--  to run after every tab above exists - earlier and it silently does
--  nothing. No-op when no autoload profile was set.
--==================================================================--
SaveManager:LoadAutoloadConfig()

--==================================================================--
--  WATERMARK                                                        --
--  Template tokens: {fps} {ping} {time} {user} {place}
--  and {flag:id} for live flag values (updates twice a second).
--==================================================================--
EZ:CreateWatermark({
    Text = "EZ TOUR | {fps} fps | {ping} ms | hello={flag:HelloToggle}",
})

----------------------------------------------------------------
-- STARTUP
----------------------------------------------------------------
EZ:Notify({
    Title = "EZ Tour",
    Content = "loaded - " .. #Icons:All() .. " icons, "
        .. #ThemeManager:GetThemes() .. " themes, 9 tabs",
    Duration = 4,
    Type = "success",
})

task.delay(0.8, function()
    EZ:Notify({
        Title = "Try this first",
        Content = "press RightShift, flip HelloToggle, watch the watermark",
        Duration = 6,
        Type = "info",
    })
end)

--[[------------------------------------------------------------------
    APPENDIX A - KEY SYSTEM (optional gate)

    Wrap everything above in a function and gate it:

    local passed = EZ:KeySystem({
        Title = "My Script",
        SubTitle = "Enter your key",
        Keys = { "plain-key" },                 -- plaintext (dev/test)
        HashedKeys = { "<sha256 hex>" },        -- recommended for release
        SaveKey = "MyKey.txt",                  -- stores the HASH, not raw
        MaxAttempts = 5,
        GetKeyLink = "https://discord.gg/...",  -- copy-link button
        OnLockout = function() end,
        Callback = function(success) ... end,
    })
    if not passed then return end

    APPENDIX B - API CHEAT SHEET

    WINDOW   :Show/:Hide/:Toggle/:Minimize/:Restore  :SetScale(s)/:GetScale
             :ToggleSidebar  :AddTab(name, icon) -> tab
             :AddDialog(id, {Title, Description, AutoDismiss, FooterButtons})
    TAB      :AddSection(name) -> sec   :AddSubTab(name) -> sub (+ :AddSection)
    SEC      AddToggle/AddSlider/AddButton/AddDropdown/AddInput/AddKeybind/
             AddColorPicker/AddLabel/AddDivider/AddParagraph/AddProgressBar/
             AddLog/AddPlayerSelector
    HANDLES  common: :Set(v[, silent]) :Get() :OnChanged(fn)
             dropdown+: :Refresh(list)          playerselector+: :GetPlayers()
             keybind : :IsActive :Configure{Key,Mode,Modifiers} :GetMode
                       :GetModifiers            picker: :SetTransparency(t)
             progress: :SetMax(m) :SetColor(c)  log: :Info/:Warn/:Error/
                       :Success/:Print(t,c)/:Clear()
             label/paragraph: :Set(text)
    LIBRARY  EZ.Flags  EZ._elements  EZ.Theme  EZ.Themes
             EZ:OnFlagChanged/OffFlagChanged(id, fn)
             EZ:Notify{Title,Content,Duration,Type}  EZ.MaxNotifications
             EZ:SetTheme(tbl)/GetTheme  EZ:SetIcons(pack)  EZ:ResolveIcon(ref)
             EZ:CreateWatermark{Text}   EZ:CreateKeybindMenu/Show/Hide/Toggle..
             EZ:Haptic("light|medium|heavy")  EZ:CheckForUpdate(repo)
             EZ:OnError(fn) EZ:GetErrors() EZ:OnDestroy(fn) EZ:Destroy()
             EZ:KeySystem{...}
-------------------------------------------------------------------]]

return "EZ Tour loaded"
