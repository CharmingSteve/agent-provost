#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CF_FILE="$ROOT_DIR/cloudformation/alpaca-provost-cf-v0.2.7.yml"
  RULES_FILE="$ROOT_DIR/rules.json"
  SYNC_FILE="$ROOT_DIR/scripts/sync_state.sh"
}

# ── CloudFormation parameter wiring ──────────────────────────────────────────

@test "allowlist controls: EnableAllowlist parameter exists in CloudFormation" {
  run grep -q "EnableAllowlist:" "$CF_FILE"
  [ "$status" -eq 0 ]
}

@test "allowlist controls: EnableAllowlist defaults to false" {
  run grep -A4 "EnableAllowlist:" "$CF_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Default: 'false'"
}

@test "allowlist controls: EnableAllowlist has AllowedValues dropdown" {
  run grep -q "AllowedValues" "$CF_FILE"
  [ "$status" -eq 0 ]
}

@test "allowlist controls: AllowedSymbols parameter still present with its default" {
  run grep -q '"SPY,QQQ,AAPL,MSFT"' "$CF_FILE"
  [ "$status" -eq 0 ]
}

@test "allowlist controls: EnableAllowlist appears before AllowedSymbols in ParameterGroups" {
  enable_line="$(grep -n "EnableAllowlist" "$CF_FILE" | grep -v "^[^:]*:#" | awk -F: '{print $1}' | sort -n | head -1)"
  allowed_line="$(grep -n "AllowedSymbols" "$CF_FILE" | grep -v "^[^:]*:#" | awk -F: '{print $1}' | sort -n | head -1)"
  [ -n "$enable_line" ]
  [ -n "$allowed_line" ]
  [ "$enable_line" -lt "$allowed_line" ]
}

@test "allowlist controls: EnableAllowlist is included in SecretString" {
  run grep -q '"EnableAllowlist"' "$CF_FILE"
  [ "$status" -eq 0 ]
}

# ── sync_state.sh jq transform ───────────────────────────────────────────────

# DoD Test 3: sync_state.sh produces allowed_tickers (not allowed_symbols)
@test "allowlist controls: sync_state writes allowed_tickers rule key" {
  run grep -q "allowed_tickers:" "$SYNC_FILE"
  [ "$status" -eq 0 ]
}

@test "allowlist controls: sync_state does NOT write old allowed_symbols key" {
  run grep -q "allowed_symbols:" "$SYNC_FILE"
  [ "$status" -ne 0 ]
}

@test "allowlist controls: sync_state enabled flag driven by EnableAllowlist" {
  run grep -q '\.EnableAllowlist == "true"' "$SYNC_FILE"
  [ "$status" -eq 0 ]
}

@test "allowlist controls: sync_state uses tickers param key (not symbols)" {
  run grep -q "tickers: (.AllowedSymbols" "$SYNC_FILE"
  [ "$status" -eq 0 ]
}

@test "allowlist controls: sync_state still uses split_csv for AllowedSymbols" {
  run grep -q "AllowedSymbols | split_csv" "$SYNC_FILE"
  [ "$status" -eq 0 ]
}

# ── Default rules.json ────────────────────────────────────────────────────────

# DoD Test 3 (default-off): rules.json ships with allowed_tickers disabled
@test "allowlist controls: default rules.json contains allowed_tickers entry" {
  run grep -q '"allowed_tickers"' "$RULES_FILE"
  [ "$status" -eq 0 ]
}

@test "allowlist controls: allowed_tickers is disabled by default in rules.json" {
  run python3 -c "
import json, sys
with open('$RULES_FILE') as f:
    rules = json.load(f)
rule = rules.get('allowed_tickers', {})
assert rule.get('enabled') == False, 'expected enabled=false'
"
  [ "$status" -eq 0 ]
}
