#!/bin/sh
# bootstrap.sh: unified secrets staging for dev, runner, and EC2
# This script stages secrets into an ephemeral directory and exports PROVOST_SECRETS_DIR.
# The caller is responsible for cleanup if using temp directories.
#
# If PROVOST_SECRETS_DIR is already set and valid, this script reuses it.
# Otherwise, based on MODE, it creates a new ephemeral directory.
#
# Usage:
#   eval "$(./bootstrap.sh dev)"           # Outputs shell commands to export PROVOST_SECRETS_DIR
#   eval "$(./bootstrap.sh runner)"        # With ALPACA_API_KEY, ALPACA_SECRET_KEY in environment
#   eval "$(./bootstrap.sh ec2)"           # Fetches from AWS Secrets Manager

set -e

MODE="${1:-dev}"

write_secret_file() {
  value="$1"
  path="$2"
  printf '%s' "$value" > "$path"
  chmod 600 "$path"
}

# Check if secrets are already staged
if [ -n "${PROVOST_SECRETS_DIR:-}" ] && [ -d "$PROVOST_SECRETS_DIR" ] && \
  [ -f "$PROVOST_SECRETS_DIR/alpaca_api_key" ] && [ -f "$PROVOST_SECRETS_DIR/alpaca_secret_key" ] && \
  [ -f "$PROVOST_SECRETS_DIR/provost_token" ]; then
  # Secrets already staged, just export the path
  echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
  echo "echo '[bootstrap] secrets already staged in $PROVOST_SECRETS_DIR'"
  exit 0
fi

case "$MODE" in
  dev)
    # DEV mode: read from local .env, copy to temp ephemeral dir
    if [ ! -f .env ]; then
      echo "echo '[bootstrap:dev] ERROR: .env file not found' >&2" >&2
      exit 1
    fi
    
    PROVOST_SECRETS_DIR=$(mktemp -d)
    
    # Load .env and write secret files
    eval "$(grep -E '^(ALPACA_API_KEY|ALPACA_SECRET_KEY|ALPACA_PAPER_TRADE|PROVOST_TOKEN)=' .env)"
    chmod 700 "$PROVOST_SECRETS_DIR"
    write_secret_file "${ALPACA_API_KEY:-}" "$PROVOST_SECRETS_DIR/alpaca_api_key"
    write_secret_file "${ALPACA_SECRET_KEY:-}" "$PROVOST_SECRETS_DIR/alpaca_secret_key"
    write_secret_file "${ALPACA_PAPER_TRADE:-true}" "$PROVOST_SECRETS_DIR/alpaca_paper_trade"
    write_secret_file "${PROVOST_TOKEN:-dev-provost-token}" "$PROVOST_SECRETS_DIR/provost_token"
    
    # Output commands for caller to source
    echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
    echo "trap \"rm -rf '$PROVOST_SECRETS_DIR'\" EXIT"
    echo "echo '[bootstrap:dev] secrets staged in $PROVOST_SECRETS_DIR'"
    ;;
  
  runner)
    # RUNNER mode: use env vars (GitHub Secrets or dummy) or create dummy
    PROVOST_SECRETS_DIR=$(mktemp -d)
    
    API_KEY="${ALPACA_API_KEY:-dummy}"
    SECRET_KEY="${ALPACA_SECRET_KEY:-dummy}"
    PAPER_TRADE="${ALPACA_PAPER_TRADE:-true}"
    PROVOST_TOKEN_VALUE="${PROVOST_TOKEN:-dummy-provost-token}"
    
    chmod 700 "$PROVOST_SECRETS_DIR"
    write_secret_file "$API_KEY" "$PROVOST_SECRETS_DIR/alpaca_api_key"
    write_secret_file "$SECRET_KEY" "$PROVOST_SECRETS_DIR/alpaca_secret_key"
    write_secret_file "$PAPER_TRADE" "$PROVOST_SECRETS_DIR/alpaca_paper_trade"
    write_secret_file "$PROVOST_TOKEN_VALUE" "$PROVOST_SECRETS_DIR/provost_token"
    
    echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
    echo "trap \"rm -rf '$PROVOST_SECRETS_DIR'\" EXIT"
    echo "echo '[bootstrap:runner] secrets staged in $PROVOST_SECRETS_DIR'"
    ;;
  
  ec2)
    # EC2 mode: fetch from AWS Secrets Manager using instance role
    if ! command -v aws >/dev/null 2>&1; then
      echo "echo '[bootstrap:ec2] ERROR: aws cli not found' >&2" >&2
      exit 1
    fi
    
    SECRET_NAME="${PROVOST_SECRET_NAME:-agent-provost/alpaca}"
    REGION="${AWS_REGION:-us-east-1}"
    
    SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query SecretString --output text 2>&1)
    
    # Use /run (tmpfs) on EC2; assume directory exists or can be created
    PROVOST_SECRETS_DIR="/run/provost-secrets"
    mkdir -p "$PROVOST_SECRETS_DIR"
    chmod 700 "$PROVOST_SECRETS_DIR"
    
    # Parse JSON and write secret files using simple string extraction (no jq dependency)
    API_KEY=$(printf '%s' "$SECRET_JSON" | grep -o '"ALPACA_API_KEY":"[^"]*' | cut -d'"' -f4 || echo "")
    SECRET_KEY=$(printf '%s' "$SECRET_JSON" | grep -o '"ALPACA_SECRET_KEY":"[^"]*' | cut -d'"' -f4 || echo "")
    PAPER_TRADE=$(printf '%s' "$SECRET_JSON" | grep -o '"ALPACA_PAPER_TRADE":"[^"]*' | cut -d'"' -f4 || echo "true")
    PROVOST_TOKEN_VALUE=$(printf '%s' "$SECRET_JSON" | grep -o '"PROVOST_TOKEN":"[^"]*' | cut -d'"' -f4 || echo "")

    if [ -z "$PROVOST_TOKEN_VALUE" ]; then
      echo "echo '[bootstrap:ec2] ERROR: PROVOST_TOKEN missing from secret payload' >&2" >&2
      exit 1
    fi
    
    write_secret_file "$API_KEY" "$PROVOST_SECRETS_DIR/alpaca_api_key"
    write_secret_file "$SECRET_KEY" "$PROVOST_SECRETS_DIR/alpaca_secret_key"
    write_secret_file "$PAPER_TRADE" "$PROVOST_SECRETS_DIR/alpaca_paper_trade"
    write_secret_file "$PROVOST_TOKEN_VALUE" "$PROVOST_SECRETS_DIR/provost_token"
    
    echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
    echo "echo '[bootstrap:ec2] secrets staged in $PROVOST_SECRETS_DIR'"
    ;;
  
  *)
    echo "echo 'Usage: \$0 {dev|runner|ec2}' >&2" >&2
    exit 1
    ;;
esac
