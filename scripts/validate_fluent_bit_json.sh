#!/bin/sh
set -eu

ROOT_DIR="${ROOT_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}"
SCHEMA_TOOL="${SCHEMA_TOOL:-check-jsonschema}"
SCHEMA_URL="${SCHEMA_URL:-http://localhost:8088/}"
SCHEMA_WAIT_SECONDS="${SCHEMA_WAIT_SECONDS:-30}"
FINAL_DIR="${FINAL_DIR:-$ROOT_DIR/logs/fluent-bit-storage/final}"
ACCESS_LOG="$FINAL_DIR/access.jsonl"
ERROR_LOG="$FINAL_DIR/error.jsonl"
ACCESS_SCHEMA="$ROOT_DIR/schemas/access_log_schema.json"
ERROR_SCHEMA="$ROOT_DIR/schemas/error_log_schema.json"
JSONL_CHECKER="$ROOT_DIR/scripts/check_jsonlines_schema.sh"
PROBE_ID="schema-smoke-$(date +%s)-$$"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

if ! command -v "$SCHEMA_TOOL" >/dev/null 2>&1; then
    echo "[schema] FAIL: missing validator on PATH: $SCHEMA_TOOL"
    exit 1
fi

if [ ! -x "$JSONL_CHECKER" ]; then
    echo "[schema] FAIL: helper is not executable: $JSONL_CHECKER"
    exit 1
fi

mkdir -p "$FINAL_DIR"
: > "$ACCESS_LOG"
: > "$ERROR_LOG"

curl -sS -o /dev/null \
    -H 'Content-Type: application/json' \
    -H "X-Provost-Request-Id: $PROBE_ID" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    "$SCHEMA_URL" || true

deadline=$(( $(date +%s) + SCHEMA_WAIT_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    access_ready=0
    error_ready=0

    if [ -s "$ACCESS_LOG" ] && grep -F "$PROBE_ID" "$ACCESS_LOG" > "$TMP_DIR/access.jsonl" 2>/dev/null; then
        access_ready=1
    fi
    if [ -s "$ERROR_LOG" ] && grep -F "$PROBE_ID" "$ERROR_LOG" > "$TMP_DIR/error.jsonl" 2>/dev/null; then
        error_ready=1
    fi

    if [ "$access_ready" -eq 1 ] && [ "$error_ready" -eq 1 ]; then
        break
    fi

    sleep 1
done

if [ ! -s "$TMP_DIR/access.jsonl" ]; then
    echo "[schema] FAIL: no access record captured for probe $PROBE_ID"
    exit 1
fi

if [ ! -s "$TMP_DIR/error.jsonl" ]; then
    echo "[schema] FAIL: no error record captured for probe $PROBE_ID"
    exit 1
fi

SCHEMA_TOOL="$SCHEMA_TOOL" "$JSONL_CHECKER" "$ACCESS_SCHEMA" "$TMP_DIR/access.jsonl"
SCHEMA_TOOL="$SCHEMA_TOOL" "$JSONL_CHECKER" "$ERROR_SCHEMA" "$TMP_DIR/error.jsonl"

echo "[schema] PASS: validated access and error JSON for probe $PROBE_ID"