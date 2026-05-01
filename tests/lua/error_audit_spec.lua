describe("audit_error module", function()
  local original_ngx
  local original_package_path

  before_each(function()
    original_package_path = package.path
    package.path = "lua/?.lua;" .. package.path
    original_ngx = _G.ngx
    _G.ngx = {
      ERR = 3,
      var = {
        time_local = "23/Apr/2026:12:00:00 +0000",
        remote_addr = "127.0.0.1",
        request = "POST /mcp HTTP/1.1",
        req_body = '{"hello":"world"}',
        resp_body = '{"error":"x"}',
        request_id = "rid-fallback",
        http_x_provost_request_id = "rid-header",
        http_x_provost_user = "user@example.com",
        http_x_provost_machine = "MACHINE-1",
      },
      shared = {
        provost_ctx = {
          get = function(_, key)
            if key == "last:user" then return "last-user@example.com" end
            if key == "last:machine" then return "LAST-MACHINE" end
            if key == "last:request_id" then return "rid-last" end
            return nil
          end
        }
      },
      utctime = function()
        return "2026-04-23T12:00:00.000000Z"
      end,
      log = function(_, ...)
        _G.__last_log = table.concat({ ... }, "")
      end
    }
    package.loaded["audit_error"] = nil
  end)

  after_each(function()
    package.path = original_package_path
    _G.ngx = original_ngx
    _G.__last_log = nil
  end)

  it("emits PROVOST_AUDIT_ERROR JSON with request identity fields", function()
    local audit = require("audit_error")
    audit.emit("provost_mcp_to_llm_error", 401, "MISSING_PROVOST_TOKEN", "")

    assert.is_truthy(_G.__last_log:find("PROVOST_AUDIT_ERROR", 1, true))
    assert.is_truthy(_G.__last_log:find('"provost_request_id":"rid%-header"'))
    assert.is_truthy(_G.__last_log:find('"provost_user":"user@example%.com"'))
    assert.is_truthy(_G.__last_log:find('"provost_machine":"MACHINE%-1"'))
  end)

  it("parses audit error JSON when nginx suffix text follows the payload", function()
    local sample = table.concat({
      [[2026/04/23 14:54:06 [error] 7#7: *38 [lua] audit_error.lua:92: emit(): PROVOST_AUDIT_ERROR {]],
      [["provost_machine":"YOUR-MACHINE-NAME","status":"401","log_type":"error",]],
      [["provost_request_id":"check-err-123","error_detail":"","date":"2026-04-23 14:54:06",]],
      [["time_local":"23/Apr/2026:14:54:06 +0000","remote_addr":"173.194.76.188",]],
      [["request":"POST /mcp HTTP/1.1","request_body":"","resp_body":"",]],
      [["error_code":"MISSING_PROVOST_TOKEN","stream_tag":"provost_mcp_to_llm_error",]],
      [["provost_user":"your.email@domain.com"}, client: 173.194.76.188, server: localhost, ]],
      [[request: \"POST /mcp HTTP/1.1\", host: \"localhost:8088\""]]
    })

    local audit_json = sample:match("PROVOST_AUDIT_ERROR (%b{})")

    assert.is_truthy(audit_json, "expected audit_json to be captured despite suffix")
    local decoded = require("cjson.safe").decode(audit_json)
    assert.is_not_nil(decoded)
    assert.equals("your.email@domain.com", decoded.provost_user)
    assert.equals("YOUR-MACHINE-NAME", decoded.provost_machine)
    assert.equals("check-err-123", decoded.provost_request_id)
  end)
end)
