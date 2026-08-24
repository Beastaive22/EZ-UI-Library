--[[
    EZ loader - one-line entry point
    After publishing, your loadstring is:
        loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/loader.lua"))()
    Loads the library + every addon, builds a starter window, returns EZ.
]]

local base = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local EZ           = loadstring(game:HttpGet(base .. "Library.lua"))()
local Icons        = loadstring(game:HttpGet(base .. "addons/Icons.lua"))()
local SaveManager  = loadstring(game:HttpGet(base .. "addons/SaveManager.lua"))()
local ThemeManager = loadstring(game:HttpGet(base .. "addons/ThemeManager.lua"))()
local QuickBar     = loadstring(game:HttpGet(base .. "addons/QuickBar.lua"))()
local NotifHistory = loadstring(game:HttpGet(base .. "addons/NotificationHistory.lua"))()

----------------------------------------------------------------
-- SETUP  (rename the strings below to your brand)
----------------------------------------------------------------
EZ:SetIcons(Icons)

SaveManager:Bind(EZ, "EZConfigs")
ThemeManager:Bind(EZ, { File = "EZ_Theme.txt" })
for name, tbl in EZ.Themes do
    ThemeManager:AddTheme(name, tbl)
end
ThemeManager:LoadSaved()

----------------------------------------------------------------
-- WINDOW
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "EZ",
    SubTitle = "starter script",
    ToggleKey = Enum.KeyCode.RightShift,
    ToggleIcon = "sparkles",
})

QuickBar:Bind(EZ, Window)
NotifHistory:Bind(EZ, Window)

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

----------------------------------------------------------------
-- SETTINGS TAB  (themes + configs + profiles, fully wired)
----------------------------------------------------------------
local Settings = Window:AddTab("Settings", "settings")

local thSec = Settings:AddSection("Theme")
thSec:AddDropdown("Theme", {
    Text = "Active theme",
    Values = ThemeManager:GetThemes(),
    Default = ThemeManager.Current,
    Callback = function(v)
        ThemeManager:SetTheme(v)
    end,
})

local cfgSec = Settings:AddSection("Configs")
SaveManager:BuildConfigSection(cfgSec, Window)

local prSec = Settings:AddSection("Profiles")
SaveManager:BuildProfileUI(prSec, Window)

-- restore autoloaded config after every element exists
SaveManager:LoadAutoloadConfig()

EZ:Notify({ Title = "EZ", Content = "loaded - press RightShift to toggle", Duration = 3, Type = "success" })

return EZ
