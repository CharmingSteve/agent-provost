-- body_filter_spec.lua
-- Unit tests for the response-body buffering logic used in default.conf
-- (body_filter_by_lua_block on both HOP-1 and HOP-2).
--
-- The pure buffer function mirrors the Lua block so we can exercise every
-- branch without a running nginx instance.

describe("body filter / ledger buffering", function()

    local MAX_CAPTURE_BYTES = 65536

    -- Pure extraction of the buffering logic from default.conf
    local function buffer_chunk(ctx_buffered, chunk, is_last)
        local buffered = ctx_buffered or ""
        local resp_body = nil
        if #buffered < MAX_CAPTURE_BYTES and chunk and #chunk > 0 then
            local remaining = MAX_CAPTURE_BYTES - #buffered
            if #chunk > remaining then
                buffered = buffered .. string.sub(chunk, 1, remaining)
            else
                buffered = buffered .. chunk
            end
        end
        if is_last then
            resp_body = buffered
        end
        return buffered, resp_body
    end

    it("accumulates multiple chunks into a single buffer", function()
        local buf, _ = buffer_chunk("", "hello", false)
        buf, _ = buffer_chunk(buf, " world", false)
        local _, resp = buffer_chunk(buf, "!", true)
        assert.equals("hello world!", resp)
    end)

    it("does not exceed MAX_CAPTURE_BYTES", function()
        local big = string.rep("x", MAX_CAPTURE_BYTES + 100)
        local buf, _ = buffer_chunk("", big, false)
        assert.equals(MAX_CAPTURE_BYTES, #buf)
    end)

    it("trims a chunk that would overflow the cap", function()
        local almost_full = string.rep("a", MAX_CAPTURE_BYTES - 10)
        local buf, _ = buffer_chunk(almost_full, string.rep("b", 20), false)
        assert.equals(MAX_CAPTURE_BYTES, #buf)
        assert.equals(string.rep("b", 10), string.sub(buf, -10))
    end)

    it("ignores empty chunks", function()
        local buf = buffer_chunk("existing", "", false)
        assert.equals("existing", buf)
    end)

    it("sets resp_body only on the final chunk", function()
        local buf, resp = buffer_chunk("", "data", false)
        assert.is_nil(resp)
        local buf2
        buf2, resp = buffer_chunk(buf, "", true)
        assert.equals("data", resp)
        assert.equals(buf, buf2)
    end)

    it("handles nil chunk gracefully", function()
        local buf, _ = buffer_chunk("", nil, false)
        assert.equals("", buf)
    end)

    it("preserves an already-full buffer when more data arrives", function()
        local full = string.rep("z", MAX_CAPTURE_BYTES)
        local buf, _ = buffer_chunk(full, "overflow", false)
        assert.equals(MAX_CAPTURE_BYTES, #buf)
    end)

    it("starts with empty buffer when ctx is nil", function()
        local buf, _ = buffer_chunk(nil, "start", false)
        assert.equals("start", buf)
    end)

    it("returns the complete buffer as resp_body on last-chunk signal", function()
        local buf, _ = buffer_chunk("", "part1", false)
        buf, _ = buffer_chunk(buf, "part2", false)
        local _, resp = buffer_chunk(buf, "part3", true)
        assert.equals("part1part2part3", resp)
    end)

end)
