-- Lobby Ranks for Hebnix
-- Inspired by GrantJL's BakkesMod "Lobby Ranks" plugin (https://github.com/GrantJL/rl-lobby-ranks).
-- Shows a table of every player in the current match with their rank, MMR and
-- games played across a configurable set of playlists.
--
-- Data sources:
--   * players  : StatsAPI "UpdateState" events (Players[].Name/PrimaryId/TeamNum)
--   * ranks    : hebnix.fetch_profile_async / hebnix.stats_result (tracker profiles)
--   * local id : Launch.log (to highlight your own row)

local plugin = {}

local VERSION = "1.0.4"
local P = "lr_" -- settings key prefix

---------------------------------------------------------------------------
-- Static data
---------------------------------------------------------------------------

-- ids are tracker / matchmaking playlist ids; casual is 0 in tracker profiles
-- (some sources use 1, both are checked)
local PLAYLISTS = {
    { id = 0,  label = "Casual", name = "Casual (Unranked)", default = false, alt = 1 },
    { id = 10, label = "1v1",    name = "Ranked Duel 1v1",     default = true },
    { id = 11, label = "2v2",    name = "Ranked Doubles 2v2",  default = true },
    { id = 13, label = "3v3",    name = "Ranked Standard 3v3", default = true },
    { id = 61, label = "4v4",    name = "Ranked 4v4 (Chaos)",  default = false },
    { id = 34, label = "Tourn",  name = "Tournament",          default = true },
    { id = 27, label = "Hoops",  name = "Hoops",               default = false },
    { id = 28, label = "Rumble", name = "Rumble",              default = false },
    { id = 29, label = "Drop",   name = "Dropshot",            default = false },
    { id = 30, label = "Snow",   name = "Snow Day",            default = false },
    { id = 63, label = "Heat",   name = "Heatseeker",          default = false },
}

local TIER_SHORT = {
    [0] = "-",
    "B1", "B2", "B3", "S1", "S2", "S3", "G1", "G2", "G3",
    "P1", "P2", "P3", "D1", "D2", "D3", "C1", "C2", "C3",
    "GC1", "GC2", "GC3", "SSL",
}

-- rank color groups: key, label, default, tier range
local RANK_GROUPS = {
    { key = "unranked", label = "Unranked",          color = "#b3b3b3", lo = 0,  hi = 0 },
    { key = "bronze",   label = "Bronze",            color = "#ff9900", lo = 1,  hi = 3 },
    { key = "silver",   label = "Silver",            color = "#ffffff", lo = 4,  hi = 6 },
    { key = "gold",     label = "Gold",              color = "#ffd900", lo = 7,  hi = 9 },
    { key = "platinum", label = "Platinum",          color = "#39f8ff", lo = 10, hi = 12 },
    { key = "diamond",  label = "Diamond",           color = "#43a4ff", lo = 13, hi = 15 },
    { key = "champ",    label = "Champion",          color = "#ca89ff", lo = 16, hi = 18 },
    { key = "gc",       label = "Grand Champion",    color = "#ff5d5d", lo = 19, hi = 21 },
    { key = "ssl",      label = "Supersonic Legend", color = "#ff6fdb", lo = 22, hi = 22 },
}

local PLATFORMS = {
    { key = "steam",  label = "Steam",       color = "#8e96b3" },
    { key = "epic",   label = "Epic",        color = "#a4a4a4" },
    { key = "psn",    label = "PlayStation", color = "#1e4293" },
    { key = "xbox",   label = "Xbox",        color = "#3d7523" },
    { key = "switch", label = "Switch",      color = "#cd3520" },
}

local DEFAULT_COLORS = {
    team_blue   = "#2074ff",
    team_orange = "#ff9c0c",
    self        = "#ffffff",
    header_fg   = "#ffffff",
    header_bg   = "#1a1a1a",
    row_even    = "#2a2a2a",
    row_odd     = "#1f1f1f",
    text        = "#e6e6e6",
}

-- combo_box falls back to the first option, so defaults go first
local ANCHORS_H = { "Center", "Left", "Right" }
local ANCHORS_V = { "Top", "Center", "Bottom" }
local ANCHOR_FACTOR = { Left = 0, Top = 0, Center = 0.5, Right = 1, Bottom = 1 }

local EXAMPLE_PLAYERS = {
    { name = "Charlie", team = 1, platform = "",       bot = false, ranks = { 0, 1 } },
    { name = "Foxtrot", team = 1, platform = "steam",  bot = false, ranks = { 4, 7 } },
    { name = "Juliet",  team = 1, platform = "psn",    bot = false, ranks = { 10, 13 } },
    { name = "Mike",    team = 0, platform = "xbox",   bot = false, ranks = { 15, 17 } },
    { name = "Oscar",   team = 0, platform = "switch", bot = false, ranks = { 20, 21 } },
    { name = "Sierra",  team = 0, platform = "epic",   bot = false, ranks = { 22, 22 }, me = true },
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local roster = {}          -- key -> entry
local roster_count = 0
local roster_seq = 0
local roster_gen = 0
local next_roster_scan = 0
local match_guid = nil
local my_id = nil
local log_key = nil
local log_retry_at = 0
local next_profile_poll = 0

local toggled = false      -- toggle bind state (like jlg_lobby_rank_toggle)
local toggle_was_pressed = false
local capturing = false

-- Anything that changes what the table shows bumps data_version; the built
-- layout is only rebuilt when its version is behind (or the screen size changes).
local data_version = 0
local live_cache = {}
local preview_cache = {}

local ROSTER_SCAN_INTERVAL = 0.25 -- UpdateState throttle (seconds)
local PROFILE_POLL_INTERVAL = 1   -- how often unresolved profiles are polled
local PROFILE_RETRY_INTERVAL = 5  -- re-request a vanished / never-started profile
-- A failed lookup (timeout, server error, rejected token...) is tried again
-- this many seconds after each failure, then shown as "?" for the rest of the
-- match. Hebnix keeps a finished result, failures included, for 15 s, so a
-- sooner retry would only read the same failure back. "Not found" isn't retried.
local PROFILE_FAILURE_RETRY_DELAYS = { 20, 40, 60 }
local REBUILD_MIN_INTERVAL = 0.1  -- cap rebuilds while settings are being dragged
local REBUILD_SAFETY_INTERVAL = 5 -- catch setting changes made outside on_settings

local function mark_dirty()
    data_version = data_version + 1
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function setting_color(key)
    local hex = hebnix.get_string(P .. "c_" .. key, DEFAULT_COLORS[key] or "#ffffff")
    if type(hex) ~= "string" or not hex:match("^#%x%x%x%x%x%x") then
        hex = DEFAULT_COLORS[key] or "#ffffff"
    end
    return hex:sub(1, 7)
end

local function with_alpha(hex, alpha)
    alpha = math.max(0, math.min(255, math.floor(alpha + 0.5)))
    return hex:sub(1, 7) .. string.format("%02x", alpha)
end

local function rank_color(tier)
    for _, group in ipairs(RANK_GROUPS) do
        if tier >= group.lo and tier <= group.hi then
            local hex = hebnix.get_string(P .. "rc_" .. group.key, group.color)
            if type(hex) == "string" and hex:match("^#%x%x%x%x%x%x") then return hex:sub(1, 7) end
            return group.color
        end
    end
    return "#ffffff"
end

local function platform_info(key)
    for _, p in ipairs(PLATFORMS) do
        if p.key == key then
            local hex = hebnix.get_string(P .. "pc_" .. p.key, p.color)
            if type(hex) ~= "string" or not hex:match("^#%x%x%x%x%x%x") then hex = p.color end
            return p.label, hex:sub(1, 7)
        end
    end
    return "", "#888888"
end

-- "Steam|7656...|0" -> "steam", "7656..."
local function split_primary_id(primary_id)
    local platform, account = tostring(primary_id or ""):match("^([^|]+)|([^|]+)")
    if not platform or not account or account == "" then return nil, nil end
    platform = platform:lower()
    if platform == "epicgames" then platform = "epic" end
    if platform == "xbl" or platform == "xboxone" then platform = "xbox" end
    if platform == "ps4" or platform == "ps5" or platform == "playstation" then platform = "psn" end
    if platform == "nintendo" then platform = "switch" end
    return platform, account
end

-- fetch_profile_async uses its own platform names
local PROFILE_PLATFORM = { steam = "steam", epic = "epic", xbox = "xboxone", psn = "psn", switch = "switch" }

local function request_profile(entry)
    if entry.bot then return end
    local platform, account = split_primary_id(entry.id)
    local key
    if platform and PROFILE_PLATFORM[platform] then
        key = hebnix.fetch_profile_async(PROFILE_PLATFORM[platform], account)
    elseif entry.id ~= "" then
        hebnix.fetch_stats_async(entry.id, entry.name or "")
        key = entry.id
    end
    entry.request_key = key
end

local function rank_for(stats, playlist)
    local ranks = stats and stats.ranks
    if type(ranks) ~= "table" then return nil end
    local direct = ranks[playlist.id] or (playlist.alt and ranks[playlist.alt])
    if type(direct) == "table" then return direct end
    for key, rank in pairs(ranks) do
        local id = tonumber(type(rank) == "table" and rank.playlist_id or key)
        if id == playlist.id or (playlist.alt and id == playlist.alt) then return rank end
    end
    return nil
end

-- stats_result copies the whole tracker profile into fresh Lua tables, so it is
-- only polled until the profile resolves. The few fields the table needs are
-- kept on the entry and stats_result is never called for it again.
local function resolve_profile(entry)
    if entry.bot or entry.profile_kind == "ok" or entry.profile_kind == "error"
        or entry.profile_kind == "retry" then return end
    local kind
    if not entry.request_key then
        kind = "none"
    else
        local result = hebnix.stats_result(entry.request_key)
        if result == nil then
            kind = "missing"
        elseif result == "pending" then
            kind = "pending"
        elseif type(result) ~= "table" then
            kind = "missing"
        elseif result.error or result.not_found then
            local failures = (entry.failures or 0) + 1
            entry.failures = failures
            local delay = not result.not_found and PROFILE_FAILURE_RETRY_DELAYS[failures]
            local reason = tostring(result.error or "not found")
            if delay then
                kind = "retry"
                entry.retry_at = hebnix.monotonic_seconds() + delay
                hebnix.log(string.format("[Lobby Ranks] rank lookup for %s failed (%s), retrying in %d s",
                    entry.name or "?", reason, delay))
            else
                kind = "error"
                hebnix.log(string.format("[Lobby Ranks] rank lookup for %s failed (%s)%s",
                    entry.name or "?", reason, result.not_found and "" or ", giving up for this match"))
            end
        else
            local ranks = {}
            for _, playlist in ipairs(PLAYLISTS) do
                local rank = rank_for(result, playlist)
                if rank then
                    ranks[playlist.id] = {
                        tier_id = tonumber(rank.tier_id),
                        division_id = tonumber(rank.division_id),
                        mmr = tonumber(rank.mmr),
                        matches_played = tonumber(rank.matches_played),
                    }
                end
            end
            entry.ranks = ranks
            kind = "ok"
        end
    end
    if kind ~= entry.profile_kind then
        entry.profile_kind = kind
        mark_dirty()
    end
end

local function rank_text(tier, division, is_casual)
    if is_casual then return "-" end
    tier = math.max(0, math.min(22, math.floor(tier or 0)))
    local text = TIER_SHORT[tier] or "?"
    if hebnix.get_bool(P .. "show_division", true) and tier > 0 and tier < 22 and division then
        text = text .. " D" .. (math.floor(division) + 1)
    end
    return text
end

local function selected_playlists()
    local list = {}
    for _, playlist in ipairs(PLAYLISTS) do
        if hebnix.get_bool(P .. "pl_" .. playlist.id, playlist.default) then
            table.insert(list, playlist)
        end
    end
    return list
end

local function team_color(team, is_me)
    if is_me then return setting_color("self") end
    if team == 0 then return setting_color("team_blue") end
    if team == 1 then return setting_color("team_orange") end
    return setting_color("text")
end

---------------------------------------------------------------------------
-- Roster from StatsAPI events
---------------------------------------------------------------------------

local function reset_roster()
    roster = {}
    roster_count = 0
    roster_seq = 0
    next_roster_scan = 0
    mark_dirty()
end

local function update_roster(event)
    local data = event and (event.data or event.Data)
    local players = type(data) == "table" and (data.Players or data.players) or nil
    if type(players) ~= "table" then return end

    -- UpdateState arrives many times a second but the roster rarely changes:
    -- scan at most every ROSTER_SCAN_INTERVAL unless the player count changed.
    local now = hebnix.monotonic_seconds()
    if now < next_roster_scan and #players == roster_count then return end
    next_roster_scan = now + ROSTER_SCAN_INTERVAL

    roster_gen = roster_gen + 1
    local changed = false
    for _, player in ipairs(players) do
        local id = tostring(player.PrimaryId or player.primary_id or "")
        local name = tostring(player.Name or player.name or "Unknown")
        local entry = id ~= "" and roster[id] or nil
        if not entry then
            local bot = id == "" or hebnix.is_bot(id)
            local key = bot and ("bot:" .. name) or id
            entry = roster[key]
            if not entry then
                roster_seq = roster_seq + 1
                roster_count = roster_count + 1
                entry = { order = roster_seq, id = id, name = name, bot = bot }
                roster[key] = entry
                local platform = split_primary_id(id)
                entry.platform = platform or ""
                request_profile(entry)
                resolve_profile(entry) -- already cached by another plugin?
                changed = true
            end
        end
        entry.gen = roster_gen

        local score = tonumber(player.Score or player.score) or 0
        local team = tonumber(player.TeamNum or player.team_num)
        team = (team == 0 or team == 1) and team or -1
        if entry.name ~= name or entry.score ~= score or entry.team ~= team then
            entry.name, entry.score, entry.team = name, score, team
            changed = true
        end
    end

    -- players that left are dropped (the BakkesMod plugin refreshed on PRI destroy)
    for key, entry in pairs(roster) do
        if entry.gen ~= roster_gen then
            roster[key] = nil
            roster_count = roster_count - 1
            changed = true
        end
    end

    if changed then mark_dirty() end
end

local function sorted_roster()
    local list = {}
    for _, entry in pairs(roster) do table.insert(list, entry) end
    local function team_rank(t) return t == 0 and 0 or (t == 1 and 1 or 2) end
    table.sort(list, function(a, b)
        if a.team ~= b.team then return team_rank(a.team) < team_rank(b.team) end
        if (a.score or 0) ~= (b.score or 0) then return (a.score or 0) > (b.score or 0) end
        return a.order < b.order
    end)
    return list
end

local function poll_local_identity()
    local now = hebnix.monotonic_seconds()
    if my_id then return end
    if not log_key then
        if now < log_retry_at then return end
        log_key = hebnix.parse_launch_log_async(false)
        return
    end
    local info = hebnix.launch_log_result(log_key)
    if info == nil or info == "pending" then return end
    log_key = nil
    if type(info) == "table" and type(info.session) == "table" and info.session.primary_id then
        my_id = tostring(info.session.primary_id)
        mark_dirty()
    else
        log_retry_at = now + 30
    end
end

---------------------------------------------------------------------------
-- Table model
--   columns : { {header, align}, ... }
--   blocks  : one per player, each with `lines` sub rows
--             cells[col] = { {text, color}, ... per line } (nil line = blank)
---------------------------------------------------------------------------

local function build_rows(players, playlists, show_mmr, show_games, show_platform)
    local columns = { { header = "Name", align = "left" } }
    if show_platform then table.insert(columns, { header = "Platform", align = "left" }) end
    for _, playlist in ipairs(playlists) do
        table.insert(columns, { header = playlist.label, align = "center" })
    end

    local lines = 1 + (show_mmr and 1 or 0) + (show_games and 1 or 0)
    local text = setting_color("text")
    local blocks = {}

    for _, player in ipairs(players) do
        local block = { team = player.team, cells = {} }
        local name_col = team_color(player.team, player.me)
        block.cells[1] = { { text = player.name, color = name_col, bold = player.me, vcenter = true } }
        if show_platform then
            local label, color = platform_info(player.platform)
            if player.bot then label, color = "Bot", "#888888" end
            block.cells[2] = { { text = label, color = color, vcenter = true } }
        end

        for _, playlist in ipairs(playlists) do
            local cell = {}
            local r = player.rank_lookup(playlist)
            if r.kind == "ok" then
                local is_casual = playlist.id == 0
                local tier = math.floor(tonumber(r.rank.tier_id) or 0)
                local color = is_casual and text or rank_color(tier)
                table.insert(cell, { text = rank_text(tier, tonumber(r.rank.division_id), is_casual), color = color, bold = true })
                if show_mmr then
                    local mmr = tonumber(r.rank.mmr)
                    table.insert(cell, { text = mmr and tostring(math.floor(mmr + 0.5)) or "-", color = color })
                end
                if show_games then
                    local games = tonumber(r.rank.matches_played)
                    table.insert(cell, { text = games and tostring(math.floor(games)) or "-", color = text })
                end
            else
                local symbol = ({ pending = "...", retry = "...", error = "?", none = "", nodata = "-", missing = "..." })[r.kind] or ""
                local color = r.kind == "nodata" and rank_color(0) or "#888888"
                table.insert(cell, { text = symbol, color = color })
                for _ = 2, lines do table.insert(cell, { text = "", color = color }) end
            end
            block.cells[#block.cells + 1] = cell
        end
        table.insert(blocks, block)
    end

    return { columns = columns, blocks = blocks, lines = lines }
end

local function live_players()
    local list = {}
    for _, entry in ipairs(sorted_roster()) do
        local kind = entry.bot and "none" or (entry.profile_kind or "pending")
        local ranks = entry.ranks
        table.insert(list, {
            name = entry.name,
            team = entry.team,
            platform = entry.platform,
            bot = entry.bot,
            me = my_id ~= nil and entry.id == my_id,
            rank_lookup = function(playlist)
                if kind ~= "ok" then return { kind = kind } end
                local rank = ranks and ranks[playlist.id]
                if not rank then return { kind = "nodata" } end
                return { kind = "ok", rank = rank }
            end,
        })
    end
    return list
end

local function example_players()
    local list = {}
    for _, ex in ipairs(EXAMPLE_PLAYERS) do
        table.insert(list, {
            name = ex.name, team = ex.team, platform = ex.platform, bot = ex.bot, me = ex.me,
            rank_lookup = function(playlist)
                local tier = (playlist.id % 2 == 0) and ex.ranks[1] or ex.ranks[2]
                return { kind = "ok", rank = {
                    tier_id = tier,
                    division_id = playlist.id % 4,
                    mmr = 150 + tier * 70 + playlist.id,
                    matches_played = 37 + tier * 11,
                } }
            end,
        })
    end
    return list
end

-- hebnix.measure_text builds a DirectWrite format + layout on every call, so
-- widths are memoized per (size, bold, text). Ranks/MMR/names repeat a lot.
local measure_cache = {}
local measure_entries = 0

local function measure(text, size, bold)
    local by_size = measure_cache[size]
    if not by_size then
        by_size = { [true] = {}, [false] = {} }
        measure_cache[size] = by_size
    end
    local by_weight = by_size[bold]
    local w = by_weight[text]
    if w then return w end
    if measure_entries >= 4096 then
        measure_cache, measure_entries = {}, 0
        return measure(text, size, bold)
    end
    w = hebnix.measure_text(text, size, bold)
    by_weight[text] = w
    measure_entries = measure_entries + 1
    return w
end

-- measure + lay out a model for a given screen size. Everything draw_model
-- needs from settings is resolved here so drawing a frame reads no settings.
local function layout_model(model, h)
    local size = hebnix.get_number(P .. "font_size", 16)
    if hebnix.get_bool(P .. "scale_res", true) then size = size * h / 1080 end
    size = math.max(8, size)
    local pad_x = size * 0.6
    local line_h = size * 1.35
    local block_pad = size * 0.25

    local widths = {}
    for c, column in ipairs(model.columns) do
        widths[c] = measure(column.header, size, true)
    end
    for _, block in ipairs(model.blocks) do
        for c, cell in ipairs(block.cells) do
            for _, line in ipairs(cell) do
                if line.text ~= "" then
                    local w = measure(line.text, size, line.bold == true)
                    if w > widths[c] then widths[c] = w end
                end
            end
        end
    end

    local total_w = 0
    for c = 1, #widths do
        widths[c] = widths[c] + pad_x * 2
        total_w = total_w + widths[c]
    end
    local header_h = line_h + block_pad * 2
    local block_h = model.lines * line_h + block_pad * 2
    model.size = size
    model.pad_x = pad_x
    model.line_h = line_h
    model.block_pad = block_pad
    model.widths = widths
    model.header_h = header_h
    model.block_h = block_h
    model.total_w = total_w
    model.total_h = header_h + block_h * #model.blocks

    local opacity = hebnix.get_number(P .. "bg_opacity", 200)
    model.px = hebnix.get_number(P .. "pos_x", 50) / 100
    model.py = hebnix.get_number(P .. "pos_y", 12) / 100
    model.ax = ANCHOR_FACTOR[hebnix.get_string(P .. "anchor_h", "Center")] or 0.5
    model.ay = ANCHOR_FACTOR[hebnix.get_string(P .. "anchor_v", "Top")] or 0
    model.header_bg = with_alpha(setting_color("header_bg"), opacity)
    model.header_fg = setting_color("header_fg")
    model.even_bg = with_alpha(setting_color("row_even"), opacity)
    model.odd_bg = with_alpha(setting_color("row_odd"), opacity)
    model.stripe_w = math.max(2, math.floor(size * 0.2))
    for _, block in ipairs(model.blocks) do
        if block.team == 0 or block.team == 1 then
            block.stripe = team_color(block.team, false)
        end
    end
    return model
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function draw_text_in(draw, x, w, y, line_h, line, align, pad_x, size)
    local text_h = size * 1.33 -- Segoe UI line box
    local ty = y + (line_h - text_h) / 2
    local tx, halign = x + pad_x, "left"
    if align == "center" then tx, halign = x + w / 2, "center"
    elseif align == "right" then tx, halign = x + w - pad_x, "right" end
    draw.text(tx, ty, line.text, { color = line.color, size = size, halign = halign, bold = line.bold == true })
end

local function draw_model(draw, model, w, h)
    if not model or #model.columns == 0 then return end
    local ox = math.floor(w * model.px - model.total_w * model.ax)
    local oy = math.floor(h * model.py - model.total_h * model.ay)

    -- header
    draw.rect(ox, oy, model.total_w, model.header_h, { filled = true, color = model.header_bg })
    local x = ox
    local header_fg = model.header_fg
    for c, column in ipairs(model.columns) do
        draw_text_in(draw, x, model.widths[c], oy + model.block_pad, model.line_h,
            { text = column.header, color = header_fg, bold = true },
            column.align, model.pad_x, model.size)
        x = x + model.widths[c]
    end

    -- player blocks
    local y = oy + model.header_h
    for b, block in ipairs(model.blocks) do
        draw.rect(ox, y, model.total_w, model.block_h,
            { filled = true, color = (b % 2 == 1) and model.even_bg or model.odd_bg })
        -- team stripe on the left edge
        if block.stripe then
            draw.rect(ox, y, model.stripe_w, model.block_h, { filled = true, color = block.stripe })
        end

        x = ox
        for c, cell in ipairs(block.cells) do
            local align = model.columns[c].align
            local inner_y = y + model.block_pad
            for l, line in ipairs(cell) do
                if line.text ~= "" then
                    local ly = line.vcenter
                        and (y + (model.block_h - model.line_h) / 2)
                        or (inner_y + (l - 1) * model.line_h)
                    draw_text_in(draw, x, model.widths[c], ly, model.line_h, line, align, model.pad_x, model.size)
                end
            end
            x = x + model.widths[c]
        end
        y = y + model.block_h
    end

    -- column separators
    x = ox
    for c = 1, #model.widths - 1 do
        x = x + model.widths[c]
        draw.line(x, oy, x, oy + model.total_h, { color = "#ffffff19", width = 1 })
    end
end

local function rebuild(w, h, preview)
    local playlists = selected_playlists()
    local show_mmr = hebnix.get_bool(P .. "show_mmr", true)
    local show_games = hebnix.get_bool(P .. "show_games", true)
    local show_platform = hebnix.get_bool(P .. "show_platform", false)
    local players = preview and example_players() or live_players()
    return layout_model(build_rows(players, playlists, show_mmr, show_games, show_platform), h)
end

---------------------------------------------------------------------------
-- Toggle bind
---------------------------------------------------------------------------

local function poll_toggle_bind()
    if capturing then
        local status, bind = hebnix.capture_bind_result()
        if status == "done" then
            hebnix.set(P .. "toggle_bind", bind or "")
            capturing = false
            toggle_was_pressed = true -- ignore the press that set it
        elseif status == "timeout" then
            capturing = false
        end
        return
    end
    local bind = hebnix.get_string(P .. "toggle_bind", "")
    if bind == "" then
        toggle_was_pressed = false
        return
    end
    local pressed = hebnix.is_bind_pressed(bind)
    if pressed and not toggle_was_pressed then toggled = not toggled end
    toggle_was_pressed = pressed
end

---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------

-- Draw from a cached layout; rebuild only when the data or screen size changed.
local function draw_overlay(draw, w, h)
    local preview = hebnix.get_bool(P .. "preview", false)
    if not preview and next(roster) == nil then return end
    local cache = preview and preview_cache or live_cache

    local now = hebnix.monotonic_seconds()
    local size_key = w * 100000 + h
    local age = now - (cache.built_at or -math.huge)
    local stale = not cache.model
        or cache.size_key ~= size_key
        or age >= REBUILD_SAFETY_INTERVAL
        or (cache.version ~= data_version and age >= REBUILD_MIN_INTERVAL)
    if stale then
        cache.model = rebuild(w, h, preview)
        cache.version, cache.size_key, cache.built_at = data_version, size_key, now
    end
    draw_model(draw, cache.model, w, h)
end

local function table_visible()
    if hebnix.get_bool(P .. "preview", false) then return true end
    if not hebnix.get_bool(P .. "enabled", true) then return false end
    if next(roster) == nil then return false end
    if toggled then return true end
    return hebnix.get_bool(P .. "with_scoreboard", true) and hebnix.is_action_pressed("scoreboard")
end

-- Hebnix repaints its own windows at the overlay refresh rate for as long as
-- any plugin defines on_tick or on_overlay while the game runs. So on_overlay
-- only exists while the table is on screen, and on_tick only while there is a
-- lobby to watch the scoreboard key for (or a key capture / preview in the
-- settings). on_tick runs just before the overlay render in the same host
-- frame, so showing the table adds no lag.
local function update_overlay_hook()
    plugin.on_overlay = table_visible() and draw_overlay or nil
end

local tick -- defined below

local function update_tick_hook()
    local want = next(roster) ~= nil or capturing or hebnix.get_bool(P .. "preview", false)
    plugin.on_tick = want and tick or nil
end

function plugin.on_load()
    hebnix.set(P .. "preview", false)
    plugin.on_overlay = nil
    plugin.on_tick = nil
    hebnix.log("Lobby Ranks " .. VERSION .. " loaded")
end

function plugin.on_unload()
    reset_roster()
    plugin.on_overlay = nil
    plugin.on_tick = nil
end

function plugin.on_game_event(event_type, event)
    local guid = event and (event.match_guid or event.MatchGuid)
    if guid and guid ~= "" and guid ~= match_guid then
        match_guid = guid
        reset_roster()
    end

    if event_type == "UpdateState" then
        update_roster(event)
    elseif event_type == "MatchCreated" or event_type == "MatchInitialized" then
        reset_roster()
    elseif event_type == "GameLeft" or event_type == "MatchDestroyed" or event_type == "GameDisconnected" then
        match_guid = nil
        reset_roster()
    end
    update_tick_hook()
    update_overlay_hook()
end

tick = function()
    poll_local_identity()
    poll_toggle_bind()

    -- poll profiles that haven't resolved yet; resolved ones are never polled again
    local now = hebnix.monotonic_seconds()
    if now >= next_profile_poll then
        next_profile_poll = now + PROFILE_POLL_INTERVAL
        for _, entry in pairs(roster) do
            if entry.profile_kind == "retry" then
                -- shows "..." either way, so the table doesn't need rebuilding
                if now >= entry.retry_at then
                    entry.profile_kind = "pending"
                    request_profile(entry)
                end
            elseif not entry.bot and entry.profile_kind ~= "ok" and entry.profile_kind ~= "error" then
                resolve_profile(entry)
                -- re-request profiles that vanished (e.g. cache cleared by another plugin)
                local kind = entry.profile_kind
                if (kind == "missing" or kind == "none") and now >= (entry.retry_at or 0) then
                    entry.retry_at = now + PROFILE_RETRY_INTERVAL
                    request_profile(entry)
                end
            end
        end
    end

    update_overlay_hook()
    update_tick_hook()
end

local function color_row(ui, key, label, default)
    ui.color_picker(key, label, default)
end

function plugin.on_settings(ui)
    -- settings may change while the panel is open; let the preview follow them
    mark_dirty()
    update_tick_hook() -- preview toggled / key capture started on the last frame
    update_overlay_hook()
    ui.heading("Lobby Ranks")
    ui.checkbox(P .. "enabled", "Enable Lobby Ranks", true)
    ui.checkbox(P .. "with_scoreboard", "Show while the scoreboard is held", true)

    ui.horizontal(function()
        local bind = hebnix.get_string(P .. "toggle_bind", "")
        ui.label("Toggle key: " .. (bind ~= "" and bind or "(none)"))
        if capturing then
            ui.colored_label("#d35400", "Press any key/button...")
        else
            if ui.button("Set") then
                if hebnix.capture_bind_async(10) then capturing = true end
            end
            if bind ~= "" and ui.button("Clear") then
                hebnix.set(P .. "toggle_bind", "")
                toggled = false
            end
        end
    end)
    ui.label("Table is currently " .. (toggled and "toggled ON" or "toggled off") .. " by the key.")
    ui.space(8)

    ui.heading("Columns")
    ui.checkbox(P .. "show_mmr", "Show MMR", true)
    ui.checkbox(P .. "show_games", "Show games played", true)
    ui.checkbox(P .. "show_division", "Show division (e.g. C2 D3)", true)
    ui.checkbox(P .. "show_platform", "Show platform", false)
    ui.space(4)
    ui.label("Playlists:")
    for _, playlist in ipairs(PLAYLISTS) do
        ui.checkbox(P .. "pl_" .. playlist.id, playlist.name, playlist.default)
    end
    ui.space(8)

    ui.heading("Position & size")
    ui.checkbox(P .. "preview", "Show preview table (example players)", false)
    ui.combo_box(P .. "anchor_h", "Horizontal anchor", ANCHORS_H)
    ui.combo_box(P .. "anchor_v", "Vertical anchor", ANCHORS_V)
    ui.slider(P .. "pos_x", "X position (% of screen)", 0, 100, 50)
    ui.slider(P .. "pos_y", "Y position (% of screen)", 0, 100, 12)
    ui.slider(P .. "font_size", "Font size", 8, 40, 16)
    ui.checkbox(P .. "scale_res", "Scale with resolution (size is for 1080p)", true)
    ui.slider(P .. "bg_opacity", "Background opacity", 0, 255, 200)
    ui.space(8)

    ui.collapsing("Table & team colors", function(ui)
        color_row(ui, P .. "c_header_bg", "Header background", DEFAULT_COLORS.header_bg)
        color_row(ui, P .. "c_header_fg", "Header text", DEFAULT_COLORS.header_fg)
        color_row(ui, P .. "c_row_even", "Row (even)", DEFAULT_COLORS.row_even)
        color_row(ui, P .. "c_row_odd", "Row (odd)", DEFAULT_COLORS.row_odd)
        color_row(ui, P .. "c_text", "Plain text", DEFAULT_COLORS.text)
        color_row(ui, P .. "c_team_blue", "Blue team", DEFAULT_COLORS.team_blue)
        color_row(ui, P .. "c_team_orange", "Orange team", DEFAULT_COLORS.team_orange)
        color_row(ui, P .. "c_self", "You", DEFAULT_COLORS.self)
    end)
    ui.collapsing("Rank colors", function(ui)
        for _, group in ipairs(RANK_GROUPS) do
            color_row(ui, P .. "rc_" .. group.key, group.label, group.color)
        end
    end)
    ui.collapsing("Platform colors", function(ui)
        for _, p in ipairs(PLATFORMS) do
            color_row(ui, P .. "pc_" .. p.key, p.label, p.color)
        end
    end)
    ui.space(8)

    local count, pending = 0, 0
    for _, entry in pairs(roster) do
        count = count + 1
        local kind = entry.profile_kind
        if not entry.bot and (kind == nil or kind == "pending" or kind == "missing" or kind == "retry") then pending = pending + 1 end
    end
    ui.label(string.format("Players tracked: %d (%d profiles loading)", count, pending))
    if ui.button("Refresh ranks (clear profile cache)") then
        hebnix.clear_stats_cache()
        for _, entry in pairs(roster) do
            entry.profile_kind, entry.ranks, entry.retry_at, entry.failures = nil, nil, nil, nil
            request_profile(entry)
        end
        mark_dirty()
    end
    ui.space(4)
    ui.label("Lobby Ranks " .. VERSION .. " - inspired by GrantJL's BakkesMod plugin")
end

return plugin
