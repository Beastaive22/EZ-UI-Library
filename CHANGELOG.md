# Changelog

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
