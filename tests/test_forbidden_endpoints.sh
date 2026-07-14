#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${PROVOST_CONTAINER:-agent-provost}"
CLIENT_CONTAINER="${PROVOST_CLIENT_CONTAINER:-alpaca-mcp}"
ENDPOINTS_FILE="${FORBIDDEN_ENDPOINTS_FILE:-./tests/forbidden_endpoints.txt}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

ALPACA_API_KEY="${ALPACA_API_KEY:-}"
ALPACA_SECRET_KEY="${ALPACA_SECRET_KEY:-}"
PROVOST_TOKEN="${PROVOST_TOKEN:-}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "container '$CONTAINER_NAME' is not running" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CLIENT_CONTAINER"; then
  echo "container '$CLIENT_CONTAINER' is not running" >&2
  exit 1
fi

if [[ ! -f "$ENDPOINTS_FILE" ]]; then
  echo "forbidden endpoints file '$ENDPOINTS_FILE' is missing" >&2
  exit 1
fi

ENDPOINTS="$(<"$ENDPOINTS_FILE")"

failures=0

request_once() {
  local method="$1"
  local route_prefix="$2"
  local path="$3"

  docker exec -i \
    -e METHOD="$method" \
    -e ROUTE_PREFIX="$route_prefix" \
    -e TARGET_PATH="$path" \
    -e ALPACA_API_KEY="$ALPACA_API_KEY" \
    -e ALPACA_SECRET_KEY="$ALPACA_SECRET_KEY" \
    -e PROVOST_TOKEN="$PROVOST_TOKEN" \
    "$CLIENT_CONTAINER" python3 - <<'PY'
import json
import os
import urllib.error
import urllib.request

method = os.environ["METHOD"]
route_prefix = os.environ["ROUTE_PREFIX"]
target_path = os.environ["TARGET_PATH"]

api_key = (os.environ.get("ALPACA_API_KEY") or "").strip()
secret_key = (os.environ.get("ALPACA_SECRET_KEY") or "").strip()
if not api_key:
  with open("/run/secrets/alpaca_api_key", "r", encoding="utf-8") as fh:
    api_key = fh.read().strip()
if not secret_key:
  with open("/run/secrets/alpaca_secret_key", "r", encoding="utf-8") as fh:
    secret_key = fh.read().strip()

url = f"http://agent-provost:8081{route_prefix}{target_path}"
data = b"{}"
headers = {
  "APCA-API-KEY-ID": api_key,
  "APCA-API-SECRET-KEY": secret_key,
  "Content-Type": "application/json",
}
req = urllib.request.Request(url=url, data=data, method=method, headers=headers)

status = 0
body = ""
try:
  with urllib.request.urlopen(req, timeout=20) as resp:
    status = int(resp.status)
    body = resp.read().decode("utf-8", errors="replace")
except urllib.error.HTTPError as exc:
  status = int(exc.code)
  body = exc.read().decode("utf-8", errors="replace")
except Exception as exc:
  status = 0
  body = str(exc)

print(status)
print(body)
PY
}

while IFS= read -r line; do
  [[ -z "$line" ]] && continue

  method="${line%% *}"
  path="${line#* }"
  route_prefix="/trading"
  if [[ "$path" == /v1/trading/accounts/* ]]; then
    route_prefix="/broker"
  fi

  response="$(request_once "$method" "$route_prefix" "$path")"

  status="$(printf '%s\n' "$response" | sed -n '1p' | tr -d '\r')"
  body="$(printf '%s\n' "$response" | sed -n '2,$p' | tr -d '\r')"

  if [[ "$status" != "403" ]] || [[ "$body" != *"PROVOST_INTERVENTION"* ]] || [[ "$body" != *"Forbidden Endpoint"* ]]; then
    echo "FAIL $method $path status=${status:-none} body=${body:-none}"
    failures=$((failures + 1))
  else
    echo "PASS $method $path"
  fi

done <<< "$ENDPOINTS"

if [[ "$failures" -gt 0 ]]; then
  echo "Forbidden endpoint test failures: $failures" >&2
  exit 1
fi

echo "All forbidden endpoints returned 403 PROVOST_INTERVENTION: Forbidden Endpoint"
