#!/usr/bin/env bash
set -xeuo pipefail

AWS_REGION="us-east-1"
AWS_BASE_ARGS=(--region "${AWS_REGION}" --output json --no-cli-pager --debug)
STATE_FILE="${BUILD_STATE_FILE:-/tmp/ami-build-state.env}"
INSTANCE_ID=""
SECURITY_GROUP_ID=""
AMI_ID=""
TIMESTAMP="${TIMESTAMP:-$(date -u +%Y%m%d%H%M%S)}"

aws_cli() {
  aws "${AWS_BASE_ARGS[@]}" "$@"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

write_state() {
  mkdir -p "$(dirname "${STATE_FILE}")"
  {
    printf 'INSTANCE_ID=%q\n' "${INSTANCE_ID}"
    printf 'SECURITY_GROUP_ID=%q\n' "${SECURITY_GROUP_ID}"
    printf 'AMI_ID=%q\n' "${AMI_ID}"
  } >"${STATE_FILE}"
}

wait_for_ssm_online() {
  local max_attempts=40
  local attempt=1
  local ping_status=""

  while (( attempt <= max_attempts )); do
    ping_status="$({
      aws_cli ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text
    } || true)"

    if [[ "${ping_status}" == "Online" ]]; then
      return 0
    fi

    echo "SSM not ready yet for ${INSTANCE_ID} (attempt ${attempt}/${max_attempts}, status: ${ping_status:-none})"
    sleep 10
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for SSM online status for ${INSTANCE_ID}" >&2
  return 1
}

wait_for_ssm_command() {
  local command_id="$1"
  local max_attempts=120
  local attempt=1
  local status=""

  while (( attempt <= max_attempts )); do
    status="$({
      aws_cli ssm get-command-invocation \
        --command-id "${command_id}" \
        --instance-id "${INSTANCE_ID}" \
        --query 'Status' \
        --output text
    } || true)"

    case "${status}" in
      Success)
        echo "--- SSM Command Output ---"
        aws ssm get-command-invocation --command-id "$command_id" --instance-id "$INSTANCE_ID" --query "StandardOutputContent" --output text || true
        echo "--- SSM Command Error ---"
        aws ssm get-command-invocation --command-id "$command_id" --instance-id "$INSTANCE_ID" --query "StandardErrorContent" --output text || true
        return 0
        ;;
      Failed|Cancelled|Cancelling|TimedOut)
        echo "--- SSM Command Output ---"
        aws ssm get-command-invocation --command-id "$command_id" --instance-id "$INSTANCE_ID" --query "StandardOutputContent" --output text || true
        echo "--- SSM Command Error ---"
        aws ssm get-command-invocation --command-id "$command_id" --instance-id "$INSTANCE_ID" --query "StandardErrorContent" --output text || true
        aws_cli ssm get-command-invocation \
          --command-id "${command_id}" \
          --instance-id "${INSTANCE_ID}" \
          --query '{Status:Status,StandardOutputContent:StandardOutputContent,StandardErrorContent:StandardErrorContent}'
        echo "SSM command failed with status ${status}" >&2
        return 1
        ;;
      InProgress|Pending|Delayed|"")
        echo "Waiting for SSM command ${command_id} (attempt ${attempt}/${max_attempts}, status: ${status:-none})"
        ;;
      *)
        echo "Unexpected SSM command status: ${status}" >&2
        ;;
    esac

    sleep 10
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for SSM command ${command_id}" >&2
  return 1
}

run_ssm_script() {
  local script_content="$1"
  local script_file=""
  local CMD_JSON=""
  local execution_timeout_seconds="7200"
  local command_id=""

  script_file="$(mktemp /tmp/ssm-script-XXXXXX.sh)"
  printf '%s\n' "${script_content}" >"${script_file}"
  CMD_JSON="$(jq -n \
    --arg script "$(cat "${script_file}")" \
    --arg timeout "${execution_timeout_seconds}" \
    '{"commands": [$script], "executionTimeout": [$timeout]}')"
  rm -f "${script_file}"

  command_id="$({
    aws_cli ssm send-command \
      --instance-ids "${INSTANCE_ID}" \
      --document-name 'AWS-RunShellScript' \
      --comment 'agent-provost-ami-build' \
      --timeout-seconds 3600 \
      --parameters "${CMD_JSON}" \
      --query 'Command.CommandId' \
      --output text
  } || true)"

  if [[ -z "${command_id}" || "${command_id}" == "None" ]]; then
    echo "Failed to submit SSM command" >&2
    return 1
  fi

  wait_for_ssm_command "${command_id}"
}

cleanup() {
  local exit_code=$?
  set +e

  write_state

  if [[ -n "${INSTANCE_ID}" ]]; then
    # Idempotent cleanup: tolerate already-terminated instances.
    aws_cli ec2 terminate-instances --instance-ids "${INSTANCE_ID}" >/dev/null 2>&1 || true
    aws_cli ec2 wait instance-terminated --instance-ids "${INSTANCE_ID}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${SECURITY_GROUP_ID}" ]]; then
    # Idempotent cleanup: tolerate already-deleted security groups.
    aws_cli ec2 delete-security-group --group-id "${SECURITY_GROUP_ID}" >/dev/null 2>&1 || true
  fi

  exit "${exit_code}"
}

trap cleanup EXIT

require_env INSTANCE_PROFILE_NAME

if [[ -z "${VERSION:-}" ]]; then
  if [[ -f version.txt ]]; then
    VERSION="$(tr -d '\r\n' < version.txt)"
  else
    echo "VERSION not set and version.txt not found" >&2
    exit 1
  fi
fi

if [[ ! "${VERSION}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION must be semver-like (examples: v1.2.3, v1.2.3-alpha.1). Received: ${VERSION}" >&2
  exit 1
fi

SECURITY_GROUP_ID="$(aws_cli ec2 create-security-group \
  --group-name "agent-provost-ami-${TIMESTAMP}" \
  --description 'Temporary SG for agent-provost AMI build (egress-only)' \
  --query 'GroupId' \
  --output text)"

write_state

# Ensure egress-only policy is explicit and idempotent.
aws_cli ec2 revoke-security-group-egress --group-id "${SECURITY_GROUP_ID}" --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true
aws_cli ec2 authorize-security-group-egress --group-id "${SECURITY_GROUP_ID}" --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true

UBUNTU_AMI_ID="$(aws_cli ssm get-parameter \
  --name '/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id' \
  --query 'Parameter.Value' \
  --output text)"

INSTANCE_ID="$(aws_cli ec2 run-instances \
  --image-id "${UBUNTU_AMI_ID}" \
  --instance-type 't4g.small' \
  --key-name 'Dassie-NV-4' \
  --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
  --associate-public-ip-address \
  --security-group-ids "${SECURITY_GROUP_ID}" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":16,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=agent-provost-ami-builder},{Key=Project,Value=agent-provost}]" \
  --query 'Instances[0].InstanceId' \
  --output text)"

write_state

aws_cli ec2 wait instance-running --instance-ids "${INSTANCE_ID}"
wait_for_ssm_online


# Create 2 GiB swap so apt-get/docker-pull never starve the SSM agent on low-memory instances.
run_ssm_script "#!/usr/bin/env bash
set -xe
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi"

run_ssm_script "#!/usr/bin/env bash
set -xe
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y jq docker.io docker-compose-v2 git ca-certificates curl unzip
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip -o /tmp/awscliv2.zip
rm -rf /tmp/aws
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update
rm -rf /tmp/aws /tmp/awscliv2.zip
systemctl enable --now docker"

run_ssm_script "#!/usr/bin/env bash
set -xe
if [ -d /opt/agent-provost ]; then rm -rf /opt/agent-provost; fi
git clone --depth 1 https://github.com/CharmingSteve/agent-provost /opt/agent-provost
cd /opt/agent-provost
docker compose --env-file .env.versions pull"

run_ssm_script "$(cat <<'SSM_SCRIPT'
#!/usr/bin/env bash
set -xe

if ! id -u provost >/dev/null 2>&1; then
  useradd -m -s /bin/bash provost
fi

usermod -aG docker provost
chown -R provost:provost /opt/agent-provost

install -d -m 755 /var/lib/cloud/scripts/per-boot
cat >/var/lib/cloud/scripts/per-boot/01-agent-provost-boot.sh <<'BOOTWRAP'
#!/usr/bin/env bash
set -euo pipefail

TOKEN="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')"
INSTANCE_ID="$(curl -fsS -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/instance-id)"
IDENTITY_DOC="$(curl -fsS -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/dynamic/instance-identity/document)"
REGION="$(printf '%s' "${IDENTITY_DOC}" | jq -r '.region')"
ACCOUNT_ID="$(printf '%s' "${IDENTITY_DOC}" | jq -r '.accountId')"

STACK_NAME="$(/usr/local/bin/aws ec2 describe-tags \
  --region "${REGION}" \
  --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=aws:cloudformation:stack-name" \
  --query 'Tags[0].Value' \
  --output text)"

if [ -z "${STACK_NAME}" ] || [ "${STACK_NAME}" = "None" ]; then
  echo "Unable to determine CloudFormation stack name from instance tags" >&2
  exit 1
fi

SECRET_NAME="agent-provost-secret-${STACK_NAME}"
S3_BUCKET="agent-provost-logs-${ACCOUNT_ID}-${REGION}-${STACK_NAME}"

install -d -m 755 /run/secrets
if ! mountpoint -q /run/secrets; then
  mount -t tmpfs -o size=1M,mode=755 tmpfs /run/secrets
fi

printf '%s' "${SECRET_NAME}" >/run/secrets/aws_secret_id
printf '%s' "${S3_BUCKET}" >/run/secrets/s3_bucket
printf '%s' "${REGION}" >/run/secrets/aws_region
chmod 600 /run/secrets/aws_secret_id /run/secrets/s3_bucket /run/secrets/aws_region
chown provost:provost /run/secrets /run/secrets/aws_secret_id /run/secrets/s3_bucket /run/secrets/aws_region

export PROVOST_SECRET_NAME="${SECRET_NAME}"
export AWS_REGION="${REGION}"
export S3_BUCKET="${S3_BUCKET}"

cd /opt/agent-provost
sudo -u provost docker compose --env-file .env.versions down || true
bootstrap_exports="$(sh bootstrap.sh ec2)"
eval "${bootstrap_exports}"
chown -R provost:provost /opt/agent-provost/.secrets
mkdir -p /opt/agent-provost/logs/fluent-bit-storage
chown -R 65532:65532 /opt/agent-provost/logs/fluent-bit-storage
export PROVOST_SECRETS_DIR="/opt/agent-provost/.secrets"
export ALPACA_API_KEY="$(cat /opt/agent-provost/.secrets/alpaca_api_key)"
export ALPACA_SECRET_KEY="$(cat /opt/agent-provost/.secrets/alpaca_secret_key)"
sudo -E -u provost docker compose --env-file .env.versions up -d
BOOTWRAP

chmod 755 /var/lib/cloud/scripts/per-boot/01-agent-provost-boot.sh
SSM_SCRIPT
)"

run_ssm_script "#!/usr/bin/env bash
set -xe
systemctl is-active docker
docker --version
docker compose version
docker images --format '{{.Repository}}:{{.Tag}}'
test -f /opt/agent-provost/docker-compose.yml"

run_ssm_script "#!/usr/bin/env bash
set -xe
find /var/log -type f -exec truncate -s 0 {} + || true
journalctl --rotate || true
journalctl --vacuum-time=1s || true
rm -f /root/.bash_history
rm -f /home/ubuntu/.bash_history
rm -f /root/.git-credentials /home/ubuntu/.git-credentials
rm -f /root/.config/git/credentials /home/ubuntu/.config/git/credentials
git config --global --unset-all credential.helper || true
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/data/* || true
nohup bash -c 'sleep 5; snap stop amazon-ssm-agent || true; rm -rf /var/snap/amazon-ssm-agent/common/state/*; rm -rf /var/snap/amazon-ssm-agent/common/logs/*' >/dev/null 2>&1 &"

# Give delayed SSM-agent teardown time to complete before stopping/imaging the instance.
sleep 15

create_image_mode=()
if aws_cli ec2 stop-instances --instance-ids "${INSTANCE_ID}" >/dev/null 2>&1; then
  aws_cli ec2 wait instance-stopped --instance-ids "${INSTANCE_ID}"
else
  echo "Warning: unable to stop instance; falling back to create-image --no-reboot" >&2
  create_image_mode=(--no-reboot)
fi

AMI_NAME="agent-provost-v${VERSION#v}-${TIMESTAMP}"
AMI_ID="$(aws_cli ec2 create-image --instance-id "${INSTANCE_ID}" "${create_image_mode[@]}" --name "${AMI_NAME}" --description "Agent Provost Golden AMI ${VERSION} ${TIMESTAMP}" --query 'ImageId' --output text)"
write_state
aws_cli ec2 wait image-available --image-ids "${AMI_ID}"

aws_cli ssm put-parameter \
  --name '/agent-provost/production/ami-id' \
  --type String \
  --value "${AMI_ID}" \
  --overwrite

printf 'Built AMI_ID=%s\n' "${AMI_ID}"
