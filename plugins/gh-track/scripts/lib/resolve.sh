#!/usr/bin/env bash
# Map the current workspace to an issue number.
# Branch name is authoritative; recorded state is the fallback for
# branches that do not follow the convention (e.g. externally created
# worktrees).

resolve_issue() {
  local branch pattern
  branch=$(git branch --show-current 2>/dev/null || true)
  pattern=$(cfg .branchPattern)

  if [ -n "$branch" ] && [[ $branch =~ $pattern ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
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
  local n=$1 top
  top=$(git rev-parse --show-toplevel)
  state_set ".worktrees[\"$top\"] = $n"
}
