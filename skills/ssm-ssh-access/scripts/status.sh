#!/usr/bin/env bash
# scripts/status.sh — list instance-ids that currently have a live pushed key.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

SSM_SSH_ROOT="${HOME}/.ssh/ssm-ssh-access"

if [ ! -d "$SSM_SSH_ROOT" ] || [ -z "$(ls -A "$SSM_SSH_ROOT" 2>/dev/null)" ]; then
  echo "No ssm-ssh-access keys currently deployed."
  exit 0
fi

printf '%-20s %-15s %-25s\n' "INSTANCE_ID" "REMOTE_USER" "PUSHED_AT"
for dir in "$SSM_SSH_ROOT"/*/; do
  state_file="${dir}state.env"
  [ -f "$state_file" ] || continue
  ( # shellcheck disable=SC1090
    source "$state_file"
    printf '%-20s %-15s %-25s\n' "$INSTANCE_ID" "$REMOTE_USER" "$PUSHED_AT"
  )
done
