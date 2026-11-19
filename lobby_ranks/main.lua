-- Lobby Ranks for Hebnix
-- Port of GrantJL's BakkesMod "Lobby Ranks" plugin (https://github.com/GrantJL/rl-lobby-ranks).
-- Shows a table of every player in the current match with their rank, MMR and
-- games played across a configurable set of playlists.
--
-- Data sources:
--   * players  : StatsAPI "UpdateState" events (Players[].Name/PrimaryId/TeamNum)
--   * ranks    : hebnix.fetch_profile_async / hebnix.stats_result (tracker profiles)
--   * local id : Launch.log (to highlight your own row)

local plugin = {}

local VERSION = "2.0.0"
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

-- rank colour groups: key, label, default, tier range
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
local roster_seq = 0
local match_guid = nil
local my_id = nil
local log_key = nil
local log_retry_at = 0
local next_profile_poll = 0

local toggled = false      -- toggle bind state (like jlg_lobby_rank_toggle)
local toggle_was_pressed = false
local capturing = false

local cached_table = nil   -- built layout
local cached_preview = nil
local last_build = -1
local last_size = ""

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

local function profile_of(entry)
    if entry.bot or not entry.request_key then return nil, "none" end
    local result = hebnix.stats_result(entry.request_key)
    if result == nil then return nil, "missing" end
    if result == "pending" then return nil, "pending" end
    if type(result) ~= "table" then return nil, "missing" end
    if result.error or result.not_found then return nil, "error" end
    return result, "ok"
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
    roster_seq = 0
    cached_table = nil
end

local function update_roster(event)
    local data = event and (event.data or event.Data)
    local players = type(data) == "table" and (data.Players or data.players) or nil
    if type(players) ~= "table" then return end

    local seen = {}
    for _, player in ipairs(players) do
        local id = tostring(player.PrimaryId or player.primary_id or "")
        local name = tostring(player.Name or player.name or "Unknown")
        local bot = id == "" or hebnix.is_bot(id)
        local key = bot and ("bot:" .. name) or id
        seen[key] = true

        local entry = roster[key]
        if not entry then
            roster_seq = roster_seq + 1
            entry = { order = roster_seq, id = id, name = name, bot = bot }
            roster[key] = entry
            local platform = split_primary_id(id)
            entry.platform = platform or ""
            request_profile(entry)
        end
        entry.name = name
        entry.score = tonumber(player.Score or player.score) or 0
        local team = tonumber(player.TeamNum or player.team_num)
        entry.team = (team == 0 or team == 1) and team or -1
    end

    -- players that left are dropped (the original refreshed on PRI destroy)
    for key in pairs(roster) do
        if not seen[key] then roster[key] = nil end
    end
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
    else
        log_retry_at = now + 10
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
                local symbol = ({ pending = "...", error = "?", none = "", nodata = "-", missing = "..." })[r.kind] or ""
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
        local stats, kind = profile_of(entry)
        table.insert(list, {
            name = entry.name,
            team = entry.team,
            platform = entry.platform,
            bot = entry.bot,
            me = my_id ~= nil and entry.id == my_id,
            rank_lookup = function(playlist)
                if kind ~= "ok" then return { kind = kind } end
                local rank = rank_for(stats, playlist)
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

-- measure + lay out a model for a given screen size
local function layout_model(model, h)
    local size = hebnix.get_number(P .. "font_size", 16)
    if hebnix.get_bool(P .. "scale_res", true) then size = size * h / 1080 end
    size = math.max(8, size)
    local pad_x = size * 0.6
    local line_h = size * 1.35
    local block_pad = size * 0.25

    local widths = {}
    for c, column in ipairs(model.columns) do
        widths[c] = hebnix.measure_text(column.header, size, true)
    end
    for _, block in ipairs(model.blocks) do
        for c, cell in ipairs(block.cells) do
            for _, line in ipairs(cell) do
                if line.text ~= "" then
                    local w = hebnix.measure_text(line.text, size, line.bold == true)
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
    local opacity = hebnix.get_number(P .. "bg_opacity", 200)

    local px = hebnix.get_number(P .. "pos_x", 50) / 100
    local py = hebnix.get_number(P .. "pos_y", 12) / 100
    local ax = ANCHOR_FACTOR[hebnix.get_string(P .. "anchor_h", "Center")] or 0.5
    local ay = ANCHOR_FACTOR[hebnix.get_string(P .. "anchor_v", "Top")] or 0
    local ox = math.floor(w * px - model.total_w * ax)
    local oy = math.floor(h * py - model.total_h * ay)

    -- header
    draw.rect(ox, oy, model.total_w, model.header_h,
        { filled = true, color = with_alpha(setting_color("header_bg"), opacity) })
    local x = ox
    local header_fg = setting_color("header_fg")
    for c, column in ipairs(model.columns) do
        draw_text_in(draw, x, model.widths[c], oy + model.block_pad, model.line_h,
            { text = column.header, color = header_fg, bold = true },
            column.align, model.pad_x, model.size)
        x = x + model.widths[c]
    end

    -- player blocks
    local even_bg = with_alpha(setting_color("row_even"), opacity)
    local odd_bg = with_alpha(setting_color("row_odd"), opacity)
    local stripe_w = math.max(2, math.floor(model.size * 0.2))
    local y = oy + model.header_h
    for b, block in ipairs(model.blocks) do
        draw.rect(ox, y, model.total_w, model.block_h,
            { filled = true, color = (b % 2 == 1) and even_bg or odd_bg })
        -- team stripe on the left edge
        if block.team == 0 or block.team == 1 then
            draw.rect(ox, y, stripe_w, model.block_h,
                { filled = true, color = team_color(block.team, false) })
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

function plugin.on_load()
    hebnix.set(P .. "preview", false)
    hebnix.log("Lobby Ranks " .. VERSION .. " loaded")
end

function plugin.on_unload()
    reset_roster()
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
end

function plugin.on_tick()
    poll_local_identity()
    poll_toggle_bind()

    -- re-request profiles that vanished (e.g. cache cleared by another plugin)
    local now = hebnix.monotonic_seconds()
    if now >= next_profile_poll then
        next_profile_poll = now + 2
        for _, entry in pairs(roster) do
            if not entry.bot then
                local _, kind = profile_of(entry)
                if kind == "missing" or kind == "none" then request_profile(entry) end
            end
        end
    end
end

function plugin.on_overlay(draw, w, h)
    local now = hebnix.monotonic_seconds()
    local size_key = w .. "x" .. h
    local stale = (now - last_build) > 0.5 or size_key ~= last_size

    if hebnix.get_bool(P .. "preview", false) then
        if stale or not cached_preview then
            cached_preview = rebuild(w, h, true)
            last_build, last_size = now, size_key
        end
        draw_model(draw, cached_preview, w, h)
        return
    end

    if not hebnix.get_bool(P .. "enabled", true) then return end
    if next(roster) == nil then return end

    local scoreboard = hebnix.get_bool(P .. "with_scoreboard", true) and hebnix.is_action_pressed("scoreboard")
    if not (toggled or scoreboard) then return end

    if stale or not cached_table then
        cached_table = rebuild(w, h, false)
        last_build, last_size = now, size_key
    end
    draw_model(draw, cached_table, w, h)
end

local function color_row(ui, key, label, default)
    ui.color_picker(key, label, default)
end

function plugin.on_settings(ui)
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

    ui.collapsing("Table & team colours", function(ui)
        color_row(ui, P .. "c_header_bg", "Header background", DEFAULT_COLORS.header_bg)
        color_row(ui, P .. "c_header_fg", "Header text", DEFAULT_COLORS.header_fg)
        color_row(ui, P .. "c_row_even", "Row (even)", DEFAULT_COLORS.row_even)
        color_row(ui, P .. "c_row_odd", "Row (odd)", DEFAULT_COLORS.row_odd)
        color_row(ui, P .. "c_text", "Plain text", DEFAULT_COLORS.text)
        color_row(ui, P .. "c_team_blue", "Blue team", DEFAULT_COLORS.team_blue)
        color_row(ui, P .. "c_team_orange", "Orange team", DEFAULT_COLORS.team_orange)
        color_row(ui, P .. "c_self", "You", DEFAULT_COLORS.self)
    end)
    ui.collapsing("Rank colours", function(ui)
        for _, group in ipairs(RANK_GROUPS) do
            color_row(ui, P .. "rc_" .. group.key, group.label, group.color)
        end
    end)
    ui.collapsing("Platform colours", function(ui)
        for _, p in ipairs(PLATFORMS) do
            color_row(ui, P .. "pc_" .. p.key, p.label, p.color)
        end
    end)
    ui.space(8)

    local count, pending = 0, 0
    for _, entry in pairs(roster) do
        count = count + 1
        local _, kind = profile_of(entry)
        if kind == "pending" or kind == "missing" then pending = pending + 1 end
    end
    ui.label(string.format("Players tracked: %d (%d profiles loading)", count, pending))
    if ui.button("Refresh ranks (clear profile cache)") then
        hebnix.clear_stats_cache()
        for _, entry in pairs(roster) do request_profile(entry) end
    end
    ui.space(4)
    ui.label("Lobby Ranks " .. VERSION .. " - port of GrantJL's BakkesMod plugin")
end

return plugin
