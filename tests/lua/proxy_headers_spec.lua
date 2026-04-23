-- proxy_headers_spec.lua
-- Validates that the proxy header and routing directives are present and
-- correct inside default.conf without needing a live nginx instance.

describe("proxy headers and routing (default.conf)", function()

    local conf

    before_each(function()
        local f = io.open("default.conf", "r")
        assert.is_not_nil(f, "default.conf must be readable from the repo root")
        conf = f:read("*a")
        f:close()
    end)

    -- llm-to-mcp outbound headers
    it("llm-to-mcp forwards the Host header from $host", function()
        assert.truthy(conf:find("proxy_set_header Host %$host", 1, false))
    end)

    it("llm-to-mcp forwards X-Real-IP from $remote_addr", function()
        assert.truthy(conf:find("proxy_set_header X%-Real%-IP %$remote_addr", 1, false))
    end)

    it("llm-to-mcp proxies upstream to alpaca-mcp on port 8088", function()
        assert.truthy(conf:find("proxy_pass http://alpaca%-mcp:8088", 1, false))
    end)

    -- SSE / streaming settings on llm-to-mcp
    it("llm-to-mcp disables proxy buffering for SSE streaming", function()
        assert.truthy(conf:find("proxy_buffering off", 1, false))
    end)

    it("llm-to-mcp uses HTTP/1.1 for keep-alive upstream connections", function()
        assert.truthy(conf:find("proxy_http_version 1.1", 1, false))
    end)

    -- mcp-to-api upstream routing
    it("mcp-to-api /trading/ route proxies to paper-api.alpaca.markets", function()
        assert.truthy(conf:find("proxy_pass https://paper%-api%.alpaca%.markets", 1, false))
    end)

    it("mcp-to-api /data/ route proxies to data.alpaca.markets", function()
        assert.truthy(conf:find("proxy_pass https://data%.alpaca%.markets", 1, false))
    end)

    it("mcp-to-api /broker/ route proxies to broker-api.alpaca.markets", function()
        assert.truthy(conf:find("proxy_pass https://broker%-api%.alpaca%.markets", 1, false))
    end)

    -- TLS SNI on mcp-to-api
    it("mcp-to-api enables SSL SNI for upstream TLS handshake", function()
        assert.truthy(conf:find("proxy_ssl_server_name on", 1, false))
    end)

    -- Log format
    it("uses json_full log format for the audit ledger", function()
        assert.truthy(conf:find("log_format json_full", 1, false))
    end)

    it("records request body in the log format", function()
        assert.truthy(conf:find('"request_body"', 1, false))
    end)

    it("records response body in the log format", function()
        assert.truthy(conf:find('"resp_body"', 1, false))
    end)

    it("records provost user in the log format", function()
        assert.truthy(conf:find('"provost_user"', 1, false))
    end)

    it("records provost machine in the log format", function()
        assert.truthy(conf:find('"provost_machine"', 1, false))
    end)

    it("enforces the inbound provost token", function()
        assert.truthy(conf:find("MISSING_PROVOST_TOKEN", 1, true))
        assert.truthy(conf:find("INVALID_PROVOST_TOKEN", 1, true))
    end)

    it("requires inbound user and machine identity headers", function()
        assert.truthy(conf:find("MISSING_PROVOST_USER", 1, true))
        assert.truthy(conf:find("MISSING_PROVOST_MACHINE", 1, true))
    end)

end)
