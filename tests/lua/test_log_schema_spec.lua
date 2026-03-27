local cjson = require("cjson.safe")

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

describe("default.conf log schema", function()
  local conf = read_file("default.conf")

  it("defines required JSON log keys", function()
    local required_keys = {
      "time_local",
      "remote_addr",
      "request",
      "status",
      "body_bytes_sent",
      "request_time",
      "upstream_response_time",
      "request_body",
      "resp_body",
    }

    for _, key in ipairs(required_keys) do
      assert.is_truthy(conf:match('"' .. key .. '"'))
    end
  end)
end)

describe("access log json schema parsing", function()
  it("contains expected keys on each line", function()
    local line = os.getenv("TEST_LOG_LINE") or table.concat({
      '{"time_local":"t","remote_addr":"1.1.1.1","request":"GET /mcp HTTP/1.1",',
      '"status":"200","body_bytes_sent":"10","request_time":"0.01",',
      '"upstream_response_time":"0.01","request_body":"{}","resp_body":"{}"}',
    })

    local decoded = cjson.decode(line)
    assert.is_not_nil(decoded)

    local expected = {
      "time_local",
      "remote_addr",
      "request",
      "status",
      "body_bytes_sent",
      "request_time",
      "upstream_response_time",
      "request_body",
      "resp_body",
    }

    for _, key in ipairs(expected) do
      assert.is_not_nil(decoded[key])
    end
  end)
end)
