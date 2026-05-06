#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 SCHEMAFILE JSONL_FILE" >&2
    exit 2
fi

SCHEMA_TOOL="${SCHEMA_TOOL:-check-jsonschema}"
SCHEMA_FILE="$1"
JSONL_FILE="$2"
TMP_DIR="$(mktemp -d)"
LINE_NO=0
FOUND=0

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

if ! command -v "$SCHEMA_TOOL" >/dev/null 2>&1; then
    echo "[schema] FAIL: missing validator on PATH: $SCHEMA_TOOL" >&2
    exit 1
fi

while IFS= read -r line || [ -n "$line" ]; do
    LINE_NO=$((LINE_NO + 1))

    if [ -z "$line" ]; then
        continue
    fi

    FOUND=1
    LINE_FILE="$TMP_DIR/line-$LINE_NO.json"
    printf '%s\n' "$line" > "$LINE_FILE"

    if ! "$SCHEMA_TOOL" --schemafile "$SCHEMA_FILE" "$LINE_FILE"; then
        echo "[schema] FAIL: $JSONL_FILE line $LINE_NO did not match $SCHEMA_FILE" >&2
        exit 1
    fi
done < "$JSONL_FILE"

if [ "$FOUND" -ne 1 ]; then
    echo "[schema] FAIL: no JSON objects found in $JSONL_FILE" >&2
    exit 1
fi
