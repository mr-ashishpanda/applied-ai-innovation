#!/usr/bin/env bash
# split — create a GitHub-native sub-issue under a parent for a spec's
# second-and-later plan. Kind inherits from the parent; stage starts at
# planned (the spec is already agreed -- that is what makes a split
# possible in the first place).

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=SCRIPTDIR/board.sh
. "$GHT_LIB/board.sh"
# shellcheck source=SCRIPTDIR/subissues.sh
. "$GHT_LIB/subissues.sh"

cmd_split() {
  cfg_load
  slug_require
  local issue=${1:-}
  require_number "$issue" "split issue number"
  shift
  local plan="" title="" size=""
  while [ $# -gt 0 ]; do
    case $1 in
      --plan) plan=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --size) size=${2:-}; shift 2 ;;
      *) die "split: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$plan" ] || die "split requires --plan PATH" 2
  [ -n "$title" ] || die "split requires --title TITLE" 2
  if [ -n "$size" ]; then
    size_valid "$size" || die "split --size must be one of: $GHT_SIZES" 2
  fi

  # Idempotency cache. This is a deliberately weaker guarantee than
  # rollup_apply's inputs (Task 2): state.json is local and git-ignored, so
  # losing it degrades to "a repeat split re-creates a duplicate sub-issue"
  # -- human-visible, one issue to close by hand -- never to a silently
  # corrupted rollup. The asymmetry is intentional: unlike a stage, a plan
  # path -> sub-issue mapping has no GitHub-durable equivalent to fall back
  # to at split time, because the new issue's body (which will eventually
  # carry the plan link) is written by the calling skill AFTER split
  # returns, not before.
  #
  # Keyed by "$issue:$plan", not by plan alone: two different parents can
  # split the same plan path without colliding on each other's sub-issue.
  # $plan is passed through --arg rather than interpolated into the jq
  # program text, so a plan path containing a double-quote cannot break the
  # filter or silently skip the cache write.
  local cache_key existing
  cache_key="$issue:$plan"
  existing=""
  if [ -f "$GHT_STATE" ]; then
    existing=$(jq -r --arg k "$cache_key" '.splits[$k] // empty' "$GHT_STATE" 2>/dev/null || true)
  fi
  if [ -n "$existing" ]; then
    printf '%s\n' "$existing"
    return 0
  fi

  local parent_labels kind
  parent_labels=$(issue_labels "$issue") \
    || die "cannot read labels for #$issue; refusing to create a sub-issue with an unknown kind" 6
  kind=$(printf '%s\n' "$parent_labels" | sed -n 's/^kind://p' | head -1)
  [ -n "$kind" ] || die "issue #$issue has no kind:* label; cannot create a sub-issue" 6

  local args="--label stage:planned --label kind:$kind"
  [ -n "$size" ] && args="$args --label size:$size"

  local url number
  # shellcheck disable=SC2086 # args is a deliberately word-split flag list
  url=$(gh issue create --repo "$GHT_SLUG" --title "$title" \
    --body "Captured by gh-track: sub-issue of #$issue. No spec yet -- plan is linked separately." \
    $args)
  number=${url##*/}
  case $number in
    ''|*[!0-9]*) die "issue create returned no issue url; refusing to link or board it (got: [$url])" 1 ;;
  esac

  # Print the number before touching the link or the board, same reasoning
  # as cmd_new: the issue exists either way, and a degraded link or board
  # write must cost only itself, never the caller's ability to capture the
  # number that was just created.
  printf '%s\n' "$number"

  sub_issue_link "$issue" "$number" \
    || warn "issue #$number created but not linked as a sub-issue of #$issue on GitHub"

  if [ -n "$(cfg .project)" ] && type board_status_set >/dev/null 2>&1; then
    board_status_set "$number" Todo \
      || warn "issue #$number created but not added to the board; labels are still correct"
    if [ -n "$size" ]; then
      board_size_set "$number" "$(size_to_field "$size")" \
        || warn "board Size not updated for #$number; labels are still correct"
    fi
  fi

  # Seed plan1:* from the parent's CURRENT stage, but only on the parent's
  # FIRST split -- a later split (plan 3, 4...) must never clobber a value
  # that direct `ghtrack stage <parent>` calls may have already advanced.
  if [ -z "$(printf '%s\n' "$parent_labels" | sed -n 's/^plan1://p' | head -1)" ]; then
    local parent_stage
    parent_stage=$(printf '%s\n' "$parent_labels" | sed -n 's/^stage://p' | head -1)
    [ -n "$parent_stage" ] && plan1_set "$issue" "$parent_stage"
  fi

  mkdir -p "$(dirname "$GHT_STATE")"
  [ -f "$GHT_STATE" ] || printf '%s' '{}' >"$GHT_STATE"
  local tmp="$GHT_STATE.tmp.$$"
  jq --arg k "$cache_key" --argjson n "$number" '.splits[$k] = $n' "$GHT_STATE" >"$tmp" \
    && mv "$tmp" "$GHT_STATE"
}
