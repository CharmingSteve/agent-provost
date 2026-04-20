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

@test ".env.versions pins fluent-bit image by digest" {
  run grep -E '^FLUENT_BIT_IMAGE=fluent/fluent-bit@sha256:[a-f0-9]{64}$' .env.versions
  [ "$status" -eq 0 ]
}

@test "docker-compose.yml includes fluent-bit service" {
  run grep -E '^\s*fluent-bit:\s*$' docker-compose.yml
  [ "$status" -eq 0 ]
}

@test "docker-compose.yml uses named runtime volume for provost socket" {
  run grep -E '^\s*- provost_run:/var/run/provost$' docker-compose.yml
  [ "$status" -eq 0 ]
}

@test "docker-compose.yml passes AWS and bucket env vars via explicit mappings" {
  run grep -E '^\s*AWS_REGION:\s*\$\{AWS_REGION:-us-east-1\}$' docker-compose.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*AWS_ACCESS_KEY_ID:\s*\$\{AWS_ACCESS_KEY_ID:-\}$' docker-compose.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*AWS_SECRET_ACCESS_KEY:\s*\$\{AWS_SECRET_ACCESS_KEY:-\}$' docker-compose.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*AWS_SESSION_TOKEN:\s*\$\{AWS_SESSION_TOKEN:-\}$' docker-compose.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*S3_BUCKET:\s*\$\{S3_BUCKET:-agent-provost-local\}$' docker-compose.yml
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

@test "CI scans fluent-bit image" {
  run grep -E 'docker pull "\$\{FLUENT_BIT_IMAGE\}"' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'docker image inspect "\$\{FLUENT_BIT_IMAGE\}" >/dev/null' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'trivy image --exit-code 1 --severity CRITICAL,HIGH "\$\{FLUENT_BIT_IMAGE\}"' .github/workflows/ci.yml
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
  run grep -E 'TRIVY_FLUENT_BIT_CVES=' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'has HIGH/CRITICAL CVEs: \$\{TRIVY_FLUENT_BIT_CVES:-unavailable\}' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}
