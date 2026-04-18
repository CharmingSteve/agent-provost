# pip Hash Pin Upgrade Plan

## Objective
Apply Docker-image-style integrity pinning to Python dependencies by using exact versions plus SHA256 hashes, with an explicit note of what version each hash block represents.

## Implemented Scope
1. Added hash manifest: `hash-pip/requirements-runtime.txt`
2. Updated `alpaca-mcp.Dockerfile` to install with `pip --require-hashes --no-deps`
3. Added a second install step for `alpaca-mcp-server==2.0.1` to resolve transitive runtime dependencies
4. Upgraded versions that were behind:
   - uv: 0.8.16 -> 0.11.7
   - alpaca-mcp-server: 2.0.0 -> 2.0.1
   - pip: 24.0 -> 26.0.1
5. Kept current versions where already up to date:
   - setuptools==82.0.1
   - wheel==0.46.3
   - jaraco.context==6.1.2

## Verification Steps
1. `docker compose down`
2. `eval "$(sh bootstrap.sh dev)"`
3. `docker compose --env-file .env.versions up -d --build`
4. Validate service status: `docker compose ps`
5. Validate MCP endpoint availability via local proxy.
6. Run buy/order and portfolio checks.
7. Verify local logs and S3 sink expectations.

## Hash Source of Truth
All hashes were taken from per-version PyPI JSON endpoints:
- `https://pypi.org/pypi/uv/0.11.7/json`
- `https://pypi.org/pypi/alpaca-mcp-server/2.0.1/json`
- `https://pypi.org/pypi/pip/26.0.1/json`
- `https://pypi.org/pypi/setuptools/82.0.1/json`
- `https://pypi.org/pypi/wheel/0.46.3/json`
- `https://pypi.org/pypi/jaraco.context/6.1.2/json`
