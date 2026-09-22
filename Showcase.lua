--[[
    ═══════════════════════════════════════════════════════════════════════
      EZ UI LIBRARY — SHOWCASE  (living documentation tour)
    ═══════════════════════════════════════════════════════════════════════

    Run it:
        loadstring(game:HttpGet(
            "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Showcase.lua"
        ))()

    Nine chapters, one per feature family. Every control carries a Tooltip
    that explains WHEN to reach for it — the tabs are written like the docs:
    read top to bottom and you have seen the whole library.

    Chapters
        1. Welcome    - the pitch, quick tips, what changed lately
        2. Inputs     - toggles, checkboxes, sliders, inputs, buttons
        3. Choices    - dropdowns in every flavour, tabboxes, players
        4. Keybinds   - toggle/hold/mouse/modifiers + the floating menu
        5. Visuals    - colours, progress, consoles, text, dividers
        6. Layout     - groupboxes, sub-tabs, pop-outs, 3D, passthrough
        7. Feedback   - notifications, dialogs, watermark, history
        8. System     - themes, cursor, anti-afk, panic, configs, loading
        9. Docs       - flags, handles, ordering rules, gotchas

    The auto-attached Settings tab (theme picker, configs, autoload, DPI,
    anti-afk...) ships on every window by default — no wiring needed.
]]

local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"

local EZ           = loadstring(game:HttpGet(repo .. "Library.lua"))()
local Icons        = loadstring(game:HttpGet(repo .. "addons/Icons.lua"))()
local SaveManager  = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local QuickBar     = loadstring(game:HttpGet(repo .. "addons/QuickBar.lua"))()
local NotifHistory = loadstring(game:HttpGet(repo .. "addons/NotificationHistory.lua"))()

---------------------------------------------------------------- SETUP
EZ:SetIcons(Icons)

-- Brand your persistence names so parallel scripts never collide
SaveManager:Bind(EZ, "EZShowcase")
ThemeManager:Bind(EZ, { File = "EZShowcase_Theme.txt" })
ThemeManager:LoadSaved()
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

---------------------------------------------------------------- WINDOW
-- Re-running the showcase replaces the previous copy
local stale = {}
for _, w in EZ.Windows do
    if w.Title == "EZ Showcase" then stale[#stale + 1] = w end
end
for _, w in stale do pcall(function() w:Destroy() end) end

local Window = EZ:CreateWindow({
    Title = "EZ Showcase",
    SubTitle = "living documentation for every feature",
    ToggleKey = Enum.KeyCode.RightShift,
    ToggleIcon = "sparkles",
    GeometryId = "ezshowcase",
})

QuickBar:Bind(EZ, Window, { MaxPins = 6 })
NotifHistory:Bind(EZ, Window)

EZ:OnDestroy(function()
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHistory:Destroy() end)
end)

-- HUD: always-on watermark with live tokens
EZ:CreateWatermark({
    Text = "EZ | {fps} fps | {ping} ms | {user} | tour={flag:Show_WelcomeOn}",
})

---------------------------------------------------------------- 1. WELCOME
local Welcome = Window:AddTab("Welcome", "home")
local hero = Welcome:AddSection("Welcome", "start here - everything is organized like the documentation")

hero:AddParagraph({
    Title = "What is this?",
    Content = "A guided tour of every feature in the library, written the way the "
        .. "docs are: each chapter explains a family of controls, and every control "
        .. "has a tooltip telling you WHEN to use it. Hover anything.",
})
hero:AddLabel({ DoesWrap = true, RichText = true,
    Text = "The <b>Settings tab</b> (bottom of the sidebar) is auto-attached by the library: "
        .. "theme picker, configs with autoload, DPI scale, corner radius, anti-afk and more. "
        .. "Press <font color=\"#7C5CFC\">RightShift</font> to hide the window - the dock lets you "
        .. "reopen it, panic, or show your keybinds." })

hero:AddDivider("Quick actions")

hero:AddToggle("Show_WelcomeOn", {
    Text = "Tour running",
    Description = "this flag is printed in the watermark, top-left",
    Default = true,
    Callback = function(v) print("[Showcase] tour =", v) end,
})

local heroBtns = Welcome:AddLeftGroupbox("Try it now", "zap", "one-click demos of the marquee features")
heroBtns:AddButton({ Text = "Welcome notification", Callback = function()
    EZ:Notify({ Title = "EZ Showcase", Content = "every chapter is a feature family - read them in order",
        Type = "success", Duration = 4 })
end })
heroBtns:AddButton({ Text = "Show the loading screen (3 steps)", Tooltip = "EZ:CreateLoading - the modal multi-stage loader",
    Callback = function()
        local ld = EZ:CreateLoading({ Title = "EZ Showcase", TotalSteps = 3, Description = "demo loader" })
        task.spawn(function()
            for i, msg in { "fetching...", "building UI...", "done!" } do
                ld:SetCurrentStep(i)
                ld:SetMessage(msg)
                task.wait(0.7)
            end
            ld:Continue()
        end)
    end })
heroBtns:AddButton({ Text = "Persistent progress notification", Tooltip = "Duration = false + TotalSteps + :ChangeStep",
    Callback = function()
        local n = EZ:Notify({ Title = "Installing script", Content = "starting...", Duration = false,
            TotalSteps = 4, Type = "info" })
        task.spawn(function()
            for step = 1, 4 do
                n:ChangeStep(step)
                n:ChangeDescription(("step %d of 4"):format(step))
                task.wait(0.6)
            end
            n:ChangeTitle("Installed")
            n:ChangeDescription("press the card's button to close it")
        end)
    end })

local whatsNew = Welcome:AddRightGroupbox("What changed lately", "history", "release highlights")
whatsNew:AddLabel({ DoesWrap = true, RichText = true, Text =
    "<b>4.2</b> loading screen, menu tap-toggles, pop-out\n"
    .. "<b>4.1</b> viewports, UI passthrough, utilities\n"
    .. "<b>4.0</b> persistent notifications, two-layer cursor\n"
    .. "<b>3.9</b> uniform handles, element catch-up\n"
    .. "<b>3.8</b> anti-afk  ·  <b>3.7</b> per-game configs" })
whatsNew:AddButton({ Text = "Check for updates", Callback = function()
    task.spawn(function()
        local info = EZ:CheckForUpdate()
        EZ:Notify({ Title = "Update check",
            Content = info and ("latest %s (you have %s)"):format(info.latest, info.current) or "offline",
            Type = info and (info.outdated and "warning" or "success") or "warning", Duration = 4 })
    end)
end })

---------------------------------------------------------------- 2. INPUTS
local Inputs = Window:AddTab("Inputs", "sliders-horizontal")
local inSec = Inputs:AddSection("Toggles, sliders, inputs, buttons", "the bread and butter - every control stores a flag you can read")

local left = Inputs:AddLeftGroupbox("Toggles & inputs", "toggle-left")
left:AddToggle("Show_Toggle", {
    Text = "Plain toggle",
    Tooltip = "WHEN: a persistent on/off setting. Flag: EZ.Flags.Show_Toggle",
    Default = true,
})
left:AddToggle("Show_ToggleDesc", {
    Text = "With description",
    Description = "a muted second line explains the setting in place",
    Default = false,
})
left:AddCheckbox("Show_Checkbox", {
    Text = "Checkbox variant",
    Tooltip = "WHEN: you prefer a square check over the pill switch (AddCheckbox, or EZ.ForceCheckbox = true)",
    Default = true,
})
left:AddToggle("Show_Advanced", { Text = "Show advanced rows", Default = false })
left:AddSlider("Show_SliderInt", {
    Text = "Integer slider",
    Min = 0, Max = 500, Default = 150, Increment = 5, Suffix = " studs/s",
    Tooltip = "WHEN: numeric settings. Click the value to TYPE an exact number",
})
left:AddSlider("Show_SliderFine", {
    Text = "Decimal slider",
    Min = 0, Max = 2, Default = 1, Increment = 0.05, Suffix = "x",
})
left:AddSlider("Show_SliderPrefix", {
    Text = "Prefix + suffix",
    Min = 0, Max = 1000, Default = 250, Increment = 25, Prefix = "$", Suffix = ".00",
    Tooltip = "v3.9: Prefix option - '$250.00'",
})
left:AddInput("Show_Input", {
    Text = "Text input",
    Placeholder = "https://discord.com/api/webhooks/...",
    Tooltip = "WHEN: free text. Callback fires on focus-lost: (text, enterPressed)",
    Callback = function(text, enter)
        if enter then print("[Showcase] input:", text) end
    end,
})
left:AddToggle("Show_AdvancedRow", {
    Text = "only visible while 'Show advanced rows' is ON",
    VisibleWhen = "Show_Advanced",
    Tooltip = "VisibleWhen: dependent options that appear with their parent",
})

local right = Inputs:AddRightGroupbox("Buttons & feedback", "mouse-pointer-2")
right:AddButton({ Text = "Plain button", Callback = function()
    EZ:Notify({ Title = "Pong", Content = "buttons are for actions, not settings", Duration = 2 })
end })
right:AddButton({ Text = "Button with tooltip", Tooltip = "WHEN: one-shot actions. For destructive ones, open a confirm dialog (Feedback chapter)",
    Callback = function()
        EZ:Notify({ Title = "Tip", Content = "use Window:AddDialog for destructive actions", Duration = 3, Type = "info" })
    end })
right:AddSlider("Show_ReadBack", { Text = "Read me with :Get()", Min = 0, Max = 100, Default = 42 })
right:AddButton({ Text = "Print every flag in this chapter", Callback = function()
    print("[Showcase] Show_SliderInt =", EZ.Flags.Show_SliderInt,
        "| Show_ReadBack =", EZ.Flags.Show_ReadBack,
        "| Show_Toggle =", EZ.Flags.Show_Toggle)
    EZ:Notify({ Title = "Flags", Content = "values printed to the F9 console", Duration = 2 })
end })
right:AddLabel({ DoesWrap = true, Text = "Flags are plain values: read EZ.Flags.Id anywhere; write through the handle (:Set) so the UI follows." })

---------------------------------------------------------------- 3. CHOICES
local Choices = Window:AddTab("Choices", "list-checks")
local chSec = Choices:AddSection("Dropdowns & pickers", "one-of-many, many-of-many, and everything between")

local chL = Choices:AddLeftGroupbox("Dropdowns", "list")
chL:AddDropdown("Show_DD", {
    Text = "Single select",
    Values = { "Legit", "Rage", "Casual" },
    Default = "Legit",
    Tooltip = "WHEN: one choice out of a few. The flag stores the string",
})
chL:AddDropdown("Show_DDKeys", {
    Text = "Dictionary values + locked entry",
    Values = { starter = "Starter", pro = "Pro", legacy = "Legacy (locked)" },
    Disabled = { legacy = true },
    Default = "starter",
    Tooltip = "WHEN: your code needs stable keys but users should see pretty labels; Disabled locks tiers",
})
chL:AddDropdown("Show_DDMulti", {
    Text = "Multi + searchable",
    Values = { "Aim", "Visuals", "Movement", "World", "Misc", "Fun" },
    Multi = true, Searchable = true,
    Default = { "Aim", "Visuals" },
    Tooltip = "WHEN: pick many from a long list. Open it - Select all/Clear row + search",
})
chL:AddDropdown("Show_DDIcons", {
    Text = "Value images",
    Values = { sword = "Sword", shield = "Shield", potion = "Potion" },
    ValueImages = { sword = "sword", shield = "shield", potion = "flask-round" },
    Default = "sword",
    Tooltip = "v3.9: icons per option (SetValueImages / AddValueImages)",
})
local swapDD
chL:AddDropdown("Show_DDSwap", { Text = "Runtime list swap", Values = { "Red", "Blue" }, Default = "Red" })
chL:AddButton({ Text = "Refresh + AddValues the list above", Callback = function()
    local dd = EZ._elements.Show_DDSwap
    dd:AddValues({ "Green" })
    dd:Set("Green", true)
    EZ:Notify({ Title = "Dropdown", Content = "AddValues appended 'Green'", Duration = 2 })
end })

local chR = Choices:AddRightGroupbox("Pickers & modes", "list-checks")
chR:AddPlayerSelector("Show_Target", {
    Text = "Player selector",
    ExcludeSelf = true,
    Tooltip = "WHEN: target pickers. @me/@random/@nearest resolve via :GetPlayers()",
})
chR:AddButton({ Text = "Resolve with :GetPlayers()", Callback = function()
    local list = EZ._elements.Show_Target:GetPlayers()
    local names = {}
    for _, p in list do names[#names + 1] = p.Name end
    EZ:Notify({ Title = "Target", Content = #names > 0 and table.concat(names, ", ") or "none", Duration = 3 })
end })
local tabbox = chR:AddTabBox("Show_Mode", { Tabs = { "Legit", "Rage" },
    Tooltip = "segmented modes with per-mode controls - the full TabBox story is in the Layout chapter" })
tabbox.Tabs["Legit"]:AddSlider("Show_LegitFOV", { Text = "FOV", Min = 10, Max = 180, Default = 90 })
tabbox.Tabs["Legit"]:AddToggle("Show_LegitSmooth", { Text = "Smoothing" })
tabbox.Tabs["Rage"]:AddSlider("Show_RageFOV", { Text = "FOV", Min = 0, Max = 360, Default = 180 })
tabbox.Tabs["Rage"]:AddToggle("Show_RageSilent", { Text = "Silent aim" })
tabbox:Select("Legit")
chR:AddButton({ Text = "TabBox:AddTab('Third')", Tooltip = "v3.9: tabs can be added after creation",
    Callback = function()
        local third = tabbox:AddTab("Third", "star")
        third:AddLabel("added at runtime")
        tabbox:Select("Third")
    end })

---------------------------------------------------------------- 4. KEYBINDS
local Binds = Window:AddTab("Keybinds", "keyboard")
local bSec = Binds:AddSection("Keybinds & the floating menu", "keys, mouse buttons, chords - all rebindable in place")

local bL = Binds:AddLeftGroupbox("Bindings", "keyboard")
bL:AddKeybind("Show_KeyToggle", { Text = "Toggle mode", Default = Enum.KeyCode.G, Mode = "Toggle",
    Tooltip = "WHEN: flip a feature with a key. Click the chip to capture a new key" })
bL:AddKeybind("Show_KeyHold", { Text = "Hold mode", Default = Enum.KeyCode.LeftShift, Mode = "Hold",
    Tooltip = "WHEN: while-pressed actions (sprint, charge)" })
bL:AddKeybind("Show_KeyMouse", { Text = "Mouse button (M2)", Default = Enum.UserInputType.MouseButton2,
    Tooltip = "M1-M3 can be bound just like keys" })
local combo = bL:AddKeybind("Show_KeyCombo", { Text = "Ctrl chord", Default = Enum.KeyCode.X, Modifiers = { Ctrl = true },
    Tooltip = "Modifiers gate the bind: { Ctrl = true } / { 'ctrl' }" })
bL:AddButton({ Text = ":Configure to Ctrl+H (Hold)", Callback = function()
    combo:Configure({ Key = Enum.KeyCode.H, Mode = "Hold", Modifiers = { Ctrl = true } })
    EZ:Notify({ Title = "Rebound", Content = "now Ctrl+H (Hold)", Type = "success", Duration = 2 })
end })

local bR = Binds:AddRightGroupbox("Menu & state", "menu")
bR:AddButton({ Text = "Toggle the keybind menu", Tooltip = "the floating cheatsheet - position persists; rows group per window",
    Callback = function() EZ:ToggleKeybindMenu() end })
bR:AddButton({ Text = "Force-activate the toggle bind", Tooltip = "SetActive works from code; the menu checkbox does the same by tap",
    Callback = function()
        local kb = EZ._elements.Show_KeyToggle
        kb:SetActive(not kb:IsActive())
        EZ:Notify({ Title = "Show_KeyToggle", Content = "active = " .. tostring(kb:IsActive()), Duration = 2 })
    end })
bR:AddLabel({ DoesWrap = true, Text = "Open the menu and tap the checkbox on a Toggle bind - v4.2 added tap-toggles for mobile parity." })

---------------------------------------------------------------- 5. VISUALS
local Visuals = Window:AddTab("Visuals", "palette")
local vSec = Visuals:AddSection("Colours, progress, text", "everything you can see - all theme-aware")

local vL = Visuals:AddLeftGroupbox("Colour & progress", "palette")
vL:AddColorPicker("Show_Color", { Text = "Colour picker", Default = Color3.fromRGB(124, 92, 252),
    Tooltip = "WHEN: any colour setting. HSV canvas + hex/RGB boxes + copy/paste" })
vL:AddColorPicker("Show_ColorPal", { Text = "With palette + transparency", Default = Color3.fromRGB(0, 255, 200),
    Transparency = 0.5,
    Palette = { Color3.fromRGB(255, 90, 90), Color3.fromRGB(90, 200, 255), Color3.fromRGB(120, 255, 140) },
    Tooltip = "v3.6: preset swatches + last-6 recents (close the popup to store one)" })
local bar = vL:AddProgressBar("Show_Bar", { Text = "XP", Max = 100, Default = 35,
    Tooltip = "WHEN: live numeric status. Drive it with :Set from your loop" })
vL:AddButton({ Text = "+10 XP", Callback = function() bar:Set((bar:Get() + 10) % 110) end })
vL:AddButton({ Text = "SetMax(200) / accent colour", Callback = function()
    bar:SetMax(200)
    bar:SetColor(EZ.Theme.Accent)
end })

local vR = Visuals:AddRightGroupbox("Text & dividers", "type")
vR:AddDivider("Divider with text")
vR:AddLabel({ DoesWrap = true, RichText = true, Text =
    "<b>RichText labels</b> - opt-in markup: <i>italic</i>, <font color=\"#7C5CFC\">accent</font>, "
        .. "<font face=\"Code\">code font</font>. Use DoesWrap for helper prose like this." })
vR:AddLabel({ Text = "Single-line muted label (classic style)" })
vR:AddParagraph({ Title = "Paragraphs", Content = "Wrapped body text with an optional title - "
    .. "updatable through :Set without rebuilding anything." })
vR:AddDivider()
local log = vR:AddLog({ Height = 110, MaxLines = 30, Text = "console",
    Tooltip = "WHEN: a scrollback of events the user re-reads later" })
log:Success("console ready")
vR:AddButton({ Text = "Push one of each log line", Callback = function()
    log:Info("info line")
    log:Warn("warning line")
    log:Error("error line")
    log:Print("custom colour", Color3.fromRGB(120, 200, 255))
end })
vR:AddButton({ Text = "Clear console", Callback = function() log:Clear() end })

---------------------------------------------------------------- 6. LAYOUT
local Layout = Window:AddTab("Layout", "layout-template")
local lSec = Layout:AddSection("Layout & embeds", "groupboxes align, sub-tabs nest, panels float, 3D and your own GUI embed")

-- Two-column groupboxes live on the TAB (sub-tabs only nest sections)
local gbL = Layout:AddLeftGroupbox("Left column", "align-start-vertical", "descriptions work here too")
gbL:AddToggle("Show_ColL", { Text = "left box toggle" })
gbL:AddLabel({ DoesWrap = true, Text = "Left and right groupboxes share one row so their tops line up - the layout Obsidian made famous." })
local gbR = Layout:AddRightGroupbox("Right column", "align-end-vertical", "and elements line up across")
gbR:AddToggle("Show_ColR", { Text = "right box toggle" })
gbR:AddSlider("Show_ColSld", { Text = "shared row height", Min = 0, Max = 100, Default = 50 })

local popDemo = Layout:AddLeftGroupbox("Pop-out demo", "external-link", "undock this box into a floating panel")
popDemo:AddToggle("Show_PopTgl", { Text = "a toggle" })
popDemo:AddButton({ Text = "Pop out / dock", Tooltip = "v4.2: drag the grip in the header; position clamps to screen",
    Callback = function() popDemo:TogglePoppedOut() end })

-- TabBox: segmented modes, each tab is a full section (structure element)
local tbDemo = Layout:AddRightGroupbox("TabBox", "columns", "segmented modes - each tab is a full section")
tbDemo:AddLabel({ DoesWrap = true, Text =
    "WHEN: sub-modes inside one panel whose options need their own controls. "
    .. "v3.9: tabs can be added at runtime, with icons." })
local layoutBox = tbDemo:AddTabBox("Show_LayoutTB", { Tabs = { "First", "Second" } })
layoutBox.Tabs["First"]:AddSlider("Show_LTBSld", { Text = "a control in tab 1", Min = 0, Max = 100, Default = 30 })
layoutBox.Tabs["First"]:AddToggle("Show_LTBTgl1", { Text = "toggles too" })
layoutBox.Tabs["Second"]:AddToggle("Show_LTBTgl2", { Text = "independent tab 2 state" })
layoutBox.Tabs["Second"]:AddInput("Show_LTBInp", { Text = "any element works", Placeholder = "each tab is a section" })
tbDemo:AddButton({ Text = "AddTab('Third', 'star')", Tooltip = "runtime AddTab with a lucide icon - the segments re-layout",
    Callback = function()
        local third = layoutBox:AddTab("Third", "star")
        third:AddLabel("added at runtime")
        layoutBox:Select("Third")
    end })

-- Sub-tabs nest pages inside a tab; each sub-tab holds sections
local embeds = Layout:AddSubTab("Embeds")
local eSec = embeds:AddSection("Embeds", "3D objects and your own GUI, inside the layout")

local demoPart = Instance.new("Part")
demoPart.Shape = Enum.PartType.Ball
demoPart.Material = Enum.Material.Neon
demoPart.Color = Color3.fromRGB(124, 92, 252)
eSec:AddViewport("Show_Viewport", { Object = demoPart, Height = 150,
    Text = "3D preview - drag to orbit, wheel to zoom", Tooltip = "AddViewport: the object is cloned into a WorldModel" })
eSec:AddButton({ Text = "Swap the viewport object", Callback = function()
    local wedge = Instance.new("WedgePart")
    wedge.Color = Color3.fromRGB(255, 130, 60)
    EZ._elements.Show_Viewport:SetObject(wedge)
end })

local passthroughHost = Instance.new("Frame")
passthroughHost.BackgroundColor3 = Color3.fromRGB(24, 22, 36)
passthroughHost.BackgroundTransparency = 0.15
local phLabel = Instance.new("TextLabel")
phLabel.Size = UDim2.fromScale(1, 1)
phLabel.BackgroundTransparency = 1
phLabel.Text = "your own GuiBase2d, embedded"
phLabel.TextColor3 = Color3.fromRGB(200, 200, 220)
phLabel.TextSize = 12
phLabel.Parent = passthroughHost
eSec:AddUIPassthrough("Show_Pass", { Instance = passthroughHost, Height = 64,
    Text = "UI passthrough", Tooltip = "AddUIPassthrough: any GUI, restored to its old parent on Destroy" })

---------------------------------------------------------------- 7. FEEDBACK
local Feedback = Window:AddTab("Feedback", "bell")
local fSec = Feedback:AddSection("Notifications & dialogs", "transient toasts, persistent progress cards, confirm dialogs")

local fL = Feedback:AddLeftGroupbox("Notifications", "bell-ring")
for _, t in { "info", "success", "warning", "error" } do
    fL:AddButton({ Text = "Type: " .. t, Callback = function()
        EZ:Notify({ Title = t:sub(1, 1):upper() .. t:sub(2), Content = "this is a '" .. t .. "' notification",
            Duration = 3, Type = t })
    end })
end
fL:AddButton({ Text = "With action buttons", Tooltip = "v3.6: buttons on the card; taking one dismisses it",
    Callback = function()
        EZ:Notify({ Title = "Save layout?", Content = "the card carries its own buttons", Type = "warning", Duration = 12,
            Buttons = {
                { Text = "Save", Callback = function()
                    pcall(function() SaveManager:Save("ShowcaseSnapshot") end)
                    EZ:Notify({ Title = "Saved", Content = "ShowcaseSnapshot written", Type = "success", Duration = 2 })
                end },
                { Text = "Later", Callback = function() end },
            } })
    end })
fL:AddButton({ Text = "Persistent + steps + sound", Tooltip = "Duration=false, TotalSteps, SoundId - all v4.0",
    Callback = function()
        local n = EZ:Notify({ Title = "Downloading assets", Content = "0%", Duration = false, TotalSteps = 5,
            Type = "info", SoundId = 12221967, Volume = 0.15 })
        task.spawn(function()
            for step = 1, 5 do
                n:ChangeStep(step)
                n:ChangeDescription(("%d%%"):format(step * 20))
                task.wait(0.5)
            end
            n:ChangeTitle("Download complete")
            n:ChangeDescription("dismiss with the X or leave it - your choice")
        end)
    end })
fL:AddButton({ Text = "Burst (MaxNotifications cap)", Callback = function()
    for i = 1, 7 do
        task.delay(i * 0.1, function()
            EZ:Notify({ Title = "Burst #" .. i, Content = "oldest evicts past the cap", Duration = 3 })
        end)
    end
end })

local fR = Feedback:AddRightGroupbox("Dialogs & history", "message-square")
fR:AddButton({ Text = "Confirm dialog (destructive)", Callback = function()
    Window:AddDialog("Show_DlgDelete", {
        Title = "Delete everything?",
        Description = "Destructive actions should always confirm first. Variants: Ghost / Primary / Destructive.",
        FooterButtons = {
            { Title = "Cancel", Variant = "Ghost", Order = 1 },
            { Title = "Delete", Variant = "Destructive", Order = 2, Callback = function(d)
                d:Dismiss()
                EZ:Notify({ Title = "Deleted", Content = "(pretend)", Type = "error", Duration = 2 })
            end },
        },
    })
end })
fR:AddButton({ Text = "Forced-choice dialog", Callback = function()
    Window:AddDialog("Show_DlgModal", {
        Title = "Accept the terms?",
        Description = "AutoDismiss = false: outside clicks are ignored.",
        AutoDismiss = false,
        FooterButtons = {
            { Title = "Agree", Variant = "Primary", Order = 1, Callback = function(d) d:Dismiss() end },
            { Title = "Decline", Variant = "Ghost", Order = 2 },
        },
    })
end })
fR:AddButton({ Text = "History stats (bell icon, top-right)", Callback = function()
    EZ:Notify({ Title = "History", Content = ("entries=%d unread=%d"):format(
        #NotifHistory:GetEntries(), NotifHistory:GetUnreadCount()), Duration = 3 })
end })
fR:AddLabel({ DoesWrap = true, Text = "The bell in the header keeps every notification; the badge counts unread. Watermark tokens: {fps} {ping} {time} {user} {place} {flag:id}." })

---------------------------------------------------------------- 8. SYSTEM
local System = Window:AddTab("System", "wand-2")
local sSec = System:AddSection("Appearance & system", "the whole UI recolours and rescales live")

local sL = System:AddLeftGroupbox("Look & feel", "brush")
sL:AddDropdown("Show_Theme", {
    Text = "Theme",
    Values = ThemeManager:GetThemes(),
    Default = ThemeManager.Current,
    Tooltip = "Switching recolours everything live, addons included",
    Callback = function(v) ThemeManager:SetTheme(v) end,
})
sL:AddButton({ Text = "Font: Jura -> Montserrat -> default", Callback = function()
    local cur = EZ._fontOverride
    EZ:SetFont(cur == "Jura" and "Montserrat" or (cur and "Default" or "Jura"))
end })
sL:AddButton({ Text = "Corner radius 8 / 14", Callback = function()
    EZ:SetCornerRadius(EZ._cornerRadiusOverride and 14 or 8)
end })
sL:AddButton({ Text = "Window scale 0.85 / 1", Callback = function()
    Window:SetScale(Window:GetScale() < 1 and 1 or 0.85)
end })
sL:AddButton({ Text = "Notification side Left / Right", Callback = function()
    EZ:SetNotificationSide(EZ._notifSide == "Left" and "Right" or "Left")
end })
sL:AddButton({ Text = "Toggle sidebar collapse", Callback = function() Window:ToggleSidebar() end })

local sR = System:AddRightGroupbox("Runtime & safety", "shield")
sR:AddToggle("Show_AntiAFK", {
    Text = "Anti-AFK",
    Description = "prevents the ~20 min idle kick",
    Default = false,
    Tooltip = "v3.8: answers Idled with a virtual press; EZ._antiAFKCount tracks prevented kicks",
    Callback = function(v) EZ:SetAntiAFK(v) end,
})
sR:AddToggle("Show_Cursor", {
    Text = "Two-layer cursor",
    Description = "crosshair + icon, follows the mouse",
    Default = false,
    Tooltip = "v4.0: EZ.Cursor API - colours, sizes, resets",
    Callback = function(on)
        if on then
            EZ.Cursor:ChangeCrossColor(Color3.fromRGB(255, 90, 90))
            EZ.Cursor:ChangeIcon("crosshair")
            EZ.Cursor:ChangeIconColor(Color3.fromRGB(120, 255, 140))
            EZ.Cursor:ChangeIconSize(UDim2.fromOffset(36, 36))
            EZ:SetCursorEnabled(true)
        else
            EZ.Cursor:ResetCursor()
            EZ:SetCursorEnabled(false)
        end
    end,
})
sR:AddButton({ Text = "Panic: off for 1.5s then restore", Tooltip = "universal kill switch - snapshots toggles/binds and restores",
    Callback = function()
        EZ:SetPanic(true)
        task.delay(1.5, function() EZ:SetPanic(false) end)
    end })
sR:AddButton({ Text = "Save + reload config round-trip", Callback = function()
    task.spawn(function()
        if SaveManager:Save("ShowcaseSnapshot") then
            task.wait(0.3)
            local ok = SaveManager:Load("ShowcaseSnapshot")
            EZ:Notify({ Title = "Configs", Content = ok and "saved + reloaded (per-game, 3.7)" or "load failed",
                Type = ok and "success" or "error", Duration = 3 })
        end
    end)
end })
sR:AddButton({ Text = "Hide window (see QuickBar pins)", Tooltip = "pinned toggles stay reachable while hidden",
    Callback = function()
        QuickBar:Pin("Show_WelcomeOn", { Icon = "sparkles" })
        QuickBar:Pin("Show_Toggle", { Icon = "toggle-left" })
        QuickBar:PinButton("Un-panic", {
            Icon = "shield",
            Callback = function() EZ:SetPanic(false) end,
        })
        task.delay(0.3, function() Window:Hide() end)
    end })
sR:AddButton({ Text = "Unload (EZ:Destroy)", Callback = function()
    task.delay(0.2, function() EZ:Destroy() end)
end })

---------------------------------------------------------------- 9. DOCS
local Docs = Window:AddTab("Docs", "book-open")
local dSec = Docs:AddSection("How the library works", "the mental model in four paragraphs")

dSec:AddLabel({ DoesWrap = true, RichText = true, Text =
    "<b>Flags.</b> Every value-bearing element stores its value in <font face=\"Code\">EZ.Flags[id]</font>. "
        .. "Read it anywhere; write through the handle - <font face=\"Code\">handle:Set(v[, silent])</font> - "
        .. "so the UI and callbacks follow. Direct flag writes do not move the UI." })
dSec:AddDivider()
dSec:AddLabel({ DoesWrap = true, RichText = true, Text =
    "<b>Handles.</b> Builders return handles with a uniform surface: "
        .. "<font face=\"Code\">.Frame, :Set, :Get, :SetText, :OnChanged, :SetVisible, :SetDisabled, :Destroy</font>. "
        .. "Destroy unregisters the id so configs, panic and the keybind menu stop tracking it." })
dSec:AddDivider()
dSec:AddLabel({ DoesWrap = true, RichText = true, Text =
    "<b>Ordering.</b> Bind managers before the window; build elements; then "
        .. "<font face=\"Code\">SaveManager:LoadAutoloadConfig()</font> LAST so restored values reach elements "
        .. "that already exist. QuickBar pins also go after their toggles." })
dSec:AddDivider()
dSec:AddLabel({ DoesWrap = true, RichText = true, Text =
    "<b>Everything else.</b> Themes recolour by value-matching - build from "
        .. "<font face=\"Code\">EZ.Theme.&lt;role&gt;</font> and any custom UI joins the party. "
        .. "Configs are namespaced per game (3.7). The Settings tab ships automatically." })

dSec:AddParagraph({ Title = "Canonical skeleton", Content =
    "1. loadstring Library + addons   2. EZ:SetIcons   3. Bind SaveManager/ThemeManager "
    .. "+ LoadSaved   4. CreateWindow   5. Bind QuickBar/NotifHistory + OnDestroy   6. Build tabs "
    .. "7. QuickBar:Pin   8. SaveManager:LoadAutoloadConfig()   9. Watermark + startup notifications" })

dSec:AddButton({ Text = "Print the full docs pointers to console", Callback = function()
    print("[Showcase] API reference : https://github.com/Beastaive22/EZ-UI-Library/blob/main/docs/API_LIBRARY.md")
    print("[Showcase] SaveManager  : docs/SAVE_MANAGER.md   ThemeManager: docs/THEME_MANAGER.md")
    print("[Showcase] Live harness  : tests/live/api-test.luau  ·  Self-testing tour: tests/live/showcase.luau")
    EZ:Notify({ Title = "Docs", Content = "paths printed to the F9 console", Duration = 3 })
end })

---------------------------------------------------------------- STARTUP
task.defer(function()
    pcall(function() SaveManager:LoadAutoloadConfig() end)
    EZ:Notify({ Title = "EZ Showcase", Content = "nine chapters, every feature - start at Welcome",
        Duration = 5, Type = "success" })
end)

return EZ
