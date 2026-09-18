# Contributing to EZ UI Library

## Running the tests

Every change should pass both gates before it lands:

1. **Static analysis** — `luau-lsp analyze` (see `.github/workflows/luau-analyze.yml`).
   The CI fails on syntax errors and **Unknown globals** (variables written
   without `local` — this class of bug shipped in 3.5.x: the slider wrote a
   global `value` shared by every slider in the environment).
2. **Live harness** — run `tests/live/api-test.luau` in an executor client
   (see `tests/README.md`). All checks must print PASS; the harness writes
   `EZTestResults.txt` even on crash.

## Adding a new element (the 6 touch-points)

All element builders live inside the `createSection` closure in `Library.lua`.
A new builder is only done when ALL of these exist — forgetting any of them
fails silently:

1. **Builder** inside `createSection`, before the `owned()` wrap loop at the
   bottom (which re-arms `EZ._connectionOwner` per method — every new
   `section:AddX` must be wrapped there, or `window:Destroy()` leaks global
   input handlers).
2. **Registry** — `registerElement(id, handle)` + a new `_type` string on the
   handle (this opts it into config save/load, the panic snapshot and the
   keybind menu).
3. **SaveManager** (`addons/SaveManager.lua`) must learn the `_type` in its
   format-2 serializer — it lives in a *different file* and the core gives no
   hint when you forget.
4. **Panic + keybind menu** dispatch on `_type` (`EZ:SetPanic`, menu
   `_refresh`) — decide whether the new type participates.
5. **Search** — `tagSearch(elem, text)` or the header search ignores it.
6. **Theme** — colors from `EZ.Theme.<role>` only. `EZ:SetTheme` recolors by
   *value matching*; any hardcoded color is silently never recolored.

Also required inside the builder: build frames via `create()` (it applies the
live font override), `setupVisibility`, `setupTooltip`,
`table.insert(section.Elements, handle)`.

## Declare-before-use discipline

Luau resolves a name to the *global* environment when no `local` of that name
is in scope yet — a closure created before `local x = ...` will read the
global, not the later local. Declare shared state (like `sliding`,
`dismissCard`) **before** the closures that reference it. CI catches
violations.

## Versioning / release

1. Bump `EZ._version` in `Library.lua` and the badge in `README.md`.
2. Add a `CHANGELOG.md` entry.
3. Tag the release (`v3.6.0`, semver) — `EZ:CheckForUpdate()` compares these
   tags. Rebranding point: `REPO_SLUG` / `REPO_RAW` at the top of `Library.lua`.

## Testing local edits live

See `tests/README.md` — build a local copy with
`sed 's/^return EZ$/getgenv().EZ_LOCAL = EZ\nreturn EZ/' Library.lua > build.luau`,
execute it in the client, and probe `getgenv().EZ_LOCAL`.
