#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CONF_FILE="$ROOT_DIR/default.conf"
}

@test "rate limit controls: shared dict is configured" {
  run grep -q "lua_shared_dict rate_limit 1m;" "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "rate limit controls: inbound guard checks cooldown and remaining" {
  run grep -q "PROVOST_COOLDOWN_ACTIVE" "$CONF_FILE"
  [ "$status" -eq 0 ]

  run grep -q "PROVOST_RATE_LIMIT_LOW" "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "rate limit controls: outbound header filter captures rate limits and 429" {
  run grep -q "header_filter_by_lua_block" "$CONF_FILE"
  [ "$status" -eq 0 ]

  run grep -q "X-RateLimit-Remaining" "$CONF_FILE"
  [ "$status" -eq 0 ]

  run grep -q "if ngx.status == 429 then" "$CONF_FILE"
  [ "$status" -eq 0 ]
}
