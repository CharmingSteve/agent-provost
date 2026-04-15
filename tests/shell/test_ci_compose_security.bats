#!/usr/bin/env bats

@test "docker-compose.yml pins openresty image by digest" {
  run grep -E '^\s*image:\s*openresty/openresty@sha256:[a-f0-9]{64}$' docker-compose.yml
  [ "$status" -eq 0 ]
}

@test "alpaca-mcp.Dockerfile pins python alpine base image by digest" {
  run grep -E '^FROM\s+python:3\.11-alpine@sha256:[a-f0-9]{64}$' alpaca-mcp.Dockerfile
  [ "$status" -eq 0 ]
}

@test "CI validates compose config" {
  run grep -E 'docker compose -f docker-compose\.yml config --quiet' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "CI scans built alpaca-mcp image" {
  run grep -E 'ALPACA_IMAGE_TAG=\$\(git rev-parse --short=7 HEAD\)' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'docker image inspect "agent-provost-alpaca-mcp:\$\{ALPACA_IMAGE_TAG\}" >/dev/null' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'trivy image --exit-code 1 --severity CRITICAL,HIGH "agent-provost-alpaca-mcp:\$\{ALPACA_IMAGE_TAG\}"' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "Checkov is blocking and scans workflow/yaml too" {
  run grep -E 'checkov --directory \. --framework dockerfile,github_actions,yaml --quiet$' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E -- '--soft-fail' .github/workflows/ci.yml
  [ "$status" -ne 0 ]
}

@test "CI security gate reports image and CVEs for Trivy failures" {
  run grep -E 'TRIVY_OPENRESTY_CVES=' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'has HIGH/CRITICAL CVEs: \$\{TRIVY_OPENRESTY_CVES:-unavailable\}' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'TRIVY_ALPACA_MCP_CVES=' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'has HIGH/CRITICAL CVEs: \$\{TRIVY_ALPACA_MCP_CVES:-unavailable\}' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}
