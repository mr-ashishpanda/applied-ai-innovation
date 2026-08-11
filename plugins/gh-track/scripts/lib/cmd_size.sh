#!/usr/bin/env bash
# size — swap the size label and mirror the board's Size field.
#
# Sizing happens at the plan checkpoint, once task count and critical path
# make the estimate meaningful, so it is a separate subcommand rather than a
# flag on `new`: the issue being sized already exists.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=SCRIPTDIR/board.sh
. "$GHT_LIB/board.sh"

cmd_size() {
  cfg_load
  slug_require
  local issue=${1:-} want=${2:-}
  require_number "$issue" "size issue number"
  [ -n "$want" ] || die "size requires a size (one of: $GHT_SIZES)" 2
  size_set "$issue" "$want"
  printf 'size set: #%s -> %s\n' "$issue" "$want"
}
