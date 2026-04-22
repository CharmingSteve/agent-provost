#!/bin/sh
# Exit immediately if any command fails.
set -e

# Load secrets from mounted files (set by bootstrap or docker compose).
# Each secret is optional, and is only exported if its file is present.
if [ -f /run/secrets/alpaca_api_key ]; then
  # Read Alpaca API key from the Docker/K8s secrets mount.
  ALPACA_API_KEY="$(cat /run/secrets/alpaca_api_key)"
  # Export so child processes (the MCP server) can read it.
  export ALPACA_API_KEY
fi
if [ -f /run/secrets/alpaca_secret_key ]; then
  # Read Alpaca secret key from the Docker/K8s secrets mount.
  ALPACA_SECRET_KEY="$(cat /run/secrets/alpaca_secret_key)"
  # Export so child processes (the MCP server) can read it.
  export ALPACA_SECRET_KEY
fi
if [ -f /run/secrets/alpaca_paper_trade ]; then
  # Read paper/live mode flag from the Docker/K8s secrets mount.
  ALPACA_PAPER_TRADE="$(cat /run/secrets/alpaca_paper_trade)"
  # Export so child processes (the MCP server) can read it.
  export ALPACA_PAPER_TRADE
fi

# Inform startup logs that runtime patching is beginning.
echo "[entrypoint] Patching TRADE_API_URL support into server.py..."
# Discover the primary Python site-packages directory at runtime.
SITE_PACKAGES=$(python -c "import site; print(site.getsitepackages()[0])")
# Build absolute path to the installed alpaca_mcp_server module file.
SERVER_PY="$SITE_PACKAGES/alpaca_mcp_server/server.py"

# Run an inline Python patcher script against the target file path.
python - "$SERVER_PY" <<'PYEOF'
# Use regex replacement for a targeted function rewrite.
import re
# Read the file path argument passed from the shell.
import sys
# Retrieve the target server.py path passed from the shell wrapper.
path = sys.argv[1]
# Load the current server.py source.
src = open(path).read()
# Match the existing _get_trading_base_url function block.
# Note: the {1,6} range is intentionally narrow and assumes upstream function size.
# If upstream expands beyond this range, the patch step will skip replacement.
# The window is intentionally small to avoid overmatching unrelated functions.
# Skip behavior is surfaced via the explicit "[patch] ... skipping." log below.
pattern = r"def _get_trading_base_url\(\) -> str:\n(?:    .*\n){1,6}"
# Define replacement block that adds TRADE_API_URL override support.
new_block = (
    "import os\n"
    "def _get_trading_base_url() -> str:\n"
    "    forced = os.environ.get(\"TRADE_API_URL\")\n"
    "    if forced:\n"
    "        return forced.rstrip(\"/\")\n"
    "    paper = os.environ.get(\"ALPACA_PAPER_TRADE\", \"true\").lower() in (\"true\", \"1\", \"yes\")\n"
    "    return TRADING_API_BASE_URLS[\"paper\" if paper else \"live\"]\n"
)
# Replace only the first matched function block.
patched, count = re.subn(pattern, new_block, src, count=1)
if count == 1:
    # Write patched content back when replacement succeeds.
    open(path, "w").write(patched)
    # Emit success log for observability.
    print("[patch] TRADE_API_URL override patch applied.")
else:
    # Emit skip log when expected target function is not found.
    print("[patch] Trading base URL function not found — skipping.")
PYEOF

# Inform startup logs that process handoff is about to happen.
echo "[entrypoint] Starting MCP Server with streamable-http transport..."
# Replace shell process with the MCP server process (PID 1 handoff).
# Binding to 0.0.0.0 is intentional in containers so mapped ports are reachable.
# Because this exposes all container interfaces, enforce access controls via network policy/firewalls.
# This entrypoint does not add network auth controls at bind time; rely on upstream proxy/platform controls.
# Application-level authentication/authorization should also be enforced by the deployed stack.
exec uv run --no-project alpaca-mcp-server --transport streamable-http --host 0.0.0.0 --port 8088
