import os
from typing import Any, Dict

import requests
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

SOVEREIGN_API_URL = os.getenv("SOVEREIGN_API_URL", "http://agent-provost:8081/sovereign")

app = FastAPI(title="Nabatech Sovereign MCP Node")


class JsonRpcRequest(BaseModel):
    jsonrpc: str
    method: str
    id: Any | None = None
    params: Dict[str, Any] | None = None


def check_reserve_liquidity() -> Dict[str, Any]:
    """Check the total supply and status of the Digital Shekel reserve."""
    response = requests.get(f"{SOVEREIGN_API_URL}/reserve_status", timeout=10)
    response.raise_for_status()
    return response.json()


def execute_sovereign_transfer(
    asset: str,
    action: str,
    amount: int,
    destination_wallet: str,
) -> Dict[str, Any]:
    """Execute a transfer of sovereign digital assets. Action must be 'mint' or 'transfer'."""
    response = requests.post(
        f"{SOVEREIGN_API_URL}/sovereign_transfer",
        json={
            "asset": asset,
            "action": action,
            "amount": amount,
            "destination_wallet": destination_wallet,
        },
        timeout=10,
    )
    response.raise_for_status()
    return response.json()


@app.post("/mcp")
def mcp_endpoint(payload: JsonRpcRequest) -> Dict[str, Any]:
    if payload.method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": payload.id,
            "result": {
                "tools": [
                    {
                        "name": "check_reserve_liquidity",
                        "description": "Check the total supply and status of the Digital Shekel reserve.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {},
                            "additionalProperties": False,
                        },
                    },
                    {
                        "name": "execute_sovereign_transfer",
                        "description": "Execute a transfer of sovereign digital assets. Action must be 'mint' or 'transfer'.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "asset": {"type": "string"},
                                "action": {"type": "string"},
                                "amount": {"type": "integer"},
                                "destination_wallet": {"type": "string"},
                            },
                            "required": ["asset", "action", "amount", "destination_wallet"],
                            "additionalProperties": False,
                        },
                    },
                ]
            },
        }

    if payload.method == "tools/call":
        if not payload.params:
            raise HTTPException(status_code=400, detail="params required")
        tool_name = payload.params.get("name")
        arguments = payload.params.get("arguments", {})

        if tool_name == "check_reserve_liquidity":
            result = check_reserve_liquidity()
        elif tool_name == "execute_sovereign_transfer":
            try:
                result = execute_sovereign_transfer(
                    asset=str(arguments["asset"]),
                    action=str(arguments["action"]),
                    amount=int(arguments["amount"]),
                    destination_wallet=str(arguments["destination_wallet"]),
                )
            except KeyError as exc:
                raise HTTPException(status_code=400, detail=f"missing argument: {exc}") from exc
        else:
            raise HTTPException(status_code=404, detail=f"unknown tool: {tool_name}")

        return {"jsonrpc": "2.0", "id": payload.id, "result": result}

    raise HTTPException(status_code=400, detail=f"unsupported method: {payload.method}")
import json
import os
from typing import Any

import requests
from mcp.server.fastmcp import FastMCP

SOVEREIGN_API_URL = os.environ.get("SOVEREIGN_API_URL", "http://localhost:9000").rstrip("/")
REQUEST_TIMEOUT_SECONDS = float(os.environ.get("REQUEST_TIMEOUT_SECONDS", "15"))

mcp = FastMCP(name="Nabatech-Mock-Node")


def _json_text(resp: requests.Response) -> str:
    """Return stable JSON text so logs capture the payload deterministically."""
    return json.dumps(resp.json(), separators=(",", ":"), sort_keys=True)


@mcp.tool()
def get_portfolio_state() -> str:
    resp = requests.get(
        f"{SOVEREIGN_API_URL}/portfolio",
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    resp.raise_for_status()
    return _json_text(resp)


@mcp.tool()
def execute_transaction(ticker: str, action: str, qty: int, price: float) -> str:
    payload: dict[str, Any] = {
        "ticker": ticker,
        "action": action,
        "qty": qty,
        "price": price,
    }
    resp = requests.post(
        f"{SOVEREIGN_API_URL}/transaction",
        json=payload,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    resp.raise_for_status()
    return _json_text(resp)


if __name__ == "__main__":
    # FastMCP host/port are configured through the settings object.
    mcp.settings.host = "0.0.0.0"
    mcp.settings.port = 8088
    mcp.run(transport="streamable-http")
