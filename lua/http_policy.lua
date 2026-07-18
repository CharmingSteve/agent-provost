-- http_policy.lua
-- Enforce REST endpoint governance for outbound MCP->API traffic.

local cjson = require("cjson.safe")
local engine = require("rules_engine")

local _M = {}
local cached_api_key = nil
local cached_secret_key = nil
local cached_creds_at = 0
local cached_account_id = nil
local cached_account_id_expires_at = 0

local function read_secret_file(path)
    local fh = io.open(path, "r")
    if not fh then
        return nil
    end
    local value = fh:read("*a")
    fh:close()
    if type(value) ~= "string" then
        return nil
    end
    value = value:gsub("%s+$", "")
    if value == "" then
        return nil
    end
    return value
end

local function load_policy_credentials()
    local now = ngx.now()
    if cached_api_key and cached_secret_key and (now - cached_creds_at) < 60 then
        return cached_api_key, cached_secret_key
    end

    local api_key = read_secret_file("/run/secrets/alpaca_api_key") or os.getenv("ALPACA_API_KEY")
    local secret_key = read_secret_file("/run/secrets/alpaca_secret_key") or os.getenv("ALPACA_SECRET_KEY")

    if api_key and secret_key then
        cached_api_key = api_key
        cached_secret_key = secret_key
        cached_creds_at = now
    end

    return cached_api_key, cached_secret_key
end

local function apply_policy_credentials_to_vars()
    local api_key, secret_key = load_policy_credentials()
    ngx.var.policy_apca_api_key = api_key or ""
    ngx.var.policy_apca_secret_key = secret_key or ""
end

local function read_rules()
    local raw_rules = ngx.shared.rules and ngx.shared.rules:get("rules")
    if not raw_rules then
        return {}
    end
    local decoded = cjson.decode(raw_rules)
    if type(decoded) ~= "table" then
        return {}
    end
    return decoded
end

local function normalize_policy_path(route, uri)
    local path = uri or ngx.var.uri or ""

    if route == "trading" then
        path = path:gsub("^/trading", "")
    elseif route == "broker" then
        path = path:gsub("^/broker", "")
    end

    if path == "" then
        path = "/"
    end

    return path
end

local function reject(detail)
    local audit_error = require("audit_error")
    audit_error.emit("provost_api_to_mcp_error", 403, "PROVOST_INTERVENTION", detail, {
        request_id = ngx.var.provost_req_id,
    })
    ngx.status = 403
    ngx.header["Content-Type"] = "application/json"
    local body = cjson.encode({
        error = "PROVOST_INTERVENTION",
        detail = detail or "Policy violation"
    })
    ngx.var.resp_body = body or ""
    ngx.say(body)
    return ngx.exit(403)
end


local function fetch_json(route, endpoint)
    local api_key, secret_key = load_policy_credentials()
    ngx.var.policy_apca_api_key = api_key or ""
    ngx.var.policy_apca_secret_key = secret_key or ""

    local sub_uri
    if route == "broker" then
        sub_uri = "/_policy/broker" .. endpoint
    else
        sub_uri = "/_policy/trading" .. endpoint
    end

    local res = ngx.location.capture(sub_uri, {
        method = ngx.HTTP_GET,
        copy_all_vars = true,
        vars = {
            policy_apca_api_key = api_key or "",
            policy_apca_secret_key = secret_key or "",
        },
    })
    if not res then
        return nil, "subrequest_failed"
    end

    if res.status < 200 or res.status >= 300 then
        return nil, "http_" .. tostring(res.status)
    end

    local payload = cjson.decode(res.body)
    if type(payload) ~= "table" then
        return nil, "invalid_json"
    end

    return payload, nil
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function discover_account_direct(api_key, secret_key)
    if not api_key or api_key == "" or not secret_key or secret_key == "" then
        return nil, "missing_credentials"
    end

    local cmd = "wget -qO- --timeout=8 "
        .. "--header=" .. shell_quote("APCA-API-KEY-ID: " .. api_key) .. " "
        .. "--header=" .. shell_quote("APCA-API-SECRET-KEY: " .. secret_key) .. " "
        .. shell_quote("https://paper-api.alpaca.markets/v2/account") .. " 2>/dev/null"

    local pipe = io.popen(cmd, "r")
    if not pipe then
        return nil, "wget_unavailable"
    end

    local body = pipe:read("*a") or ""
    pipe:close()
    if body == "" then
        return nil, "empty_response"
    end

    local payload = cjson.decode(body)
    if type(payload) ~= "table" then
        return nil, "invalid_json"
    end

    local discovered = payload.id or payload.account_id
    if type(discovered) ~= "string" or discovered == "" then
        return nil, "account_id_missing"
    end

    return discovered, nil
end

local function get_account_id()
    local now = ngx.now()
    if cached_account_id and now < cached_account_id_expires_at then
        return cached_account_id, nil
    end

    local cache = ngx.shared.provost_ctx
    local cache_key = "alpaca:account_id"

    if cache then
        local cached = cache:get(cache_key)
        if cached and cached ~= "" then
            return cached, nil
        end
    end

    local api_key, secret_key = load_policy_credentials()
    local discovered, direct_err = discover_account_direct(api_key, secret_key)

    if not discovered then
        local account, fetch_err = fetch_json("trading", "/v2/account")
        if not account then
            return nil, fetch_err or direct_err or "account_lookup_failed"
        end
        discovered = account.id or account.account_id
        if type(discovered) ~= "string" or discovered == "" then
            return nil, "account_id_missing"
        end
    end

    cached_account_id = discovered
    cached_account_id_expires_at = now + 300

    if cache then
        cache:set(cache_key, discovered, 300)
    end

    return discovered, nil
end

function _M.enforce(route)
    local rules = read_rules()
    local req_method = ngx.req.get_method()
    local req_path = normalize_policy_path(route, ngx.var.uri)
    local req_body = ngx.req.get_body_data() or ""

    local api_key, secret_key = load_policy_credentials()
    if api_key and api_key ~= "" then
        ngx.req.set_header("APCA-API-KEY-ID", api_key)
        ngx.var.policy_apca_api_key = api_key
    end
    if secret_key and secret_key ~= "" then
        ngx.req.set_header("APCA-API-SECRET-KEY", secret_key)
        ngx.var.policy_apca_secret_key = secret_key
    end

    local context = {
        get_account_id = get_account_id,
        http_fetch_json = fetch_json,
        audit_event = function(code, message)
            ngx.log(ngx.WARN, "[http_policy] ", code or "PROVOST_AUDIT", ": ", message or "")
        end
    }

    local blocked, reason = engine.check_http_request(req_method, req_path, req_body, rules, context)
    if blocked then
        return reject(reason)
    end

    return true
end

function _M.prime_account_id_cache()
    local discovered, err = get_account_id()
    if discovered and discovered ~= "" then
        return true
    end
    if err and err ~= "" then
        ngx.log(ngx.WARN, "[http_policy] account cache prime skipped: ", err)
    end
    return false
end

return _M
