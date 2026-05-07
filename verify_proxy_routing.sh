#!/bin/sh
set -e

ROOT_DIR="${ROOT_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$ROOT_DIR")}"
RUN_DIR="${PROVOST_RUN_DIR:-}"
FLUENT_BUFFER_DIR="${FLUENT_BUFFER_DIR:-$ROOT_DIR/logs/fluent-bit-storage}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
PYTHON_BIN="${PYTHON_BIN:-$PROJECT_DIR/.venv/bin/python}"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-dev}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-.env.versions}"
VERIFY_REQUIRE_S3="${VERIFY_REQUIRE_S3:-auto}"
VERIFY_S3_POLL_SECONDS="${VERIFY_S3_POLL_SECONDS:-60}"
VERIFY_S3_BUCKET="${VERIFY_S3_BUCKET:-${S3_BUCKET:-}}"
VERIFY_S3_REGION="${VERIFY_S3_REGION:-${AWS_REGION:-}}"

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

# Bootstrap may export AWS/S3 env vars; refresh derived verify values afterward.
VERIFY_S3_BUCKET="${VERIFY_S3_BUCKET:-${S3_BUCKET:-}}"
VERIFY_S3_REGION="${VERIFY_S3_REGION:-${AWS_REGION:-}}"

RUN_DIR="${PROVOST_RUN_DIR:-$RUN_DIR}"
SOCKET_PATH="/var/run/provost/fluent-bit.sock"
PROBE_ID="verify-$(date +%s)-$$"

wait_for_fluentbit_health() {
    i=0
    while [ "$i" -lt 30 ]; do
        status=$($DOCKER_BIN inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' fluent-bit 2>/dev/null || true)
        if [ "$status" = "healthy" ]; then
            echo "[verify] fluent-bit health=healthy"
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    echo "[verify] FAIL: fluent-bit did not become healthy"
    return 1
}

wait_for_agent_running() {
    i=0
    while [ "$i" -lt 30 ]; do
        status=$($DOCKER_BIN inspect -f '{{.State.Status}}' agent-provost 2>/dev/null || true)
        if [ "$status" = "running" ]; then
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    echo "[verify] FAIL: agent-provost did not reach running state"
    return 1
}

check_buffer_evidence() {
    if [ ! -d "$FLUENT_BUFFER_DIR" ]; then
        echo "[verify] FAIL: fluent-bit buffer directory not found: $FLUENT_BUFFER_DIR"
        return 1
    fi
    file_count=$(find "$FLUENT_BUFFER_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "[verify] fluent-bit buffer file_count=$file_count"
    if [ "$file_count" -lt 1 ]; then
        echo "[verify] FAIL: no fluent-bit buffer evidence found"
        return 1
    fi
}

check_s3_for_probe() {
    if ! command -v aws >/dev/null 2>&1; then
        echo "[verify] FAIL: aws cli not found for S3 validation"
        return 1
    fi
    if [ -z "${VERIFY_S3_BUCKET:-}" ] || [ -z "${VERIFY_S3_REGION:-}" ]; then
        echo "[verify] FAIL: VERIFY_S3_BUCKET/AWS_REGION not set for S3 validation"
        return 1
    fi

    prefix="agent-provost/logs/$(date -u +%Y/%m/%d/%H/)"
    deadline=$(( $(date +%s) + VERIFY_S3_POLL_SECONDS ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        keys=$(aws s3api list-objects-v2 \
            --bucket "$VERIFY_S3_BUCKET" \
            --prefix "$prefix" \
            --region "$VERIFY_S3_REGION" \
            --query 'reverse(sort_by(Contents,&LastModified))[:20].Key' \
            --output text 2>/dev/null || true)

        if [ -n "$keys" ]; then
            for key in $keys; do
                if aws s3 cp "s3://$VERIFY_S3_BUCKET/$key" - --region "$VERIFY_S3_REGION" 2>/dev/null | grep -q "$PROBE_ID"; then
                    echo "[verify] found probe id in s3://$VERIFY_S3_BUCKET/$key"
                    return 0
                fi
            done
        fi
        sleep 3
    done

    echo "[verify] FAIL: probe id not found in S3 within timeout"
    return 1
}

echo "[verify] restarting stack"
"$DOCKER_BIN" compose --env-file "$COMPOSE_ENV_FILE" up -d --force-recreate >/dev/null

wait_for_fluentbit_health
wait_for_agent_running

if ! "$DOCKER_BIN" exec agent-provost sh -lc "test -S '$SOCKET_PATH'" >/dev/null 2>&1; then
    echo "[verify] FAIL: fluent-bit socket missing at $SOCKET_PATH"
    exit 1
fi
echo "[verify] socket present: $SOCKET_PATH"

echo "[verify] probing mcp endpoint"
PROVOST_VERIFY_REQUEST_ID="$PROBE_ID" "$PYTHON_BIN" - <<'PY'
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
    request_id = os.environ.get("PROVOST_VERIFY_REQUEST_ID")
    headers = {
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json",
        "X-Provost-Token": provost_token,
        "X-Provost-User": os.environ.get("PROVOST_VERIFY_USER", "verify_proxy_script@local"),
        "X-Provost-Machine": os.environ.get("PROVOST_VERIFY_MACHINE", "verify-proxy-script-runner"),
        "X-Provost-Request-Id": request_id,
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
    has_rpc_error = isinstance(r2, dict) and r2.get("error") is not None
    is_error = ((r2.get("result") or {}).get("isError")) if isinstance(r2, dict) else True
    print(f"initialize_status={c1}")
    print(f"tools_call_status={c2}")
    print(f"tool_is_error={is_error}")
    if c1 != 200 or c2 != 200 or has_rpc_error or is_error is True:
        raise SystemExit(1)
PY

case "$VERIFY_REQUIRE_S3" in
    true)
        check_s3_for_probe
        ;;
    false)
        check_buffer_evidence
        ;;
    auto)
        if [ -n "${VERIFY_S3_BUCKET:-}" ] && [ -n "${VERIFY_S3_REGION:-}" ] && command -v aws >/dev/null 2>&1; then
            check_s3_for_probe || check_buffer_evidence
        else
            check_buffer_evidence
        fi
        ;;
    *)
        echo "[verify] FAIL: VERIFY_REQUIRE_S3 must be true|false|auto"
        exit 1
        ;;
esac

echo "[verify] PASS: fluent-bit socket/audit path validated"
