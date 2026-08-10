#!/usr/bin/env bash
# stage — swap the stage label and mirror the board Status.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=SCRIPTDIR/board.sh
. "$GHT_LIB/board.sh"

cmd_stage() {
  cfg_load
  slug_require
  local issue=${1:-} want=${2:-}
  require_number "$issue" "stage issue number"
  [ -n "$want" ] || die "stage requires a stage name (one of: $GHT_STAGES)" 2
  stage_set "$issue" "$want"
  printf 'stage set: #%s -> %s\n' "$issue" "$want"
}
