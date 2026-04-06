# Agent Provost: The Safety Firewall & Audit Ledger for Autonomous AI Trading

**Agent Provost** is a high-performance, mandatory MITM (Man-in-the-Middle) boundary designed specifically for **AI trading flows** and **Autonomous Agents**. By placing an OpenResty (Nginx + Lua) proxy between your LLM client, your **Model Context Protocol (MCP) server**, and the **Alpaca Trading API**, it ensures every single trade is observable, audited, and safety-checked.

Stop your AI agent from going rogue with programmable risk guardrails and a tamper-proof audit trail.

---

## 🚀 Key Features for AI Safety & Compliance

*   **Programmable Circuit Breaker (Risk Kill-Switch):** Built-in Lua logic that intercepts and blocks high-risk orders. (Default: Blocks any trade quantity > 100).
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

- `llm_to_alpaca_access.log`: steps 1 and 4
- `mcp_to_alpaca_access.log`: steps 2 and 3

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
| `blocked_tickers` | **enabled**, list = GME/AMC/BBBY | Blocks trades on restricted ticker symbols |
| `trading_window` | disabled | Placeholder: restrict trading to specific UTC hours |

All blocked requests return `403 Forbidden` with a `PROVOST_INTERVENTION` JSON error body.

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
- `request_body` (The actual JSON sent by the AI)
- `resp_body` (The actual JSON returned by the API)

---

## 🛠️ Quick Start & Verification

### 1. Requirements
- Docker and Docker Compose
- Alpaca API Keys (Paper or Live) in a `.env` file

### 2. Run the Compliance Check
Run the built-in verification script to spin up the stack, execute a test trade, and verify the logs:

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

Log side effects are intentional. If you need to preserve existing logs, copy them out before running the script.

### 3. Manual Startup
```bash
docker compose up -d --build
```

Point your MCP clients to: `http://localhost:8088/mcp`

---

## 🧪 Mock Sovereign MCP Harness (Local, Deterministic)

This repo also includes a deterministic mock harness under `mock-mcp/` for proving the full four-step audit trail without calling external Alpaca endpoints.

What the mock stack does:

- `sovereign-api` (FastAPI): simple backend ledger with:
   - `GET /portfolio`
   - `POST /transaction`
- `mock-mcp` (FastMCP): exposes tools:
   - `get_portfolio_state`
   - `execute_transaction`
- `agent-provost` (OpenResty): same two-hop MITM idea:
   - hop 1: LLM -> MCP (`llm_to_mcp_*` logs)
   - hop 2: MCP -> API (`mcp_to_api_*` logs)

Policy behavior on hop 1 (mock config):

- blocks `execute_transaction` when `qty > 100`
- blocks `execute_transaction` when `ticker == "GME"`
- returns `403` with a policy error body

### Start the Mock Stack

```bash
cd agent-provost/mock-mcp
docker compose up -d --build
```

### Run End-to-End Verification

```bash
cd agent-provost/mock-mcp
./verify_mock_proxy_routing.sh
```

This script:

1. boots/recreates the mock stack
2. sends initialize + tools calls through hop 1
3. executes one allowed transaction and two blocked transactions
4. validates that request and response bodies are present in both hop access logs
5. checks that both error logs exist

### Run Natural-Language-Style Tool Requests

The helper script maps NL prompts to MCP tool calls and runs them through the proxy:

```bash
cd agent-provost/mock-mcp
docker cp run_nl_queries.py mock-mcp:/tmp/run_nl_queries.py
docker compose exec -T mock-mcp python /tmp/run_nl_queries.py
```

Example prompts used by the helper:

- "Show my current portfolio state."
- "Buy 7 shares of AAPL at 120.25."
- "Buy 1 share of GME at 25.0." (expected `403` block)

### Which Log Files to Inspect

Use bounded tails to avoid large reads:

```bash
cd agent-provost/mock-mcp
tail -n 6 nginx-logs/llm_to_mcp_access.log
tail -n 6 nginx-logs/mcp_to_api_access.log
tail -n 2 nginx-logs/llm_to_mcp_error.log
tail -n 2 nginx-logs/mcp_to_api_error.log
```

Interpretation:

- `llm_to_mcp_access.log`: LLM intent and MCP response
   - contains JSON-RPC `request_body`
   - contains MCP/event-stream or error `resp_body`
- `mcp_to_api_access.log`: MCP outbound payload and API response
   - contains backend `request_body`
   - contains backend `resp_body`
- `*_error.log`: operational proxy errors/info for each hop

---

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
