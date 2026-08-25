--[[
    EZ ThemeManager
    Theme switching for the EZ UI Library
]]

local HttpService = game:GetService("HttpService")

local THEME_FILE = "EZTheme.txt"
-- custom (user-created) themes persist separately from the built-ins
local CUSTOM_FILE = "EZCustomThemes.txt"

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
    -- user-created themes (persisted to CUSTOM_FILE); built-ins stay in Themes
    CustomThemes = {},
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
        -- accented key so AddTheme("Rose") / the library's Rose Pine preset
        -- can never overwrite this built-in (bracket-quoted: identifiers
        -- must be ASCII)
        ["Rosé"] = {
            Name = "Rosé",
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
    if type(opts) == "table" and type(opts.CustomFile) == "string" and #opts.CustomFile > 0 then
        CUSTOM_FILE = opts.CustomFile
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

-- ~~ custom theme CRUD (Settings > Themes groupbox) ~~

local function colorToHex(c)
    return string.format("#%02X%02X%02X",
        math.floor(c.R * 255 + 0.5),
        math.floor(c.G * 255 + 0.5),
        math.floor(c.B * 255 + 0.5))
end

local function hexToColor(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("#", "")
    if #hex ~= 6 or not hex:match("^[%x]+$") then return nil end
    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    if not r or not g or not b then return nil end
    return Color3.fromRGB(r, g, b)
end

local function safeThemeName(v)
    if type(v) ~= "string" then return nil end
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" or #v > 64 then return nil end
    if v:find('[<>:"/\\|%?%z]') then return nil end
    return v
end

-- accepts "#RRGGBB" strings or {R,G,B} tables; returns a sanitized theme
local function parseThemeColors(entry)
    local colors = {}
    if typeof(entry) ~= "table" then return colors end
    for _, role in ROLE_KEYS do
        local v = entry[role]
        if type(v) == "string" then
            local c = hexToColor(v)
            if c then colors[role] = c end
        elseif typeof(v) == "table" then
            local r, g, b = tonumber(v.R), tonumber(v.G), tonumber(v.B)
            if r and g and b then colors[role] = Color3.fromRGB(r, g, b) end
        end
    end
    return colors
end

function ThemeManager:GetCustomThemeNames()
    local names = {}
    for k in self.CustomThemes do
        table.insert(names, k)
    end
    table.sort(names)
    return names
end

-- Create/overwrite a persisted custom theme from the CURRENT UI colours.
function ThemeManager:AddCustomTheme(name, themeTable)
    if not safeThemeName(name) then return false, "Invalid theme name" end
    -- a name that matches a NON-custom built-in must not be hijacked: the
    -- overwrite would silently replace the preset (and DeleteTheme could
    -- never remove the custom copy afterwards)
    if self.Themes[name] and not self.CustomThemes[name] then
        warn(`[EZ ThemeManager] "{name}" is a built-in theme - choose another name`)
        return false, "Name collides with a built-in theme"
    end
    local ok = self:AddTheme(name, themeTable)
    if not ok then return false, "Invalid theme table" end
    -- persist the sanitized version actually in use
    self.CustomThemes[name] = sanitizeTheme(self.Themes[name])
    self:SaveCustomThemes()
    return true
end

function ThemeManager:DeleteTheme(name)
    if type(name) ~= "string" or not self.CustomThemes[name] then
        return false, "Not a custom theme"
    end
    self.CustomThemes[name] = nil
    self.Themes[name] = nil
    if self._applied == name then self._applied = nil end
    self:SaveCustomThemes()
    return true
end

function ThemeManager:SaveCustomThemes()
    pcall(function()
        if not writefile then return end
        local payload = {}
        for name, theme in self.CustomThemes do
            local entry = {}
            for _, role in ROLE_KEYS do
                local c = theme[role]
                if typeof(c) == "Color3" then entry[role] = colorToHex(c) end
            end
            payload[name] = entry
        end
        writefile(CUSTOM_FILE, HttpService:JSONEncode(payload))
    end)
end

function ThemeManager:LoadCustomThemes()
    pcall(function()
        if not isfile or not readfile or not isfile(CUSTOM_FILE) then return end
        local raw = readfile(CUSTOM_FILE)
        if type(raw) ~= "string" or raw == "" then return end
        local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
        if not ok or typeof(data) ~= "table" then return end
        for name, entry in data do
            if type(name) == "string" and typeof(entry) == "table" then
                local colors = parseThemeColors(entry)
                if next(colors) ~= nil then
                    self.CustomThemes[name] = sanitizeTheme(colors)
                    self:AddTheme(name, colors)
                end
            end
        end
    end)
end

-- Returns JSON (hex colours + Name), or nil + err.
function ThemeManager:ExportTheme(name)
    local theme = self.Themes[name]
    if typeof(theme) ~= "table" then return nil, "Unknown theme" end
    local payload = { Name = name }
    for _, role in ROLE_KEYS do
        local c = theme[role]
        if typeof(c) == "Color3" then payload[role] = colorToHex(c) end
    end
    local ok, json = pcall(function() return HttpService:JSONEncode(payload) end)
    if not ok then return nil, "Encode failed" end
    return json, true
end

-- Accepts a single theme ({ Name?, Base="#..", ... }) or a map of themes.
-- preferredName is used when the JSON has no Name. Returns success, err.
function ThemeManager:ImportTheme(jsonStr, preferredName)
    if type(jsonStr) ~= "string" or jsonStr == "" then return false, "No JSON provided" end
    local ok, data = pcall(function() return HttpService:JSONDecode(jsonStr) end)
    if not ok or typeof(data) ~= "table" then return false, "Bad JSON" end

    local isSingle = false
    for _, role in ROLE_KEYS do
        if data[role] ~= nil then isSingle = true break end
    end

    if isSingle then
        local name = safeThemeName(data.Name) or safeThemeName(preferredName)
        if not name then return false, "No theme name (fill 'Custom theme name' or add Name in JSON)" end
        local colors = parseThemeColors(data)
        if next(colors) == nil then return false, "No valid colors in JSON" end
        self:AddCustomTheme(name, colors)
        -- apply immediately so an import is visible without a manual pick;
        -- bare `self.Current = name` never touched the UI or the dedupe guard
        self:SetTheme(name)
        return true
    end

    -- map form: { ["MyTheme"] = { Base = ... }, ... }
    local count = 0
    for name, entry in data do
        if type(name) == "string" and typeof(entry) == "table" then
            local colors = parseThemeColors(entry)
            if next(colors) ~= nil then
                self:AddCustomTheme(name, colors)
                count = count + 1
            end
        end
    end
    if count == 0 then return false, "No themes found in JSON" end
    return true
end

-- Clear the persisted default and fall back to Midnight.
function ThemeManager:ResetDefault()
    pcall(function()
        if delfile and isfile and isfile(THEME_FILE) then
            delfile(THEME_FILE)
        end
    end)
    self._applied = nil
    self.Current = "Midnight"
    self:SetTheme("Midnight")
    return true
end

-- auto-load saved theme
function ThemeManager:LoadSaved()
    -- custom themes must exist before a saved name can resolve to one
    self:LoadCustomThemes()
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
