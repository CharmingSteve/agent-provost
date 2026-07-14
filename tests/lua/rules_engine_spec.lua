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

-- ---------------------------------------------------------------------------
-- REST endpoint governance rules
-- ---------------------------------------------------------------------------
describe("rules_engine: http endpoint governance", function()

    it("build_pattern matches dynamic account_id and symbol segments", function()
        local pattern = engine.build_pattern("/v1/trading/accounts/{account_id}/positions/{symbol}")
        assert.truthy(pattern)
        assert.truthy(("/v1/trading/accounts/abc-123/positions/ETH/USD"):match(pattern))
    end)

    it("is_forbidden blocks method+path template matches", function()
        local forbidden = {
            "DELETE /v2/positions",
            "DELETE /v1/trading/accounts/{account_id}/positions"
        }

        assert.is_true(engine.is_forbidden("DELETE", "/v2/positions", forbidden))
        assert.is_true(engine.is_forbidden("DELETE", "/v1/trading/accounts/abc-123/positions", forbidden))
        assert.is_false(engine.is_forbidden("GET", "/v2/positions", forbidden))
    end)

    it("blocks forbidden endpoint using forbidden_tools rule", function()
        local rules = {
            forbidden_tools = {
                enabled = true,
                params = { tools = { "DELETE /v2/positions" } }
            }
        }

        local blocked, reason = engine.check_http_request("DELETE", "/v2/positions", "", rules, {})
        assert.is_true(blocked)
        assert.truthy(reason:find("Forbidden Endpoint"))
    end)

    it("blocks all default forbidden endpoint templates with real ids", function()
        local rules = {
            forbidden_tools = {
                enabled = true,
                params = {
                    tools = {
                        "DELETE /v2/positions",
                        "DELETE /v2/orders",
                        "DELETE /v1/trading/accounts/{account_id}/orders",
                        "DELETE /v1/trading/accounts/{account_id}/positions",
                        "POST /v1/transfers",
                        "POST /v1/journals",
                        "POST /v1/journals/batch",
                        "POST /v1/journals/reverse_batch",
                        "POST /v1/funding_wallets/withdrawals",
                        "POST /v1/crypto/wallets/withdrawals",
                        "POST /v1/crypto/wallets/whitelisted_addresses",
                        "POST /v1/instant_funding",
                        "POST /v1/trading/accounts/{account_id}/options/exercise",
                        "PATCH /v2/account/configurations",
                        "PATCH /v1/trading/accounts/{account_id}/account/configurations",
                        "POST /v1/rebalancing/runs",
                        "POST /v1/rebalancing/portfolios",
                        "PATCH /v1/rebalancing/portfolios/{portfolio_id}",
                        "POST /v1/rebalancing/subscriptions",
                        "POST /v1/crypto/perps/wallets/withdrawals",
                        "POST /v1/crypto/perps/wallets/whitelisted_addresses",
                        "POST /v1/crypto/perps/leverage"
                    }
                }
            }
        }

        local requests = {
            { "DELETE", "/v2/positions" },
            { "DELETE", "/v2/orders" },
            { "DELETE", "/v1/trading/accounts/acct-123/orders" },
            { "DELETE", "/v1/trading/accounts/acct-123/positions" },
            { "POST", "/v1/transfers" },
            { "POST", "/v1/journals" },
            { "POST", "/v1/journals/batch" },
            { "POST", "/v1/journals/reverse_batch" },
            { "POST", "/v1/funding_wallets/withdrawals" },
            { "POST", "/v1/crypto/wallets/withdrawals" },
            { "POST", "/v1/crypto/wallets/whitelisted_addresses" },
            { "POST", "/v1/instant_funding" },
            { "POST", "/v1/trading/accounts/acct-123/options/exercise" },
            { "PATCH", "/v2/account/configurations" },
            { "PATCH", "/v1/trading/accounts/acct-123/account/configurations" },
            { "POST", "/v1/rebalancing/runs" },
            { "POST", "/v1/rebalancing/portfolios" },
            { "PATCH", "/v1/rebalancing/portfolios/portfolio-99" },
            { "POST", "/v1/rebalancing/subscriptions" },
            { "POST", "/v1/crypto/perps/wallets/withdrawals" },
            { "POST", "/v1/crypto/perps/wallets/whitelisted_addresses" },
            { "POST", "/v1/crypto/perps/leverage" }
        }

        for _, req in ipairs(requests) do
            local blocked, reason = engine.check_http_request(req[1], req[2], "{}", rules, {})
            assert.is_true(blocked)
            assert.truthy(reason:find("Forbidden Endpoint"))
        end
    end)

    it("blocks broker request when URL account_id mismatches discovered account", function()
        local rules = {}
        local context = {
            get_account_id = function()
                return "real-account-id", nil
            end
        }

        local blocked, reason = engine.check_http_request(
            "PATCH",
            "/v1/trading/accounts/wrong-account/orders/ord-1",
            "{}",
            rules,
            context
        )
        assert.is_true(blocked)
        assert.truthy(reason:find("Account ID Mismatch"))
    end)

    it("blocks replace notional above limit", function()
        local rules = {
            max_replace_notional = { enabled = true, params = { limit = 10000 } }
        }
        local context = {
            http_fetch_json = function(_, _)
                return { notional = 5000, type = "limit" }, nil
            end
        }

        local blocked, reason = engine.check_http_request(
            "PATCH",
            "/v2/orders/ord-1",
            '{"notional":12000,"type":"limit"}',
            rules,
            context
        )
        assert.is_true(blocked)
        assert.truthy(reason:find("Replace Notional Exceeds Limit"))
    end)

    it("blocks replacement that upgrades limit order to market", function()
        local rules = {
            prevent_market_order_upgrade = { enabled = true, params = { enabled = true } }
        }
        local context = {
            http_fetch_json = function(_, _)
                return { notional = 2000, type = "limit" }, nil
            end
        }

        local blocked, reason = engine.check_http_request(
            "PATCH",
            "/v2/orders/ord-1",
            '{"notional":1800,"type":"market"}',
            rules,
            context
        )
        assert.is_true(blocked)
        assert.truthy(reason:find("Market Order Upgrade Not Allowed"))
    end)

    it("blocks close position when symbol is not in allowed_close_tickers", function()
        local rules = {
            allowed_close_tickers = {
                enabled = true,
                params = { tickers = { "AAPL", "MSFT" } }
            }
        }
        local context = {
            http_fetch_json = function(_, _)
                return { market_value = 1000 }, nil
            end
        }

        local blocked, reason = engine.check_http_request(
            "DELETE",
            "/v2/positions/TSLA",
            "",
            rules,
            context
        )
        assert.is_true(blocked)
        assert.truthy(reason:find("Symbol Not Allowed for Close"))
    end)

    it("blocks close position when current notional exceeds max_close_notional", function()
        local rules = {
            max_close_notional = {
                enabled = true,
                params = { limit = 10000 }
            },
            allowed_close_tickers = {
                enabled = true,
                params = { tickers = { "AAPL", "MSFT" } }
            }
        }
        local context = {
            http_fetch_json = function(_, _)
                return { market_value = 12500 }, nil
            end
        }

        local blocked, reason = engine.check_http_request(
            "DELETE",
            "/v2/positions/AAPL",
            "",
            rules,
            context
        )

        assert.is_true(blocked)
        assert.truthy(reason:find("Close Notional Exceeds Limit"))
    end)

    it("allows and audits do-not-exercise requests", function()
        local seen_audit = false
        local context = {
            get_account_id = function()
                return "acct-1", nil
            end,
            audit_event = function(code, _)
                if code == "PROVOST_DNE_AUDIT" then
                    seen_audit = true
                end
            end
        }

        local blocked = engine.check_http_request(
            "POST",
            "/v1/trading/accounts/acct-1/options/donotexercise",
            "{}",
            {},
            context
        )

        assert.is_false(blocked)
        assert.is_true(seen_audit)
    end)

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

    it("blocks notional orders estimated above share limit with valid limit_price", function()
        -- notional=$10,001 / limit_price=$100 = 100.01 shares > 100 limit
        local blocked, reason = engine.check_request(
            make_parsed({ notional = 10001, limit_price = 100 }),
            { max_trade_size = { enabled = true, params = { limit = 100 } } })
        assert.is_true(blocked)
        assert.truthy(reason:find("PROVOST_INTERVENTION"))
    end)

    it("allows notional orders estimated below share limit", function()
        -- notional=$5,000 / limit_price=$100 = 50 shares < 100 limit
        local rules_enabled = { max_trade_size = { enabled = true, params = { limit = 100 } } }
        local blocked = engine.check_request(
            make_parsed({ notional = 5000, limit_price = 100 }),
            rules_enabled)
        assert.is_false(blocked)
    end)

    it("blocks notional orders without limit_price (fail-safe)", function()
        local rules_enabled = { max_trade_size = { enabled = true, params = { limit = 100 } } }
        local blocked, reason = engine.check_request(
            make_parsed({ notional = 100000 }),
            rules_enabled)
        assert.is_true(blocked)
        assert.truthy(reason:find("limit_price"))
    end)

    it("blocks notional orders with zero or invalid limit_price", function()
        local rules_enabled = { max_trade_size = { enabled = true, params = { limit = 100 } } }
        local blocked_zero = engine.check_request(
            make_parsed({ notional = 100000, limit_price = 0 }),
            rules_enabled)
        assert.is_true(blocked_zero)
        local blocked_neg = engine.check_request(
            make_parsed({ notional = 100000, limit_price = -50 }),
            rules_enabled)
        assert.is_true(blocked_neg)
    end)

    it("respects custom limit value for notional orders", function()
        local rules_50 = { max_trade_size = { enabled = true, params = { limit = 50 } } }
        -- 50 shares at limit: notional=$5,000 / price=$100
        assert.is_false(engine.check_request(make_parsed({ notional = 5000, limit_price = 100 }), rules_50))
        -- 51 shares over limit: notional=$5,100 / price=$100
        assert.is_true(engine.check_request(make_parsed({ notional = 5100, limit_price = 100 }), rules_50))
    end)

    it("blocks trades above the configured dollar notional limit", function()
        local rules_value = { max_trade_notional = { enabled = true, params = { limit = 50000 } } }
        assert.is_true(engine.check_request(make_parsed({ notional = 51000, limit_price = 250 }), rules_value))
        assert.is_false(engine.check_request(make_parsed({ notional = 49000, limit_price = 250 }), rules_value))
    end)

    it("blocks qty orders against notional limit when limit_price is provided", function()
        local rules_value = { max_trade_notional = { enabled = true, params = { limit = 50000 } } }
        assert.is_true(engine.check_request(make_parsed({ qty = 210.7, limit_price = 242 }), rules_value))
        assert.is_false(engine.check_request(make_parsed({ qty = 200, limit_price = 242 }), rules_value))
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
-- allowed_tickers rule
-- ---------------------------------------------------------------------------
describe("rules_engine: allowed_tickers rule", function()

    local rules_enabled = {
        allowed_tickers = {
            enabled = true,
            params  = { tickers = { "SPY", "QQQ" } }
        }
    }
    local rules_disabled = {
        allowed_tickers = {
            enabled = false,
            params  = { tickers = { "SPY", "QQQ" } }
        }
    }

    -- DoD Test 1: allowlist disabled → any symbol passes
    it("does NOT block when rule is disabled (AAPL passes through)", function()
        local blocked = engine.check_request(make_parsed({ ticker = "AAPL" }), rules_disabled)
        assert.is_false(blocked)
    end)

    -- DoD Test 2a: enabled, ticker in list → allowed
    it("allows a ticker that IS in the allowlist (SPY)", function()
        local blocked = engine.check_request(make_parsed({ ticker = "SPY" }), rules_enabled)
        assert.is_false(blocked)
    end)

    it("allows a ticker that IS in the allowlist (QQQ)", function()
        local blocked = engine.check_request(make_parsed({ ticker = "QQQ" }), rules_enabled)
        assert.is_false(blocked)
    end)

    -- DoD Test 2b: enabled, ticker NOT in list → blocked
    it("blocks a ticker NOT in the allowlist (AAPL)", function()
        local blocked, reason = engine.check_request(make_parsed({ ticker = "AAPL" }), rules_enabled)
        assert.is_true(blocked)
        assert.is_string(reason)
        assert.truthy(reason:find("PROVOST_INTERVENTION"))
        assert.truthy(reason:find("AAPL"))
        assert.truthy(reason:find("not in the allowed symbol list"))
    end)

    -- Case-insensitive matching
    it("allows a ticker in lowercase that matches an uppercase entry (spy → SPY)", function()
        local blocked = engine.check_request(make_parsed({ ticker = "spy" }), rules_enabled)
        assert.is_false(blocked)
    end)

    -- Fail-open for requests with no ticker field
    it("does not block when ticker field is absent (fail-open for non-trade tools)", function()
        local blocked = engine.check_request(make_parsed({ quantity = 5 }), rules_enabled)
        assert.is_false(blocked)
    end)

    -- Invalid ticker type is rejected
    it("blocks when ticker field is a non-string type", function()
        local blocked, reason = engine.check_request(make_parsed({ ticker = 123 }), rules_enabled)
        assert.is_true(blocked)
        assert.truthy(reason:find("Invalid ticker type"))
    end)

    -- Priority: allowed_tickers fires before blocked_tickers
    it("blocks via allowlist rule (not blocklist) when allowlist is enabled", function()
        local both_rules = {
            allowed_tickers = { enabled = true, params = { tickers = { "SPY" } } },
            blocked_tickers = { enabled = true, params = { tickers = { "AAPL" } } }
        }
        local blocked, reason = engine.check_request(make_parsed({ ticker = "AAPL" }), both_rules)
        assert.is_true(blocked)
        assert.truthy(reason:find("not in the allowed symbol list"))
    end)

    -- symbol field alias is also normalised
    it("blocks via symbol field alias when ticker NOT in allowlist", function()
        local blocked, reason = engine.check_request(make_parsed({ symbol = "TSLA" }), rules_enabled)
        assert.is_true(blocked)
        assert.truthy(reason:find("TSLA"))
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

-- ---------------------------------------------------------------------------
-- cumulative_trade_notional rule
-- ---------------------------------------------------------------------------
describe("rules_engine: cumulative_trade_notional rule", function()

    local function make_store()
        local data = {}
        return {
            add = function(_, key, value, _)
                if data[key] ~= nil then
                    return nil, "exists"
                end
                data[key] = value
                return true
            end,
            get = function(_, key)
                return data[key]
            end,
            set = function(_, key, value, _)
                data[key] = value
                return true
            end
        }
    end

    it("blocks the second order when cumulative notional crosses the limit", function()
        local rules = {
            cumulative_trade_notional = {
                enabled = true,
                params = {
                    limit = 50000,
                    window_seconds = 300
                }
            }
        }
        local ctx = {
            user = "risk-user",
            machine = "risk-machine",
            store = make_store()
        }

        local blocked_first = engine.check_request(
            make_parsed({ symbol = "GOOGL", qty = "10", limit_price = "2500" }, "place_stock_order"),
            rules,
            ctx
        )
        assert.is_false(blocked_first)

        local blocked_second, reason_second = engine.check_request(
            make_parsed({ symbol = "GOOGL", qty = "11", limit_price = "2500" }, "place_stock_order"),
            rules,
            ctx
        )
        assert.is_true(blocked_second)
        assert.truthy(reason_second:find("Cumulative Risk Limit Exceeded"))
    end)

    it("tracks cumulative exposure separately per identity", function()
        local rules = {
            cumulative_trade_notional = {
                enabled = true,
                params = {
                    limit = 50000,
                    window_seconds = 300
                }
            }
        }
        local shared_store = make_store()

        local ctx_a = {
            user = "risk-user-a",
            machine = "risk-machine",
            store = shared_store
        }
        local ctx_b = {
            user = "risk-user-b",
            machine = "risk-machine",
            store = shared_store
        }

        local blocked_a = engine.check_request(
            make_parsed({ symbol = "GOOGL", qty = "20", limit_price = "2500" }, "place_stock_order"),
            rules,
            ctx_a
        )
        assert.is_false(blocked_a)

        local blocked_b = engine.check_request(
            make_parsed({ symbol = "GOOGL", qty = "20", limit_price = "2500" }, "place_stock_order"),
            rules,
            ctx_b
        )
        assert.is_false(blocked_b)
    end)

end)

-- ---------------------------------------------------------------------------
-- allowed_asset_classes rule
-- ---------------------------------------------------------------------------
describe("rules_engine: allowed_asset_classes rule", function()

    local crypto_only = {
        allowed_asset_classes = {
            enabled = true,
            params = { classes = { "crypto" } }
        }
    }

    local all_three = {
        allowed_asset_classes = {
            enabled = true,
            params = { classes = { "us_equity", "crypto", "us_option" } }
        }
    }

    it("allows crypto tool calls when crypto is allowed", function()
        local blocked = engine.check_request(
            make_parsed({ symbol = "BTC/USD", qty = "0.01" }, "place_crypto_order"),
            crypto_only)
        assert.is_false(blocked)
    end)

    it("blocks stock tool calls when only crypto is allowed", function()
        local blocked, reason = engine.check_request(
            make_parsed({ symbol = "MSFT", qty = "1" }, "place_stock_order"),
            crypto_only)
        assert.is_true(blocked)
        assert.truthy(reason:find("Asset class"))
        assert.truthy(reason:find("us_equity"))
    end)

    it("blocks option tool calls when only crypto is allowed", function()
        local blocked, reason = engine.check_request(
            make_parsed({ symbol = "AAPL240621C00195000", qty = "1" }, "place_option_order"),
            crypto_only)
        assert.is_true(blocked)
        assert.truthy(reason:find("us_option"))
    end)

    it("allows stock, option, and crypto tools when all classes are allowed", function()
        assert.is_false(engine.check_request(
            make_parsed({ symbol = "MSFT", qty = "1" }, "place_stock_order"),
            all_three))
        assert.is_false(engine.check_request(
            make_parsed({ symbol = "AAPL240621C00195000", qty = "1" }, "place_option_order"),
            all_three))
        assert.is_false(engine.check_request(
            make_parsed({ symbol = "BTC/USD", qty = "0.01" }, "place_crypto_order"),
            all_three))
    end)

    it("honors explicit asset_class when provided by the request payload", function()
        local blocked = engine.check_request(
            make_parsed({ symbol = "MSFT", qty = "1", asset_class = "crypto" }, "place_stock_order"),
            crypto_only)
        assert.is_false(blocked)
    end)

    it("does not block unknown tools that cannot be mapped to an asset class", function()
        local blocked = engine.check_request(
            make_parsed({ symbol = "MSFT", qty = "1" }, "get_stock_bars"),
            crypto_only)
        assert.is_false(blocked)
    end)

end)

    -- ---------------------------------------------------------------------------
    -- symbol_order_cooldown rule
    -- ---------------------------------------------------------------------------
    describe("rules_engine: symbol_order_cooldown rule", function()

        local function make_store()
            local data = {}
            return {
                add = function(_, key, value, _)
                    if data[key] ~= nil then
                        return nil, "exists"
                    end
                    data[key] = value
                    return true
                end,
                get = function(_, key) return data[key] end,
                set = function(_, key, value, _) data[key] = value; return true end
            }
        end

        local rules_enabled = {
            symbol_order_cooldown = { enabled = true, params = { window_seconds = 300 } }
        }
        local rules_disabled = {
            symbol_order_cooldown = { enabled = false, params = { window_seconds = 300 } }
        }

        it("allows the first order for a symbol", function()
            local ctx = { user = "u@x.com", machine = "m1", store = make_store() }
            local blocked = engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99" }, "place_stock_order"),
                rules_enabled, ctx)
            assert.is_false(blocked)
        end)

        it("blocks a second order for the same symbol within the window", function()
            local ctx = { user = "u@x.com", machine = "m1", store = make_store() }
            engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99" }, "place_stock_order"),
                rules_enabled, ctx)
            local blocked, reason = engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99" }, "place_stock_order"),
                rules_enabled, ctx)
            assert.is_true(blocked)
            assert.truthy(reason:find("PROVOST_INTERVENTION"))
            assert.truthy(reason:find("WMT"))
        end)

        it("blocks market orders for the same symbol (no limit_price bypass)", function()
            local ctx = { user = "u@x.com", machine = "m1", store = make_store() }
            engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99", type = "market" }, "place_stock_order"),
                rules_enabled, ctx)
            local blocked, reason = engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99", type = "market" }, "place_stock_order"),
                rules_enabled, ctx)
            assert.is_true(blocked)
            assert.truthy(reason:find("Cooldown"))
        end)

        it("allows a different symbol after the first is in cooldown", function()
            local ctx = { user = "u@x.com", machine = "m1", store = make_store() }
            engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99" }, "place_stock_order"),
                rules_enabled, ctx)
            local blocked = engine.check_request(
                make_parsed({ symbol = "AAPL", qty = "50" }, "place_stock_order"),
                rules_enabled, ctx)
            assert.is_false(blocked)
        end)

        it("does not block when rule is disabled", function()
            local ctx = { user = "u@x.com", machine = "m1", store = make_store() }
            engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99" }, "place_stock_order"),
                rules_enabled, ctx)
            local blocked = engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99" }, "place_stock_order"),
                rules_disabled, ctx)
            assert.is_false(blocked)
        end)

        it("skips enforcement when context or store is absent (fail-open)", function()
            local blocked = engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99" }, "place_stock_order"),
                rules_enabled)
            assert.is_false(blocked)
        end)

        it("tracks cooldown separately per user identity", function()
            local shared_store = make_store()
            local ctx_a = { user = "user-a@x.com", machine = "m1", store = shared_store }
            local ctx_b = { user = "user-b@x.com", machine = "m1", store = shared_store }
            engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99" }, "place_stock_order"),
                rules_enabled, ctx_a)
            local blocked = engine.check_request(
                make_parsed({ symbol = "WMT", qty = "99" }, "place_stock_order"),
                rules_enabled, ctx_b)
            assert.is_false(blocked)
        end)

    end)
