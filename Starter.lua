--[[
    EZ loader - one-line entry point
    Your public loadstring:
        loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/loader.lua"))()
    Loads the library + every addon, builds a starter window. The Settings
    tab (themes/configs/profiles/autoload) is attached AUTOMATICALLY by the
    library - no wiring needed. Returns EZ.
]]

local base = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local EZ    = loadstring(game:HttpGet(base .. "Library.lua"))()
local Icons = loadstring(game:HttpGet(base .. "addons/Icons.lua"))()

-- Pre-register the managers so AutoSettings reuses them instead of fetching.
local ThemeManager = loadstring(game:HttpGet(base .. "addons/ThemeManager.lua"))()
local SaveManager  = loadstring(game:HttpGet(base .. "addons/SaveManager.lua"))()
local QuickBar     = loadstring(game:HttpGet(base .. "addons/QuickBar.lua"))()
local NotifHistory = loadstring(game:HttpGet(base .. "addons/NotificationHistory.lua"))()
EZ._addonCache = { ThemeManager = ThemeManager, SaveManager = SaveManager }

----------------------------------------------------------------
-- SETUP  (rename the strings below to your brand)
----------------------------------------------------------------
EZ:SetIcons(Icons)

SaveManager:Bind(EZ, "EZConfigs")
ThemeManager:Bind(EZ, { File = "EZ_Theme.txt" })

----------------------------------------------------------------
-- WINDOW  -  Settings tab is added automatically
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "EZ",
    SubTitle = "starter script",
    ToggleKey = Enum.KeyCode.RightShift,
    ToggleIcon = "sparkles",
    -- AutoSettings = false, -- uncomment ONLY if you build your own Settings tab
})

QuickBar:Bind(EZ, Window)
NotifHistory:Bind(EZ, Window)

-- EZ:Destroy() fires OnDestroy handlers BEFORE it empties the ScreenGuis, so
-- the addons get a live window to tear down; without this their dock and bell
-- would strand on screen after an unload/re-execution.
EZ:OnDestroy(function()
    pcall(function() QuickBar:Destroy() end)
    pcall(function() NotifHistory:Destroy() end)
end)

----------------------------------------------------------------
-- YOUR FEATURES  (replace the demos below)
----------------------------------------------------------------
local Main = Window:AddTab("Main", "zap")
local Sec = Main:AddSection("Features")

Sec:AddToggle("Speed", {
    Text = "Walk Speed",
    Callback = function(v)
        print("[EZ] Speed =", v)
    end,
})

Sec:AddSlider("Multiplier", {
    Text = "Multiplier",
    Min = 1, Max = 10, Default = 2, Increment = 0.5, Suffix = "x",
    Callback = function(v)
        print("[EZ] Multiplier =", v)
    end,
})

Sec:AddButton({
    Text = "Ping",
    Callback = function()
        EZ:Notify({ Title = "EZ", Content = "edit loader.lua to make this yours", Duration = 2 })
    end,
})

return EZ
