#!/usr/bin/env bats

@test "mock compose exists and keeps traffic on internal-only network" {
  run grep -E '^\s*mcp_internal:' mock-mcp/docker-compose.yml
  [ "$status" -eq 0 ]

  run grep -E '^\s*internal:\s*true$' mock-mcp/docker-compose.yml
  [ "$status" -eq 0 ]

  run grep -E '^\s*proxy_egress:' mock-mcp/docker-compose.yml
  [ "$status" -ne 0 ]
}

@test "mock compose wires MCP to hop-2 proxy endpoint" {
  run grep -E 'SOVEREIGN_API_URL:\s*"http://agent-provost:8081"' mock-mcp/docker-compose.yml
  [ "$status" -eq 0 ]
}

@test "mock proxy defines both access and error logs per hop" {
  run grep -E 'llm_to_mcp_access\.log' mock-mcp/default.conf
  [ "$status" -eq 0 ]

  run grep -E 'llm_to_mcp_error\.log' mock-mcp/default.conf
  [ "$status" -eq 0 ]

  run grep -E 'mcp_to_api_access\.log' mock-mcp/default.conf
  [ "$status" -eq 0 ]

  run grep -E 'mcp_to_api_error\.log' mock-mcp/default.conf
  [ "$status" -eq 0 ]
}

@test "mock proxy hop-1 routes to mock-mcp and hop-2 routes to sovereign-api" {
  run grep -E 'proxy_pass http://mock-mcp:8088;' mock-mcp/default.conf
  [ "$status" -eq 0 ]

  run grep -E 'proxy_pass http://sovereign-api:9000;' mock-mcp/default.conf
  [ "$status" -eq 0 ]
}

@test "mock verify script validates body capture via bounded tails" {
  run grep -E 'tail -n 8 "\$LOG_DIR/llm_to_mcp_access\.log"' mock-mcp/verify_mock_proxy_routing.sh
  [ "$status" -eq 0 ]

  run grep -E 'tail -n 8 "\$LOG_DIR/mcp_to_api_access\.log"' mock-mcp/verify_mock_proxy_routing.sh
  [ "$status" -eq 0 ]

  run grep -E 'request_body' mock-mcp/verify_mock_proxy_routing.sh
  [ "$status" -eq 0 ]

  run grep -E 'resp_body' mock-mcp/verify_mock_proxy_routing.sh
  [ "$status" -eq 0 ]
}
