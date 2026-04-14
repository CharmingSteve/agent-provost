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

end)
