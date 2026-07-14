#!/bin/bash
set -euo pipefail

if [ ! -f "./docker-compose.yml" ] || [ ! -d "./scripts" ]; then
  echo "ERROR: Run this script from the repository root."
  exit 1
fi

require_secret_file() {
  local file_path="$1"
  if [ ! -f "$file_path" ]; then
    echo "ERROR: Missing required secret file: $file_path"
    exit 1
  fi
}

if [ -z "${PROVOST_TOKEN:-}" ]; then
  require_secret_file ".secrets/provost_token"
  PROVOST_TOKEN="$(<.secrets/provost_token)"
fi

if [ -z "$PROVOST_TOKEN" ]; then
  echo "ERROR: PROVOST_TOKEN is empty"
  exit 1
fi

PROXY_URL="${PROXY_URL:-http://100.53.91.94:8088/mcp}"
PROXY_BASE_URL="${PROXY_URL%/mcp}"
PROVOST_USER="${PROVOST_USER:-steve@local}"
PROVOST_MACHINE="${PROVOST_MACHINE:-demo-load-test}"
MCP_SESSION_ID=""
ALPACA_API_KEY="${ALPACA_API_KEY:-}"
ALPACA_SECRET_KEY="${ALPACA_SECRET_KEY:-}"
FORBIDDEN_REPEAT_COUNT="${FORBIDDEN_REPEAT_COUNT:-3}"

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

echo "MCP session initialized and ready."
echo ""

send_request() {
  local name="$1"
  local payload="$2"
  local expected_status="$3"
  local status
  local response
  local body

  response="$(curl -s -w "\nHTTP:%{http_code}" \
    -X POST "$PROXY_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $PROVOST_TOKEN" \
    -H "X-Provost-User: $PROVOST_USER" \
    -H "X-Provost-Machine: $PROVOST_MACHINE" \
    -H "mcp-session-id: $MCP_SESSION_ID" \
    --data "$payload")"

  status="$(echo "$response" | grep "^HTTP:" | cut -d: -f2)"
  body="$(echo "$response" | grep -v "^HTTP:" | tail -1)"

  if [[ ",${expected_status}," == *",${status},"* ]]; then
    echo "[OK] $name (Expected $expected_status, Got $status)"
  else
    echo "[FAIL] $name (Expected $expected_status, Got $status)"
    if [ -n "$body" ] && [[ "$status" == "403" || "$status" == "400" ]]; then
      error_detail=$(echo "$body" | jq -r '.error.data.detail // .error.message // .error' 2>/dev/null || echo "$body")
      echo "      Error: $(echo "$error_detail" | cut -c1-150)"
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
  local args_json="${2:-{}}"

  printf '{"jsonrpc":"2.0","id":"forbidden-%d","method":"tools/call","params":{"name":"%s","arguments":%s}}' \
    "$RANDOM" "$tool_name" "$args_json"
}

load_secret_if_empty() {
  local var_name="$1"
  local file_path="$2"
  if [ -z "${!var_name:-}" ] && [ -f "$file_path" ]; then
    printf -v "$var_name" '%s' "$(<"$file_path")"
  fi
}

send_endpoint_request() {
  local name="$1"
  local method="$2"
  local route_prefix="$3"
  local path="$4"
  local expected_status="$5"
  local status
  local response
  local body

  response="$(curl -s -w "\nHTTP:%{http_code}" \
    -X "$method" "${PROXY_BASE_URL}${route_prefix}${path}" \
    -H "Content-Type: application/json" \
    -H "APCA-API-KEY-ID: $ALPACA_API_KEY" \
    -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" \
    --data '{}')"

  status="$(echo "$response" | grep "^HTTP:" | cut -d: -f2)"
  body="$(echo "$response" | grep -v "^HTTP:" | tail -1)"

  if [[ ",${expected_status}," == *",${status},"* ]]; then
    echo "[OK] $name (Expected $expected_status, Got $status)"
  else
    echo "[FAIL] $name (Expected $expected_status, Got $status)"
    if [ -n "$body" ] && [[ "$status" == "403" || "$status" == "400" ]]; then
      error_detail=$(echo "$body" | jq -r '.error.data.detail // .error.message // .error' 2>/dev/null || echo "$body")
      echo "      Error: $(echo "$error_detail" | cut -c1-150)"
    fi
  fi
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

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for forbidden endpoint list parsing"
  exit 1
fi

load_secret_if_empty "ALPACA_API_KEY" ".secrets/alpaca_api_key"
load_secret_if_empty "ALPACA_SECRET_KEY" ".secrets/alpaca_secret_key"

if [ -z "$ALPACA_API_KEY" ] || [ -z "$ALPACA_SECRET_KEY" ]; then
  echo "ERROR: ALPACA_API_KEY and ALPACA_SECRET_KEY are required to run forbidden endpoint tests"
  exit 1
fi

mapfile -t forbidden_endpoints < <(jq -r '.forbidden_tools.params.tools[]' rules.json)

if [ "${#forbidden_endpoints[@]}" -eq 0 ]; then
  echo "ERROR: No forbidden endpoints found in rules.json"
  exit 1
fi

echo "Loaded ${#forbidden_endpoints[@]} forbidden endpoints from rules.json"

for round in $(seq 1 "$FORBIDDEN_REPEAT_COUNT"); do
  for endpoint in "${forbidden_endpoints[@]}"; do
    method="${endpoint%% *}"
    path="${endpoint#* }"
    route_prefix="/trading"
    if [[ "$path" == /v1/trading/accounts/* ]]; then
      route_prefix="/broker"
    fi

    send_endpoint_request "Forbidden Endpoint #$round ($method $path)" "$method" "$route_prefix" "$path" "403"
    sleep 2
  done
done

sleep 2
echo "=== Phase 3: Security attack (missing auth header) ==="
for i in $(seq 1 10); do
  payload="$(build_order_payload "AAPL" "1" "buy")"
  status="$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$PROXY_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "X-Provost-User: $PROVOST_USER" \
    -H "X-Provost-Machine: $PROVOST_MACHINE" \
    --data "$payload")"

  if [ "$status" = "401" ]; then
    echo "[OK] Missing Auth #$i (Expected 401, Got $status)"
  else
    echo "[FAIL] Missing Auth #$i (Expected 401, Got $status)"
  fi
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
echo "Load test complete."
