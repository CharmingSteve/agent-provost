# agent-provost

Agent Provost is a mandatory MITM boundary for AI trading flows. It places OpenResty between the client and MCP server, and between the MCP server and Alpaca, so both hops are observable in logs.

## Architecture

Two-hop flow:

1. Hop 1: LLM client -> Agent Provost (port 8000) -> MCP server
2. Hop 2: MCP server -> Agent Provost (port 8081) -> Alpaca APIs

Public entrypoint:

- host port 8088 maps to proxy port 8000

Internal outbound routing from MCP is configured to proxy prefixes:

- trading: http://agent-provost:8081/trading
- data: http://agent-provost:8081/data
- broker: http://agent-provost:8081/broker

## What Gets Logged

Logs live in ./nginx-logs:

- llm_to_alpaca_access.log
- llm_to_alpaca_error.log
- mcp_to_alpaca_access.log
- mcp_to_alpaca_error.log

Both access logs use the same JSON schema:

- time_local
- remote_addr
- request
- status
- body_bytes_sent
- request_time
- upstream_response_time
- request_body
- resp_body

This means each recorded request includes request and response payload text as seen at that hop.

## Four-Step Compliance Model

If you want full traceability, these four events should be visible across the two access logs:

1. LLM -> proxy request to MCP
2. MCP -> proxy request to Alpaca
3. Alpaca -> proxy response to MCP
4. Proxy -> LLM response from MCP

How they map:

- llm_to_alpaca_access.log: steps 1 and 4
- mcp_to_alpaca_access.log: steps 2 and 3

A healthy outbound tool call (for example get_stock_snapshot SPY) should show:

- llm_to_alpaca_access.log line for tools/call
- mcp_to_alpaca_access.log line for upstream API call such as GET /data/v2/stocks/snapshots?symbols=SPY

## What You Will See In Practice

After startup with no traffic:

- access logs may stay unchanged
- error logs may be empty

After one outbound MCP tool call:

- llm_to_alpaca_access.log should add entries for initialize, notifications/initialized, and tools/call
- mcp_to_alpaca_access.log should add at least one entry for the real Alpaca endpoint hit by that tool

If mcp_to_alpaca_access.log does not move while tools/call succeeds, outbound traffic is bypassing hop 2 and the setup is not compliant.

## Built-In Verification

Preferred way to run and verify the full stack from repo root:

- sh agent-provost/verify_proxy_routing.sh

The script:

1. Recreates the entire compose stack (`docker compose up -d --force-recreate`)
2. Truncates all four log files to zero before probing
3. Runs initialize + get_account_info through localhost:8088/mcp
4. Fails unless:
   - hop 1 access log has fresh lines
   - hop 2 access log has fresh lines
   - hop 2 error log is empty

Log side effects are intentional:

- `llm_to_alpaca_access.log` is truncated
- `mcp_to_alpaca_access.log` is truncated
- `llm_to_alpaca_error.log` is truncated
- `mcp_to_alpaca_error.log` is truncated

If you need to preserve existing logs, copy them out before running the script.

## Running

Recommended:

- from repo root: `sh agent-provost/verify_proxy_routing.sh`

This command both starts/recreates compose and proves end-to-end two-hop logging is active.

Manual alternative:

- from `agent-provost` directory: `docker compose up -d --force-recreate`

Then point MCP clients to:

- http://localhost:8088/mcp

## Important Notes

- This README describes current behavior of the active config files in this repo.
- If clients call MCP directly (or MCP calls Alpaca directly), those paths will not be represented in both hop logs.
- Error logs are expected to be empty during normal operation and will populate only when proxy/upstream errors occur.
