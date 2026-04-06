#!/bin/sh
set -e

ROOT_DIR="${ROOT_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/nginx-logs}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

cd "$ROOT_DIR"

mkdir -p "$LOG_DIR"

: > "$LOG_DIR/llm_to_mcp_access.log"
: > "$LOG_DIR/mcp_to_api_access.log"
: > "$LOG_DIR/llm_to_mcp_error.log"
: > "$LOG_DIR/mcp_to_api_error.log"

echo "[verify-mock] starting stack"
"$DOCKER_BIN" compose up -d --build --force-recreate >/dev/null

# Wait until mock-mcp reports healthy startup logs.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if "$DOCKER_BIN" compose logs --tail=20 mock-mcp | grep -q "Uvicorn running on"; then
        break
    fi
    sleep 1
done

echo "[verify-mock] sending MCP calls through hop-1"
if ! "$DOCKER_BIN" compose exec -T mock-mcp python - <<'PY'
import json
import time
import requests

candidate_urls = [
    "http://agent-provost:8000/mcp",
    "http://mock-agent-provost:8000/mcp",
]
url = candidate_urls[0]
sid = None


def parse_payload(text: str):
    data_lines = [ln.split(":", 1)[1].strip() for ln in text.splitlines() if ln.startswith("data:")]
    if data_lines:
        joined = "\n".join(data_lines)
        try:
            return json.loads(joined)
        except Exception:
            return {"raw": joined}
    try:
        return json.loads(text)
    except Exception:
        return {"raw": text}


def call(sess, rid, method, params=None, timeout_seconds=30):
    global sid
    headers = {
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json",
    }
    if sid:
        headers["mcp-session-id"] = sid

    payload = {"jsonrpc": "2.0", "method": method}
    if rid is not None:
        payload["id"] = rid
    if params is not None:
        payload["params"] = params

    try:
        resp = sess.post(url, headers=headers, json=payload, timeout=timeout_seconds)
    except requests.exceptions.RequestException as exc:
        return 0, {"error": str(exc)}
    if resp.headers.get("mcp-session-id"):
        sid = resp.headers["mcp-session-id"]
    return resp.status_code, parse_payload(resp.text)


with requests.Session() as s:
    init_status = 0
    init_payload = {}
    for _ in range(60):
        for candidate in candidate_urls:
            url = candidate
            init_status, init_payload = call(
                s,
                1,
                "initialize",
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "mock-verify", "version": "1.0"},
                },
                timeout_seconds=2,
            )
            if init_status == 200:
                break
        if init_status == 200:
            break
        time.sleep(1)

    if init_status != 200:
        raise SystemExit(
            f"initialize failed (status={init_status}, payload={init_payload}, tried={candidate_urls})"
        )

    call(s, None, "notifications/initialized", {})

    tools_status, tools_payload = call(s, 2, "tools/list", {})
    if tools_status != 200:
        raise SystemExit(f"tools/list failed with status {tools_status}")

    ok_status, ok_payload = call(
        s,
        3,
        "tools/call",
        {
            "name": "get_portfolio_state",
            "arguments": {},
        },
    )
    if ok_status != 200:
        raise SystemExit(f"get_portfolio_state failed with status {ok_status}")

    tx_status, tx_payload = call(
        s,
        4,
        "tools/call",
        {
            "name": "execute_transaction",
            "arguments": {
                "ticker": "AAPL",
                "action": "buy",
                "qty": 5,
                "price": 120.5,
            },
        },
    )
    if tx_status != 200:
        raise SystemExit(f"execute_transaction failed with status {tx_status}")

    # Should be blocked by hop-1 policy.
    blocked_status, _ = call(
        s,
        5,
        "tools/call",
        {
            "name": "execute_transaction",
            "arguments": {
                "ticker": "GME",
                "action": "buy",
                "qty": 1,
                "price": 23.0,
            },
        },
    )
    if blocked_status != 403:
        raise SystemExit(f"expected GME block (403), got {blocked_status}")

    blocked_qty_status, _ = call(
        s,
        6,
        "tools/call",
        {
            "name": "execute_transaction",
            "arguments": {
                "ticker": "MSFT",
                "action": "buy",
                "qty": 150,
                "price": 99.0,
            },
        },
    )
    if blocked_qty_status != 403:
        raise SystemExit(f"expected qty block (403), got {blocked_qty_status}")

    print("initialize_status=200")
    print(f"mcp_url={url}")
    print("tools_status=200")
    print(f"get_portfolio_state_status={ok_status}")
    print(f"execute_transaction_status={tx_status}")
    print(f"blocked_gme_status={blocked_status}")
    print(f"blocked_qty_status={blocked_qty_status}")
    print(f"tools_payload_keys={list(tools_payload.keys()) if isinstance(tools_payload, dict) else 'raw'}")
    print(f"portfolio_payload_keys={list(ok_payload.keys()) if isinstance(ok_payload, dict) else 'raw'}")
    print(f"transaction_payload_keys={list(tx_payload.keys()) if isinstance(tx_payload, dict) else 'raw'}")
PY
then
    echo "[verify-mock] diagnostics: compose ps"
    "$DOCKER_BIN" compose ps || true
    echo "[verify-mock] diagnostics: agent-provost logs"
    "$DOCKER_BIN" compose logs --tail=120 agent-provost || true
    echo "[verify-mock] diagnostics: mock-mcp logs"
    "$DOCKER_BIN" compose logs --tail=120 mock-mcp || true
    exit 1
fi

echo "[verify-mock] checking bounded tail snippets"
llm_tail="$(tail -n 8 "$LOG_DIR/llm_to_mcp_access.log" || true)"
mcp_tail="$(tail -n 8 "$LOG_DIR/mcp_to_api_access.log" || true)"

[ -n "$llm_tail" ] || { echo "[verify-mock] FAIL: hop-1 access log has no lines"; exit 1; }
[ -n "$mcp_tail" ] || { echo "[verify-mock] FAIL: hop-2 access log has no lines"; exit 1; }

printf '%s\n' "$llm_tail" | grep -q 'request_body' || { echo "[verify-mock] FAIL: hop-1 request_body missing"; exit 1; }
printf '%s\n' "$llm_tail" | grep -q 'resp_body' || { echo "[verify-mock] FAIL: hop-1 resp_body missing"; exit 1; }
printf '%s\n' "$llm_tail" | grep -q 'execute_transaction' || { echo "[verify-mock] FAIL: hop-1 missing execute_transaction payload"; exit 1; }

printf '%s\n' "$mcp_tail" | grep -q 'request_body' || { echo "[verify-mock] FAIL: hop-2 request_body missing"; exit 1; }
printf '%s\n' "$mcp_tail" | grep -q 'resp_body' || { echo "[verify-mock] FAIL: hop-2 resp_body missing"; exit 1; }
printf '%s\n' "$mcp_tail" | grep -q 'AAPL' || { echo "[verify-mock] FAIL: hop-2 missing transaction request payload"; exit 1; }
printf '%s\n' "$mcp_tail" | grep -q 'notional_value' || { echo "[verify-mock] FAIL: hop-2 missing transaction response payload"; exit 1; }

# Error logs should exist; they can be empty in a healthy run.
[ -f "$LOG_DIR/llm_to_mcp_error.log" ] || { echo "[verify-mock] FAIL: hop-1 error log missing"; exit 1; }
[ -f "$LOG_DIR/mcp_to_api_error.log" ] || { echo "[verify-mock] FAIL: hop-2 error log missing"; exit 1; }

echo "[verify-mock] PASS: both hops captured request/response bodies"
