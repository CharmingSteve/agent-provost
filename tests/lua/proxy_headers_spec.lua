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

    -- HOP-1 outbound headers
    it("hop-1 forwards the Host header from $host", function()
        assert.truthy(conf:find("proxy_set_header Host %$host", 1, false))
    end)

    it("hop-1 forwards X-Real-IP from $remote_addr", function()
        assert.truthy(conf:find("proxy_set_header X%-Real%-IP %$remote_addr", 1, false))
    end)

    it("hop-1 proxies upstream to alpaca-mcp on port 8088", function()
        assert.truthy(conf:find("proxy_pass http://alpaca%-mcp:8088", 1, false))
    end)

    -- SSE / streaming settings on HOP-1
    it("hop-1 disables proxy buffering for SSE streaming", function()
        assert.truthy(conf:find("proxy_buffering off", 1, false))
    end)

    it("hop-1 uses HTTP/1.1 for keep-alive upstream connections", function()
        assert.truthy(conf:find("proxy_http_version 1.1", 1, false))
    end)

    -- HOP-2 upstream routing
    it("hop-2 /trading/ route proxies to paper-api.alpaca.markets", function()
        assert.truthy(conf:find("proxy_pass https://paper%-api%.alpaca%.markets", 1, false))
    end)

    it("hop-2 /data/ route proxies to data.alpaca.markets", function()
        assert.truthy(conf:find("proxy_pass https://data%.alpaca%.markets", 1, false))
    end)

    it("hop-2 /broker/ route proxies to broker-api.alpaca.markets", function()
        assert.truthy(conf:find("proxy_pass https://broker%-api%.alpaca%.markets", 1, false))
    end)

    -- TLS SNI on HOP-2
    it("hop-2 enables SSL SNI for upstream TLS handshake", function()
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

end)
