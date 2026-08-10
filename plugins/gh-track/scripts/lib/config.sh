#!/usr/bin/env bash
# Config and state. Knows nothing about issues — only where settings live.

cfg_load() {
  need_cmd git
  need_cmd jq
  GHT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside a git repository"
  GHT_CONFIG="$GHT_ROOT/.claude/gh-track/config.json"
  GHT_STATE="$GHT_ROOT/.claude/gh-track/state.json"
  export GHT_ROOT GHT_CONFIG GHT_STATE
}

# cfg KEY [DEFAULT] — dotted jq key. Built-in defaults apply when the key is
# absent and no explicit default is given.
cfg() {
  local key=$1 default=${2:-}
  if [ -z "$default" ]; then
    case $key in
      .specGlob) default="docs/superpowers/specs/**/*.md" ;;
      .planGlob) default="docs/superpowers/plans/**/*.md" ;;
      .taskHeadingPattern) default="^### Task ([0-9]+):" ;;
      .branchPattern) default="^([0-9]+)-" ;;
      .board.statusField) default="Status" ;;
      .board.sizeField) default="Size" ;;
    esac
  fi
  json_get "$GHT_CONFIG" "$key" "$default"
}

state_get() { json_get "$GHT_STATE" "$1" "${2:-}"; }

# state_set JQ_ASSIGNMENT — e.g. state_set '.worktrees["/p"] = 42'
state_set() {
  mkdir -p "$(dirname "$GHT_STATE")"
  [ -f "$GHT_STATE" ] || printf '%s' '{}' >"$GHT_STATE"
  local tmp="$GHT_STATE.tmp.$$"
  jq "$1" "$GHT_STATE" >"$tmp" && mv "$tmp" "$GHT_STATE"
}

repo_slug() {
  local slug
  slug=$(cfg .repo)
  if [ -n "$slug" ]; then printf '%s' "$slug"; return 0; fi
  slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  [ -n "$slug" ] || die "cannot determine repo; set .repo in $GHT_CONFIG"
  printf '%s' "$slug"
}

repo_owner() { repo_slug | cut -d/ -f1; }
repo_name() { repo_slug | cut -d/ -f2; }
