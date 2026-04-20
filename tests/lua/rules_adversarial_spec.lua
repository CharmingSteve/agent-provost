package.path = package.path .. ";lua/?.lua"
local engine = require("rules_engine")

local function make_parsed(args, tool_name)
    local parsed = { params = { arguments = args } }
    if tool_name then
        parsed.method = "tools/call"
        parsed.params.name = tool_name
    end
    return parsed
end

describe("rules_engine adversarial bypass resistance", function()
    it("blocks restricted ticker with whitespace injection", function()
        local rules = {
            blocked_tickers = { enabled = true, params = { tickers = { "GME" } } }
        }
        local blocked = engine.check_request(make_parsed({ ticker = "   GME   " }), rules)
        assert.is_true(blocked)
    end)

    it("blocks restricted ticker with null-byte injection", function()
        local rules = {
            blocked_tickers = { enabled = true, params = { tickers = { "GME" } } }
        }
        local blocked = engine.check_request(make_parsed({ ticker = "GME\0" }), rules)
        assert.is_true(blocked)
    end)

    it("blocks restricted_ticker_tool_rules on type confusion for ticker arrays", function()
        local rules = {
            restricted_ticker_tool_rules = {
                enabled = true,
                params = {
                    tools = { "place_stock_order" },
                    tickers = { "GME" }
                }
            }
        }
        local blocked, reason = engine.check_request(
            make_parsed({ ticker = { "GME" }, qty = "1" }, "place_stock_order"),
            rules
        )
        assert.is_true(blocked)
        assert.truthy(reason:find("Invalid ticker type"))
    end)

    it("blocks restricted_ticker_tool_rules when tool name includes padded whitespace", function()
        local rules = {
            restricted_ticker_tool_rules = {
                enabled = true,
                params = {
                    tools = { "place_stock_order" },
                    tickers = { "GME" }
                }
            }
        }
        local blocked = engine.check_request(
            make_parsed({ ticker = "GME", qty = "1" }, "  place_stock_order  "),
            rules
        )
        assert.is_true(blocked)
    end)
end)
