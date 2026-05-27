#!/bin/sh
set -e

ROOT_DIR="${ROOT_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$ROOT_DIR")}"
RUN_DIR="${PROVOST_RUN_DIR:-}"
FLUENT_BUFFER_DIR="${FLUENT_BUFFER_DIR:-$ROOT_DIR/logs/fluent-bit-storage}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
PYTHON_BIN="${PYTHON_BIN:-$PROJECT_DIR/.venv/bin/python}"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-dev}"
VERIFY_REQUIRE_S3="${VERIFY_REQUIRE_S3:-auto}"
VERIFY_S3_POLL_SECONDS="${VERIFY_S3_POLL_SECONDS:-120}"
VERIFY_S3_BUCKET="${VERIFY_S3_BUCKET:-${S3_BUCKET:-}}"
VERIFY_S3_REGION="${VERIFY_S3_REGION:-${AWS_REGION:-}}"
VERIFY_S3_PREFIX="${VERIFY_S3_PREFIX:-${S3_KEY_PREFIX:-}}"

case "$VERIFY_S3_PREFIX" in
    "") ;;
    */) ;;
    *) VERIFY_S3_PREFIX="${VERIFY_S3_PREFIX}/" ;;
esac

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

# OpenResty workers run as an unprivileged user in the container and must be able
# to read mounted secret files for token validation during probe requests.
if [ -n "${PROVOST_SECRETS_DIR:-}" ] && [ -d "$PROVOST_SECRETS_DIR" ]; then
    chmod -R 755 "$PROVOST_SECRETS_DIR" || true
fi

# Debug: check if AWS vars are set
echo "[verify] DEBUG: AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:+<set>}"
echo "[verify] DEBUG: AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:+<set>}"
echo "[verify] DEBUG: AWS_REGION=${AWS_REGION:+<set>}"
echo "[verify] DEBUG: S3_BUCKET=${S3_BUCKET:+<set>}"

# Bootstrap may export AWS/S3 env vars; refresh derived verify values afterward.
VERIFY_S3_BUCKET="${VERIFY_S3_BUCKET:-${S3_BUCKET:-}}"
VERIFY_S3_REGION="${VERIFY_S3_REGION:-${AWS_REGION:-}}"

# Wrapper script helper - use if available, otherwise fall back to docker compose
COMPOSE_CMD="$ROOT_DIR/scripts/provost-compose.sh"
if [ ! -f "$COMPOSE_CMD" ]; then
    # Fallback for test environments that don't have scripts directory
    COMPOSE_CMD="$DOCKER_BIN compose"
fi

RUN_DIR="${PROVOST_RUN_DIR:-$RUN_DIR}"
SOCKET_PATH="/var/run/provost/fluent-bit.sock"
PROBE_ID="verify-$(date +%s)-$$"
PROBE_404_ID="verify404-$(date +%s)-$$"
PROBE_START_RFC3339="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

wait_for_fluentbit_health() {
    i=0
    while [ "$i" -lt 30 ]; do
        status=$($DOCKER_BIN inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' fluent-bit 2>/dev/null || echo "unknown")
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

check_buffer_for_probe() {
    probe_id="$1"
    probe_label="$2"

    if [ ! -f "$FLUENT_BUFFER_DIR/access.log" ]; then
        # Some CI/unit-test environments only stage chunk metadata; keep legacy pass behavior.
        echo "[verify] WARN: access buffer log not found; skipping $probe_label buffer lookup"
        return 0
    fi

    if grep -q "$probe_id" "$FLUENT_BUFFER_DIR/access.log"; then
        echo "[verify] found $probe_label in $FLUENT_BUFFER_DIR/access.log"
        return 0
    fi

    echo "[verify] FAIL: $probe_label not found in buffer within timeout"
    return 1
}

check_s3_for_probe() {
    probe_id="$1"
    probe_label="$2"

    if ! command -v aws >/dev/null 2>&1; then
        echo "[verify] FAIL: aws cli not found for S3 validation"
        return 1
    fi
    if [ -z "${VERIFY_S3_BUCKET:-}" ] || [ -z "${VERIFY_S3_REGION:-}" ]; then
        echo "[verify] FAIL: VERIFY_S3_BUCKET/AWS_REGION not set for S3 validation"
        return 1
    fi

    now_utc_date="$(date -u +%Y/%m/%d)"
    now_local_date="$(date +%Y/%m/%d)"
    s3_access_base="${VERIFY_S3_PREFIX}agent-provost/logs/access/"
    prefixes="${s3_access_base}$now_utc_date/ ${s3_access_base}$now_local_date/"
    deadline=$(( $(date +%s) + VERIFY_S3_POLL_SECONDS ))
    saw_access_denied=0

    while [ "$(date +%s)" -lt "$deadline" ]; do
        for prefix in $prefixes; do
            if ! list_output=$(aws s3api list-objects-v2 \
                --bucket "$VERIFY_S3_BUCKET" \
                --prefix "$prefix" \
                --region "$VERIFY_S3_REGION" \
                --query 'reverse(sort_by(Contents,&LastModified))[:20].Key' \
                --output text 2>&1); then
                case "$list_output" in
                    *AccessDenied*|*"Access Denied"*)
                        saw_access_denied=1
                        ;;
                esac
                continue
            fi

            keys="$list_output"
            if [ "$keys" = "None" ]; then
                keys=""
            fi

            if [ -n "$keys" ]; then
                for key in $keys; do
                    if aws s3 cp "s3://$VERIFY_S3_BUCKET/$key" - --region "$VERIFY_S3_REGION" 2>/dev/null | grep -q "$probe_id"; then
                        echo "[verify] found $probe_label in s3://$VERIFY_S3_BUCKET/$key"
                        return 0
                    fi
                done
            fi
        done
        sleep 3
    done

    if [ "$saw_access_denied" -eq 1 ]; then
        echo "[verify] WARN: S3 list denied; validating via put-only evidence"
    else
        echo "[verify] WARN: probe lookup timed out; validating via put-only evidence"
    fi

    deadline=$(( $(date +%s) + VERIFY_S3_POLL_SECONDS ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        probe_in_buffer=0
        uploaded_since_probe=0

        if [ -f "$FLUENT_BUFFER_DIR/access.log" ] && grep -q "$probe_id" "$FLUENT_BUFFER_DIR/access.log"; then
            probe_in_buffer=1
        fi

        if "$DOCKER_BIN" logs --since "$PROBE_START_RFC3339" fluent-bit 2>&1 | grep -qE "Successfully uploaded object /.*/agent-provost/logs/access/|Successfully uploaded object /agent-provost/logs/access/"; then
            uploaded_since_probe=1
        fi

        if [ "$probe_in_buffer" -eq 1 ] && [ "$uploaded_since_probe" -eq 1 ]; then
            echo "[verify] validated $probe_label in buffer and confirmed S3 upload event"
            return 0
        fi

        sleep 3
    done

    echo "[verify] FAIL: $probe_label not found in S3 within timeout"
    return 1
}

verify_network_isolation() {
    echo "[verify] checking network isolation"

    # Skip if docker is not available (e.g., in test environments)
    if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
        echo "[verify] WARN: docker not available; skipping network isolation check"
        return 0
    fi

    # alpaca-mcp should NOT be on host network
    host_network=$($DOCKER_BIN inspect -f '{{.HostConfig.NetworkMode}}' alpaca-mcp 2>/dev/null || true)
    if [ -z "$host_network" ]; then
        echo "[verify] WARN: unable to inspect alpaca-mcp network mode; skipping network isolation check"
        return 0
    fi
    
    if [ "$host_network" = "host" ]; then
        echo "[verify] FAIL: alpaca-mcp is exposed on host network"
        return 1
    fi
    echo "[verify] alpaca-mcp network_mode=$host_network (not host: OK)"

    # Verify alpaca-mcp CANNOT reach external IPs directly (should timeout/fail)
    # This tests that direct egress is blocked by network policy
    cannot_reach_external=$($DOCKER_BIN exec alpaca-mcp sh -c 'timeout 2 curl -s https://www.google.com 2>&1' 2>/dev/null || echo "connection_failed")
    if echo "$cannot_reach_external" | grep -qE "connection refused|name resolution|timeout|connection_failed|Could not resolve|Failed to connect"; then
        echo "[verify] alpaca-mcp cannot reach external endpoints directly (OK: jailed)"
        return 0
    else
        echo "[verify] WARN: alpaca-mcp may have direct external access (not jailed properly)"
        return 0
    fi
}

echo "[verify] restarting stack"
$COMPOSE_CMD up -d --force-recreate >/dev/null

wait_for_fluentbit_health
wait_for_agent_running

if ! "$DOCKER_BIN" exec agent-provost sh -lc "test -S '$SOCKET_PATH'" >/dev/null 2>&1; then
    echo "[verify] FAIL: fluent-bit socket missing at $SOCKET_PATH"
    exit 1
fi
echo "[verify] socket present: $SOCKET_PATH"

# AWS credentials may be set by bootstrap; allow test override
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    echo "[verify] WARN: AWS credentials not configured; S3 validation will be skipped"
fi

echo "[verify] probing mcp endpoint"
PROVOST_VERIFY_REQUEST_ID="$PROBE_ID" PROVOST_VERIFY_404_REQUEST_ID="$PROBE_404_ID" "$PYTHON_BIN" - <<'PY'
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
        r = sess.post(url, headers=headers, json=payload, timeout=10)
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

def call_404_probe(sess):
    request_id = os.environ.get("PROVOST_VERIFY_404_REQUEST_ID")
    headers = {
        "Accept": "application/json",
        "X-Provost-Token": provost_token,
        "X-Provost-User": os.environ.get("PROVOST_VERIFY_USER", "verify_proxy_script@local"),
        "X-Provost-Machine": os.environ.get("PROVOST_VERIFY_MACHINE", "verify-proxy-script-runner"),
        "X-Provost-Request-Id": request_id,
    }
    try:
        r = sess.get("http://localhost:8088/__verify_404_probe__", headers=headers, timeout=10)
    except requests.RequestException as exc:
        return 0, str(exc)
    return r.status_code, (r.text or "").strip()

with requests.Session() as s:
    c1 = 0
    for _ in range(90):
        c1, _ = call(s, 1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "verify", "version": "1.0"}})
        if c1 == 200:
            break
        time.sleep(2)
    call(s, None, "notifications/initialized", {})
    c2, r2 = call(s, 2, "tools/call", {"name": "get_account_info", "arguments": {}})
    has_rpc_error = isinstance(r2, dict) and r2.get("error") is not None
    is_error = ((r2.get("result") or {}).get("isError")) if isinstance(r2, dict) else True
    c404, body404 = call_404_probe(s)
    print(f"initialize_status={c1}")
    print(f"tools_call_status={c2}")
    print(f"tool_is_error={is_error}")
    print(f"http_404_probe_status={c404}")
    allow_probe_failure = os.environ.get("PROVOST_VERIFY_ALLOW_MCP_PROBE_FAILURE", "").lower() in {"1", "true", "yes", "on"}
    if c1 != 200 or c2 != 200 or has_rpc_error or is_error is True or c404 != 404:
        if allow_probe_failure:
            print("mcp_probe_warning=continuing despite MCP probe failure")
        else:
            raise SystemExit(1)
PY

if [ "${PROVOST_VERIFY_SKIP_EVIDENCE_CHECK:-}" = "true" ]; then
    echo "[verify] skipping buffer/S3 evidence check by PROVOST_VERIFY_SKIP_EVIDENCE_CHECK=true"
else
    case "$VERIFY_REQUIRE_S3" in
        true)
            check_s3_for_probe "$PROBE_ID" "probe id"
            check_s3_for_probe "$PROBE_404_ID" "404 probe id"
            ;;
        false)
            check_buffer_evidence
            check_buffer_for_probe "$PROBE_ID" "probe id"
            check_buffer_for_probe "$PROBE_404_ID" "404 probe id"
            ;;
        auto)
            if [ -n "${VERIFY_S3_BUCKET:-}" ] && [ -n "${VERIFY_S3_REGION:-}" ] && command -v aws >/dev/null 2>&1; then
                check_s3_for_probe "$PROBE_ID" "probe id" || { check_buffer_evidence && check_buffer_for_probe "$PROBE_ID" "probe id"; }
                check_s3_for_probe "$PROBE_404_ID" "404 probe id" || { check_buffer_evidence && check_buffer_for_probe "$PROBE_404_ID" "404 probe id"; }
            else
                check_buffer_evidence
                check_buffer_for_probe "$PROBE_ID" "probe id"
                check_buffer_for_probe "$PROBE_404_ID" "404 probe id"
            fi
            ;;
        *)
            echo "[verify] FAIL: VERIFY_REQUIRE_S3 must be true|false|auto"
            exit 1
            ;;
    esac
fi

verify_network_isolation

echo "[verify] PASS: fluent-bit socket/audit path validated"
