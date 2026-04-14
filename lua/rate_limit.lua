-- rate_limit.lua
-- Tracks upstream rate-limit state for preemptive inbound protection.

local _M = {}

local LOW_REMAINING_THRESHOLD = 10
local DEFAULT_COOLDOWN_SECONDS = 60
local REMAINING_TTL_SECONDS = 300

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

return _M
