# agent-provost
A runtime and audit ledger for autonomous AI. Decouples agent logic via a mandatory Registration Gate, runs entirely on OpenResty/Lua, and provides boundary control and real-time intent-action logs for LLM agent workloads. Move from agentic anarchy to a tamper-proof system of record. And it does much more. AGPL-3.0.

## Architecture
- **OpenResty proxy layer** sits at `agent-proxy` and funnels agent RPC traffic through Lua filters that capture request/response bodies, add structured metadata, and enforce timeouts. This keeps _agent intent_ observable while keeping the downstream MCP server untouched.
- **Sefaria MCP backend** is fronted by the reverse proxy and is currently hardcoded to `sefaria-mcp:8088` inside the Compose stack.

## Running
1. Build the MCP image (`sefaria-mcp`) and spin up the stack via `docker compose up` from the repo root.
2. Agents connect to `agent-proxy:8088`, which in turn mirrors traffic to both `sefaria-mcp:8088` and `www.sefaria.org:443` (for API calls). The proxy also streams full logs into `./agent-provost/nginx-logs`.

## Observability
Logs are emitted in JSON via the Lua body filters. Sample entries illustrate how every agent request is traced from the IDE down through MCP:

```json
{"ts":"2026-03-23T16:19:17+00:00","remote_addr":"192.168.65.1","uri":"/messages/?session_id=163820703d75476f9e99b1e077ef7cf8","method":"POST","status":202,"upstream_addr":"172.19.0.2:8088","request_body":"{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",...\"}","upstream_response_length":"8"}
```

The logs in `nginx-logs/` include `llm_to_mcp_access.log`, `llm_to_mcp_error.log`, `mcp_to_sefaria_access.log`, and `mcp_to_sefaria_error.log`, so you can audit everything the agents request, how the upstream MCP responds, and any connectivity hiccups.

## Current limitations
- The Sefaria MCP server is hardcoded into `docker-compose.yml` / `default.conf`. Adjust the service definitions manually if you need to point at a different MCP endpoint.
