#!/bin/bash
set -euo pipefail
git config --global --add safe.directory /opt/agent-provost

# Ensure we are in the repo root
if [ ! -f "bootstrap.sh" ]; then
    echo "ERROR: Must be run from the repository root"
    exit 1
fi

BRANCH_NAME="${1:-main}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="backups/upgrade-${TIMESTAMP}"

echo "[upgrade] Backing up config and policy files to $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# Backup configs (Archival only - we will use the new branch's rules.json)
[ -f .env.versions ] && cp -a .env.versions "$BACKUP_DIR/"
[ -f rules.json ] && cp -a rules.json "$BACKUP_DIR/rules.json.pre-upgrade"
[ -f docker-compose.yml ] && cp -a docker-compose.yml "$BACKUP_DIR/"
[ -d lua ] && cp -a lua "$BACKUP_DIR/"

# Backup Docker Images
if [ -f .env.versions ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' .env.versions | xargs)
    
    for img_var in OPENRESTY_IMAGE BASE_PYTHON_IMAGE ALPACA_IMAGE FLUENT_BIT_IMAGE; do
        img_val="${!img_var:-}"
        
        # Special handling for ALPACA_IMAGE which uses a separate TAG variable
        if [ "$img_var" = "ALPACA_IMAGE" ] && [ -n "${ALPACA_IMAGE_TAG:-}" ]; then
            # Check if the tag is a digest (starts with sha256:) or a regular tag
            if [[ "$ALPACA_IMAGE_TAG" == sha256:* ]]; then
                img_val="${img_val}@${ALPACA_IMAGE_TAG}"
            else
                img_val="${img_val}:${ALPACA_IMAGE_TAG}"
            fi
        fi

        if [ -n "$img_val" ] && docker image inspect "$img_val" >/dev/null 2>&1; then
            safe_name=$(echo "$img_var" | tr '[:upper:]' '[:lower:]')
            echo "[upgrade] Saving local image for $img_var -> $BACKUP_DIR/${safe_name}.tar.gz"
            docker save "$img_val" | gzip > "$BACKUP_DIR/${safe_name}.tar.gz"
        else
            echo "[upgrade] Skipping $img_var (not present locally): $img_val"
        fi
    done
fi

echo "[upgrade] Stashing any uncommitted changes"
git stash

echo "[upgrade] Unshallowing clone if needed (handles older AMI-baked depth-1 clones)"
git fetch --unshallow 2>/dev/null || true

echo "[upgrade] Fetching all refs from remote"
git fetch origin "+refs/heads/*:refs/remotes/origin/*"

echo "[upgrade] Verifying branch exists on remote"
if ! git rev-parse --verify "origin/$BRANCH_NAME" >/dev/null 2>&1; then
    echo "ERROR: Branch 'origin/$BRANCH_NAME' does not exist on remote"
    echo "Available branches:"
    git branch -r
    exit 1
fi

echo "[upgrade] Checking out $BRANCH_NAME"
git checkout --track -B "$BRANCH_NAME" "origin/$BRANCH_NAME"

echo "[upgrade] Pulling origin/$BRANCH_NAME"
git pull origin "$BRANCH_NAME"

echo "[upgrade] Re-staging bootstrap runtime/secrets"
# Auto-detect environment
if [[ -d /opt/agent-provost ]]; then
    BOOTSTRAP_MODE="ec2"
else
    BOOTSTRAP_MODE="dev"
fi

if ! eval "$(sh bootstrap.sh "$BOOTSTRAP_MODE")"; then
    echo "ERROR: bootstrap failed in $BOOTSTRAP_MODE mode"
    exit 1
fi

echo "[upgrade] Pulling pinned images"
./scripts/provost-compose.sh pull

echo "[upgrade] Loading secrets from /run/secrets"
if [ -d "/run/secrets" ]; then
    if [ -f "/run/secrets/alpaca_api_key" ]; then
        ALPACA_API_KEY=$(cat /run/secrets/alpaca_api_key)
        export ALPACA_API_KEY
    fi
    if [ -f "/run/secrets/alpaca_secret_key" ]; then
        ALPACA_SECRET_KEY=$(cat /run/secrets/alpaca_secret_key)
        export ALPACA_SECRET_KEY
    fi
    if [ -f "/run/secrets/s3_bucket" ]; then
        S3_BUCKET=$(cat /run/secrets/s3_bucket)
        export S3_BUCKET
    fi
    if [ -f "/run/secrets/aws_region" ]; then
        AWS_REGION=$(cat /run/secrets/aws_region)
        export AWS_REGION
    fi
fi

echo "[upgrade] Restarting stack"
export PROVOST_SECRETS_DIR="/run/secrets"
./scripts/provost-compose.sh up -d --remove-orphans

echo ""
echo "Upgrade complete"
echo "Backup location: $BACKUP_DIR"
echo "Current commit: $(git rev-parse --short HEAD)"
echo "Restore hint: gunzip -c $BACKUP_DIR/openresty_image.tar.gz | docker load"
