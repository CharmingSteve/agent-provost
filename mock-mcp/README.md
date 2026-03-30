# Sovereign Mock MCP Harness (Project SHAKED / Nabatech)

This directory contains a sovereign CBDC mock stack with:
- a sovereign ledger API
- a Nabatech-style MCP node
- an Agent Provost policy proxy with full two-hop logging

## Services

- sovereign-api: FastAPI backend for reserve and transfer endpoints
- nabatech-node: MCP-compatible JSON-RPC endpoint exposing sovereign tools
- agent-provost: OpenResty proxy enforcing policy and audit logging

## MCP Endpoint

- POST /mcp
- Transport: JSON-RPC style request bodies

## Tool Catalog (All Options)

### 1) check_reserve_liquidity

Purpose:
- Check the total supply and status of the Digital Shekel reserve.

Arguments:
- none

Behavior:
- Calls GET {SOVEREIGN_API_URL}/reserve_status

Expected result shape:
- asset: string
- total_supply: number
- status: string

Current example result:
- asset: Digital Shekel (ILS-D)
- total_supply: 50000000.0
- status: active

JSON-RPC tool call payload:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "check_reserve_liquidity",
    "arguments": {}
  }
}
```

### 2) execute_sovereign_transfer

Purpose:
- Execute a transfer of sovereign digital assets. Action must be mint or transfer.

Arguments:
- asset: string
- action: string
- amount: integer
- destination_wallet: string

Behavior:
- Calls POST {SOVEREIGN_API_URL}/sovereign_transfer with JSON payload

Current backend response shape:
- status: settled
- transaction_id: TXN-9982
- amount_transferred: integer

JSON-RPC tool call payload:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "execute_sovereign_transfer",
    "arguments": {
      "asset": "Digital Shekel (ILS-D)",
      "action": "transfer",
      "amount": 250000,
      "destination_wallet": "BOI-CLEARING-002"
    }
  }
}
```

## Sovereign Policy Rules (Hop 1)

The proxy blocks execute_sovereign_transfer when either condition is true:
- action equals mint
- amount is greater than 1000000

Blocked response:
- HTTP status: 403
- error: PROVOST_INTERVENTION: Sovereign Policy Violation. Unauthorized Minting or Amount Exceeds Reserve Limits.

Policy examples:
- transfer amount 1000000: allowed
- transfer amount 1000001: blocked
- mint amount 1: blocked

## Backend API Endpoints

### GET /reserve_status

Response:

```json
{
  "asset": "Digital Shekel (ILS-D)",
  "total_supply": 50000000.0,
  "status": "active"
}
```

### POST /sovereign_transfer

Request body:

```json
{
  "asset": "Digital Shekel (ILS-D)",
  "action": "transfer",
  "amount": 250000,
  "destination_wallet": "BOI-CLEARING-002"
}
```

Response body:

```json
{
  "status": "settled",
  "transaction_id": "TXN-9982",
  "amount_transferred": 250000
}
```

## Tool Discovery

You can discover available tools via tools/list:

```json
{
  "jsonrpc": "2.0",
  "id": 99,
  "method": "tools/list"
}
```

Expected tools list:
- check_reserve_liquidity
- execute_sovereign_transfer

## Natural Language Prompt Examples

Allowed prompts:
- Check reserve liquidity.
- Show current Digital Shekel reserve status.
- Transfer 250000 Digital Shekel to BOI-CLEARING-002.
- Transfer exactly 1000000 Digital Shekel to GOV-DISBURSE-01.

Blocked prompts:
- Mint 500 Digital Shekel to BOI-TREASURY-001.
- Transfer 1000001 Digital Shekel to BOI-CLEARING-002.

## Audit Logs

Hop 1 logs:
- nginx-logs/llm_to_mcp_access.log
- nginx-logs/llm_to_mcp_error.log

Hop 2 logs:
- nginx-logs/mcp_to_api_access.log
- nginx-logs/mcp_to_api_error.log

Each access log captures:
- request body
- response body
- status
- timing metadata

## Run and Test

Start:

```bash
docker compose up -d --build
```

Run shell integration tests:

```bash
bats tests/shell/test_mock_harness.bats
```

Run Lua unit tests:

```bash
busted tests/lua/mock_circuit_breaker_spec.lua
```
