# EZ Library — Core API Reference

Everything exposed by `Library.lua`. All filesystem/exec-only calls are pcall-guarded; features degrade gracefully where an executor lacks them.

---

## Getting the library

```lua
local EZ = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Library.lua"))()
```

Loading it twice is safe — old `EZUI` / `EZNotifs` / `EZQuickBar` ScreenGuis from a previous run are cleaned up automatically.

---

## Top-level state

| Property | Type | Description |
|---|---|---|
| `EZ.Flags` | `table` | Live element values keyed by element id. Read freely; **never write directly** — use the element's `:Set()` so the UI moves too |
| `EZ.Theme` | `table` | Current theme colours (`Base`, `Surface`, `Panel`, `Border`, `Accent`, `AccentDark`, `Text`, `TextDim`, `TextMuted`, `Success`, `Warning`, `Error`, `Info`) |
| `EZ.Themes` | `table` | 8 curated presets: `Midnight`, `Catppuccin`, `TokyoNight`, `Dracula`, `Nord`, `Rose` (Rose Pine), `Cyberpunk`, `Monochrome` |
| `EZ.Windows` | `table` | All live window handles |
| `EZ.Notifications` | `table` | Notification cards currently on screen |
| `EZ.MaxNotifications` | `number` | Cap for on-screen cards (default `5`; oldest pops off) |
| `EZ._version` | `string` | `"3.4.0"` |

Rebranding constants at the top of `Library.lua`: `REPO_SLUG` / `REPO_RAW` power the update checker and AutoSettings' addon fetches.

---

## EZ:SetIcons(pack)

```lua
EZ:SetIcons(Icons) -- Icons = the Icons addon module (see docs/ICONS.md)
```

Once bound, every icon slot in the library accepts **Lucide names** (`"sword"`, `"bell"`) in addition to raw asset refs.

## EZ:ResolveIcon(ref) -> `string?`

Accepts and normalises: plain number id, numeric string, any string containing `rbxassetid://` / `rbxthumb://` / `rbxgameasset://` / `http`, or a Lucide name resolved through the bound icon pack. Returns `nil` when unresolvable.

---

## EZ:Notify(options) -> `Frame`

| Option | Type | Default | Description |
|---|---|---|---|
| `Title` | string | `"EZ"` | Bold heading |
| `Content` | string | `""` | Wrapped body text |
| `Duration` | number | `4` | Seconds before dismiss |
| `Type` | string | `"info"` | `info` / `success` / `warning` / `error` — colours the edge |

Cards stack top-right, newest on top, capped by `EZ.MaxNotifications`. Returns the card frame.

---

## Flag listeners

```lua
EZ:OnFlagChanged(id, fn)    -- fn(newValue)
EZ:OffFlagChanged(id, fn)   -- remove a specific listener
```

Listeners fire whenever an element with that id changes (including config restores). Listeners run through `safecall` (async, errors logged not thrown). Removing a listener from inside a listener is safe.

Elements also expose a chained variant: `handle:OnChanged(fn)`.

---

## Error handling

```lua
EZ:OnError(function(entry)
    -- entry.source, entry.message, entry.traceback, entry.time
end)
local log = EZ:GetErrors() -- last 50 error entries
```

Internal failures are logged, warned, surfaced as an error notification, and passed to your handler — callbacks never crash the host script.

---

## EZ:KeySystem(options) -> `boolean` *(yields)*

Blocks the calling thread until the key passes or attempts run out. Returns `true` when unlocked.

| Option | Type | Default | Description |
|---|---|---|---|
| `Title` | string | `"Key System"` | Card heading |
| `SubTitle` | string | `"Enter your key to continue"` | Sub-heading |
| `Keys` | `{string}` | `{}` | Plaintext keys (dev/test) |
| `HashedKeys` | `{string}` | — | SHA-256 hashes (recommended). Requires executor `crypt.hash`; without it the gate locks itself with an explicit error instead of pretending |
| `SaveKey` | string | `"EZKey.txt"` | Saved-key filename. Stores the **HWID-salted hash**, never the raw key (plaintext fallback when no crypt) |
| `MaxAttempts` | number | `5` | Wrong tries before lockout |
| `GetKeyLink` | string? | — | Shows a copy-to-clipboard button |
| `GetKeyText` | string | `"Get Key"` | Button label |
| `OnLockout` | function? | — | Fires when locked out |
| `Callback` | function? | — | `function(success)` after unlock (also fired on saved-key bypass) |

```lua
if not EZ:KeySystem({
    Title = "My Hub",
    Keys = { "dev-key" },            -- use HashedKeys in production
    SaveKey = "MyHub_Key.txt",
    GetKeyLink = "https://discord.gg/Bba9Jct6PN",
}) then return end
```

---

## EZ:CreateWindow(options) -> `Window`

| Option | Type | Default | Description |
|---|---|---|---|
| `Title` | string | `"EZ"` | Header text |
| `SubTitle` | string? | — | Small muted sub-header |
| `ToggleKey` | Enum.KeyCode | `RightShift` | Hide/show hotkey |
| `ToggleIcon` | string? | — | Lucide name / asset ref for the restore pill |
| `ToggleText` | string? | `"V"` | Pill text when no icon |
| `Width` / `Height` | number | `560×400` (auto-fit on mobile) | Window size |
| `TabWidth` | number | `150` (52 mobile) | Sidebar width |
| `Scale` | number | `1` | Initial UIScale (0.5–2) |
| `SidebarToggle` | boolean | `true` | Show sidebar collapse chevron |
| `Gestures` | boolean | `true` | Mobile swipe tab-switching |
| `AutoSettings` | boolean | `true` | Auto-attach the Settings tab — see [AUTO_SETTINGS.md](AUTO_SETTINGS.md) |

### Window methods

```lua
Window:Show() Window:Hide() Window:Toggle()
Window:Minimize()  -- alias of Hide (addon-friendly delegation)
Window:Restore()   -- alias of Show
Window:ToggleSidebar()
Window:SetScale(n) Window:GetScale()
Window:AddTab(name, icon?) -> Tab
Window:AddDialog(id, options) -> Dialog
Window:Destroy()
```

`Show`/`Hide` are delegated, so addon hooks (QuickBar) survive rebinding. Closing the header ✕ runs the **full** `EZ:Destroy()` nuke.

### Dialogs

```lua
Window:AddDialog("unique-id", {
    Title = "Delete config",
    Description = "This cannot be undone.",
    AutoDismiss = false,          -- dimmer inert; force a button (default true = click-outside dismisses)
    FooterButtons = {
        { Title = "Cancel", Variant = "Ghost", Order = 1 },
        { Title = "Delete", Variant = "Destructive", Order = 2,
          Callback = function(dialog) dialog:Dismiss() end },
    },
})
```

Variants: `Ghost` (muted), `Primary` (accent), `Destructive` (red). Buttons without a `Callback` self-dismiss. Sorted by `Order`.

---

## Tabs

```lua
local Tab = Window:AddTab("Main", "sword")  -- icon optional (lucide name / asset ref)

Tab:AddSection(name) -> Section
Tab:AddSubTab(name)  -> SubTab        -- horizontal pill row; SubTab:AddSection nests under it
Tab._activate()                      -- programmatic switch (used internally by gestures)
```

Each tab also gets an automatic **badge** counting its currently-visible ON toggles (compact `1.2k` formatting).

Mobile tabs truncate labels to 3 characters; swipe left/right switches tabs.

---

## Section elements

Every element writes its value into `EZ.Flags[id]`, supports `opts.Tooltip` (string), `opts.VisibleWhen` (flag id that must be truthy for the row to exist visually), and registers itself for the header **search filter** (matches against display text). Duplicate ids warn — the last element registered wins saves/loads.

All value-holding handles share: `:Set(v [, silent])`, `:Get()`, `:OnChanged(fn)` (chainable).

### AddToggle(id, options) -> handle

| Option | Default | Description |
|---|---|---|
| `Text` | `id` | Row label |
| `Default` | `false` | Initial state |

### AddSlider(id, options) -> handle

| Option | Default | Description |
|---|---|---|
| `Text` | `id` | Label |
| `Min` / `Max` | `0` / `100` | Swapped automatically if inverted |
| `Default` | `Min` | Clamped into range |
| `Increment` | `1` | Snap step; decimal steps render cleanly (no float noise) |
| `Suffix` | `""` | Value-label unit, e.g. `"x"` |

Clicking anywhere on the rail jumps straight to that position.

### AddButton(options) -> button

`Text`, `Callback`. Press flash + accent glow included. Accepts `Tooltip`/`VisibleWhen`.

### AddDropdown(id, options) -> handle

| Option | Default | Description |
|---|---|---|
| `Text` | — | Title above the box |
| `Values` | `{}` | String list |
| `Default` | first value | Pre-selected entry |
| `Multi` | `false` | Map mode — value arrives/expects `{Name = true}` |
| `Callback` | — | Receives selection |

Extras: `handle:Refresh(newList)` swaps options (keeps selection when still present). Lists open outside their section (never clipped), close on outside-click/scroll/page-scroll/minimise.

### AddInput(id, options) -> handle

`Text`, `Placeholder` (`"Type here..."`), `Default` (`""`). Callback receives `(text, enterPressed)`; `:Set` coerces to string.

### AddKeybind(id, options) -> handle

| Option | Default | Description |
|---|---|---|
| `Text` | `id` | Label |
| `Default` | `Enum.KeyCode.Unknown` | Bound key |
| `Mode` | `"Toggle"` | `"Toggle"` flips on press, `"Hold"` is down-state |
| `Modifiers` | none | `{Ctrl = true}` or `{"ctrl"}` — either physical Ctrl/Alt/Shift counts |

Click the chip to capture (press **Esc to cancel** — modifiers held during capture are recorded). The flag stays a plain KeyCode; modifiers live on the handle.

```lua
handle:Configure({ Key = Enum.KeyCode.K, Mode = "Hold", Modifiers = { Ctrl = true } })
handle:GetMode() handle:GetModifiers() handle:IsActive()
```

Configs restore the full shape via `Configure`.

### AddColorPicker(id, options) -> handle

| Option | Default | Description |
|---|---|---|
| `Text` | `id` | Label |
| `Default` | white | Any Color3 |
| `Transparency` | `0` | Alpha preview (0–1) |

HSV canvas + hue bar + transparency ramp + HEX box. **Invariant:** the flag stays a plain `Color3`; transparency lives on the handle — `:SetTransparency(t)` / `:GetTransparency()` (silent, config-safe). Bad restores are ignored safely.

### AddLabel(text) / AddParagraph(options) / AddDivider()

Labels accept a string or `{ Text = ... }`. Paragraphs take `{ Title?, Content }` and wrap; both expose `:Set(newText)`. Dividers are hairlines.

### AddProgressBar(id, options) -> handle

`Text`, `Max` (`100`), `Default` (`0`), `Color` (accent), `ShowText` (`true`). Methods: `:Set(v)` (clamped), `:SetMax(m)` (rescale in place), `:SetColor(c)`, `:Get()`. Saved by configs (`Progress` type).

### AddLog(options) -> handle

`Height` (`120`), `MaxLines` (`50`), optional `Text` (search tag). Methods: `:Info :Warn :Error :Success :Print(txt, color?) :Clear()`. Line order is monotonic — trimming never scrambles layout.

### AddPlayerSelector(id, options) -> dropdown handle

A self-refreshing dropdown of players plus shortcuts. Options: `Text` (`"Select Player"`), `Multi`, `ExcludeSelf` (`true` — hides your own name; `false` adds `@me`), `Default`.

Shortcuts: `@me`, `@random`, `@nearest` (needs a HumanoidRootPart). Resolve real players with:

```lua
local players = selector:GetPlayers() -- respects the shortcut / multi-map
```

---

## Watermark

```lua
local wm = EZ:CreateWatermark({
    Text = "{user} | {fps} fps | {ping} ms",
    Position = UDim2.new(0, 12, 0, 12),
})
wm:SetText(tmpl) wm:SetPosition(udim2) wm:Show() wm:Hide() wm:Destroy()
```

Tokens (refreshed 2×/sec): `{fps}` `{ping}` `{time}` `{user}` `{place}` `{flag:id}`.

---

## Floating keybind menu

```lua
EZ:ShowKeybindMenu() EZ:HideKeybindMenu() EZ:ToggleKeybindMenu()
local menu = EZ:CreateKeybindMenu() -- handle: SetVisible(bool) / Destroy()
```

Lists every keybind across all windows with live combos + active dots. Drag position and visibility persist to `EZKeybindMenu.txt`.

---

## Misc

```lua
EZ:Haptic("light" | "medium" | "heavy")  -- gamepad rumble; no-op without a controller
local info = EZ:CheckForUpdate("Beastaive22/EZ-UI-Library")
-- info = { latest, current, outdated, url, body }; proper semver compare

EZ:AttachTooltip(guiObject, "text")      -- manual tooltip attach
EZ:Destroy()                             -- nuke everything (windows, pills, listeners, flags)
EZ:OnDestroy(fn)                         -- cleanup hook for addons holding outside resources
```

`CheckForUpdate` reads GitHub releases; tag prefixes like `v3.4.0` are handled, and locally-newer builds report up-to-date.

---

## Behaviour notes

- **Search**: typing in the header filters every registered element by display text; empty sections collapse; sub-tabs hand visibility back on clear; hidden-by-condition rows never leak back.
- **Tooltips** attach on hover, flip above near screen bottom, die with their owner.
- **Dragging**: window clamps ≥80px visible; popups/dropdowns close on minimise.
- **Threading**: all callbacks run via `task.spawn` — rapid interactions can interleave; guards exist for slider/picker drags (`EZ._activeDrag` mutex).
