# AutoSettings — Zero-Wiring Settings Tab

**Every `EZ:CreateWindow()` ships a fully-wired Settings tab by default.** Scripts built on the library never have to think about themes, configs, or persistence again.

```lua
local Window = EZ:CreateWindow({ Title = "My Script" })
-- Done. The window now has a "Settings" tab containing:
--   • Active-theme dropdown (13 presets + any custom themes)
--   • Configs: create / list / load / overwrite / delete (with confirm
--     dialogs), Set as Autoload / Clear Autoload + live status label,
--     JSON import/export
--   • Profiles: save / new / rename / delete + active-profile label
--   • Autoloaded config restored automatically after your tabs finish building
```

---

## Options

| Value | Behaviour |
|---|---|
| *(omitted)* / `true` | Auto-attach (default) |
| `false` | No automatic tab — build your own with SaveManager/ThemeManager |

```lua
EZ:CreateWindow({ Title = "Tour", AutoSettings = false })
```

---

## How it resolves the addons

1. **Pre-registered?** If `EZ._addonCache.ThemeManager` / `.SaveManager` exist, they're reused — no HTTP call. This is how `loader.lua` avoids double-fetching:

   ```lua
   EZ._addonCache = { ThemeManager = ThemeManager, SaveManager = SaveManager }
   ```

2. **Otherwise** they're fetched once from `REPO_RAW .. "addons/<Name>.lua"`, compiled and cached. A failed fetch warns and won't retry per-window.

3. **Bindings are adopted, never duplicated:** if you already called `SaveManager:Bind(EZ, folder)` / `ThemeManager:Bind(EZ, {File=...})`, AutoSettings keeps your folders/filenames. Unbound managers get sensible defaults (`EZConfigs`, `EZTheme.txt`).

4. **Host-built Settings tab wins:** if you added a tab literally named `"Settings"` yourself, AutoSettings skips its own tab and only runs config autoload on top.

5. Your saved theme (`LoadSaved`) is applied before/while the tab builds; the live recolour sweep covers everything already on screen.

6. **Autoload timing:** `SaveManager:LoadAutoloadConfig()` runs deferred — after your synchronous tab-building code finishes — so elements created later in your script still receive their saved values.

---

## Manual equivalent

What AutoSettings does under the hood, if you ever want it à la carte:

```lua
local ThemeManager = loadstring(...addons/ThemeManager.lua))()
local SaveManager  = loadstring(...addons/SaveManager.lua))()
ThemeManager:Bind(EZ); SaveManager:Bind(EZ, "Configs")
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end
ThemeManager:LoadSaved()

local Settings = Window:AddTab("Settings", "settings")
Settings:AddSection("Theme"):AddDropdown("_EZTheme", {
    Text = "Active theme",
    Values = ThemeManager:GetThemes(),
    Default = ThemeManager.Current,
    Callback = function(v) ThemeManager:SetTheme(v) end,
})
SaveManager:BuildConfigSection(Settings:AddSection("Configs"), Window)
SaveManager:BuildProfileUI(Settings:AddSection("Profiles"), Window)
task.defer(function() SaveManager:LoadAutoloadConfig() end)
```

`Example.lua` runs exactly this manual version (with `AutoSettings = false`) as a teaching tour.
