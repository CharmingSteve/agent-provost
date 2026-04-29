#!/usr/bin/env bats
# tests/shell/test_entrypoint.bats
# Unit tests for entrypoint.sh and verify_proxy_routing.sh.
# These tests inspect script content and structure; they do not execute the
# scripts (which require a live Docker / Python environment).

# ── entrypoint.sh ────────────────────────────────────────────────────────────

@test "entrypoint.sh: strict error handling is enabled (set -e)" {
    run grep -c "^set -e" entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: patches TRADE_API_URL override into server.py" {
    run grep -c "TRADE_API_URL" entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: starts MCP server on port 8088" {
    run grep -c "\-\-port 8088" entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: uses streamable-http transport" {
    run grep -c "streamable-http" entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: binds server to 0.0.0.0 (all interfaces)" {
    run grep -c "\-\-host 0.0.0.0" entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: uses exec to replace the shell process (no zombie)" {
    run grep -c "^exec " entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

# ── verify_proxy_routing.sh ──────────────────────────────────────────────────

@test "verify_proxy_routing.sh: strict error handling is enabled (set -e)" {
    run grep -c "^set -e" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: validates fluent-bit health before probe" {
    run grep -c "wait_for_fluentbit_health\|fluent-bit health" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: validates socket path in shared runtime dir" {
    run grep -c "fluent-bit.sock\|socket present" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: supports S3 audit evidence check" {
    run grep -c "check_s3_for_probe\|VERIFY_S3_BUCKET\|agent-provost/logs" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: supports buffer fallback evidence check" {
    run grep -c "check_buffer_evidence\|fluent-bit buffer" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: embeds unique probe request id marker" {
    run grep -c "PROBE_ID\|X-Provost-Request-Id\|PROVOST_VERIFY_REQUEST_ID" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: can force S3-only or buffer-only mode" {
    run grep -c "VERIFY_REQUIRE_S3\|true)\|false)\|auto)" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: reports PASS for fluent-bit audit path" {
    run grep -c "PASS: fluent-bit socket/audit path validated" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: probes the MCP endpoint on port 8088" {
    run grep -c "localhost:8088" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

# ── bootstrap.sh ─────────────────────────────────────────────────────────────

@test "bootstrap.sh: defines truthy helper for flag parsing" {
    run grep -c "^is_true()" bootstrap.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "bootstrap.sh: ec2 fallback copy requires explicit ALLOW_EC2_LOCAL_FALLBACK_SECRETS" {
    run grep -c 'if is_true "\${ALLOW_EC2_LOCAL_FALLBACK_SECRETS:-false}"; then' bootstrap.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "bootstrap.sh: dev and runner still sync local fallback secrets" {
    run grep -E -c '^[[:space:]]+sync_local_fallback_secrets "\$PROVOST_SECRETS_DIR"$' bootstrap.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 2 ]
}
