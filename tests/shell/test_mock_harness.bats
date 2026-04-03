#!/usr/bin/env bats

setup() {
  export TEST_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "mock-mcp/docker-compose.yml exists" {
  [ -f "$TEST_REPO_ROOT/mock-mcp/docker-compose.yml" ]
}

@test "mock-mcp/docker-compose.yml pins openresty image by digest" {
  run grep -E '^\s*image:\s*openresty/openresty@sha256:[a-f0-9]{64}$' \
      "$TEST_REPO_ROOT/mock-mcp/docker-compose.yml"
  [ "$status" -eq 0 ]
}

@test "mock-mcp/default.conf exists" {
  [ -f "$TEST_REPO_ROOT/mock-mcp/default.conf" ]
}

@test "mock-mcp/default.conf contains hop1 access log" {
  run grep -q 'hop1' "$TEST_REPO_ROOT/mock-mcp/default.conf"
  [ "$status" -eq 0 ]
}

@test "mock-mcp/default.conf contains hop2 access log" {
  run grep -q 'hop2' "$TEST_REPO_ROOT/mock-mcp/default.conf"
  [ "$status" -eq 0 ]
}

@test "mock-mcp/default.conf logs request_body" {
  run grep -q 'request_body' "$TEST_REPO_ROOT/mock-mcp/default.conf"
  [ "$status" -eq 0 ]
}

@test "mock-mcp/default.conf logs resp_body" {
  run grep -q 'resp_body' "$TEST_REPO_ROOT/mock-mcp/default.conf"
  [ "$status" -eq 0 ]
}

@test "CI validates mock-mcp compose config" {
  run grep -E 'docker compose -f mock-mcp/docker-compose\.yml config --quiet' \
      "$TEST_REPO_ROOT/.github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}

@test "CI prints hop1 logs in mock-harness job" {
  run grep -E 'hop1' "$TEST_REPO_ROOT/.github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}

@test "CI prints hop2 logs in mock-harness job" {
  run grep -E 'hop2' "$TEST_REPO_ROOT/.github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}

@test "CI prints request_body in mock-harness job" {
  run grep -E 'request_body' "$TEST_REPO_ROOT/.github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}

@test "CI prints resp_body in mock-harness job" {
  run grep -E 'resp_body' "$TEST_REPO_ROOT/.github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}

@test "CI mock-harness job does not upload artifacts" {
  run grep -E 'upload-artifact' "$TEST_REPO_ROOT/.github/workflows/ci.yml"
  [ "$status" -ne 0 ]
}
