-- rate_limit_spec.lua
-- Unit tests for lua/rate_limit.lua using a mocked ngx environment.

package.path = package.path .. ";lua/?.lua"

describe("rate_limit module", function()
    local original_ngx
    local now_value
    local store

    local function reset_store()
        store = {}
    end

    local function shared_set(_, key, value, _ttl)
        store[key] = value
        return true
    end

    local function shared_get(_, key)
        return store[key]
    end

    local function shared_incr(_, key, value, init, _init_ttl)
        if type(store[key]) ~= "number" then
            if init == nil then
                return nil, "not found"
            end
            store[key] = init
        end
        store[key] = store[key] + value
        return store[key]
    end

    before_each(function()
        original_ngx = _G.ngx
        now_value = 100
        reset_store()

        _G.ngx = {
            now = function()
                return now_value
            end,
            shared = {
                rate_limit = {
                    set = shared_set,
                    get = shared_get,
                    incr = shared_incr,
                }
            }
        }

        package.loaded["rate_limit"] = nil
    end)

    after_each(function()
        _G.ngx = original_ngx
        package.loaded["rate_limit"] = nil
    end)

    it("stores and reads remaining quota", function()
        local rate_limit = require("rate_limit")
        assert.is_true(rate_limit.set_remaining("42"))
        assert.equals(42, rate_limit.get_remaining())
    end)

    it("does not mark low quota when remaining is absent", function()
        local rate_limit = require("rate_limit")
        assert.is_false(rate_limit.is_remaining_low())
    end)

    it("marks low quota when below threshold", function()
        local rate_limit = require("rate_limit")
        rate_limit.set_remaining(9)
        assert.is_true(rate_limit.is_remaining_low())
    end)

    it("does not mark low quota at threshold", function()
        local rate_limit = require("rate_limit")
        rate_limit.set_remaining(10)
        assert.is_false(rate_limit.is_remaining_low())
    end)

    it("ignores invalid remaining values", function()
        local rate_limit = require("rate_limit")
        assert.is_false(rate_limit.set_remaining("not-a-number"))
        assert.is_nil(rate_limit.get_remaining())
    end)

    it("enters cooldown and reports active", function()
        local rate_limit = require("rate_limit")
        local until_epoch = rate_limit.enter_cooldown(60)
        assert.equals(160, until_epoch)
        assert.is_true(rate_limit.is_cooldown_active())
    end)

    it("cooldown expires after ttl", function()
        local rate_limit = require("rate_limit")
        rate_limit.enter_cooldown(60)
        now_value = 161
        assert.is_false(rate_limit.is_cooldown_active())
    end)

    it("blocks requests above configured inbound rpm", function()
        local rate_limit = require("rate_limit")
        local rules = {
            inbound_request_rate_limit = {
                enabled = true,
                params = { rpm = 2 }
            }
        }

        assert.is_false(rate_limit.is_inbound_request_rate_exceeded(rules, "client-a"))
        assert.is_false(rate_limit.is_inbound_request_rate_exceeded(rules, "client-a"))
        assert.is_true(rate_limit.is_inbound_request_rate_exceeded(rules, "client-a"))
    end)

    it("does not enforce inbound limiter when rpm is zero", function()
        local rate_limit = require("rate_limit")
        local rules = {
            inbound_request_rate_limit = {
                enabled = true,
                params = { rpm = 0 }
            }
        }

        assert.is_false(rate_limit.is_inbound_request_rate_exceeded(rules, "client-b"))
        assert.is_false(rate_limit.is_inbound_request_rate_exceeded(rules, "client-b"))
        assert.is_false(rate_limit.is_inbound_request_rate_exceeded(rules, "client-b"))
    end)

    it("fails open for missing or invalid inbound limiter config", function()
        local rate_limit = require("rate_limit")
        assert.is_false(rate_limit.is_inbound_request_rate_exceeded({}, "client-c"))
        assert.is_false(rate_limit.is_inbound_request_rate_exceeded({
            inbound_request_rate_limit = { enabled = true, params = { rpm = "bad" } }
        }, "client-c"))
    end)

end)
