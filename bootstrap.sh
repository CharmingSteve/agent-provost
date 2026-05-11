#!/bin/sh
# bootstrap.sh: unified secrets/runtime staging for dev, runner, and EC2

set -e

MODE="${1:-dev}"
ENV_FILE=".env"
LOCAL_FALLBACK_SECRETS_DIR=".secrets"

write_secret_file() {
  value="$1"
  path="$2"
  printf '%s' "$value" > "$path"
  chmod 600 "$path"
}

sync_local_fallback_secrets() {
  src_dir="$1"
  mkdir -p "$LOCAL_FALLBACK_SECRETS_DIR"
  chmod 700 "$LOCAL_FALLBACK_SECRETS_DIR"
  cp "$src_dir/alpaca_api_key" "$LOCAL_FALLBACK_SECRETS_DIR/alpaca_api_key"
  cp "$src_dir/alpaca_secret_key" "$LOCAL_FALLBACK_SECRETS_DIR/alpaca_secret_key"
  cp "$src_dir/alpaca_paper_trade" "$LOCAL_FALLBACK_SECRETS_DIR/alpaca_paper_trade"
  if [ ! -f "$LOCAL_FALLBACK_SECRETS_DIR/provost_token" ]; then
    cp "$src_dir/provost_token" "$LOCAL_FALLBACK_SECRETS_DIR/provost_token"
  fi
  chmod 600 "$LOCAL_FALLBACK_SECRETS_DIR/alpaca_api_key" \
    "$LOCAL_FALLBACK_SECRETS_DIR/alpaca_secret_key" \
    "$LOCAL_FALLBACK_SECRETS_DIR/alpaca_paper_trade"
}

is_true() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

env_get() {
  key="$1"
  file="$2"
  awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found=1 } END { if (!found) exit 1 }' "$file"
}

emit_export_or_unset() {
  key="$1"
  value="$2"
  if [ -n "$value" ]; then
    echo "export $key='$value'"
  else
    echo "unset $key"
  fi
}

create_secrets_dir() {
  mode="$1"
  if [ "$mode" = "ec2" ]; then
    PROVOST_SECRETS_DIR="/run/provost-secrets"
    mkdir -p "$PROVOST_SECRETS_DIR"
  elif [ -z "${PROVOST_SECRETS_DIR:-}" ] || [ ! -d "$PROVOST_SECRETS_DIR" ]; then
    PROVOST_SECRETS_DIR=$(mktemp -d)
  fi
  chmod 700 "$PROVOST_SECRETS_DIR"
}

create_run_dir() {
  mode="$1"
  if [ "$mode" = "ec2" ]; then
    PROVOST_RUN_DIR="/run/provost"
    mkdir -p "$PROVOST_RUN_DIR"
  elif [ -z "${PROVOST_RUN_DIR:-}" ] || [ ! -d "$PROVOST_RUN_DIR" ]; then
    PROVOST_RUN_DIR=$(mktemp -d)
  fi
  chmod 700 "$PROVOST_RUN_DIR"
  rm -f "$PROVOST_RUN_DIR/fluent-bit.sock"
}

has_staged_secrets() {
  [ -n "${PROVOST_SECRETS_DIR:-}" ] && [ -d "$PROVOST_SECRETS_DIR" ] && \
    [ -f "$PROVOST_SECRETS_DIR/alpaca_api_key" ] && [ -f "$PROVOST_SECRETS_DIR/alpaca_secret_key" ] && \
    [ -f "$PROVOST_SECRETS_DIR/provost_token" ]
}

if has_staged_secrets && [ -n "${PROVOST_RUN_DIR:-}" ] && [ -d "$PROVOST_RUN_DIR" ]; then
  rm -f "$PROVOST_RUN_DIR/fluent-bit.sock"
  echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
  echo "export PROVOST_RUN_DIR='$PROVOST_RUN_DIR'"
  echo "echo '[bootstrap] secrets/runtime already staged'"
  exit 0
fi

case "$MODE" in
  dev)
    if [ ! -f "$ENV_FILE" ]; then
      echo "echo '[bootstrap:dev] ERROR: .env file not found' >&2" >&2
      exit 1
    fi

    create_secrets_dir dev
    create_run_dir dev

    ALPACA_API_KEY=$(env_get ALPACA_API_KEY "$ENV_FILE" || true)
    ALPACA_SECRET_KEY=$(env_get ALPACA_SECRET_KEY "$ENV_FILE" || true)
    ALPACA_PAPER_TRADE=$(env_get ALPACA_PAPER_TRADE "$ENV_FILE" || true)
    PROVOST_TOKEN_VALUE=$(env_get PROVOST_TOKEN "$ENV_FILE" || true)

    AWS_REGION_VALUE=$(env_get AWS_REGION "$ENV_FILE" || true)
    S3_BUCKET_VALUE=$(env_get S3_BUCKET "$ENV_FILE" || true)
    AWS_ACCESS_KEY_ID_VALUE=$(env_get AWS_ACCESS_KEY_ID "$ENV_FILE" || true)
    AWS_SECRET_ACCESS_KEY_VALUE=$(env_get AWS_SECRET_ACCESS_KEY "$ENV_FILE" || true)
    AWS_SESSION_TOKEN_VALUE=$(env_get AWS_SESSION_TOKEN "$ENV_FILE" || true)
    INSTANCE_ID_VALUE=$(env_get INSTANCE_ID "$ENV_FILE" || true)

    write_secret_file "${ALPACA_API_KEY:-}" "$PROVOST_SECRETS_DIR/alpaca_api_key"
    write_secret_file "${ALPACA_SECRET_KEY:-}" "$PROVOST_SECRETS_DIR/alpaca_secret_key"
    write_secret_file "${ALPACA_PAPER_TRADE:-true}" "$PROVOST_SECRETS_DIR/alpaca_paper_trade"
    write_secret_file "${PROVOST_TOKEN_VALUE:-dev-provost-token}" "$PROVOST_SECRETS_DIR/provost_token"
    sync_local_fallback_secrets "$PROVOST_SECRETS_DIR"

    echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
    echo "export PROVOST_RUN_DIR='$PROVOST_RUN_DIR'"
    emit_export_or_unset AWS_REGION "$AWS_REGION_VALUE"
    emit_export_or_unset S3_BUCKET "$S3_BUCKET_VALUE"
    emit_export_or_unset AWS_ACCESS_KEY_ID "$AWS_ACCESS_KEY_ID_VALUE"
    emit_export_or_unset AWS_SECRET_ACCESS_KEY "$AWS_SECRET_ACCESS_KEY_VALUE"
    emit_export_or_unset AWS_SESSION_TOKEN "$AWS_SESSION_TOKEN_VALUE"
    if [ -n "$INSTANCE_ID_VALUE" ]; then
      echo "export INSTANCE_ID='$INSTANCE_ID_VALUE'"
    else
      echo "export INSTANCE_ID='local-dev'"
    fi
    echo "trap \"rm -rf '$PROVOST_SECRETS_DIR' '$PROVOST_RUN_DIR'\" EXIT"
    echo "echo '[bootstrap:dev] staged secrets/runtime dirs'"
    ;;

  runner)
    create_secrets_dir runner
    create_run_dir runner

    API_KEY="${ALPACA_API_KEY:-dummy}"
    SECRET_KEY="${ALPACA_SECRET_KEY:-dummy}"
    PAPER_TRADE="${ALPACA_PAPER_TRADE:-true}"
    PROVOST_TOKEN_VALUE="${PROVOST_TOKEN:-dummy-provost-token}"

    write_secret_file "$API_KEY" "$PROVOST_SECRETS_DIR/alpaca_api_key"
    write_secret_file "$SECRET_KEY" "$PROVOST_SECRETS_DIR/alpaca_secret_key"
    write_secret_file "$PAPER_TRADE" "$PROVOST_SECRETS_DIR/alpaca_paper_trade"
    write_secret_file "$PROVOST_TOKEN_VALUE" "$PROVOST_SECRETS_DIR/provost_token"

    # Production safety default: do not copy real secrets into repo-local .secrets
    # unless explicitly requested for break-glass troubleshooting.
    if is_true "${ALLOW_EC2_LOCAL_FALLBACK_SECRETS:-false}"; then
      sync_local_fallback_secrets "$PROVOST_SECRETS_DIR"
    fi

    echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
    echo "export PROVOST_RUN_DIR='$PROVOST_RUN_DIR'"
    emit_export_or_unset AWS_REGION "${AWS_REGION:-}"
    emit_export_or_unset S3_BUCKET "${S3_BUCKET:-}"
    emit_export_or_unset AWS_ACCESS_KEY_ID "${AWS_ACCESS_KEY_ID:-}"
    emit_export_or_unset AWS_SECRET_ACCESS_KEY "${AWS_SECRET_ACCESS_KEY:-}"
    emit_export_or_unset AWS_SESSION_TOKEN "${AWS_SESSION_TOKEN:-}"
    if [ -n "${INSTANCE_ID:-}" ]; then
      echo "export INSTANCE_ID='${INSTANCE_ID}'"
    else
      echo "export INSTANCE_ID='runner-local'"
    fi
    echo "trap \"rm -rf '$PROVOST_SECRETS_DIR' '$PROVOST_RUN_DIR'\" EXIT"
    echo "echo '[bootstrap:runner] staged secrets/runtime dirs'"
    ;;

  ec2)
    if ! command -v aws >/dev/null 2>&1; then
      echo "echo '[bootstrap:ec2] ERROR: aws cli not found' >&2" >&2
      exit 1
    fi

    create_secrets_dir ec2
    create_run_dir ec2

    # Ensure directories exist
    mkdir -p "$PROVOST_SECRETS_DIR" "$PROVOST_RUN_DIR"

    # Gracefully attempt to secure directories (CloudFormation handles this on boot)
    chmod 700 "$PROVOST_SECRETS_DIR" 2>/dev/null || true
    chmod 755 "$PROVOST_RUN_DIR" 2>/dev/null || true

    SECRET_NAME="${PROVOST_SECRET_NAME:-agent-provost/alpaca}"
    REGION="${AWS_REGION:-us-east-1}"
    SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query SecretString --output text 2>&1)

    API_KEY=$(printf '%s' "$SECRET_JSON" | grep -o '"ALPACA_API_KEY":"[^"]*' | cut -d'"' -f4 || echo "")
    SECRET_KEY=$(printf '%s' "$SECRET_JSON" | grep -o '"ALPACA_SECRET_KEY":"[^"]*' | cut -d'"' -f4 || echo "")
    PAPER_TRADE=$(printf '%s' "$SECRET_JSON" | grep -o '"ALPACA_PAPER_TRADE":"[^"]*' | cut -d'"' -f4 || echo "true")
    PROVOST_TOKEN_VALUE=$(printf '%s' "$SECRET_JSON" | grep -o '"PROVOST_TOKEN":"[^"]*' | cut -d'"' -f4 || echo "")
    S3_BUCKET_VALUE=$(printf '%s' "$SECRET_JSON" | grep -o '"S3_BUCKET":"[^"]*' | cut -d'"' -f4 || echo "")

    if [ -z "$PROVOST_TOKEN_VALUE" ]; then
      echo "echo '[bootstrap:ec2] ERROR: PROVOST_TOKEN missing from secret payload' >&2" >&2
      exit 1
    fi

    write_secret_file "$API_KEY" "$PROVOST_SECRETS_DIR/alpaca_api_key"
    write_secret_file "$SECRET_KEY" "$PROVOST_SECRETS_DIR/alpaca_secret_key"
    write_secret_file "$PAPER_TRADE" "$PROVOST_SECRETS_DIR/alpaca_paper_trade"
    write_secret_file "$PROVOST_TOKEN_VALUE" "$PROVOST_SECRETS_DIR/provost_token"

    # Production safety default: keep secrets on tmpfs only.
    # Enable fallback copy explicitly for break-glass troubleshooting.
    if is_true "${ALLOW_EC2_LOCAL_FALLBACK_SECRETS:-false}"; then
      sync_local_fallback_secrets "$PROVOST_SECRETS_DIR"
    fi

    echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
    echo "export PROVOST_RUN_DIR='$PROVOST_RUN_DIR'"
    echo "export AWS_REGION='${REGION}'"
    emit_export_or_unset S3_BUCKET "$S3_BUCKET_VALUE"
    echo "unset AWS_ACCESS_KEY_ID"
    echo "unset AWS_SECRET_ACCESS_KEY"
    echo "unset AWS_SESSION_TOKEN"
    echo "export INSTANCE_ID='ec2-instance'"
    echo "echo '[bootstrap:ec2] staged secrets/runtime dirs and configured IAM-based aws auth'"
    ;;

  *)
    echo "echo 'Usage: \$0 {dev|runner|ec2}' >&2" >&2
    exit 1
    ;;
esac
