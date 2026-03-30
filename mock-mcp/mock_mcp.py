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
