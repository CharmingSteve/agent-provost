local cjson = require("cjson.safe")

local _M = {}

-- Build JSON with guaranteed field order (cjson.encode on a table gives hash order).
local function ordered_json(fields)
    local parts = {}
    for _, pair in ipairs(fields) do
        parts[#parts + 1] = cjson.encode(pair[1]) .. ":" .. cjson.encode(pair[2])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function encode_or_fallback(fields)
    local ok, result = pcall(ordered_json, fields)
    if ok and result then
        return result
    end
    return "{}"
end

local function resolve_from_ctx_store(ctx_store, request_id)
    if not ctx_store or not request_id or request_id == "" then
        return nil, nil
    end

    local raw = ctx_store:get("req:" .. request_id)
    if not raw then
        return nil, nil
    end

    local decoded = cjson.decode(raw) or {}
    return decoded.user, decoded.machine
end

function _M.resolve_identity(request_id)
    local var = ngx.var or {}
    local ctx_store = ngx.shared and ngx.shared.provost_ctx or nil
    local req_headers = {}
    if ngx.req and ngx.req.get_headers then
        req_headers = ngx.req.get_headers() or {}
    end

    local header_request_id = req_headers["X-Provost-Request-Id"] or req_headers["x-provost-request-id"]
    local header_user = req_headers["X-Provost-User"] or req_headers["x-provost-user"]
    local header_machine = req_headers["X-Provost-Machine"] or req_headers["x-provost-machine"]

    local resolved_request_id = request_id
        or var.provost_req_id
        or header_request_id
        or var.http_x_provost_request_id
        or (ctx_store and ctx_store:get("last:request_id"))
        or var.request_id
        or ""

    local user = header_user or var.http_x_provost_user
    local machine = header_machine or var.http_x_provost_machine

    if (not user or user == "") or (not machine or machine == "") then
        local ctx_user, ctx_machine = resolve_from_ctx_store(ctx_store, resolved_request_id)
        user = (user and user ~= "") and user or ctx_user
        machine = (machine and machine ~= "") and machine or ctx_machine
    end

    if not user or user == "" then
        user = (ctx_store and ctx_store:get("last:user")) or ""
    end
    if not machine or machine == "" then
        machine = (ctx_store and ctx_store:get("last:machine")) or ""
    end

    if resolved_request_id and resolved_request_id ~= "" then
        ngx.var.provost_req_id = resolved_request_id
    end

    return resolved_request_id or "", user or "", machine or ""
end

function _M.emit(tag, status_code, error_code, error_detail, opts)
    opts = opts or {}

    local request_id, user, machine = _M.resolve_identity(opts.request_id)

    -- Fields ordered to match access log cosmetic order (time_local first).
    local fields = {
        {"time_local",          ngx.var.time_local or ""},
        {"remote_addr",         ngx.var.remote_addr or ""},
        {"request",             ngx.var.request or ""},
        {"status",              tostring(status_code or ngx.status or "")},
        {"provost_request_id",  request_id},
        {"provost_user",        user},
        {"provost_machine",     machine},
        {"request_body",        opts.request_body or ngx.var.req_body or ""},
        {"resp_body",           opts.resp_body or ngx.var.resp_body or ""},
        {"error_code",          error_code or "PROVOST_ERROR"},
        {"error_detail",        error_detail or ""},
        {"stream_tag",          tag},
        {"log_type",            "error"},
        {"date",                ngx.utctime()},
    }

    local encoded = encode_or_fallback(fields)
    local audit_line = "PROVOST_AUDIT_ERROR " .. encoded

    -- Route audit errors through nginx error_log (syslog unix socket) for
    -- deterministic local delivery into the Fluent Bit syslog input.
    ngx.log(ngx.ERR, audit_line)
end

return _M
