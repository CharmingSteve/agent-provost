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
local cjson = require("cjson.safe")

-- Fallback limit used when max_trade_size rule is enabled but params.limit
-- is absent or non-numeric.
local DEFAULT_TRADE_SIZE_LIMIT = 100

local function normalize_http_method(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:upper()
end

local function normalize_http_path(value)
    if type(value) ~= "string" then
        return ""
    end
    local path = value:gsub("%z", "")
    local query_start = path:find("?", 1, true)
    if query_start then
        path = path:sub(1, query_start - 1)
    end
    return path
end

local function bool_from_rule(rule)
    if type(rule) ~= "table" then
        return false
    end
    if type(rule.enabled) == "boolean" then
        return rule.enabled
    end
    if type(rule.enabled) == "string" then
        return rule.enabled:lower() == "true"
    end
    return false
end

local function parse_json_body(raw)
    if type(raw) ~= "string" or raw == "" then
        return {}
    end
    local decoded = cjson.decode(raw)
    if type(decoded) == "table" then
        return decoded
    end
    return {}
end

local function parse_method_path(entry)
    if type(entry) ~= "string" then
        return nil, nil
    end

    local normalized = entry:gsub("^%s+", ""):gsub("%s+$", "")
    if normalized == "" then
        return nil, nil
    end

    local method, path = normalized:match("^(%u+)%s+(.+)$")
    if not method or not path then
        return nil, nil
    end

    return method, path:gsub("^%s+", ""):gsub("%s+$", "")
end

local function build_pattern(template)
    if type(template) ~= "string" or template == "" then
        return nil
    end

    local pattern = template
        :gsub("{account_id}", "__ACCOUNT_ID__")
        :gsub("{portfolio_id}", "__PORTFOLIO_ID__")
        :gsub("{order_id}", "__ORDER_ID__")
        :gsub("{symbol}", "__SYMBOL__")

    pattern = pattern:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    pattern = pattern
        :gsub("__ACCOUNT_ID__", "[%%w%%-]+")
        :gsub("__PORTFOLIO_ID__", "[%%w%%-]+")
        :gsub("__ORDER_ID__", "[%%w%%-]+")
        :gsub("__SYMBOL__", "[%%w%%-%%./]+")

    return "^" .. pattern .. "$"
end

local function is_forbidden(method, path, forbidden_list)
    if type(forbidden_list) ~= "table" then
        return false
    end

    local normalized_method = normalize_http_method(method)
    local normalized_path = normalize_http_path(path)
    if normalized_method == "" or normalized_path == "" then
        return false
    end

    for _, entry in ipairs(forbidden_list) do
        local entry_method, entry_path = parse_method_path(entry)
        if entry_method == normalized_method and entry_path then
            local pattern = build_pattern(entry_path)
            if pattern and normalized_path:match(pattern) then
                return true
            end
        end
    end

    return false
end

local function extract_account_id(path)
    if type(path) ~= "string" then
        return nil
    end
    return path:match("^/v1/trading/accounts/([%w%-]+)/")
end

local function extract_order_id(path)
    if type(path) ~= "string" then
        return nil
    end
    local order_id = path:match("^/v2/orders/([%w%-]+)$")
    if order_id then
        return order_id
    end
    return path:match("^/v1/trading/accounts/[%w%-]+/orders/([%w%-]+)$")
end

local function extract_symbol(path)
    if type(path) ~= "string" then
        return nil
    end
    local symbol = path:match("^/v2/positions/(.+)$")
    if symbol and symbol ~= "" then
        return symbol
    end
    symbol = path:match("^/v1/trading/accounts/[%w%-]+/positions/(.+)$")
    if symbol and symbol ~= "" then
        return symbol
    end
    return nil
end

local function normalize_symbol(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:gsub("^%s+", ""):gsub("%s+$", ""):upper()
end

local function ticker_allowed(symbol, list)
    if type(list) ~= "table" then
        return true
    end
    local normalized_symbol = normalize_symbol(symbol)
    if normalized_symbol == "" then
        return false
    end
    for _, candidate in ipairs(list) do
        if normalize_symbol(candidate) == normalized_symbol then
            return true
        end
    end
    return false
end

local function compute_order_notional(payload)
    if type(payload) ~= "table" then
        return nil
    end
    local notional = tonumber(payload.notional)
    if notional and notional > 0 then
        return notional
    end

    local qty = tonumber(payload.qty) or tonumber(payload.quantity)
    local limit_price = tonumber(payload.limit_price)
    if qty and qty > 0 and limit_price and limit_price > 0 then
        return qty * limit_price
    end
    return nil
end

local function compute_position_notional(payload)
    if type(payload) ~= "table" then
        return nil
    end

    local market_value = tonumber(payload.market_value)
    if market_value then
        return math.abs(market_value)
    end

    local qty = tonumber(payload.qty)
    local current_price = tonumber(payload.current_price)
    if qty and current_price then
        return math.abs(qty * current_price)
    end

    return nil
end

local function fetch_json(context, route, endpoint)
    if type(context) ~= "table" or type(context.http_fetch_json) ~= "function" then
        return nil, "fetch_unavailable"
    end
    return context.http_fetch_json(route, endpoint)
end

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
    -- Rule: allowed_tickers
    -- Draconian mode: blocks any ticker NOT in the explicit allowlist.
    -- Check happens before blocked_tickers so a strict allowlist takes
    -- precedence over any per-symbol blocklist entries.
    -- ----------------------------------------------------------------
    local allowed_rule = rules.allowed_tickers
    if type(allowed_rule) == "table" and allowed_rule.enabled == true
       and type(allowed_rule.params) == "table"
       and type(allowed_rule.params.tickers) == "table" then
        if has_invalid_ticker_type(args) then
            return true,
                "PROVOST_INTERVENTION: Invalid ticker type. " ..
                "Ticker fields must be strings."
        end
        local ticker = normalize_ticker(args)
        if ticker ~= "" then
            local found = false
            for _, allowed_sym in ipairs(allowed_rule.params.tickers) do
                local allowed_symbol = normalize_identifier(allowed_sym)
                if allowed_symbol ~= nil and ticker == allowed_symbol:upper() then
                    found = true
                    break
                end
            end
            if not found then
                return true,
                    "PROVOST_INTERVENTION: Ticker '" .. ticker ..
                    "' is not in the allowed symbol list."
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

function _M.check_http_request(method, path, raw_body, rules, context)
    rules = rules or {}
    context = resolve_context(context)

    local http_method = normalize_http_method(method)
    local http_path = normalize_http_path(path)
    local body = parse_json_body(raw_body)

    if http_method == "" or http_path == "" then
        return false, nil
    end

    local forbidden_rule = rules.forbidden_tools
    if bool_from_rule(forbidden_rule)
       and type(forbidden_rule.params) == "table"
       and type(forbidden_rule.params.tools) == "table"
       and is_forbidden(http_method, http_path, forbidden_rule.params.tools) then
        return true, "PROVOST_INTERVENTION: Forbidden Endpoint"
    end

    local broker_account_id = extract_account_id(http_path)
    if broker_account_id then
        if type(context) ~= "table" or type(context.get_account_id) ~= "function" then
            return true, "PROVOST_INTERVENTION: Account ID Discovery Failed"
        end

        local discovered_account_id, discover_err = context.get_account_id()
        if not discovered_account_id or discovered_account_id == "" then
            return true, "PROVOST_INTERVENTION: Account ID Discovery Failed"
        end

        if discover_err and discover_err ~= "" then
            return true, "PROVOST_INTERVENTION: Account ID Discovery Failed"
        end

        if broker_account_id ~= discovered_account_id then
            return true, "PROVOST_INTERVENTION: Account ID Mismatch"
        end
    end

    local order_id = extract_order_id(http_path)
    if http_method == "PATCH" and order_id then
        local route = broker_account_id and "broker" or "trading"
        local order_endpoint = route == "broker"
            and ("/v1/trading/accounts/" .. broker_account_id .. "/orders/" .. order_id)
            or ("/v2/orders/" .. order_id)

        local original_order, fetch_err = fetch_json(context, route, order_endpoint)
        if not original_order then
            return true, "PROVOST_INTERVENTION: Order Lookup Failed"
        end

        local replace_notional = compute_order_notional(body)
        local original_notional = compute_order_notional(original_order)

        local max_replace_rule = rules.max_replace_notional
        if bool_from_rule(max_replace_rule)
           and type(max_replace_rule.params) == "table" then
            local limit = tonumber(max_replace_rule.params.limit)
            if limit and replace_notional and replace_notional > limit then
                return true, "PROVOST_INTERVENTION: Replace Notional Exceeds Limit"
            end
        end

        if replace_notional and original_notional and replace_notional > original_notional then
            return true, "PROVOST_INTERVENTION: Replace Notional Exceeds Original"
        end

        local market_upgrade_rule = rules.prevent_market_order_upgrade
        if bool_from_rule(market_upgrade_rule) then
            local original_type = type(original_order.type) == "string" and original_order.type:lower() or ""
            local replacement_type = ""
            if type(body.type) == "string" then
                replacement_type = body.type:lower()
            elseif type(body.order_type) == "string" then
                replacement_type = body.order_type:lower()
            end

            if original_type == "limit" and replacement_type == "market" then
                return true, "PROVOST_INTERVENTION: Market Order Upgrade Not Allowed"
            end
        end
    end

    local symbol = extract_symbol(http_path)
    if http_method == "DELETE" and symbol and http_path ~= "/v2/positions" then
        local allowed_close_rule = rules.allowed_close_tickers
        if bool_from_rule(allowed_close_rule)
           and type(allowed_close_rule.params) == "table"
           and type(allowed_close_rule.params.tickers) == "table"
           and not ticker_allowed(symbol, allowed_close_rule.params.tickers) then
            return true, "PROVOST_INTERVENTION: Symbol Not Allowed for Close"
        end

        local route = broker_account_id and "broker" or "trading"
        local position_endpoint = route == "broker"
            and ("/v1/trading/accounts/" .. broker_account_id .. "/positions/" .. symbol)
            or ("/v2/positions/" .. symbol)

        local position_payload = fetch_json(context, route, position_endpoint)
        if not position_payload then
            return true, "PROVOST_INTERVENTION: Position Lookup Failed"
        end

        local close_notional = compute_position_notional(position_payload)
        local max_close_rule = rules.max_close_notional
        if bool_from_rule(max_close_rule)
           and type(max_close_rule.params) == "table" then
            local limit = tonumber(max_close_rule.params.limit)
            if limit and close_notional and close_notional > limit then
                return true, "PROVOST_INTERVENTION: Close Notional Exceeds Limit"
            end
        end
    end

    if http_method == "POST"
       and http_path:match("^/v1/trading/accounts/[%w%-]+/options/donotexercise$")
       and type(context) == "table"
       and type(context.audit_event) == "function" then
        context.audit_event("PROVOST_DNE_AUDIT", "DNE request allowed and recorded")
    end

    return false, nil
end

_M.build_pattern = build_pattern
_M.is_forbidden = is_forbidden

return _M
