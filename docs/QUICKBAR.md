# QuickBar — Floating Pin Dock

An iOS-Control-Center-style dock that appears **while the window is hidden**: one tile to reopen the window plus pinned toggles (glow when ON) and buttons.

```lua
local QuickBar = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/addons/QuickBar.lua"))()
QuickBar:Bind(EZ, Window, { MaxPins = 5 })
```

---

## API

| Method | Description |
|---|---|
| `Bind(library, window, opts?)` | Build the dock. Opts: `MaxPins` (`5`), `File` (`"EZQuickBar.json"`), `Position` (center default). Safe to call twice — the previous dock is torn down first |
| `Pin(id, opts?)` | Pin a **toggle** by flag id. Requires the toggle to already exist. `opts.Icon` = lucide name / asset ref |
| `PinButton(label, callbackOrOpts)` | Pin a button — pass a bare function or `{ Callback, Icon }`. Session-only by design (callbacks can't be serialised) |
| `Unpin(idOrLabel)` | Remove a pin |
| `GetPins()` | Current pin ids/labels |
| `IsPinned(idOrLabel)` | bool |
| `Destroy()` | Removes tiles, listeners, ScreenGui and hands `Window:Show/Hide` back untouched |

Toggle pins **persist** to disk (id + icon) with dedupe; stale ids whose flags no longer exist are pruned once the UI exists.

---

## Behaviour notes

- The dock replaces the restore pill while pins exist; with zero pins it hides and the pill comes back
- Tap vs drag: moving >6px cancels the click, so dragging never misfires tiles; the dock stays ≥28px reachable on every screen edge
- Toggle tiles flip via the element handle (callbacks + config state stay consistent) with a haptic bounce
- Fully theme-aware — follows live theme switches
- Re-executing the library cleans up an orphaned dock automatically (`EZQuickBar` gui)
