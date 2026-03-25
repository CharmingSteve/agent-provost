#!/bin/sh
# Stable entrypoint for alpaca-mcp container.
# Pinned version + TRADE_API_URL patch + streamable-http transport.

set -e

# ── 1. Install pinned version ────────────────────────────────────────────────
echo "[entrypoint] Installing alpaca-mcp-server==2.0.0 ..."
pip install --no-cache-dir "alpaca-mcp-server==2.0.0"

# ── 2. Patch _get_trading_base_url to honour TRADE_API_URL env var ───────────
# v2 natively reads DATA_API_URL, but NOT TRADE_API_URL.
# This patch adds the override without touching anything else.
echo "[entrypoint] Applying TRADE_API_URL patch ..."
python3 - <<'PATCHEOF'
import pathlib

p = pathlib.Path('/usr/local/lib/python3.11/site-packages/alpaca_mcp_server/server.py')
src = p.read_text()

if 'TRADE_API_URL' not in src:
    injection = (
        '    trade_url = os.environ.get("TRADE_API_URL", "").rstrip("/")\n'
        '    if trade_url:\n'
        '        return trade_url\n'
    )
    src = src.replace(
        'def _get_trading_base_url() -> str:\n',
        'def _get_trading_base_url() -> str:\n' + injection,
    )
    p.write_text(src)
    print("[entrypoint] Patch applied: TRADE_API_URL override added.")
else:
    print("[entrypoint] Patch already present, skipping.")
PATCHEOF

# ── 3. Start with streamable-http transport (/mcp endpoint) ─────────────────
echo "[entrypoint] Starting alpaca-mcp-server (streamable-http, port 8088) ..."
exec alpaca-mcp-server --transport streamable-http --host 0.0.0.0 --port 8088
