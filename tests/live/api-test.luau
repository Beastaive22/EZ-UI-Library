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
            box:ReleaseFocus()
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
    for _, d in card:GetDescendants() do
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
