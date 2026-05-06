#!/usr/bin/env bats

setup() {
  export TEST_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export TEST_TMPDIR="$(mktemp -d)"
  export JSONL_CHECKER="$TEST_REPO_ROOT/scripts/check_jsonlines_schema.sh"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

write_access_case() {
  case "$1" in
    valid)
      cat > "$2" <<'EOF'
{"time_local":"06/May/2026:12:00:00 +0000","remote_addr":"127.0.0.1","request":"POST / HTTP/1.1","status":"401","body_bytes_sent":"123","request_time":"0.001","upstream_response_time":"-","provost_request_id":"rid-1","provost_user":"","provost_machine":"","request_body":"{\"jsonrpc\":\"2.0\"}","resp_body":"{\"error\":\"MISSING_PROVOST_TOKEN\"}","pri":"err","host":"localhost","ident":"provost_llm_to_mcp_access","stream_tag":"provost_llm_to_mcp_access","log_type":"access","Region":"us-east-1","Instance_ID":"local-dev","message":"{\"time_local\":\"06/May/2026:12:00:00 +0000\"}"}
EOF
      ;;
    rogue)
      cat > "$2" <<'EOF'
{"time_local":"06/May/2026:12:00:00 +0000","remote_addr":"127.0.0.1","request":"POST / HTTP/1.1","status":"401","body_bytes_sent":"123","request_time":"0.001","upstream_response_time":"-","provost_request_id":"rid-1","provost_user":"","provost_machine":"","request_body":"{\"jsonrpc\":\"2.0\"}","resp_body":"{\"error\":\"MISSING_PROVOST_TOKEN\"}","pri":"err","host":"localhost","ident":"provost_llm_to_mcp_access","stream_tag":"provost_llm_to_mcp_access","log_type":"access","Region":"us-east-1","Instance_ID":"local-dev","message":"{\"time_local\":\"06/May/2026:12:00:00 +0000\"}","test_rogue_field":"boom"}
EOF
      ;;
    missing)
      cat > "$2" <<'EOF'
{"time_local":"06/May/2026:12:00:00 +0000","remote_addr":"127.0.0.1","request":"POST / HTTP/1.1","body_bytes_sent":"123","request_time":"0.001","upstream_response_time":"-","provost_request_id":"rid-1","provost_user":"","provost_machine":"","request_body":"{\"jsonrpc\":\"2.0\"}","resp_body":"{\"error\":\"MISSING_PROVOST_TOKEN\"}","pri":"err","host":"localhost","ident":"provost_llm_to_mcp_access","stream_tag":"provost_llm_to_mcp_access","log_type":"access","Region":"us-east-1","Instance_ID":"local-dev","message":"{\"time_local\":\"06/May/2026:12:00:00 +0000\"}"}
EOF
      ;;
    renamed)
      cat > "$2" <<'EOF'
{"time_local":"06/May/2026:12:00:00 +0000","remote_addr":"127.0.0.1","request":"POST / HTTP/1.1","status_code":"401","body_bytes_sent":"123","request_time":"0.001","upstream_response_time":"-","provost_request_id":"rid-1","provost_user":"","provost_machine":"","request_body":"{\"jsonrpc\":\"2.0\"}","resp_body":"{\"error\":\"MISSING_PROVOST_TOKEN\"}","pri":"err","host":"localhost","ident":"provost_llm_to_mcp_access","stream_tag":"provost_llm_to_mcp_access","log_type":"access","Region":"us-east-1","Instance_ID":"local-dev","message":"{\"time_local\":\"06/May/2026:12:00:00 +0000\"}"}
EOF
      ;;
  esac
}

write_error_case() {
  case "$1" in
    valid)
      cat > "$2" <<'EOF'
{"time_local":"06/May/2026:12:00:00 +0000","remote_addr":"127.0.0.1","request":"POST / HTTP/1.1","status":"401","provost_request_id":"rid-1","provost_user":"","provost_machine":"","request_body":"{\"jsonrpc\":\"2.0\"}","resp_body":"{\"error\":\"MISSING_PROVOST_TOKEN\"}","error_code":"MISSING_PROVOST_TOKEN","error_detail":"","stream_tag":"provost_mcp_to_llm_error","date":"2026-05-06T12:00:00Z","pri":"err","host":"localhost","ident":"provost_mcp_to_llm_error","log_type":"error","Region":"us-east-1","Instance_ID":"local-dev"}
EOF
      ;;
    rogue)
      cat > "$2" <<'EOF'
{"time_local":"06/May/2026:12:00:00 +0000","remote_addr":"127.0.0.1","request":"POST / HTTP/1.1","status":"401","provost_request_id":"rid-1","provost_user":"","provost_machine":"","request_body":"{\"jsonrpc\":\"2.0\"}","resp_body":"{\"error\":\"MISSING_PROVOST_TOKEN\"}","error_code":"MISSING_PROVOST_TOKEN","error_detail":"","stream_tag":"provost_mcp_to_llm_error","date":"2026-05-06T12:00:00Z","pri":"err","host":"localhost","ident":"provost_mcp_to_llm_error","log_type":"error","Region":"us-east-1","Instance_ID":"local-dev","test_rogue_field":"boom"}
EOF
      ;;
    missing)
      cat > "$2" <<'EOF'
{"time_local":"06/May/2026:12:00:00 +0000","remote_addr":"127.0.0.1","request":"POST / HTTP/1.1","provost_request_id":"rid-1","provost_user":"","provost_machine":"","request_body":"{\"jsonrpc\":\"2.0\"}","resp_body":"{\"error\":\"MISSING_PROVOST_TOKEN\"}","error_code":"MISSING_PROVOST_TOKEN","error_detail":"","stream_tag":"provost_mcp_to_llm_error","date":"2026-05-06T12:00:00Z","pri":"err","host":"localhost","ident":"provost_mcp_to_llm_error","log_type":"error","Region":"us-east-1","Instance_ID":"local-dev"}
EOF
      ;;
    renamed)
      cat > "$2" <<'EOF'
{"time_local":"06/May/2026:12:00:00 +0000","remote_addr":"127.0.0.1","request":"POST / HTTP/1.1","status_code":"401","provost_request_id":"rid-1","provost_user":"","provost_machine":"","request_body":"{\"jsonrpc\":\"2.0\"}","resp_body":"{\"error\":\"MISSING_PROVOST_TOKEN\"}","error_code":"MISSING_PROVOST_TOKEN","error_detail":"","stream_tag":"provost_mcp_to_llm_error","date":"2026-05-06T12:00:00Z","pri":"err","host":"localhost","ident":"provost_mcp_to_llm_error","log_type":"error","Region":"us-east-1","Instance_ID":"local-dev"}
EOF
      ;;
  esac
}

@test "access schema accepts the canonical final record" {
  file="$TEST_TMPDIR/access-valid.jsonl"
  write_access_case valid "$file"

  run "$JSONL_CHECKER" "$TEST_REPO_ROOT/schemas/access_log_schema.json" "$file"
  [ "$status" -eq 0 ]
}

@test "access schema rejects added, removed, and renamed fields" {
  for variant in rogue missing renamed; do
    file="$TEST_TMPDIR/access-$variant.jsonl"
    write_access_case "$variant" "$file"
    run "$JSONL_CHECKER" "$TEST_REPO_ROOT/schemas/access_log_schema.json" "$file"
    [ "$status" -ne 0 ]
  done
}

@test "error schema accepts the canonical final record" {
  file="$TEST_TMPDIR/error-valid.jsonl"
  write_error_case valid "$file"

  run "$JSONL_CHECKER" "$TEST_REPO_ROOT/schemas/error_log_schema.json" "$file"
  [ "$status" -eq 0 ]
}

@test "error schema rejects added, removed, and renamed fields" {
  for variant in rogue missing renamed; do
    file="$TEST_TMPDIR/error-$variant.jsonl"
    write_error_case "$variant" "$file"
    run "$JSONL_CHECKER" "$TEST_REPO_ROOT/schemas/error_log_schema.json" "$file"
    [ "$status" -ne 0 ]
  done
}