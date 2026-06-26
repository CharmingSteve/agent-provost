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
  run grep -E '^BASE_PYTHON_IMAGE=public\.ecr\.aws/docker/library/python:3\.11-alpine@sha256:[a-f0-9]{64}$' .env.versions
  [ "$status" -eq 0 ]
}

@test ".env.versions pins fluent-bit image by digest" {
  run grep -E '^FLUENT_BIT_IMAGE=public\.ecr\.aws/aws-observability/aws-for-fluent-bit@sha256:[a-f0-9]{64}$' .env.versions
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

@test "CI includes always-on compose smoke gate" {
  run grep -E '^  compose-smoke:' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E '^    runs-on: ubuntu-24.04-arm$' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'docker compose --env-file \.env\.versions pull' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'docker compose --env-file \.env\.versions up -d' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'docker compose --env-file \.env\.versions down -v --remove-orphans' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "CI includes blocking GitHub Actions lint via actionlint" {
  run grep -E '^  lint-github-actions:' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'name: actionlint \(GitHub Actions\)' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'https://github.com/rhysd/actionlint/releases/download/' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*actionlint$' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "CI includes blocking GitHub Actions security lint via zizmor" {
  run grep -E '^  security-zizmor:' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'name: zizmor \(GitHub Actions security\)' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'python3 -m pip install zizmor==1\.24\.1' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*zizmor \.github/workflows/$' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "zizmor baseline config is narrow and pins only accepted workflow findings" {
  run grep -E '^rules:$' .github/zizmor.yml
  [ "$status" -eq 0 ]
  run grep -E '^  dangerous-triggers:$' .github/zizmor.yml
  [ "$status" -eq 0 ]
  run grep -E '^      - increment-version\.yml:3$' .github/zizmor.yml
  [ "$status" -eq 0 ]
  run grep -E '^  unpinned-uses:$' .github/zizmor.yml
  [ "$status" -eq 0 ]
  run grep -E '^      - ci\.yml$' .github/zizmor.yml
  [ "$status" -eq 0 ]
  run grep -E '^      - increment-version\.yml$' .github/zizmor.yml
  [ "$status" -eq 0 ]
  run grep -E '^  artipacked:$' .github/zizmor.yml
  [ "$status" -eq 0 ]
  count=$(grep -E '^      - ' .github/zizmor.yml | wc -l | tr -d ' ')
  [ "$count" -eq 5 ]
}

@test "CI does not contain stale hardcoded openresty SHA" {
  run grep -F '4dcb9e26b5872609488cf3b6d47c330faec246978d54f8d2812b65431d789b50' .github/workflows/ci.yml
  [ "$status" -ne 0 ]
}

@test "CI runs Fluent Bit schema validation in integration-tests (not compose-smoke)" {
  run grep -E 'compose-smoke:' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'integration-tests:' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'Generate Traffic and Validate Final Fluent Bit JSON Schemas' .github/workflows/ci.yml
  [ "$status" -ne 0 ]
  run grep -E 'name: Generate Error Log, Download from S3, and Validate Schema' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'check-jsonschema' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "build-secure-push-test runs independently and pushes only on image changes" {
  run grep -E '^  build-secure-push-test:' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'Detect image content changes' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'if: env\.IMAGE_CHANGED == '\''true'\''' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run sh -c "awk '/^  build-secure-push-test:/{flag=1; next} /^  [a-zA-Z0-9_-]+:/{if(flag) exit} flag' .github/workflows/ci.yml | grep -E '^\\s+needs:'"
  [ "$status" -ne 0 ]
  run grep -E 'Step 4 \(Login & Push to ECR\) - Push tags' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "CI scans built alpaca-mcp image" {
  run grep -E 'TRIVY_BUILD_TAG=\$\(git rev-parse --short=7 HEAD\)' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'docker image inspect "agent-provost-alpaca-mcp:\$\{TRIVY_BUILD_TAG\}" >/dev/null' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'trivy image --exit-code 1 --severity CRITICAL,HIGH "agent-provost-alpaca-mcp:\$\{TRIVY_BUILD_TAG\}"' .github/workflows/ci.yml
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

@test "CI includes python dependency audit with pip-audit" {
  run grep -E '^  security-python-audit:' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  run grep -E 'pip-audit .*hash-pip/requirements-runtime.txt' .github/workflows/ci.yml
  [ "$status" -eq 0 ]
}

@test "requirements-runtime.txt pins pip to CVE-clean version 26.1" {
  # pip==26.0.1 has CVE-2026-3219; only 26.1 or newer is clean
  run grep -E '^pip==26\.1' hash-pip/requirements-runtime.txt
  [ "$status" -eq 0 ]
  # Must NOT contain the vulnerable version
  run grep -E '^pip==26\.0\.1' hash-pip/requirements-runtime.txt
  [ "$status" -ne 0 ]
}

@test "requirements-runtime.txt pip 26.1 hashes match known-good PyPI sha256" {
  # Hashes sourced from https://pypi.org/pypi/pip/26.1.2/json
  # whl artifact sha256
  run grep -F 'sha256:382ff9f685ee3bc25864f820aa50505825f10f5458ffff07e30a6d96e5715cab' \
    hash-pip/requirements-runtime.txt
  [ "$status" -eq 0 ]
  # sdist artifact sha256
  run grep -F 'sha256:f49cd134c61cf2fd75e0ce2676db03e4054504a5a4986d00f8299ae632dc4605' \
    hash-pip/requirements-runtime.txt
  [ "$status" -eq 0 ]
}

@test "every package pin in requirements-runtime.txt has at least one sha256 hash" {
  # Extract lines like 'package==version \' and verify the next non-comment line has --hash=sha256:
  # Approach: no package==x block should have zero hash lines before the next blank/comment
  local req_file="hash-pip/requirements-runtime.txt"
  local pkg_count hash_count
  # Count package==version declarations (lines matching word==version, not comments)
  pkg_count=$(grep -cE '^[a-zA-Z0-9._-]+==[0-9]' "$req_file")
  # Count --hash=sha256: entries
  hash_count=$(grep -cE -- '--hash=sha256:' "$req_file")
  [ "$pkg_count" -ge 1 ]
  [ "$hash_count" -ge "$pkg_count" ]
}

@test "alpaca-mcp.Dockerfile uses --require-hashes for pip install" {
  run grep -E '\-\-require-hashes' alpaca-mcp.Dockerfile
  [ "$status" -eq 0 ]
}

@test ".env.versions defines ALPACA_IMAGE" {
  run grep -E '^ALPACA_IMAGE=public\.ecr\.aws/e2u9m9o7/agent-provost$' .env.versions
  [ "$status" -eq 0 ]
}

@test "docker-compose.yml uses ALPACA_IMAGE for alpaca-mcp" {
  run grep -E 'image:\s*\$\{ALPACA_IMAGE\}@\$\{ALPACA_IMAGE_TAG\}' docker-compose.yml
  [ "$status" -eq 0 ]
}

@test ".env.versions pins ALPACA_IMAGE_TAG by digest" {
  run grep -E '^ALPACA_IMAGE_TAG=sha256:[a-f0-9]{64}$' .env.versions
  [ "$status" -eq 0 ]
}

@test "docker-compose.yml has pull_policy if-not-present for alpaca-mcp" {
  run grep -B 2 'pull_policy: if_not_present' docker-compose.yml
  [ "$status" -eq 0 ]
  # Verify it appears at least 3 times (once for each service)
  count=$(grep -c 'pull_policy: if_not_present' docker-compose.yml)
  [ "$count" -ge 3 ]
}

@test "compose services are configured as non-root and read-only" {
  run grep -E '^\s*user:\s*"10001:10001"$' docker-compose.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*user:\s*"65532:65532"$' docker-compose.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*read_only:\s*true$' docker-compose.yml
  [ "$status" -eq 0 ]
}

@test "increment-version workflow keeps same-repo guard and anti-recursion branch exclusion" {
  run grep -E "github\.event\.pull_request\.head\.repo\.full_name == github\.repository" .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
  run grep -E "startsWith\(github\.event\.pull_request\.head\.ref, 'version-bump/'\)" .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
}

@test "increment-version workflow keeps current PR-activity trigger model" {
  run grep -E '^  pull_request_target:$' .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
  run grep -E '^    types: \[opened, reopened, synchronize, ready_for_review\]$' .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
}

@test "increment-version workflow keeps minimal write permission scope" {
  run grep -E '^permissions:$' .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
  run grep -E '^  contents: write$' .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
  run grep -E '^[[:space:]]+(actions|pull-requests|packages|id-token): write$' .github/workflows/increment-version.yml
  [ "$status" -ne 0 ]
}

@test "increment-version workflow does not execute checked-out repo scripts" {
  run grep -E '(^|[[:space:]])(bash|sh|source)[[:space:]]+\./|(^|[[:space:]])\./[^[:space:]]+' .github/workflows/increment-version.yml
  [ "$status" -ne 0 ]
}

@test "increment-version workflow keeps PR head ref usage bounded to current safe locations" {
  count=$(grep -o 'github\.event\.pull_request\.head\.ref' .github/workflows/increment-version.yml | wc -l | tr -d ' ')
  [ "$count" -eq 3 ]
  run grep -E "!startsWith\(github\.event\.pull_request\.head\.ref, 'version-bump/'\)" .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*ref: \$\{\{ github\.event\.pull_request\.head\.ref \}\}$' .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*PR_HEAD_REF: \$\{\{ github\.event\.pull_request\.head\.ref \}\}$' .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
}

@test "increment-version workflow remains limited to version.txt patch bump operations" {
  run grep -E 'git show origin/main:version\.txt' .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*echo "\$new_version" > version\.txt$' .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*git add version\.txt$' .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
  run grep -E '^\s*git push origin "HEAD:\$\{PR_HEAD_REF\}"$' .github/workflows/increment-version.yml
  [ "$status" -eq 0 ]
}
