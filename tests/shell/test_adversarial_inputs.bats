#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CONF_FILE="$ROOT_DIR/default.conf"
}

@test "adversarial auth: malformed bearer strings are explicitly rejected" {
  run grep -E 'MALFORMED_BEARER_TOKEN' "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "adversarial auth: expired bearer strings are explicitly rejected" {
  run grep -E 'EXPIRED_BEARER_TOKEN' "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "adversarial auth: mixed-case bearer variants are normalized by regex match" {
  run grep -E '\^\[Bb\]\[Ee\]\[Aa\]\[Rr\]\[Ee\]\[Rr\]%s\+\(\.\+\)\$' "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "adversarial payloads: invalid/deeply nested JSON decode failures are blocked" {
  run grep -E 'INVALID_JSON_BODY' "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "adversarial payloads: client_max_body_size is set to cap oversized request bodies" {
  run grep -E 'client_max_body_size[[:space:]]+1m;' "$CONF_FILE"
  [ "$status" -eq 0 ]
}
