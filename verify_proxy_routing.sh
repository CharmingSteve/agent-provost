#!/bin/sh
set -e

ROOT_DIR="${ROOT_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$ROOT_DIR")}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/nginx-logs}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
PYTHON_BIN="${PYTHON_BIN:-$PROJECT_DIR/.venv/bin/python}"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-dev}"

if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="python3"
fi

cd "$ROOT_DIR"

echo "[verify] starting with bootstrap mode: $BOOTSTRAP_MODE"

# Stage secrets via bootstrap wrapper (source output to set PROVOST_SECRETS_DIR)
if [ -f "$ROOT_DIR/bootstrap.sh" ]; then
    eval "$(sh "$ROOT_DIR/bootstrap.sh" "$BOOTSTRAP_MODE")"
else
    echo "[verify] bootstrap.sh not found; skipping secrets staging"
fi

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
import os
import time
import requests

url = "http://localhost:8088/mcp"
sid = None
secrets_dir = os.environ.get("PROVOST_SECRETS_DIR", "/run/secrets")
token_path = os.path.join(secrets_dir, "provost_token")

try:
    with open(token_path, "r", encoding="utf-8") as f:
        provost_token = f.read().strip()
except OSError as exc:
    raise SystemExit(f"unable to read provost token from {token_path}: {exc}")

if not provost_token:
    raise SystemExit(f"provost token file is empty: {token_path}")

def call(sess, rid, method, params=None):
    global sid
    headers = {
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json",
        "X-Provost-Token": provost_token,
        "X-Provost-User": os.environ.get("PROVOST_VERIFY_USER", "verify@local"),
        "X-Provost-Machine": os.environ.get("PROVOST_VERIFY_MACHINE", "verify-runner"),
    }
    if sid:
        headers["mcp-session-id"] = sid
    payload = {"jsonrpc": "2.0", "method": method}
    if rid is not None:
        payload["id"] = rid
    if params is not None:
        payload["params"] = params
    try:
        r = sess.post(url, headers=headers, json=payload, timeout=45)
    except requests.RequestException as exc:
        return 0, {"error": str(exc)}
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
