# Changelog

## 4.2.0

### Added
- **Loading screen** — `EZ:CreateLoading({Title, Icon, TotalSteps, Message, Description, IconTweenTime})`:
  modal overlay (own ScreenGui, above everything) with a rotating icon,
  title, message + description, progress bar with `n/total` counter, and an
  optional sidebar. Methods: `SetMessage`, `SetDescription`,
  `SetCurrentStep`, `SetTotalSteps`, `SetLoadingIcon` (lucide/asset),
  `SetLoadingIconTweenTime` (0 stops rotation), `SetLoadingIconColor`,
  `ShowSidebarPage(bool)`, `ShowErrorPage(bool)`, `SetErrorMessage`,
  `SetErrorButtons` (dialog-style `{Title, Variant, Callback}` array or map),
  `Destroy` / `Continue` (alias; restores the main window if one exists).
  **`Loading.Sidebar` supports every element builder** (it borrows an
  invisible host window's section internally). Creating a new loader replaces
  the previous one; `EZ:Destroy()` cleans it.
- **Keybind menu tap-toggles** — toggle-mode rows get a clickable checkbox
  (mobile parity); `EZ.ShowToggleFrameInKeybinds = false` hides it.
- **Groupbox/section pop-out** — `:SetPoppedOut(bool, floatPos?)`,
  `:TogglePoppedOut()`, `:IsPoppedOut()`, `:SetMaxPopOutHeight(h)`,
  `:SetPopOutWidth(w)`: the section floats in a draggable panel (grip in the
  header), clamped to the screen. Simplified vs Obsidian: the whole section
  floats (no separate scrolling body).

## 4.1.0

### Added
- **`Section:AddViewport(id, {Object, Camera, Interactive, AutoFocus, Height})`** —
  ViewportFrame + WorldModel 3D preview. The object is **cloned** into the
  world (the caller's instance stays theirs); camera auto-fits via
  `GetBoundingBox`; drag to orbit + wheel/pinch to zoom (touch included);
  handle: `SetObject`, `GetObject`, `SetCamera`, `SetInteractive`,
  `SetHeight`, `Focus`, `SetVisible`/`SetDisabled`/`Destroy`.
- **`Section:AddUIPassthrough(id, {Instance, Height})`** — embeds any GuiBase2d
  in the layout; `SetInstance` swaps, `SetHeight` resizes, `Destroy` hands the
  instance back to its original parent with its original size/position.
- **Public utilities** (Obsidian-parity):
  - `EZ:GetIcon(name)` / `EZ:ApplyLucideIcon(imageGui, ref, rotation?)`
  - `EZ:GiveSignal(conn)` — register an existing connection for
    disconnect-on-`EZ:Destroy`
  - `EZ:SafeCallback(fn, ...)` — error-captured invocation
  - `EZ:GetTextBounds(text, font, size, maxWidth?)` → width, height
  - `EZ:GetBetterColor(c, amount)` / `EZ:GetLighterColor` / `EZ:GetDarkerColor`
  - **`EZ.ImageManager`** — `AddAsset(name, assetId, url?, forceRedownload?)`,
    `GetAsset(name)`, `DownloadAsset(name, force?)`: downloads once via
    `getcustomasset` into `EZImageCache/`, caches per session, falls back to
    the Roblox asset id when the executor lacks filesystem/custom assets.

## 4.0.0

### Added
- **Notifications v2** — `EZ:Notify` now returns a notification **handle**
  (a forwarding table: property reads/writes still work on the card, method
  calls go through `handle.Frame:X()`):
  - **Persistent notifications** — `Duration = false` (or `math.huge`) keeps
    the card until `:Dismiss()`/`:Destroy()` or an action button dismisses it.
  - **Live updates** — `:ChangeTitle(t)`, `:ChangeDescription(t)` (card
    re-measures its height automatically).
  - **Step/progress notifications** — `TotalSteps = n` renders a progress bar;
    `:ChangeStep(n)` tweens the fill + updates the `n/total` label.
  - **Sounds** — `SoundId` (+ `Volume`, default 3) plays when the card shows.
- **Two-layer custom cursor** — the cursor is now a real overlay
  (crosshair layer + optional icon layer) instead of `Mouse.Icon`:
  `EZ.Cursor:ChangeCrossColor/ResetCross/ChangeIcon/ChangeIconColor/
  ChangeIconSize/ResetIcon/ResetCursor`; `ChangeIcon` takes a Lucide name,
  asset id or URL; the icon layer replaces the crosshair while active.
  `EZ:SetCursorIcon/SetCursorEnabled` map onto the new system. Survives
  respawn (`ResetOnSpawn = false`), and `EZ:Destroy()` cleans the overlay.

### Changed
- `EZ:Notify` returns the forwarding handle instead of the raw card frame —
  property-style usage keeps working; method calls on the card itself
  (e.g. `:GetDescendants`) go through `handle.Frame`.

## 3.9.0

**Uniform element handles + Obsidian-parity element upgrades.**

### Added
- **Every element handle now has**: `.Frame`, `:SetVisible(v)` (composes with
  `VisibleWhen` + header search), `:SetDisabled(d)` / `:IsDisabled()` (dims +
  blocks interaction), `:Destroy()` (removes from the UI **and** the config
  registry). Addon-parity with Obsidian's per-element API.
- **`SetText(t)`** on Toggle/Slider/Dropdown/Input/Keybind/ColorPicker/
  ProgressBar/Label (`Set` alias kept).
- **Checkbox visual variant**: `Section:AddCheckbox(id, opts)` (square + check
  mark) or globally `EZ.ForceCheckbox = true`.
- **Dividers**: centered text + `MarginTop`/`MarginBottom` —
  `AddDivider("Grouped")` or `AddDivider({ Text = ..., MarginTop = 8 })`.
- **Labels**: `DoesWrap = true` (multiline), `Size = 14` (text size), `SetSize`.
- **Slider**: `SetMin`/`SetMax` (live range, re-clamps), `SetPrefix` (`Prefix`
  option too).
- **Dropdown**: `AddValues`, `SetValues` (alias), `SetDisabledValues`/
  `AddDisabledValues`, `SetValueImages`/`AddValueImages` (icons per option),
  `SetText`, `SetDragSelect` (sweep multi-select), `VisibleItems`/`Height`
  list sizing, `AllowEmptySelection`, `GetActiveValues(countOnly?)`,
  Default-as-index (`Default = 2`).
- **TabBox**: `AddTab(name, icon?)` after creation with auto re-layout + icons.
- **Groupbox/Section**: `SetDescription(desc)` (create/update/clear after
  creation), `SetVisible`/`Show`/`Hide`.

### Changed
- Element `Destroy` unregisters the id: SaveManager, panic and the keybind
  menu stop tracking destroyed elements; `EZ.Flags[id]` is cleared.
- Known limitation: builder connections are window-tracked, so a destroyed
  element's input connections release at window teardown (documented).

## 3.8.0

### Added
- **Anti-AFK** — Settings ▸ Menu ▸ "Anti-AFK" toggle (also `EZ:SetAntiAFK(bool)`
  / `EZ:IsAntiAFK()` / `EZ._antiAFKCount`). When the game fires `Idled`
  (just before the ~20-minute idle kick), the library answers with a virtual
  controller press (`VirtualUser:CaptureController` + `ClickButton2`) — plain
  Roblox APIs, so it works on any executor. If a game blocks VirtualUser, the
  fallback mutes the game's `Idled` connections directly (sUNC
  `getconnections`) and **re-enables every muted connection when you turn
  Anti-AFK off**. The first prevented kick notifies; `EZ._antiAFKCount` tracks
  the rest. Persists through config save/load + autoload like any toggle.

## 3.7.0

**SaveManager is namespaced per game.** The executor workspace is shared by
every game and script, so 3.6 and earlier let a config (or the autoload
pointer) saved in one game silently apply in the next one.

### Added
- **Per-game config isolation** — configs, `profiles/`, `_autoload.txt` and
  `_active_profile.txt` now live under `Folder/<experience id>/` (GameId,
  PlaceId fallback in Studio). Opt out with `SaveManager:SetPerGame(false)`;
  override the key with `SaveManager:SetGameKey(key)` (e.g. a PlaceId to
  isolate sub-places of one experience).
- **Legacy migration** — on `Bind`, 3.6-era files (root `*.json` configs,
  `profiles/`, `_autoload.txt`, `_active_profile.txt`) are moved into the
  per-game namespace automatically: copy-then-delete, fully pcall-guarded,
  nothing deleted unless the copy succeeded.
- **Config metadata** — format-2 configs now carry `game` + `script`; loading
  a config saved for another game (via import/JSON) warns instead of silently
  half-applying.
- `SubFolder` now nests **under** the game key (`Folder/<game>/<sub>/`), so
  place-level splits stay per-game too.

### Changed
- Default disk layout is `Folder/<game id>/*.json`, `Folder/<game id>/profiles/`,
  `Folder/<game id>/_autoload.txt`, `Folder/<game id>/_active_profile.txt`.
  Same `Bind` signature as before — existing scripts keep working.

## 3.6.0

Correctness sweep (live-verified against an executor client), a batch of
quality-of-life features, and the first in-repo test/CI infrastructure.

### Added
- **Slider text entry** — click a slider's value label to type an exact value;
  commits through the same clamp/snap/callback path as dragging. Enter or
  clicking away commits; unparseable input restores the label.
- **Toggle descriptions** — `AddToggle(id, { Description = "..." })` renders a
  muted second line under the label.
- **Section/groupbox descriptions** — `AddSection(name, description?)`,
  `AddLeftGroupbox(name, icon?, description?)` etc.
- **Dropdown multi polish** — long selections collapse to `"A, B +N more"` in
  the header; open lists get a **Select all / Clear** row (disabled values
  excluded).
- **Notification actions** — `EZ:Notify({ Buttons = { {Text, Callback} } })`
  renders action buttons on the card (taking an action dismisses it); types
  now show a Lucide icon when the icon pack resolves one, with the colored dot
  as fallback.
- **RichText** — `AddLabel({ RichText = true })` / `AddParagraph({ RichText = true })`.
- **ColorPicker palette + recents** — `opts.Palette = {Color3...}` swatch row
  in the popup plus the last 6 deliberate picks (session-only).
- **Keybind menu grouping** — rows group under their owning window's name when
  two or more windows have keybinds.
- **Window options** — `GeometryId` (stable persistence key, immune to title
  punctuation changes) and `CloseBehavior = "window"` (X closes just that
  window; default keeps the full-`EZ:Destroy()` nuke).
- `LICENSE` (MIT), `tests/` live harness + showcase, luau-analyze CI.

### Fixed
- **Multi dropdown `:Set` crash** — passing a scalar (or array) crashed the
  header refresh with "attempt to iterate over a string value"; `Set` now
  normalizes map/array/scalar, and a map-form `Default` stores correctly
  (it used to write a `true` key).
- **Dropdown `Refresh` silently dropped `Disabled`** — previously requested
  disabled entries survive a refresh unless `Refresh(newValues, disabled)`
  replaces them.
- **Slider leaked a global `value`** across every slider in the environment.
- **Dock position fought across windows/scripts** — the minimize dock now
  saves per-window (`EZDockPos_<key>.txt`), falling back to the old shared
  `EZDockPos.txt` for migration. Geometry files follow the same `GeometryId`.
- **Dropdown bulk row duplicated** — the Select all/Clear row is a Frame, but
  `refreshItems` only cleared TextButton children, so every refresh (item tap,
  search keystroke) stacked another bulk row. Both are cleared now.
- **Open dropdown lists leaked on window teardown** — the floating list lives
  in the root ScreenGui but was never registered as a popup, so a window
  destroyed (or hidden) with a dropdown open left the list stranded on screen,
  still showing its bulk row. Dropdown lists now register via the same popup
  registry pickers/dialogs use.

### Docs
- Documented `KeySystem`'s `GetKeyText` option and its blocking behavior,
  `CheckForUpdate`'s return shape, the multi-dropdown `Set` map rule, the
  `AddButton` TextButton return, and the ProgressBar's lack of a Callback
  option. `CONTRIBUTING.md` documents the element touch-point checklist.

## 3.5.1

Maintenance release: input-lifecycle, geometry and persistence fixes from a
full patch audit, verified live on an executor, plus two quality-of-life
behaviour changes.

### Added
- **Keybind menu corner anchor** — Settings ▸ Menu ▾ "Keybind Menu Position"
  (Top Left / Top Right / Bottom Left / Bottom Right; default **Top Right**).
  Fresh installs open at the chosen corner; a dragged position still wins
  until a different anchor is picked, which also moves the live menu.
  API: `EZ:SetKeybindMenuAnchor(name)` / `EZ:GetKeybindMenuAnchor()`.
- The minimize dock stays wherever the user parked it — only a first-ever
  minimize (no saved dock position) centers the pill at the window.

### Fixed
- Re-executing the library no longer stacks zombie input contexts: every load
  consumes a `getgenv` teardown token that `EZ:Destroy()`s the previous copy
  before building a new one.
- `loader.lua`-style unloads now destroy the QuickBar dock and notification
  bell through `EZ:OnDestroy` (previously they stranded on screen).
- Restored window geometry is clamped to the current viewport — both on
  initial load and on minimize-restore — so positions saved on larger
  screens or resolutions can never strand the window off-screen.
- Resize grip minimum no longer exceeds the created window on small/mobile
  viewports (`min(460, winW) × min(360, winH)`).
- Multi-select dropdowns keep their scroll position across item taps.
- Slider `Default = 0/0` (NaN) clamps to Min instead of Max.
- Color-picker canvas/hue/transparency drags respect the `_activeDrag`
  mutex, so the slider underneath no longer fights an active picker drag.
- Dock tiles: grabbing a tile drags the dock again (press no longer cancels
  the dock drag); taps need ≤6px movement and an on-tile release (+8px
  tolerance), so sliding off a tile no longer fires its action.
- `_cornerRegistry` prunes instances of destroyed windows every 200 inserts;
  `_panicTiles` drops dead windows' tiles on registration; `fireListeners`
  only clones listener arrays larger than four entries.
- The floating keybind menu is destroyed by `EZ:Destroy()`, and a queued
  row refresh on a destroyed menu frame exits early.
- ThemeManager: the "Rose" built-in is renamed to **Rosé** (bracket-quoted
  key — bare unicode identifiers do not parse) so `AddTheme("Rose")` and the
  library's Rose Pine preset can no longer overwrite it; `AddCustomTheme`
  rejects names colliding with non-custom built-ins; `ImportTheme` applies
  the import immediately via `SetTheme` instead of only recording the name.
- SaveManager persists TabBox elements (active tab name round-trips through
  save/load).
- Watermark `{flag:x}` values render verbatim — gsub applies `%` templates
  to string replacements only, so function replacements must not escape
  (values like `50%` display exactly).

### Docs
- Corrected the preset count (12), SaveManager restore/autoload disk-layout
  prose, notification-history entry design, and the element flag-support
  matrix; documented the window X button performing a full `EZ:Destroy()`.

## 3.5.0

Biggest release yet: Obsidian-style layout system, mouse-button keybinds, a
universal panic switch, and a long list of bug fixes found through a full
behavioural audit.

### Added
- **Groupboxes** — `Tab:AddLeftGroupbox(name, icon?)` / `AddRightGroupbox` /
  `AddGroupbox(side, name, icon)`: symmetric two-column layouts that line up,
  work with every element builder, and participate in header search.
- **TabBox element** — `Section:AddTabBox(id, {Tabs = {...}})`: segmented
  "Tab 1 | Tab 2" control; each tab is a full section handle.
- **Dropdown upgrades** — `Searchable = true` (search box in the open list),
  dictionary values (`{key = "Display"}` — key stored, display rendered), and
  `Disabled` values (dimmed, unclickable). `Refresh` accepts either shape.
- **Panic system** — `EZ:SetPanic / TogglePanic / IsPanic` + `_EZPanic` flag:
  snapshots every toggle, switches them all off, deactivates active keybinds;
  un-panic restores. Reachable from the minimize dock and Settings.
- **Minimize dock** — the old plain pill is now a 3-tile draggable dock
  (Open / Panic / Keybinds) with persisted position; QuickBar still replaces
  it when pins exist.
- **Window resize** — drag the bottom-right grip (460×360 minimum); window
  position + size persist across sessions (`PersistGeometry` opt-out).
- **Live appearance controls** — `EZ:SetCornerRadius(0-20)`,
  `EZ:SetFont` (FontFace families: BuilderSans, Jura, Montserrat, ...),
  `EZ:SetNotificationSide`, `EZ:SetCursorIcon/SetCursorEnabled`.
- **Keybinds** — mouse buttons M1–M3 can be bound and triggered; compact
  `M1/M2/M3` chip labels; `keybind:SetActive(bool)`;
  `Window:SetToggleKey` accepts mouse buttons too.
- **Color picker** — RGB input beside hex, Copy/Paste color buttons, closes on
  outside click and on page scroll.
- Rebindable menu hotkey (`Settings ▸ Menu bind`) — old hotkey retires, new
  key or mouse button takes over, no double-fire.
- Custom theme CRUD in ThemeManager (create/overwrite/delete/import/export,
  persisted per-brand) + "Reset default".

### Fixed
- Auto Settings tab no longer spawns as tab #1: it builds deferred, pins to
  the bottom of the sidebar, and never steals initial focus.
- Keybind menu: rows no longer render on top of the header (container was
  missing its Y offset); menu is a true singleton (the create-guard checked a
  table field that was always nil, spawning stacked ghost menus); labels are
  Lua-capped instead of relying on executor `TextTruncate`.
- Hold keybinds no longer latch ON when the modifier is released before the key.
- Hiding the window mid-show-animation no longer shrinks it ~10% per cycle.
- DPI Scale dropdown crash (`tonumber` base out of range via gsub multi-return).
- Color picker no longer hangs detached when the page scrolls.
- Element labels truncate instead of overlapping controls in narrow groupboxes.
- SaveManager: active-profile restore no longer hits a nil global; empty
  config-name/JSON inputs are rejected properly; button labels match the UI.
- QuickBar: dock no longer pops over a re-shown window; its corners follow
  the live corner-radius setting (NotificationHistory too).
- Visibility listeners idle instead of writing into destroyed frames;
  `EZ:Destroy` marks all windows destroyed to stop teardown races.
- Watermark FPS loop sleeps while hidden (and reports honest FPS on return).

### Changed
- Settings tab layout: Menu + Themes groupboxes (left) and Configuration
  (right) — Profiles are now opt-in (`AddSettingsTab({Profiles = true})`).
- Selected tab highlight is a clearly filled background.
- Notifications redesigned: type dot + neutral border (no accent bar), same
  for notification-history cards.
- Dropdown chevrons and section collapse arrows use proper icons when an
  icon pack is bound.
- Default window size 620×440; addon HTTP fetch no longer blocks
  `CreateWindow`.

## 3.4.0

Initial public release baseline (see git history).
