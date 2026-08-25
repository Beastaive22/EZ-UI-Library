--[[
    EZ SaveManager (Obsidian-parity edition)
    Config save/load + named profiles + autoload + ignore lists + load order.

    Public API (superset of the previous EZ release - everything old still works):
        SaveManager:Bind(library, folder?)          legacy entry (alias of SetLibrary + SetFolder)
        SaveManager:SetLibrary(library)
        SaveManager:SetFolder(folder)               validated, builds folder tree
        SaveManager:SetSubFolder(sub)               nest configs under a subfolder
        SaveManager:GetPaths()                      ordered folder segments
        SaveManager:BuildFolderTree(skipExisting?)
        SaveManager:CheckFolderTree()
        SaveManager:CheckSubFolder(create?)

        SaveManager:SetIgnoreIndexes({ids})         never save/apply these flags
        SaveManager:ClearIgnoreIndexes()
        SaveManager:IgnoreThemeSettings()           preset for theme/UI internals

        SaveManager:SetLoadingOrder(enabled, {"Keybind","Dropdown",...})

        SaveManager:RefreshConfigList()
        SaveManager:GetConfigs()                    legacy alias
        SaveManager:SaveJSON(name?) -> json, ok, err
        SaveManager:LoadJSON(json) -> ok, err       accepts new AND legacy formats
        SaveManager:Save(name) / :Load(name) / :Delete(name)

        SaveManager:Export()                        legacy base64 export
        SaveManager:Import(str)

        Profiles: GetProfiles / GetActiveProfile / SaveProfile / LoadProfile /
                  DeleteProfile / RenameProfile / BuildProfileUI(section, window?)

        Autoload (points at a CONFIG):
        SaveManager:GetAutoloadConfig()      -> name | "none", ok, err
        SaveManager:SaveAutoloadConfig(name) -> ok, err
        SaveManager:LoadAutoloadConfig()
        SaveManager:DeleteAutoLoadConfig()   -> ok, err

        SaveManager:BuildConfigSection(section, window?)  full management UI
]]

local HttpService = game:GetService("HttpService")

--// Filesystem shims \\--
-- The is_____ family must answer yes/no, never throw. A handful of executors
-- still error on missing paths, which would bubble out of unrelated code.
local function shimFs(fn)
    if type(fn) ~= "function" then
        return function() return false end
    end
    return function(...)
        local ok, res = pcall(fn, ...)
        if not ok then return false end
        return res
    end
end

local FS_IsFolder = shimFs(isfolder)
local FS_IsFile = shimFs(isfile)
local FS_ListFiles = shimFs(listfiles)

--// Module \\--
local SaveManager = {
    Library = nil,

    Folder = "EZConfigs",
    SubFolder = "",

    Ignore = {},
    LoadingOrder = {},
    UseLoadingOrder = false,

    AutoloadConfig = nil,
}

-- names that hold manager state inside the folder; they can never be used
-- as config/profile names
local RESERVED = { autoload = true }

local AUTOLOAD_FILE = "_autoload.txt"
local ACTIVE_PROFILE_FILE = "_active_profile.txt"

-- ── helpers ──────────────────────────────────────────────

local function trim(str)
    if type(str) ~= "string" then return nil end
    str = str:match("^%s*(.-)%s*$")
    return #str > 0 and str or nil
end

-- Config and profile names come straight from a text box and are pasted into
-- a file path, so strip anything that could climb out of the folder.
local function safeName(name)
    name = tostring(name or "")
    name = name:gsub("[^%w%-_ %.]", "_")
    name = name:match("^%s*(.-)%s*$")
    if name == "" or name == "." or name == ".." then return nil end
    return name
end

local function isReserved(name)
    return RESERVED[string.lower(tostring(name))] == true
end

-- Same character blacklist Obsidian uses for folder names.
local function isValidFolderPath(name)
    if typeof(name) ~= "string" then return false end
    if not trim(name) then return false end
    if name:find('[<>:"|%?%z]') then return false end
    return true
end

-- ── element type parsers ────────────────────────────────
-- Each parser knows how to snapshot one EZ element (_elements entry tagged
-- with _type by the library) and how to push a saved value back into it.
-- Unknown / untagged elements are skipped, matching Obsidian behaviour of
-- only persisting recognised types.

local ElementParsers = {}

local function fromHex(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("#", "")
    if #hex ~= 6 or not hex:match("^[%x]+$") then return nil end
    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    if not r or not g or not b then return nil end
    return Color3.fromRGB(r, g, b)
end

local function toHex(c)
    return string.format("#%02X%02X%02X",
        math.floor(c.R * 255 + 0.5),
        math.floor(c.G * 255 + 0.5),
        math.floor(c.B * 255 + 0.5))
end

local function parseEnumItem(str)
    if type(str) ~= "string" then return nil end
    local parts = str:split(".")
    if #parts >= 3 and Enum[parts[2]] and Enum[parts[2]][parts[3]] then
        return Enum[parts[2]][parts[3]]
    end
    return nil
end

-- normalise a multi-dropdown value to the map form EZ uses ({Name=true})
local function normalizeMulti(v)
    if typeof(v) ~= "table" then return nil end
    local isMap = false
    for k, _ in v do
        if type(k) ~= "number" then isMap = true break end
    end
    if isMap then
        local m = {}
        for k, on in v do
            if on then m[k] = true end
        end
        return m
    end
    local m = {}
    for _, name in v do m[tostring(name)] = true end
    return m
end

do
    local function def(typeTag, saveFn, loadFn)
        ElementParsers[typeTag] = { save = saveFn, load = loadFn }
    end

    def("Toggle",
        function(elem) return { value = elem.Value == true } end,
        function(elem, data)
            if type(data.value) ~= "boolean" then return end
            if elem.Get and elem.Get() == data.value then return end
            elem:Set(data.value)
        end)

    def("Slider",
        function(elem) return { value = tonumber(elem.Value) } end,
        function(elem, data)
            local v = tonumber(data.value)
            if not v then return end
            if elem.Get and elem.Get() == v then return end
            elem:Set(v)
        end)

    def("Dropdown",
        function(elem)
            return { value = elem.Value, multi = typeof(elem.Value) == "table" }
        end,
        function(elem, data)
            if data.multi then
                local m = normalizeMulti(data.value)
                if not m then return end
                elem:Set(m)
            else
                if type(data.value) ~= "string" then return end
                if elem.Get and elem.Get() == data.value then return end
                elem:Set(data.value)
            end
        end)

    def("Input",
        function(elem) return { text = tostring(elem.Value or "") } end,
        function(elem, data)
            if type(data.text) ~= "string" then return end
            if elem.Get and elem.Get() == data.text then return end
            elem:Set(data.text)
        end)

    def("Keybind",
        function(elem)
            return {
                key = tostring(elem.Value),
                mode = elem.GetMode and elem:GetMode() or nil,
                modifiers = elem.GetModifiers and elem:GetModifiers() or nil,
            }
        end,
        function(elem, data)
            local key = parseEnumItem(data.key)
            if not key then return end

            if elem.Configure then
                -- full-shape restore; Configure only fires the flag listener
                -- when the key itself actually changed
                elem:Configure({
                    Key = key,
                    Mode = data.mode,
                    Modifiers = data.modifiers,
                })
            else
                if elem.Get and elem.Get() == key then return end
                elem:Set(key)
            end
        end)

    def("ColorPicker",
        function(elem)
            return {
                value = toHex(elem.Value),
                transparency = elem.GetTransparency and elem:GetTransparency() or nil,
            }
        end,
        function(elem, data)
            local c = fromHex(data.value)
            if not c then return end

            if elem.Get and elem.Get() ~= c then
                elem:Set(c)
            end
            if data.transparency ~= nil and elem.SetTransparency then
                elem:SetTransparency(tonumber(data.transparency) or 0)
            end
        end)

    def("Progress",
        function(elem) return { value = tonumber(elem.Value) } end,
        function(elem, data)
            local v = tonumber(data.value)
            if not v then return end
            if elem.Get and elem.Get() == v then return end
            elem:Set(v)
        end)

    -- TabBox handle (Library.lua AddTabBox): .Value is the active tab NAME,
    -- .Get()/.Set(name) read/write it and .Tabs is a name-keyed map of the
    -- per-tab sections - so the saved string doubles as the membership check.
    def("TabBox",
        function(elem) return { value = tostring(elem.Value) } end,
        function(elem, data)
            if type(data.value) ~= "string" then return end
            if elem.Get and elem.Get() == data.value then return end
            if elem.Tabs and elem.Tabs[data.value] then elem:Set(data.value) end
        end)
end

-- ── core serialization ──────────────────────────────────
-- New format:
--   { format = 2, timestamp = "...", name = "...",
--     objects = { { idx, type, ...payload } ... } }
-- Legacy format (flat map of flag -> { type, value }) is still loaded.

local function serializeObjects(mgr, configName)
    local lib = mgr.Library
    local objects = {}

    -- deterministic order: sort by flag id so diffs between saves are clean
    local ids = {}
    for id, elem in lib._elements do
        if elem._type and ElementParsers[elem._type] then
            table.insert(ids, id)
        end
    end
    table.sort(ids, function(a, b) return a < b end)

    for _, id in ids do
        if mgr.Ignore[id] then continue end
        local elem = lib._elements[id]
        local parser = ElementParsers[elem._type]
        local ok, payload = pcall(parser.save, elem)
        if ok and type(payload) == "table" then
            payload.idx = id
            payload.type = elem._type
            table.insert(objects, payload)
        end
    end

    return {
        format = 2,
        timestamp = os.date("%d.%m.%Y %H:%M:%S"),
        name = configName or "",
        objects = objects,
    }
end

-- Generic flag restore (legacy configs + anything not covered by parsers).
-- Deferred Sets so a callback that mutates flags/elements cannot re-enter
-- the middle of this loop mid-restore.
local function applyData(mgr, data)
    local lib = mgr.Library
    if type(data) ~= "table" then
        return false, "Invalid config data"
    end
    if not lib then
        return false, "No library bound"
    end

    for flag, info in data do
        if type(flag) ~= "string" or lib.Flags[flag] == nil then
            continue
        end

        if mgr.Ignore[flag] then
            continue
        end

        if type(info) ~= "table" then
            continue
        end

        local val = info.value

        if info.type == "boolean" then
            if type(val) ~= "boolean" then continue end
        elseif info.type == "number" then
            if type(val) ~= "number" then continue end
        elseif info.type == "string" then
            if type(val) ~= "string" then continue end
        elseif info.type == "Color3" then
            if type(val) ~= "table" then continue end
            val = Color3.new(
                tonumber(val.R) or 0,
                tonumber(val.G) or 0,
                tonumber(val.B) or 0
            )
        elseif info.type == "EnumItem" then
            local parsed = parseEnumItem(tostring(val))
            if not parsed then continue end
            val = parsed
        elseif info.type == "table" then
            if type(val) ~= "table" then continue end
        else
            continue
        end

        lib.Flags[flag] = val

        local elem = lib._elements and lib._elements[flag]
        if elem and elem.Set then
            task.defer(function()
                pcall(elem.Set, elem, val)
            end)
        end
    end

    return true
end

-- Parser-driven restore for the objects[] format.
local function applyObjects(mgr, objects)
    local lib = mgr.Library

    if mgr.UseLoadingOrder and type(mgr.LoadingOrder) == "table" then
        table.sort(objects, function(a, b)
            local ai = table.find(mgr.LoadingOrder, a.type) or math.huge
            local bi = table.find(mgr.LoadingOrder, b.type) or math.huge
            return ai < bi
        end)
    end

    for _, obj in objects do
        if type(obj) ~= "table" or type(obj.idx) ~= "string" then continue end
        if mgr.Ignore[obj.idx] then continue end

        local elem = lib._elements and lib._elements[obj.idx]
        if not elem or not elem.Set then continue end

        local parser = obj.type and ElementParsers[obj.type]
        -- fall back to the element's own type when the payload omits/mismatches
        if not parser and elem._type then
            parser = ElementParsers[elem._type]
        end
        if not parser then continue end

        task.defer(function()
            pcall(parser.load, elem, obj)
        end)
    end

    return true
end

-- ── binding / folders ───────────────────────────────────

function SaveManager:SetLibrary(library)
    self.Library = library
    -- register so EZ:CreateWindow().AddSettingsTab() can find us
    if library then library._saveManager = self end
end

-- Single source of truth for where configs live.
local function configRoot(mgr)
    if trim(mgr.Folder) == "" then return false end
    if trim(mgr.SubFolder) ~= "" then
        return mgr.Folder .. "/" .. mgr.SubFolder
    end
    return mgr.Folder
end

-- Single source of truth for where profiles live. Every profile/autoload API
-- used to hardcode Folder .. "/profiles" while BuildFolderTree created the
-- folder under the deepest configured path (Folder/SubFolder/profiles), so
-- enabling a SubFolder sent profiles and configs into different trees and the
-- whole profile system silently died (empty list, failed writes, autoload
-- reporting "Config file not found").
-- Declared BEFORE :Bind, which restores the active profile on attach -
-- referenced at its old position below, the call hit a nil global inside a
-- pcall and the restore silently died.
local function profilesRoot(mgr)
    local root = configRoot(mgr)
    if not root then return false end
    return root .. "/profiles"
end

function SaveManager:Bind(library, folder)
    self.Library = library
    if library then library._saveManager = self end
    if folder then
        self:SetFolder(folder)
    else
        self:BuildFolderTree()
    end
    -- restore last active profile name (only when its file still exists;
    -- a deleted or renamed profile must not linger as the active one)
    pcall(function()
        local p = self.Folder .. "/" .. ACTIVE_PROFILE_FILE
        if FS_IsFile(p) then
            local name = trim(readfile(p))
            local root = profilesRoot(self)
            if name and type(root) == "string" and FS_IsFile(root .. "/" .. name .. ".json") then
                self._activeProfile = name
            end
        end
    end)
    return self
end


function SaveManager:GetPaths()
    local root = configRoot(self)
    if type(root) ~= "string" then return {} end
    local out = {}
    local current = ""
    for part in string.gmatch(root, "[^/]+") do
        current = (current == "") and part or (current .. "/" .. part)
        table.insert(out, current)
    end
    return out
end

function SaveManager:BuildFolderTree(skipWhenCreated)
    local paths = self:GetPaths()
    if #paths == 0 then return false end

    -- configs and profiles share the deepest folder
    local profilesPath = profilesRoot(self)
    if type(profilesPath) ~= "string" then return false end

    if skipWhenCreated and FS_IsFolder(paths[1]) and FS_IsFolder(profilesPath) then
        return true
    end

    for _, p in paths do
        if not FS_IsFolder(p) then
            pcall(makefolder, p)
        end
    end
    if not FS_IsFolder(profilesPath) then
        pcall(makefolder, profilesPath)
    end
    return true
end

function SaveManager:CheckFolderTree()
    return self:BuildFolderTree(true)
end

function SaveManager:CheckSubFolder(createFolder)
    local root = configRoot(self)
    if not root or trim(self.SubFolder) == "" then return false end
    local exists = FS_IsFolder(root)
    if not createFolder then return exists end
    pcall(makefolder, root)
    return true
end

function SaveManager:SetFolder(folder)
    assert(isValidFolderPath(folder), "Invalid path provided")
    self.Folder = folder
    self:BuildFolderTree()
end

function SaveManager:SetSubFolder(subFolder)
    assert(isValidFolderPath(subFolder), "Invalid path provided")
    self.SubFolder = subFolder
    self:BuildFolderTree()
end

-- ── indexes ─────────────────────────────────────────────

function SaveManager:SetIgnoreIndexes(indexes)
    if type(indexes) ~= "table" then return false end
    for _, idx in indexes do
        self.Ignore[tostring(idx)] = true
    end
    return true
end

function SaveManager:ClearIgnoreIndexes()
    table.clear(self.Ignore)
end

-- EZ keeps themes OUT of flags (ThemeManager owns them), so unlike Obsidian
-- there is nothing theme-shaped to filter; this exists for API parity and
-- still strips any same-named internals if a host script creates them.
function SaveManager:IgnoreThemeSettings()
    self:SetIgnoreIndexes({
        "BackgroundColor", "MainColor", "AccentColor", "OutlineColor",
        "FontColor", "FontFace", "BackgroundImage",
        "ThemeManager_ThemeList", "ThemeManager_CustomThemeList",
        "ThemeManager_CustomThemeName",
    })
end

function SaveManager:SetLoadingOrder(enabled, order)
    self.UseLoadingOrder = enabled == true
    if typeof(order) == "table" then
        self.LoadingOrder = order
    end
end

-- ── config listing ──────────────────────────────────────

function SaveManager:RefreshConfigList()
    local root = configRoot(self)
    if not root then return {} end

    local ok, files = pcall(FS_ListFiles, root)
    if not ok or typeof(files) ~= "table" then return {} end

    local names = {}
    for _, filePath in files do
        local fileName = filePath:gsub("\\", "/"):match("/([^/]+)$") or filePath
        local base = fileName:match("(.+)%.json$")
        if base and not isReserved(base) then
            table.insert(names, base)
        end
    end
    table.sort(names, function(a, b) return a < b end)
    return names
end

function SaveManager:GetConfigs()
    return self:RefreshConfigList()
end

-- ── JSON in/out ─────────────────────────────────────────

-- Returns encoded json, success, err
function SaveManager:SaveJSON(configName)
    if not self.Library then
        return "", false, "No library bound"
    end

    local payload = serializeObjects(self, configName)
    local okEncode, encoded = pcall(function()
        return HttpService:JSONEncode(payload)
    end)
    if not okEncode then
        return "", false, "Failed to encode data"
    end

    return encoded, true
end

-- Accepts BOTH the new objects[] format and the legacy flat flag map.
-- Returns success, err
function SaveManager:LoadJSON(content)
    if type(content) ~= "string" or #content == 0 then
        return false, "No JSON provided"
    end

    local okDecode, decoded = pcall(function()
        return HttpService:JSONDecode(content)
    end)
    if not okDecode or typeof(decoded) ~= "table" then
        return false, "Failed to decode config data"
    end

    if typeof(decoded.objects) == "table" then
        return applyObjects(self, decoded.objects)
    end

    -- legacy flat map
    return applyData(self, decoded)
end

-- ── config CRUD ─────────────────────────────────────────

local function getConfigPath(mgr, name)
    local root = configRoot(mgr)
    if not root then return false end
    return root .. "/" .. name .. ".json"
end

function SaveManager:DoesConfigExist(name)
    local p = getConfigPath(self, name)
    return p ~= false and FS_IsFile(p)
end

function SaveManager:Save(name)
    if not self.Library then return false, "No library bound" end
    name = safeName(name)
    if not name then return false, "Invalid config name provided" end
    if isReserved(name) then return false, "Reserved config name" end

    self:CheckFolderTree()

    local json, okEncode, encodeErr = self:SaveJSON(name)
    if not okEncode then
        return false, encodeErr
    end

    local okWrite, err = pcall(writefile, getConfigPath(self, name), json)
    if not okWrite then
        return false, "Failed to write config file: " .. tostring(err)
    end
    return true
end

function SaveManager:Load(name)
    if not self.Library then return false, "No library bound" end
    name = safeName(name)
    if not name then return false, "No config is selected" end

    local path = getConfigPath(self, name)
    if path == false or not FS_IsFile(path) then
        return false, "Config file does not exist"
    end

    local okRead, content = pcall(readfile, path)
    if not okRead or type(content) ~= "string" then
        return false, "Failed to read config file"
    end

    return self:LoadJSON(content)
end

function SaveManager:Delete(name)
    name = safeName(name)
    if not name then return false, "No config is selected" end
    if isReserved(name) then return false, "Reserved config name" end

    local path = getConfigPath(self, name)
    if path == false or not FS_IsFile(path) then
        return false, "Config file does not exist"
    end

    local okDel, err = pcall(delfile, path)
    if not okDel then
        return false, "Failed to delete config file: " .. tostring(err)
    end

    if name == self.AutoloadConfig then
        self:DeleteAutoLoadConfig()
    end

    return true
end

-- ── legacy export / import ──────────────────────────────

local function b64encode(str)
    local enc
    pcall(function()
        if crypt and crypt.base64encode then enc = crypt.base64encode(str)
        elseif crypt and crypt.base64 and crypt.base64.encode then enc = crypt.base64.encode(str)
        elseif base64_encode then enc = base64_encode(str)
        end
    end)
    return enc
end

local function b64decode(str)
    local dec
    pcall(function()
        if crypt and crypt.base64decode then dec = crypt.base64decode(str)
        elseif crypt and crypt.base64 and crypt.base64.decode then dec = crypt.base64.decode(str)
        elseif base64_decode then dec = base64_decode(str)
        end
    end)
    return dec
end

function SaveManager:Export()
    if not self.Library then return nil, "No library bound" end
    -- flat legacy shape so old importers can still read it
    local data = {}
    for flag, val in self.Library.Flags do
        if self.Ignore[flag] then continue end
        local t = typeof(val)
        if t == "boolean" or t == "number" or t == "string" then
            data[flag] = { type = t, value = val }
        elseif t == "Color3" then
            data[flag] = { type = "Color3", value = { R = val.R, G = val.G, B = val.B } }
        elseif t == "EnumItem" then
            data[flag] = { type = "EnumItem", value = tostring(val) }
        elseif t == "table" then
            data[flag] = { type = "table", value = val }
        end
    end
    local json = HttpService:JSONEncode(data)
    return b64encode(json) or json
end

function SaveManager:Import(str)
    if not self.Library then return false, "No library bound" end
    if type(str) ~= "string" or #str == 0 then return false, "Empty string" end

    -- Export falls back to raw json when the executor has no base64 helpers,
    -- so a string may be either. Try the decode, then the string as-is:
    -- base64-decoding raw json yields garbage that never parses.
    local candidates = {}
    local decoded = b64decode(str)
    if type(decoded) == "string" and #decoded > 0 then
        table.insert(candidates, decoded)
    end
    table.insert(candidates, str)

    for _, candidate in candidates do
        local ok = self:LoadJSON(candidate)
        if ok then
            return true
        end
    end

    return false, "Bad config string"
end

-- ── profiles ────────────────────────────────────────────

function SaveManager:GetProfiles()
    local profiles = {}
    local root = profilesRoot(self)
    if type(root) ~= "string" then return profiles end
    pcall(function()
        local files = FS_ListFiles(root)
        for _, f in files do
            local name = f:gsub("\\", "/"):match("/([^/]+)%.json$") or f:match("([^/\\]+)%.json$")
            if name and not isReserved(name) then
                table.insert(profiles, name)
            end
        end
    end)
    table.sort(profiles, function(a, b) return a < b end)
    return profiles
end

function SaveManager:GetActiveProfile()
    return self._activeProfile
end

function SaveManager:SaveProfile(name)
    if not self.Library then return false, "No library bound" end
    name = safeName(name)
    if not name then return false, "No name" end
    if isReserved(name) then return false, "Reserved name" end

    local json, okEncode, encodeErr = self:SaveJSON(name)
    if not okEncode then
        return false, encodeErr
    end

    self:CheckFolderTree()

    local root = profilesRoot(self)
    if type(root) ~= "string" then return false, "Invalid folder" end

    local ok, err = pcall(function()
        writefile(root .. "/" .. name .. ".json", json)
    end)
    if ok then
        self._activeProfile = name
        pcall(function() writefile(self.Folder .. "/" .. ACTIVE_PROFILE_FILE, name) end)
    end
    return ok, err
end

function SaveManager:LoadProfile(name)
    if not self.Library then return false, "No library bound" end
    name = safeName(name)
    if not name then return false, "No name" end

    local root = profilesRoot(self)
    if type(root) ~= "string" then return false, "Invalid folder" end
    local path = root .. "/" .. name .. ".json"
    local okRead, raw = pcall(readfile, path)
    if not okRead or type(raw) ~= "string" then
        return false, "Profile not found"
    end

    local ok = self:LoadJSON(raw)
    if ok then
        self._activeProfile = name
        pcall(function() writefile(self.Folder .. "/" .. ACTIVE_PROFILE_FILE, name) end)
        return true
    end
    return false, "Bad profile format"
end

function SaveManager:DeleteProfile(name)
    name = safeName(name)
    if not name then return false, "Bad name" end
    if isReserved(name) then return false, "Reserved name" end

    local root = profilesRoot(self)
    if type(root) ~= "string" then return false, "Invalid folder" end

    local ok, err = pcall(function()
        delfile(root .. "/" .. name .. ".json")
    end)
    if self._activeProfile == name then self._activeProfile = nil end
    return ok, err
end

function SaveManager:RenameProfile(old, new)
    old, new = safeName(old), safeName(new)
    if not old or not new then return false, "Bad name" end
    if isReserved(new) then return false, "Reserved name" end
    if old == new then return true end

    local root = profilesRoot(self)
    if type(root) ~= "string" then return false, "Invalid folder" end
    local src = root .. "/" .. old .. ".json"
    local dst = root .. "/" .. new .. ".json"

    local okRead, raw = pcall(readfile, src)
    if not okRead or type(raw) ~= "string" then
        return false, "Profile not found"
    end

    -- verify the destination actually landed before removing the source; the
    -- old code discarded the pcall result and reported success even when the
    -- rename never happened
    local okWrite, writeErr = pcall(writefile, dst, raw)
    if not okWrite then
        return false, "Failed to write renamed profile: " .. tostring(writeErr)
    end
    pcall(delfile, src)

    if self._activeProfile == old then
        self._activeProfile = new
        pcall(function() writefile(self.Folder .. "/" .. ACTIVE_PROFILE_FILE, new) end)
    end
    return true
end

-- ── autoload (targets a PROFILE) ────────────────────────

local function getAutoloadPath(mgr)
    return mgr.Folder .. "/" .. AUTOLOAD_FILE
end

function SaveManager:GetAutoloadConfig()
    self:CheckFolderTree()

    local path = getAutoloadPath(self)
    if not FS_IsFile(path) then
        return "none", false, "Autoload config is not set"
    end

    local okRead, name = pcall(readfile, path)
    if not okRead or type(name) ~= "string" then
        return "none", false, "Failed to read autoload pointer"
    end

    name = safeName(trim(name))
    if not name then
        return "none", false, "Autoload config is not set"
    end

    -- autoload targets a regular CONFIG in the settings folder
    local path = getConfigPath(self, name)
    if path == false or not FS_IsFile(path) then
        return "none", false, "Config file not found"
    end

    self.AutoloadConfig = name
    return name, true
end

function SaveManager:SaveAutoloadConfig(configName)
    if not self.Library then return false, "No library bound" end
    configName = safeName(configName)
    if not configName then return false, "No config is selected" end
    if isReserved(configName) then return false, "Reserved name" end

    self:CheckFolderTree()

    -- autoload targets a regular CONFIG in the settings folder
    local path = getConfigPath(self, configName)
    if path == false or not FS_IsFile(path) then
        return false, "Config does not exist"
    end

    local okWrite, err = pcall(writefile, getAutoloadPath(self), configName)
    if not okWrite then
        return false, tostring(err)
    end

    self.AutoloadConfig = configName
    return true
end

function SaveManager:DeleteAutoLoadConfig()
    self:CheckFolderTree()

    local path = getAutoloadPath(self)
    if not FS_IsFile(path) then
        return false, "Autoload config is not set"
    end

    local ok, err = pcall(delfile, path)
    if not ok then
        return false, tostring(err)
    end

    self.AutoloadConfig = nil
    return true
end

function SaveManager:LoadAutoloadConfig()
    local configName, success, fetchErr = self:GetAutoloadConfig()
    if not success or fetchErr then
        if fetchErr ~= "Autoload config is not set" then
            if self.Library and self.Library.Notify then
                self.Library:Notify({
                    Title = "SaveManager",
                    Content = "Failed to load autoload config: " .. tostring(fetchErr),
                    Duration = 3,
                    Type = "error",
                })
            end
        end
        return false, fetchErr
    end

    local okLoad, loadErr = self:Load(configName)
    if not okLoad then
        if self.Library and self.Library.Notify then
            self.Library:Notify({
                Title = "SaveManager",
                Content = "Failed to load autoload config: " .. tostring(loadErr),
                Duration = 3,
                Type = "error",
            })
        end
        return false, loadErr
    end

    if self.Library and self.Library.Notify then
        self.Library:Notify({
            Title = "SaveManager",
            Content = 'Loaded autoload config "' .. configName .. '"',
            Duration = 2,
            Type = "success",
        })
    end
    return true
end

-- ── GUI: dialogs ────────────────────────────────────────
-- Destructive actions go through window:AddDialog when the library exposes
-- it; otherwise the action runs immediately (old behaviour, never blocks).

local function confirm(mgr, window, title, description, destructiveText, action)
    if not (window and type(window.AddDialog) == "function") then
        return action()
    end

    return window:AddDialog("SaveManager_" .. tostring(math.floor(os.clock() * 1000)), {
        Title = title,
        Description = description,
        AutoDismiss = false,
        FooterButtons = {
            { Title = "Cancel", Variant = "Ghost", Order = 1 },
            { Title = destructiveText, Variant = "Destructive", Order = 2,
              Callback = function(dialog)
                  dialog:Dismiss()
                  action()
              end },
        },
    })
end

local function notifyResult(mgr, ok, prefix, name, err)
    if not (mgr.Library and mgr.Library.Notify) then return end
    -- omit the quotes entirely when there is no name, otherwise messages
    -- rendered like: Copied config to clipboard ""
    local label = (name ~= nil and name ~= "") and (' "' .. tostring(name) .. '"') or ""
    mgr.Library:Notify({
        Title = "SaveManager",
        Content = ok and (prefix .. label) or (prefix .. label .. " failed: " .. tostring(err)),
        Duration = 2,
        Type = ok and "success" or "error",
    })
end

-- ── GUI: full config section ────────────────────────────
-- section: an EZ section (tab:AddSection(...))
-- window:  optional EZ window for confirmation dialogs
--
-- Mirrors Obsidian's BuildConfigSection: create / list / load / overwrite /
-- delete / refresh / autoload set+reset with status label / import+export.

function SaveManager:BuildConfigSection(section, window)
    assert(self.Library, "Library is not set, call SaveManager:SetLibrary(Library) first.")
    local mgr = self

    -- our own widgets must never leak into configs
    mgr:SetIgnoreIndexes({ "_EZSM_ConfigName", "_EZSM_ConfigList", "_EZSM_JSON" })

    section:AddInput("_EZSM_ConfigName", {
        Text = "Config name",
        Placeholder = "my-config",
    })

    -- forward-declared: used by "Create config" below, assigned after the
    -- config dropdown exists
    local refreshList
    local refreshStatus -- forward-declared; the autoload label lives further down

    section:AddButton({
        Text = "Create config",
        Callback = function()
            -- sanitise up front so the existence prompt below reasons about
            -- the SAME name Save() will actually write to disk
            local name = safeName(mgr.Library.Flags["_EZSM_ConfigName"])
            if not name then
                notifyResult(mgr, false, "Create", "?", "name cannot be empty")
                return
            end
            if isReserved(name) then
                notifyResult(mgr, false, "Create", name, "reserved name")
                return
            end
            -- a fresh name saves straight through; only a real collision
            -- deserves the "already exists" overwrite confirmation
            if not mgr:DoesConfigExist(name) then
                local ok, err = mgr:Save(name)
                notifyResult(mgr, ok, "Created config", name, err)
                refreshList()
                return
            end
            confirm(mgr, window,
                "Config already exists",
                ('A config named "%s" already exists. Overwrite it with your current settings?'):format(name),
                "Overwrite",
                function()
                    local ok, err = mgr:Save(name)
                    notifyResult(mgr, ok, "Created config", name, err)
                end)
        end,
    })

    section:AddDivider()

    local configDD
    configDD = section:AddDropdown("_EZSM_ConfigList", {
        Text = "Config list",
        Values = mgr:RefreshConfigList(),
    })

    refreshList = function()
        local list = mgr:RefreshConfigList()
        configDD:Refresh(list)
        -- Keep the current selection whenever it still exists. Forcing the
        -- alphabetical-first entry made the selection silently jump after
        -- creating/deleting a differently-sorted name, so "Overwrite config"
        -- could target the wrong file.
        local current = mgr.Library.Flags["_EZSM_ConfigList"]
        if type(current) ~= "string" or not table.find(list, current) then
            configDD:Set(list[1] or "", true)
        end
        if refreshStatus then refreshStatus() end
    end

    local function selectedConfig()
        local v = mgr.Library.Flags["_EZSM_ConfigList"]
        if type(v) ~= "string" or trim(v) == "" then return nil end
        return v
    end

    section:AddButton({
        Text = "Load config",
        Callback = function()
            local name = selectedConfig()
            if not name then
                notifyResult(mgr, false, "Load", "?", "select a config first")
                return
            end
            confirm(mgr, window,
                "Load config",
                ('Load "%s"? Your current settings will be overwritten.'):format(name),
                "Load",
                function()
                    local ok, err = mgr:Load(name)
                    notifyResult(mgr, ok, "Loaded config", name, err)
                end)
        end,
    })

    section:AddButton({
        Text = "Overwrite config",
        Callback = function()
            local name = selectedConfig()
            if not name then
                notifyResult(mgr, false, "Overwrite", "?", "select a config first")
                return
            end
            confirm(mgr, window,
                "Overwrite config",
                ('Overwrite "%s" with your current settings? This cannot be undone.'):format(name),
                "Overwrite",
                function()
                    local ok, err = mgr:Save(name)
                    notifyResult(mgr, ok, "Overwrote config", name, err)
                end)
        end,
    })

    section:AddButton({
        Text = "Delete config",
        Callback = function()
            local name = selectedConfig()
            if not name then
                notifyResult(mgr, false, "Delete", "?", "select a config first")
                return
            end
            confirm(mgr, window,
                "Delete config",
                ('Delete "%s"? This cannot be undone.'):format(name),
                "Delete",
                function()
                    local ok, err = mgr:Delete(name)
                    notifyResult(mgr, ok, "Deleted config", name, err)
                    refreshList()
                end)
        end,
    })

    section:AddButton({
        Text = "Refresh list",
        Callback = refreshList,
    })

    -- Autoload points straight at a CONFIG: pick one in the list above and
    -- it restores on every launch (Obsidian-style).
    section:AddButton({
        Text = "Set as Autoload",
        Callback = function()
            local name = selectedConfig()
            if not name then
                notifyResult(mgr, false, "Set autoload", "?", "select a config first")
                return
            end
            local ok, err = mgr:SaveAutoloadConfig(name)
            if ok then
                if mgr.Library and mgr.Library.Notify then
                    mgr.Library:Notify({
                        Title = "SaveManager",
                        Content = 'Autoload set to "' .. name .. '"',
                        Duration = 2,
                        Type = "success",
                    })
                end
            else
                notifyResult(mgr, false, "Set autoload", name, err)
            end
            if refreshStatus then refreshStatus() end
        end,
    })

    section:AddButton({
        Text = "Reset autoload",
        Callback = function()
            local ok, err = mgr:DeleteAutoLoadConfig()
            if ok then
                if mgr.Library and mgr.Library.Notify then
                    mgr.Library:Notify({
                        Title = "SaveManager",
                        Content = "Autoload cleared",
                        Duration = 2,
                        Type = "info",
                    })
                end
            else
                notifyResult(mgr, false, "Clear autoload", "", err)
            end
            if refreshStatus then refreshStatus() end
        end,
    })

    -- live indicator of what (if anything) autoloads on launch
    local autoloadLbl = section:AddLabel("Current autoload: none")
    refreshStatus = function()
        local name, autoOk = mgr:GetAutoloadConfig()
        autoloadLbl:Set("Current autoload config: " .. ((autoOk == true and type(name) == "string") and name or "none"))
    end
    refreshStatus()

    section:AddDivider()

    section:AddInput("_EZSM_JSON", {
        Text = "Config JSON",
        Placeholder = "paste here to import",
    })

    section:AddButton({
        Text = "Import config",
        Callback = function()
            local json = mgr.Library.Flags["_EZSM_JSON"]
            if type(json) ~= "string" or trim(json) == "" then
                notifyResult(mgr, false, "Import", "?", "JSON box is empty")
                return
            end
            confirm(mgr, window,
                "Import config",
                "Import this configuration? Your current settings will be overwritten.",
                "Import",
                function()
                    local ok, err = mgr:LoadJSON(json)
                    notifyResult(mgr, ok, "Imported config", "", err)
                end)
        end,
    })

    section:AddButton({
        Text = "Export current config",
        Callback = function()
            -- SaveJSON returns "", false, err on failure; "" is truthy in
            -- Lua, so the old `if not json` guard never fired and an empty
            -- string got copied with a success toast
            local json, okEncode, encodeErr = mgr:SaveJSON()
            if not okEncode then
                notifyResult(mgr, false, "Export", "", encodeErr or "encode failed")
                return
            end
            pcall(function() setclipboard(json) end)
            notifyResult(mgr, true, "Copied config to clipboard", "", nil)
        end,
    })

    return section
end

-- ── GUI: profile section ────────────────────────────────

function SaveManager:BuildProfileUI(section, window)
    if not section then return end
    local lib = self.Library
    local mgr = self

    -- our widgets must never round-trip through a save
    mgr:SetIgnoreIndexes({ "_EZProfile", "_EZSM_ProfileName" })

    local refreshStatus -- forward-declared; the status label lives further down

    local profiles = mgr:GetProfiles()
    local active = mgr:GetActiveProfile()

    local dd
    dd = section:AddDropdown("_EZProfile", {
        Text = "Profile",
        Values = #profiles > 0 and profiles or {"(none)"},
        Default = active or (profiles[1] or "(none)"),
        Callback = function(v)
            if v == "(none)" then return end
            local ok, err = mgr:LoadProfile(v)
            if ok and lib.Notify then
                lib:Notify({ Title = "Profile", Content = 'Loaded "' .. v .. '"', Duration = 2, Type = "success" })
            elseif not ok and lib.Notify then
                lib:Notify({ Title = "Profile", Content = "Failed: " .. tostring(err), Duration = 3, Type = "error" })
            end
            if refreshStatus then refreshStatus() end
        end,
    })

    local function refreshDD()
        local list = mgr:GetProfiles()
        if #list == 0 then list = {"(none)"} end
        dd:Refresh(list)
        -- Refresh only swaps the option list; if the selected profile just got
        -- deleted or renamed the dropdown would keep showing a dead name.
        if not table.find(list, lib.Flags["_EZProfile"]) then
            dd:Set(list[1], true)
        end
        if refreshStatus then refreshStatus() end
    end

    section:AddButton({
        Text = "Save Profile",
        Callback = function()
            -- read it now: `active` was captured when the UI was built and
            -- went stale the moment another profile was loaded
            local name = mgr:GetActiveProfile() or "default"
            local v = lib.Flags["_EZProfile"]
            if v and v ~= "(none)" then name = v end

            local function doSave()
                local ok, err = mgr:SaveProfile(name)
                if ok then
                    refreshDD()
                end
                if lib.Notify then
                    lib:Notify({ Title = "Profile",
                        Content = ok and ('Saved "' .. name .. '"') or ("Failed: " .. tostring(err)),
                        Duration = 2, Type = ok and "success" or "error" })
                end
            end

            -- overwriting an existing profile is destructive; ask first
            -- (falls back to immediate save when no window/dialogs available)
            local root = profilesRoot(mgr)
            if type(root) == "string" and FS_IsFile(root .. "/" .. name .. ".json") then
                confirm(mgr, window,
                    "Profile already exists",
                    ('A profile named "%s" already exists. Overwrite it with your current settings?'):format(name),
                    "Overwrite",
                    doSave)
            else
                doSave()
            end
        end,
    })

    section:AddButton({
        Text = "New Profile",
        Callback = function()
            -- first free slot; #profiles + 1 collided with an existing name
            -- as soon as anything had been deleted or renamed
            local taken = {}
            for _, p in mgr:GetProfiles() do taken[p] = true end
            local n = 1
            while taken["Profile " .. n] do n = n + 1 end
            local name = "Profile " .. n
            local ok, err = mgr:SaveProfile(name)
            if ok then
                refreshDD()
                -- silent: the profile was just written, re-loading it is pointless
                pcall(function() dd:Set(name, true) end)
            end
            if lib.Notify then
                lib:Notify({ Title = "Profile",
                    Content = ok and ('Created "' .. name .. '"') or ("Failed: " .. tostring(err)),
                    Duration = 2, Type = ok and "info" or "error" })
            end
        end,
    })

    section:AddInput("_EZSM_ProfileName", {
        Text = "New profile name (for rename)",
        Placeholder = "my-profile",
    })

    section:AddButton({
        Text = "Rename Profile",
        Callback = function()
            local v = lib.Flags["_EZProfile"]
            if not v or v == "(none)" then
                if lib.Notify then
                    lib:Notify({ Title = "Profile", Content = "Select a profile first", Duration = 2, Type = "warning" })
                end
                return
            end
            local newName = safeName(lib.Flags["_EZSM_ProfileName"])
            if not newName then
                if lib.Notify then
                    lib:Notify({ Title = "Profile", Content = "Type the new name in the box above first", Duration = 2, Type = "warning" })
                end
                return
            end
            local ok, err = mgr:RenameProfile(v, newName)
            if ok then
                pcall(function() dd:Set(newName, true) end)
                refreshDD()
            end
            if lib.Notify then
                lib:Notify({ Title = "Profile",
                    Content = ok and ('Renamed to "' .. newName .. '"') or ("Failed: " .. tostring(err)),
                    Duration = 2, Type = ok and "success" or "error" })
            end
        end,
    })

    section:AddButton({
        Text = "Delete Profile",
        Callback = function()
            local v = lib.Flags["_EZProfile"]
            if not v or v == "(none)" then return end
            -- deleting is irreversible; confirm when the window supports it,
            -- otherwise keep the old immediate behaviour
            confirm(mgr, window,
                "Delete profile",
                ('Delete "%s"? This cannot be undone.'):format(v),
                "Delete",
                function()
                    local ok, err = mgr:DeleteProfile(v)
                    if ok then refreshDD() end
                    if lib.Notify then
                        lib:Notify({ Title = "Profile",
                            Content = ok and ('Deleted "' .. v .. '"') or ("Failed: " .. tostring(err)),
                            Duration = 2, Type = ok and "warning" or "error" })
                    end
                end)
        end,
    })

    -- NOTE: autoload intentionally does NOT live here anymore. It points at
    -- a plain CONFIG (see BuildConfigSection); profiles stay manual snapshots
    -- you flip between yourself.

    -- live status line: which profile is currently active
    local statusLbl = section:AddLabel("Active profile: -")
    refreshStatus = function()
        local a = mgr:GetActiveProfile()
        statusLbl:Set("Active profile: " .. (type(a) == "string" and a or "-"))
    end
    refreshStatus()

    return dd
end

return SaveManager
