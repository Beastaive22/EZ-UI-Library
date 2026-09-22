--[[
    EZ UI Library — FULL FEATURE SHOWCASE + SELF-TEST (v3.6)
    Run via executor. Two purposes:
      1. Demonstrates EVERY feature with a "WHEN:" comment on each one.
      2. Self-tests: the "Self-test" tab runs ~25 live checks (including every
         3.6 regression fix) and prints PASS/FAIL into an on-screen console —
         you can verify the library yourself, no tooling needed.

    Source selection: if a local build is loaded on getgenv().EZ_LOCAL (see
    tests/README.md), it is used so you can test UNCOMMITTED changes; otherwise
    the library loads from the repo's main branch.
    Crash-safe: results always written to EZShowcaseResults.txt.
]]

local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local usingLocal = getgenv().EZ_LOCAL ~= nil
local EZ = usingLocal and getgenv().EZ_LOCAL or loadstring(game:HttpGet(repo .. "Library.lua"))()
local SaveManager = getgenv().SM_LOCAL or loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local Icons   = loadstring(game:HttpGet(repo .. "addons/Icons.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local QuickBar     = loadstring(game:HttpGet(repo .. "addons/QuickBar.lua"))()
local NotifHistory = loadstring(game:HttpGet(repo .. "addons/NotificationHistory.lua"))()

local results, started = {}, os.clock()
local function check(name, cond, extra)
    results[#results + 1] = ("%s %s%s"):format(cond and "PASS" or "FAIL", name,
        (cond == false and extra) and (" | " .. tostring(extra)) or "")
end
local function try(name, fn)
    local ok, err = pcall(fn)
    check(name, ok, ok and nil or tostring(err))
    return ok
end

-- fires a GuiButton's click handlers reliably: firesignal can silently
-- no-op on some connections, Connection:Fire() (sUNC) always reaches them
local function clickBtn(b)
    local ok = pcall(function()
        for _, c in getconnections(b.MouseButton1Click) do
            c:Fire()
        end
    end)
    if not ok then firesignal(b.MouseButton1Click) end
end

local Window, log1, visibleDD
local function runAll()
    ---------------------------------------------------------------- SETUP
    -- WHEN: bind managers BEFORE CreateWindow so AutoSettings adopts them
    -- instead of re-fetching/creating defaults. Use per-script brand names so
    -- parallel scripts never collide on disk.
    EZ:SetIcons(Icons) -- WHEN: once; then every icon slot accepts Lucide names
    SaveManager:Bind(EZ, "EZDemoConfigs")
    ThemeManager:Bind(EZ, { File = "EZDemo_Theme.txt" })
    ThemeManager:LoadSaved() -- WHEN: before window build = no colour flash
    for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

    ---------------------------------------------------------------- WINDOW
    -- Re-running the showcase reuses the library instance (EZ_LOCAL), so
    -- close any previous showcase window first or they pile up. Collect
    -- BEFORE destroying: Destroy() removes from EZ.Windows mid-iteration,
    -- which skips the next entry.
    local staleWindows = {}
    for _, w in EZ.Windows do
        local t = w.Title
        if t == "EZ Showcase" or t == "Selftest Hub" or t == "Second Hub" then
            staleWindows[#staleWindows + 1] = w
        end
    end
    for _, w in staleWindows do pcall(function() w:Destroy() end) end

    -- WHEN: one call per script. AutoSettings (default) auto-attaches a full
    -- Settings tab (theme picker, configs, autoload, DPI, corner radius...).
    Window = EZ:CreateWindow({
        Title = "EZ Showcase",
        SubTitle = usingLocal and "LOCAL BUILD (uncommitted)" or "every feature, and when to use it",
        ToggleKey = Enum.KeyCode.RightShift,   -- WHEN: hide/show hotkey; M1-M3 also accepted
        ToggleIcon = "sparkles",               -- WHEN: icon for the dock's Open tile
        GeometryId = "ezshowcase",             -- WHEN: stable persistence key (title edits don't orphan your saved layout)
    })
    check("CreateWindow", Window ~= nil)

    -- WHEN: dock surfaces that live outside the window; bind right after it
    QuickBar:Bind(EZ, Window, { MaxPins = 6 })
    NotifHistory:Bind(EZ, Window)              -- WHEN: keep a searchable notification log

    -- WHEN: explicit cleanup for anything holding its own ScreenGui
    EZ:OnDestroy(function()
        pcall(function() QuickBar:Destroy() end)
        pcall(function() NotifHistory:Destroy() end)
    end)

    ---------------------------------------------------------------- TABS
    local Home     = Window:AddTab("Home", "home")
    local Inputs   = Window:AddTab("Inputs", "sliders-horizontal")
    local Selects  = Window:AddTab("Selects", "list-checks")
    local Binds    = Window:AddTab("Binds", "keyboard")
    local Visuals  = Window:AddTab("Visuals", "palette")
    local Feedback = Window:AddTab("Feedback", "bell")
    local Layout   = Window:AddTab("Layout", "layout-template")
    local Polish   = Window:AddTab("Polish", "wand-2")
    local New36    = Window:AddTab("v3.6", "sparkles")
    local SelfTest = Window:AddTab("Self-test", "flask-conical")

    -- WHEN: AddSection = full-width block; AddLeftGroupbox/AddRightGroupbox =
    -- symmetric two-column layout for dense panels. Sections and groupboxes
    -- take an optional description (v3.6).
    local homeSec = Home:AddSection("Welcome", "every tab demos a feature family - tooltips explain when to reach for it")
    local lgb = Inputs:AddLeftGroupbox("Text & Numbers", "sliders-horizontal")
    local rgb = Inputs:AddRightGroupbox("Buttons & Players", "mouse-pointer-2")

    -- WHEN: Paragraph = static info block; Label = one muted line; Divider = hairline.
    homeSec:AddParagraph({
        Title = "Showcase",
        Content = "RightShift hides/shows; the minimized dock has Open / Panic / "
            .. "Keybinds tiles. The v3.6 tab demos the newest features and the "
            .. "Self-test tab verifies them live.",
    })
    homeSec:AddDivider()

    -- WHEN: Toggle = persistent boolean setting (writes a flag).
    homeSec:AddToggle("DemoShowcaseOn", {
        Text = "Showcase running",
        Description = "read EZ.Flags.DemoShowcaseOn; never write it directly", -- v3.6: description line
        Default = true,
        Callback = function(v) print("[Demo] showcase =", v) end,
    })

    -- WHEN: VisibleWhen = dependent options that only exist while a parent
    -- flag is ON. Keeps panels clean; hidden rows never leak into search.
    homeSec:AddToggle("DemoAdvanced", { Text = "Show advanced extras", Default = false })
    homeSec:AddToggle("DemoAdvancedRow", { Text = "advanced row", VisibleWhen = "DemoAdvanced" })

    ---------------------------------------------------------------- INPUTS
    -- WHEN: Slider = numeric setting; Increment/Suffix for clean decimals/units.
    lgb:AddSlider("DemoSpeed", { Text = "Speed", Min = 0, Max = 500, Default = 150,
        Increment = 5, Suffix = " studs/s", Tooltip = "click the value to type an exact number (v3.6)" })
    lgb:AddSlider("DemoFine", { Text = "Fine adjust", Min = 0, Max = 2, Default = 1,
        Increment = 0.05, Suffix = "x" })

    -- WHEN: Input = free text (webhooks, names). Callback gets (text, enterPressed).
    lgb:AddInput("DemoWebhook", { Text = "Webhook URL", Placeholder = "https://discord.com/api/webhooks/...",
        Callback = function(text, enter)
            if enter then EZ:Notify({ Title = "Webhook", Content = "saved on Enter", Type = "success", Duration = 2 }) end
        end })

    ---------------------------------------------------------------- INPUTS (right column)
    -- WHEN: Button = action. Destructive? pair with a Dialog (Feedback tab).
    rgb:AddButton({ Text = "Ping", Callback = function()
        EZ:Notify({ Title = "Pong", Content = "buttons are for actions, not settings", Duration = 2 })
    end })
    -- WHEN: PlayerSelector = target pickers; @me/@random/@nearest resolve via :GetPlayers().
    local sel = rgb:AddPlayerSelector("DemoTarget", { Text = "Target player", ExcludeSelf = true })
    rgb:AddButton({ Text = "Resolve target", Callback = function()
        local list = sel:GetPlayers()
        local names = {}
        for _, p in list do names[#names + 1] = p.Name end
        EZ:Notify({ Title = "Target", Content = table.concat(names, ", "), Duration = 2 })
    end })

    ---------------------------------------------------------------- SELECTS
    local selSec = Selects:AddSection("Choices")
    -- WHEN: single Dropdown = one-of-many choice.
    selSec:AddDropdown("DemoMode", {
        Text = "Single select",
        Values = { "Legit", "Rage", "Casual" },
        Default = "Legit",
        Tooltip = "flag stores the string",
    })
    -- WHEN: dictionary Values = stable key stored, pretty label shown.
    -- WHEN: Disabled = lock tiers/values that exist but are unavailable.
    selSec:AddDropdown("DemoSkin", {
        Text = "Skins (dictionary + locked value)",
        Values = { starter = "Starter", pro = "Pro", legacy = "Legacy (locked)" },
        Disabled = { legacy = true },
        Default = "starter",
        Tooltip = "flag stores 'starter'/'pro', display shows the label",
    })
    -- WHEN: Multi + Searchable = pick many from a long list. v3.6 adds a
    -- Select all / Clear row at the top of the open list and collapses long
    -- selections to "A, B +N more".
    selSec:AddDropdown("DemoMulti", {
        Text = "Multi select (searchable)",
        Values = { "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot" },
        Multi = true,
        Searchable = true,
        Default = { "Alpha" },
        Tooltip = "open it: Select all / Clear row + search; Set takes a map",
        Callback = function(selMap)
            local on = {}
            for k, v in selMap do if v then on[#on + 1] = k end end
            print("[Demo] multi:", table.concat(on, ", "))
        end,
    })
    -- WHEN: Refresh = swap choices at runtime (e.g. new game modes/teams).
    visibleDD = selSec:AddDropdown("DemoTeam", {
        Text = "Team list (swappable)",
        Values = { "Red", "Blue" },
        Default = "Red",
    })
    selSec:AddButton({ Text = "Swap team list at runtime", Callback = function()
        visibleDD:Refresh({ "Red", "Blue", "Green" })
        visibleDD:Set("Green", true) -- single dropdown: scalar is fine (multi takes a map)
    end })

    -- WHEN: TabBox = segmented sub-modes inside one panel; each tab is a full
    -- section. Use instead of a second dropdown when options need their own controls.
    local tb = selSec:AddTabBox("DemoWeapon", { Tabs = { "Legit", "Rage" } })
    tb.Tabs["Legit"]:AddSlider("DemoLegitFOV", { Text = "FOV", Min = 10, Max = 180, Default = 90 })
    tb.Tabs["Rage"]:AddToggle("DemoSilentAim", { Text = "Silent aim" })
    tb:Select("Legit")

    ---------------------------------------------------------------- BINDS
    local bindSec = Binds:AddSection("Keybinds")
    -- WHEN: Keybind Mode="Toggle" = flip a feature on/off with a key.
    bindSec:AddKeybind("DemoAimKey", { Text = "Toggle aim", Default = Enum.KeyCode.G,
        Mode = "Toggle", Callback = function(active) print("[Demo] aim", active) end })
    -- WHEN: Mode="Hold" = while-pressed actions (sprint, charge).
    bindSec:AddKeybind("DemoSprint", { Text = "Hold sprint", Default = Enum.KeyCode.LeftShift,
        Mode = "Hold", Callback = function(down) print("[Demo] sprint", down) end })
    -- WHEN: mouse buttons M1-M3 can be bound too; modifiers gate chords.
    bindSec:AddKeybind("DemoCombo", { Text = "Ctrl + mouse M2", Default = Enum.UserInputType.MouseButton2,
        Modifiers = { Ctrl = true }, Mode = "Toggle" })
    local rebindable = bindSec:AddKeybind("DemoRebindable", { Text = "Programmatic rebind", Default = Enum.KeyCode.K })
    bindSec:AddButton({ Text = ":Configure to Ctrl+H (Hold)", Callback = function()
        rebindable:Configure({ Key = Enum.KeyCode.H, Mode = "Hold", Modifiers = { Ctrl = true } })
        EZ:Notify({ Title = "Keybind", Content = "now Ctrl+H (Hold)", Type = "success", Duration = 2 })
    end })
    -- WHEN: SetActive = programmatically activate/deactivate a bind.
    bindSec:AddButton({ Text = "Force-activate aim bind", Callback = function()
        for id, elem in EZ._elements do
            if id == "DemoAimKey" and elem.SetActive then
                elem:SetActive(not elem.Active)
                EZ:Notify({ Title = "DemoAimKey", Content = "active=" .. tostring(elem.Active), Duration = 2 })
                break
            end
        end
    end })
    -- WHEN: floating keybind menu = on-screen cheatsheet; v3.6 groups rows
    -- under their owning window's name when 2+ windows have binds.
    bindSec:AddButton({ Text = "Toggle keybind menu", Tooltip = "draggable; position persists; grouped per window",
        Callback = function() EZ:ToggleKeybindMenu() end })

    ---------------------------------------------------------------- VISUALS
    local visSec = Visuals:AddSection("Colors, progress & console")
    -- WHEN: ColorPicker = any colour setting; Transparency for alpha ramp.
    visSec:AddColorPicker("DemoESPColor", { Text = "ESP colour", Default = Color3.fromRGB(124, 92, 252) })
    visSec:AddColorPicker("DemoGhost", { Text = "With transparency", Default = Color3.fromRGB(0, 255, 200),
        Transparency = 0.5 })
    -- WHEN: ProgressBar = live numeric status (farm progress, XP, load).
    local bar = visSec:AddProgressBar("DemoXP", { Text = "XP", Max = 100, Default = 30 })
    -- WHEN: Log = scrolling console for events the user can read later.
    log1 = visSec:AddLog({ Height = 120, MaxLines = 40 })
    log1:Success("showcase console ready")
    log1:Info("log = history of events; notify = transient popups")
    visSec:AddButton({ Text = "Drive the progress bar", Callback = function()
        local v = (bar:Get() + 10) % 110
        bar:Set(v)
        log1:Print(("XP -> %d"):format(v), Color3.fromRGB(120, 200, 255))
    end })
    visSec:AddButton({ Text = "Warn/Error into the log", Callback = function()
        log1:Warn("this is a warning line")
        log1:Error("this is an error line")
    end })

    ---------------------------------------------------------------- FEEDBACK
    local fbSec = Feedback:AddSection("Notifications & dialogs")
    -- WHEN: Notify = transient feedback; Type gives the icon/dot its colour.
    for _, t in { "info", "success", "warning", "error" } do
        fbSec:AddButton({ Text = "Notify: " .. t, Callback = function()
            EZ:Notify({ Title = t:sub(1, 1):upper() .. t:sub(2), Content = "Type = '" .. t .. "'", Duration = 3, Type = t })
        end })
    end
    fbSec:AddButton({ Text = "Burst test (MaxNotifications cap)", Callback = function()
        for i = 1, 7 do
            task.delay(i * 0.12, function()
                EZ:Notify({ Title = "Burst #" .. i, Content = "oldest auto-evicts past the cap", Duration = 4 })
            end)
        end
    end })
    -- WHEN: history bell (NotifHistory) keeps every notification readable later.
    fbSec:AddButton({ Text = "Notification history stats", Callback = function()
        EZ:Notify({ Title = "History", Content = ("entries=%d unread=%d"):format(
            #NotifHistory:GetEntries(), NotifHistory:GetUnreadCount()), Duration = 3 })
    end })
    -- WHEN: AddDialog = blocking confirmation for destructive/irreversible actions.
    fbSec:AddButton({ Text = "Confirm-style dialog", Callback = function()
        Window:AddDialog("DlgConfirm", {
            Title = "Delete the demo config?",
            Description = "Destructive actions should always confirm first.",
            FooterButtons = {
                { Title = "Cancel", Variant = "Ghost", Order = 1 },
                { Title = "Delete", Variant = "Destructive", Order = 2, Callback = function(d)
                    d:Dismiss()
                    pcall(function() SaveManager:Delete("DemoSnapshot") end)
                    EZ:Notify({ Title = "Deleted", Content = "DemoSnapshot removed", Type = "error", Duration = 2 })
                end },
            },
        })
    end })
    -- WHEN: AutoDismiss=false = forced choice (terms, warnings).
    fbSec:AddButton({ Text = "Forced-choice dialog", Callback = function()
        Window:AddDialog("DlgTerms", {
            Title = "Accept?",
            Description = "AutoDismiss=false: outside clicks ignored.",
            AutoDismiss = false,
            FooterButtons = {
                { Title = "Agree", Variant = "Primary", Order = 1, Callback = function(d) d:Dismiss() end },
                { Title = "Decline", Variant = "Ghost", Order = 2 },
            },
        })
    end })
    -- WHEN: error hooks capture callback crashes; UI never dies with your bug.
    fbSec:AddButton({ Text = "Crash a callback on purpose", Callback = function()
        error("intentional demo error")
    end })
    fbSec:AddButton({ Text = "How many errors captured?", Callback = function()
        EZ:Notify({ Title = "Error log", Content = #EZ:GetErrors() .. " captured (never crashed the UI)", Duration = 3 })
    end })

    ---------------------------------------------------------------- LAYOUT
    -- WHEN: SubTab = nested pages inside a tab (per-character config etc.).
    local subA = Layout:AddSubTab("Characters")
    local subB = Layout:AddSubTab("World")
    subA:AddSection("Inside Characters"):AddToggle("DemoSubTgl", { Text = "sub-tab toggle" })
    subB:AddSection("Inside World"):AddSlider("DemoSubSld", { Text = "Time of day", Min = 0, Max = 24, Default = 12 })
    -- WHEN: two-column groupboxes for dense settings panels.
    local l2 = Layout:AddLeftGroupbox("Left column", "align-start-vertical")
    local r2 = Layout:AddRightGroupbox("Right column", "align-end-vertical")
    l2:AddToggle("DemoColL", { Text = "left box toggle" })
    r2:AddToggle("DemoColR", { Text = "right box toggle" })
    Layout:AddSection("Full-width above the columns"):AddLabel("Sections render above groupbox columns.")

    ---------------------------------------------------------------- POLISH
    local polSec = Polish:AddSection("Live appearance & system")
    -- WHEN: appearance APIs recolour/rescale the WHOLE UI live.
    polSec:AddButton({ Text = "Font: Jura -> Montserrat -> default", Callback = function()
        local cur = EZ._fontOverride
        EZ:SetFont(cur == "Jura" and "Montserrat" or (cur and "Default" or "Jura"))
        EZ:Notify({ Title = "Font", Content = "swept all elements", Duration = 2 })
    end })
    polSec:AddButton({ Text = "Corner radius 8 / 14", Callback = function()
        EZ:SetCornerRadius(EZ._cornerRadiusOverride and 14 or 8)
    end })
    polSec:AddButton({ Text = "Scale 0.85 / 1", Callback = function()
        Window:SetScale(Window:GetScale() < 1 and 1 or 0.85)
    end })
    polSec:AddButton({ Text = "Notification side Left / Right", Callback = function()
        EZ:SetNotificationSide(EZ._notifSide == "Left" and "Right" or "Left")
    end })
    polSec:AddButton({ Text = "Toggle sidebar collapse", Callback = function() Window:ToggleSidebar() end })
    -- WHEN: background image = cosmetic wallpaper; auto-clears in 2s here.
    polSec:AddButton({ Text = "Background image demo (2s)", Callback = function()
        local id = EZ:ResolveIcon("sparkles")
        Window:SetBackgroundImage(id)
        task.delay(2, function() pcall(function() Window:SetBackgroundImage("") end) end)
    end })
    -- WHEN: custom cursor = themed pointer; re-applies on respawn.
    polSec:AddToggle("DemoCursor", { Text = "Custom cursor", Default = false, Callback = function(on)
        if on then
            EZ:SetCursorIcon(EZ:ResolveIcon("crosshair"))
            EZ:SetCursorEnabled(true)
        else
            EZ:SetCursorEnabled(false)
        end
    end })
    polSec:AddButton({ Text = "Haptic pulse (gamepad only)", Callback = function() EZ:Haptic("medium") end })

    ---------------------------------------------------------------- SYSTEM
    polSec:AddButton({ Text = "Watermark tokens demo", Callback = function()
        EZ:CreateWatermark({ Text = "SHOWCASE | {fps} fps | {ping} ms | {user} | place {place} | {flag:DemoShowcaseOn}" })
        EZ:Notify({ Title = "Watermark", Content = "tokens: fps/ping/time/user/place/flag:id", Duration = 3 })
    end })
    polSec:AddButton({ Text = "Panic: off 1.5s then restore", Callback = function()
        EZ:SetPanic(true)
        task.delay(1.5, function() EZ:SetPanic(false) end)
    end })
    polSec:AddButton({ Text = "Check for library update", Callback = function()
        task.spawn(function()
            local info = EZ:CheckForUpdate()
            if info then
                EZ:Notify({ Title = "Update check", Content = ("outdated=%s latest=%s"):format(
                    tostring(info.outdated), tostring(info.latest)), Duration = 4,
                    Type = info.outdated and "warning" or "success" })
            else
                EZ:Notify({ Title = "Update check", Content = "offline / request failed", Type = "warning", Duration = 3 })
            end
        end)
    end })
    polSec:AddButton({ Text = "Custom theme: apply Demo Brand", Callback = function()
        ThemeManager:AddTheme("Demo Brand", {
            Accent = Color3.fromRGB(255, 110, 60),
            Base = Color3.fromRGB(16, 12, 10),
        })
        ThemeManager:SetTheme("Demo Brand")
        task.delay(3, function() pcall(function() ThemeManager:SetTheme("Midnight") end) end)
    end })
    -- WHEN: config snapshot round-trip (SaveManager persists every flag type).
    polSec:AddButton({ Text = "Save + reload config round-trip", Callback = function()
        task.spawn(function()
            local ok = SaveManager:Save("DemoSnapshot")
            if ok then
                task.wait(0.3)
                local ok2 = SaveManager:Load("DemoSnapshot")
                EZ:Notify({ Title = "Config", Content = ok2 and "saved + reloaded" or "load failed",
                    Type = ok2 and "success" or "error", Duration = 3 })
            end
        end)
    end })
    -- WHEN: QuickBar pins = control key toggles while the window is hidden.
    polSec:AddButton({ Text = "Hide window (see QuickBar pins)", Callback = function()
        QuickBar:Pin("DemoShowcaseOn", { Icon = "sparkles" })
        QuickBar:Pin("DemoSpeed", { Icon = "gauge" })
        QuickBar:PinButton("Reset showcase toggles", {
            Icon = "rotate-ccw",
            Callback = function()
                for id, elem in EZ._elements do
                    if elem._type == "Toggle" and EZ.Flags[id] == true then elem:Set(false) end
                end
            end,
        })
        task.delay(0.3, function() Window:Hide() end)
    end })
    -- WHEN: unload = full teardown of windows + addons + listeners.
    polSec:AddButton({ Text = "Unload (EZ:Destroy)", Callback = function()
        task.delay(0.2, function() EZ:Destroy() end)
    end })

    -- Icon API demo, logged (WHEN: fuzzy-find icons while building UIs)
    try("Icon fuzzy search", function()
        local best = Icons:Fuzzy("shld")
        log1:Info("Fuzzy('shld') -> " .. tostring(best))
        for _, hit in Icons:Search("shield", 3) do
            log1:Print(("  %s (score %d)"):format(hit.name, hit.score), Color3.fromRGB(160, 160, 170))
        end
    end)

    ---------------------------------------------------------------- V3.6 TAB
    -- Every feature added in v3.6, interactive.
    local n36a = New36:AddSection("New elements", "everything shipped in v3.6 - hover the tooltips")
    -- WHEN: Toggle Description = explain a setting without a separate paragraph.
    n36a:AddToggle("Demo36Tgl", { Text = "Toggle with description", Default = true,
        Description = "the muted line under the label is opts.Description",
        Tooltip = "v3.6: AddToggle({ Description = ... })" })
    -- WHEN: Slider text entry = exact values without dragging (Rayfield-style).
    n36a:AddSlider("Demo36Slider", { Text = "Type an exact value", Min = 0, Max = 100, Default = 50,
        Tooltip = "v3.6: click the purple value label, type, press Enter" })
    -- WHEN: Multi dropdown bulk row + collapsed header.
    n36a:AddDropdown("Demo36Multi", {
        Text = "Multi with Select all / Clear",
        Values = { "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf" },
        Multi = true,
        Default = { "Alpha", "Bravo", "Charlie" },
        Tooltip = "v3.6: header shows 'A, B +N more'; list has Select all/Clear",
    })
    -- WHEN: ColorPicker palette + session recents.
    n36a:AddColorPicker("Demo36CP", { Text = "Palette + recents",
        Default = Color3.fromRGB(124, 92, 252),
        Palette = {
            Color3.fromRGB(255, 90, 90), Color3.fromRGB(90, 200, 255),
            Color3.fromRGB(120, 255, 140), Color3.fromRGB(255, 200, 80),
            Color3.fromRGB(230, 120, 255),
        },
        Tooltip = "v3.6: preset swatches + your last 6 picks (close the popup to store a recent)" })
    -- WHEN: RichText labels/paragraphs (opt-in only - never for user-typed text).
    n36a:AddLabel({ RichText = true,
        Text = "RichText label: <b>bold</b>, <i>italic</i>, <font color=\"#7C5CFC\">accent</font>" })
    n36a:AddParagraph({ Title = "RichText paragraph", RichText = true,
        Content = "You can mix <b>bold</b> and <font color=\"#7C5CFC\">colours</font> "
            .. "in paragraphs too. Opt-in per element." })
    -- WHEN: Notification actions = buttons on the card (clicking one dismisses it).
    n36a:AddButton({ Text = "Notification with action buttons", Callback = function()
        EZ:Notify({
            Title = "Save layout?",
            Content = "the card carries buttons; the icon is type-tinted",
            Type = "warning", Duration = 15,
            Buttons = {
                { Text = "Save now", Callback = function()
                    pcall(function() SaveManager:Save("DemoSnapshot") end)
                    EZ:Notify({ Title = "Saved", Content = "DemoSnapshot written", Type = "success", Duration = 2 })
                end },
                { Text = "Later", Callback = function() end },
            },
        })
    end })

    local n36b = New36:AddSection("New window options", "GeometryId + CloseBehavior")
    -- WHEN: GeometryId = stable persistence key. This button creates a
    -- throwaway window with its own key and CloseBehavior="window" so the X
    -- closes only that window - and its keybind shows up grouped in the menu.
    n36b:AddButton({ Text = "Spawn test window (GeometryId + CloseBehavior)", Callback = function()
        if getgenv().Demo36Win and not getgenv().Demo36Win._destroyed then
            getgenv().Demo36Win:Destroy()
        end
        local w2 = EZ:CreateWindow({
            Title = "Second Hub",
            GeometryId = "ezshowcase-second",
            CloseBehavior = "window", -- v3.6: X closes only this window
            SubTitle = "X me - the showcase stays alive",
        })
        w2:AddTab("Other", "box"):AddSection("S"):AddKeybind("Demo36OtherBind", {
            Text = "Other window bind", Default = Enum.KeyCode.J, Mode = "Toggle",
        })
        getgenv().Demo36Win = w2
    end })
    n36b:AddButton({ Text = "Open grouped keybind menu", Tooltip = "v3.6: rows group under their window's name when 2+ windows have binds",
        Callback = function() EZ:ShowKeybindMenu() end })
    n36b:AddButton({ Text = "Check geometry files on disk", Callback = function()
        local a = isfile and isfile("EZGeom_ezshowcase.txt")
        local b = isfile and isfile("EZGeom_ezshowcase-second.txt")
        EZ:Notify({ Title = "Geometry files", Content = ("showcase=%s second=%s (per-GeometryId)")
            :format(tostring(a), tostring(b)), Duration = 4 })
    end })

    ---------------------------------------------------------------- PARITY TAB
    -- v3.9 Obsidian-parity demos: uniform handles, checkbox variant, text
    -- dividers, value images, wrapped labels, SetDescription.
    local Parity = Window:AddTab("Parity", "equal")
    local pSec = Parity:AddSection("Element parity", "checkboxes, text dividers, value images, wrapped labels (3.9)")
    pSec:AddCheckbox("DemoCheckbox", { Text = "Checkbox visual",
        Description = "AddCheckbox - square + check (or EZ.ForceCheckbox = true)", Default = true })
    pSec:AddDivider("Grouped values")
    pSec:AddDropdown("DemoValueImages", {
        Text = "Value images + AddValues",
        Values = { sword = "Sword", shield = "Shield", potion = "Potion" },
        ValueImages = { sword = "sword", shield = "shield", potion = "flask-round" },
        Default = "sword",
        Tooltip = "v3.9: SetValueImages/AddValueImages via the icon pack",
    })
    pSec:AddLabel({ DoesWrap = true,
        Text = "Wrapped label: this label wraps across multiple lines because DoesWrap = true - long helper text without needing a full paragraph." })
    pSec:AddSlider("DemoPrefix", { Text = "Price", Min = 0, Max = 1000, Default = 250,
        Prefix = "$", Suffix = ".00", Increment = 25, Tooltip = "v3.9: SetPrefix; click the value to type" })
    pSec:AddButton({ Text = "Handles demo", Tooltip = "SetDisabled dims + blocks input; Destroy removes the element",
        Callback = function()
            local tmp = pSec:AddToggle("DemoHandles", { Text = "disappears in 2s" })
            task.delay(0.6, function() pcall(function() tmp:SetDisabled(true) end) end)
            task.delay(2.2, function() pcall(function() tmp:Destroy() end) end)
        end })
    local pGB = Parity:AddLeftGroupbox("Groupbox extras", "box", "SetDescription demo")
    pGB:AddToggle("DemoGBTgl", { Text = "toggle" })
    pGB:AddButton({ Text = "Change groupbox description", Callback = function()
        pGB:SetDescription("changed at " .. os.date("%H:%M:%S"))
    end })
    pGB:AddButton({ Text = "Hide/Show groupbox", Callback = function()
        pGB:SetVisible(false)
        task.delay(1, function() pcall(function() pGB:Show() end) end)
    end })

    -- v4.0 demos: persistent/step notifications + two-layer cursor
    pSec:AddButton({ Text = "Persistent progress notification", Tooltip = "v4.0: Duration=false + :ChangeStep + :ChangeTitle",
        Callback = function()
            local n = EZ:Notify({
                Title = "Loading session", Content = "initializing...", Duration = false,
                Type = "info", TotalSteps = 4, SoundId = 12221967, Volume = 0.2,
            })
            task.spawn(function()
                for step = 1, 4 do
                    n:ChangeStep(step)
                    n:ChangeDescription(("step %d of 4..."):format(step))
                    task.wait(0.8)
                end
                n:ChangeTitle("Done")
                n:ChangeDescription("this card stays until you press the button")
                n:ChangeStep(4)
            end)
            task.delay(4.5, function()
                pcall(function()
                    EZ:Notify({ Title = "Cleanup", Content = "closing the loader card", Duration = 3, Type = "info" })
                end)
            end)
        end })
    pSec:AddButton({ Text = "Two-layer cursor (4s)", Tooltip = "v4.0: crosshair + icon layers, colors and sizes",
        Callback = function()
            EZ.Cursor:ChangeCrossColor(Color3.fromRGB(255, 80, 80))
            EZ.Cursor:ChangeIcon("crosshair")
            EZ.Cursor:ChangeIconColor(Color3.fromRGB(120, 255, 140))
            EZ.Cursor:ChangeIconSize(UDim2.fromOffset(36, 36))
            EZ:SetCursorEnabled(true)
            task.delay(2, function() pcall(function() EZ.Cursor:ResetIcon() end) end)
            task.delay(4, function()
                pcall(function()
                    EZ.Cursor:ResetCursor()
                    EZ:SetCursorEnabled(false)
                end)
            end)
        end })

    ---------------------------------------------------------------- SELF-TEST TAB
    -- WHEN: an in-UI regression runner. Click "Run all checks" (it also runs
    -- once on load) and read the PASS/FAIL console; results also go to
    -- EZShowcaseResults.txt. Covers every 3.6 fix + the core API surface.
    local stSec = SelfTest:AddSection("Live self-test", "runs ~25 checks against this very library instance")
    local testLog = stSec:AddLog({ Height = 180, MaxLines = 60 })

    local tests = {}
    local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

    test("CreateWindow", function()
        assert(Window ~= nil and Window.ScreenGui ~= nil)
    end)
    test("Toggle Set/Get/OnChanged", function()
        local h = EZ._elements.DemoShowcaseOn
        assert(h and h._type == "Toggle")
        local fired = 0
        h:OnChanged(function() fired += 1 end)
        h:Set(false); h:Set(true)
        assert(fired == 2 and h.Get() == true)
    end)
    test("Slider snap", function()
        local h = EZ._elements.Demo36Slider
        local before = h.Get()
        h:Set(before + 0.4) -- default Increment 1 snaps down
        assert(h.Get() == before, tostring(h.Get()))
    end)
    test("Slider text entry (typed 88)", function()
        local h = EZ._elements.Demo36Slider
        -- locate THIS slider's row via its title label (the ScreenGui holds
        -- several sliders; a tree-wide EZSliderValue search could grab another)
        local rowFrame
        for _, d in Window.ScreenGui:GetDescendants() do
            if d:IsA("TextLabel") and d.Text == "Type an exact value" then rowFrame = d.Parent break end
        end
        assert(rowFrame, "v3.6 slider row not found")
        local btn
        for _, d in rowFrame:GetDescendants() do
            if d.Name == "EZSliderValue" then btn = d break end
        end
        assert(btn, "EZSliderValue missing")
        -- focus can be denied while the game window is backgrounded, which
        -- commits+destroys the editor instantly; retry the click
        local box
        for _ = 1, 3 do
            clickBtn(btn)
            task.wait(0.12)
            for _, d in rowFrame:GetDescendants() do
                if d.Name == "EZSliderEdit" then box = d break end
            end
            if box then break end
        end
        assert(box, "editor did not open")
        box.Text = "88"
        -- ReleaseFocus is unreliable when the OS window is backgrounded:
        -- fire the FocusLost commit connection directly instead
        pcall(function()
            for _, c in getconnections(box.FocusLost) do pcall(function() c:Fire(true) end) end
        end)
        task.wait(0.1)
        assert(h.Get() == 88, "typed value not committed: " .. tostring(h.Get()))
    end)
    test("Dropdown Set scalar (3.6 fix)", function()
        local h = EZ._elements.Demo36Multi
        h:Set("Delta")
        assert(h.Get().Delta == true)
    end)
    test("Dropdown Set array + map Default", function()
        local h = EZ._elements.Demo36Multi
        h:Set({ "Echo", "Foxtrot" })
        assert(h.Get().Echo == true and h.Get().Foxtrot == true)
        local dd2 = EZ._elements.DemoMulti
        assert(dd2 ~= nil)
    end)
    test("Dropdown header collapse (A, B +N more)", function()
        local h = EZ._elements.Demo36Multi
        h:Set({ Alpha = true, Bravo = true, Charlie = true })
        local found
        for _, d in Window.ScreenGui:GetDescendants() do
            if d:IsA("TextLabel") and d.Text:find("+1 more") then found = d.Text break end
        end
        assert(found, "collapsed header not found")
    end)
    test("Select all / Clear bulk row", function()
        local h = EZ._elements.Demo36Multi
        -- locate the dropdown's row via its TITLE label (the header text
        -- changes with selection; the title stays constant), then take the
        -- TextButton (the header) inside that row
        local elemFrame
        for _, d in Window.ScreenGui:GetDescendants() do
            if d:IsA("TextLabel") and d.Text == "Multi with Select all / Clear"
                and d.Parent and d.Parent:IsA("Frame") and d.Parent.Name ~= "EZToggle" then
                elemFrame = d.Parent break
            end
        end
        assert(elemFrame, "dropdown row not found")
        local header
        for _, d in elemFrame:GetChildren() do
            if d:IsA("TextButton") then header = d break end
        end
        assert(header, "dropdown header not found")
        clickBtn(header)
        task.wait(0.05)
        -- the OPEN popup lives at the shared-gui root; scope every lookup to
        -- it (and exclude the main window, which contains every docked
        -- dropdown's pre-rendered rows) so closed lists can't match
        local openList
        for _, d in Window.ScreenGui:GetChildren() do
            if d:IsA("Frame") and d.Name ~= "EZWindow" and d:FindFirstChild("EZBulkRow", true) then openList = d break end
        end
        assert(openList, "open list not found at gui root")
        local allBtn, clearBtn
        for _, d in openList:GetDescendants() do
            if d:IsA("TextButton") and d.Text == "Select all" then allBtn = d
            elseif d:IsA("TextButton") and d.Text == "Clear" then clearBtn = d end
        end
        assert(allBtn and clearBtn, "bulk row missing")
        clickBtn(allBtn)
        local n = 0
        for _ in h.Get() do n += 1 end
        assert(n == 7, "select all: " .. tostring(n))
        -- regression (3.6): the bulk row used to duplicate on every refresh
        -- because refreshItems only cleared TextButton children. Count rows
        -- inside the OPEN popup only.
        local bulkRows = 0
        for _, d in openList:GetDescendants() do
            if d.Name == "EZBulkRow" then bulkRows += 1 end
        end
        assert(bulkRows == 1, "bulk row duplicated in open list: " .. tostring(bulkRows))
        -- the Select-all refresh rebuilt the row: the old Clear button is
        -- destroyed (its connections died with it), so re-find the fresh one
        clearBtn = nil
        for _, d in openList:GetDescendants() do
            if d:IsA("TextButton") and d.Text == "Clear" then clearBtn = d break end
        end
        assert(clearBtn, "fresh Clear button missing")
        clickBtn(clearBtn)
        local m = 0
        for _ in h.Get() do m += 1 end
        assert(m == 0, "clear: " .. tostring(m))
        clickBtn(header) -- close
    end)
    test("Input Set/Get", function()
        local h = EZ._elements.DemoWebhook
        h:Set("probe", true)
        assert(h.Get() == "probe")
        h:Set("", true)
    end)
    test("Keybind Configure + grouping tag", function()
        local h = EZ._elements.DemoRebindable
        h:Configure({ Key = Enum.KeyCode.H, Mode = "Hold", Modifiers = { Ctrl = true } })
        assert(h.GetMode() == "Hold" and h.GetModifiers().Ctrl == true)
        assert(h._windowTitle ~= nil)
        h:Configure({ Key = Enum.KeyCode.K, Mode = "Toggle", Modifiers = {} })
    end)
    test("ColorPicker + palette swatches", function()
        local h = EZ._elements.Demo36CP
        h:Set(Color3.fromRGB(0, 0, 255))
        assert(h.Get().B > 0.99)
        local palSw
        for _, d in Window.ScreenGui:GetDescendants() do
            if d:IsA("TextButton") and d.Size == UDim2.new(0, 16, 0, 16)
                and d.BackgroundColor3 == Color3.fromRGB(255, 200, 80) then
                palSw = d break
            end
        end
        assert(palSw, "palette swatch missing")
        firesignal(palSw.MouseButton1Click)
        local c = h.Get()
        assert(math.abs(c.R - 1) < 0.01 and math.abs(c.G - 200 / 255) < 0.01)
    end)
    test("TabBox select", function()
        local h = EZ._elements.DemoWeapon
        h:Select("Rage")
        assert(h.Get() == "Rage")
        h:Select("Legit")
    end)
    test("ProgressBar", function()
        local h = EZ._elements.DemoXP
        h:Set(77)
        assert(h.Get() == 77)
    end)
    test("Log handle", function()
        local h = EZ._elements.DemoXP -- any handle; log asserted via method presence
        assert(log1.Info ~= nil and log1.Clear ~= nil)
    end)
    test("Notify action buttons", function()
        local clicked = false
        local card = EZ:Notify({ Title = "selftest", Content = "", Duration = 3,
            Buttons = { { Text = "Go", Callback = function() clicked = true end } } })
        local doBtn
        for _, d in card.Frame:GetDescendants() do
            if d:IsA("TextButton") and d.Text == "Go" then doBtn = d break end
        end
        assert(doBtn, "action button missing")
        clickBtn(doBtn)
        task.wait(0.05)
        assert(clicked == true)
    end)
    test("RichText labels", function()
        local found
        for _, d in Window.ScreenGui:GetDescendants() do
            if d:IsA("TextLabel") and d.RichText == true and d.Text:find("RichText") then found = true break end
        end
        assert(found, "no RichText label")
    end)
    test("Section description rendered", function()
        local found
        for _, d in Window.ScreenGui:GetDescendants() do
            if d:IsA("TextLabel") and d.Text == "everything shipped in v3.6 - hover the tooltips" then found = true break end
        end
        assert(found)
    end)
    test("Panic cycle", function()
        EZ:SetPanic(true)
        assert(EZ:IsPanic() == true)
        EZ:SetPanic(false)
        assert(EZ:IsPanic() == false)
    end)
    test("Theme presets + accent", function()
        local n = 0
        for _ in EZ.Themes do n += 1 end
        assert(n >= 8, tostring(n))
        assert(EZ.Theme.Accent ~= nil)
    end)
    test("CloseBehavior=window + GeometryId (spawn/close)", function()
        local before = #EZ.Windows
        local w2 = EZ:CreateWindow({
            Title = "Selftest Hub", GeometryId = "selftest", CloseBehavior = "window", AutoSettings = false,
        })
        w2:AddTab("t"):AddSection("s"):AddKeybind("SelftestBind", { Text = "b", Default = Enum.KeyCode.B })
        w2:Hide() -- triggers geometry save with the GeometryId key
        assert(isfile("EZGeom_selftest.txt"), "GeometryId file missing")
        local btn
        for _, d in w2._main:GetDescendants() do
            if d.Name == "EZCloseBtn" then btn = d break end
        end
        assert(btn, "EZCloseBtn missing")
        clickBtn(btn)
        task.wait(0.1)
        assert(#EZ.Windows == before, "X did not remove only its window")
        assert(EZ._destroyed == false)
    end)
    test("Notifications v2 (4.0)", function()
        local n = EZ:Notify({ Title = "v2", Content = "persistent probe", Duration = false, TotalSteps = 4 })
        n:ChangeTitle("v2 renamed")
        n:ChangeDescription("live update")
        n:ChangeStep(2)
        task.wait(0.15)
        assert(n.Frame.Parent ~= nil, "persistent card dismissed itself")
        local stepLbl
        for _, d in n.Frame:GetDescendants() do
            if d:IsA("TextLabel") and d.Text == "2/4" then stepLbl = d break end
        end
        assert(stepLbl, "step label missing")
        n:Destroy()
        task.wait(0.6) -- dismiss tween (0.25) + destroy delay (0.3)
        assert(n.Frame.Parent == nil, "Destroy failed")
    end)
    test("Cursor v2 (4.0)", function()
        EZ.Cursor:ChangeCrossColor(Color3.fromRGB(255, 80, 80))
        EZ.Cursor:ChangeIcon("crosshair")
        EZ:SetCursorEnabled(true)
        assert(EZ._cursorGui ~= nil and EZ._cursorCrossLabel ~= nil, "cursor overlay missing")
        EZ.Cursor:ChangeIconSize(UDim2.fromOffset(40, 40))
        assert(EZ._cursorIconLabel.Size == UDim2.fromOffset(40, 40))
        EZ.Cursor:ResetCursor()
        EZ:SetCursorEnabled(false)
        assert(EZ._cursorGui == nil, "cursor gui not cleaned")
    end)
    test("Uniform handles (3.9)", function()
        local h = EZ._elements.Demo36Slider
        assert(h.Frame ~= nil, "no Frame on handle")
        h:SetVisible(false)
        assert(h.Frame.Visible == false)
        h:SetVisible(true)
        assert(h.Frame.Visible == true)
        h:SetDisabled(true)
        assert(h:IsDisabled() == true)
        h:SetDisabled(false)
        h:SetText("Type an exact value")
    end)
    test("Element Destroy (3.9)", function()
        -- throwaway toggle on this very section; do NOT destroy a window here
        -- (EZ.Windows[1] IS the showcase window)
        local tmp = stSec:AddToggle("SelftestTmp", { Text = "tmp" })
        assert(EZ._elements.SelftestTmp ~= nil)
        tmp:Destroy()
        assert(EZ._elements.SelftestTmp == nil, "still registered")
        assert(tmp.Frame.Parent == nil, "frame still alive")
    end)
    test("Anti-AFK (3.8)", function()
        EZ:SetAntiAFK(true)
        local before = EZ._antiAFKCount or 0
        pcall(function()
            for _, c in getconnections(game:GetService("Players").LocalPlayer.Idled) do
                pcall(function() c:Fire() end)
            end
        end)
        assert(EZ:IsAntiAFK() == true, "not enabled")
        assert((EZ._antiAFKCount or 0) == before + 1, "idle not handled: " .. tostring(EZ._antiAFKCount))
        EZ:SetAntiAFK(false)
        assert(EZ:IsAntiAFK() == false)
    end)
    test("SaveManager per-game isolation (3.7)", function()
        SaveManager:SetPerGame(true)
        local gk = tostring((game.GameId ~= 0 and game.GameId) or game.PlaceId)
        local root = "EZDemoConfigs/" .. gk
        assert(SaveManager:Save("SelftestIso") == true, "Save failed")
        assert(isfile(root .. "/SelftestIso.json"), "config not in game namespace: " .. root)
        local json = SaveManager:SaveJSON("SelftestIso")
        assert(type(json) == "string" and json:find('"game"') ~= nil, "no metadata stamp")
        SaveManager:Delete("SelftestIso")
    end)
    test("Icon pack: Get/Fuzzy/Search", function()
        assert(Icons.Get and Icons:Get("zap") ~= nil)
        assert(Icons:Fuzzy("zap") ~= nil)
        assert(#Icons:Search("shield", 2) > 0)
    end)

    local function runSelfTest()
        task.spawn(function()
            local fails = 0
            for _, t in tests do
                local ok, err = pcall(t.fn)
                if ok then
                    testLog:Success("PASS " .. t.name)
                else
                    fails += 1
                    testLog:Error("FAIL " .. t.name .. " - " .. tostring(err))
                end
                task.wait(0.03)
            end
            local line = ("[Self-test] %d checks, %d failures"):format(#tests, fails)
            if fails == 0 then
                testLog:Success(line)
                EZ:Notify({ Title = "Self-test", Content = "all " .. #tests .. " checks passed", Type = "success", Duration = 4 })
            else
                testLog:Warn(line)
                EZ:Notify({ Title = "Self-test", Content = fails .. " failing - read the console tab", Type = "error", Duration = 4 })
            end
            check("Self-test run", fails == 0, fails .. " failures")
            pcall(function()
                writefile("EZShowcaseResults.txt",
                    ("[Showcase] %s build\n"):format(usingLocal and "LOCAL" or "repo")
                    .. table.concat(results, "\n"))
            end)
        end)
    end

    stSec:AddButton({ Text = "Run all checks", Callback = runSelfTest })

    -- auto-run once shortly after the window is built
    task.delay(1.5, runSelfTest)
end

local bodyOk, bodyErr = pcall(runAll)
if not bodyOk then check("RUN BODY", false, bodyErr) end

local function report()
    local fails = 0
    for _, line in results do if line:find("FAIL") then fails += 1 end end
    local summary = ("[Showcase] DONE: %d checks, %d failures, bodyOk=%s"):format(#results, fails, tostring(bodyOk))
    print("[Showcase]", summary)
    pcall(function()
        writefile("EZShowcaseResults.txt",
            ("[Showcase] %s build, %.2fs\n"):format(usingLocal and "LOCAL" or "repo", os.clock() - started)
            .. table.concat(results, "\n") .. "\n" .. summary)
    end)
end
report()
task.delay(2, report)

-- WHEN: LoadAutoloadConfig LAST — pushes saved values into elements that now exist.
task.defer(function()
    pcall(function() SaveManager:LoadAutoloadConfig() end)
    EZ:Notify({
        Title = "EZ Showcase v3.6",
        Content = usingLocal and "LOCAL build loaded - Self-test tab is running"
            or "loaded - explore every tab, RightShift to hide",
        Duration = 4, Type = "success",
    })
end)
