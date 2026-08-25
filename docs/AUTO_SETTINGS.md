# AutoSettings — Zero-Wiring Settings Tab

**Every `EZ:CreateWindow()` ships a fully-wired Settings tab by default.** Scripts built on the library never have to think about themes, configs, or persistence again.

```lua
local Window = EZ:CreateWindow({ Title = "My Script" })
-- Done. The window now has a "Settings" tab laid out in symmetric
-- groupboxes (Obsidian-style, two columns):
--
--   LEFT:  Menu groupbox
--          • Open Keybind Menu toggle      • Notification Side dropdown
--          • Custom Cursor toggle          • DPI Scale dropdown
--          • Always On Top toggle          • Corner Radius slider
--          • Menu bind (rebinds the window hotkey)  • Unload button
--
--   LEFT:  Themes groupbox
--          • Background/Main/Accent/Outline/Font colour pickers
--          • Font Face dropdown  • Background Image input
--          • Theme list + Set as default
--          • Custom theme CRUD (create/overwrite/delete/refresh,
--            set & reset default, JSON import/export) - persisted
--
--   RIGHT: Configuration groupbox
--          • Config name / create / list / load / overwrite / delete
--          • Refresh list, Set as autoload / Reset autoload + live status
--          • Config JSON import / export
--
-- Profiles are NOT attached by default anymore - build them manually with
-- SaveManager:BuildProfileUI(section), or pass AddSettingsTab({Profiles=true}).
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

5. **Placement is stable:** the Settings tab builds *deferred* (after your synchronous `AddTab` calls) and its sidebar button is pinned to the **bottom** of the list. Your first real tab keeps both the top slot and the initial focus — AutoSettings can no longer jump to the top of the sidebar or open as the active tab.

6. Your saved theme (`LoadSaved`) is applied before/while the tab builds; the live recolour sweep covers everything already on screen.

7. **Autoload timing:** `SaveManager:LoadAutoloadConfig()` runs deferred — after your synchronous tab-building code finishes — so elements created later in your script still receive their saved values.

---

## Manual equivalent

What AutoSettings does under the hood, if you ever want it à la carte:

```lua
local ThemeManager = loadstring(...addons/ThemeManager.lua))()
local SaveManager  = loadstring(...addons/SaveManager.lua))()
ThemeManager:Bind(EZ); SaveManager:Bind(EZ, "Configs")
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end
ThemeManager:LoadSaved()

-- one call builds the whole groupbox layout (Menu / Themes / Configuration):
local Settings = Window:AddSettingsTab({ Title = "Settings" })

-- or assemble it yourself from groupboxes:
local menuGb  = Settings:AddLeftGroupbox("Menu")
local themesGb = Settings:AddLeftGroupbox("Themes")
local cfgGb   = Settings:AddRightGroupbox("Configuration")
SaveManager:BuildConfigSection(cfgGb, Window)
task.defer(function() SaveManager:LoadAutoloadConfig() end)
```

`Example.lua` runs a manual version (with `AutoSettings = false`) as a teaching tour.
