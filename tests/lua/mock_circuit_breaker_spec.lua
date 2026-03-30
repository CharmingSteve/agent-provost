describe("mock harness circuit breaker", function()

    local function should_block(parsed)
        if not parsed then
            return false
        end

        local args = nil
        local method = parsed.method

        if method == "execute_transaction" and parsed.params then
            args = parsed.params.arguments or parsed.params
        end

        if method == "tools/call" and parsed.params and parsed.params.name == "execute_transaction" then
            args = parsed.params.arguments or {}
        end

        if not args then
            return false
        end

        local qty = tonumber(args.qty) or tonumber(args.quantity)
        local ticker = tostring(args.ticker or "")

        return (qty ~= nil and qty > 100) or ticker == "GME"
    end

    it("blocks tools/call execute_transaction when qty > 100", function()
        local parsed = {
            method = "tools/call",
            params = {
                name = "execute_transaction",
                arguments = { ticker = "AAPL", qty = 150 },
            },
        }
        assert.is_true(should_block(parsed))
    end)

    it("blocks tools/call execute_transaction when ticker is GME", function()
        local parsed = {
            method = "tools/call",
            params = {
                name = "execute_transaction",
                arguments = { ticker = "GME", qty = 1 },
            },
        }
        assert.is_true(should_block(parsed))
    end)

    it("allows normal execute_transaction payload", function()
        local parsed = {
            method = "tools/call",
            params = {
                name = "execute_transaction",
                arguments = { ticker = "MSFT", qty = 5 },
            },
        }
        assert.is_false(should_block(parsed))
    end)

    it("ignores unrelated MCP methods", function()
        local parsed = {
            method = "tools/list",
            params = {},
        }
        assert.is_false(should_block(parsed))
    end)

end)
