# ThemeManager — Themes & Persistence

Live theme switching with disk persistence, custom theme registration, and safe merging.

```lua
local ThemeManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/addons/ThemeManager.lua"))()
ThemeManager:Bind(EZ, { File = "MyHub_Theme.txt" })  -- File optional (default "EZTheme.txt")
```

> AutoSettings handles all of this for you — see [AUTO_SETTINGS.md](AUTO_SETTINGS.md).

---

## API

| Method | Description |
|---|---|
| `Bind(library, opts?)` | Attach to the library. `opts.File` gives the persistence file a per-brand name so parallel scripts don't fight over one setting |
| `SetTheme(name)` -> `bool` | Apply + save. Re-applying the active theme is a cheap no-op; an external `EZ:SetTheme()` call automatically un-sticks that guard |
| `GetThemes()` | Sorted theme-name list |
| `AddTheme(name, colorTable)` -> `bool` | Register/replace a theme. Missing roles are filled from frozen Midnight; non-Color3 values are dropped with a warning |
| `LoadSaved()` | Read + apply the persisted choice (trims whitespace) |

```lua
ThemeManager:AddTheme("Brand Purple", {
    Accent = Color3.fromRGB(160, 90, 255),
    Base   = Color3.fromRGB(12, 10, 20),
    -- any role you omit inherits Midnight
})
```

**Rebranding note:** replacing an already-active theme via `AddTheme` correctly invalidates the dedupe guard, so updated colours actually apply on the next `SetTheme(name)`.

---

## Colour roles

Every theme may define all 13 roles (Color3 only):

`Base` · `Surface` · `Panel` · `Border` · `Accent` · `AccentDark` · `Text` · `TextDim` · `TextMuted` · `Success` · `Warning` · `Error` · `Info`

Switching themes recolours the **entire UI live** — windows, dropdown lists, popups, tooltips, watermark and addon surfaces included — by matching each instance's current colour back to its role (two deterministic maps keyed by usage, so themes that share exact RGB values can't cross-contaminate).

---

## Built-in presets

### In the library (`EZ.Themes`, auto-registered by AutoSettings)

| Name | Accent | Text |
|---|---|---|
| Midnight | `(124, 92, 252)` | `(232, 232, 240)` |
| Catppuccin | `(203, 166, 247)` | `(205, 214, 244)` |
| TokyoNight | `(125, 207, 255)` | `(192, 202, 245)` |
| Dracula | `(189, 147, 249)` | `(248, 248, 242)` |
| Nord | `(136, 192, 208)` | `(236, 239, 244)` |
| Rose (Rose Pine) | `(235, 188, 186)` | `(224, 222, 244)` |
| Cyberpunk | `(0, 255, 200)` | `(240, 240, 255)` |
| Monochrome | `(230, 230, 230)` | `(245, 245, 245)` |

### Extra in ThemeManager

Ocean `(50,140,255)` · Rose `(240,80,130)` · Emerald `(50,210,120)` · Sunset `(255,130,50)` — plus Midnight again as the merge base.
