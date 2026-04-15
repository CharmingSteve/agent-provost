#!/usr/bin/env bats

@test "docker-compose.yml uses OPENRESTY_IMAGE variable for openresty image" {
  run grep -E '^\s*image:\s*\$\{OPENRESTY_IMAGE\}' docker-compose.yml
  [ "$status" -eq 0 ]
}

@test ".env.versions pins openresty image by digest" {
  run grep -E '^OPENRESTY_IMAGE=openresty/openresty@sha256:[a-f0-9]{64}$' .env.versions
  [ "$status" -eq 0 ]
}

@test "alpaca-mcp.Dockerfile uses ARG BASE_PYTHON_IMAGE" {
  run grep -E '^ARG BASE_PYTHON_IMAGE=python:3\.11-alpine@sha256:[a-f0-9]{64}$' alpaca-mcp.Dockerfile
  [ "$status" -eq 0 ]
  run grep -E '^FROM \$\{BASE_PYTHON_IMAGE\}$' alpaca-mcp.Dockerfile
  [ "$status" -eq 0 ]
}

@test ".env.versions pins python base image by digest" {
  run grep -E '^BASE_PYTHON_IMAGE=python:3\.11-alpine@sha256:[a-f0-9]{64}$' .env.versions
  [ "$status" -eq 0 ]
}

@test "CI validates compose config with env-file" {
  run grep -E 'docker compose --env-file .env\.versions -f docker-compose\.yml config --quiet' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "CI does not contain stale hardcoded openresty SHA" {
  run grep -F '4dcb9e26b5872609488cf3b6d47c330faec246978d54f8d2812b65431d789b50' .github/workflows/ci.yml
  [ "$status" -ne 0 ]
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
