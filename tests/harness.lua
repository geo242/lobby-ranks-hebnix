-- Mock Hebnix host to exercise lobby_ranks/main.lua
local store = {}
local now = 0
local draws = {}
local scoreboard = false
local bind_down = false

hebnix = {
    rl_connected = function() return true end,
    log = function(...) print("[log]", ...) end,
    get_bool = function(k, d) local v = store[k]; if type(v) == "boolean" then return v end; return d == nil and false or d end,
    get_string = function(k, d) local v = store[k]; if type(v) == "string" then return v end; return d or "" end,
    get_number = function(k, d) local v = store[k]; if type(v) == "number" then return v end; return d or 0 end,
    set = function(k, v) store[k] = v end,
    monotonic_seconds = function() return now end,
    is_bot = function(id) return id == "" or id:lower():find("unknown") ~= nil or not id:find("|", 1, true) end,
    measure_text = function(t, size, bold) return #t * size * (bold and 0.6 or 0.55) end,
    is_action_pressed = function(a) return a == "scoreboard" and scoreboard end,
    is_bind_pressed = function(b) return bind_down end,
    capture_bind_async = function() return true end,
    capture_bind_result = function() return "done", "f3" end,
    parse_launch_log_async = function() return "logkey" end,
    launch_log_result = function() return { session = { primary_id = "Steam|111|0" } } end,
    fetch_profile_async = function(platform, account) return platform .. ":" .. account end,
    fetch_stats_async = function() return true end,
    clear_stats_cache = function() end,
    stats_result = function(key)
        if key == "epic:222" then return "pending" end
        if key == "psn:333" then return { error = "boom" } end
        return { ranks = {
            [10] = { playlist_id = 10, tier_id = 13, division_id = 2, mmr = 1003.4, matches_played = 120 },
            [11] = { playlist_id = 11, tier_id = 22, division_id = 0, mmr = 1901, matches_played = 900 },
            ["34"] = { playlist_id = 34, tier_id = 0, division_id = 0, mmr = 600, matches_played = 0 },
            [0] = { playlist_id = 0, tier_id = 0, division_id = 0, mmr = 812, matches_played = 3000 },
        } }
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
    plugin.on_tick()
    plugin.on_overlay(draw, 1920, 1080)
    return draws
end

-- 1. no match: nothing drawn
assert(#frame() == 0, "drew with empty roster")

-- 2. match with players
plugin.on_game_event("UpdateState", { match_guid = "m1", data = { Players = {
    { Name = "Me",    PrimaryId = "Steam|111|0", TeamNum = 0, Score = 100 },
    { Name = "EpicG", PrimaryId = "Epic|222|0",  TeamNum = 1, Score = 50 },
    { Name = "Psn",   PrimaryId = "PS4|333|0",   TeamNum = 1, Score = 70 },
    { Name = "Bot A", PrimaryId = "Unknown|0|0", TeamNum = 0, Score = 0 },
} } })
assert(#frame() == 0, "drew without scoreboard/toggle")

scoreboard = true
local d = frame()
assert(#d > 0, "nothing drawn with scoreboard held")
for _, line in ipairs(d) do if line:sub(1, 4) == "text" then print(line) end end

-- expected content checks
local joined = table.concat(d, "\n")
assert(joined:find("D1 D3"), "rank text missing")
assert(joined:find("SSL"), "SSL missing")
assert(joined:find("1003"), "mmr missing")
assert(joined:find("%.%.%."), "pending marker missing")
assert(joined:find("text %?"), "error marker missing")

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
plugin.on_settings(setmetatable({}, { __index = function(_, k)
    if k == "horizontal" or k == "collapsing" then
        return function(a, b) local f = type(a) == "function" and a or b; f(setmetatable({}, getmetatable(_ or {}))) end
    end
    if k == "button" then return function(t) return t == "Set" end end
    if k == "combo_box" then return function(key, _, opts) return opts[1] end end
    return function() end
end }))
frame() -- capture completes -> bind f3
assert(store["lr_toggle_bind"] == "f3", "bind not captured")
bind_down = true; frame(); bind_down = false; frame() -- press is ignored (it set the bind)
bind_down = true; d = frame()
assert(#d > 0, "toggle did not show table")
bind_down = false; frame(); bind_down = true; d = frame()
assert(#d == 0, "toggle did not hide table")

-- 5. preview works out of match
plugin.on_game_event("GameLeft", {})
store["lr_preview"] = true
d = frame()
assert(table.concat(d, "\n"):find("Sierra"), "preview missing")

-- 6. disabled
store["lr_preview"] = false
store["lr_enabled"] = false
scoreboard = true
assert(#frame() == 0)

print("ALL TESTS PASSED")

