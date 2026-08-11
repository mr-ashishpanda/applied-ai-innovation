#!/usr/bin/env bash
# resolve — print the issue number for this workspace, or record one.
#
# Output is a BARE number, by design: this is a single-value accessor, the
# analogue of `git rev-parse`, and it exists to be captured with $(...) --
# `issue=$("$ghtrack" resolve 2>/dev/null) || exit 0` is the specified shape
# for plan 2's hook scripts. A `key=value` line would break every call site.
# Do not "make it consistent" with show/link/doctor; those are multi-field.

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
    printf '%s\n' "$2"
    return 0
  fi
  # resolve_issue dies with exit 3 when nothing resolves. Assign FIRST, then
  # print: interpolating $(resolve_issue) straight into printf would confine
  # that `exit` to the substitution subshell, so printf would still run and
  # the subcommand would emit an empty line and exit 0. A plain assignment's
  # status is visible, so the failure propagates with its code intact and
  # stdout stays empty.
  local issue rc=0
  issue=$(resolve_issue) || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  printf '%s\n' "$issue"
}
