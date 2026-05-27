-- rate_limit.lua
-- Tracks upstream rate-limit state for preemptive inbound protection.

local _M = {}

local LOW_REMAINING_THRESHOLD = 10
local DEFAULT_COOLDOWN_SECONDS = 60
local REMAINING_TTL_SECONDS = 300
local INBOUND_WINDOW_SECONDS = 60

local function dict()
    return ngx.shared.rate_limit
end

local function to_number(value)
    local n = tonumber(value)
    if not n then
        return nil
    end
    return n
end

function _M.set_remaining(value)
    local n = to_number(value)
    if not n then
        return false
    end
    dict():set("remaining", n, REMAINING_TTL_SECONDS)
    return true
end

function _M.get_remaining()
    return to_number(dict():get("remaining"))
end

function _M.is_remaining_low()
    local remaining = _M.get_remaining()
    if not remaining then
        return false
    end
    return remaining < LOW_REMAINING_THRESHOLD
end

function _M.enter_cooldown(seconds)
    local ttl = to_number(seconds) or DEFAULT_COOLDOWN_SECONDS
    local until_epoch = ngx.now() + ttl
    dict():set("cooldown_until", until_epoch, ttl)
    return until_epoch
end

function _M.is_cooldown_active()
    local until_epoch = to_number(dict():get("cooldown_until"))
    if not until_epoch then
        return false
    end
    return ngx.now() < until_epoch
end

function _M.get_inbound_rpm(rules)
    if type(rules) ~= "table" then
        return nil
    end

    local rule = rules.inbound_request_rate_limit
    if type(rule) ~= "table" or rule.enabled ~= true then
        return nil
    end

    local params = rule.params
    if type(params) ~= "table" then
        return nil
    end

    local rpm = to_number(params.rpm)
    if not rpm or rpm <= 0 then
        return nil
    end

    return math.floor(rpm)
end

function _M.is_inbound_request_rate_exceeded(rules, client_key)
    local rpm = _M.get_inbound_rpm(rules)
    if not rpm then
        return false, nil
    end

    local key = client_key
    if type(key) ~= "string" or key == "" then
        key = "anonymous"
    end

    local window = math.floor(ngx.now() / INBOUND_WINDOW_SECONDS)
    local redis_key = "inbound_rpm:" .. key .. ":" .. window
    local ttl = INBOUND_WINDOW_SECONDS + 1

    local current
    local d = dict()
    if d.incr then
        local value, err = d:incr(redis_key, 1, 0, ttl)
        if not value then
            return false, rpm, err
        end
        current = value
    else
        current = to_number(d:get(redis_key)) or 0
        current = current + 1
        d:set(redis_key, current, ttl)
    end

    return current > rpm, rpm
end

return _M
