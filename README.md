# Agent Provost: The Safety Firewall & Audit Ledger for Autonomous AI Trading

**Agent Provost** is a high-performance, mandatory MITM (Man-in-the-Middle) boundary designed specifically for **AI trading flows** and **Autonomous Agents**. By placing an OpenResty (Nginx + Lua) proxy between your LLM client, your **Model Context Protocol (MCP) server**, and the **Alpaca Trading API**, it ensures every single trade is observable, audited, and safety-checked.

Stop your AI agent from going rogue with programmable risk guardrails and a tamper-proof audit trail.

---

## 🚀 Key Features for AI Safety & Compliance

*   **Programmable Circuit Breaker (Risk Kill-Switch):** Built-in Lua logic that intercepts and blocks high-risk orders. (Default: Blocks any trade quantity > 100).
*   **Upstream Rate-Limit Guardrails:** Automatically blocks new inbound requests for 60 seconds after an upstream `429`, and preemptively blocks when upstream `RateLimit-Remaining` is below threshold.
*   **Two-Hop Observability:** Full visibility into both the LLM-to-MCP and MCP-to-Alpaca communication channels.
*   **Zero-Trust Audit Ledger:** Every request and response body is captured in structured JSON logs for forensic analysis and compliance.
*   **Runtime Source Patching:** Unique `entrypoint.sh` technology that hot-patches the `alpaca-mcp-server` at runtime to support proxy routing without needing a custom fork.
*   **Dockerized Deployment:** Spin up a fully compliant, two-hop trading environment in seconds with Docker Compose.

---

## 🏗️ Architecture: The Two-Hop Flow

To guarantee full traceability, Agent Provost monitors two distinct hops:

1.  **Hop 1 (Inbound):** `LLM Client` -> `Agent Provost (Port 8000)` -> `MCP Server`
2.  **Hop 2 (Outbound):** `MCP Server` -> `Agent Provost (Port 8081)` -> `Alpaca APIs`

This "Double-Proxy" setup ensures that even if the MCP server is compromised or contains bugs, the outbound calls to Wall Street are still captured and governed by your proxy rules.

Public entrypoint:

- host port 8088 maps to proxy port 8000

Internal outbound routing from MCP is configured to proxy prefixes:

- trading: http://agent-provost:8081/trading
- data: http://agent-provost:8081/data
- broker: http://agent-provost:8081/broker

### Four-Step Compliance Model

If you want full traceability, these four events should be visible across the two access logs:

1. LLM -> proxy request to MCP
2. MCP -> proxy request to Alpaca
3. Alpaca -> proxy response to MCP
4. Proxy -> LLM response from MCP

How they map:

- `llm_to_alpaca_access.log`: step 1 (LLM -> MCP) and step 4 (MCP -> LLM)
- `mcp_to_alpaca_access.log`: step 2 (MCP -> Alpaca) and step 3 (Alpaca -> MCP)

For normal authenticated trading traffic, both access logs should carry the same identity fields:

- `provost_user` (for example `your.email@domain.com`)
- `provost_machine` (for example `YOUR-MACHINE-NAME`)
- `provost_request_id` (the request correlation id shared across hops)

These values should be present and non-null for normal MCP trading flows so the four-hop audit trail can be correlated end to end.

---

## 🛡️ Safety Controls & Governance

Agent Provost doesn't just watch; it protects. The proxy contains an active **Circuit Breaker** inside `default.conf` that inspects JSON payloads in real-time using a **hot-reloadable, JSON-driven rule engine**.

### Dynamic Rules Engine

Rules are stored in [`rules.json`](rules.json) and evaluated by `lua/rules_engine.lua` on every request.  The rule set is kept in `lua_shared_dict` (OpenResty shared memory) and reloaded from disk every 10 seconds—no nginx reload or HUP required.

See [`RULES_ENGINE.md`](RULES_ENGINE.md) for full documentation: JSON structure, hot-reload architecture, how to add rules, and operational notes for SREs.

### Current Protections

| Rule | Default | Description |
|---|---|---|
| `max_trade_size` | **enabled**, limit = 100 | Blocks any `tools/call` with `quantity` or `qty` > 100 |
| `blocked_tickers` | **enabled**, list = GME/AMC/BBBY | Blocks trades on restricted ticker symbols using normalized symbol fields |
| `blocked_tool_names` | disabled | Optional: block named trade tools regardless of argument syntax |
| `restricted_ticker_tool_rules` | **enabled**, list = GME/AMC/BBBY | Blocks restricted symbols when used by specific order tools |
| `trading_window` | disabled | Placeholder: restrict trading to specific UTC hours |
| `upstream_429_cooldown` | **enabled**, 60s | Blocks all inbound traffic with `429` while cooldown is active after upstream `429` |
| `upstream_remaining_guard` | **enabled**, threshold = 10 | Blocks inbound traffic with `429` when upstream remaining quota falls below threshold |

Blocked requests return either `403 Forbidden` (`PROVOST_INTERVENTION`) for policy violations or `429 Too Many Requests` for upstream-protection guardrails.

### Live Rule Update Example (no restart)

```bash
# Lower the trade size limit from 100 to 10 — takes effect within 10 s
sed -i 's/"limit": 100/"limit": 10/' rules.json
```

### 💡 We Need Your Ideas!
We are expanding the safety suite. What other controls should we add?
- [ ] Price-based slippage protection?
- [ ] Daily Notional Value (DNV) caps?
- [ ] Restricted ticker "Blacklists"?
- [ ] Time-of-day trading windows?

**[Suggest a new safety control in the Issues section!](https://github.com/CharmingSteve/agent-provost/issues)**

---

## 📊 The Ultimate Audit Ledger

Logs are stored in `./nginx-logs` in a structured JSON format, making them ready for ingestion into ELK, Splunk, or custom monitoring dashboards.

Log files:

- `llm_to_alpaca_access.log`
- `llm_to_alpaca_error.log`
- `mcp_to_alpaca_access.log`
- `mcp_to_alpaca_error.log`

Each entry captures:
- `time_local` & `remote_addr`
- `request` (Method/Path)
- `status` (200, 403, etc.)
- `body_bytes_sent`, `request_time`, `upstream_response_time`
- `provost_request_id` (the correlation id shared across hops)
- `provost_user` (the human/client identity from the MCP request headers)
- `provost_machine` (the client machine identity from the MCP request headers)
- `request_body` (The actual JSON sent by the AI)
- `resp_body` (The actual JSON returned by the API)

`provost_request_id` is created on Hop 1 when the inbound request is validated. If the client already supplied `X-Provost-Request-Id`, the proxy reuses it; otherwise Hop 1 generates one from `request_id` or a timestamp-random fallback, stores the identity context in shared memory, and forwards the same id downstream so Hop 2 can recover and log the same correlation id.

---

## 🛠️ Quick Start & Verification

### 1. Requirements
- Docker and Docker Compose
- Alpaca API Keys (Paper or Live) in a `.env` file for local dev
- A shared `PROVOST_TOKEN` in `.env` for local dev and integration auth

### 2. Run the Compliance Check
Run the built-in verification script to spin up the stack, execute an MCP initialize + get_account_info probe, and verify the logs:

```bash
sh agent-provost/verify_proxy_routing.sh
```

The script:

1. Recreates the entire compose stack (`docker compose up -d --force-recreate`)
2. Truncates all four log files to zero before probing
3. Runs initialize + get_account_info through localhost:8088/mcp
4. Fails unless:
   - hop 1 access log has fresh lines
   - hop 2 access log has fresh lines
   - hop 2 error log is empty

After verification, inspect `llm_to_alpaca_access.log` and `mcp_to_alpaca_access.log` and confirm recent authenticated entries contain the same `provost_user`, `provost_machine`, and `provost_request_id` values across both hops.

Log side effects are intentional. If you need to preserve existing logs, copy them out before running the script.

### 3. Manual Startup
Before starting the stack locally, stage secrets from `.env`:

```bash
eval "$(sh bootstrap.sh dev)"
docker compose up -d --build
```

`bootstrap.sh dev` stages `.env` secrets into a temporary directory and exports `PROVOST_SECRETS_DIR`; `docker compose` then mounts that directory into `/run/secrets` in both containers. If you change `.env`, restart the bootstrap step and recreate the compose stack so the mounted `provost_token` still matches your MCP client configuration.

Point your MCP clients to: `http://localhost:8088/mcp`

Required client headers for Hop 1 auth:

- `X-Provost-Token` (must match `/run/secrets/provost_token`)
- `X-Provost-User` (human identity; for example `your.email@domain.com`)
- `X-Provost-Machine` (client machine identity; for example `YOUR-MACHINE-NAME`)

Do not set `X-Provost-Request-Id` manually in `mcp.json` unless you have a specific reason to supply your own correlation id. In the normal flow, Agent Provost creates and forwards that id automatically.

Example `mcp.json` server entry:

```json
{
   "transport": "streamable-http",
   "url": "http://localhost:8088/mcp",
   "headers": {
      "X-Provost-Token": "dev-provost-token-123",
      "X-Provost-User": "your.email@domain.com",
      "X-Provost-Machine": "YOUR-MACHINE-NAME"
   }
}
```

For integration and EC2/production, `bootstrap.sh` also stages `provost_token` from runner env (`PROVOST_TOKEN`) or AWS Secrets Manager (`PROVOST_TOKEN` key in the JSON secret payload).

---

## 🧪 Testing Token Authentication

Token authentication and rate-limit protection are validated across three levels:
- **Configuration tests** (Lua/BATS): Verify token validation code, rate-limit guard logic, and secret staging logic are present
- **Permission tests** (BATS): Verify token files are staged with restrictive `600` permissions
- **Runtime tests** (BATS/Lua): Requests with missing/invalid tokens are rejected, and rate-limit cooldown/remaining logic is enforced

Run token auth tests locally:

```bash
bats tests/shell/test_provost_token.bats  # 12 token auth validation tests
bats tests/shell/                           # All 34 shell tests
busted tests/lua/                            # All 103 Lua config tests
```

The CI pipeline runs all tests and gates deployment on successful auth and audit validation.

---

## Demo harness note

The sovereign mock harness is not included in this branch. Use the separate demo branch for `mock-mcp/` proof-of-concept code and end-to-end mock verification.

## 🎯 Target Use Cases
- **AI Hedge Funds:** Ensure every trade is logged for regulatory compliance.
- **Independent Developers:** Prevent "buggy" agent loops from draining your Alpaca account.
- **Enterprise AI:** Maintain a "Human-in-the-Loop" style oversight via automated logs.

---

## Important Notes

- This README describes current behavior of the active config files in this repo.
- If clients call MCP directly (or MCP calls Alpaca directly), those paths will not be represented in both hop logs.
- Error logs are expected to be empty during normal operation and will populate only when proxy/upstream errors occur.

---

*Agent Provost is an open-source project aimed at making autonomous finance safer for everyone. If you find this useful, please **Star** the repository and contribute your safety logic ideas!*
