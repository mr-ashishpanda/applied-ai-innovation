#!/usr/bin/env bash
# close — close the GitHub issue itself. The done checkpoint's own
# procedure (SKILL.md) already covers `stage N done`, rewriting body links,
# and posting the `done` comment; closing the issue was the one remaining
# step with no CLI command, so completing it meant a hand-rolled `gh issue
# close` call — which CLAUDE.md-style tracking discipline forbids ("every
# GitHub write goes through ghtrack"). This closes that gap.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"

cmd_close() {
  cfg_load
  slug_require
  local issue=${1:-}
  require_number "$issue" "close issue number"
  shift

  local reason="completed"
  while [ $# -gt 0 ]; do
    case $1 in
      --reason) reason=${2:-}; shift 2 ;;
      *) die "close: unexpected argument: $1" 2 ;;
    esac
  done
  case $reason in
    completed|"not planned") : ;;
    *) die 'close --reason must be "completed" or "not planned"' 2 ;;
  esac

  local state
  state=$(gh issue view "$issue" --repo "$GHT_SLUG" --json state --jq .state 2>/dev/null) \
    || die "cannot read issue #$issue"
  if [ "$state" = "CLOSED" ]; then
    printf 'already closed: #%s\n' "$issue"
    return 0
  fi

  # A soft guard, not a block: closing at any stage is a legitimate call
  # (e.g. "not planned" on a backlog item nobody will build), so a stage
  # other than done only warns — the same warn-don't-block discipline
  # stage_set and the board writes already follow elsewhere in this tool.
  local stage
  stage=$(issue_stage "$issue") || stage=""
  if [ "$reason" = "completed" ] && [ "$stage" != "done" ]; then
    warn "issue #$issue is at stage:${stage:-<unset>}, not stage:done - closing anyway (run 'ghtrack stage $issue done' first if that was unintentional)"
  fi

  gh issue close "$issue" --repo "$GHT_SLUG" --reason "$reason" >/dev/null \
    || die "cannot close issue #$issue"

  printf 'closed: #%s (%s)\n' "$issue" "$reason"
}
