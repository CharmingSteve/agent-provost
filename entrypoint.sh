#!/bin/sh
set -e

# Load secrets from mounted files (set by bootstrap or docker compose)
if [ -f /run/secrets/alpaca_api_key ]; then
  ALPACA_API_KEY="$(cat /run/secrets/alpaca_api_key)"
  export ALPACA_API_KEY
fi
if [ -f /run/secrets/alpaca_secret_key ]; then
  ALPACA_SECRET_KEY="$(cat /run/secrets/alpaca_secret_key)"
  export ALPACA_SECRET_KEY
fi
if [ -f /run/secrets/alpaca_paper_trade ]; then
  ALPACA_PAPER_TRADE="$(cat /run/secrets/alpaca_paper_trade)"
  export ALPACA_PAPER_TRADE
fi

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
    "import os\n"
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
exec uv run --no-project alpaca-mcp-server --transport streamable-http --host 0.0.0.0 --port 8088

