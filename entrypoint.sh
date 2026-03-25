#!/bin/sh
set -e

echo "[entrypoint] Patching TRADE_API_URL support into server.py..."
SITE_PACKAGES=$(python -c "import site; print(site.getsitepackages()[0])")
SERVER_PY="$SITE_PACKAGES/alpaca_mcp_server/server.py"

python - "$SERVER_PY" <<'PYEOF'
import re
import sys
path = sys.argv[1]
src = open(path).read()
pattern = r"def _get_trading_base_url\(\) -> str:\n(?:    .*\n){1,6}"
new_block = (
    "def _get_trading_base_url() -> str:\n"
    "    forced = os.environ.get(\"TRADE_API_URL\")\n"
    "    if forced:\n"
    "        return forced.rstrip(\"/\")\n"
    "    paper = os.environ.get(\"ALPACA_PAPER_TRADE\", \"true\").lower() in (\"true\", \"1\", \"yes\")\n"
    "    return TRADING_API_BASE_URLS[\"paper\" if paper else \"live\"]\n"
)
patched, count = re.subn(pattern, new_block, src, count=1)
if count == 1:
    open(path, "w").write(patched)
    print("[patch] TRADE_API_URL override patch applied.")
else:
    print("[patch] Trading base URL function not found — skipping.")
PYEOF

echo "[entrypoint] Starting MCP Server with streamable-http transport..."
exec alpaca-mcp-server --transport streamable-http --host 0.0.0.0 --port 8088

