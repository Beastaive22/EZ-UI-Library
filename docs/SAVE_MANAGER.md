# SaveManager — Configs, Profiles & Autoload

Config snapshots, named profiles, and one-click **config autoload** (Obsidian-style). Everything is pcall-guarded; a missing filesystem degrades to no-ops instead of errors.

```lua
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/addons/SaveManager.lua"))()
SaveManager:Bind(EZ, "MyHubConfigs")
```

> **Prefer zero setup?** `EZ:CreateWindow()` attaches this (plus ThemeManager) automatically via AutoSettings — see [AUTO_SETTINGS.md](AUTO_SETTINGS.md). This doc covers the manual API.

---

## Disk layout

**v3.7: everything is namespaced per game.** The executor workspace is shared
by every game and script on it — without a game layer, a config (or the
autoload pointer) saved in one game silently applied in the next one. The
default game key is the experience id (`game.GameId`, falling back to
`game.PlaceId`, empty in Studio). `SetPerGame(false)` restores the flat layout.

```
MyHubConfigs/                      <- Folder (SetFolder / Bind)
├── 123456789/                     <- game key (game.GameId by default)
│   ├── my-config.json             <- configs live here
│   ├── another-config.json
│   ├── _autoload.txt              <- autoload pointer (per game)
│   ├── _active_profile.txt        <- active profile marker (per game)
│   └── profiles/
│       └── Profile 1.json
└── 987654321/                     <- another game, completely separate
```

`SetSubFolder("doors-run")` nests one level deeper **under the game key**
(`MyHubConfigs/123456789/doors-run/`) — place-level splits stay per-game too.
On `Bind`, anything saved by 3.6 or earlier (root configs, `profiles/`,
`_autoload.txt`, `_active_profile.txt`) is **migrated** into the per-game
namespace automatically (copy-then-delete, fully guarded).

Name sanitisation: anything outside `[A-Za-z0-9 -_. ]` becomes `_`; `"."`,
`".."` and the reserved name `autoload` are rejected.

---

## Setup API

| Method | Description |
|---|---|
| `SaveManager:SetLibrary(EZ)` | Bind the library (no folder work) |
| `SaveManager:Bind(EZ, folder?)` | Full bind: SetFolder + build tree + **migrate legacy files** + restore active profile. Returns self |
| `SaveManager:SetFolder(folder)` | Assert-valid folder, rebuild tree |
| `SaveManager:SetPerGame(enabled)` | Toggle per-game namespacing (default **on**). `SetPerGame(false)` restores the flat pre-3.7 layout |
| `SaveManager:SetGameKey(key)` | Override the game key (default `tostring(game.GameId)`; use a PlaceId to isolate sub-places; `nil` restores the default) |
| `SaveManager:MigrateLegacyLayout()` | Move 3.6-era root files into the per-game namespace (called by `Bind`) |
| `SaveManager:SetSubFolder(sub)` | Nest configs + profiles one level deeper, **under the game key** |
| `SaveManager:GetPaths()` | Cumulative path segments (`{ "A", "A/<game>" }`) |
| `SaveManager:BuildFolderTree(skipWhenCreated?)` | Create every missing folder incl. `profiles` |
| `SaveManager:CheckFolderTree()` | `BuildFolderTree(true)` — cheap existence check |
| `SaveManager:CheckSubFolder(create?)` | Sub-folder exists? / create it |

`isValidFolderPath` rejects `< > : " | ? %z` and whitespace-only names.

---

## Ignore lists & load order

```lua
SaveManager:SetIgnoreIndexes({ "SomeFlag", "_EZSM_JSON" })  -- never saved/restored
SaveManager:ClearIgnoreIndexes()

-- restore toggles first, then dropdowns, then the rest:
SaveManager:SetLoadingOrder(true, { "Toggle", "Dropdown", "Slider", "Input", "Keybind", "ColorPicker", "Progress" })
```

`IgnoreThemeSettings()` exists for API parity with Obsidian; EZ keeps themes out of flags so there's normally nothing theme-shaped to filter.

---

## Config CRUD

| Method | Returns | Notes |
|---|---|---|
| `Save(name)` | `ok, err` | Sanitises name, rejects reserved, builds tree, writes JSON |
| `Load(name)` | `ok, err` | Reads + applies (objects format or legacy flat map) |
| `Delete(name)` | `ok, err` | Removes file; clears the autoload pointer if it pointed here |
| `DoesConfigExist(name)` | bool | Raw-path check (unsanitised input) |
| `RefreshConfigList()` | `{string}` | `*.json` basenames, sorted |
| `GetConfigs()` | `{string}` | Alias of RefreshConfigList |

### JSON formats

**Format 2 (written):**

```json
{
    "format": 2,
    "timestamp": "24.08.2026 14:02:11",
    "name": "my-config",
    "game": "123456789",
    "script": "MyHubConfigs",
    "objects": [
        { "idx": "SpeedToggle", "type": "Toggle",   "value": true },
        { "idx": "FOV",         "type": "Slider",    "value": 120 },
        { "idx": "Team",        "type": "Dropdown",  "value": "Red", "multi": false },
        { "idx": "Names",       "type": "Dropdown",  "value": {"Alpha": true}, "multi": true },
        { "idx": "Webhook",     "type": "Input",     "text": "https://..." },
        { "idx": "AimKey",      "type": "Keybind",
          "key": "Enum.KeyCode.G", "mode": "Hold",
          "modifiers": { "Ctrl": true } },
        { "idx": "ESPColor",    "type": "ColorPicker",
          "value": "#7C5CFC", "transparency": 0.5 },
        { "idx": "XPBar",       "type": "Progress",  "value": 40 }
    ]
}
```

Object order is deterministic (sorted by flag id) → clean diffs between saves.

**Legacy flat map (still loaded):** `{ FlagName = { type = "boolean|number|string|Color3|EnumItem|table", value = ... } }`.

Restore rules shared by both formats:

- Values are validated by type before applying; garbage is skipped silently
- Elements are restored through their handles (fires callbacks + listeners), deferred per object so callbacks can't re-enter mid-loop
- Parsers skip when `Get()` already equals the saved value — unchanged values never re-push into the element
- Keybinds restore key + mode + modifiers via `Configure`; color pickers restore hex **and** transparency

### Import / Export (clipboard-friendly)

```lua
local str  = SaveManager:Export()      -- base64 legacy JSON (falls back to raw JSON)
local ok, err = SaveManager:Import(str) -- accepts base64 OR raw JSON, either format
local json, okEncode, err = SaveManager:SaveJSON("name") -- format-2 string
SaveManager:LoadJSON(json)              -- -> ok, err
```

---

## Autoload — points at a CONFIG

```lua
SaveManager:SetAutoload... -- see methods below
```

| Method | Returns | Description |
|---|---|---|
| `GetAutoloadConfig()` | `name\|"none", ok, err` | Reads `_autoload.txt`, validates the config file exists |
| `SaveAutoloadConfig(configName)` | `ok, err` | Config must exist; writes the pointer |
| `DeleteAutoLoadConfig()` | `ok, err` | Removes the pointer |
| `LoadAutoloadConfig()` | `ok, err` | Validates then `Load`s it; notifies on failure/success |

Call once after **all** tabs/elements exist (AutoSettings defers it for you):

```lua
SaveManager:LoadAutoloadConfig()
```

Deleting an autoloaded config via `Delete()` clears the pointer automatically.

---

## Profiles — manual named snapshots

Profiles are separate from autoload: extra copies you flip between yourself (per-game setups etc.).

| Method | Returns | Notes |
|---|---|---|
| `GetProfiles()` | `{string}` | Sorted from `profiles/` |
| `GetActiveProfile()` | `string?` | Restored on `Bind` if its file still exists |
| `SaveProfile(name)` | `ok, err` | Writes + marks active |
| `LoadProfile(name)` | `ok, err` | Applies + marks active |
| `RenameProfile(old, new)` | `ok, err` | Verifies destination write **before** deleting source |
| `DeleteProfile(name)` | `ok, err` | Clears active marker; never touches autoload |

---

## UI builders

### BuildConfigSection(section, window?) 

Renders the full management UI into any EZ section:

1. **Config name** input
2. **Create config** — overwrite-confirm dialog when the file exists
3. *divider*
4. **Config list** dropdown (selection preserved across refreshes)
5. Load config / Overwrite config / Delete config / Refresh list (destructive ones confirm)
6. **Set as Autoload** / **Reset autoload**
7. Live label: `Current autoload config: <name>`
8. *divider*
9. **Config JSON** input + Import-from-box / Export-to-clipboard

Internal flags (`_EZSM_ConfigName`, `_EZSM_ConfigList`, `_EZSM_JSON`) are auto-registered in the ignore list.

### BuildProfileUI(section, window?)

Profile dropdown (selecting loads it), **Save / New / Rename / Delete Profile**, live `Active profile:` label. Delete + overwrite confirm via dialogs when a `window` is passed. Internal flags: `_EZProfile`, `_EZSM_ProfileName`.
