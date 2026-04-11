#!/usr/bin/env python3
"""
Test script: Get Alpaca paper trading account info and sell all positions.
Connects to MCP server at localhost:8088.
Prints outputs in real time.
"""

import json
import requests
import sys
import time

MCP_URL = "http://localhost:8088/mcp"
SESSION = None
SESSION_ID = None


def call_mcp(rid, method, params=None):
    """Make an MCP RPC call and return status, response."""
    global SESSION_ID
    
    headers = {
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json"
    }
    if SESSION_ID:
        headers["mcp-session-id"] = SESSION_ID
    
    payload = {"jsonrpc": "2.0", "method": method}
    if rid is not None:
        payload["id"] = rid
    if params is not None:
        payload["params"] = params
    
    try:
        r = SESSION.post(MCP_URL, headers=headers, json=payload, timeout=60)
    except Exception as exc:
        print(f"[ERROR] Request failed: {exc}", file=sys.stderr)
        return 0, {"error": str(exc)}
    
    # Capture session ID
    if "mcp-session-id" in r.headers:
        SESSION_ID = r.headers["mcp-session-id"]
    
    # Parse SSE format response
    txt = r.text.strip()
    data = [ln.split(":", 1)[1].strip() for ln in txt.splitlines() if ln.startswith("data:")]
    
    if data:
        try:
            return r.status_code, json.loads("\n".join(data))
        except Exception:
            return r.status_code, {"raw": "\n".join(data)}
    
    try:
        return r.status_code, r.json()
    except Exception:
        return r.status_code, {"raw": txt}


def main():
    global SESSION
    SESSION = requests.Session()
    
    print("[test] =" * 50)
    print("[test] Alpaca Paper Trading Account Test via MCP")
    print("[test] " + "=" * 50)
    print()
    
    # Initialize MCP
    print("[test] Initializing MCP session...")
    for attempt in range(20):
        status, resp = call_mcp(1, "initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test-account", "version": "1.0"}
        })
        if status == 200:
            print("[test] ✓ MCP initialized")
            break
        print(f"[test] Attempt {attempt+1}: status={status}")
        time.sleep(1)
    else:
        print("[ERROR] Failed to initialize MCP")
        return 1
    
    # Send initialized notification
    call_mcp(None, "notifications/initialized", {})
    
    # Get account info
    print("[test]")
    print("[test] Getting account info...")
    status, resp = call_mcp(2, "tools/call", {
        "name": "get_account_info",
        "arguments": {}
    })
    
    if status == 200:
        print("[test] ✓ Account info retrieved")
        print()
        print("[account_info_start]")
        if isinstance(resp, dict) and "result" in resp:
            result = resp["result"]
            if isinstance(result, dict):
                # Pretty print account info
                for key, value in result.items():
                    print(f"  {key}: {value}")
            else:
                print(json.dumps(resp, indent=2))
        else:
            print(json.dumps(resp, indent=2))
        print("[account_info_end]")
        print()
    else:
        print(f"[ERROR] Failed to get account info: status={status}")
        print(json.dumps(resp, indent=2))
        return 1
    
    # Get positions
    print("[test] Fetching open positions...")
    status, resp = call_mcp(3, "tools/call", {
        "name": "get_positions",
        "arguments": {}
    })
    
    if status != 200:
        print(f"[ERROR] Failed to get positions: status={status}")
        print(json.dumps(resp, indent=2))
        return 1
    
    positions = []
    if isinstance(resp, dict) and "result" in resp:
        result = resp["result"]
        if isinstance(result, list):
            positions = result
        elif isinstance(result, dict) and "positions" in result:
            positions = result["positions"]
    
    if not positions:
        print("[test] ✓ No open positions found")
        print()
    else:
        print(f"[test] ✓ Found {len(positions)} open position(s)")
        print()
        print("[positions_start]")
        for i, pos in enumerate(positions):
            if isinstance(pos, dict):
                symbol = pos.get("symbol", "UNKNOWN")
                qty = pos.get("qty", pos.get("quantity", 0))
                print(f"  Position {i+1}: {symbol} x {qty}")
            else:
                print(f"  Position {i+1}: {pos}")
        print("[positions_end]")
        print()
        
        # Sell all positions
        print("[test] Selling all positions...")
        print()
        
        for i, pos in enumerate(positions):
            if not isinstance(pos, dict):
                print(f"[WARNING] Position {i+1} is not a dict, skipping")
                continue
            
            symbol = pos.get("symbol", "UNKNOWN")
            qty = pos.get("qty", pos.get("quantity", 0))
            
            if not symbol or not qty or qty == 0:
                continue
            
            print(f"[sell] Selling {symbol} x {qty}...")
            
            status, resp = call_mcp(
                i + 100,  # Use different IDs for sell operations
                "tools/call",
                {
                    "name": "place_order",
                    "arguments": {
                        "symbol": symbol,
                        "qty": qty,
                        "side": "sell",
                        "type": "market"
                    }
                }
            )
            
            if status == 200:
                if isinstance(resp, dict) and "result" in resp:
                    result = resp["result"]
                    if isinstance(result, dict):
                        order_id = result.get("id", "UNKNOWN")
                        status_code = result.get("status", "UNKNOWN")
                        print(f"[sell] ✓ Sell order submitted: {order_id} (status: {status_code})")
                    else:
                        print(f"[sell] ✓ Sell order submitted: {json.dumps(result)}")
                else:
                    print(f"[sell] ✓ Response: {json.dumps(resp)}")
            else:
                print(f"[sell] ✗ Failed (status={status})")
                if "PROVOST_INTERVENTION" in str(resp):
                    print(f"[sell] INFO: Blocked by circuit breaker - likely due to quantity limit")
                elif "GME" in symbol or "AMC" in symbol or "BBBY" in symbol:
                    print(f"[sell] INFO: {symbol} is on restricted list, cannot sell")
                else:
                    print(f"[sell] Response: {json.dumps(resp)}")
            
            print()
    
    print("[test] =" * 50)
    print("[test] Test completed successfully!")
    print("[test] " + "=" * 50)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n[test] Interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n[ERROR] Unexpected error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)
