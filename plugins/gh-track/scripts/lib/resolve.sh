#!/usr/bin/env bash
# Map the current workspace to an issue number.
# Branch name is authoritative; recorded state is the fallback for
# branches that do not follow the convention (e.g. externally created
# worktrees) -- EXCEPT on a configured shared/integration branch (main,
# v2, ...), which never uses that fallback at all. See is_shared_branch.

# is_shared_branch BRANCH — true iff BRANCH is one of the repo's configured
# long-lived integration branches (`.sharedBranches`, a JSON array; default
# ["main","master"] when unset).
#
# Why this exists: the recorded-state fallback is keyed by the checkout's
# PATH, not its branch, and is meant for a worktree whose branch happens not
# to match the naming convention. A shared branch's checked-out content
# changes constantly as unrelated work merges into it, so a path-keyed pin
# recorded once there (often before "always use a dedicated worktree" was
# the habit) silently outlives the work it was recorded for. Concretely
# observed: a repo's main checkout was `--set` for one early issue; every
# session afterward that started there before a task-specific worktree
# existed reported that SAME issue as "the current work" -- including
# months later, on completely unrelated tasks, after that issue had long
# since closed. An ad-hoc one-off branch name (`spike/no-number`) is NOT a
# shared branch and keeps using the fallback below, unchanged.
is_shared_branch() {
  local branch=$1 hit
  [ -n "$branch" ] || return 1
  hit=$(jq -r --arg b "$branch" \
    '(.sharedBranches // ["main","master"]) | index($b) // empty' \
    "$GHT_CONFIG" 2>/dev/null || true)
  [ -n "$hit" ]
}

resolve_issue() {
  local branch pattern
  branch=$(git branch --show-current 2>/dev/null || true)
  pattern=$(cfg .branchPattern)

  if [ -n "$branch" ] && [[ $branch =~ $pattern ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  if is_shared_branch "$branch"; then
    die "no single issue is tracked on shared branch '$branch'; create a dedicated worktree (<issue>-<slug>) for the next tracked task" 3
  fi

  local top recorded
  top=$(git rev-parse --show-toplevel)
  recorded=$(state_get ".worktrees[\"$top\"]")
  if [ -n "$recorded" ]; then
    printf '%s' "$recorded"
    return 0
  fi

  die "cannot resolve issue for branch ${branch:-<detached>}; run: ghtrack resolve --set N" 3
}

resolve_remember() {
  local n=$1 top branch
  branch=$(git branch --show-current 2>/dev/null || true)
  if is_shared_branch "$branch"; then
    die "refusing to pin issue #$n to shared branch '$branch' -- this mapping is keyed by the checkout's PATH and would apply to every future branch here that doesn't match the naming pattern, including unrelated work. Create a dedicated worktree for this issue and run --set there instead." 2
  fi
  top=$(git rev-parse --show-toplevel)
  state_set ".worktrees[\"$top\"] = $n"
}

# resolve_forget — remove this workspace's recorded mapping, if any. The
# symmetric undo for resolve_remember/--set: previously the only way to fix
# a bad pin was to hand-edit state.json directly.
resolve_forget() {
  local top
  top=$(git rev-parse --show-toplevel)
  state_set "del(.worktrees[\"$top\"])"
}
