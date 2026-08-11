#!/usr/bin/env bash
# Sub-issues: GitHub-native parent/child links for a spec's second-and-later
# plan, plus the parent stage rollup that reads them.
#
# issue_parent_number and issue_sub_issue_numbers read GitHub directly rather
# than caching the relationship in state.json: state.json is git-ignored, and
# a fresh clone or a fresh subagent worktree must still compute a correct
# rollup without it. GitHub's own sub_issues/parent endpoints are the durable
# source gh-track already trusts everywhere else for canonical state.

# issue_parent_number N — the parent's issue number, or empty. Verified live
# against the real API: a 404 (no parent) makes `gh api` exit non-zero
# WITHOUT applying --jq, so a failed read and a genuine "no parent" are
# indistinguishable from here -- which is fine, because both mean the same
# thing to every caller: there is nothing to roll up to right now.
issue_parent_number() {
  gh api "repos/$GHT_SLUG/issues/$1/parent" --jq '.number' 2>/dev/null
}

# issue_sub_issue_numbers N — one child issue number per line, or empty when
# N has no sub-issues (a real, successful empty list -- verified live).
issue_sub_issue_numbers() {
  gh api "repos/$GHT_SLUG/issues/$1/sub_issues" --jq '.[].number' 2>/dev/null
}

# sub_issue_link PARENT CHILD — link CHILD as a GitHub-native sub-issue of
# PARENT. Never dies: CHILD already exists as a real issue by the time this
# runs (cmd_split creates it first), so a failed link degrades to "no
# progress-bar rollup in GitHub's own UI", never to a failed issue creation.
# The REST endpoint wants CHILD's numeric database id, not its GraphQL node
# id -- `gh issue view --json id` returns the latter, so the id must come
# from `gh api .../issues/N` instead (verified live against the real API).
sub_issue_link() {
  local parent=$1 child=$2 cid
  cid=$(gh api "repos/$GHT_SLUG/issues/$child" --jq '.id' 2>/dev/null) || true
  [ -n "$cid" ] || { warn "cannot resolve #$child's id; not linked as a sub-issue of #$parent"; return 1; }
  gh api -X POST "repos/$GHT_SLUG/issues/$parent/sub_issues" \
    -F sub_issue_id="$cid" >/dev/null 2>&1 \
    || { warn "cannot link #$child as a sub-issue of #$parent"; return 1; }
  return 0
}

# Rank for comparing stages in the rollup's min(). Restricted to the stages a
# split sub-issue or its parent can actually be in post-split
# (planned/building/review/done): a split only happens once plan 1's spec is
# already agreed, so backlog/spec/triage/debugging cannot recur here. Any
# other input -- including empty, which is what a failed issue_stage read
# yields -- maps to rank 0, the conservative direction: it can only ever pull
# the rollup DOWN, never wrongly advance the parent past a stage nothing has
# proven it reached.
rollup_stage_rank() {
  case $1 in
    planned) printf 0 ;;
    building) printf 1 ;;
    review) printf 2 ;;
    "done") printf 3 ;;
    *) printf 0 ;;
  esac
}

# rollup_stage_from_rank RANK — the stage a rank maps back to. Rank 0 maps to
# building, never planned: the floor below always wins before this is ever
# called with an unfloored 0, so 0 as an OUTPUT never actually occurs, but the
# safe default here still matches the floor rather than under-reporting.
rollup_stage_from_rank() {
  case $1 in
    0|1) printf building ;;
    2) printf review ;;
    3) printf "done" ;;
    *) printf building ;;
  esac
}

# rollup_apply PARENT CHILDREN — recompute PARENT's stage as
# min(plan 1's own stage, every child's stage), floored at building, and
# write it with the ordinary stage_set (label + board, unchanged). CHILDREN
# is a space-separated list of issue numbers, already resolved by the caller.
# Best-effort: never dies. Returns 1 if unable to read the parent's current
# labels (stage_set would need them), after which the whole write is skipped.
rollup_apply() {
  local parent=$1 children=$2 plan1 c min_rank cur_rank floor_rank target

  # Guard: ensure the parent's labels are readable before calling stage_set.
  # stage_set would die if this fails, so we catch it early and return 1.
  issue_labels "$parent" >/dev/null || {
    warn "cannot read labels for issue #$parent; skipping rollup"
    return 1
  }

  plan1=$(issue_plan1_stage "$parent")
  [ -n "$plan1" ] || plan1=$(issue_stage "$parent")
  min_rank=$(rollup_stage_rank "$plan1")

  for c in $children; do
    cur_rank=$(rollup_stage_rank "$(issue_stage "$c")")
    [ "$cur_rank" -lt "$min_rank" ] && min_rank=$cur_rank
  done

  floor_rank=$(rollup_stage_rank building)
  [ "$min_rank" -lt "$floor_rank" ] && min_rank=$floor_rank

  target=$(rollup_stage_from_rank "$min_rank")
  stage_set "$parent" "$target"
}
