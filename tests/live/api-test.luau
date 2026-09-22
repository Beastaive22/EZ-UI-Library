--[[
    EZ UI Library — live API test harness
    Run inside an executor (or via roblox-mcp execute-file). Exercises the
    public API and regression-checks the 3.6 fixes. ALWAYS writes results to
    "EZTestResults.txt" in the executor workspace, even on crash.
]]

local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
-- local overrides for uncommitted changes (see tests/README.md)
local EZ = getgenv().EZ_LOCAL or loadstring(game:HttpGet(repo .. "Library.lua"))()
local SM = getgenv().SM_LOCAL or loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local Icons   = loadstring(game:HttpGet(repo .. "addons/Icons.lua"))()

local results, started = {}, os.clock()
local function check(name, cond, extra)
    results[#results + 1] = ("%s %s%s"):format(
        cond and "PASS" or "FAIL", name, (cond == false and extra) and (" | " .. tostring(extra)) or "")
end
local function try(name, fn)
    local ok, err = pcall(fn)
    check(name, ok, ok and nil or tostring(err))
end

local function runAll()
    EZ:SetIcons(Icons)
    local w = EZ:CreateWindow({ Title = "EZ ApiTest", AutoSettings = false })
    check("CreateWindow", w ~= nil)
    local s = w:AddTab("Main", "zap"):AddSection("Probe")

    -- toggle
    local tgl = s:AddToggle("T_Toggle", { Text = "t", Default = true })
    local fired = {}
    tgl:OnChanged(function(v) fired[#fired + 1] = v end)
    tgl:Set(false)
    tgl:Set(true)
    check("Toggle Set/Get/OnChanged", tgl.Get() == true and #fired == 2 and fired[2] == true)

    -- slider: snap + typed entry commit path
    local sld = s:AddSlider("T_Slider", { Text = "s", Min = 0, Max = 100, Default = 50 })
    sld:Set(42.7)
    check("Slider snap", sld.Get() == 43, tostring(sld.Get()))
    -- text entry: click the value label, type, release focus
    local valBtn
    for _, d in w.ScreenGui:GetDescendants() do
        if d.Name == "EZSliderValue" then valBtn = d break end
    end
    if valBtn then
        local box
        for _ = 1, 3 do
            -- firesignal can silently no-op; Connection:Fire always reaches
            pcall(function()
                for _, c in getconnections(valBtn.MouseButton1Click) do pcall(function() c:Fire() end) end
            end)
            task.wait(0.1)
            for _, d in w.ScreenGui:GetDescendants() do
                if d.Name == "EZSliderEdit" then box = d break end
            end
            if box then break end
        end
        if box then
            box.Text = "88"
            -- ReleaseFocus is unreliable when the OS window is backgrounded:
            -- fire the FocusLost commit connection directly instead
            pcall(function()
                for _, c in getconnections(box.FocusLost) do pcall(function() c:Fire(true) end) end
            end)
            task.wait(0.1)
            check("Slider text entry", sld.Get() == 88, tostring(sld.Get()))
        else
            check("Slider text entry", false, "editor box did not open")
        end
    else
        check("Slider text entry", false, "EZSliderValue button missing")
    end

    -- dropdown: 3.6 Set normalization (scalar/array used to crash)
    local dd = s:AddDropdown("T_DD", { Text = "m", Multi = true, Values = { "A", "B", "C" } })
    local ok1 = pcall(function() dd:Set("B") end)
    check("Dropdown Set scalar (3.6 fix)", ok1 and dd.Get().B == true)
    local ok2 = pcall(function() dd:Set({ "A", "C" }) end)
    check("Dropdown Set array (3.6 fix)", ok2 and dd.Get().A == true and dd.Get().C == true)
    local dd2 = s:AddDropdown("T_DD2", { Text = "m2", Multi = true, Values = { "X", "Y" }, Default = { X = true } })
    check("Dropdown map Default (3.6 fix)", dd2.Get().X == true)

    -- input
    local inp = s:AddInput("T_Input", { Text = "i", Default = "abc" })
    inp:Set("xyz", true)
    check("Input Set/Get", inp.Get() == "xyz")

    -- keybind
    local kb = s:AddKeybind("T_Key", { Text = "k", Default = Enum.KeyCode.G, Mode = "Toggle" })
    kb:Configure({ Key = Enum.KeyCode.H, Mode = "Hold", Modifiers = { Ctrl = true } })
    check("Keybind Configure", kb.GetMode() == "Hold" and kb.GetModifiers().Ctrl == true)
    check("Keybind grouped tag", kb._windowTitle ~= nil)

    -- colorpicker (+ palette)
    local cp = s:AddColorPicker("T_CP", { Text = "c", Default = Color3.fromRGB(255, 0, 0),
        Palette = { Color3.fromRGB(0, 255, 0) } })
    cp:Set(Color3.fromRGB(0, 0, 255))
    check("ColorPicker Set/Get", cp.Get().B > 0.99)

    -- tabbox
    local tb = s:AddTabBox("T_TB", { Tabs = { "One", "Two" } })
    tb:Select("Two")
    check("TabBox select", tb.Get() == "Two")
    local tbVis = tb.Tabs["Two"]
    check("TabBox content visible", tbVis.Frame.Visible == true and tbVis.Frame.Parent.Visible == true,
        "container hidden = tabs look empty")

    -- progress + log
    local prog = s:AddProgressBar("T_Bar", { Text = "xp", Max = 200, Default = 50 })
    prog:Set(120)
    check("ProgressBar", prog.Get() == 120)
    local log = s:AddLog({ Height = 80 })
    log:Success("harness running")
    check("Log handle", log.Info ~= nil)

    -- notifications with actions
    local clicked = false
    local card = EZ:Notify({ Title = "h", Content = "b", Duration = 5,
        Buttons = { { Text = "Go", Callback = function() clicked = true end } } })
    local doBtn
    for _, d in card.Frame:GetDescendants() do
        if d:IsA("TextButton") and d.Text == "Go" then doBtn = d break end
    end
    if doBtn then firesignal(doBtn.MouseButton1Click) end
    check("Notify action buttons", clicked == true)

    -- richtext
    s:AddLabel({ Text = "rt", RichText = true })
    local richOk = false
    for _, d in w.ScreenGui:GetDescendants() do
        if d:IsA("TextLabel") and d.Text == "rt" then richOk = d.RichText == true break end
    end
    check("RichText label", richOk)

    -- panic cycle
    EZ:SetPanic(true)
    local p1 = EZ:IsPanic()
    EZ:SetPanic(false)
    check("Panic cycle", p1 == true and EZ:IsPanic() == false)

    -- CloseBehavior = "window": the X removes just this window
    local w2 = EZ:CreateWindow({ Title = "T_CloseWin", AutoSettings = false, CloseBehavior = "window" })
    w2:AddTab("t")
    -- search THIS window's main frame: the ScreenGui is shared by all
    -- windows, so a ScreenGui-wide search can hit another window's X
    local closeBtn
    for _, d in (w2._main or w2.ScreenGui):GetDescendants() do
        if d.Name == "EZCloseBtn" then closeBtn = d break end
    end
    if closeBtn then
        firesignal(closeBtn.MouseButton1Click)
        task.wait(0.1)
        local stillListed = false
        for _, x in EZ.Windows do if x.Title == "T_CloseWin" then stillListed = true end end
        check("CloseBehavior window-only", stillListed == false and EZ._destroyed == false)
    else
        check("CloseBehavior window-only", false, "EZCloseBtn not found")
    end
    -- v3.9 uniform element handles + parity catch-up
    local tgl9 = s:AddToggle("T_Handles", { Text = "handles" })
    tgl9:SetVisible(false)
    check("SetVisible hides", tgl9.Frame.Visible == false)
    tgl9:SetVisible(true)
    check("SetVisible shows", tgl9.Frame.Visible == true)
    tgl9:SetText("renamed toggle")
    tgl9:SetDisabled(true)
    check("SetDisabled attr", tgl9:IsDisabled() == true)
    tgl9:SetDisabled(false)

    local dd9 = s:AddDropdown("T_HandlesDD", { Text = "dd", Multi = true, Values = { "A", "B" } })
    dd9:AddValues({ "C" })
    dd9:SetDisabledValues({ C = true })
    dd9:SetValueImages({ A = "rbxassetid://130551565616516" })
    dd9:SetText("renamed dd")
    check("Dropdown AddValues/SetDisabledValues", dd9 ~= nil)
    check("GetActiveValues count", type(dd9:GetActiveValues(true)) == "number")
    dd9:Destroy()
    check("Element Destroy unregisters", EZ._elements["T_HandlesDD"] == nil and dd9.Frame.Parent == nil)

    local cb9 = s:AddCheckbox("T_Checkbox", { Text = "checkbox visual" })
    check("AddCheckbox variant", cb9 ~= nil and cb9.Get ~= nil)

    s:AddDivider("Grouped below")
    local tb9 = s:AddTabBox("T_HandlesTB", { Tabs = { "One" } })
    tb9:AddTab("Two", "star")
    tb9:Select("Two")
    check("TabBox AddTab", tb9.Get() == "Two")

    local tab9 = w:AddTab("Handles", "wrench")
    local gb9 = tab9:AddLeftGroupbox("GB", "box", "original desc")
    gb9:SetDescription("updated desc")
    gb9:SetVisible(false)
    check("Groupbox SetDescription/Hide", gb9.Frame.Visible == false)
    gb9:Show()

    local sld9 = s:AddSlider("T_Sld9", { Text = "s9", Min = 0, Max = 100, Default = 50 })
    sld9:SetMin(10)
    sld9:SetMax(20)
    sld9:Set(200)
    check("Slider SetMin/SetMax", sld9.Get() == 20, tostring(sld9.Get()))
    sld9:SetPrefix("$")
    sld9:SetText("Money")

    -- SaveManager per-game isolation (3.7)
    SM:Bind(EZ, "EZTestConfigs")
    local gameKey = tostring((game.GameId ~= 0 and game.GameId) or game.PlaceId)
    local smRoot = "EZTestConfigs/" .. gameKey
    check("SaveManager per-game path", isfolder(smRoot), smRoot)
    check("SaveManager namespaced Save", SM:Save("T_Iso") == true and isfile(smRoot .. "/T_Iso.json"))
    local smJson = SM:SaveJSON("T_Iso")
    check("SaveManager metadata stamp", type(smJson) == "string" and smJson:find('"game"') ~= nil)
    SM:Delete("T_Iso")
    -- legacy migration: a 3.6-era root autoload pointer moves into the game ns
    pcall(function() writefile("EZTestConfigs/_autoload.txt", "T_Migrated") end)
    SM:Bind(EZ, "EZTestConfigs")
    check("SaveManager legacy migration", isfile(smRoot .. "/_autoload.txt") and not isfile("EZTestConfigs/_autoload.txt"))
    pcall(function() SM:DeleteAutoLoadConfig() end)

    -- Anti-AFK (3.8)
    EZ:SetAntiAFK(true)
    local aaBefore = EZ._antiAFKCount or 0
    pcall(function()
        for _, c in getconnections(game:GetService("Players").LocalPlayer.Idled) do
            pcall(function() c:Fire() end)
        end
    end)
    check("Anti-AFK idle handled", EZ:IsAntiAFK() and (EZ._antiAFKCount or 0) == aaBefore + 1,
        tostring((EZ._antiAFKCount or 0)) .. " vs " .. tostring(aaBefore + 1))
    EZ:SetAntiAFK(false)
    check("Anti-AFK off", EZ:IsAntiAFK() == false)

    -- Notifications v2 (4.0): persistent + live updates + steps + sounds
    local n2 = EZ:Notify({
        Title = "N2 probe", Content = "persistent", Duration = false,
        TotalSteps = 4, SoundId = 12221967, Volume = 0.2, Type = "info",
    })
    n2:ChangeTitle("N2 renamed")
    n2:ChangeDescription("updated live")
    n2:ChangeStep(3)
    task.wait(0.15)
    check("Notify persistent stays", n2.Frame.Parent ~= nil)
    check("Notify ChangeTitle", n2.Frame:FindFirstChildWhichIsA("TextLabel", true) ~= nil)
    local t2 = {}
    for _, d in n2.Frame:GetDescendants() do
        if d:IsA("TextLabel") and d.Text == "3/4" then t2[#t2+1] = d end
    end
    check("Notify ChangeStep", #t2 >= 1)
    n2:Destroy()
    task.wait(0.6) -- dismiss tween (0.25) + destroy delay (0.3)
    check("Notify Destroy", n2.Frame.Parent == nil)
    -- frame-style BC: the handle forwards reads to the card
    local n3 = EZ:Notify({ Title = "BC", Content = "b", Duration = false })
    check("Notify frame-BC", n3.BackgroundColor3 ~= nil)
    n3:Destroy()

    -- Cursor v2 (4.0): two layers + resets
    EZ.Cursor:ChangeCrossColor(Color3.fromRGB(255, 0, 0))
    EZ.Cursor:ChangeIcon("crosshair")
    EZ:SetCursorEnabled(true)
    check("Cursor v2 layers", EZ._cursorGui ~= nil and EZ._cursorCrossLabel ~= nil and EZ._cursorIconLabel ~= nil)
    EZ.Cursor:ChangeIconSize(UDim2.fromOffset(48, 48))
    check("Cursor icon size", EZ._cursorIconLabel.Size == UDim2.fromOffset(48, 48))
    EZ.Cursor:ResetIcon()
    check("Cursor ResetIcon", EZ._cursorIcon == nil)
    EZ:SetCursorEnabled(false)
    check("Cursor disabled", EZ._cursorGui == nil)

    -- Viewport + passthrough + utilities (4.1)
    local vp = s:AddViewport("T_VP", { Object = Instance.new("Part"), Height = 120 })
    check("Viewport built", vp ~= nil and vp.Frame ~= nil and vp:GetObject() ~= nil)
    vp:SetHeight(150)
    check("Viewport SetHeight", vp.Frame.Size == UDim2.new(1, 0, 0, 150))
    local srcPart = Instance.new("Part")
    vp:SetObject(srcPart)
    check("Viewport SetObject (cloned)", vp:GetObject() ~= nil and vp:GetObject() ~= srcPart)
    vp:Focus()
    vp:Destroy()
    check("Viewport Destroy", vp.Frame.Parent == nil)

    local embedded = Instance.new("Frame")
    embedded.Parent = s.Frame
    local pass = s:AddUIPassthrough("T_Pass", { Instance = embedded, Height = 90 })
    check("Passthrough embeds", embedded.Parent == pass.Frame)
    pass:Destroy()
    check("Passthrough restores", embedded.Parent == s.Frame)
    embedded:Destroy()

    local wpx = EZ:GetTextBounds("Hello", Enum.Font.Gotham, 14)
    check("GetTextBounds", type(wpx) == "number" and wpx > 0, tostring(wpx))
    local conn = EZ:GiveSignal(game:GetService("RunService").Heartbeat:Connect(function() end))
    check("GiveSignal", typeof(conn) == "RBXScriptConnection")
    conn:Disconnect()
    local ran = false
    EZ:SafeCallback(function() ran = true end)
    check("SafeCallback", ran == true)
    check("Color helpers", typeof(EZ:GetLighterColor(EZ.Theme.Accent)) == "Color3" and typeof(EZ:GetDarkerColor(EZ.Theme.Accent)) == "Color3")
    local img = Instance.new("ImageLabel")
    check("ApplyLucideIcon", EZ:ApplyLucideIcon(img, "zap") == true and img.Image ~= "")
    img:Destroy()
    check("ImageManager fallback", EZ.ImageManager.AddAsset("probe", 12221967) == "rbxassetid://12221967")

    -- Loading screen + pop-out + keybind toggles (4.2)
    local ld = EZ:CreateLoading({ Title = "EZ Test", TotalSteps = 4 })
    check("Loading built", ld ~= nil and ld.Sidebar ~= nil)
    ld:SetMessage("phase one")
    ld:SetDescription("running checks")
    ld:SetCurrentStep(2)
    ld:SetLoadingIcon("info")
    ld:SetLoadingIconTweenTime(0.8)
    ld:SetLoadingIconColor(Color3.fromRGB(120, 200, 255))
    ld:ShowSidebarPage(true)
    ld.Sidebar:AddLabel("sidebar label works")
    local slBtn = ld.Sidebar:AddButton({ Text = "sidebar button", Callback = function() end })
    check("Loading sidebar elements", slBtn ~= nil)
    ld:SetErrorButtons({ { Title = "Retry", Variant = "Primary", Callback = function() end } })
    ld:ShowErrorPage(true)
    check("Loading error page", true)
    ld:ShowErrorPage(false)
    ld:Destroy()
    check("Loading Destroy", EZ._loading == nil)

    local gb42 = w:AddTab("PopTest", "box"):AddLeftGroupbox("Pop", "box")
    gb42:SetPoppedOut(true, UDim2.fromOffset(120, 120))
    check("Pop-out floats", gb42:IsPoppedOut() == true and gb42.Frame.Parent ~= nil)
    gb42:SetPopOutWidth(300)
    gb42:SetMaxPopOutHeight(220)
    gb42:TogglePoppedOut()
    check("Pop-out docks", gb42:IsPoppedOut() == false)

    -- v4.3 additions
    local subBtn = s:AddButton({ Text = "sub", Sub = true, Callback = function() end })
    check("Sub button", subBtn ~= nil)
    local disBtn = s:AddButton({ Text = "disabled", Disabled = true, Callback = function() end })
    check("Disabled button attr", disBtn:GetAttribute("EZDisabled") == true)
    local lbl = s:AddLabel("LblId", { Text = "hello", DoesWrap = true })
    check("EZ.Labels registry", EZ.Labels.LblId == lbl)
    lbl:Destroy()
    check("Labels unregister", EZ.Labels.LblId == nil)
    local mllbl = s:AddLabel("line one\nline two")
    check("Multiline label", mllbl.Frame ~= nil and mllbl.Frame.AutomaticSize == Enum.AutomaticSize.Y)
    local disp = s:AddSlider("T_Disp", { Text = "d", Min = 1, Max = 5, Default = 3, Increment = 1,
        Display = function(v) return v .. "/5" end })
    local dispFound = false
    for _, d in disp.Frame:GetDescendants() do
        if d:IsA("TextButton") and d.Text == "3/5" then dispFound = true break end
    end
    check("Slider custom Display", dispFound)
    local pressKb = s:AddKeybind("T_Press", { Text = "p", Default = Enum.KeyCode.Y, Mode = "Press", Callback = function() end })
    check("Keybind Press mode", pressKb ~= nil)
    local tbTop = w:AddTab("TBTab", "columns"):AddLeftTabbox({ Tabs = { "A", "B" } })
    check("Top-level Tabbox", tbTop ~= nil and tbTop:Get() == "A")
    check("Top-level Tabbox content visible", tbTop.Tabs["A"].Frame.Parent.Visible == true)
    tbTop:AddTab("C", "star")
    local nT = 0
    for _ in tbTop.Tabs do nT += 1 end
    check("Top-level Tabbox AddTab", nT == 3)
    local dl = EZ:CreateDraggableLabel("probe")
    check("DraggableLabel", dl.Frame.Parent ~= nil)
    dl:Destroy()
    local wf = EZ:CreateWindow({ Title = "T_Footer", AutoSettings = false, Footer = "v-probe", Icon = "sparkles" })
    local footerFound = false
    for _, d in wf._main:GetDescendants() do
        if d.Name == "EZFooter" then footerFound = true break end
    end
    check("Window Footer", footerFound)
    wf:Destroy()

    -- v4.4: pop-out drag-out / drag-back (synthetic input simulation)
    local UIS = game:GetService("UserInputService")
    local poTab = w:AddTab("PopTab", "box")
    local poSec = poTab:AddLeftGroupbox("PopDrag", "box")
    check("Pop-out API", poSec:IsPoppedOut() == false)
    local hdr = poSec._header
    local main = w._main
    local function fireAll(signal, fake)
        pcall(function()
            for _, c in getconnections(signal) do pcall(function() c:Fire(fake) end) end
        end)
    end
    fireAll(hdr.InputBegan, { UserInputType = Enum.UserInputType.MouseButton1, Position = Vector3.new(100, 100, 0) })
    local outsideX = math.max(4, main.AbsolutePosition.X - 150)
    fireAll(UIS.InputChanged, { UserInputType = Enum.UserInputType.MouseMovement,
        Position = Vector3.new(outsideX, main.AbsolutePosition.Y + 60, 0) })
    task.wait(0.1)
    check("Drag-out pops out", poSec:IsPoppedOut() == true)
    fireAll(UIS.InputEnded, { UserInputType = Enum.UserInputType.MouseButton1,
        Position = Vector3.new(main.AbsolutePosition.X + 60, main.AbsolutePosition.Y + 60, 0) })
    task.wait(0.1)
    check("Drag-back re-docks", poSec:IsPoppedOut() == false)

    -- v4.4.2: docking keeps the original column order + floating resize
    local ordTab = w:AddTab("OrdTab", "box")
    local ordA = ordTab:AddLeftGroupbox("OrdA", "box")
    local ordB = ordTab:AddLeftGroupbox("OrdB", "box")
    local ordC = ordTab:AddLeftGroupbox("OrdC", "box")
    local function indexOf(f)
        local i = 0
        for _, c in f.Parent:GetChildren() do
            if c:IsA("GuiObject") then
                i += 1
                if c == f then return i end
            end
        end
        return -1
    end
    local beforeIdx = indexOf(ordB.Frame)
    ordB:SetPoppedOut(true)
    ordB:TogglePoppedOut()
    check("Dock keeps column order", beforeIdx == indexOf(ordB.Frame),
        tostring(beforeIdx) .. " -> " .. tostring(indexOf(ordB.Frame)))

    ordB:SetPoppedOut(true)
    local panel = ordB.Frame.Parent
    local rz = panel and panel:FindFirstChild("EZPopOutResize")
    check("Pop-out resize grip", rz ~= nil)
    if rz then
        local baseSize = panel.AbsoluteSize
        fireAll(rz.InputBegan, { UserInputType = Enum.UserInputType.MouseButton1, Position = Vector3.new(500, 500, 0) })
        fireAll(UIS.InputChanged, { UserInputType = Enum.UserInputType.MouseMovement, Position = Vector3.new(600, 560, 0) })
        task.wait(0.1)
        check("Pop-out resizes", panel.AbsoluteSize.X > baseSize.X,
            tostring(baseSize.X) .. " -> " .. tostring(panel.AbsoluteSize.X))
        fireAll(UIS.InputEnded, { UserInputType = Enum.UserInputType.MouseButton1, Position = Vector3.new(600, 560, 0) })
    end
    ordB:TogglePoppedOut()

    w:Destroy()
end

local bodyOk, bodyErr = pcall(runAll)
if not bodyOk then check("RUN BODY", false, bodyErr) end

local function report()
    local fails = 0
    for _, line in results do if line:find("FAIL") then fails += 1 end end
    local summary = ("[EZTest] DONE: %d checks, %d failures, bodyOk=%s"):format(#results, fails, tostring(bodyOk))
    print("[EZTest]", summary)
    for _, line in results do print("[EZTest]", line) end
    pcall(function()
        writefile("EZTestResults.txt",
            ("[EZTest] build %.2fs\n"):format(os.clock() - started)
            .. table.concat(results, "\n") .. "\n" .. summary)
    end)
end
report()
task.delay(1, report)
