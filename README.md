# agent-provost
A mandatory man-in-the-middle (MITM) control plane for AI agents. Every inbound request and outbound upstream call is forced through OpenResty/Lua and logged with bodies + headers for auditability. AGPL-3.0.

## What This Is
`agent-provost` is not a passive logger. It is an active inline boundary:

- Hop 1: LLM client -> MCP server (reverse proxy on port `8000`)
- Hop 2: MCP server -> Alpaca APIs (forward/egress proxy on port `8081`)

Because both hops are proxied, both directions are observable and recorded.

## Logging Guarantee
All major traffic surfaces are captured in JSON logs under `./nginx-logs/`:

- `llm_to_alpaca_access.log`
- `llm_to_alpaca_error.log`
- `mcp_to_alpaca_access.log`
- `mcp_to_alpaca_error.log`

The access logs include:

- request and response bodies
- truncation flags for oversized payloads
- request/response metadata (status, upstream timings, method, URI)
- selected request/response headers (including auth/header fields as seen by the proxy)

## Log Coverage Summary
The current Alpaca proxy logging is intentionally broader than the original Sefaria baseline used in this project.

Per access-log entry, you capture all of the following categories at once:

- Identity and transport: timestamp, server socket, client IP/port, request ID, connection counters, protocol.
- HTTP request envelope: method, host, URI, query args, request length, content type/length.
- HTTP response envelope: status, bytes sent, body bytes sent, request_time.
- Upstream timing and target: upstream_addr, upstream_status, connect/header/response timings, upstream response length.
- Full request payload visibility: `request_body` plus `request_body_truncated`.
- Full response payload visibility: `response_body` plus `response_body_truncated`.
- Inbound headers: user-agent, authorization, accept headers, forwarded headers, cookies, origin.
- Outbound/sent headers: sent content-type/length/cache metadata and related response headers.
- Upstream response headers: upstream content-type/length/date/server and cache-related headers.

This means each log line is a full transaction record, not just an access summary.

Compared to the original Sefaria setup, this version adds stronger body observability controls (explicit body truncation flags) while preserving two-hop visibility (`llm_to_alpaca_*` and `mcp_to_alpaca_*`).

## End-Of-File Graph Log Examples
Two concrete examples from the tail region of the access logs show full graph-shaped tool payloads (request + response + structured content) captured in single JSON transactions:

- `nginx-logs/llm_to_alpaca_access.log`, line 24:
	`tools/call` for `get_stock_bars` with multi-symbol arguments in `request_body`, plus graph payload in `response_body` and `structuredContent` (`counts`, `per_symbol`, and bars data).
- `nginx-logs/mcp_to_alpaca_access.log`, line 22:
	Matching `get_stock_bars` transaction on the second hop, again including full request arguments and graph response structure (`tool`, `request`, `counts`, and per-symbol bar records).

These examples demonstrate that the same graph transaction is visible on both MITM hops, which is the core auditability requirement.

## Proof In Config (line citations)
The behavior above is directly implemented in `default.conf`:

- Request body capture enabled globally: line 13 (`lua_need_request_body on;`)
- JSON log format declaration: line 16 (`log_format json_full`)
- Request/response bodies in log schema: lines 41-44 (`request_body`, `response_body`, truncation flags)
- Header fields in log schema (example: authorization): line 49 (`http_authorization`)
- Inbound MITM hop listener (LLM -> MCP): line 123 (`listen 8000;`)
- Inbound access log destination: line 130 (`llm_to_alpaca_access.log`)
- Inbound request body Lua capture: line 134 (`access_by_lua_block`)
- Inbound response body Lua capture: line 212 (`body_filter_by_lua_block`)
- Egress MITM hop listener (MCP -> Alpaca): line 245 (`listen 8081;`)
- Egress access log destination: line 252 (`mcp_to_alpaca_access.log`)
- Egress upstream routing examples:
	- line 256 (`proxy_pass https://alpaca_trading_api/`)
	- line 307 (`proxy_pass https://alpaca_data_api/`)
	- line 358 (`proxy_pass https://alpaca_broker_api/`)
- Egress body capture blocks:
	- response capture lines 258, 309, 360 (`body_filter_by_lua_block`)
	- request capture lines 278, 329, 380 (`access_by_lua_block`)

## Running
1. From repo root, start the stack with Docker Compose for this directory.
2. Point your MCP client at `localhost:8088` (container maps host `8088` -> proxy `8000`).
3. Inspect logs in `./agent-provost/nginx-logs`.

## Notes
- Large payloads are truncated in logs to cap memory/size (`*_truncated` fields indicate this).
- If traffic bypasses this proxy, it will not be logged; keep clients and MCP egress pointed at this boundary.
