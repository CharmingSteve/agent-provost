-- rules_engine_spec.lua
-- Unit tests for the dynamic rules engine (lua/rules_engine.lua).
--
-- All tests use the pure check_request() function which has no OpenResty
-- or file-system dependencies.  The module is required via a package.path
-- extension so busted can find it relative to the repo root.

package.path = package.path .. ";lua/?.lua"
local engine = require("rules_engine")

-- ---------------------------------------------------------------------------
-- Helper: build a parsed request body with params.arguments
-- ---------------------------------------------------------------------------
local function make_parsed(args, tool_name)
    local parsed = { params = { arguments = args } }
    if tool_name then
        parsed.method = "tools/call"
        parsed.params.name = tool_name
    end
    return parsed
end

-- ---------------------------------------------------------------------------
-- max_trade_size rule
-- -------------------------------------------------------------------
describe("rules_engine: max_trade_size rule", function()

    local rules_enabled = {
        max_trade_size = { enabled = true, params = { limit = 100 } }
    }
    local rules_disabled = {
        max_trade_size = { enabled = false, params = { limit = 100 } }
    }

    it("blocks when quantity > limit (rule enabled)", function()
        local blocked, reason = engine.check_request(make_parsed({ quantity = 101 }), rules_enabled)
        assert.is_true(blocked)
        assert.is_string(reason)
        assert.truthy(reason:find("PROVOST_INTERVENTION"))
    end)

    it("allows when quantity == limit (boundary: not strictly greater)", function()
        local blocked = engine.check_request(make_parsed({ quantity = 100 }), rules_enabled)
        assert.is_false(blocked)
    end)

    it("allows when quantity < limit", function()
        local blocked = engine.check_request(make_parsed({ quantity = 50 }), rules_enabled)
        assert.is_false(blocked)
    end)

    it("blocks when qty > limit (alternate field name)", function()
        local blocked = engine.check_request(make_parsed({ qty = 200 }), rules_enabled)
        assert.is_true(blocked)
    end)

    it("does NOT block when rule is disabled", function()
        local blocked = engine.check_request(make_parsed({ quantity = 9999 }), rules_disabled)
        assert.is_false(blocked)
    end)

    it("falls back to DEFAULT_TRADE_SIZE_LIMIT (100) when params.limit is absent", function()
        local rules_no_limit = { max_trade_size = { enabled = true, params = {} } }
        local blocked = engine.check_request(make_parsed({ quantity = 101 }), rules_no_limit)
        assert.is_true(blocked)
        local allowed = engine.check_request(make_parsed({ quantity = 100 }), rules_no_limit)
        assert.is_false(allowed)
    end)

    it("falls back to DEFAULT_TRADE_SIZE_LIMIT when params is absent entirely", function()
        local rules_no_params = { max_trade_size = { enabled = true } }
        local blocked = engine.check_request(make_parsed({ quantity = 101 }), rules_no_params)
        assert.is_true(blocked)
    end)

    it("handles string-encoded quantity values via tonumber coercion", function()
        local blocked = engine.check_request(make_parsed({ quantity = "150" }), rules_enabled)
        assert.is_true(blocked)
    end)

    it("ignores non-numeric quantity values (passes through)", function()
        local blocked = engine.check_request(make_parsed({ quantity = "big" }), rules_enabled)
        assert.is_false(blocked)
    end)

    it("blocks large fractional quantities", function()
        local blocked = engine.check_request(make_parsed({ quantity = 100.5 }), rules_enabled)
        assert.is_true(blocked)
    end)

    it("allows fractional quantities at or below the limit", function()
        local blocked = engine.check_request(make_parsed({ quantity = 99.9 }), rules_enabled)
        assert.is_false(blocked)
    end)

    it("respects a custom limit value (e.g. 50)", function()
        local rules_50 = { max_trade_size = { enabled = true, params = { limit = 50 } } }
        assert.is_true(engine.check_request(make_parsed({ quantity = 51 }), rules_50))
        assert.is_false(engine.check_request(make_parsed({ quantity = 50 }), rules_50))
    end)

end)

-- ---------------------------------------------------------------------------
-- blocked_tool_names rule
-- ---------------------------------------------------------------------------
describe("rules_engine: blocked_tool_names rule", function()

    local rules_enabled = {
        blocked_tool_names = {
            enabled = true,
            params  = { tools = { "place_stock_order" } }
        }
    }

    local rules_disabled = {
        blocked_tool_names = {
            enabled = false,
            params  = { tools = { "place_stock_order" } }
        }
    }

    it("blocks a disabled trade tool by exact tool name", function()
        local blocked = engine.check_request(
            make_parsed({ symbol = "GME", qty = "1" }, "place_stock_order"),
            rules_enabled)
        assert.is_true(blocked)
    end)

    it("allows a safe tool when rule is disabled", function()
        local blocked = engine.check_request(
            make_parsed({ symbol = "GME", qty = "1" }, "place_stock_order"),
            rules_disabled)
        assert.is_false(blocked)
    end)

    it("allows a different tool when not blocked", function()
        local blocked = engine.check_request(
            make_parsed({ symbol = "GME", qty = "1" }, "get_stock_bars"),
            rules_enabled)
        assert.is_false(blocked)
    end)

end)

-- ---------------------------------------------------------------------------
-- restricted_ticker_tool_rules rule
-- ---------------------------------------------------------------------------
describe("rules_engine: restricted_ticker_tool_rules rule", function()

    local rules_enabled = {
        restricted_ticker_tool_rules = {
            enabled = true,
            params  = {
                tools = { "place_stock_order", "place_option_order", "place_crypto_order" },
                tickers = { "GME", "AMC", "BBBY" }
            }
        }
    }

    local rules_disabled = {
        restricted_ticker_tool_rules = {
            enabled = false,
            params  = {
                tools = { "place_stock_order" },
                tickers = { "GME" }
            }
        }
    }

    it("blocks a restricted symbol for a supported order tool", function()
        local blocked = engine.check_request(
            make_parsed({ symbol = "GME", qty = "1" }, "place_stock_order"),
            rules_enabled)
        assert.is_true(blocked)
    end)

    it("blocks a restricted symbol with ticker field for a supported order tool", function()
        local blocked = engine.check_request(
            make_parsed({ ticker = "AMC", quantity = 1 }, "place_stock_order"),
            rules_enabled)
        assert.is_true(blocked)
    end)

    it("does not block a permitted symbol for a supported order tool", function()
        local blocked = engine.check_request(
            make_parsed({ symbol = "AAPL", qty = "1" }, "place_stock_order"),
            rules_enabled)
        assert.is_false(blocked)
    end)

    it("does not block a restricted symbol when the rule is disabled", function()
        local blocked = engine.check_request(
            make_parsed({ symbol = "GME", qty = "1" }, "place_stock_order"),
            rules_disabled)
        assert.is_false(blocked)
    end)

end)

-- ---------------------------------------------------------------------------
-- blocked_tickers rule
-- ---------------------------------------------------------------------------
describe("rules_engine: blocked_tickers rule", function()

    local rules_enabled = {
        blocked_tickers = {
            enabled = true,
            params  = { tickers = { "GME", "AMC", "BBBY" } }
        }
    }
    local rules_disabled = {
        blocked_tickers = {
            enabled = false,
            params  = { tickers = { "GME", "AMC", "BBBY" } }
        }
    }

    it("blocks a ticker on the restricted list (GME)", function()
        local blocked, reason = engine.check_request(make_parsed({ ticker = "GME" }), rules_enabled)
        assert.is_true(blocked)
        assert.truthy(reason:find("GME"))
    end)

    it("blocks a ticker on the restricted list (AMC)", function()
        local blocked = engine.check_request(make_parsed({ ticker = "AMC" }), rules_enabled)
        assert.is_true(blocked)
    end)

    it("allows a ticker NOT on the restricted list", function()
        local blocked = engine.check_request(make_parsed({ ticker = "AAPL" }), rules_enabled)
        assert.is_false(blocked)
    end)

    it("does NOT block when rule is disabled", function()
        local blocked = engine.check_request(make_parsed({ ticker = "GME" }), rules_disabled)
        assert.is_false(blocked)
    end)

    it("does not block when ticker field is absent", function()
        local blocked = engine.check_request(make_parsed({ quantity = 5 }), rules_enabled)
        assert.is_false(blocked)
    end)

end)

-- ---------------------------------------------------------------------------
-- Both rules active simultaneously
-- ---------------------------------------------------------------------------
describe("rules_engine: multiple rules active", function()

    local both_enabled = {
        max_trade_size  = { enabled = true, params = { limit = 100 } },
        blocked_tickers = { enabled = true, params = { tickers = { "GME" } } }
    }

    it("blocks on quantity violation first", function()
        local blocked = engine.check_request(
            make_parsed({ quantity = 500, ticker = "AAPL" }), both_enabled)
        assert.is_true(blocked)
    end)

    it("blocks on ticker violation when quantity is safe", function()
        local blocked = engine.check_request(
            make_parsed({ quantity = 5, ticker = "GME" }), both_enabled)
        assert.is_true(blocked)
    end)

    it("allows when both conditions are safe", function()
        local blocked = engine.check_request(
            make_parsed({ quantity = 5, ticker = "AAPL" }), both_enabled)
        assert.is_false(blocked)
    end)

end)

-- ---------------------------------------------------------------------------
-- Edge cases and pass-through scenarios
-- ---------------------------------------------------------------------------
describe("rules_engine: edge cases", function()

    local some_rules = {
        max_trade_size = { enabled = true, params = { limit = 100 } }
    }

    it("passes through when parsed body is nil", function()
        local blocked = engine.check_request(nil, some_rules)
        assert.is_false(blocked)
    end)

    it("passes through when params field is absent", function()
        local blocked = engine.check_request({}, some_rules)
        assert.is_false(blocked)
    end)

    it("passes through when params.arguments is absent", function()
        local blocked = engine.check_request({ params = {} }, some_rules)
        assert.is_false(blocked)
    end)

    it("passes through when rules table is nil (no rules loaded yet)", function()
        local blocked = engine.check_request(make_parsed({ quantity = 9999 }), nil)
        assert.is_false(blocked)
    end)

    it("passes through when rules table is empty (all rules removed)", function()
        local blocked = engine.check_request(make_parsed({ quantity = 9999 }), {})
        assert.is_false(blocked)
    end)

    it("ignores unknown/future rule keys gracefully", function()
        local rules_future = {
            max_trade_size      = { enabled = true, params = { limit = 100 } },
            unknown_future_rule = { enabled = true, params = { foo = "bar" } }
        }
        local blocked = engine.check_request(make_parsed({ quantity = 50 }), rules_future)
        assert.is_false(blocked)
    end)

    it("returns a non-nil reason string whenever blocked is true", function()
        local rules = { max_trade_size = { enabled = true, params = { limit = 10 } } }
        local blocked, reason = engine.check_request(make_parsed({ quantity = 99 }), rules)
        assert.is_true(blocked)
        assert.is_not_nil(reason)
        assert.is_string(reason)
    end)

    it("returns nil reason when not blocked", function()
        local rules = { max_trade_size = { enabled = true, params = { limit = 100 } } }
        local blocked, reason = engine.check_request(make_parsed({ quantity = 5 }), rules)
        assert.is_false(blocked)
        assert.is_nil(reason)
    end)

end)
