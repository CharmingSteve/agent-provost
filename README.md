# Agent Provost: The Safety Firewall & Audit Ledger for Autonomous AI Trading

<p align="center">
   <img src="agent-provost-1-Copilot_20260526_195647.png" alt="Agent Provost lock-eye emblem" width="360" />
</p>

> Agent Provost: gaurdrails for AI trading

**Agent Provost** is a high-performance, mandatory MITM (Man-in-the-Middle) boundary designed specifically for **AI trading flows** and **Autonomous Agents**. By placing an OpenResty (Nginx + Lua) proxy between your LLM client, your **Model Context Protocol (MCP) server**, and the **Alpaca Trading API**, it ensures every single trade is observable, audited, and safety-checked.

Stop your AI agent from going rogue with programmable risk guardrails and a tamper-proof audit trail.

---

## Quickstart (TLDR)

Clone and run locally (dev):
Have the following set in a local .env file in the root dir of the repo
ALPACA_API_KEY=YOUR-ALPACA-KEY
ALPACA_SECRET_KEY=YOUR-ALPACA-SECRET-KEY
ALPACA_PAPER_TRADE=True #just paper alpaca sandbox
PROVOST_TOKEN=THIS-TOKEN_YOU-ranDomLy-create-locally # needs to also be in your mcp.json

```sh
git clone https://github.com/CharmingSteve/agent-provost.git
cd agent-provost
# ensure any previous staging is cleared
unset PROVOST_SECRETS_DIR
docker compose down
eval "$(sh bootstrap.sh dev)"
docker compose --env-file .env.versions up -d
# verify the staged token inside the running container
docker exec agent-provost cat /run/secrets/provost_token
```


## 🚀 Key Features for AI Safety & Compliance

*   **Programmable Circuit Breaker (Risk Kill-Switch):** Built-in Lua logic that intercepts and blocks high-risk orders. (Default: Blocks any trade quantity > 100).
*   **Upstream Rate-Limit Guardrails:** Automatically blocks new inbound requests for 60 seconds after an upstream `429`, and preemptively blocks when upstream `RateLimit-Remaining` is below threshold.
*   **Two-Hop Observability:** Full visibility into both the LLM-to-MCP and MCP-to-Alpaca communication channels.
*   **Zero-Trust Audit Ledger:** Every request and response body is captured in structured JSON logs for forensic analysis and compliance.
*   **Runtime Source Patching:** Unique `entrypoint.sh` technology that hot-patches the `alpaca-mcp-server` at runtime to support proxy routing without needing a custom fork.
*   **Dockerized Deployment:** Spin up a fully compliant, two-hop trading environment in seconds with Docker Compose.

---

## 🏗️ Architecture: The Two-Hop Flow

To guarantee full traceability, Agent Provost monitors two distinct boundaries:

1.  **llm-to-mcp (Inbound):** `LLM Client` -> `Agent Provost (Port 8000)` -> `MCP Server`
2.  **mcp-to-api (Outbound):** `MCP Server` -> `Agent Provost (Port 8081)` -> `Alpaca APIs`

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

How they map in the Fluent Bit pipeline (`stream_tag`):

- `provost_llm_to_mcp_access`: step 1 (LLM -> MCP) and step 4 (MCP -> LLM)
- `provost_mcp_to_api_access`: step 2 (MCP -> Alpaca) and step 3 (Alpaca -> MCP)

Error stream tags:

- `provost_mcp_to_llm_error`: request-path errors on the llm-to-mcp boundary
- `provost_api_to_mcp_error`: request-path errors on the mcp-to-api boundary
- `provost_nginx_error`: OpenResty worker/runtime errors (not request-scoped)

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

### Updating Your Trading Rules (Guardrails) via AWS Console

Agent Provost enforces strict risk management rules. You set these rules when you first deployed the stack, but you can update them at any time directly through the AWS Console.

Because Agent Provost is completely stateless, updating these rules will safely replace your EC2 instance with a new one containing the updated guardrails — without losing any state.

**Available Rules to Update:**

| Parameter | Description |
| --- | --- |
| `MaxTradeNotional` | The maximum dollar amount allowed for a single trade. |
| `DailyNotionalLimit` | The total dollar amount the AI is allowed to trade per day. |
| `BlockedTickers` | A comma-separated list of symbols the AI is forbidden from trading (e.g., `GME,AMC,DJT`). |
| `AllowedAssetClasses` | The types of assets the AI can trade (e.g., `us_equity,crypto`). |

**How to Update:**
1. Go to the **AWS CloudFormation Console**.
2. Select your Agent Provost stack and click **Update**.
3. Select **Use current template** and click **Next**.
4. Modify the rule parameters to your new desired limits.
5. Click **Next** through the remaining screens and click **Submit**.

AWS will automatically provision a new instance with your updated `rules.json` and seamlessly swap it out.

> 💬 **Need a custom rule set tailored to your firm's specific risk policy?** We build bespoke guardrail configurations for institutional clients. [Open an issue](https://github.com/CharmingSteve/agent-provost/issues) or start a [Discussion](https://github.com/CharmingSteve/agent-provost/discussions) to request a custom rule set.

### Upgrading the Agent Provost Stack

If you need to deploy a hotfix, update to a new version, or switch to a custom customer branch, you can use the built-in upgrade script. This script safely backs up your current configuration and Docker images before pulling the new code.

To run the upgrade on your EC2 instance, you must execute it as the `provost` user:

```bash
# 1. Switch to the provost service account
sudo -i

# 2. Navigate to the installation directory
cd /opt/agent-provost

# 3. Run the upgrade script (replace 'main' with your target branch if needed)
./scripts/provost-upgrade.sh <NEW-BRANCH-NAME>
```

The script will automatically stash local changes, fetch the new branch, pull the latest pinned Docker images, and restart the stack with zero downtime. If the upgrade fails, the script output provides a one-line command to restore your previous Docker images from the `backups/` directory.

### 💡 We Need Your Ideas!
We are expanding the safety suite. What other controls should we add?
- [ ] Price-based slippage protection?
- [ ] Daily Notional Value (DNV) caps?
- [ ] Restricted ticker "Blacklists"?
- [ ] Time-of-day trading windows?

**[Suggest a new safety control in the Issues section!](https://github.com/CharmingSteve/agent-provost/issues)**

---

## 📊 The Ultimate Audit Ledger

Logs are streamed from OpenResty over a Unix socket to Fluent Bit, buffered on disk, and written to S3.

Primary audit sink:

- `s3://$S3_BUCKET/agent-provost/logs/%Y/%m/%d/%H/$UUID.json`

Date/hour partitions follow the container local timezone (`TZ`). If `TZ=UTC`, partitions are UTC.

Local durability buffer:

- `./logs/fluent-bit-storage` (host)
- `/var/log/fluent-bit/storage` (container)

Each OpenResty access log entry (from `json_full`) captures:
- `time_local` & `remote_addr`
- `request` (Method/Path)
- `status` ("200", "403", etc.)
- `body_bytes_sent`, `request_time`, `upstream_response_time`
- `provost_request_id` (the correlation id shared across hops)
- `provost_user` (the human/client identity from the MCP request headers)
- `provost_machine` (the client machine identity from the MCP request headers)
- `request_body` (The actual JSON sent by the AI)
- `resp_body` (The actual JSON returned by the API)

Fluent Bit then parses/enriches and writes records to S3, including:
- `stream_tag` (`provost_llm_to_mcp_access`, `provost_mcp_to_api_access`, and error tags)
- `log_type` (`access` or `error`)
- `Region`
- `Instance_ID`

`provost_request_id` is created on the llm-to-mcp boundary when the inbound request is validated. If the client already supplied `X-Provost-Request-Id`, the proxy reuses it; otherwise it generates one from `request_id` or a timestamp-random fallback, stores the identity context in shared memory, and forwards the same id downstream so the mcp-to-api boundary can recover and log the same correlation id.

### Log Schema Source of Truth and CI Validation

The log payload shape is defined at emission time in two places:

- Access log JSON fields are defined in `json_full` in [default.conf](default.conf).
- Error/audit JSON fields are defined by the ordered field list in [lua/audit_error.lua](lua/audit_error.lua).

Schema validation is executed in GitHub Actions from [.github/workflows/ci.yml](.github/workflows/ci.yml), inside the `integration-tests` job in the step named `Generate Error Log, Download from S3, and Validate Schema`.

Current CI access-log validation loop:

```bash
               ACCESS_LOGS=$(find downloaded-logs -type f -path "*/access/*")
               if [ -z "$ACCESS_LOGS" ]; then
                  echo "❌ ERROR: No access logs found in S3!"
                  exit 1
               fi
               for file in $ACCESS_LOGS; do
                  echo "Checking $file..."
                  python /tmp/validate_jsonl.py schemas/access_log_schema.json "$file"
               done
```

Current CI error-log validation loop:

```bash
               ERROR_LOGS=$(find downloaded-logs -type f -path "*/error/*")
               if [ -z "$ERROR_LOGS" ]; then
                  echo "⚠️  No error logs found in S3; continuing because the access-log schema check is the gate for this run."
               else
                  for file in $ERROR_LOGS; do
                     echo "Checking $file..."
                     python /tmp/validate_jsonl.py schemas/error_log_schema.json "$file"
                  done
               fi
```

How it works:

1. CI creates `/tmp/validate_jsonl.py` in that step and uses Python `jsonschema` (`Draft7Validator`) as the validation engine.
2. Each log line is parsed as a JSON object and validated against the strict schemas in `schemas/access_log_schema.json` and `schemas/error_log_schema.json`.
3. If any line contains an unexpected field (for example, a canary field like `test_rogue_field` when not in schema), the step fails with a schema validation error.

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

1. Recreates the entire compose stack (`docker compose --env-file .env.versions up -d --force-recreate`)
2. Waits for Fluent Bit health and verifies socket mount availability
3. Runs initialize + get_account_info through localhost:8088/mcp with a unique correlation marker
4. Fails unless:
   - Fluent Bit socket is present
   - Audit evidence is found in S3 (or in local durable buffer when S3 validation is disabled)

After verification, inspect recent S3 objects under `agent-provost/logs/` and confirm entries contain expected identity and correlation fields.

### 3. Manual Startup
Before starting the stack locally, stage secrets from `.env`:

If you have stale bootstrap environment from a previous run, unset both runtime exports first:

```sh
unset PROVOST_SECRETS_DIR
unset PROVOST_RUN_DIR
```

```bash
eval "$(sh bootstrap.sh dev)"
docker compose --env-file .env.versions up -d --build
```

`bootstrap.sh dev` stages `.env` secrets into a temporary directory and exports `PROVOST_SECRETS_DIR`; `docker compose` then mounts that directory into `/run/secrets` in both containers. If you change `.env`, restart the bootstrap step and recreate the compose stack so the mounted `provost_token` still matches your MCP client configuration.

For Fluent Bit audit streaming in local dev, configure these `.env` keys:

- `AWS_REGION`
- `S3_BUCKET`
- optional `AWS_ACCESS_KEY_ID`
- optional `AWS_SECRET_ACCESS_KEY`
- optional `AWS_SESSION_TOKEN`

Point your MCP clients to: `http://localhost:8088/mcp`

Required client headers for llm-to-mcp auth:

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

## ⚖️ Regulatory Compliance Alignment

Agent Provost is designed to support compliance with financial AI governance regulations across major jurisdictions. The immutable audit trail, structured JSON logs, kill-switch controls, and traceable agent actions are specifically architected to align with the following frameworks:

| Region | Regulation | Alignment Summary |
| --- | --- | --- |
| 🇺🇸 USA | **SEC Advisers Act Rule 204‑2** | Supports required retention of investment‑decision records through immutable audit logs, traceable agent actions, and documented decision pathways. |
| 🇺🇸 USA | **FINRA 3110 / 4511** | Provides supervisory oversight features and optional S3 Object Lock for tamper‑proof retention consistent with books‑and‑records expectations. |
| 🇪🇺 EU | **EU AI Act (High‑Risk AI Requirements)** | Delivers mandatory logging, traceability, human‑override controls, and operational safeguards such as kill‑switch and agent registration. |
| 🇬🇧 UK | **FCA AI Governance Principles** | Aligns with expectations for auditability, operational resilience, and governance of automated decision systems. |
| 🇸🇬 Singapore | **MAS FEAT Principles** | Enables transparency, accountability, and human oversight through structured logging and agent‑level control mechanisms. |
| 🇨🇦 Canada | **OSFI AI Risk Management** | Supports governance, monitoring, and audit‑trail requirements for AI systems used in financial decision processes. |
| 🌐 Global | **ISO 42001 (AI Management) / ISO 27001 (Security)** | Provides foundational controls for AI governance, security, and traceability consistent with international standards. |

> **Note:** This alignment summary describes architectural intent and does not constitute legal or compliance advice. Consult your compliance officer to validate applicability to your specific regulatory context.

---

## 📜 License and Legal Notices

- Open-source repository license: [AGPL-3.0](LICENSE)
- Commercial AWS Marketplace license terms: [legal/EULA.md](legal/EULA.md)
- Third-party attributions and notices: [legal/THIRD-PARTY-NOTICES.txt](legal/THIRD-PARTY-NOTICES.txt)

For AWS Marketplace deployments, review the commercial terms in the EULA. For source-code licensing and redistribution obligations in this repository, follow AGPL-3.0.

---

## Important Notes

- This README describes current behavior of the active config files in this repo.
- If clients call MCP directly (or MCP calls Alpaca directly), those paths will not be represented in both hop logs.
- Error logs are expected to be empty during normal operation and will populate only when proxy/upstream errors occur.

## Security Decision Record

- Decision: keep `alpaca-mcp` writable temporarily; keep `fluent-bit` and `agent-provost` read-only.
- Why writable is required: `entrypoint.sh` applies a runtime patch to `alpaca_mcp_server/server.py` so `TRADE_API_URL` override routing is enforced.
- Compensating controls: non-root users, `no-new-privileges`, dropped Linux capabilities, tmpfs for `/tmp`, pinned images/dependencies, and CI security scans (Trivy/Checkov/pip-audit/gitleaks).
- Owner: Steve (repo owner).
- Deadline to remove exception: migrate patching to Docker build stage by `v0.3.0` (target date: 2026-05-31), then set `alpaca-mcp` to read-only.

---

## ☁️ AWS CloudFormation Deployment

### Stack Name Length Limit

> ⚠️ **The CloudFormation Stack Name must be 25 characters or less.**

Although AWS CloudFormation allows stack names up to 128 characters, Agent Provost enforces a stricter limit of **25 characters**. This is because the stack name is appended directly to the S3 audit log bucket name, which is constructed as:

```
ap-logs-${AWS::AccountId}-${AWS::Region}-${AWS::StackName}
```

S3 bucket names are limited to 63 characters by AWS. With the fixed prefix (`ap-logs-`), your Account ID (12 digits), your Region (e.g., `us-east-1`), and the separating dashes, the remaining space for your stack name is **25 characters**.

**Examples of valid stack names:**
- `provost-prod`
- `my-trading-agent`
- `acme-provost-live`

**Examples of invalid stack names (too long):**
- `my-company-agent-provost-production-stack` ❌

---

### S3 Audit Log Immutability Options

The CloudFormation template now supports three S3 Object Lock modes for audit log retention:

- **NoLock**: No immutability. Audit logs can be deleted or altered by any IAM principal with S3 permissions. Use for development or test environments where regulatory retention is not required.
- **GOVERNANCE**: Objects are WORM-locked (Write Once, Read Many), but privileged users (admins) can bypass retention and delete or alter objects if needed. Suitable for internal controls or environments where admin override is acceptable.
- **COMPLIANCE**: Objects are WORM-locked and cannot be deleted or altered by anyone—including root/admins—until the retention period expires. Required for strict regulatory compliance (e.g., SEC Advisers Act Rule 204-2, FINRA 3110/4511, 17a-4, CFTC, etc.).

**Retention Period**: The `ObjectLockRetentionDays` parameter sets the number of days objects are locked. This is only enforced when `ObjectLockMode` is set to `GOVERNANCE` or `COMPLIANCE`.

**Regulatory context:**
- Use **COMPLIANCE** mode for SEC/FINRA/17a-4 or similar requirements for tamper-proof, non-bypassable retention.
- Use **GOVERNANCE** for internal audit or operational controls where admin override is acceptable.
- Use **NoLock** for dev/test or where immutability is not required.

> **Note:** Changing the lock mode only affects new objects written after the change. Existing objects retain their original lock mode unless explicitly updated.

---

## AWS CloudTrail and CloudWatch — Deployment Security Note

When you deploy Agent Provost using the CloudFormation template, you supply your Alpaca API key, Alpaca secret key, and Provost token as stack parameters. Those parameters are marked `NoEcho: true`, which prevents them from being displayed in the CloudFormation console and most AWS tooling surfaces.

However, `NoEcho` is not a complete guarantee that the values are invisible to all AWS logging paths:

- **CloudTrail management events** — if your account has CloudTrail enabled with broad management-event capture, the `CreateStack` / `UpdateStack` API calls can appear in trail logs. AWS does redact `NoEcho` parameter values from CloudTrail records in most regions and configurations, but this is an AWS behaviour you should verify for your own account and organisational policies.
- **CloudFormation resource creation** — the template constructs a Secrets Manager secret directly from the parameter values at stack-creation time. That means the plaintext values briefly exist inside the CloudFormation service's processing layer before being written to Secrets Manager.
- **CloudWatch Logs (EC2 startup)** — if you or your customers have CloudWatch Logs agents collecting `/var/log/cloud-init-output.log` or journal output, and the instance bootstrap script ever echoes variable content to stdout or stderr, those values could land in a log stream. The current `bootstrap.sh` does **not** print secret values, but you should confirm this for your specific AMI and any custom UserData you add.


**Get in touch** — if you are evaluating Agent Provost for a regulated environment and have questions about this tradeoff, the deployment model, or custom hardening for your org, I am happy to help. Open a GitHub Issue or start a Discussion in this repository and I will respond directly.

---

*Agent Provost is an open-source project aimed at making autonomous finance safer for everyone. If you find this useful, please **Star** the repository and contribute your safety logic ideas!*

Temporary validation line for version bump workflow.
