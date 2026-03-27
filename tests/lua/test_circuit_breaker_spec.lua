local function read_file(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

describe("default.conf circuit breaker", function()
  local conf = read_file("default.conf")

  it("checks both quantity and qty fields", function()
    assert.is_truthy(conf:match("tonumber%(args%.quantity%)"))
    assert.is_truthy(conf:match("tonumber%(args%.qty%)"))
  end)

  it("blocks requests larger than 100 with HTTP 403", function()
    assert.is_truthy(conf:match("if qty and qty > 100 then"))
    assert.is_truthy(conf:match("ngx%.status = 403"))
    assert.is_truthy(conf:match('PROVOST_INTERVENTION: Risk Limit Exceeded'))
  end)
end)
