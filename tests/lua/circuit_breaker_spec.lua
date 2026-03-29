-- circuit_breaker_spec.lua
-- Unit tests for the circuit-breaker logic embedded in default.conf
-- (access_by_lua_block on port-8000 / HOP-1).
--
-- The pure decision function mirrors the Lua block exactly so that we can
-- validate every branch without a running nginx instance.

describe("circuit breaker", function()

    -- Pure extraction of the decision logic from default.conf
    local function should_block(parsed)
        if parsed and parsed.params and parsed.params.arguments then
            local args = parsed.params.arguments
            local qty = tonumber(args.quantity) or tonumber(args.qty)
            return qty ~= nil and qty > 100, qty
        end
        return false, nil
    end

    it("blocks when 'quantity' field exceeds 100", function()
        local body = { params = { arguments = { quantity = 101 } } }
        local blocked, qty = should_block(body)
        assert.is_true(blocked)
        assert.equals(101, qty)
    end)

    it("blocks when 'qty' field exceeds 100", function()
        local body = { params = { arguments = { qty = 200 } } }
        local blocked, qty = should_block(body)
        assert.is_true(blocked)
        assert.equals(200, qty)
    end)

    it("blocks at quantity = 101 (just above boundary)", function()
        local body = { params = { arguments = { quantity = 101 } } }
        local blocked = should_block(body)
        assert.is_true(blocked)
    end)

    it("allows quantity = 100 (boundary: not strictly greater)", function()
        local body = { params = { arguments = { quantity = 100 } } }
        local blocked = should_block(body)
        assert.is_false(blocked)
    end)

    it("allows quantity = 99", function()
        local body = { params = { arguments = { quantity = 99 } } }
        local blocked = should_block(body)
        assert.is_false(blocked)
    end)

    it("allows qty = 1", function()
        local body = { params = { arguments = { qty = 1 } } }
        local blocked = should_block(body)
        assert.is_false(blocked)
    end)

    it("prefers 'quantity' over 'qty' when both are present", function()
        -- tonumber(args.quantity) is evaluated first in the 'or' chain
        local body = { params = { arguments = { quantity = 50, qty = 200 } } }
        local blocked, qty = should_block(body)
        assert.is_false(blocked)
        assert.equals(50, qty)
    end)

    it("falls back to 'qty' when 'quantity' is nil", function()
        local body = { params = { arguments = { qty = 150 } } }
        local blocked, qty = should_block(body)
        assert.is_true(blocked)
        assert.equals(150, qty)
    end)

    it("passes through when arguments field is absent", function()
        local body = { params = {} }
        local blocked = should_block(body)
        assert.is_false(blocked)
    end)

    it("passes through when params field is absent", function()
        local body = {}
        local blocked = should_block(body)
        assert.is_false(blocked)
    end)

    it("passes through when parsed body is nil (decode failure)", function()
        local blocked = should_block(nil)
        assert.is_false(blocked)
    end)

    it("handles string-encoded quantity values (tonumber coercion)", function()
        local body = { params = { arguments = { quantity = "150" } } }
        local blocked = should_block(body)
        assert.is_true(blocked)
    end)

    it("ignores non-numeric quantity values", function()
        local body = { params = { arguments = { quantity = "big" } } }
        local blocked = should_block(body)
        assert.is_false(blocked)
    end)

    it("blocks large fractional quantities", function()
        local body = { params = { arguments = { quantity = 100.5 } } }
        local blocked = should_block(body)
        assert.is_true(blocked)
    end)

    it("allows fractional quantities at or below 100", function()
        local body = { params = { arguments = { quantity = 99.9 } } }
        local blocked = should_block(body)
        assert.is_false(blocked)
    end)

end)
