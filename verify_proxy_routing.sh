#!/bin/sh
set -e

ROOT_DIR="${ROOT_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$ROOT_DIR")}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/nginx-logs}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
PYTHON_BIN="${PYTHON_BIN:-$PROJECT_DIR/.venv/bin/python}"

cd "$ROOT_DIR"

echo "[verify] restarting stack"
"$DOCKER_BIN" compose up -d --force-recreate >/dev/null

echo "[verify] clearing logs"
: > "$LOG_DIR/llm_to_alpaca_access.log"
: > "$LOG_DIR/mcp_to_alpaca_access.log"
: > "$LOG_DIR/llm_to_alpaca_error.log"
: > "$LOG_DIR/mcp_to_alpaca_error.log"

echo "[verify] probing mcp endpoint"
"$PYTHON_BIN" - <<'PY'
import json
import time
import requests

url = "http://localhost:8088/mcp"
sid = None

def call(sess, rid, method, params=None):
    global sid
    headers = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
    if sid:
        headers["mcp-session-id"] = sid
    payload = {"jsonrpc": "2.0", "method": method}
    if rid is not None:
        payload["id"] = rid
    if params is not None:
        payload["params"] = params
    r = sess.post(url, headers=headers, json=payload, timeout=45)
    if r.headers.get("mcp-session-id"):
        sid = r.headers["mcp-session-id"]
    txt = r.text.strip()
    data = [ln.split(":", 1)[1].strip() for ln in txt.splitlines() if ln.startswith("data:")]
    if data:
        try:
            return r.status_code, json.loads("\n".join(data))
        except Exception:
            return r.status_code, {"raw": "\n".join(data)}
    try:
        return r.status_code, r.json()
    except Exception:
        return r.status_code, {"raw": txt}

with requests.Session() as s:
    c1 = 0
    for _ in range(20):
        c1, _ = call(s, 1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "verify", "version": "1.0"}})
        if c1 == 200:
            break
        time.sleep(1)
    call(s, None, "notifications/initialized", {})
    c2, r2 = call(s, 2, "tools/call", {"name": "get_account_info", "arguments": {}})
    is_error = ((r2.get("result") or {}).get("isError")) if isinstance(r2, dict) else True
    print(f"initialize_status={c1}")
    print(f"tools_call_status={c2}")
    print(f"tool_is_error={is_error}")
    if c1 != 200 or c2 != 200 or is_error:
        raise SystemExit(1)
PY

hop1_count=$(wc -l < "$LOG_DIR/llm_to_alpaca_access.log")
hop2_count=$(wc -l < "$LOG_DIR/mcp_to_alpaca_access.log")
err2_count=$(wc -l < "$LOG_DIR/mcp_to_alpaca_error.log")

echo "[verify] hop1_count=$hop1_count"
echo "[verify] hop2_count=$hop2_count"
echo "[verify] hop2_error_count=$err2_count"

if [ "$hop1_count" -lt 1 ]; then
  echo "[verify] FAIL: no hop-1 traffic logged"
  exit 1
fi

if [ "$hop2_count" -lt 1 ]; then
  echo "[verify] FAIL: no hop-2 traffic logged"
  exit 1
fi

if [ "$err2_count" -gt 0 ]; then
  echo "[verify] FAIL: hop-2 errors present"
  exit 1
fi

echo "[verify] PASS: both hops logged fresh traffic"
