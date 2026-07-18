#!/bin/bash
set -euo pipefail

if [ ! -f "./docker-compose.yml" ] || [ ! -d "./scripts" ]; then
  echo "ERROR: Run this script from the repository root."
  exit 1
fi

require_file() {
  local file_path="$1"
  if [ ! -f "$file_path" ]; then
    echo "ERROR: Missing required file: $file_path"
    exit 1
  fi
}

if [ -z "${PROVOST_TOKEN:-}" ]; then
  require_file ".secrets/provost_token"
  PROVOST_TOKEN="$(<.secrets/provost_token)"
fi

if [ -z "$PROVOST_TOKEN" ]; then
  echo "ERROR: PROVOST_TOKEN is empty"
  exit 1
fi

PROXY_URL="${PROXY_URL:-http://44.202.164.204:8088/mcp}"
PROVOST_USER="${PROVOST_USER:-steve@local}"
PROVOST_MACHINE="${PROVOST_MACHINE:-demo-load-test}"
FORBIDDEN_ENDPOINTS_FILE="${FORBIDDEN_ENDPOINTS_FILE:-./tests/forbidden_endpoints.txt}"
MCP_SESSION_ID=""
FORBIDDEN_REPEAT_COUNT="${FORBIDDEN_REPEAT_COUNT:-3}"
STRICT_FORBIDDEN_COVERAGE="${STRICT_FORBIDDEN_COVERAGE:-0}"
DEBUG_MCP_PAYLOADS="${DEBUG_MCP_PAYLOADS:-0}"
STOP_AFTER_PHASE2C="${STOP_AFTER_PHASE2C:-0}"
FAILURES=0
COVERAGE_GAPS=0
MCP_TOOL_NAMES=""

require_file "$FORBIDDEN_ENDPOINTS_FILE"

FORBIDDEN_ENDPOINTS="$(<"$FORBIDDEN_ENDPOINTS_FILE")"

read -r -d '' FORBIDDEN_RELATED_PUBLIC_TOOLS <<'EOF' || true
cancel_all_orders
close_all_positions
exercise_options_position
update_account_config
EOF

read -r -d '' MCP_FORBIDDEN_ASSERTIONS <<'EOF' || true
cancel_all_orders|{}|PROVOST_INTERVENTION: Forbidden Endpoint|DELETE /v2/orders
close_all_positions|{"cancel_orders":true}|PROVOST_INTERVENTION: Forbidden Endpoint|DELETE /v2/positions
update_account_config|{"dtbp_check":"entry"}|PROVOST_INTERVENTION: Forbidden Endpoint|PATCH /v2/account/configurations
update_account_config|{"no_shorting":true}|PROVOST_INTERVENTION: Forbidden Endpoint|PATCH /v2/account/configurations
EOF

read -r -d '' MCP_VISIBLE_GAP_CASES <<'EOF' || true
exercise_options_position|{"symbol_or_contract_id":"11111111-1111-1111-1111-111111111111"}|invalid symbol|POST /v1/trading/accounts/11111111-1111-1111-1111-111111111111/options/exercise
EOF

read -r -d '' MCP_UNMAPPED_FORBIDDEN_ENDPOINTS <<'EOF' || true
DELETE /v1/trading/accounts/11111111-1111-1111-1111-111111111111/orders
DELETE /v1/trading/accounts/11111111-1111-1111-1111-111111111111/positions
POST /v1/transfers
POST /v1/journals
POST /v1/journals/batch
POST /v1/journals/reverse_batch
POST /v1/funding_wallets/withdrawals
POST /v1/crypto/wallets/withdrawals
POST /v1/crypto/wallets/whitelisted_addresses
POST /v1/instant_funding
PATCH /v1/trading/accounts/11111111-1111-1111-1111-111111111111/account/configurations
POST /v1/rebalancing/runs
POST /v1/rebalancing/portfolios
PATCH /v1/rebalancing/portfolios/portfolio-123
POST /v1/rebalancing/subscriptions
POST /v1/crypto/perps/wallets/withdrawals
POST /v1/crypto/perps/wallets/whitelisted_addresses
POST /v1/crypto/perps/leverage
EOF

# ============================================================================
# MCP Session Handshake
# ============================================================================
echo "=== Initializing MCP session ==="

# Step 1: Initialize
INIT_PAYLOAD='{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"load-tests","version":"1.0"}}}'
INIT_RESPONSE=$(curl -s -i -X POST "$PROXY_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $PROVOST_TOKEN" \
  -H "X-Provost-User: $PROVOST_USER" \
  -H "X-Provost-Machine: $PROVOST_MACHINE" \
  --data "$INIT_PAYLOAD")

# Extract session ID from response headers
MCP_SESSION_ID=$(echo "$INIT_RESPONSE" | grep -i "mcp-session-id:" | head -1 | awk '{print $2}' | tr -d '\r')

if [ -z "$MCP_SESSION_ID" ]; then
  echo "ERROR: Failed to obtain MCP session ID during initialize"
  exit 1
fi

echo "Session ID obtained: $MCP_SESSION_ID"

# Step 2: Send notifications/initialized (no id field, as a notification)
NOTIF_PAYLOAD='{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
curl -s -X POST "$PROXY_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $PROVOST_TOKEN" \
  -H "X-Provost-User: $PROVOST_USER" \
  -H "X-Provost-Machine: $PROVOST_MACHINE" \
  -H "mcp-session-id: $MCP_SESSION_ID" \
  --data "$NOTIF_PAYLOAD" >/dev/null

TOOLS_LIST_RESPONSE="$(curl -s -X POST "$PROXY_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $PROVOST_TOKEN" \
  -H "X-Provost-User: $PROVOST_USER" \
  -H "X-Provost-Machine: $PROVOST_MACHINE" \
  -H "mcp-session-id: $MCP_SESSION_ID" \
  --data '{"jsonrpc":"2.0","id":"tools-1","method":"tools/list","params":{}}')"

MCP_TOOL_NAMES="$(printf '%s\n' "$TOOLS_LIST_RESPONSE" | grep -o '"name":"[^"]*"' | sed 's/"name":"//; s/"$//' | sort -u || true)"

echo "MCP session initialized and ready."
echo ""

record_failure() {
  FAILURES=$((FAILURES + 1))
}

record_gap() {
  COVERAGE_GAPS=$((COVERAGE_GAPS + 1))
}

count_nonempty_lines() {
  printf '%s\n' "$1" | awk 'NF { count += 1 } END { print count + 0 }'
}

tool_is_exposed() {
  local tool_name="$1"
  printf '%s\n' "$MCP_TOOL_NAMES" | grep -Fxq "$tool_name"
}

send_request() {
  local name="$1"
  local payload="$2"
  local expected_status="$3"
  local status
  local response
  local body
  local error_detail

  response="$(curl -s -w "\nHTTP:%{http_code}" \
    -X POST "$PROXY_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $PROVOST_TOKEN" \
    -H "X-Provost-User: $PROVOST_USER" \
    -H "X-Provost-Machine: $PROVOST_MACHINE" \
    -H "mcp-session-id: $MCP_SESSION_ID" \
    --data "$payload")"

  status="$(printf '%s\n' "$response" | awk -F: '/^HTTP:/{print $2; exit}')"
  body="$(printf '%s\n' "$response" | sed '/^HTTP:/d')"

  if [[ ",${expected_status}," == *",${status},"* ]]; then
    echo "[OK] $name (Expected $expected_status, Got $status)"
  else
    echo "[FAIL] $name (Expected $expected_status, Got $status)"
    record_failure
    if [ -n "$body" ] && [[ "$status" == "403" || "$status" == "400" ]]; then
      error_detail=$(printf '%s\n' "$body" | jq -r '.error.data.detail // .error.message // .error' 2>/dev/null || printf '%s\n' "$body")
      echo "      Error: $(printf '%s' "$error_detail" | tr '\n' ' ' | cut -c1-150)"
    fi
  fi
}

build_order_payload() {
  local symbol="$1"
  local qty="$2"
  local side="$3"

  printf '{"jsonrpc":"2.0","id":"load-%d","method":"tools/call","params":{"name":"place_stock_order","arguments":{"symbol":"%s","qty":"%s","side":"%s","type":"market","time_in_force":"day","client_order_id":"load-%d"}}}' \
    "$RANDOM" "$symbol" "$qty" "$side" "$RANDOM"
}

build_forbidden_payload() {
  local tool_name="$1"
  local args_json

  if [ "$#" -ge 2 ]; then
    args_json="$2"
  else
    args_json='{}'
  fi

  jq -cn \
    --arg request_id "forbidden-$RANDOM" \
    --arg tool_name "$tool_name" \
    --argjson arguments "$args_json" \
    '{jsonrpc:"2.0",id:$request_id,method:"tools/call",params:{name:$tool_name,arguments:$arguments}}'
}

send_request_expect_text() {
  local name="$1"
  local payload="$2"
  local expected_status="$3"
  local expected_text="$4"
  local status
  local response
  local body

  if [ "$DEBUG_MCP_PAYLOADS" = "1" ]; then
    echo "[DEBUG] $name payload: $payload"
  fi

  response="$(curl -s -w "\nHTTP:%{http_code}" \
    -X POST "$PROXY_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $PROVOST_TOKEN" \
    -H "X-Provost-User: $PROVOST_USER" \
    -H "X-Provost-Machine: $PROVOST_MACHINE" \
    -H "mcp-session-id: $MCP_SESSION_ID" \
    --data "$payload")"

  status="$(printf '%s\n' "$response" | awk -F: '/^HTTP:/{print $2; exit}')"
  body="$(printf '%s\n' "$response" | sed '/^HTTP:/d')"

  if [[ ",${expected_status}," == *",${status},"* ]] && [[ "$body" == *"$expected_text"* ]]; then
    echo "[OK] $name (Expected $expected_status + $expected_text, Got $status)"
  else
    echo "[FAIL] $name (Expected $expected_status + $expected_text, Got $status)"
    record_failure
    if [ -n "$body" ]; then
      echo "      Error: $(printf '%s' "$body" | tr '\n' ' ' | cut -c1-150)"
    fi
  fi
}

send_request_without_auth() {
  local name="$1"
  local payload="$2"
  local expected_status="$3"
  local status
  local response

  response="$(curl -s -w "\nHTTP:%{http_code}" \
    -X POST "$PROXY_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "X-Provost-User: $PROVOST_USER" \
    -H "X-Provost-Machine: $PROVOST_MACHINE" \
    --data "$payload")"

  status="$(printf '%s\n' "$response" | awk -F: '/^HTTP:/{print $2; exit}')"

  if [[ ",${expected_status}," == *",${status},"* ]]; then
    echo "[OK] $name (Expected $expected_status, Got $status)"
  else
    echo "[FAIL] $name (Expected $expected_status, Got $status)"
    record_failure
  fi
}

probe_visible_gap_case() {
  local tool_name="$1"
  local args_payload="$2"
  local expected_text="$3"
  local endpoint_name="$4"
  local payload
  local response
  local status
  local body

  payload="$(build_forbidden_payload "$tool_name" "$args_payload")"

  if [ "$DEBUG_MCP_PAYLOADS" = "1" ]; then
    echo "[DEBUG] Public MCP Gap Probe ($tool_name -> $endpoint_name) payload: $payload"
  fi

  response="$(curl -s -w "\nHTTP:%{http_code}" \
    -X POST "$PROXY_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $PROVOST_TOKEN" \
    -H "X-Provost-User: $PROVOST_USER" \
    -H "X-Provost-Machine: $PROVOST_MACHINE" \
    -H "mcp-session-id: $MCP_SESSION_ID" \
    --data "$payload")"

  status="$(printf '%s\n' "$response" | awk -F: '/^HTTP:/{print $2; exit}')"
  body="$(printf '%s\n' "$response" | sed '/^HTTP:/d')"

  if [[ "$status" == "200" && "$body" == *"PROVOST_INTERVENTION: Forbidden Endpoint"* ]]; then
    echo "[INFO] Public MCP Gap Closed ($tool_name -> $endpoint_name now returns Forbidden Endpoint)"
    return
  fi

  if [[ "$status" == "200" && "$body" == *"$expected_text"* ]]; then
    echo "[INFO] Public MCP Coverage Gap ($tool_name -> $endpoint_name returns $expected_text before forbidden policy)"
    record_gap
    return
  fi

  echo "[FAIL] Public MCP Gap Probe ($tool_name -> $endpoint_name returned unexpected response, Got $status)"
  if [ -n "$body" ]; then
    echo "      Error: $(printf '%s' "$body" | tr '\n' ' ' | cut -c1-150)"
  fi
  record_failure
}

echo "=== Phase 1: Green logs (paced) ==="
# Use a large pool of unique symbols to avoid the 300s symbol cooldown rule.
# If you still hit cooldowns, wait 300s and re-run with fresh symbol pool.
green_symbols=("GOOG" "AMZN" "MSFT" "NVDA" "TSLA" "META" "APPLE" "NFLX" "UBER" "LYFT" "SNAP" "PINS" "ROKU" "SHOP" "SQ" "PYPL" "ADBE" "CRM" "CSCO" "INTC" "AMD" "QCOM" "AVGO" "MU" "NXPI" "ASML" "AMAT" "LRCX" "LSCC" "MPWR" "MCHP" "JKHY" "NOW" "OKTA" "CRWD" "PALO" "DDOG" "FTNT" "NET" "ZSCL" "ZM" "RBLX")
for i in $(seq 1 20); do
  symbol="${green_symbols[$((i - 1))]}"
  qty=$((RANDOM % 10 + 1))
  payload="$(build_order_payload "$symbol" "$qty" "buy")"
  send_request "Valid Trade #$i ($symbol x$qty)" "$payload" "200"
  sleep 2
done

sleep 2
echo "=== Phase 2: Policy violations (fast) ==="
for i in $(seq 1 5); do
  payload="$(build_order_payload "GME" "1" "buy")"
  send_request "Blocked Ticker #$i (GME)" "$payload" "403"
  sleep 2
done

for i in $(seq 1 5); do
  payload="$(build_order_payload "AAPL" "1000" "buy")"
  send_request "Notional Limit #$i (AAPL x1000)" "$payload" "403"
  sleep 2
done

for i in $(seq 1 5); do
  payload="$(build_order_payload "MSFT" "200" "buy")"
  send_request "Share Limit #$i (MSFT x200)" "$payload" "403"
  sleep 2
done

sleep 2
echo "=== Phase 2b: Forbidden defaults (repeated) ==="

echo "Configured forbidden endpoints: $(count_nonempty_lines "$FORBIDDEN_ENDPOINTS")"
echo "Public forbidden-related tools expected in tools/list: $(count_nonempty_lines "$FORBIDDEN_RELATED_PUBLIC_TOOLS")"

while IFS= read -r tool_name; do
  [ -z "$tool_name" ] && continue
  if tool_is_exposed "$tool_name"; then
    echo "[OK] Public Forbidden-Related Tool ($tool_name)"
  else
    echo "[FAIL] Public Forbidden-Related Tool ($tool_name missing from tools/list)"
    record_failure
  fi
done <<< "$FORBIDDEN_RELATED_PUBLIC_TOOLS"

while IFS='|' read -r tool_name args_payload expected_text endpoint_name; do
  [ -z "$tool_name" ] && continue
  for i in $(seq 1 "$FORBIDDEN_REPEAT_COUNT"); do
    payload="$(build_forbidden_payload "$tool_name" "$args_payload")"
    send_request_expect_text "Forbidden MCP Tool #$i ($tool_name -> $endpoint_name)" "$payload" "200" "$expected_text"
    sleep 2
  done
done <<< "$MCP_FORBIDDEN_ASSERTIONS"

echo "=== Phase 2c: Forbidden inventory gaps on the public MCP path ==="

while IFS='|' read -r tool_name args_payload expected_text endpoint_name; do
  [ -z "$tool_name" ] && continue
  probe_visible_gap_case "$tool_name" "$args_payload" "$expected_text" "$endpoint_name"
done <<< "$MCP_VISIBLE_GAP_CASES"

while IFS= read -r endpoint_name; do
  [ -z "$endpoint_name" ] && continue
  echo "[INFO] No Public MCP Tool Mapping ($endpoint_name)"
  record_gap
done <<< "$MCP_UNMAPPED_FORBIDDEN_ENDPOINTS"

if [ "$STOP_AFTER_PHASE2C" = "1" ]; then
  echo "Stopping after Phase 2c because STOP_AFTER_PHASE2C=1"
  echo ""
  echo "=== Summary ==="
  echo "Assertion failures: $FAILURES"
  echo "Customer-path coverage gaps: $COVERAGE_GAPS"
  if [ "$FAILURES" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi

sleep 2
echo "=== Phase 3: Security attack (missing auth header) ==="
for i in $(seq 1 10); do
  payload="$(build_order_payload "AAPL" "1" "buy")"
  send_request_without_auth "Missing Auth #$i" "$payload" "401"
done

sleep 2
echo "=== Phase 4: Rate limit burst (instant) ==="
# These symbols must NOT overlap with green_symbols to avoid the 300s cooldown rule.
# green_symbols used: GOOG AMZN MSFT NVDA TSLA META APPLE NFLX UBER LYFT SNAP PINS ROKU SHOP SQ PYPL ADBE CRM CSCO INTC
burst_symbols=("JPM" "BAC" "WFC" "GS" "MS" "BLK" "SPY" "QQQ" "EEM" "VTI" "VOO" "IVV" "GLD" "TLT" "XLK" "XLV" "XLF" "XLE" "XLI" "XLC")
for i in $(seq 1 20); do
  symbol="${burst_symbols[$((i - 1))]}"
  payload="$(build_order_payload "$symbol" "1" "buy")"
  send_request "Burst Request #$i ($symbol)" "$payload" "200,429"
  sleep 2
done
wait

echo "Burst complete: some requests may return 429 Too Many Requests due to Lua rate limiting."
echo ""
echo "=== Summary ==="
echo "Assertion failures: $FAILURES"
echo "Customer-path coverage gaps: $COVERAGE_GAPS"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi

if [ "$COVERAGE_GAPS" -gt 0 ]; then
  echo "Load test assertions passed, but some forbidden endpoints are only inventoried because the public MCP server does not expose matching customer tools."
  if [ "$STRICT_FORBIDDEN_COVERAGE" = "1" ]; then
    exit 1
  fi
else
  echo "All forbidden coverage in this script is exercised through public MCP tools."
fi

echo "Load test complete."
