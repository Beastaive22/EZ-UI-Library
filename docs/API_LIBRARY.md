# EZ UI Library — API Reference

Complete reference for `Library.lua` + official addons. Everything here is
verified against the current build (**v3.6.0**, live-tested on an executor client).

```
local EZ = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/Library.lua"))()
```

---

## 1. EZ:CreateWindow(options) -> Window

| Option | Default | Description |
|---|---|---|
| `Title` | `"EZ"` | Header title (also keys the geometry save file) |
| `SubTitle` | — | Small line under the title |
| `Width` / `Height` | `620` / `440` | Window size (resizable by drag, min 460×360 — never above the created size) |
| `TabWidth` | `150` (52 mobile) | Sidebar width |
| `ToggleKey` | `Enum.KeyCode.RightShift` | Hide/show hotkey — keyboard **or** `Enum.UserInputType.MouseButton1/2/3` |
| `ToggleIcon` | — | Lucide name / asset ref for the dock's Open tile |
| `ToggleText` | `"V"` | Open tile fallback text when no icon resolves |
| `Icon` | — | Header brand icon: Lucide name, asset id, or url. Falls back to the pulsing accent dot |
| `IconTint` | auto | Tint the header icon to the theme. Auto = pack icons yes, supplied art no (tinting a black logo to accent makes it vanish on a dark header) |
| `Scale` | `1` | Initial UI scale (0.5–2) |
| `SidebarToggle` | `true` | Show the sidebar-collapse button |
| `Gestures` | `true` | Mobile swipe-to-switch-tabs |
| `AutoSettings` | `true` | Auto-attach the Settings tab (see [AUTO_SETTINGS.md](AUTO_SETTINGS.md)) |
| `PersistGeometry` | `true` | Remember window position + size across rejoins |
| `GeometryId` | title slug | Stable persistence key for geometry/dock files — use it when two scripts could share a title, or when the title contains punctuation (the slug strips it) |
| `CloseBehavior` | `"library"` | `"library"`: the X button nukes the whole library (`EZ:Destroy()`). `"window"`: the X destroys only this window (addons/listeners stay) |

### Window methods

```lua
Window:Show() Window:Hide() Window:Toggle()
Window:Minimize() Window:Restore()      -- delegate to Hide/Show (addon-safe)
Window:SetScale(n) Window:GetScale()
Window:SetToggleKey(key) Window:GetToggleKey()
Window:SetBackgroundImage(asset)        -- "rbxassetid://...", numeric id, or "" to clear
Window:ToggleSidebar()
Window:AddTab(name, icon?) -> Tab
Window:AddSettingsTab(options?) -> Tab  -- Obsidian-style groupbox layout
Window:AddDialog(id, options) -> Dialog
Window:Destroy()
```

Closing the window with its **X button** runs a full `EZ:Destroy()` nuke — every
window, addon surface, listener and connection goes down with it.

### Minimize dock

Hiding the window shows a draggable 3-tile dock (position persists):

| Tile | Action |
|---|---|
| **Open** (accent) | Restore the window |
| **Panic** | Suspend every toggle + active keybind (tile turns red); click again to restore. Also: `EZ:SetPanic(bool)` / `EZ:TogglePanic()` / `EZ:IsPanic()` / `_EZPanic` flag |
| **Keybinds** | Toggle the floating keybind menu |

If [QuickBar](#7-addons) has pins, it replaces the dock.

### Dialogs

```lua
Window:AddDialog("id", {
    Title = "Delete config",
    Description = "This cannot be undone.",
    AutoDismiss = false,   -- default true: click outside dismisses
    FooterButtons = {
        { Title = "Cancel", Variant = "Ghost", Order = 1 },
        { Title = "Delete", Variant = "Destructive", Order = 2,
          Callback = function(dialog) dialog:Dismiss() end },
    },
})
```

Variants: `Ghost` / `Primary` / `Destructive`. Buttons without a callback self-dismiss.

---

## 2. Appearance APIs

```lua
EZ:SetFont(font)          -- "BuilderSans", "GothamBold", "Code", "Jura", ... (EZ.FONT_FAMILIES)
                          -- or an Enum.Font; "Default" resets. Sweeps all UI incl. new elements.
EZ:SetCornerRadius(n)     -- 0-20 live corner radius (14 = designed per-element radii)
EZ:SetNotificationSide("Left" | "Right")
-- Custom cursor — v4.0 two-layer overlay (crosshair + optional icon):
EZ.Cursor:ChangeCrossColor(Color3.fromRGB(255, 80, 80))
EZ.Cursor:ResetCross()
EZ.Cursor:ChangeIcon("crosshair")      -- lucide name, asset id or URL; "" = reset
EZ.Cursor:ChangeIconColor(Color3.fromRGB(80, 255, 120))
EZ.Cursor:ChangeIconSize(UDim2.fromOffset(32, 32))
EZ.Cursor:ResetIcon()
EZ.Cursor:ResetCursor()                -- resets both layers
EZ:SetCursorEnabled(true)              -- toggle (Settings ▸ Custom Cursor)
EZ:SetCursorIcon("rbxassetid://...")   -- alias of EZ.Cursor:ChangeIcon
EZ:SetTheme(partialTable) -- merge e.g. { Accent = Color3... }; full UI recolour
EZ:GetTheme()             -- live theme table
EZ.Themes                 -- 8 built-in presets (Midnight, Catppuccin, ...)
```

---

## 3. Tabs, Groupboxes, Sections

```lua
local Tab = Window:AddTab("Main", "sword")  -- icon: lucide name / asset ref

Tab:AddSection(name, description?) -> Section           -- full-width
Tab:AddLeftGroupbox(name, icon?, description?)  -> Section -- two-column layout, boxes align
Tab:AddRightGroupbox(name, icon?, description?) -> Section
Tab:AddGroupbox("left" | "right", name, icon?, description?) -> Section
Tab:AddSubTab(name) -> SubTab                -- pill row; SubTab:AddSection nests inside
Tab._activate()                              -- programmatic switch
```

- Groupboxes are full sections — every builder below works inside them, including
  `SaveManager:BuildConfigSection(groupbox, Window)`.
- Full-width sections render above the groupbox columns.
- Selected tab = filled highlight + accent indicator. Tabs auto-badge visible ON toggles.
- Header search filters sections, groupboxes and sub-tabs.
- **v3.9**: sections/groupboxes take an optional description, and every
  section supports `:SetDescription(desc)` (create/update/clear after
  creation), `:SetVisible(v)` / `:Show()` / `:Hide()`.

---

## 4. Elements

**v3.9 uniform handles**: every element handle carries `.Frame` and supports
`:SetVisible(v)` (composes with `VisibleWhen` + search), `:SetDisabled(d)` /
`:IsDisabled()` (dims + blocks interaction), `:Destroy()` (removes from the UI
+ config registry; `EZ.Flags[id]` cleared). `:SetText(t)` exists on Toggle,
Slider, Dropdown, Input, Keybind, ColorPicker, ProgressBar and Label.

Not every element writes a flag: **Toggle, Slider, Dropdown, Input, Keybind,
ColorPicker, Progress and TabBox** store `EZ.Flags[id]`; Button, Label,
Divider, Paragraph and Log hold none. Elements generally support
`opts.Tooltip` (string) and `opts.VisibleWhen` (flag id gating visibility)
and appear in header search — Log supports neither. Handles share
`:Set(v [, silent])`, `:Get()`, `:OnChanged(fn)` where meaningful.
Duplicate ids warn (last wins config save/load).

### AddToggle(id, {Text, Default, Description, Callback}) -> handle
`Set(bool)` / `Get()` / `OnChanged(fn)`. `Description` renders a muted second
line under the label.

### AddSlider(id, {Text, Min, Max, Default, Increment, Suffix, Prefix, Callback}) -> handle
Clamped + snapped; decimal steps render cleanly. `Set(n)` / `Get()`.
**Click the value label to type an exact value** — commits through the same
clamp/snap/callback path as dragging; unparseable input restores the label.
**v3.9**: `Prefix` option + `:SetPrefix(t)`, `:SetText(t)`,
`:SetMin(n)` / `:SetMax(n)` (live range, value re-clamps).

### AddCheckbox(id, {Text, Default, Description, Callback}) -> handle
**v3.9**: checkbox visual variant (square + check mark) with the identical
toggle handle. Also enabled globally via `EZ.ForceCheckbox = true`.

### AddButton({Text, Callback, Tooltip, VisibleWhen})

### AddDropdown(id, options) -> handle
| Option | Description |
|---|---|
| `Text` | Title above the box |
| `Values` | **Array** `{"A","B"}` or **dictionary** `{key = "Display"}` (key is stored, display shown) |
| `Default` | Initial value / table for Multi |
| `Multi` | `true` → flag is `{name = true}` map |
| `Searchable` | `true` → search box inside the open list |
| `Disabled` | `{Value = true}` (or array) — dimmed, unclickable entries |
| `Callback` | `(value)` |

Handle: `Set(v [, silent])`, `Get()`, `Refresh(newValues [, disabled])` (accepts
either shape again; previously requested `Disabled` entries survive a refresh
unless the second argument replaces them). **`Set` on a Multi dropdown takes a
map** (`{Value = true}`) — arrays and bare scalars are normalized, but a raw
string crashed pre-3.6. Open multi lists get a Select all / Clear row
(disabled values excluded), and long selections collapse the header to
`"A, B +N more"`.

**v3.9 additions**: `SetValues` (alias of Refresh), `AddValues` (merge without
wiping), `SetDisabledValues`/`AddDisabledValues`, `SetValueImages`/
`AddValueImages` (icons per option — Lucide name / asset), `SetText`,
`SetDragSelect(true)` (sweep-select rows), `GetActiveValues(countOnly?)`;
options `VisibleItems` (row cap), `Height` (fixed px), `AllowEmptySelection`
(single: clicking the selected value clears it), and `Default` as an index.

### AddInput(id, {Text, Placeholder, Default, Callback}) -> handle
Callback `(text, enterPressed)`. `Set(text [, silent])` / `Get()`.

### AddTabBox(id, {Tabs = {"Tab 1", "Tab 2"}, Callback}) -> handle
Segmented pill control; each tab is a full section:

```lua
local tb = sec:AddTabBox("Mode", { Tabs = { "Legit", "Rage" } })
tb.Tabs["Legit"]:AddToggle("Smooth", { Default = true })
tb.Tabs["Rage"]:AddSlider("FOV", { Min = 0, Max = 360, Default = 90 })
tb:Select("Rage")  -- or tb.Set / tb.Get; flag = selected name
```

### AddKeybind(id, options) -> handle
| Option | Description |
|---|---|
| `Text` | Row label |
| `Default` | `Enum.KeyCode.X` **or** `Enum.UserInputType.MouseButton1/2/3` |
| `Mode` | `"Toggle"` (default) or `"Hold"` |
| `Modifiers` | `{Ctrl = true}` / `{"ctrl"}` — either physical key counts |
| `Callback` | `(isActive)` |

Click the chip to capture any key **or mouse button** (Esc cancels; held modifiers
are recorded; chip shows `M1/M2/M3`). Mouse triggers respect game-processed
input. Releasing a Hold always releases even if a modifier lifted first.

Handle: `Set(k)` (accepts `"G"`, `"MouseButton2"`, `"Enum.KeyCode.G"`), `Get()`,
`IsActive()`, `SetActive(bool)`, `Configure({Key, Mode, Modifiers})`,
`GetMode()`, `GetModifiers()`. Flag = plain EnumItem; SaveManager round-trips it.

### AddColorPicker(id, {Text, Default, Transparency, Palette, Callback}) -> handle
HSV canvas + hue + transparency ramp + **hex box + RGB box + Copy/Paste color**.
Closes on outside click and on page scroll. `Set(Color3)`, `Get()`,
`SetTransparency(0-1)`, `GetTransparency()`. Flag stays a plain Color3.
`Palette = {Color3, ...}` renders a preset-swatch row in the popup, and the
last 6 deliberate picks are remembered for the session (not persisted).

### AddLabel(textOrOpts) / AddDivider(textOrOpts) / AddParagraph({Title, Content})
Labels/paragraphs accept `{Text/Title/Content, Tooltip, VisibleWhen, RichText}`;
handles expose `:Set(text)`. `RichText = true` opts the label into Roblox
RichText markup (`<b>`, `<font color="#...">`, ...) — opt-in only, never set it
for user-typed content. **v3.9**: labels take `DoesWrap = true` (multiline) and
`Size = 14` (text size) + `:SetSize(n)`; dividers take centered text
(`AddDivider("Grouped")`) and `MarginTop`/`MarginBottom`, and return a handle
(`:Destroy()`).

### AddProgressBar(id, {Text, Default, Max, Color, ShowText}) -> handle
`Set(v)` / `Get()` / `SetMax(m)` / `SetColor(Color3)`.

### AddLog({Height, MaxLines, Text}) -> handle
`Info/Warn/Error/Success/Print(text, color)/Clear()`.

### AddPlayerSelector(id, {Text, ExcludeSelf, Multi, Callback}) -> dropdown handle
Preloaded with `@me` / `@random` / `@nearest` + players; auto-refreshes on
join/leave. `dd:GetPlayers()` resolves the selection to Player instances.

### AddViewport(id, {Object, Camera, Interactive, AutoFocus, Height}) -> handle  (v4.1)
3D preview (ViewportFrame + WorldModel). `Object` is cloned into the world;
camera auto-fits unless `AutoFocus = false`; `Interactive` (default true) adds
drag-orbit + wheel/pinch zoom. Handle: `:SetObject(o)`, `:GetObject()`,
`:SetCamera(cam)`, `:SetInteractive(v)`, `:SetHeight(h)`, `:Focus()` +
uniform `SetVisible/SetDisabled/Destroy`.

### AddUIPassthrough(id, {Instance, Height}) -> handle  (v4.1)
Embeds any GuiBase2d in the layout. `:SetInstance(inst)` swaps (the previous
instance is restored to its old parent/size/position), `:SetHeight(h)`;
`:Destroy()` hands the embedded instance back to where it came from.

### Utilities (v4.1)
```lua
EZ:GetIcon(name) / EZ:ApplyLucideIcon(imageGui, ref, rotation?)
EZ:GiveSignal(conn)            -- disconnected on EZ:Destroy
EZ:SafeCallback(fn, ...)       -- error-captured call
EZ:GetTextBounds(text, font, size, maxWidth?) -> w, h
EZ:GetBetterColor(c, amt) / GetLighterColor(c) / GetDarkerColor(c)
EZ.ImageManager:AddAsset(name, assetId, url?, force?) / GetAsset(name) / DownloadAsset(name, force?)
-- ImageManager downloads once via getcustomasset into EZImageCache/ and falls
-- back to rbxassetid://<assetId> when the executor can't do custom assets
```

---

## 5. Notifications

```lua
EZ:Notify({
    Title = "Hi", Content = "...", Duration = 4,
    Type = "info|success|warning|error",
    Buttons = { { Text = "Open", Callback = function() end } }, -- action row; taking an action dismisses the card
    Duration = false,          -- v4.0: persistent (no auto-dismiss)
    TotalSteps = 4,            -- v4.0: renders a progress bar
    SoundId = 12221967,        -- v4.0: plays when the card shows
    Volume = 3,                -- v4.0 sound volume (default 3)
})
EZ.MaxNotifications = 5   -- max cards on screen

local n = EZ:Notify({ Title = "Job", TotalSteps = 4, Duration = false }) -- v4.0 handle
n:ChangeTitle("New title")          -- v4.0: live update
n:ChangeDescription("New text")     -- v4.0: card re-measures its height
n:ChangeStep(2)                     -- v4.0: tween the progress fill + "2/4" label
n:Dismiss()                         -- v4.0: alias Destroy — closes the card
n.Frame                             -- the card frame (property reads/writes forward)
```

Cards show a type-colored Lucide icon (when the icon pack resolves one —
`info/circle-check/triangle-alert/octagon-x` with fallbacks) or a colored dot;
auto-dismiss unless persistent.

---

## 6. Keybind menu, watermark, misc

```lua
EZ:ShowKeybindMenu() EZ:HideKeybindMenu() EZ:ToggleKeybindMenu()
-- draggable panel of every keybind + live combos; position/visibility persist
-- rows group under their owning window's name when 2+ windows have keybinds
EZ:SetKeybindMenuAnchor("Top Left|Top Right|Bottom Left|Bottom Right")
EZ:GetKeybindMenuAnchor()           -- start corner (default Top Right);
                                    -- a dragged position wins until re-picked

local wm = EZ:CreateWatermark({ Text = "{fps} fps | {ping} ms | {flag:MyToggle}" })
-- tokens: {fps} {ping} {time} {user} {place} {flag:id}
wm:SetText(t) wm:SetPosition(udim2) wm:Show() wm:Hide() wm:Destroy()

EZ:Haptic("light|medium|heavy")     -- gamepad rumble
EZ:SetAntiAFK(true) / EZ:IsAntiAFK() -- v3.8: prevent the ~20 min idle kick;
                                     -- answers Idled with a virtual press,
                                     -- getconnections fallback, reversible.
                                     -- EZ._antiAFKCount = prevented kicks
local info = EZ:CheckForUpdate(repo?)  -- GitHub latest-release compare
-- returns NIL on any failure; otherwise { latest, current, outdated, url, body }
EZ:AttachTooltip(guiObj, text)
EZ:Destroy()                        -- full nuke; EZ:OnDestroy(fn) hooks first
```

### Flags & listeners

```lua
EZ.Flags.SomeToggle                 -- live values
EZ:OnFlagChanged(id, fn) EZ:OffFlagChanged(id, fn)
handle:OnChanged(fn)                -- chainable
EZ:OnError(fn) EZ:GetErrors()       -- callback errors are captured, never crash the UI
```

### Key system

```lua
if not EZ:KeySystem({
    Title = "My Hub", Keys = { "KEY1" },          -- or HashedKeys = { sha256... }
    SaveKey = "MyHub_Key.txt", GetKeyLink = "https://...",
    GetKeyText = "Get Key from Discord",           -- custom link-button label
    MaxAttempts = 5, OnLockout = function() end,
}) then return end
```
**This call blocks its thread** until the user passes or gets locked out —
always gate the rest of your script with `if not EZ:KeySystem(...) then return end`.
HWID-salted SHA-256 when `crypt.hash` exists; stores the hash, never the key.

---

## 7. Addons

### SaveManager
```lua
SaveManager:Bind(EZ, "Configs")     -- or SetLibrary + SetFolder/SetSubFolder
SaveManager:SetPerGame(enabled)     -- v3.7: per-game namespace (default on)
SaveManager:SetGameKey(key)         -- v3.7: override the game key (PlaceId etc.)
SaveManager:BuildConfigSection(sectionOrGroupbox, Window)
SaveManager:Save("name") / Load / Delete / GetConfigs()
SaveManager:SaveAutoloadConfig("name") / LoadAutoloadConfig() / DeleteAutoLoadConfig()
SaveManager:Export() / Import(str) / SaveJSON(name) / LoadJSON(json)
SaveManager:BuildProfileUI(section, Window)   -- profiles (not auto-attached)
```
Configs persist every registered element type; JSON import/export included.
Since 3.7 configs, profiles and the autoload pointer are namespaced per game
(`Folder/<game id>/…`) and 3.6-era files are migrated automatically on Bind.

### ThemeManager
```lua
ThemeManager:Bind(EZ, { File = "Brand_Theme.txt", CustomFile = "Brand_Themes.txt" })
ThemeManager:SetTheme(name) / GetThemes() / AddTheme(name, colorTable) / LoadSaved()
ThemeManager:AddCustomTheme(name, colors) / DeleteTheme(name)
ThemeManager:ExportTheme(name) / ImportTheme(json, preferredName?) / ResetDefault()
```

### QuickBar
```lua
QuickBar:Bind(EZ, Window, { MaxPins = 5, Position = UDim2..., File = "EZQuickBar.json" })
QuickBar:Pin("ToggleId", { Icon = "crosshair" })
QuickBar:PinButton("Reset", { Icon = "rotate-ccw", Callback = fn })
QuickBar:Unpin(idOrLabel) QuickBar:GetPins() QuickBar:IsPinned(idOrLabel)
```
Dock visible while the window is hidden; toggle pins flip the real elements.

### NotificationHistory
```lua
NotifHistory:Bind(EZ, Window, { MaxEntries = 50, ShowTimestamp = true })
NotifHistory:GetEntries() / GetUnreadCount() / MarkAllRead() / Clear()
```
Bell in the header + slide-out history panel.

---

## 8. Icons

`EZ:SetIcons(IconsPack)` enables lucide names everywhere an icon is accepted
(tabs, groupboxes, dock tiles, chevrons). `EZ:ResolveIcon(ref)` also accepts
`rbxassetid://`, plain numeric ids, or urls — including `rbxasset://` strings
from `getcustomasset`, so an `EZ.ImageManager.AddAsset` result can be passed
straight to any `Icon` field.

`EZ:IsRawIcon(ref)` tells the two apart: `true` for author-supplied art (urls,
ids), `false` for a name from the pack. The library uses it to decide whether
an icon may be recoloured — pack icons are monochrome and get tinted per state,
supplied art keeps its own colours (and is faded with `ImageTransparency`
instead). The same rule decides the header icon tint; override it per window
with `CreateWindow({ IconTint = ... })`.
