#!/usr/bin/env bash
# resolve — print the issue number for this workspace, or record one.
# key=value output, matching doctor, show and link.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/resolve.sh
. "$GHT_LIB/resolve.sh"

cmd_resolve() {
  cfg_load
  if [ "${1:-}" = "--set" ]; then
    [ -n "${2:-}" ] || die "resolve --set requires an issue number" 2
    require_number "$2" "resolve --set"
    resolve_remember "$2"
    printf 'issue=%s\n' "$2"
    return 0
  fi
  # resolve_issue dies with exit 3 when nothing resolves. Capture it into a
  # variable rather than interpolating $(resolve_issue) into printf: inside a
  # substitution used as an argument, that `exit` kills only the subshell and
  # the command still runs -- printing `issue=` and exiting 0.
  local issue rc=0
  issue=$(resolve_issue) || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  printf 'issue=%s\n' "$issue"
}
