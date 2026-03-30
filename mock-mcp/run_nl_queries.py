import json
import requests

URL = "http://agent-provost:8000/mcp"
SID = None


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
    global SID
    headers = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
    if SID:
        headers["mcp-session-id"] = SID

    payload = {"jsonrpc": "2.0", "method": method}
    if rid is not None:
        payload["id"] = rid
    if params is not None:
        payload["params"] = params

    resp = sess.post(URL, headers=headers, json=payload, timeout=30)
    if resp.headers.get("mcp-session-id"):
        SID = resp.headers["mcp-session-id"]
    return resp.status_code, parse_payload(resp.text)


queries = [
    ("Show my current portfolio state.", "get_portfolio_state", {}),
    (
        "Buy 7 shares of AAPL at 120.25.",
        "execute_transaction",
        {"ticker": "AAPL", "action": "buy", "qty": 7, "price": 120.25},
    ),
    (
        "Buy 1 share of GME at 25.0.",
        "execute_transaction",
        {"ticker": "GME", "action": "buy", "qty": 1, "price": 25.0},
    ),
]

with requests.Session() as session:
    init_code, _ = call(
        session,
        1,
        "initialize",
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "nl-runner", "version": "1.0"},
        },
    )
    print("initialize_status:", init_code)
    call(session, None, "notifications/initialized", {})

    for i, (nl_query, tool_name, args) in enumerate(queries, start=2):
        code, response = call(
            session,
            i,
            "tools/call",
            {"name": tool_name, "arguments": args},
        )
        print("\nNL_QUERY:", nl_query)
        print("TOOL:", tool_name)
        print("STATUS:", code)
        if isinstance(response, dict):
            print("RESPONSE_KEYS:", list(response.keys()))
            print("RESPONSE_SNIPPET:", json.dumps(response)[:280])
        else:
            print("RESPONSE_RAW:", str(response)[:280])
