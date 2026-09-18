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
EZ:SetCursorIcon(asset)   -- custom cursor image ("rbxassetid://...")
EZ:SetCursorEnabled(bool) -- apply/clear it (re-applies on respawn)
EZ:SetTheme(partialTable) -- merge e.g. { Accent = Color3... }; full UI recolour
EZ:GetTheme()             -- live theme table
EZ.Themes                 -- 8 built-in presets (Midnight, Catppuccin, ...)
```

---

## 3. Tabs, Groupboxes, Sections

```lua
local Tab = Window:AddTab("Main", "sword")  -- icon: lucide name / asset ref

Tab:AddSection(name) -> Section              -- full-width
Tab:AddLeftGroupbox(name, icon?)  -> Section -- two-column layout, boxes align
Tab:AddRightGroupbox(name, icon?) -> Section
Tab:AddGroupbox("left" | "right", name, icon?) -> Section
Tab:AddSubTab(name) -> SubTab                -- pill row; SubTab:AddSection nests inside
Tab._activate()                              -- programmatic switch
```

- Groupboxes are full sections — every builder below works inside them, including
  `SaveManager:BuildConfigSection(groupbox, Window)`.
- Full-width sections render above the groupbox columns.
- Selected tab = filled highlight + accent indicator. Tabs auto-badge visible ON toggles.
- Header search filters sections, groupboxes and sub-tabs.

---

## 4. Elements

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

### AddSlider(id, {Text, Min, Max, Default, Increment, Suffix, Callback}) -> handle
Clamped + snapped; decimal steps render cleanly. `Set(n)` / `Get()`.
**Click the value label to type an exact value** — commits through the same
clamp/snap/callback path as dragging; unparseable input restores the label.

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

### AddLabel(textOrOpts) / AddDivider() / AddParagraph({Title, Content})
Labels/paragraphs accept `{Text/Title/Content, Tooltip, VisibleWhen, RichText}`;
handles expose `:Set(text)`. `RichText = true` opts the label into Roblox
RichText markup (`<b>`, `<font color="#...">`, ...) — opt-in only, never set it
for user-typed content.

### AddProgressBar(id, {Text, Default, Max, Color, ShowText}) -> handle
`Set(v)` / `Get()` / `SetMax(m)` / `SetColor(Color3)`.

### AddLog({Height, MaxLines, Text}) -> handle
`Info/Warn/Error/Success/Print(text, color)/Clear()`.

### AddPlayerSelector(id, {Text, ExcludeSelf, Multi, Callback}) -> dropdown handle
Preloaded with `@me` / `@random` / `@nearest` + players; auto-refreshes on
join/leave. `dd:GetPlayers()` resolves the selection to Player instances.

---

## 5. Notifications

```lua
EZ:Notify({
    Title = "Hi", Content = "...", Duration = 4,
    Type = "info|success|warning|error",
    Buttons = { { Text = "Open", Callback = function() end } }, -- action row; taking an action dismisses the card
})
EZ.MaxNotifications = 5   -- max cards on screen
```

Cards show a type-colored Lucide icon (when the icon pack resolves one —
`info/circle-check/triangle-alert/octagon-x` with fallbacks) or a colored dot;
auto-dismiss.

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
SaveManager:BuildConfigSection(sectionOrGroupbox, Window)
SaveManager:Save("name") / Load / Delete / GetConfigs()
SaveManager:SaveAutoloadConfig("name") / LoadAutoloadConfig() / DeleteAutoLoadConfig()
SaveManager:Export() / Import(str) / SaveJSON(name) / LoadJSON(json)
SaveManager:BuildProfileUI(section, Window)   -- profiles (not auto-attached)
```
Configs persist every registered element type; JSON import/export included.

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
`rbxassetid://`, plain numeric ids, or urls.
