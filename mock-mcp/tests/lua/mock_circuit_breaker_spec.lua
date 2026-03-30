describe("sovereign circuit breaker", function()

    local function should_block(parsed)
        if parsed
           and parsed.method == "tools/call"
           and parsed.params
           and parsed.params.name == "execute_sovereign_transfer"
           and parsed.params.arguments then
            local args = parsed.params.arguments
            local action = tostring(args.action or "")
            local amount = tonumber(args.amount)
            if action == "mint" or (amount and amount > 1000000) then
                return true
            end
        end
        return false
    end

    it("blocks action=mint", function()
        local body = {
            method = "tools/call",
            params = {
                name = "execute_sovereign_transfer",
                arguments = {
                    action = "mint",
                    amount = 100,
                },
            },
        }
        assert.is_true(should_block(body))
    end)

    it("blocks transfer amount greater than 1,000,000", function()
        local body = {
            method = "tools/call",
            params = {
                name = "execute_sovereign_transfer",
                arguments = {
                    action = "transfer",
                    amount = 1000001,
                },
            },
        }
        assert.is_true(should_block(body))
    end)

    it("allows transfer amount equal to 1,000,000", function()
        local body = {
            method = "tools/call",
            params = {
                name = "execute_sovereign_transfer",
                arguments = {
                    action = "transfer",
                    amount = 1000000,
                },
            },
        }
        assert.is_false(should_block(body))
    end)

    it("does not apply rule to other tools", function()
        local body = {
            method = "tools/call",
            params = {
                name = "check_reserve_liquidity",
                arguments = {},
            },
        }
        assert.is_false(should_block(body))
    end)

end)
