-- rule_loader_spec.lua
-- Unit tests for the pure JSON-parsing and validation logic used by
-- lua/rule_loader.lua.
--
-- Because rule_loader.lua relies on OpenResty-specific globals (ngx.shared,
-- ngx.timer.at, ngx.log) it cannot be required directly in busted.  These
-- tests instead extract and exercise the pure portions of its logic—JSON
-- parsing/validation and file reading—following the same pattern as the
-- existing circuit_breaker_spec.lua tests for default.conf logic.

local cjson = require("cjson.safe")

-- ---------------------------------------------------------------------------
-- Pure helpers mirroring rule_loader.lua internals
-- These are the functions that can be unit-tested without OpenResty.
-- ---------------------------------------------------------------------------

-- Reads a file and returns its content string, or nil + error message.
local function read_file(path)
    local f, err = io.open(path, "r")
    if not f then
        return nil, "cannot open '" .. path .. "': " .. (err or "unknown")
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return nil, "file is empty: " .. path
    end
    return content, nil
end

-- Parses and validates a rules JSON string.
-- Returns (rules_table, nil) on success or (nil, error_string) on failure.
local function parse_and_validate(content)
    if not content or content == "" then
        return nil, "empty content"
    end
    local rules, err = cjson.decode(content)
    if not rules then
        return nil, "JSON parse error: " .. (err or "unknown")
    end
    if type(rules) ~= "table" then
        return nil, "rules must be a JSON object, got: " .. type(rules)
    end
    -- Reject JSON arrays: their first key is an integer, not a string.
    local first_key = next(rules)
    if type(first_key) == "number" then
        return nil, "rules must be a JSON object, got a JSON array"
    end
    return rules, nil
end

-- Simulate the mtime-based change detection used in the reload timer.
-- Returns true when the new mtime differs from the last-seen mtime.
local function mtime_changed(last_mtime, current_mtime)
    return last_mtime ~= current_mtime
end

-- ---------------------------------------------------------------------------
-- JSON parsing / validation
-- ---------------------------------------------------------------------------
describe("rule_loader: JSON parsing and validation", function()

    it("parses a valid rules JSON object", function()
        local json = cjson.encode({
            max_trade_size = { enabled = true, params = { limit = 100 } }
        })
        local rules, err = parse_and_validate(json)
        assert.is_nil(err)
        assert.is_table(rules)
    end)

    it("rejects invalid (malformed) JSON", function()
        local rules, err = parse_and_validate("{not: valid json")
        assert.is_nil(rules)
        assert.is_string(err)
        assert.truthy(err:find("JSON parse error"))
    end)

    it("rejects empty string content", function()
        local rules, err = parse_and_validate("")
        assert.is_nil(rules)
        assert.is_string(err)
    end)

    it("rejects nil content", function()
        local rules, err = parse_and_validate(nil)
        assert.is_nil(rules)
        assert.is_string(err)
    end)

    it("rejects a JSON array (rules must be an object)", function()
        local rules, err = parse_and_validate("[1, 2, 3]")
        assert.is_nil(rules)
        assert.is_string(err)
        assert.truthy(err:find("JSON object"))
    end)

    it("rejects a JSON string scalar", function()
        local rules, err = parse_and_validate('"just a string"')
        assert.is_nil(rules)
        assert.is_string(err)
    end)

    it("accepts a JSON object with no known rule keys (future-proofing)", function()
        local json = cjson.encode({ unknown_rule = { enabled = false } })
        local rules, err = parse_and_validate(json)
        assert.is_nil(err)
        assert.is_table(rules)
    end)

end)

-- ---------------------------------------------------------------------------
-- Parsed rule structure
-- ---------------------------------------------------------------------------
describe("rule_loader: parsed rule structure", function()

    local SAMPLE_JSON = cjson.encode({
        max_trade_size = {
            enabled     = true,
            description = "Block large trades",
            params      = { limit = 100 }
        },
        blocked_tickers = {
            enabled     = true,
            description = "Block GME etc.",
            params      = { tickers = { "GME", "AMC" } }
        },
        trading_window = {
            enabled     = false,
            description = "Restrict hours",
            params      = { start_hour = 13, end_hour = 21 }
        }
    })

    it("contains the expected top-level rule keys", function()
        local rules, _ = parse_and_validate(SAMPLE_JSON)
        assert.is_table(rules.max_trade_size)
        assert.is_table(rules.blocked_tickers)
        assert.is_table(rules.trading_window)
    end)

    it("correctly reflects boolean enabled flags", function()
        local rules, _ = parse_and_validate(SAMPLE_JSON)
        assert.is_true(rules.max_trade_size.enabled)
        assert.is_true(rules.blocked_tickers.enabled)
        assert.is_false(rules.trading_window.enabled)
    end)

    it("preserves numeric params values (limit)", function()
        local rules, _ = parse_and_validate(SAMPLE_JSON)
        assert.equals(100, rules.max_trade_size.params.limit)
    end)

    it("preserves array params values (tickers)", function()
        local rules, _ = parse_and_validate(SAMPLE_JSON)
        local tickers = rules.blocked_tickers.params.tickers
        assert.is_table(tickers)
        assert.equals("GME", tickers[1])
        assert.equals("AMC", tickers[2])
    end)

end)

-- ---------------------------------------------------------------------------
-- Hot-reload change detection (pure mtime comparison logic)
-- ---------------------------------------------------------------------------
describe("rule_loader: hot-reload change detection", function()

    it("detects a changed mtime (reload required)", function()
        assert.is_true(mtime_changed("1000", "1001"))
    end)

    it("no reload needed when mtime is unchanged", function()
        assert.is_false(mtime_changed("1000", "1000"))
    end)

    it("triggers reload on first load (last_mtime is nil)", function()
        assert.is_true(mtime_changed(nil, "1000"))
    end)

    it("detects a changed limit in the rules (simulating live rule update)", function()
        local v1_json = cjson.encode({
            max_trade_size = { enabled = true, params = { limit = 100 } }
        })
        local v2_json = cjson.encode({
            max_trade_size = { enabled = true, params = { limit = 50 } }
        })

        local rules_v1, _ = parse_and_validate(v1_json)
        local rules_v2, _ = parse_and_validate(v2_json)

        -- The live rule set would differ after a hot reload.
        assert.not_equals(
            rules_v1.max_trade_size.params.limit,
            rules_v2.max_trade_size.params.limit
        )
        assert.equals(100, rules_v1.max_trade_size.params.limit)
        assert.equals(50,  rules_v2.max_trade_size.params.limit)
    end)

    it("detects a toggled enabled flag (rule turned off at runtime)", function()
        local v1_json = cjson.encode({
            max_trade_size = { enabled = true,  params = { limit = 100 } }
        })
        local v2_json = cjson.encode({
            max_trade_size = { enabled = false, params = { limit = 100 } }
        })

        local r1, _ = parse_and_validate(v1_json)
        local r2, _ = parse_and_validate(v2_json)
        assert.is_true(r1.max_trade_size.enabled)
        assert.is_false(r2.max_trade_size.enabled)
    end)

end)

-- ---------------------------------------------------------------------------
-- File reading (uses the actual rules.json from the repo root)
-- ---------------------------------------------------------------------------
describe("rule_loader: file loading", function()

    it("reads rules.json from disk without error", function()
        local content, err = read_file("rules.json")
        assert.is_nil(err, "read_file should succeed: " .. (err or ""))
        assert.is_string(content)
        assert.truthy(#content > 0)
    end)

    it("parses the on-disk rules.json successfully", function()
        local content, _ = read_file("rules.json")
        local rules, err = parse_and_validate(content)
        assert.is_nil(err, "parse should succeed: " .. (err or ""))
        assert.is_table(rules)
    end)

    it("on-disk rules.json contains max_trade_size rule", function()
        local content, _ = read_file("rules.json")
        local rules, _   = parse_and_validate(content)
        assert.is_table(rules.max_trade_size)
        assert.not_nil(rules.max_trade_size.enabled)
    end)

    it("on-disk rules.json contains blocked_tickers rule", function()
        local content, _ = read_file("rules.json")
        local rules, _   = parse_and_validate(content)
        assert.is_table(rules.blocked_tickers)
    end)

    it("on-disk rules.json contains trading_window rule", function()
        local content, _ = read_file("rules.json")
        local rules, _   = parse_and_validate(content)
        assert.is_table(rules.trading_window)
    end)

    it("returns an error when reading a non-existent file", function()
        local content, err = read_file("/tmp/nonexistent_rules_9999.json")
        assert.is_nil(content)
        assert.is_string(err)
    end)

end)
