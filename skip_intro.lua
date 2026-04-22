-- ============================================================
--  skip_intro.lua — MPV script pour passer les intros de series
--
--  APIs utilisees (100% gratuites, sans cle API) :
--    1. TVMaze API   (api.tvmaze.com)  -> imdbID + numero relatif
--    2. IntroDB API  (api.introdb.app) -> timestamps intro
--
--  Logique de conversion episode absolu -> relatif :
--    - Saison   : extraite du DOSSIER parent  (ex: S16)
--    - Episode  : numero relatif via TVMaze   (ex: E23)
--
--  INSTALLATION :
--    Linux/macOS : ~/.config/mpv/scripts/skip_intro.lua
--    Windows     : %APPDATA%\mpv\scripts\skip_intro.lua
--
--  CONFIGURATION (optionnelle) :
--    Fichier : ~/.config/mpv/script-opts/skip_intro.conf
--    IMPORTANT : pas de commentaires inline sur les lignes de valeur
--
--    Exemple :
--      auto_skip=yes
--      osd_duration=5
--      debug=no
-- ============================================================

local mp      = require("mp")
local msg     = require("mp.msg")
local utils   = require("mp.utils")
local options = require("mp.options")

-- ── Options ────────────────────────────────────────────────
local opts = {
    auto_skip    = true,
    osd_duration = 5,
    debug        = false,
}
options.read_options(opts, "skip_intro")

-- ── Endpoints ──────────────────────────────────────────────
local TVMAZE_SEARCH   = "https://api.tvmaze.com/search/shows?q=%s"
local TVMAZE_EPISODES = "https://api.tvmaze.com/shows/%d/episodes"
local INTRODB_URL = "https://api.introdb.app/segments?imdb_id=%s&season=%d&episode=%d&segment_type=intro"

-- ── Etat global ────────────────────────────────────────────
local intro_start = nil
local intro_end   = nil
local skip_shown  = false

-- ── Logging ────────────────────────────────────────────────
local function log(level, fmt, ...)
    if level == "debug" and not opts.debug then return end
    local fn = ({ debug=msg.debug, info=msg.info,
                  warn=msg.warn,   error=msg.error })[level] or msg.info
    fn(string.format(fmt, ...))
end

-- ── URL encoding ───────────────────────────────────────────
local function urlencode(s)
    s = tostring(s):gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return s:gsub(" ", "+")
end

-- ── HTTP GET synchrone via curl ────────────────────────────
local function http_get(url)
    log("debug", "GET -> %s", url)
    local res = utils.subprocess({
        args = {
            "curl", "-fsSL",
            "--max-time", "15",
            "--user-agent", "mpv-skip-intro/1.0",
            url,
        },
        capture_stdout = true,
        capture_stderr = true,
    })
    if res.status ~= 0 then
        log("warn", "curl erreur (code %d) : %s",
            res.status, (res.stderr or ""):match("^[^\n]*") or "")
        return nil
    end
    log("debug", "Reponse : %s", res.stdout)
    return res.stdout
end

-- ── Extraction JSON minimale ────────────────────────────────
local function jget_num(json, key)
    local v = json:match('"' .. key .. '"%s*:%s*(%-?%d+%.?%d*)')
    return v and tonumber(v) or nil
end

local function jget_str(json, key)
    return json:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

-- ── Nettoyage du nom de serie ───────────────────────────────
local function clean_show_name(raw)
    local s = raw or ""
    s = s:gsub("%d%d%d%d?[pP].*",               "")
    s = s:gsub("[Bb]lu[Rr]ay.*",                 "")
    s = s:gsub("[Hh][Dd][Rr][Ii][Pp].*",        "")
    s = s:gsub("[Ww][Ee][Bb]%-?[Dd][Ll].*",     "")
    s = s:gsub("[Ww][Ee][Bb]%-?[Rr][Ii][Pp].*", "")
    s = s:gsub("[Mm][Uu][Ll][Tt][Ii].*",        "")
    s = s:gsub("[Xx]26[45].*",                  "")
    s = s:gsub("[Aa][Mm][Bb]%d+.*",             "")
    s = s:gsub("[%.%_%-]+", " ")
    s = s:match("^%s*(.-)%s*$")
    return s
end

-- ── Parsing du chemin complet ───────────────────────────────
local function parse_filepath(path)
    local folder   = path:match("^(.*)[/\\][^/\\]+$") or ""
    local filename = (path:match("([^/\\]+)$") or path):gsub("%.[^%.]+$", "")

    log("debug", "Dossier  : %s", folder)
    log("debug", "Fichier  : %s", filename)

    local folder_season_str = folder:match("[Ss](%d+)")
    local folder_season     = folder_season_str and tonumber(folder_season_str) or nil

    local show_raw, file_season, episode
    local is_absolute = false

    local s, e = filename:match("[Ss](%d+)[Ee](%d+)")
    if s then
        file_season  = tonumber(s)
        episode      = tonumber(e)
        show_raw     = filename:gsub("[Ss]%d+[Ee]%d+.*", "")
        is_absolute  = false
    end

    if not file_season then
        s, e = filename:match("(%d+)x(%d+)")
        if s then
            file_season  = tonumber(s)
            episode      = tonumber(e)
            show_raw     = filename:gsub("%d+x%d+.*", "")
            is_absolute  = false
        end
    end

    if not file_season then
        e = filename:match("[Ee](%d+)")
        if e then
            episode      = tonumber(e)
            show_raw     = filename:gsub("[Ee]%d+.*", "")
            is_absolute  = true
        end
    end

    if not episode then
        log("warn", "Impossible d'extraire l'episode de : %s", filename)
        return nil, nil, nil, nil
    end

    local final_season = folder_season or file_season or 1

    local show = clean_show_name(show_raw)
    if #show < 2 then
        local folder_name = (folder:match("([^/\\]+)$") or "")
        folder_name = folder_name:gsub("[Ss]%d+.*", "")
        folder_name = folder_name:gsub("[Aa]rc%s+.*", "")
        show = clean_show_name(folder_name)
        log("debug", "Nom depuis dossier : '%s'", show)
    end
    if #show < 2 then
        log("warn", "Nom de serie introuvable")
        return nil, nil, nil, nil
    end

    log("info", "Parsing -> serie='%s'  saison=%d  episode=%d  absolu=%s",
        show, final_season, episode, tostring(is_absolute))
    return show, final_season, episode, is_absolute
end

-- ── TVMaze : recherche → TVMaze show ID + imdbID ───────────
--
--  Priorites de selection :
--    1. Correspondance exacte du nom (insensible a la casse)
--    2. Parmi les correspondances exactes, le show le plus recent
--    3. Si aucune correspondance exacte, premier resultat avec IMDB ID valide
--       (le plus recent en premier)
--
local function tvmaze_search(show_name)
    local url  = string.format(TVMAZE_SEARCH, urlencode(show_name))
    local body = http_get(url)
    if not body or body == "" then return nil, nil end

    local search_lower = show_name:lower()
    local candidates   = {}

    for show_block in body:gmatch('"show"%s*:%s*(%b{})') do
        local id_str    = show_block:match('"id"%s*:%s*(%d+)')
        local tvmaze_id = id_str and tonumber(id_str) or nil
        local imdb      = jget_str(show_block, "imdb")
        local premiered = jget_str(show_block, "premiered") or "0000"
        local stype     = jget_str(show_block, "type") or ""
        local name      = jget_str(show_block, "name") or ""
        local year      = tonumber(premiered:match("^(%d%d%d%d)")) or 0

        log("debug", "  TVMaze candidat: id=%s '%s' (%s %d) imdb=%s",
            tostring(tvmaze_id), name, stype, year, imdb or "nil")

        if tvmaze_id and imdb and imdb:match("^tt%d+") then
            local exact = (name:lower() == search_lower)
            table.insert(candidates, {
                tvmaze_id = tvmaze_id,
                imdb      = imdb,
                name      = name,
                year      = year,
                stype     = stype,
                exact     = exact,
            })
        end
    end

    if #candidates == 0 then
        log("warn", "TVMaze : aucun resultat valide pour '%s'", show_name)
        return nil, nil
    end

    -- Tri : correspondances exactes d'abord, puis par annee decroissante
    -- Le show le plus recent prime (evite de choisir un vieux homonyme)
    table.sort(candidates, function(a, b)
        if a.exact ~= b.exact then
            return a.exact  -- true (exact) avant false (non-exact)
        end
        return a.year > b.year  -- plus recent en premier
    end)

    local best = candidates[1]
    log("info", "TVMaze -> id=%d  imdbID=%s  '%s'  %s  annee=%d  exact=%s",
        best.tvmaze_id, best.imdb, best.name, best.stype,
        best.year, tostring(best.exact))

    if not best.exact then
        log("warn", "TVMaze : pas de correspondance exacte pour '%s' -> utilise '%s' (%d)",
            show_name, best.name, best.year)
    end

    return best.tvmaze_id, best.imdb
end

-- ── TVMaze : episode absolu → numero RELATIF ───────────────
local function tvmaze_get_relative_ep(tvmaze_id, abs_episode)
    local url  = string.format(TVMAZE_EPISODES, tvmaze_id)
    local body = http_get(url)
    if not body or body == "" then return nil end

    local index = 0
    for ep_block in body:gmatch('%b{}') do
        local ss = ep_block:match('"season"%s*:%s*(%d+)')
        local nn = ep_block:match('"number"%s*:%s*(%d+)')
        local season_n  = ss and tonumber(ss) or nil
        local episode_n = nn and tonumber(nn) or nil

        if season_n and episode_n and season_n > 0 and episode_n > 0 then
            index = index + 1
            if index == abs_episode then
                log("info",
                    "TVMaze : E%d absolu = episode relatif %d (groupe TVMaze S%d)",
                    abs_episode, episode_n, season_n)
                return episode_n
            end
        end
    end

    log("warn", "TVMaze : episode absolu %d introuvable (total = %d)",
        abs_episode, index)
    return nil
end

-- ── IntroDB : timestamps intro ─────────────────────────────
local function fetch_intro_timestamps(imdb_id, season, episode)
    local url  = string.format(INTRODB_URL, imdb_id, season, episode)
    local body = http_get(url)
    if not body or body == "" then return nil, nil end

    if body:match('"intro"%s*:%s*null') then
        log("info", "IntroDB : intro = null pour %s S%02dE%02d",
            imdb_id, season, episode)
        return nil, nil
    end

    local intro_block = body:match('"intro"%s*:%s*(%b{})')
    if not intro_block then
        log("info", "IntroDB : pas de bloc intro pour %s S%02dE%02d",
            imdb_id, season, episode)
        log("debug", "Corps recu : %s", body)
        return nil, nil
    end

    local t_start = jget_num(intro_block, "start_sec")
    local t_end   = jget_num(intro_block, "end_sec")

    if t_start and t_end then
        log("info", "IntroDB -> intro %.3fs -- %.3fs", t_start, t_end)
    else
        log("warn", "IntroDB : start_sec/end_sec manquants dans le bloc intro")
        log("debug", "Bloc intro : %s", intro_block)
    end
    return t_start, t_end
end

-- ── OSD ────────────────────────────────────────────────────
local function hide_osd()
    mp.osd_message("", 0)
    skip_shown = false
end

local function show_skip_banner()
    if skip_shown then return end
    skip_shown = true
    mp.osd_message("[i]  Passer l'intro", opts.osd_duration)
    mp.add_timeout(opts.osd_duration, function()
        if skip_shown then hide_osd() end
    end)
end

local function do_skip()
    if not intro_end then
        mp.osd_message("Aucune donnee d'intro disponible", 3)
        return
    end
    log("info", "Skip -> seek %.3fs", intro_end)
    mp.commandv("seek", tostring(intro_end), "absolute")
    mp.osd_message("Intro passee", 2)
    hide_osd()
end

-- ── Surveillance position ───────────────────────────────────
local function on_time_pos(_, time)
    if not time or not intro_start or not intro_end then return end
    if time >= intro_start and time < intro_end then
        if opts.auto_skip then do_skip() else show_skip_banner() end
    elseif time >= intro_end and skip_shown then
        hide_osd()
    end
end

-- ── Chargement d'un nouveau fichier ────────────────────────
local function on_file_loaded()
    intro_start = nil
    intro_end   = nil
    skip_shown  = false

    local path = mp.get_property("path")
    if not path then return end

    log("info", "Fichier charge : %s", path)

    local show_name, folder_season, episode, is_absolute = parse_filepath(path)
    if not show_name then
        log("warn", "Serie non reconnue -- skip_intro desactive")
        return
    end

    mp.add_timeout(0, function()
        local tvmaze_id, imdb_id = tvmaze_search(show_name)
        if not imdb_id then return end

        local final_season  = folder_season
        local final_episode = episode

        if is_absolute then
            log("info", "Conversion E%d absolu -> relatif via TVMaze...", episode)
            local rel_ep = tvmaze_get_relative_ep(tvmaze_id, episode)
            if rel_ep then
                final_episode = rel_ep
                log("info", "-> S%02dE%02d envoye a IntroDB",
                    final_season, final_episode)
            else
                log("warn", "Conversion echouee, tentative avec episode brut E%d",
                    episode)
            end
        end

        local t_start, t_end =
            fetch_intro_timestamps(imdb_id, final_season, final_episode)
        if not t_start or not t_end then return end

        intro_start = t_start
        intro_end   = t_end

        local pos = mp.get_property_number("time-pos") or 0
        if pos >= intro_start and pos < intro_end then
            if opts.auto_skip then do_skip() else show_skip_banner() end
        else
            mp.osd_message(
                string.format("Intro : %.0fs -- %.0fs", intro_start, intro_end), 3)
        end
    end)
end

-- ── Raccourci & evenements ─────────────────────────────────
mp.add_key_binding("i", "skip-intro-manual", do_skip)
mp.register_event("file-loaded", on_file_loaded)
mp.observe_property("time-pos", "number", on_time_pos)

log("info", "skip_intro.lua charge -- auto_skip=%s | [i] pour skip manuel",
    tostring(opts.auto_skip))