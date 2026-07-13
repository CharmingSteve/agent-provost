#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${PROVOST_CONTAINER:-agent-provost}"
CLIENT_CONTAINER="${PROVOST_CLIENT_CONTAINER:-alpaca-mcp}"

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

discover_account_id() {
  docker exec -i \
    -e ALPACA_API_KEY="$ALPACA_API_KEY" \
    -e ALPACA_SECRET_KEY="$ALPACA_SECRET_KEY" \
    -e PROVOST_TOKEN="$PROVOST_TOKEN" \
    "$CLIENT_CONTAINER" python3 - <<'PY'
import json
import os
import urllib.request

api_key = (os.environ.get('ALPACA_API_KEY') or '').strip()
secret_key = (os.environ.get('ALPACA_SECRET_KEY') or '').strip()
if not api_key:
    with open('/run/secrets/alpaca_api_key', 'r', encoding='utf-8') as fh:
        api_key = fh.read().strip()
if not secret_key:
    with open('/run/secrets/alpaca_secret_key', 'r', encoding='utf-8') as fh:
        secret_key = fh.read().strip()

req = urllib.request.Request(
    url='http://agent-provost:8081/trading/v2/account',
    method='GET',
    headers={
        'APCA-API-KEY-ID': api_key,
        'APCA-API-SECRET-KEY': secret_key,
    },
)
with urllib.request.urlopen(req, timeout=20) as resp:
    payload = json.loads(resp.read().decode('utf-8', errors='replace'))

print(payload.get('id') or payload.get('account_id') or '')
PY
}

check_request() {
  local target_account_id="$1"
  docker exec -i \
    -e TARGET_ACCOUNT_ID="$target_account_id" \
    -e ALPACA_API_KEY="$ALPACA_API_KEY" \
    -e ALPACA_SECRET_KEY="$ALPACA_SECRET_KEY" \
    -e PROVOST_TOKEN="$PROVOST_TOKEN" \
    "$CLIENT_CONTAINER" python3 - <<'PY'
import os
import urllib.error
import urllib.request

api_key = (os.environ.get('ALPACA_API_KEY') or '').strip()
secret_key = (os.environ.get('ALPACA_SECRET_KEY') or '').strip()
if not api_key:
    with open('/run/secrets/alpaca_api_key', 'r', encoding='utf-8') as fh:
        api_key = fh.read().strip()
if not secret_key:
    with open('/run/secrets/alpaca_secret_key', 'r', encoding='utf-8') as fh:
        secret_key = fh.read().strip()

target = os.environ['TARGET_ACCOUNT_ID']
url = f'http://agent-provost:8081/broker/v1/trading/accounts/{target}/options/donotexercise'
payload = b'{"symbol_or_contract_id":"AAPL240621C00195000"}'
headers = {
    'APCA-API-KEY-ID': api_key,
    'APCA-API-SECRET-KEY': secret_key,
    'Content-Type': 'application/json',
}
req = urllib.request.Request(url=url, data=payload, method='POST', headers=headers)

status = 0
body = ''
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        status = int(resp.status)
        body = resp.read().decode('utf-8', errors='replace')
except urllib.error.HTTPError as exc:
    status = int(exc.code)
    body = exc.read().decode('utf-8', errors='replace')
except Exception as exc:
    status = 0
    body = str(exc)

print(status)
print(body)
PY
}

account_id="$(discover_account_id | tr -d '\r')"

if [[ -z "$account_id" ]]; then
  echo "failed to discover account id from /trading/v2/account" >&2
  exit 1
fi

wrong_account_id="${account_id%?}X"
if [[ "$wrong_account_id" == "$account_id" ]]; then
  wrong_account_id="${account_id}-wrong"
fi

correct_result="$(check_request "$account_id")"
correct_status="$(printf '%s\n' "$correct_result" | sed -n '1p' | tr -d '\r')"
correct_body="$(printf '%s\n' "$correct_result" | sed -n '2,$p' | tr -d '\r')"

if [[ "$correct_status" == "403" && "$correct_body" == *"Account ID Mismatch"* ]]; then
  echo "correct account id request unexpectedly blocked" >&2
  exit 1
fi

echo "PASS correct account id request: status=$correct_status"

wrong_result="$(check_request "$wrong_account_id")"
wrong_status="$(printf '%s\n' "$wrong_result" | sed -n '1p' | tr -d '\r')"
wrong_body="$(printf '%s\n' "$wrong_result" | sed -n '2,$p' | tr -d '\r')"

if [[ "$wrong_status" != "403" ]] || { [[ "$wrong_body" != *"Account ID Mismatch"* ]] && [[ "$wrong_body" != *"Account ID Discovery Failed"* ]]; }; then
  echo "wrong account id request was not blocked as expected" >&2
  echo "status=$wrong_status body=$wrong_body" >&2
  exit 1
fi

echo "PASS wrong account id request blocked by broker account guard"
