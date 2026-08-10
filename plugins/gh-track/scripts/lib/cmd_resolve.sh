#!/usr/bin/env bash
# resolve — print the issue number for this workspace, or record one.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/resolve.sh
. "$GHT_LIB/resolve.sh"

cmd_resolve() {
  cfg_load
  if [ "${1:-}" = "--set" ]; then
    [ -n "${2:-}" ] || die "resolve --set requires an issue number" 2
    resolve_remember "$2"
    printf '%s\n' "$2"
    return 0
  fi
  resolve_issue
  printf '\n'
}
