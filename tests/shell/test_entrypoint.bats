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

@test "verify_proxy_routing.sh: truncates all four log files before each run" {
    run grep -c ": >" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 4 ]
}

@test "verify_proxy_routing.sh: verifies hop-1 log received traffic" {
    run grep -c "hop1_count" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: verifies hop-2 log received traffic" {
    run grep -c "hop2_count" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: fails when hop-1 has no traffic" {
    run grep -c "no hop-1 traffic logged" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: fails when hop-2 has no traffic" {
    run grep -c "no hop-2 traffic logged" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: fails when hop-2 error log is non-empty" {
    run grep -c "hop-2 errors present" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: reports PASS when both hops logged traffic" {
    run grep -c "PASS: both hops logged" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: probes the MCP endpoint on port 8088" {
    run grep -c "localhost:8088" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}
