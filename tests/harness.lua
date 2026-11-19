-- Mock Hebnix host to exercise lobby_ranks/main.lua
local store = {}
local now = 0
local draws = {}
local scoreboard = false
local bind_down = false
local calls = { measure = 0, stats = {}, fetch = {} }
local logs = {}
local RANKS = { ranks = {
    [10] = { playlist_id = 10, tier_id = 13, division_id = 2, mmr = 1003.4, matches_played = 120 },
    [11] = { playlist_id = 11, tier_id = 22, division_id = 0, mmr = 1901, matches_played = 900 },
    ["34"] = { playlist_id = 34, tier_id = 0, division_id = 0, mmr = 600, matches_played = 0 },
    [0] = { playlist_id = 0, tier_id = 0, division_id = 0, mmr = 812, matches_played = 3000 },
} }
local psn_result = { error = "profile service returned HTTP 503" }

hebnix = {
    rl_connected = function() return true end,
    log = function(text) table.insert(logs, text); print("[log]", text) end,
    get_bool = function(k, d) local v = store[k]; if type(v) == "boolean" then return v end; return d == nil and false or d end,
    get_string = function(k, d) local v = store[k]; if type(v) == "string" then return v end; return d or "" end,
    get_number = function(k, d) local v = store[k]; if type(v) == "number" then return v end; return d or 0 end,
    set = function(k, v) store[k] = v end,
    monotonic_seconds = function() return now end,
    is_bot = function(id) return id == "" or id:lower():find("unknown") ~= nil or not id:find("|", 1, true) end,
    measure_text = function(t, size, bold) calls.measure = calls.measure + 1; return #t * size * (bold and 0.6 or 0.55) end,
    is_action_pressed = function(a) return a == "scoreboard" and scoreboard end,
    is_bind_pressed = function(b) return bind_down end,
    capture_bind_async = function() return true end,
    capture_bind_result = function() return "done", "f3" end,
    parse_launch_log_async = function() return "logkey" end,
    launch_log_result = function() return { session = { primary_id = "Steam|111|0" } } end,
    fetch_profile_async = function(platform, account)
        local key = platform .. ":" .. account
        calls.fetch[key] = (calls.fetch[key] or 0) + 1
        return key
    end,
    fetch_stats_async = function() return true end,
    clear_stats_cache = function() end,
    stats_result = function(key)
        calls.stats[key] = (calls.stats[key] or 0) + 1
        if key == "epic:222" then return "pending" end
        if key == "psn:333" then return psn_result end
        return RANKS
    end,
}

local draw = {
    rect = function(x, y, w, h, o) table.insert(draws, string.format("rect %.0f,%.0f %.0fx%.0f %s", x, y, w, h, o.color)) end,
    line = function(x1, y1, x2, y2, o) table.insert(draws, "line") end,
    text = function(x, y, t, o) table.insert(draws, string.format("text %-10s %s %s", t, o.color, o.halign)) end,
}

local plugin = dofile(arg_path)
plugin.on_load()

local function frame()
    draws = {}
    now = now + 1
    -- like the host: on_tick / on_overlay are only called while the plugin defines them
    if plugin.on_tick then plugin.on_tick() end
    if plugin.on_overlay then plugin.on_overlay(draw, 1920, 1080) end
    return draws
end

local function settings_ui(pressed)
    return setmetatable({}, { __index = function(_, k)
        if k == "horizontal" or k == "collapsing" then
            return function(a, b) local f = type(a) == "function" and a or b; f(settings_ui(pressed)) end
        end
        if k == "button" then return function(t) return t == pressed end end
        if k == "combo_box" then return function(key, _, opts) return opts[1] end end
        return function() end
    end })
end

-- 1. no match: nothing drawn, and neither hook is defined (either one keeps
-- Hebnix repainting at the overlay rate)
assert(#frame() == 0, "drew with empty roster")
assert(plugin.on_overlay == nil, "on_overlay defined while nothing is shown")
assert(plugin.on_tick == nil, "on_tick defined outside a match")

-- 2. match with players
plugin.on_game_event("UpdateState", { match_guid = "m1", data = { Players = {
    { Name = "Me",    PrimaryId = "Steam|111|0", TeamNum = 0, Score = 100 },
    { Name = "EpicG", PrimaryId = "Epic|222|0",  TeamNum = 1, Score = 50 },
    { Name = "Psn",   PrimaryId = "PS4|333|0",   TeamNum = 1, Score = 70 },
    { Name = "Bot A", PrimaryId = "Unknown|0|0", TeamNum = 0, Score = 0 },
} } })
assert(#frame() == 0, "drew without scoreboard/toggle")
assert(plugin.on_overlay == nil, "on_overlay defined while the table is hidden")
assert(plugin.on_tick ~= nil, "on_tick not defined in a match (scoreboard key unwatched)")

scoreboard = true
local d = frame()
assert(#d > 0, "nothing drawn with scoreboard held")
assert(plugin.on_overlay ~= nil, "on_overlay not defined while the table is shown")
for _, line in ipairs(d) do if line:sub(1, 4) == "text" then print(line) end end

-- expected content checks
local joined = table.concat(d, "\n")
assert(joined:find("D1 D3"), "rank text missing")
assert(joined:find("SSL"), "SSL missing")
assert(joined:find("1003"), "mmr missing")
assert(joined:find("%.%.%."), "pending marker missing")
assert(not joined:find("text %?"), "a first failure shown as ? instead of being retried")

-- 2b. resolved profiles are not re-read; a failed one isn't polled before its
-- retry; unchanged frames don't re-measure text
local steam_reads, psn_reads = calls.stats["steam:111"], calls.stats["psn:333"]
local measures = calls.measure
for _ = 1, 3 do assert(#frame() > 0) end
assert(calls.stats["steam:111"] == steam_reads, "resolved profile polled again")
assert(calls.stats["psn:333"] == psn_reads, "failed profile polled before its retry")
assert(calls.measure == measures, "text re-measured without changes")

-- 2c. repeated UpdateState with the same roster is cheap; a player leaving is seen at once
local same = { match_guid = "m1", data = { Players = {
    { Name = "Me",    PrimaryId = "Steam|111|0", TeamNum = 0, Score = 100 },
    { Name = "EpicG", PrimaryId = "Epic|222|0",  TeamNum = 1, Score = 50 },
    { Name = "Psn",   PrimaryId = "PS4|333|0",   TeamNum = 1, Score = 70 },
} } }
plugin.on_game_event("UpdateState", same)
now = now + 5 -- force the safety rebuild so the table reflects the roster
d = frame()
assert(not table.concat(d, "\n"):find("Bot A"), "player that left still shown")
plugin.on_game_event("UpdateState", { match_guid = "m1", data = { Players = {
    { Name = "Me",    PrimaryId = "Steam|111|0", TeamNum = 0, Score = 100 },
    { Name = "EpicG", PrimaryId = "Epic|222|0",  TeamNum = 1, Score = 50 },
    { Name = "Psn",   PrimaryId = "PS4|333|0",   TeamNum = 1, Score = 70 },
    { Name = "Bot A", PrimaryId = "Unknown|0|0", TeamNum = 0, Score = 0 },
} } })
d = frame()
assert(table.concat(d, "\n"):find("Bot A"), "player that joined not shown")

-- 2d. a failing lookup is retried after 20, 40 and 60 s, then shown as "?"
local function has(text) return table.concat(frame(), "\n"):find(text, 1, true) ~= nil end
local function wait(seconds) for _ = 1, seconds do frame() end end
local function any_log(text)
    for _, line in ipairs(logs) do if line:find(text, 1, true) then return true end end
    return false
end
local fetches = calls.fetch["psn:333"]
wait(20)
assert(calls.fetch["psn:333"] == fetches + 1, "first retry not sent after 20 s")
assert(not has("text ?"), "? shown while retries remain")
wait(40)
assert(calls.fetch["psn:333"] == fetches + 2, "second retry not sent after 40 s")
wait(60)
assert(calls.fetch["psn:333"] == fetches + 3, "third retry not sent after 60 s")
wait(2)
assert(has("text ?"), "? not shown after the retries ran out")
wait(120)
assert(calls.fetch["psn:333"] == fetches + 3, "retried after giving up")
assert(any_log("rank lookup for Psn failed (profile service returned HTTP 503), retrying in 20 s"), "failure reason not logged")
assert(any_log("giving up for this match"), "giving up not logged")

-- 2e. a lookup that succeeds on a retry shows the rank ("Refresh ranks" starts over)
local refresh = "Refresh ranks (clear profile cache)"
psn_result = { error = "profile service request failed: timed out" }
plugin.on_settings(settings_ui(refresh))
wait(2)
assert(not has("text ?"), "refresh didn't start over")
local function count(text)
    local n = 0
    for _, line in ipairs(frame()) do if line:find(text, 1, true) then n = n + 1 end end
    return n
end
assert(count("text 1003") == 1, "only Me should have an MMR before the retry")
psn_result = RANKS
wait(20)
assert(not has("text ?") and count("text 1003") == 2, "rank not shown after a successful retry")

-- 2f. "not found" isn't retried
psn_result = { error = "NOT_FOUND_404: profile service returned 404", not_found = true }
plugin.on_settings(settings_ui(refresh))
fetches = calls.fetch["psn:333"]
wait(2)
assert(has("text ?"), "not found not shown as ?")
wait(100)
assert(calls.fetch["psn:333"] == fetches, "not found was retried")
psn_result = RANKS
plugin.on_settings(settings_ui(refresh))
wait(2)

-- 3. platform + casual + all playlists, then preview
store["lr_show_platform"] = true
store["lr_pl_0"] = true
store["lr_pl_63"] = true
now = now + 5
d = frame()
assert(table.concat(d, "\n"):find("Steam"), "platform missing")
assert(table.concat(d, "\n"):find("812"), "casual mmr missing")

-- 4. toggle bind
scoreboard = false
plugin.on_settings(settings_ui("Set"))
frame() -- capture completes -> bind f3
assert(store["lr_toggle_bind"] == "f3", "bind not captured")
bind_down = true; frame(); bind_down = false; frame() -- press is ignored (it set the bind)
bind_down = true; d = frame()
assert(#d > 0, "toggle did not show table")
bind_down = false; frame(); bind_down = true; d = frame()
assert(#d == 0, "toggle did not hide table")

-- 5. preview works out of match
plugin.on_game_event("GameLeft", {})
assert(plugin.on_tick == nil and plugin.on_overlay == nil, "hooks kept after leaving the match")
store["lr_preview"] = true
plugin.on_settings(settings_ui())
d = frame()
assert(table.concat(d, "\n"):find("Sierra"), "preview missing")

-- 6. disabled
store["lr_preview"] = false
store["lr_enabled"] = false
scoreboard = true
assert(#frame() == 0)
assert(plugin.on_tick == nil and plugin.on_overlay == nil, "hooks kept after the preview closed")

print("ALL TESTS PASSED")

