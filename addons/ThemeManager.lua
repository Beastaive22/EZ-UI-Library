--[[
    EZ ThemeManager
    Theme switching for the EZ UI Library
]]

local THEME_FILE = "EZTheme.txt"

-- Every colour role a theme may define. Custom tables are filtered against
-- this list so a stray non-Color3 value (hex string, number) can never reach
-- EZ.Theme and crash element creation / live recolouring afterwards.
local ROLE_KEYS = {
    "Base", "Surface", "Panel", "Border",
    "Accent", "AccentDark",
    "Text", "TextDim", "TextMuted",
    "Success", "Warning", "Error", "Info",
}

local function copyTheme(t)
    local c = {}
    for k, v in t do c[k] = v end
    return c
end

-- keeps only valid Color3 entries for known roles
local function sanitizeTheme(themeTable)
    local clean = {}
    if type(themeTable) ~= "table" then return clean end
    for _, role in ROLE_KEYS do
        local v = themeTable[role]
        if typeof(v) == "Color3" then clean[role] = v end
    end
    return clean
end

local ThemeManager = {
    Library = nil,
    Current = "Midnight",
    _applied = nil,
    Themes = {
        Midnight = {
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
        },
        Ocean = {
            Name = "Ocean",
            Base = Color3.fromRGB(8, 12, 18),
            Surface = Color3.fromRGB(14, 22, 34),
            Panel = Color3.fromRGB(20, 30, 46),
            Border = Color3.fromRGB(35, 55, 80),
            Accent = Color3.fromRGB(50, 140, 255),
            AccentDark = Color3.fromRGB(35, 100, 200),
            Text = Color3.fromRGB(220, 235, 250),
            TextDim = Color3.fromRGB(120, 150, 180),
            TextMuted = Color3.fromRGB(60, 85, 110),
            Success = Color3.fromRGB(60, 210, 140),
            Warning = Color3.fromRGB(255, 190, 60),
            Error = Color3.fromRGB(255, 90, 90),
            Info = Color3.fromRGB(80, 170, 255),
        },
        Rose = {
            Name = "Rose",
            Base = Color3.fromRGB(14, 10, 12),
            Surface = Color3.fromRGB(26, 18, 22),
            Panel = Color3.fromRGB(36, 24, 30),
            Border = Color3.fromRGB(65, 40, 50),
            Accent = Color3.fromRGB(240, 80, 130),
            AccentDark = Color3.fromRGB(190, 55, 100),
            Text = Color3.fromRGB(245, 230, 235),
            TextDim = Color3.fromRGB(170, 130, 145),
            TextMuted = Color3.fromRGB(110, 75, 90),
            Success = Color3.fromRGB(100, 220, 140),
            Warning = Color3.fromRGB(255, 180, 60),
            Error = Color3.fromRGB(255, 80, 80),
            Info = Color3.fromRGB(120, 160, 255),
        },
        Emerald = {
            Name = "Emerald",
            Base = Color3.fromRGB(8, 14, 10),
            Surface = Color3.fromRGB(14, 24, 18),
            Panel = Color3.fromRGB(20, 34, 26),
            Border = Color3.fromRGB(35, 60, 45),
            Accent = Color3.fromRGB(50, 210, 120),
            AccentDark = Color3.fromRGB(35, 160, 90),
            Text = Color3.fromRGB(225, 245, 232),
            TextDim = Color3.fromRGB(120, 170, 140),
            TextMuted = Color3.fromRGB(65, 100, 80),
            Success = Color3.fromRGB(80, 230, 130),
            Warning = Color3.fromRGB(255, 190, 50),
            Error = Color3.fromRGB(255, 85, 85),
            Info = Color3.fromRGB(80, 170, 240),
        },
        Sunset = {
            Name = "Sunset",
            Base = Color3.fromRGB(16, 10, 8),
            Surface = Color3.fromRGB(28, 18, 14),
            Panel = Color3.fromRGB(40, 26, 20),
            Border = Color3.fromRGB(70, 45, 35),
            Accent = Color3.fromRGB(255, 130, 50),
            AccentDark = Color3.fromRGB(200, 95, 35),
            Text = Color3.fromRGB(250, 238, 228),
            TextDim = Color3.fromRGB(180, 145, 120),
            TextMuted = Color3.fromRGB(110, 80, 60),
            Success = Color3.fromRGB(90, 220, 120),
            Warning = Color3.fromRGB(255, 200, 60),
            Error = Color3.fromRGB(255, 75, 75),
            Info = Color3.fromRGB(100, 170, 255),
        },
    }
}

-- frozen copy of the original Midnight. AddTheme merges from this, not from
-- self.Themes.Midnight: letting AddTheme overwrite Midnight would poison the
-- merge base and hand nil colours to every theme added afterwards.
local BASE_THEME = copyTheme(ThemeManager.Themes.Midnight)

function ThemeManager:Bind(library, opts)
    self.Library = library
    -- register so window:AddSettingsTab() can find us
    if library then library._themeManager = self end

    -- Per-brand persistence file. Every script using this library used to
    -- fight over the same workspace-root "EZTheme.txt"; give each brand its
    -- own via ThemeManager:Bind(EZ, { File = "YourBrand_Theme.txt" }).
    if type(opts) == "table" and type(opts.File) == "string" and #opts.File > 0 then
        THEME_FILE = opts.File
    end

    -- Direct EZ:SetTheme calls bypass this manager. Without invalidating
    -- _applied, re-picking the theme you were already on did nothing because
    -- the dedupe guard believed it was still applied.
    if library and type(library.SetTheme) == "function" and not library._ezThemeManagerHooked then
        library._ezThemeManagerHooked = true
        local origSetTheme = library.SetTheme
        library.SetTheme = function(lib, themeTable)
            if not ThemeManager._internalApply then
                ThemeManager._applied = nil
            end
            return origSetTheme(lib, themeTable)
        end
    end

    return self
end

function ThemeManager:SetTheme(name)
    if type(name) ~= "string" or not self.Themes[name] then return false end
    -- Re-applying the active theme reruns a full UI recolour sweep (every
    -- instance, several property probes each) plus a disk write for zero
    -- visual change. Scripts that re-apply settings on respawn would pay
    -- that every time, so skip when this manager already applied it.
    if self._applied == name then return true end
    self.Current = name
    self._applied = name
    if self.Library then
        -- pass a sanitized copy so malformed entries cannot leak into EZ.Theme
        -- (flagged so the library wrapper does not invalidate our dedupe)
        ThemeManager._internalApply = true
        self.Library:SetTheme(sanitizeTheme(self.Themes[name]))
        ThemeManager._internalApply = nil
    end
    -- save preference
    pcall(function()
        writefile(THEME_FILE, name)
    end)
    return true
end

function ThemeManager:GetThemes()
    local names = {}
    for k in self.Themes do
        table.insert(names, k)
    end
    -- stable order; hash iteration reshuffled the theme dropdown every run
    table.sort(names)
    return names
end

function ThemeManager:AddTheme(name, themeTable)
    if type(name) ~= "string" or #name == 0 then return false end
    if type(themeTable) ~= "table" then return false end

    -- Fill gaps from the frozen Midnight base: a partial table would
    -- otherwise leave the library reading nil colours. Values that are not
    -- Color3 are dropped with a warning instead of being copied through.
    local merged = copyTheme(BASE_THEME)
    for _, role in ROLE_KEYS do
        local v = themeTable[role]
        if v ~= nil then
            if typeof(v) ~= "Color3" then
                warn(`[EZ ThemeManager] {name}.{role} ignored - expected Color3, got {typeof(v)}`)
            else
                merged[role] = v
            end
        end
    end
    merged.Name = name

    self.Themes[name] = merged

    -- replacing an existing theme invalidates the dedupe guard in SetTheme,
    -- otherwise the updated colours would never actually get applied
    if self._applied == name then
        self._applied = nil
    end

    return true
end

-- auto-load saved theme
function ThemeManager:LoadSaved()
    pcall(function()
        if not isfile or not readfile then return end
        if not isfile(THEME_FILE) then return end
        local raw = readfile(THEME_FILE)
        if type(raw) ~= "string" then return end
        -- a writefile round-trip can leave trailing whitespace, which would
        -- never match a theme key
        local saved = raw:match("^%s*(.-)%s*$")
        if saved and self.Themes[saved] then
            self:SetTheme(saved)
        end
    end)
end

return ThemeManager
