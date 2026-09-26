--[[
    EZ Hub — one-line loader.

        loadstring(game:HttpGet(
            "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/loader.lua"
        ))()

    What it does:
      1. waits for the game to finish loading
      2. looks up the place you are in (game.PlaceId, then game.GameId) in the
         tables below
      3. downloads that game's module from games/ and runs it
      4. if the place is not one of ours, shows a small window listing what the
         hub carries instead of doing nothing

    Forcing a script (anywhere, including places not in the map):

        getgenv().EZHubForceGame = "counter-type"
        loadstring(game:HttpGet(".../loader.lua"))()

    The game modules are standalone: each one loads the library it needs and
    builds its own window, exactly like running it directly. The loader does
    NOT preload the library — a second load of Library.lua would tear down the
    first one, and the game's own window with it.
]]

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local REPO = "https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/"

--[[
    Where game modules come from.

    Gated (default once you deploy the worker): the modules live in a PRIVATE
    repo and are served by a Cloudflare Worker that holds the GitHub token
    server-side and only answers callers that send the key below.

    Ungated fallback: leave KEY empty and SOURCE pointing at a plain folder
    (either a public games/ folder in this repo, or your own host). Nothing
    else changes.

    The key travels as a query parameter rather than a header on purpose:
    game:HttpGet sends no custom headers, so this works on every executor
    without needing request / syn.request / http_request.

    Read the key out of this file and it only gets the game modules — never
    your GitHub token, and never your account. Rotate it by editing HUB_KEYS
    on the worker; this loader's copy is the only place it lives.
]]
local HUB = {
	KEY    = "",
	SOURCE = REPO .. "games/",
	-- once deployed, it looks like:
	-- KEY    = "paste-your-hub-key",
	-- SOURCE = "https://ezhub-games.YOUR-SUBDOMAIN.workers.dev/",
}

-- One entry per game. Adding a game means adding ONE entry to this list: the
-- two lookup tables and the catalog window below are derived from it, so they
-- cannot drift apart. (They used to be three separate tables, which is exactly
-- how a game ends up detectable but missing from the window, or vice versa.)
--
--   slug      filename in games/ minus .luau — also the EZHubForceGame value
--   name      shown in the catalog window
--   note      one line under the name
--   universes game.GameId values. One entry covers every place in that game
--             (lobby, match servers, event places), so it is usually enough.
--   places    game.PlaceId values, for when a single place needs its own
--             module or the universe list is not enough. PlaceId wins.
--
-- Every id must be checked against Roblox's own API, never guessed:
--   https://games.roblox.com/v1/games?universeIds=<id>   -> name + rootPlaceId
local GAMES = {
	{
		slug = "total-conquest", name = "Total Conquest", note = "autoplay",
		universes = { 10591363798 },              -- LDS Fighting
		places = { 131530256182298, 121112783648487 }, -- lobby, war match
	},
	{
		slug = "counter-type", name = "Counter Type", note = "autoplay",
		universes = { 10767575396 },              -- DomBlox Games
		places = { 92964612950536, 91221196478310 },   -- main, war
	},
	{
		slug = "slam-a-winner", name = "Slam A Winner", note = "autoplay",
		universes = { 10766047255 },              -- UpdatesDev
		places = { 84605263710079 },
	},
	{
		slug = "project-12", name = "Project 12", note = "vehicle + combat",
		universes = { 9286558970 },
		places = { 79966250354565 },
	},
	{
		slug = "bloxburg", name = "Bloxburg", note = "job farming",
		universes = { 88070565 },
	},
	{
		slug = "levelmoba", name = "Starforged", note = "aura suite",
		universes = { 9410753415 },
		places = { 109826671174115 },
	},
}

local BY_PLACE, BY_GAME = {}, {}
for _, entry in ipairs(GAMES) do
	for _, id in ipairs(entry.universes or {}) do BY_GAME[id] = entry.slug end
	for _, id in ipairs(entry.places or {}) do BY_PLACE[id] = entry.slug end
end

-- what the "unsupported place" window lists, in the order above
local CATALOG = GAMES

local function fetchModule(slug)
	local url = HUB.SOURCE .. slug .. ".luau"
	if HUB.KEY and HUB.KEY ~= "" then
		url = url .. "?key=" .. HUB.KEY
	end
	local ok, body = pcall(function()
		return game:HttpGet(url)
	end)
	-- Executors disagree on how a failed download looks: some throw, some
	-- return the response body, some (Potassium) return an empty string. So
	-- the status is read from the error text AND the body, and when neither
	-- says anything useful the message names both likely causes.
	if not ok then
		local err = tostring(body):lower()
		if err:find("403") or err:find("forbidden") or err:find("unauthor") then
			return nil, "hub key rejected — update HUB.KEY"
		end
		if err:find("404") or err:find("not found") then
			return nil, "no such module"
		end
		return nil, "download failed (" .. tostring(body):sub(1, 60) .. ")"
	end
	if type(body) ~= "string" or body == "" then
		return nil, "download failed — wrong hub key, or the worker/URL is not live yet"
	end
	if #body < 200 then
		if body:find("EZHUB_DENIED") or body:lower():find("invalid key") then
			return nil, "hub key rejected — update HUB.KEY"
		end
		if body:find("EZHUB_MISSING") or body:find("404") then
			return nil, "no such module"
		end
	end
	return body
end

local function runModule(slug, source)
	local chunk, compileErr = loadstring(source)
	if not chunk then
		return false, "not valid Luau: " .. tostring(compileErr)
	end
	local ok, runErr = pcall(chunk)
	if not ok then
		return false, "errored: " .. tostring(runErr)
	end
	return true
end

-- Unsupported place: load the library and show what the hub carries. This is
-- the one path where the loader loads Library.lua itself, and it is safe here
-- because no game module is going to run and claim the instance.
local function showCatalog(why)
	local ok, EZ = pcall(function()
		return loadstring(game:HttpGet(REPO .. "Library.lua"))()
	end)
	if not ok or not EZ then
		warn("[EZHub] " .. why .. " — and the library could not be loaded either")
		return
	end
	pcall(function()
		EZ:SetIcons(loadstring(game:HttpGet(REPO .. "addons/Icons.lua"))())
	end)

	local window = EZ:CreateWindow({
		Title = "EZ Hub",
		SubTitle = why,
		ToggleKey = Enum.KeyCode.RightShift,
		ToggleIcon = "layout-grid",
		Icon = EZ.ImageManager.AddAsset("ez_logo", nil, REPO .. "assets/logo.png"),
		Footer = "EZ Hub | v" .. EZ._version,
	})

	local tab = window:AddTab("Games", "gamepad-2")
	local box = tab:AddLeftGroupbox("Supported games", "list", "play one of these and re-run the loader")

	for _, entry in ipairs(CATALOG) do
		box:AddLabel({ DoesWrap = true, RichText = true,
			Text = ("<b>%s</b> — %s"):format(entry.name, entry.note) })
	end

	box:AddDivider("Loader")
	box:AddButton({
		Text = "Copy the loader one-liner",
		Sub = true,
		Callback = function()
			local line = ('loadstring(game:HttpGet("%sloader.lua"))()'):format(REPO)
			if setclipboard then pcall(setclipboard, line) end
			EZ:Notify({ Title = "Copied", Content = line, Duration = 5, Type = "success" })
		end,
	})

	local here = tab:AddRightGroupbox("This place", "map-pin", "not in the map yet")
	here:AddLabel({ DoesWrap = true, Text =
		"Playing one of the games on the left? Re-run the loader there and it will "
		.. "download that game's module by itself." })
	here:AddDivider("Ids")
	here:AddParagraph({ Title = "PlaceId", Content = tostring(game.PlaceId) })
	here:AddParagraph({ Title = "GameId", Content = tostring(game.GameId) })
	here:AddParagraph({ Title = "JobId", Content = tostring(game.JobId) })
	here:AddDivider("Alt places")
	here:AddLabel({ DoesWrap = true, Text =
		"If a game has match servers the map does not know, force its module with "
		.. 'getgenv().EZHubForceGame = "slug" before running the loader.' })
end

----------------------------------------------------------------
-- entry
----------------------------------------------------------------

local forced = getgenv and getgenv().EZHubForceGame
local slug = forced or BY_PLACE[game.PlaceId] or BY_GAME[game.GameId]

if not slug then
	showCatalog("this place is not in the map")
	return
end

local source, fetchErr = fetchModule(slug)
if not source then
	warn(("[EZHub] %s — %s"):format(slug, tostring(fetchErr)))
	showCatalog(("%s: %s"):format(slug, tostring(fetchErr)))
	return
end

local ok, runErr = runModule(slug, source)
if not ok then
	warn(("[EZHub] %s %s"):format(slug, tostring(runErr)))
	showCatalog(("%s %s"):format(slug, tostring(runErr)))
end
