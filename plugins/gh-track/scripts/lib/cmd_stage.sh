#!/usr/bin/env bash
# stage — swap the stage label and mirror the board Status. If this issue is
# a split parent or a sub-issue of one, also recompute the parent's rolled-up
# stage: min(plan 1's own stage, every sub-issue's stage), floored at
# building. See subissues.sh for the rollup itself.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=SCRIPTDIR/board.sh
. "$GHT_LIB/board.sh"
# shellcheck source=SCRIPTDIR/subissues.sh
. "$GHT_LIB/subissues.sh"

cmd_stage() {
  cfg_load
  slug_require
  local issue=${1:-} want=${2:-}
  require_number "$issue" "stage issue number"
  [ -n "$want" ] || die "stage requires a stage name (one of: $GHT_STAGES)" 2
  stage_set "$issue" "$want"

  # I am a split parent: this direct call is plan 1's own stage advancing.
  # Record it durably, then let the rollup decide what the LABEL should
  # actually show once every sub-issue is accounted for.
  local children
  children=$(issue_sub_issue_numbers "$issue") || children=""
  if [ -n "$children" ]; then
    plan1_set "$issue" "$want"
    rollup_apply "$issue" "$children" \
      || warn "stage rollup not recomputed for #$issue"
  fi

  # I am a sub-issue: my own stage just changed, so my parent's rollup may
  # need to move too.
  local parent
  parent=$(issue_parent_number "$issue") || parent=""
  if [ -n "$parent" ]; then
    local siblings
    siblings=$(issue_sub_issue_numbers "$parent") || siblings=""
    rollup_apply "$parent" "$siblings" \
      || warn "parent #$parent's rolled-up stage not updated"
  fi

  printf 'stage set: #%s -> %s\n' "$issue" "$want"
}
