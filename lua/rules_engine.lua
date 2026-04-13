-- rules_engine.lua
-- Pure rule evaluation module for Agent Provost.
--
-- Checks a decoded MCP request body against a rules table sourced from
-- lua_shared_dict (populated by rule_loader.lua). This module has no I/O
-- or OpenResty dependencies and can be required in both OpenResty workers
-- and busted unit tests.
--
-- Usage (in access_by_lua_block):
--   local engine  = require("rules_engine")
--   local cjson   = require("cjson.safe")
--   local raw     = ngx.shared.rules:get("rules")
--   local rules   = raw and cjson.decode(raw) or {}
--   local blocked, reason = engine.check_request(parsed, rules)
--   if blocked then ... end

local _M = {}

-- Fallback limit used when max_trade_size rule is enabled but params.limit
-- is absent or non-numeric.
local DEFAULT_TRADE_SIZE_LIMIT = 100

local function get_tool_name(parsed)
    if type(parsed) ~= "table" then
        return nil
    end

    if parsed.method == "tools/call"
       and type(parsed.params) == "table"
       and type(parsed.params.name) == "string" then
        return parsed.params.name
    end

    if type(parsed.method) == "string" then
        return parsed.method
    end

    return nil
end

local function normalize_quantity(args)
    if type(args) ~= "table" then
        return nil
    end

    return tonumber(args.quantity)
        or tonumber(args.qty)
        or tonumber(args.order_quantity)
end

local function normalize_ticker(args)
    if type(args) ~= "table" then
        return ""
    end

    return tostring(args.ticker
        or args.symbol
        or args.symbol_or_asset_id
        or "")
end

-- check_request evaluates a decoded request body against the rules table.
--
-- @param  parsed  table|nil  Decoded JSON request body (output of cjson.decode).
-- @param  rules   table|nil  Rules table from shared dict.  Nil is treated as
--                            an empty table (fail-open: no rules applied).
-- @return blocked bool       true when the request must be blocked.
-- @return reason  string|nil Human-readable PROVOST_INTERVENTION message, or
--                            nil when not blocked.
function _M.check_request(parsed, rules)
    rules = rules or {}

local function normalize_notional(args)
    if type(args) ~= "table" then
        return nil
    end
    return tonumber(args.notional)
end

local function normalize_limit_price(args)
    if type(args) ~= "table" then
        return nil
    end
    return tonumber(args.limit_price)
end

-- check_request evaluates a decoded request body against the rules table.
    -- No parseable body or wrong shape: pass through.
    if not parsed
       or type(parsed.params) ~= "table"
       or type(parsed.params.arguments) ~= "table" then
        return false, nil
    end

    local args = parsed.params.arguments

    local tool_name = get_tool_name(parsed)

    -- ----------------------------------------------------------------
    -- Rule: max_trade_size
    -- Blocks requests where qty/quantity exceeds the configured limit.
    -- ----------------------------------------------------------------
    local size_rule = rules.max_trade_size
    if type(size_rule) == "table" and size_rule.enabled == true then
        local limit = DEFAULT_TRADE_SIZE_LIMIT
        if type(size_rule.params) == "table"
           and type(size_rule.params.limit) == "number" then
            limit = size_rule.params.limit
        end
        local qty = normalize_quantity(args)
        if qty ~= nil and qty > limit then
            return true,
                "PROVOST_INTERVENTION: Risk Limit Exceeded. " ..
                "Attempted trade size too large. Blocked to protect capital."
        end

        -- Check for notional (dollar-based) orders
        local notional = normalize_notional(args)
        if notional ~= nil and notional > 0 then
            local limit_price = normalize_limit_price(args)
            if limit_price ~= nil and limit_price > 0 then
                local estimated_qty = notional / limit_price
                if estimated_qty > limit then
                    return true,
                        "PROVOST_INTERVENTION: Risk Limit Exceeded. " ..
                        "Notional order estimated at " .. string.format("%.2f", estimated_qty) ..
                        " shares exceeds limit of " .. limit .. "."
                end
            else
                return true,
                    "PROVOST_INTERVENTION: Risk Limit Exceeded. " ..
                    "Notional orders require limit_price for safe evaluation."
            end
        end
    end
    -- ----------------------------------------------------------------
    -- Rule: blocked_tool_names
    -- Blocks requests whose tool name is explicitly restricted.
    -- ----------------------------------------------------------------
    local tool_rule = rules.blocked_tool_names
    if type(tool_rule) == "table" and tool_rule.enabled == true
       and type(tool_rule.params) == "table"
       and type(tool_rule.params.tools) == "table"
       and tool_name ~= nil then
        for _, blocked_tool in ipairs(tool_rule.params.tools) do
            if tool_name == tostring(blocked_tool) then
                return true,
                    "PROVOST_INTERVENTION: Tool '" .. tool_name ..
                    "' is on the restricted list."
            end
        end
    end

    -- ----------------------------------------------------------------
    -- Rule: restricted_ticker_tool_rules
    -- Blocks restricted symbols when used by specific order tools.
    -- ----------------------------------------------------------------
    local restricted_tool_rule = rules.restricted_ticker_tool_rules
    if type(restricted_tool_rule) == "table" and restricted_tool_rule.enabled == true
       and type(restricted_tool_rule.params) == "table"
       and type(restricted_tool_rule.params.tools) == "table"
       and type(restricted_tool_rule.params.tickers) == "table"
       and tool_name ~= nil then
        local ticker = normalize_ticker(args)
        if ticker ~= "" then
            for _, blocked_tool in ipairs(restricted_tool_rule.params.tools) do
                if tool_name == tostring(blocked_tool) then
                    for _, blocked_sym in ipairs(restricted_tool_rule.params.tickers) do
                        if ticker == tostring(blocked_sym) then
                            return true,
                                "PROVOST_INTERVENTION: Restricted symbol '" .. ticker ..
                                "' blocked for tool '" .. tool_name .. "'."
                        end
                    end
                end
            end
        end
    end

    -- ----------------------------------------------------------------
    -- Rule: blocked_tickers
    -- Blocks requests whose ticker field matches the restricted list.
    -- ----------------------------------------------------------------
    local ticker_rule = rules.blocked_tickers
    if type(ticker_rule) == "table" and ticker_rule.enabled == true then
        local ticker = normalize_ticker(args)
        if type(ticker_rule.params) == "table"
           and type(ticker_rule.params.tickers) == "table" then
            for _, blocked_sym in ipairs(ticker_rule.params.tickers) do
                if ticker == tostring(blocked_sym) then
                    return true,
                        "PROVOST_INTERVENTION: Ticker '" .. ticker ..
                        "' is on the restricted list."
                end
            end
        end
    end

    -- ----------------------------------------------------------------
    -- Rule: trading_window  (placeholder — disabled by default)
    -- Blocks requests outside allowed UTC trading hours.
    -- Requires ngx.time(); skipped when ngx is not available.
    -- ----------------------------------------------------------------
    local window_rule = rules.trading_window
    if type(window_rule) == "table" and window_rule.enabled == true then
        if type(ngx) == "table" and type(ngx.time) == "function" then
            local params = window_rule.params or {}
            local start_h = tonumber(params.start_hour) or 0
            local end_h   = tonumber(params.end_hour)   or 23
            -- Use os.date('!*t') to get the current UTC hour correctly.
            local hour    = os.date("!*t", ngx.time()).hour
            if hour < start_h or hour >= end_h then
                return true,
                    "PROVOST_INTERVENTION: Trading outside allowed window " ..
                    "(" .. start_h .. ":00-" .. end_h .. ":00 UTC)."
            end
        end
    end

    return false, nil
end

return _M
