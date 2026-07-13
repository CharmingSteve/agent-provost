#!/usr/bin/env bash
set -euo pipefail

IMDS_TOKEN="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')"
INSTANCE_ID="$(curl -fsS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/instance-id)"
IDENTITY_DOC="$(curl -fsS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" http://169.254.169.254/latest/dynamic/instance-identity/document)"
REGION="$(printf '%s' "${IDENTITY_DOC}" | jq -r '.region')"

STACK_NAME="$(aws ec2 describe-tags \
  --region "${REGION}" \
  --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=aws:cloudformation:stack-name" \
  --query 'Tags[0].Value' \
  --output text)"

if [[ -z "${STACK_NAME}" || "${STACK_NAME}" == "None" ]]; then
  echo "Unable to determine CloudFormation stack name from instance tags" >&2
  exit 1
fi

TZ="$(aws ec2 describe-tags \
  --region "${REGION}" \
  --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=ProvostTimezone" \
  --query 'Tags[0].Value' \
  --output text 2>/dev/null || echo '')"

if [[ -n "${TZ}" && "${TZ}" != "None" ]]; then
  if ! command -v timedatectl >/dev/null 2>&1; then
    echo "Warning: timedatectl is not available; skipping timezone update" >&2
  elif ! timedatectl list-timezones 2>/dev/null | grep -Fxq -- "${TZ}"; then
    echo "Warning: invalid ProvostTimezone tag value '${TZ}'; skipping timezone update" >&2
  elif ! sudo timedatectl set-timezone "${TZ}"; then
    echo "Warning: failed to set timezone to '${TZ}'; continuing" >&2
  fi
fi

SECRET_NAME="agent-provost-secret-${STACK_NAME}"
SECRET_STRING="$(aws secretsmanager get-secret-value \
  --region "${REGION}" \
  --secret-id "${SECRET_NAME}" \
  --query 'SecretString' \
  --output text)"
S3_BUCKET="$(printf '%s' "${SECRET_STRING}" | jq -r '.S3_BUCKET')"

if [[ ! -d /run/secrets ]]; then
  install -d -m 755 /run/secrets
  mount -t tmpfs -o size=1M,mode=755 tmpfs /run/secrets
fi

printf '%s' "${SECRET_NAME}" >/run/secrets/aws_secret_id
printf '%s' "${S3_BUCKET}" >/run/secrets/s3_bucket
printf '%s' "${REGION}" >/run/secrets/aws_region
chmod 600 /run/secrets/aws_secret_id /run/secrets/s3_bucket /run/secrets/aws_region

printf '%s\n' "${SECRET_STRING}" | jq '
  def split_csv:
    split(",")
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0));
  def to_num:
    if type == "number" then . else tonumber end;
  def to_bool:
    if type == "boolean" then .
    elif type == "string" then ascii_downcase == "true"
    else false
    end;
  {
    max_trade_size: {
      enabled: true,
      description: "Block trades whose quantity exceeds the configured limit. Protects against oversized orders from a runaway agent.",
      params: { limit: (.MaxSharesPerTrade | to_num) }
    },
    max_trade_notional: {
      enabled: true,
      description: "Block trades whose dollar notional value exceeds the configured limit.",
      params: { limit: (.MaxTradeNotional | to_num) }
    },
    inbound_request_rate_limit: {
      enabled: true,
      description: "Limit inbound request rate at the proxy boundary. Set rpm to 0 to disable.",
      params: { rpm: (.RateLimitRPM | to_num) }
    },
    allowed_tickers: {
      enabled: (.EnableAllowlist == "true"),
      description: "Draconian Mode: Block ALL trades except for those in this explicit allowlist.",
      params: { tickers: (.AllowedSymbols | split_csv) }
    },
    blocked_tickers: {
      enabled: true,
      description: "Block trades on tickers that appear in the restricted symbol list. Prevents unauthorized exposure to specific securities.",
      params: { tickers: (.BlockedSymbols | split_csv) }
    },
    allowed_asset_classes: {
      enabled: true,
      description: "Allow trading only for listed asset classes.",
      params: { classes: (.AllowedAssetClasses | split_csv) }
    },
    forbidden_tools: {
      enabled: true,
      description: "Hard-block method+path endpoint templates before rule-based checks.",
      params: { tools: (.ForbiddenTools | split_csv) }
    },
    max_replace_notional: {
      enabled: true,
      description: "Block order replacement requests when replacement notional exceeds policy limit.",
      params: { limit: (.MaxReplaceNotional | to_num) }
    },
    prevent_market_order_upgrade: {
      enabled: (.PreventMarketOrderUpgrade | to_bool),
      description: "Block replacing limit orders with market orders.",
      params: { enabled: (.PreventMarketOrderUpgrade | to_bool) }
    },
    max_close_notional: {
      enabled: true,
      description: "Block close-position requests above configured notional limit.",
      params: { limit: (.MaxCloseNotional | to_num) }
    },
    allowed_close_tickers: {
      enabled: true,
      description: "Allow close-position requests only for configured symbols.",
      params: { tickers: (.AllowedCloseTickers | split_csv) }
    },
    log_dne_requests: {
      enabled: (.LogDNERequests | to_bool),
      description: "Allow but audit do-not-exercise broker requests.",
      params: { enabled: (.LogDNERequests | to_bool) }
    }
  }
' >/opt/agent-provost/rules.json

chown provost:provost /opt/agent-provost/rules.json
chmod 0644 /opt/agent-provost/rules.json

running_services="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
should_launch=0
if [[ "${running_services}" != *"agent-provost"* || "${running_services}" != *"alpaca-mcp"* || "${running_services}" != *"fluent-bit"* ]]; then
  should_launch=1
fi
if pgrep -f cloud-init >/dev/null 2>&1; then
  should_launch=1
fi

if [[ "${should_launch}" == "1" ]]; then
  cd /opt/agent-provost
  export PROVOST_SECRET_NAME="${SECRET_NAME}"
  export AWS_REGION="${REGION}"
  export S3_BUCKET="${S3_BUCKET}"
  export ALLOW_EC2_LOCAL_FALLBACK_SECRETS="false"
  eval "$(sh /opt/agent-provost/bootstrap.sh ec2)"

  cp /run/provost-secrets/alpaca_api_key /run/secrets/alpaca_api_key
  cp /run/provost-secrets/alpaca_secret_key /run/secrets/alpaca_secret_key
  cp /run/provost-secrets/alpaca_paper_trade /run/secrets/alpaca_paper_trade
  cp /run/provost-secrets/provost_token /run/secrets/provost_token
  chmod 444 /run/secrets/alpaca_api_key /run/secrets/alpaca_secret_key /run/secrets/alpaca_paper_trade /run/secrets/provost_token
  chown root:root /run/secrets/alpaca_api_key /run/secrets/alpaca_secret_key /run/secrets/alpaca_paper_trade /run/secrets/provost_token

  rm -rf /opt/agent-provost/.secrets
  mkdir -p /opt/agent-provost/logs/fluent-bit-storage
  chown -R 65532:65532 /opt/agent-provost/logs/fluent-bit-storage

  export PROVOST_SECRETS_DIR="/run/secrets"
  ALPACA_API_KEY="$(cat /run/secrets/alpaca_api_key)"
  ALPACA_SECRET_KEY="$(cat /run/secrets/alpaca_secret_key)"
  export ALPACA_API_KEY
  export ALPACA_SECRET_KEY
  sudo -E -u provost docker compose --env-file .env.versions down || true
  sudo -E -u provost docker compose --env-file .env.versions up -d
fi