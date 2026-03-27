local function read_file(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

describe("default.conf proxy and body filter settings", function()
  local conf = read_file("default.conf")

  it("captures response body in body_filter_by_lua_block", function()
    assert.is_truthy(conf:match("body_filter_by_lua_block"))
    assert.is_truthy(conf:match("local MAX_CAPTURE_BYTES = 65536"))
    assert.is_truthy(conf:match("ngx%.var%.resp_body = buffered"))
  end)

  it("sets expected proxy headers and SSE behavior for hop 1", function()
    assert.is_truthy(conf:match("proxy_set_header Host %$host;"))
    assert.is_truthy(conf:match("proxy_set_header X%-Real%-IP %$remote_addr;"))
    assert.is_truthy(conf:match("proxy_http_version 1%.1;"))
    assert.is_truthy(conf:match("proxy_buffering off;"))
    assert.is_truthy(conf:match("proxy_cache off;"))
  end)
end)
