-- rule_loader.lua
-- Hot-reload rules from rules.json into lua_shared_dict "rules".
--
-- This module is loaded once per OpenResty worker via init_worker_by_lua_block.
-- It performs an immediate synchronous load on startup, then schedules a
-- recurring background timer (every RELOAD_INTERVAL seconds) that checks
-- whether rules.json has changed and, if so, validates and atomically
-- writes the new rule set into the shared dictionary.
--
-- Design principles:
--   • No file I/O occurs in the hot path (access_by_lua_block). All I/O
--     happens exclusively in the background timer callback.
--   • JSON is validated (cjson.decode) before writing to the shared dict,
--     so a partial write or invalid file never poisons the live rule set.
--   • If the file is missing or unparseable, an error is logged and the
--     previous rules remain active (fail-safe, not fail-open).
--   • mtime comparison avoids unnecessary parse/write cycles on every tick.
--   • LuaFileSystem (lfs) is used for file stat to avoid shell injection.

local cjson = require("cjson.safe")

-- LuaFileSystem is bundled with OpenResty; prefer it over io.popen/stat.
local lfs_ok, lfs = pcall(require, "lfs")

-- Path to the rules configuration file (mounted via docker volume).
local RULES_FILE = "/etc/rules.json"

-- How often (seconds) to poll for changes.
local RELOAD_INTERVAL = 10

-- Per-worker last-known mtime value; avoids redundant reloads.
local last_mtime = nil

-- ---------------------------------------------------------------------------
-- read_file(path)
-- Opens path, reads all content, and returns it as a string.
-- Returns nil, errmsg on any failure.
-- ---------------------------------------------------------------------------
local function read_file(path)
    local f, open_err = io.open(path, "r")
    if not f then
        return nil, "cannot open '" .. path .. "': " .. (open_err or "unknown")
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return nil, "file is empty: " .. path
    end
    return content, nil
end

-- ---------------------------------------------------------------------------
-- get_mtime(path)
-- Returns the file modification time as a number (via LuaFileSystem) or as a
-- string (via POSIX stat -c %Y fallback).  Returns nil when unavailable.
-- Using lfs avoids constructing a shell command from a path string.
-- ---------------------------------------------------------------------------
local function get_mtime(path)
    if lfs_ok then
        local attrs = lfs.attributes(path)
        return attrs and tostring(attrs.modification) or nil
    end
    -- Fallback: use a fixed, hardcoded shell command (no user-supplied data).
    -- This branch is only reached if lfs is unexpectedly absent.
    local handle = io.popen("stat -c %Y /etc/rules.json 2>/dev/null")
    if not handle then
        return nil
    end
    local result = handle:read("*l")
    handle:close()
    if result then
        result = result:match("^%s*(.-)%s*$")
    end
    return (result ~= "" and result) or nil
end

-- ---------------------------------------------------------------------------
-- load_rules_from_disk()
-- Reads, validates, and atomically writes rules.json to the shared dict.
-- Returns true on success, false on any failure (error is logged).
-- ---------------------------------------------------------------------------
local function load_rules_from_disk()
    local content, read_err = read_file(RULES_FILE)
    if not content then
        ngx.log(ngx.ERR, "[rule_loader] file read failed: " .. (read_err or "unknown"))
        return false
    end

    -- Validate JSON before touching the shared dict (atomic reload safety).
    local rules, parse_err = cjson.decode(content)
    if not rules then
        ngx.log(ngx.ERR, "[rule_loader] JSON parse error in '" .. RULES_FILE ..
                "': " .. (parse_err or "unknown"))
        return false
    end
    if type(rules) ~= "table" then
        ngx.log(ngx.ERR, "[rule_loader] rules.json must be a JSON object, got: " ..
                type(rules))
        return false
    end
    -- Reject JSON arrays (integer-keyed tables are not valid rule sets).
    local first_key = next(rules)
    if type(first_key) == "number" then
        ngx.log(ngx.ERR, "[rule_loader] rules.json must be a JSON object, not an array")
        return false
    end

    -- Write the validated JSON string to the shared dict.
    local ok, set_err = ngx.shared.rules:set("rules", content)
    if not ok then
        ngx.log(ngx.ERR, "[rule_loader] shared dict write error: " .. (set_err or "unknown"))
        return false
    end

    ngx.log(ngx.INFO, "[rule_loader] rules reloaded from " .. RULES_FILE)
    return true
end

-- ---------------------------------------------------------------------------
-- reload_rules(premature)
-- Timer callback: checks mtime, reloads on change, reschedules itself.
-- ---------------------------------------------------------------------------
local function reload_rules(premature)
    -- premature == true when nginx is shutting down; do not reschedule.
    if premature then
        return
    end

    local mtime = get_mtime(RULES_FILE)
    if mtime ~= last_mtime then
        local ok = load_rules_from_disk()
        if ok then
            last_mtime = mtime
        end
    end

    -- Schedule the next check.
    local timer_ok, timer_err = ngx.timer.at(RELOAD_INTERVAL, reload_rules)
    if not timer_ok then
        ngx.log(ngx.ERR, "[rule_loader] failed to schedule next reload: " ..
                (timer_err or "unknown"))
    end
end

-- ---------------------------------------------------------------------------
-- Bootstrap: immediate load + start the periodic timer.
-- Called once per worker from init_worker_by_lua_block in nginx.conf.
-- ---------------------------------------------------------------------------
local ok = load_rules_from_disk()
if ok then
    last_mtime = get_mtime(RULES_FILE)
end

local timer_ok, timer_err = ngx.timer.at(RELOAD_INTERVAL, reload_rules)
if not timer_ok then
    ngx.log(ngx.ERR, "[rule_loader] failed to start initial reload timer: " ..
            (timer_err or "unknown"))
end

