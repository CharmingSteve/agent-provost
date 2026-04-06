#!/usr/bin/env bats

@test "docker-compose.yml pins openresty image by digest" {
  run grep -E '^\s*image:\s*openresty/openresty@sha256:[a-f0-9]{64}$' docker-compose.yml
  [ "$status" -eq 0 ]
}

@test "mock compose pins openresty image by digest" {
  run grep -E '^\s*image:\s*openresty/openresty@sha256:[a-f0-9]{64}$' mock-mcp/docker-compose.yml
  [ "$status" -eq 0 ]
}

@test "alpaca-mcp.Dockerfile pins python alpine base image by digest" {
  run grep -E '^FROM\s+python:3\.11-alpine@sha256:[a-f0-9]{64}$' alpaca-mcp.Dockerfile
  [ "$status" -eq 0 ]
}

@test "CI validates compose config" {
  run grep -E 'docker compose -f docker-compose\.yml config --quiet' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'docker compose -f mock-mcp/docker-compose\.yml config --quiet' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "CI scans pulled openresty image" {
  run grep -E 'trivy image --exit-code 1 --severity CRITICAL,HIGH openresty/openresty@sha256:[a-f0-9]{64}' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "CI scans built alpaca-mcp image" {
  run grep -E 'docker image inspect agent-provost-alpaca-mcp:latest >/dev/null' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'trivy image --exit-code 1 --severity CRITICAL,HIGH agent-provost-alpaca-mcp:latest' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "CI scans built mock harness images" {
  run grep -E 'docker image inspect mock-mcp-mock-mcp:latest >/dev/null' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'trivy image --exit-code 1 --severity CRITICAL,HIGH mock-mcp-mock-mcp:latest' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'docker image inspect mock-mcp-sovereign-api:latest >/dev/null 2>&1' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'docker image inspect sovereign-mock-api:latest >/dev/null 2>&1' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'trivy image --exit-code 1 --severity CRITICAL,HIGH "\$SOVEREIGN_IMAGE"' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "Checkov is blocking and scans workflow/yaml too" {
  run grep -E 'checkov --directory \. --framework dockerfile,github_actions,yaml --quiet$' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E -- '--soft-fail' .github/workflows/ci.yml
  [ "$status" -ne 0 ]
}
