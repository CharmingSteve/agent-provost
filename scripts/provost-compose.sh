#!/bin/bash

set -euo pipefail

# Prefer the EC2 install path, but fall back to the repo root for local dev.
if [[ -d /opt/agent-provost ]]; then
	PROJECT_ROOT=/opt/agent-provost
else
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

cd "$PROJECT_ROOT"
docker compose --env-file .env.versions "$@"
