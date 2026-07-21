#!/usr/bin/env bash
# scripts/revoke.sh — remove a previously-pushed key from the instance and clean up locally.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") --instance-id <id> [--profile <aws-profile>]

Removes the ssm-ssh-access key from the instance's authorized_keys, deletes the
local keypair + state, and removes the ~/.ssh/config block for <id>.
EOF
}

INSTANCE_ID=""; PROFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; ssm_die "Unknown argument: $1" ;;
  esac
done

[ -n "$INSTANCE_ID" ] || { usage; ssm_die "--instance-id is required"; }

ssm_require_cli

if ! ssm_state_load "$INSTANCE_ID"; then
  ssm_log "No local state for ${INSTANCE_ID}; nothing to revoke remotely. Cleaning up any leftover local files/config anyway."
else
  # PROFILE from the command line wins; ssm_state_load already left the saved
  # PROFILE in place if none was passed on the command line.
  ssm_log "Removing pushed key (${KEY_COMMENT}) from ${INSTANCE_ID} as ${REMOTE_USER}..."
  REMOTE_SCRIPT=$(cat <<EOS
U="${REMOTE_USER}"
HOME_DIR=\$(getent passwd "\$U" | cut -d: -f6)
if [ -z "\$HOME_DIR" ]; then HOME_DIR="/home/\$U"; fi
if [ -f "\$HOME_DIR/.ssh/authorized_keys" ]; then
  grep -vF "${KEY_COMMENT}" "\$HOME_DIR/.ssh/authorized_keys" > "\$HOME_DIR/.ssh/authorized_keys.tmp" || true
  mv "\$HOME_DIR/.ssh/authorized_keys.tmp" "\$HOME_DIR/.ssh/authorized_keys"
fi
echo "REVOKE_OK"
EOS
)
  CMD_ID=$(ssm_send_shell_command "$PROFILE" "$INSTANCE_ID" "$REMOTE_SCRIPT")
  if ssm_wait_command "$PROFILE" "$INSTANCE_ID" "$CMD_ID"; then
    OUT=$(ssm_command_output "$PROFILE" "$INSTANCE_ID" "$CMD_ID")
    if [[ "$OUT" == *"REVOKE_OK"* ]]; then
      ssm_log "Remote key removed."
    else
      ssm_log "WARNING: remote cleanup output unexpected: ${OUT}"
    fi
  else
    ssm_log "WARNING: could not confirm remote key removal (instance may be unreachable). Local cleanup will continue."
  fi
fi

ssm_log "Removing local key material and state for ${INSTANCE_ID}..."
rm -rf "$(ssm_instance_dir "$INSTANCE_ID")"

ssm_log "Removing ~/.ssh/config block for ${INSTANCE_ID}..."
ssm_ssh_config_remove_block "$INSTANCE_ID"

ssm_log "Done. ${INSTANCE_ID} has been fully revoked."
