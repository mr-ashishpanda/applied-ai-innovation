#!/usr/bin/env bash
# scripts/connect.sh — push an ephemeral SSH key to an EC2 instance over SSM and
# configure ~/.ssh/config so `ssh <instance-id>` works directly afterwards.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") --instance-id <id> [--profile <aws-profile>] [--region <region>] [--user <remote-user>]

Pushes a per-instance ephemeral SSH key to the target over AWS SSM and configures
~/.ssh/config so 'ssh <instance-id>' / 'scp file <instance-id>:/path' work directly.

Options:
  --instance-id <id>   EC2 instance ID (required)
  --profile <name>     AWS CLI profile to use (optional; default credential chain otherwise)
  --region <name>      AWS region (optional; falls back to the profile/CLI default)
  --user <name>        Skip user discovery and use this remote user
  -h, --help           Show this help
EOF
}

INSTANCE_ID=""; PROFILE=""; REGION=""; FORCE_USER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --user) FORCE_USER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; ssm_die "Unknown argument: $1" ;;
  esac
done

[ -n "$INSTANCE_ID" ] || { usage; ssm_die "--instance-id is required"; }

ssm_require_cli

ssm_log "Checking AWS auth..."
ssm_aws "$PROFILE" sts get-caller-identity >/dev/null \
  || ssm_die "AWS auth failed. Check --profile / AWS_PROFILE / your credential chain."

ssm_log "Checking instance ${INSTANCE_ID} is SSM-managed..."
PING_STATUS=$(ssm_aws "$PROFILE" ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
[ "$PING_STATUS" = "Online" ] || ssm_die "Instance ${INSTANCE_ID} is not SSM-managed/online (got: ${PING_STATUS}). Check the SSM Agent and the instance's IAM role."

REMOTE_USER="$FORCE_USER"
if [ -z "$REMOTE_USER" ]; then
  ssm_log "Discovering real login users on the instance via SSM (no guessing)..."
  CMD_ID=$(ssm_send_shell_command "$PROFILE" "$INSTANCE_ID" '{ ls /home 2>/dev/null; echo root; } | sort -u')
  ssm_wait_command "$PROFILE" "$INSTANCE_ID" "$CMD_ID" || ssm_die "Failed to list remote users on ${INSTANCE_ID}."
  mapfile -t USERS < <(ssm_command_output "$PROFILE" "$INSTANCE_ID" "$CMD_ID")
  [ "${#USERS[@]}" -gt 0 ] || ssm_die "No candidate users discovered on the instance."
  echo "Discovered users on ${INSTANCE_ID}:"
  PS3="Select the remote user to use: "
  select u in "${USERS[@]}"; do
    if [ -n "$u" ]; then REMOTE_USER="$u"; break; fi
    echo "Invalid selection, try again."
  done
fi
[ -n "$REMOTE_USER" ] || ssm_die "No remote user selected."

KEY_PATH=$(ssm_key_path "$INSTANCE_ID")
REUSE=0
if ssm_state_load "$INSTANCE_ID" 2>/dev/null && [ -f "$KEY_PATH" ] && [ -f "${KEY_PATH}.pub" ]; then
  REUSE=1
  ssm_log "Reusing existing key for ${INSTANCE_ID} (previously pushed at ${PUSHED_AT:-unknown} for user ${REMOTE_USER})."
else
  ssm_log "Generating new ed25519 keypair for ${INSTANCE_ID}..."
  mkdir -p "$(dirname "$KEY_PATH")"
  chmod 700 "$(dirname "$KEY_PATH")"
  rm -f "$KEY_PATH" "${KEY_PATH}.pub"
  ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -C "ssm-ssh-access-${INSTANCE_ID}-$(ssm_timestamp)" -q
fi

KEY_COMMENT=$(awk '{print $3}' "${KEY_PATH}.pub")
PUB_KEY_CONTENT=$(cat "${KEY_PATH}.pub")

if [ "$REUSE" -eq 0 ]; then
  ssm_log "Pushing public key to ${INSTANCE_ID} as ${REMOTE_USER}..."
  REMOTE_SCRIPT=$(cat <<EOS
U="${REMOTE_USER}"
HOME_DIR=\$(getent passwd "\$U" | cut -d: -f6)
if [ -z "\$HOME_DIR" ]; then HOME_DIR="/home/\$U"; fi
mkdir -p "\$HOME_DIR/.ssh"
touch "\$HOME_DIR/.ssh/authorized_keys"
grep -qF "${KEY_COMMENT}" "\$HOME_DIR/.ssh/authorized_keys" || echo "${PUB_KEY_CONTENT}" >> "\$HOME_DIR/.ssh/authorized_keys"
chmod 700 "\$HOME_DIR/.ssh"
chmod 600 "\$HOME_DIR/.ssh/authorized_keys"
chown -R "\$U":"\$U" "\$HOME_DIR/.ssh" || true
echo "PUSH_OK"
EOS
)
  PUSH_CMD_ID=$(ssm_send_shell_command "$PROFILE" "$INSTANCE_ID" "$REMOTE_SCRIPT")
  ssm_wait_command "$PROFILE" "$INSTANCE_ID" "$PUSH_CMD_ID" || ssm_die "Failed to push public key to ${INSTANCE_ID}."
  OUT=$(ssm_command_output "$PROFILE" "$INSTANCE_ID" "$PUSH_CMD_ID")
  [[ "$OUT" == *"PUSH_OK"* ]] || ssm_die "Key push did not confirm success. Output: ${OUT}"
  ssm_state_save "$INSTANCE_ID" "$REMOTE_USER" "$PROFILE" "$REGION" "$KEY_COMMENT"
fi

ssm_log "Configuring ~/.ssh/config for ${INSTANCE_ID}..."
ssm_ssh_config_upsert_block "$INSTANCE_ID" "$REMOTE_USER" "$KEY_PATH" "$PROFILE" "$REGION"

ssm_log "Ready. You can now run:"
ssm_log "  ssh ${INSTANCE_ID}"
ssm_log "  scp <file> ${INSTANCE_ID}:/path"
ssm_log "Remember to run scripts/revoke.sh --instance-id ${INSTANCE_ID} when you're done, if you don't want to reuse this key later."
