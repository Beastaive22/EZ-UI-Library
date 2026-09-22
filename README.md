<p align="center">
  <img src="assets/logo.png" width="140" alt="EZ UI Library logo">
</p>

<h1 align="center">EZ UI Library</h1>

<p align="center">
  Premium dark glassmorphism UI for Roblox scripts.<br>
  PC + mobile · zero dependencies · one loadstring · <b>settings &amp; persistence built in</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-3.8.0-7c5cfc" alt="version">
  <img src="https://img.shields.io/badge/license-MIT-46d17a" alt="license">
  <img src="https://img.shields.io/badge/platform-Roblox%20executors-232323?logo=roblox" alt="platform">
  <img src="https://img.shields.io/badge/mobile-supported-46d17a" alt="mobile">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen" alt="deps">
</p>

---

## Install

**Full script shell** — library + every addon + starter window + auto Settings tab:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/loader.lua"))()
```

**Library only:**

```lua
local EZ = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Library.lua"))()
```

**Guided tour** — a 9-tab interactive reference demonstrating everything:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Example.lua"))()
```

## Minimal script

```lua
local EZ = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Library.lua"))()

local Window = EZ:CreateWindow({
    Title = "My Script",
    ToggleKey = Enum.KeyCode.RightShift,
})

local Sec = Window:AddTab("Main", "zap"):AddSection("Features")

Sec:AddToggle("Speed", {
    Text = "Walk Speed",
    Callback = function(v) print("speed:", v) end,
})

Sec:AddSlider("Multiplier", {
    Text = "Multiplier",
    Min = 1, Max = 10, Default = 2, Increment = 0.5, Suffix = "x",
})
```

That's the whole script — **the Settings tab (theme picker, config save/load, autoload, profiles) attaches itself automatically.** Press `RightShift` to hide/show.

## Highlights

| | |
|---|---|
| 🪟 **Windows** | Draggable + **resizable** (geometry persists, `GeometryId` for stable keys), minimize-to-**dock** (Open / Panic / Keybinds), rebindable hotkey (keys or mouse buttons), live search filter, tab badges, collapsible sidebar, mobile gestures, UI scale 0.5–2×, live corner-radius + font + notification-side controls, `CloseBehavior = "window"` for per-window X |
| 🧩 **Elements** | Toggle (+ **description line**), Slider (+ **click-to-type exact values**), Button, Dropdown (single/multi, searchable, dictionary values, disabled entries, **Select all/Clear**), Input, Keybind (Toggle/Hold + Ctrl/Alt/Shift + M1-M3), ColorPicker (+ alpha, **palette + recents**), Label/Paragraph (**RichText** opt-in), Divider, ProgressBar, Log console, PlayerSelector (`@me` / `@random` / `@nearest`) |
| ⚙️ **Zero-config persistence** | Settings tab ships on every window (`AutoSettings = false` to opt out): Obsidian-style groupbox layout - Menu (keybind menu, cursor, always-on-top, notification side, DPI scale, corner radius, menu bind, **anti-afk**, unload), Themes (colour pickers, font face, background image, custom theme CRUD + JSON import/export), Configuration (config CRUD with confirm dialogs, **config autoload**, **per-game isolation since 3.7**) |
| ✨ **Polish** | **Groupboxes** (symmetric two-column layout, + descriptions), **panic button** (universal kill switch + restore), tooltips, conditional visibility (`VisibleWhen`), confirm dialogs, notification history bell, **notification action buttons**, floating keybind menu (**grouped per window**), watermark tokens, error hooks |
| 🔑 **Key system** | Optional HWID-bound gate: SHA-256 hashed keys, saved-key bypass, attempt lockout |

## Documentation

| Doc | Contents |
|---|---|
| [`docs/API_LIBRARY.md`](docs/API_LIBRARY.md) | **Core reference** — every window option, every element, every option, every handle method, key system, watermark, misc API |
| [`docs/AUTO_SETTINGS.md`](docs/AUTO_SETTINGS.md) | The built-in Settings tab — behaviour, opt-out, manual equivalent |
| [`docs/SAVE_MANAGER.md`](docs/SAVE_MANAGER.md) | Configs, profiles, config autoload, JSON formats, disk layout, full API |
| [`docs/THEME_MANAGER.md`](docs/THEME_MANAGER.md) | Theme switching/persistence, custom themes, colour roles, preset swatches |
| [`docs/QUICKBAR.md`](docs/QUICKBAR.md) | Floating pin dock for toggles/buttons while hidden |
| [`docs/NOTIFICATION_HISTORY.md`](docs/NOTIFICATION_HISTORY.md) | Header bell, unread badge, scrollable log |
| [`docs/ICONS.md`](docs/ICONS.md) | ~1700 embedded Lucide icons + fuzzy search |

## Addons

| Addon | Purpose |
|---|---|
| [`SaveManager`](docs/SAVE_MANAGER.md) | Configs + Obsidian-style autoload + named profiles + ignore lists |
| [`ThemeManager`](docs/THEME_MANAGER.md) | Live theme switching with persistence + custom registration |
| [`QuickBar`](docs/QUICKBAR.md) | Floating dock of pinned toggles/buttons shown while hidden |
| [`NotificationHistory`](docs/NOTIFICATION_HISTORY.md) | Bell icon with scrollable notification log + unread badge |
| [`Icons`](docs/ICONS.md) | Embedded Lucide pack with fuzzy search |

## Themes

12 curated presets ship out of the box — 8 in the library (`Midnight`, `Catppuccin`, `TokyoNight`, `Dracula`, `Nord`, `Rose`, `Cyberpunk`, `Monochrome`) plus 4 more via ThemeManager (`Ocean`, `Rosé`, `Emerald`, `Sunset`). Register your own in one call; switching recolours the entire UI live. Swatches: [THEME_MANAGER.md](docs/THEME_MANAGER.md).

## Key system

```lua
if not EZ:KeySystem({
    Title = "My Hub",
    Keys = { "dev-key" },          -- use HashedKeys (SHA-256) in production
    SaveKey = "MyHub_Key.txt",     -- stores the hash, never the raw key
    GetKeyLink = "https://discord.gg/Bba9Jct6PN",
}) then return end
```

## Compatibility

Executor environment required (`gethui`, `writefile`, etc.). Every filesystem/API call is pcall-guarded; features degrade gracefully when missing (no gamepad → haptics no-op, no crypt → key system warns and falls back).


## Branding checklist

Publishing under your own name:

1. Point the loadstrings above at **your** repo and update `Example.lua` / `KeySystemTest.lua` / addon headers.
2. `Library.lua` lines 14–16 hold `REPO_SLUG` / `REPO_RAW` — used by `CheckForUpdate()` and AutoSettings' addon fetches.
3. Give each script its own persistence names so parallel scripts never collide:
   - `SaveManager:Bind(EZ, "YourHubConfigs")`
   - `ThemeManager:Bind(EZ, { File = "YourHub_Theme.txt" })`
   - `EZ:KeySystem({ SaveKey = "YourHub_Key.txt", ... })`
   - `QuickBar:Bind(EZ, Window, { File = "YourBar.json" })`
4. Bump `EZ._version` when cutting releases; `CheckForUpdate()` semver-compares against your GitHub tags.

## License

Licensed under **MIT** — see [LICENSE](LICENSE).
