#!/usr/bin/env bats

setup_file() {
  export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  cd "$REPO_ROOT" || exit 1

  docker compose down -v >/dev/null 2>&1 || true
  docker compose up -d
  sleep 5
}

teardown_file() {
  cd "$REPO_ROOT" || exit 1
  docker compose down -v >/dev/null 2>&1 || true
}

@test "allows check_reserve_liquidity tool" {
  run docker exec nabatech-node python -c '
import requests
payload = {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"check_reserve_liquidity","arguments":{}}}
r = requests.post("http://agent-provost:8000/mcp", json=payload, timeout=10)
print(r.status_code)
print(r.text)
'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | head -n 1)" = "200" ]

  run sh -c 'echo "$1" | sed -n "2p" | jq -r ".result.asset"' _ "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "Digital Shekel (ILS-D)" ]
}

@test "blocks execute_sovereign_transfer when action is mint" {
  run docker exec nabatech-node python -c '
import requests
payload = {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute_sovereign_transfer","arguments":{"asset":"Digital Shekel (ILS-D)","action":"mint","amount":500,"destination_wallet":"BOI-TREASURY-001"}}}
r = requests.post("http://agent-provost:8000/mcp", json=payload, timeout=10)
print(r.status_code)
print(r.text)
'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | head -n 1)" = "403" ]

  run sh -c 'echo "$1" | sed -n "2p" | jq -r ".error"' _ "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "PROVOST_INTERVENTION: Sovereign Policy Violation. Unauthorized Minting or Amount Exceeds Reserve Limits." ]
}

@test "blocks execute_sovereign_transfer when amount exceeds 1,000,000" {
  run docker exec nabatech-node python -c '
import requests
payload = {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"execute_sovereign_transfer","arguments":{"asset":"Digital Shekel (ILS-D)","action":"transfer","amount":1000001,"destination_wallet":"BOI-CLEARING-002"}}}
r = requests.post("http://agent-provost:8000/mcp", json=payload, timeout=10)
print(r.status_code)
print(r.text)
'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | head -n 1)" = "403" ]

  run sh -c 'echo "$1" | sed -n "2p" | jq -r ".error"' _ "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "PROVOST_INTERVENTION: Sovereign Policy Violation. Unauthorized Minting or Amount Exceeds Reserve Limits." ]
}
