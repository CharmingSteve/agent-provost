import json
import requests

url = "http://agent-provost:8000/mcp"
sid = None


def parse_payload(text: str):
    data_lines = [ln.split(":", 1)[1].strip() for ln in text.splitlines() if ln.startswith("data:")]
    if data_lines:
        joined = "\n".join(data_lines)
        try:
            return json.loads(joined)
        except Exception:
            return {"raw": joined}
    try:
        return json.loads(text)
    except Exception:
        return {"raw": text}


def call(sess: requests.Session, rid: int | None, method: str, params=None):
    global sid
    headers = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
    if sid:
        headers["mcp-session-id"] = sid
    payload = {"jsonrpc": "2.0", "method": method}
    if rid is not None:
        payload["id"] = rid
    if params is not None:
        payload["params"] = params
    resp = sess.post(url, headers=headers, json=payload, timeout=30)
    if resp.headers.get("mcp-session-id"):
        sid = resp.headers["mcp-session-id"]
    return resp.status_code, parse_payload(resp.text)


nl_query = "Sell 3 shares of MSFT at 101.5."
arguments = {"ticker": "MSFT", "action": "sell", "qty": 3, "price": 101.5}

with requests.Session() as session:
    init_status, _ = call(
        session,
        1,
        "initialize",
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "one-query", "version": "1.0"},
        },
    )
    call(session, None, "notifications/initialized", {})

    status, payload = call(
        session,
        2,
        "tools/call",
        {"name": "execute_transaction", "arguments": arguments},
    )

    print("NL_QUERY:", nl_query)
    print("TOOL:", "execute_transaction")
    print("INIT_STATUS:", init_status)
    print("CALL_STATUS:", status)
    print("PAYLOAD_SNIPPET:", json.dumps(payload)[:320])
