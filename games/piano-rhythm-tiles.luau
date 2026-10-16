-- Game guard: this module only runs in its own game (universe 10766845655).
-- Anywhere else (autoexec, a shared hub, a wrong map) it exits before touching
-- anything.
if game.GameId ~= 10766845655 then return end

--[[
    Piano Rhythm Tiles — Perfect Autoplay
    Built on EZ-UI-Library (https://github.com/Beastaive22/EZ-UI-Library)
    Executor: Potassium / sUNC

    How the game actually scores (from the client's own Engine module,
    PlayerScripts.Client.Engine — judging is 100% client-side, the server only
    receives the end-of-run aggregates):

      * Every tile spawns at chart time t and travels for ApproachTime
        (1.5s at 1x scroll). A tap is judged by how far the tile has FALLEN
        when you press its lane:
            PERFECT  >= 50% of the fall   (anything up to the deadline)
            COOL     >= 25%
            GOOD     anything earlier
        The deadline is t + ApproachTime + tap-length grace, and a tile that
        crosses it un-pressed is a MISS (a miss or a wrong tap fails a
        classic-mode run).
      * Hold tiles judge the HEAD on press like any tile, then the lane must
        stay held for >= 82% (Config.HoldKeepFrac) of the hold duration or the
        hit is downgraded to MISS. Releasing late is always safe, and holding
        past the end auto-settles with full credit.

    So "perfect every tile" = press each lane exactly once, when its tile is
    ~72% down its fall (dead centre of the PERFECT window — the same fraction
    the game's own built-in dev autoplay uses), and release holds just after
    their full duration. This script drives the game's own Engine.press /
    Engine.release — the exact entry point real keyboard input uses — so every
    judgement, sound, combo and score goes through normal game code. Nothing
    is spoofed; endRun reports what really happened.

    Extras over the built-in autoplay:
      * hold releases are tracked per tile — a release never lands on a newer
        tile that took over the lane (early release = MISS otherwise)
      * tiles whose window already closed (lag spike) are skipped instead of
        pressed, so recovery never fires a blind tap
      * start gates (phase "gated") are cleared by pressing their tiles, same
        as the dev harness
      * engages itself on every new run; a mid-run "Engage now" button aligns
        the cursor for taking over an idle/AFK run

    Don't tap keys while it's driving — manual presses can steal a tile the
    cursor is about to hit and desync it.

    Toggle UI: RightShift
]]

local game = game
local getgenv = getgenv

print("[PIANO-AUTOPLAY] starting")
if getgenv().__PIANO_AUTO_LOADED then
    pcall(function() getgenv().__PIANO_AUTO_DESTROY() end)
end

----------------------------------------------------------------
-- Library (canonical EZ-UI-Library setup)
----------------------------------------------------------------
local repo = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"
local EZ = loadstring(game:HttpGet(repo .. "Library.lua"))()
local Icons = loadstring(game:HttpGet(repo .. "addons/Icons.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local QuickBar = loadstring(game:HttpGet(repo .. "addons/QuickBar.lua"))()
local NotifHistory = loadstring(game:HttpGet(repo .. "addons/NotificationHistory.lua"))()

EZ:SetIcons(Icons)
SaveManager:Bind(EZ, "PianoTilesAutoplayConfigs")
ThemeManager:Bind(EZ, { File = "PianoAutoplay_Theme.txt" })
ThemeManager:LoadSaved() -- apply saved theme before the window builds: no colour flash
for name, tbl in EZ.Themes do ThemeManager:AddTheme(name, tbl) end

----------------------------------------------------------------
-- Runtime handles — the game's own client engine
----------------------------------------------------------------
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local lp = Players.LocalPlayer
local Client = lp:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Engine = require(Client:WaitForChild("Engine"))

local RUNNING = true
local log -- assigned once the Run log section builds its console

----------------------------------------------------------------
-- Bot state
----------------------------------------------------------------
local BOT = {
    running = false, -- master flag (UI)
    engaged = false, -- cursor is valid for the current run
    cursor = 1,      -- next tile index to press
    runId = nil,
    holds = {},      -- [tileIndex] = { lane, tile, at (chart time) }
    laneHold = {},   -- [lane] = tileIndex we believe is holding that lane
    gateTimer = nil,
    pressed = 0,
}

local function flagNum(id, fallback, lo, hi)
    local v = tonumber(EZ.Flags[id])
    if not v then return fallback end
    return math.clamp(v, lo, hi)
end

-- Press one chart tile through the game's own entry point.
local function doPress(tile, wall)
    Engine.press(tile.lane, wall or os.clock())
    if tile.hold then
        BOT.laneHold[tile.lane] = tile.i
        -- release just after the full hold duration (frac ends >= 1, well over
        -- HoldKeepFrac 0.82); read songTime AFTER the press so the deadline
        -- derives from the actual judged chart time
        BOT.holds[tile.i] = {
            lane = tile.lane,
            tile = tile.i,
            at = Engine.songTime() + tile.hold + flagNum("HoldPad", 0.05, 0, 0.2),
        }
    end
    BOT.pressed += 1
end

local function resetCursor()
    BOT.cursor = 1
    table.clear(BOT.holds)
    table.clear(BOT.laneHold)
    BOT.gateTimer = nil
    BOT.pressed = 0
end

local function step()
    local chart = Engine.chart()
    if not chart then
        BOT.engaged = false
        return
    end

    local rid = Engine.runId() or 0
    if rid ~= BOT.runId then
        BOT.runId = rid
        resetCursor()
        -- a fresh run: the cursor starts at tile 1, alignment is exact
        BOT.engaged = BOT.running
        if BOT.engaged then
            EZ:Notify({
                Title = "Autoplay engaged",
                Content = ("%s — %d tiles"):format(tostring(Engine.currentSongId() or "?"), chart.noteCount or #chart.tiles),
                Type = "success",
                Duration = 4,
            })
        end
    end

    if not (BOT.running and BOT.engaged) then return end

    local phase = Engine.phase()
    local tiles = chart.tiles
    local st = Engine.songTime()

    if phase == "gated" then
        local gate = Engine.gate()
        if not gate then return end
        BOT.gateTimer = BOT.gateTimer or os.clock()
        if os.clock() - BOT.gateTimer < flagNum("GateWait", 0.8, 0, 2) then return end
        BOT.gateTimer = nil
        -- press every tile the gate has already reached; gate lanes clear the
        -- gate, the rest are judged at the frozen gate time (still PERFECT)
        while BOT.cursor <= #tiles and tiles[BOT.cursor].t <= gate.t + 1e-6 do
            local t = tiles[BOT.cursor]
            BOT.cursor += 1
            doPress(t)
        end
        return
    else
        BOT.gateTimer = nil
    end

    if phase ~= "playing" then return end

    local fall = flagNum("FallFrac", 0.72, 0.5, 0.95)
    local now = os.clock()
    while BOT.cursor <= #tiles do
        local t = tiles[BOT.cursor]
        if st < Engine.fallAt(t, fall) then break end
        BOT.cursor += 1
        -- skip tiles whose whole window closed (lag spike): pressing them
        -- would be a blind tap; the engine already marked them missed
        if st <= Engine.fallAt(t, 1) then
            doPress(t, now)
        end
    end

    -- hold releases: only when our tile is still the one holding the lane
    for i, h in pairs(BOT.holds) do
        if st >= h.at then
            BOT.holds[i] = nil
            if BOT.laneHold[h.lane] == h.tile then
                BOT.laneHold[h.lane] = nil
                Engine.release(h.lane, os.clock())
            end
        end
    end
end

local lastErr, lastErrAt = nil, 0
local hb = RunService.Heartbeat:Connect(function()
    local ok, err = pcall(step)
    if not ok then
        if err ~= lastErr or os.clock() - lastErrAt > 5 then
            lastErr, lastErrAt = err, os.clock()
            if log then log:Error("step: " .. tostring(err)) end
            warn("[PIANO-AUTOPLAY] step error: " .. tostring(err))
        end
    end
end)

-- Run summaries straight from the engine's finish signal
local finishConn = Engine.onFinish.connect(function(res)
    if log then
        log:Success(("finished %s | score %d | acc %.1f%% | perfects %d/%d | maxCombo %d | misses %d | wrong %d | completed %s")
            :format(
                tostring(res.songId), res.score or 0, (res.accuracy or 0) * 100,
                res.perfects or 0, res.total or 0, res.maxCombo or 0,
                res.misses or 0, res.wrongTaps or 0, tostring(res.completed)))
    end
end)

----------------------------------------------------------------
-- Window
----------------------------------------------------------------
local Window = EZ:CreateWindow({
    Title = "Piano Autoplay",
    SubTitle = "Piano Rhythm Tiles",
    ToggleKey = Enum.KeyCode.RightShift,
    ToggleIcon = "music",
    GeometryId = "piano-autoplay",
})
QuickBar:Bind(EZ, Window)
NotifHistory:Bind(EZ, Window)

local Tab = Window:AddTab("Autoplay", "music")

local controls = Tab:AddLeftGroupbox("Bot", "play", "Drives the game's own Engine input path")
local autoToggle = controls:AddToggle("AutoPlay", {
    Text = "Autoplay",
    Description = "Perfects every tile, holds hold-tiles for their full length",
    Default = false,
    Tooltip = "Engages automatically when a song starts. Leave it on and just press play.",
    Callback = function(v)
        BOT.running = v
        if v and not BOT.engaged then
            if log then log:Info("armed — engages when the next song starts") end
        elseif not v and BOT.engaged then
            BOT.engaged = false
            if log then log:Warn("disengaged mid-run") end
        end
    end,
})
controls:AddKeybind("BotKey", {
    Mode = "Toggle",
    Default = Enum.KeyCode.P,
    Text = "Toggle autoplay",
    Tooltip = "Hotkey for the autoplay toggle",
    Callback = function(active)
        autoToggle:Set(active)
    end,
})
controls:AddSlider("FallFrac", {
    Text = "Press point",
    Min = 0.5, Max = 0.95, Increment = 0.01, Default = 0.72,
    Suffix = " of fall",
    Tooltip = "How far down its fall a tile is when the bot taps. 0.72 = centre of the PERFECT window (game's own value). Below 0.5 stops being PERFECT; above 0.9 gets close to the miss deadline.",
})
controls:AddSlider("HoldPad", {
    Text = "Hold release pad",
    Min = 0, Max = 0.2, Increment = 0.01, Default = 0.05,
    Suffix = "s",
    Tooltip = "Extra time held past a hold tile's end before releasing. Later is always safe; too early (under 82% held) downgrades the hit to MISS.",
})
controls:AddSlider("GateWait", {
    Text = "Gate delay",
    Min = 0, Max = 2, Increment = 0.1, Default = 0.8,
    Suffix = "s",
    Tooltip = "How long to sit on a start gate before pressing through it. The song clock is frozen during a gate, so this is cosmetic.",
})
controls:AddButton({
    Text = "Engage now (align mid-run)",
    Tooltip = "Take over the CURRENT run by aligning the tile cursor. Safe on an idle/AFK run. On a run you were playing yourself it can misjudge already-tapped tiles — prefer letting it engage at the next song.",
    Callback = function()
        local chart = Engine.chart()
        if not chart then
            EZ:Notify({ Title = "No run", Content = "Start a song first.", Type = "warning" })
            return
        end
        local st = Engine.songTime()
        local tiles = chart.tiles
        local idx = #tiles + 1
        for i = 1, #tiles do
            if Engine.fallAt(tiles[i], 1) > st + 0.03 then
                idx = i
                break
            end
        end
        BOT.cursor = idx
        table.clear(BOT.holds)
        table.clear(BOT.laneHold)
        BOT.gateTimer = nil
        BOT.engaged = BOT.running
        if log then log:Info(("engaged mid-run at tile %d/%d"):format(idx, #tiles)) end
        EZ:Notify({ Title = "Engaged", Content = ("aligned at tile %d/%d"):format(idx, #tiles), Type = "success" })
    end,
})

local live = Tab:AddRightGroupbox("Live", "activity", "Straight from Engine.stats()")
local L = {}
for _, def in ipairs({
    { "state", "State" },
    { "song", "Song" },
    { "tiles", "Tiles" },
    { "score", "Score" },
    { "combo", "Combo" },
    { "perfects", "Perfects" },
    { "misses", "Misses" },
    { "holds", "Held holds" },
}) do
    L[def[1]] = live:AddLabel(def[2] .. ": -")
end

local logSection = Tab:AddSection("Run log", "Engine onFinish summaries")
log = logSection:AddLog({ MaxLines = 30, Height = 140 })

----------------------------------------------------------------
-- Status pump
----------------------------------------------------------------
local uiAlive = true
task.spawn(function()
    while uiAlive do
        task.wait(0.25)
        local ok = pcall(function()
            local phase = Engine.phase()
            local chart = Engine.chart()
            local st = Engine.stats()

            local state
            if not BOT.running then
                state = "off"
            elseif not BOT.engaged then
                state = "armed — next song"
            elseif phase == "gated" then
                state = "gate"
            elseif phase == "playing" then
                state = "playing"
            else
                state = phase
            end
            L.state:SetText("State: " .. state)

            if chart then
                L.song:SetText("Song: " .. tostring(Engine.currentSongId() or "?"))
                local done = math.min(BOT.cursor - 1, #chart.tiles)
                L.tiles:SetText(("Tiles: %d/%d"):format(done, #chart.tiles))
            else
                L.song:SetText("Song: -")
                L.tiles:SetText("Tiles: -")
            end

            if st then
                L.score:SetText("Score: " .. tostring(st.score or 0))
                L.combo:SetText(("Combo: %d (max %d)"):format(st.combo or 0, st.maxCombo or 0))
                L.perfects:SetText(("Perfects: %d | misses %d | wrong %d")
                    :format(st.perfects or 0, st.misses or 0, st.wrongTaps or 0))
            end

            local held = 0
            for _ in pairs(BOT.holds) do held += 1 end
            L.holds:SetText("Held holds: " .. held)
        end)
    end
end)

----------------------------------------------------------------
-- Console API + teardown
----------------------------------------------------------------
getgenv().PianoAuto = {
    enable = function()
        autoToggle:Set(true)
    end,
    disable = function()
        autoToggle:Set(false)
    end,
    toggle = function()
        autoToggle:Set(not (EZ.Flags.AutoPlay and true or false))
    end,
    status = function()
        local chart = Engine.chart()
        return {
            running = BOT.running,
            engaged = BOT.engaged,
            phase = Engine.phase(),
            song = Engine.currentSongId(),
            cursor = BOT.cursor,
            tiles = chart and #chart.tiles or 0,
            stats = Engine.stats(),
        }
    end,
}

local function teardown()
    RUNNING = false
    uiAlive = false
    pcall(function() hb:Disconnect() end)
    pcall(function() if finishConn then finishConn() end end)
    getgenv().__PIANO_AUTO_LOADED = nil
    getgenv().__PIANO_AUTO_DESTROY = nil
    getgenv().PianoAuto = nil
end
getgenv().__PIANO_AUTO_LOADED = true
getgenv().__PIANO_AUTO_DESTROY = teardown
EZ:OnDestroy(teardown)

QuickBar:Pin("AutoPlay", { Icon = "music" })
SaveManager:LoadAutoloadConfig()
BOT.running = EZ.Flags.AutoPlay and true or false

print("[PIANO-AUTOPLAY] loaded — RightShift to toggle UI, P toggles autoplay")
EZ:Notify({
    Title = "Piano Autoplay loaded",
    Content = "Autoplay is OFF. Flip the toggle (or press P) — it takes over from the next song you start.",
    Type = "info",
    Duration = 6,
})
