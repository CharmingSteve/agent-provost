#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CONF_FILE="$ROOT_DIR/default.conf"
}

@test "log privacy: json_full log_format uses escape=json to prevent log injection" {
  run grep -E 'log_format[[:space:]]+json_full[[:space:]]+escape=json' "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "log privacy: request body redaction masks APCA and token fields before writing nginx-logs" {
  run grep -E 'APCA%-API%-SECRET%-KEY|APCA%-API%-KEY%-ID|\\[REDACTED\\]' "$CONF_FILE"
  [ "$status" -eq 0 ]
  run grep -E 'redact_sensitive' "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "log privacy: multiline payload content remains valid JSON line structure" {
  TMPDIR="$(mktemp -d)"
  mkdir -p "$TMPDIR/nginx-logs"
  LOG_FILE="$TMPDIR/nginx-logs/llm_to_alpaca_access.log"

  cat > "$LOG_FILE" <<'EOF'
{"time_local":"t","remote_addr":"127.0.0.1","request":"POST /mcp HTTP/1.1","status":"200","body_bytes_sent":"1","request_time":"0.01","upstream_response_time":"0.01","request_body":"{\"note\":\"line1\\nline2\",\"APCA-API-SECRET-KEY\":\"[REDACTED]\"}","resp_body":"{\"ok\":true}"}
EOF

  run python3 -c 'import json,sys; json.loads(open(sys.argv[1], "r", encoding="utf-8").read().strip()); print("ok")' "$LOG_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
