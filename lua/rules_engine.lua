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

local function normalize_identifier(value)
    if type(value) ~= "string" then
        return nil
    end
    local cleaned = value:gsub("%z", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if cleaned == "" then
        return nil
    end
    return cleaned
end

local function get_tool_name(parsed)
    if type(parsed) ~= "table" then
        return nil
    end

    if parsed.method == "tools/call"
       and type(parsed.params) == "table"
       and type(parsed.params.name) == "string" then
        return normalize_identifier(parsed.params.name)
    end

    if type(parsed.method) == "string" then
        return normalize_identifier(parsed.method)
    end

    return nil
end

local function normalize_asset_class(value)
    local cleaned = normalize_identifier(value)
    if not cleaned then
        return nil
    end
    local lowered = cleaned:lower()
    if lowered == "equity" or lowered == "stock" then
        return "us_equity"
    end
    if lowered == "option" or lowered == "options" then
        return "us_option"
    end
    return lowered
end

local function infer_asset_class(tool_name, args)
    if type(args) == "table" then
        local explicit = normalize_asset_class(args.asset_class)
        if explicit then
            return explicit
        end
    end

    if type(tool_name) ~= "string" or tool_name == "" then
        return nil
    end

    local normalized_tool = tool_name:lower()
    if normalized_tool:find("place_crypto_order", 1, true) then
        return "crypto"
    end
    if normalized_tool:find("place_option_order", 1, true)
       or normalized_tool:find("exercise_options_position", 1, true)
       or normalized_tool:find("options", 1, true) then
        return "us_option"
    end
    if normalized_tool:find("place_stock_order", 1, true)
       or normalized_tool:find("place_etf_order", 1, true)
       or normalized_tool:find("place_equity_order", 1, true) then
        return "us_equity"
    end

    return nil
end

local function is_allowed_asset_class(classes, candidate)
    if type(classes) ~= "table" or candidate == nil then
        return false
    end

    for _, class_name in ipairs(classes) do
        if normalize_asset_class(class_name) == candidate then
            return true
        end
    end

    return false
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

    local raw = args.ticker
        or args.symbol
        or args.symbol_or_asset_id

    local cleaned = normalize_identifier(raw)
    if not cleaned then
        return ""
    end

    return cleaned:upper()
end

local function has_invalid_ticker_type(args)
    if type(args) ~= "table" then
        return false
    end
    for _, key in ipairs({ "ticker", "symbol", "symbol_or_asset_id" }) do
        if args[key] ~= nil and type(args[key]) ~= "string" then
            return true
        end
    end
    return false
end

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

local function estimate_order_value(args)
    local limit_price = normalize_limit_price(args)
    local notional = normalize_notional(args)
    if notional ~= nil and notional > 0 then
        return notional, notional, nil, limit_price
    end

    local qty = normalize_quantity(args)
    if qty ~= nil and qty > 0 and limit_price ~= nil and limit_price > 0 then
        return qty * limit_price, nil, qty, limit_price
    end

    return nil, notional, qty, limit_price
end

local function get_cumulative_exposure_key(context, args)
    if type(context) ~= "table" then
        return nil
    end
    local user = context.user
    local machine = context.machine
    if type(user) ~= "string" or user == "" or type(machine) ~= "string" or machine == "" then
        return nil
    end

    local ticker = normalize_ticker(args)
    if ticker == "" then
        ticker = "ALL"
    end

    return "cum_notional:" .. user .. ":" .. machine .. ":" .. ticker
end

local function resolve_context(context)
    if type(context) == "table" then
        return context
    end

    if type(ngx) ~= "table" then
        return nil
    end

    local var = ngx.var or {}
    local shared = ngx.shared or {}
    local user = var.http_x_provost_user
    local machine = var.http_x_provost_machine

    if (not user or user == "") and type(shared.provost_ctx) == "table" then
        user = shared.provost_ctx:get("last:user")
    end
    if (not machine or machine == "") and type(shared.provost_ctx) == "table" then
        machine = shared.provost_ctx:get("last:machine")
    end

    return {
        user = user,
        machine = machine,
        store = shared.provost_ctx
    }
end

-- check_request evaluates a decoded request body against the rules table.
--
-- @param  parsed  table|nil  Decoded JSON request body (output of cjson.decode).
-- @param  rules   table|nil  Rules table from shared dict.  Nil is treated as
--                            an empty table (fail-open: no rules applied).
-- @return blocked bool       true when the request must be blocked.
-- @return reason  string|nil Human-readable PROVOST_INTERVENTION message, or
--                            nil when not blocked.
function _M.check_request(parsed, rules, context)
    rules = rules or {}
    context = resolve_context(context)

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
    -- Rule: allowed_asset_classes
    -- Restricts mutating trade tools to a configured asset class allowlist.
    -- ----------------------------------------------------------------
    local allowed_classes_rule = rules.allowed_asset_classes
    if type(allowed_classes_rule) == "table"
       and allowed_classes_rule.enabled == true
       and type(allowed_classes_rule.params) == "table"
       and type(allowed_classes_rule.params.classes) == "table" then
        local inferred_class = infer_asset_class(tool_name, args)
        if inferred_class ~= nil
           and not is_allowed_asset_class(allowed_classes_rule.params.classes, inferred_class) then
            return true,
                "PROVOST_INTERVENTION: Asset class '" .. inferred_class ..
                "' is not allowed by current policy."
        end
    end

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
    -- Rule: max_trade_notional
    -- ----------------------------------------------------------------
    local notional_rule = rules.max_trade_notional
    if type(notional_rule) == "table" and notional_rule.enabled == true then
        local limit_value = nil
        if type(notional_rule.params) == "table" then
            limit_value = tonumber(notional_rule.params.limit)
        end

        if limit_value and limit_value > 0 then
            local estimated_value, notional, _, limit_price = estimate_order_value(args)

            if estimated_value and estimated_value > limit_value then
                return true,
                    "PROVOST_INTERVENTION: Risk Limit Exceeded. " ..
                    "Attempted trade value too large. Blocked to protect capital."
            end

            if notional ~= nil and notional > 0 and (limit_price == nil or limit_price <= 0) then
                return true,
                    "PROVOST_INTERVENTION: Risk Limit Exceeded. " ..
                    "Notional orders require limit_price for safe evaluation."
            end
        end
    end

    -- ----------------------------------------------------------------
    -- Rule: cumulative_trade_notional
    -- ----------------------------------------------------------------
    local cumulative_rule = rules.cumulative_trade_notional
    if type(cumulative_rule) == "table" and cumulative_rule.enabled == true then
        local limit_value = nil
        local window_seconds = 300
        if type(cumulative_rule.params) == "table" then
            limit_value = tonumber(cumulative_rule.params.limit)
            window_seconds = tonumber(cumulative_rule.params.window_seconds) or window_seconds
        end

        if limit_value and limit_value > 0 and window_seconds > 0 then
            local estimated_value = estimate_order_value(args)
            if estimated_value and estimated_value > 0 then
                local exposure_key = get_cumulative_exposure_key(context, args)
                local store = type(context) == "table" and context.store or nil

                if type(store) == "table" and exposure_key ~= nil then
                    local add_ok, add_err = store:add(exposure_key, 0, window_seconds)
                    if not add_ok and add_err ~= "exists" and add_err ~= "not found" then
                        return true,
                            "PROVOST_INTERVENTION: Risk State Unavailable. " ..
                            "Blocked to avoid untracked cumulative exposure."
                    end

                    local current = tonumber(store:get(exposure_key) or 0) or 0
                    local new_total = current + estimated_value
                    if new_total > limit_value then
                        return true,
                            "PROVOST_INTERVENTION: Cumulative Risk Limit Exceeded. " ..
                            "Rolling trade exposure too large within active window."
                    end

                    local set_ok = store:set(exposure_key, new_total, window_seconds)
                    if not set_ok then
                        return true,
                            "PROVOST_INTERVENTION: Risk State Unavailable. " ..
                            "Blocked to avoid untracked cumulative exposure."
                    end
                end
            end
        end
    end
    -- ----------------------------------------------------------------
    -- Rule: symbol_order_cooldown
    -- Blocks repeat orders for the same symbol within a time window.
    -- Enforced regardless of order type or quantity — any second order
    -- for a symbol that already has an active cooldown entry is blocked.
    -- ----------------------------------------------------------------
    local cooldown_rule = rules.symbol_order_cooldown
    if type(cooldown_rule) == "table" and cooldown_rule.enabled == true then
        local window_seconds = 300
        if type(cooldown_rule.params) == "table" then
            window_seconds = tonumber(cooldown_rule.params.window_seconds) or window_seconds
        end

        if window_seconds > 0 then
            local ticker = normalize_ticker(args)
            if ticker ~= "" then
                local user    = type(context) == "table" and context.user    or nil
                local machine = type(context) == "table" and context.machine or nil
                local store   = type(context) == "table" and context.store   or nil

                if type(store) == "table"
                   and type(user) == "string" and user ~= ""
                   and type(machine) == "string" and machine ~= "" then
                    local cooldown_key = "symbol_cooldown:" .. user .. ":" .. machine .. ":" .. ticker
                    local add_ok, add_err = store:add(cooldown_key, 1, window_seconds)
                    if not add_ok and add_err == "exists" then
                        return true,
                            "PROVOST_INTERVENTION: Symbol Cooldown Active. " ..
                            "Symbol '" .. ticker .. "' was already ordered within the active " ..
                            window_seconds .. "s window. Wait before reordering."
                    elseif not add_ok then
                        return true,
                            "PROVOST_INTERVENTION: Risk State Unavailable. " ..
                            "Blocked to avoid untracked symbol cooldown."
                    end
                end
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
        if has_invalid_ticker_type(args) then
            return true,
                "PROVOST_INTERVENTION: Invalid ticker type. " ..
                "Ticker fields must be strings."
        end
        local ticker = normalize_ticker(args)
        if ticker ~= "" then
            for _, blocked_tool in ipairs(restricted_tool_rule.params.tools) do
                local blocked_tool_name = normalize_identifier(blocked_tool)
                if blocked_tool_name ~= nil and tool_name == blocked_tool_name then
                    for _, blocked_sym in ipairs(restricted_tool_rule.params.tickers) do
                        local blocked_symbol = normalize_identifier(blocked_sym)
                        if blocked_symbol ~= nil and ticker == blocked_symbol:upper() then
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
        if has_invalid_ticker_type(args) then
            return true,
                "PROVOST_INTERVENTION: Invalid ticker type. " ..
                "Ticker fields must be strings."
        end
        local ticker = normalize_ticker(args)
        if type(ticker_rule.params) == "table"
           and type(ticker_rule.params.tickers) == "table" then
            for _, blocked_sym in ipairs(ticker_rule.params.tickers) do
                local blocked_symbol = normalize_identifier(blocked_sym)
                if blocked_symbol ~= nil and ticker == blocked_symbol:upper() then
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
