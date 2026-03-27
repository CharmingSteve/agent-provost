#!/usr/bin/env bats

setup() {
  export TEST_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "verify_proxy_routing.sh clears all expected logs and exits cleanly when probe succeeds" {
  TMPDIR="$(mktemp -d)"
  cp "$TEST_REPO_ROOT/verify_proxy_routing.sh" "$TMPDIR/verify_proxy_routing.sh"
  mkdir -p "$TMPDIR/nginx-logs"
  printf 'x\n' > "$TMPDIR/nginx-logs/llm_to_alpaca_access.log"
  printf 'x\n' > "$TMPDIR/nginx-logs/mcp_to_alpaca_access.log"
  printf 'x\n' > "$TMPDIR/nginx-logs/llm_to_alpaca_error.log"
  printf 'x\n' > "$TMPDIR/nginx-logs/mcp_to_alpaca_error.log"

  mkdir -p "$TMPDIR/bin" "$TMPDIR/.venv/bin"
  cat > "$TMPDIR/bin/docker" <<'EOF'
#!/bin/sh
echo "docker compose $*" >/dev/null
exit 0
EOF
  chmod +x "$TMPDIR/bin/docker"

  cat > "$TMPDIR/.venv/bin/python" <<'EOF'
#!/bin/sh
echo "initialize_status=200"
echo "tools_call_status=200"
echo "tool_is_error=False"
cat <<'JSON' >> "$LOG_DIR/llm_to_alpaca_access.log"
{"time_local":"t","status":"200"}
JSON
cat <<'JSON' >> "$LOG_DIR/mcp_to_alpaca_access.log"
{"time_local":"t","status":"200"}
JSON
exit 0
EOF
  chmod +x "$TMPDIR/.venv/bin/python"

  run env PATH="$TMPDIR/bin:$PATH" ROOT_DIR="$TMPDIR" PROJECT_DIR="$TMPDIR" LOG_DIR="$TMPDIR/nginx-logs" sh "$TMPDIR/verify_proxy_routing.sh"
  [ "$status" -eq 0 ]
  [ -s "$TMPDIR/nginx-logs/llm_to_alpaca_access.log" ]
  [ -s "$TMPDIR/nginx-logs/mcp_to_alpaca_access.log" ]
  [ ! -s "$TMPDIR/nginx-logs/llm_to_alpaca_error.log" ]
  [ ! -s "$TMPDIR/nginx-logs/mcp_to_alpaca_error.log" ]
}
