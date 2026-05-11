#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CONF_FILE="$ROOT_DIR/default.conf"
  RULES_FILE="$ROOT_DIR/rules.json"
  SYNC_FILE="$ROOT_DIR/scripts/sync_state.sh"
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

@test "rate limit controls: default rules include inbound_request_rate_limit" {
  run grep -q '"inbound_request_rate_limit"' "$RULES_FILE"
  [ "$status" -eq 0 ]
}

@test "rate limit controls: sync_state maps RateLimitRPM to inbound rule" {
  run grep -q '\.RateLimitRPM | to_num' "$SYNC_FILE"
  [ "$status" -eq 0 ]
}

@test "rate limit controls: inbound limiter uses shared rules JSON" {
  run grep -q 'is_inbound_request_rate_exceeded(rules, rate_key)' "$CONF_FILE"
  [ "$status" -eq 0 ]

  run grep -q 'os.getenv("RATE_LIMIT_RPM")' "$CONF_FILE"
  [ "$status" -ne 0 ]
}
