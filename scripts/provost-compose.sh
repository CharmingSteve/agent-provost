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

# Load .env.versions (digests) always.
# Load .env (local dev creds) if it exists, don't error if missing (for CI/prod).
# Source .env into shell environment so credentials are available to export.
if [[ -f .env ]]; then
	set -a
	# shellcheck disable=SC1091
	source .env
	set +a
fi

# Explicitly export AWS/S3 env vars to ensure docker compose picks them up from shell.
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
export AWS_REGION="${AWS_REGION:-}"
export S3_BUCKET="${S3_BUCKET:-}"

if [[ -f .env ]]; then
	docker compose --env-file .env.versions --env-file .env "$@"
else
	docker compose --env-file .env.versions "$@"
fi
