#!/usr/bin/env bash
# scripts/lib/common.sh — shared helpers for the ssm-ssh-access skill (macOS/Linux)
set -euo pipefail

SSM_SSH_ROOT="${HOME}/.ssh/ssm-ssh-access"

ssm_log()  { printf '[ssm-ssh-access] %s\n' "$*" >&2; }
ssm_die()  { ssm_log "ERROR: $*"; exit 1; }

ssm_require_cli() {
  local missing=()
  command -v aws >/dev/null 2>&1 || missing+=("aws (AWS CLI v2)")
  command -v session-manager-plugin >/dev/null 2>&1 || missing+=("session-manager-plugin")
  command -v ssh-keygen >/dev/null 2>&1 || missing+=("ssh-keygen")
  if [ "${#missing[@]}" -gt 0 ]; then
    ssm_log "Missing required tools:"
    for m in "${missing[@]}"; do ssm_log "  - $m"; done
    ssm_die "Run scripts/install-plugin.sh first, then retry."
  fi
}

ssm_instance_dir() { printf '%s/%s' "$SSM_SSH_ROOT" "$1"; }
ssm_state_file()   { printf '%s/state.env' "$(ssm_instance_dir "$1")"; }
ssm_key_path()      { printf '%s/id_ed25519' "$(ssm_instance_dir "$1")"; }

ssm_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

ssm_state_load() {
  local f; f=$(ssm_state_file "$1")
  [ -f "$f" ] || return 1
  # shellcheck disable=SC1090
  source "$f"
}

ssm_state_save() {
  local id="$1" user="$2" profile="$3" region="$4" comment="$5"
  local dir; dir=$(ssm_instance_dir "$id")
  mkdir -p "$dir"
  chmod 700 "$dir"
  local f; f=$(ssm_state_file "$id")
  {
    printf 'INSTANCE_ID=%q\n' "$id"
    printf 'REMOTE_USER=%q\n' "$user"
    printf 'PROFILE=%q\n' "$profile"
    printf 'REGION=%q\n' "$region"
    printf 'KEY_COMMENT=%q\n' "$comment"
    printf 'PUSHED_AT=%q\n' "$(ssm_timestamp)"
  } > "$f"
  chmod 600 "$f"
}

ssm_aws() {
  local profile="$1"; shift
  if [ -n "$profile" ]; then
    aws --profile "$profile" "$@"
  else
    aws "$@"
  fi
}

ssm_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

ssm_send_shell_command() {
  # args: profile instance_id script_body(may be multi-line) -> prints command-id
  local profile="$1" instance_id="$2" script="$3"
  local tmp; tmp=$(mktemp)
  {
    printf '{"commands":['
    local first=1 line
    while IFS= read -r line; do
      [ "$first" -eq 1 ] || printf ','
      printf '"%s"' "$(ssm_json_escape "$line")"
      first=0
    done <<< "$script"
    printf ']}'
  } > "$tmp"
  local cmd_id
  cmd_id=$(ssm_aws "$profile" ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "file://${tmp}" \
    --query 'Command.CommandId' --output text)
  rm -f "$tmp"
  printf '%s' "$cmd_id"
}

ssm_wait_command() {
  # args: profile instance_id command_id
  local profile="$1" instance_id="$2" command_id="$3" status
  for _ in $(seq 1 30); do
    status=$(ssm_aws "$profile" ssm get-command-invocation \
      --instance-id "$instance_id" --command-id "$command_id" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
    case "$status" in
      Success) return 0 ;;
      Failed|Cancelled|TimedOut) return 1 ;;
      *) sleep 2 ;;
    esac
  done
  return 1
}

ssm_command_output() {
  local profile="$1" instance_id="$2" command_id="$3"
  ssm_aws "$profile" ssm get-command-invocation \
    --instance-id "$instance_id" --command-id "$command_id" \
    --query 'StandardOutputContent' --output text
}

ssm_ssh_config_path() { printf '%s/.ssh/config' "$HOME"; }

ssm_ssh_config_remove_block() {
  local id="$1" cfg; cfg=$(ssm_ssh_config_path)
  [ -f "$cfg" ] || return 0
  local tmp; tmp=$(mktemp)
  awk -v id="$id" '
    $0 == "# BEGIN ssm-ssh-access " id { skip=1; next }
    $0 == "# END ssm-ssh-access " id { skip=0; next }
    skip != 1 { print }
  ' "$cfg" > "$tmp"
  mv "$tmp" "$cfg"
}

ssm_ssh_config_upsert_block() {
  local id="$1" user="$2" key_path="$3" profile="$4" region="$5"
  local cfg; cfg=$(ssm_ssh_config_path)
  mkdir -p "$(dirname "$cfg")"
  touch "$cfg"
  chmod 600 "$cfg"
  ssm_ssh_config_remove_block "$id"
  local proxy="aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p"
  [ -n "$profile" ] && proxy="${proxy} --profile ${profile}"
  [ -n "$region" ] && proxy="${proxy} --region ${region}"
  # Prepended, not appended: ssh resolves ProxyCommand/User/IdentityFile by
  # first match in file order, so our specific Host block must come before
  # any pre-existing generic "Host i-*"/"Host mi-*" block or it's ignored.
  local tmp; tmp=$(mktemp)
  {
    echo "# BEGIN ssm-ssh-access ${id}"
    echo "Host ${id}"
    echo "  User ${user}"
    echo "  IdentityFile ${key_path}"
    echo "  ProxyCommand ${proxy}"
    echo "  StrictHostKeyChecking accept-new"
    echo "# END ssm-ssh-access ${id}"
    cat "$cfg"
  } > "$tmp"
  mv "$tmp" "$cfg"
}
