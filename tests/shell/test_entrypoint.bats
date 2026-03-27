#!/usr/bin/env bats

setup() {
  export TEST_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "entrypoint.sh patches server.py and starts alpaca-mcp-server" {
  TMPDIR="$(mktemp -d)"
  cp "$TEST_REPO_ROOT/entrypoint.sh" "$TMPDIR/entrypoint.sh"
  mkdir -p "$TMPDIR/bin" "$TMPDIR/site/alpaca_mcp_server"
  cat > "$TMPDIR/site/alpaca_mcp_server/server.py" <<'EOF'
def _get_trading_base_url() -> str:
    return "https://paper-api.alpaca.markets"
EOF

  cat > "$TMPDIR/bin/python" <<'EOF'
#!/bin/sh
if [ "$1" = "-c" ]; then
  printf '%s\n' "$SITE_PACKAGES_OVERRIDE"
  exit 0
fi
exec /usr/bin/python3 "$@"
EOF
  chmod +x "$TMPDIR/bin/python"

  cat > "$TMPDIR/bin/alpaca-mcp-server" <<'EOF'
#!/bin/sh
echo "alpaca-mcp-server $*"
exit 0
EOF
  chmod +x "$TMPDIR/bin/alpaca-mcp-server"

  run env PATH="$TMPDIR/bin:$PATH" SITE_PACKAGES_OVERRIDE="$TMPDIR/site" sh "$TMPDIR/entrypoint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[entrypoint] Starting MCP Server with streamable-http transport..."* ]]
  [[ "$output" == *"alpaca-mcp-server --transport streamable-http --host 0.0.0.0 --port 8088"* ]]
  run grep -q "TRADE_API_URL" "$TMPDIR/site/alpaca_mcp_server/server.py"
  [ "$status" -eq 0 ]
}
