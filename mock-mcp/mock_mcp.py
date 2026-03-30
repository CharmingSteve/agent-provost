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
