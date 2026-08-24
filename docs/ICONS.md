# Icons — Embedded Lucide Pack

~1700 Lucide icons compiled to Roblox asset ids, with exact, fuzzy and scored search. Zero HTTP at runtime — everything is embedded.

```lua
local Icons = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/addons/Icons.lua"))()
EZ:SetIcons(Icons)
```

Once bound via `EZ:SetIcons`, **every** icon slot in the library (tabs, toggle pill, QuickBar tiles, key system link) accepts Lucide names directly.

---

## API

```lua
Icons("sword")            -- shorthand -> asset id string or nil
Icons:Get("heart")        -- exact match
Icons:Fuzzy("swrd")       -- best-match id even with typos (or nil)
Icons:Search("arrow", 10) -- up to 10 results: { {name, score, id}, ... }
Icons:All()               -- sorted flat list of every name (for dropdowns)
Icons:Raw()               -- the raw name->id table
```

### Name normalisation

Lookups are forgiving: `"Sword Icon"`, `"sword_icon"` and `"sword icon"` all resolve to `sword-icon` (lowercased, `_`/spaces → `-`, stray symbols stripped).

### Fuzzy scoring

Exact name > contains-substring (earlier = better) > in-order subsequence with proximity weighting. Non-matches return `nil` / score `< 0`.

---

## Where icons are accepted

Anywhere the library resolves an icon — `Window:AddTab(name, "shield")`, `CreateWindow({ ToggleIcon = "sparkles" })`, `QuickBar:Pin(id, { Icon = "activity" })` — plus raw refs (`"rbxassetid://123"`, numbers, `rbxthumb://`) always work without the pack.
