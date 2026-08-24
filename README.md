<p align="center">
  <img src="assets/logo.png" width="140" alt="EZ UI Library logo">
</p>

<h1 align="center">EZ UI Library</h1>

<p align="center">
  Premium dark glassmorphism UI for Roblox scripts.<br>
  PC + mobile &middot; zero dependencies &middot; one loadstring.
</p>

---

## Install

```lua
local EZ = loadstring(game:HttpGet("https://raw.githubusercontent.com/YourName/YourRepo/main/Library.lua"))()
```

Or run the full guided tour - a 9-tab interactive reference that demonstrates every element, window feature and addon with live callbacks:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/YourName/YourRepo/main/Example.lua"))()
```

## Minimal example

```lua
local EZ = loadstring(game:HttpGet("https://raw.githubusercontent.com/YourName/YourRepo/main/Library.lua"))()

local Window = EZ:CreateWindow({
    Title = "My Script",
    ToggleKey = Enum.KeyCode.RightShift,
})

local Tab = Window:AddTab("Main", "sword") -- lucide icon name
local Sec = Tab:AddSection("Features")

Sec:AddToggle("Speed", {
    Text = "Walk Speed",
    Default = false,
    Callback = function(v)
        print("speed:", v) -- also readable as EZ.Flags.Speed
    end,
})

Sec:AddSlider("Multiplier", {
    Text = "Multiplier",
    Min = 1, Max = 10, Default = 2, Increment = 0.5, Suffix = "x",
    Callback = function(v) print(v) end,
})

Sec:AddButton({
    Text = "Do the thing",
    Callback = function()
        EZ:Notify({ Title = "Done", Type = "success", Duration = 3 })
    end,
})
```

## What's inside

- **Window**: draggable (clamped on-screen), minimize-to-pill, toggle hotkey, live search filter across every element, tab badges, collapsible sidebar, mobile gestures + auto-fit sizing, UI scale 0.5x-2x
- **Elements**: Toggle, Slider, Button, Dropdown (single/multi), Input, Keybind (Toggle/Hold modes + Ctrl/Alt/Shift modifiers), ColorPicker (+ alpha ramp), Label, Divider, Paragraph, ProgressBar, Log console, PlayerSelector (`@me` / `@random` / `@nearest`)
- **Polish**: tooltips, conditional visibility (`VisibleWhen`), confirm dialogs with Ghost/Primary/Destructive variants, notifications with history panel, floating keybind menu, watermark with `{fps}`/`{ping}`/`{flag:id}` tokens, error handling hooks
- **Persistence-ready**: flag system + element handles (`:Set/:Get/:OnChanged`) designed for config save/load

## Addons

| Addon | Purpose |
|---|---|
| `SaveManager` | Configs with Obsidian-style autoload (Set/Clear + live status line), named profiles for manual swapping, ignore lists, JSON import/export. `BuildConfigSection(section, window)` / `BuildProfileUI(section, window)` |
| `ThemeManager` | Theme switching with persistence, custom theme registration. Per-brand file via `ThemeManager:Bind(EZ, { File = "YourBrand_Theme.txt" })` |
| `QuickBar` | Floating dock of pinned toggles/buttons shown while the window is hidden (safe to re-bind) |
| `NotificationHistory` | Header bell with scrollable notification log + unread badge (re-binds across windows) |
| `Icons` | ~1700 embedded Lucide icons with fuzzy search |

## Branding checklist

Before publishing under your own name:

1. Update the `repo` URL in `Example.lua` and the loadstring URLs in `README.md`, `KeySystemTest.lua`, and the addon headers to point at **your** repository.
2. `loader.lua` is an optional all-in-one entry point (loads the library + every addon, builds a starter window). Point your public loadstring at it, or delete it if you only ship `Library.lua`.
3. Give each script its own persistence names so parallel scripts never collide:
   - `SaveManager:Bind(EZ, "YourBrandConfigs")`
   - `ThemeManager:Bind(EZ, { File = "YourBrand_Theme.txt" })`
   - `EZ:KeySystem({ SaveKey = "YourBrandKey.txt", ... })`
   - `QuickBar:Bind(EZ, Window, { File = "YourBar.json" })`
4. Bump `EZ._version` in `Library.lua` when you cut a release; `EZ:CheckForUpdate()` compares semver against your GitHub tags.

## Themes

8 curated presets ship built in (`EZ.Themes`: Midnight, Catppuccin, Tokyo Night, Dracula, Nord, Rose Pine, Cyberpunk, Monochrome), plus 5 more in ThemeManager. Switch live with `EZ:SetTheme(tbl)` or persistently through ThemeManager.

## Key system

Optional HWID-bound gate with SHA-256 hashing, saved-key bypass, attempt lockout and get-key link:

```lua
if not EZ:KeySystem({
    Title = "My Script",
    Keys = { "dev-key" },          -- use HashedKeys in production
    SaveKey = "MyKey.txt",
    GetKeyLink = "https://discord.gg/...",
}) then return end
```

## Documentation

[`Example.lua`](Example.lua) is the living documentation - read it top-to-bottom or run it and click around. Every option of every element is labelled and wired to a visible callback.

## Compatibility

Executor environment required (`gethui`, `writefile`, etc.). Every filesystem/API call is pcall-guarded; the library degrades gracefully where features are missing (e.g. no gamepad -> haptics are a no-op).
