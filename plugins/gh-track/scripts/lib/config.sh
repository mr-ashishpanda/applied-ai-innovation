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
#
# Known limitation: for the six keys below, `cfg KEY ''` cannot request an
# empty default — an explicitly empty DEFAULT is indistinguishable from an
# omitted one, so the built-in wins. No caller wants that, and the
# alternative ($# inspection) buys nothing today; revisit if one appears.
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

# repo_slug — print owner/name, or warn and return 1.
#
# This function must NEVER die: every call site is a `$(...)` substitution,
# where `exit` kills only the substitution subshell. The enclosing command
# then runs with an empty --repo and the subcommand reports success — a
# false success (the defect this replaced). Failure is signalled by exit
# status so `slug_require` can turn it into a real abort at top level.
repo_slug() {
  local slug
  slug=$(cfg .repo)
  if [ -z "$slug" ]; then
    slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  fi
  if [ -z "$slug" ]; then
    warn "cannot determine repo; set .repo in $GHT_CONFIG"
    return 1
  fi
  printf '%s' "$slug"
}

# slug_require — resolve the slug ONCE into GHT_SLUG, or abort.
#
# Called from a subcommand's top level, where a plain assignment's exit
# status is visible to `||` and to `set -e`; every library function then
# reads "$GHT_SLUG" instead of re-invoking `$(repo_slug)`. That both fixes
# the swallowed-die false success and removes the duplicate `gh repo view`
# calls a single subcommand used to make. An unset GHT_SLUG under `set -u`
# is a loud programming error, which is the intent.
slug_require() {
  GHT_SLUG=$(repo_slug) || die "cannot determine repo; refusing to act on an unknown repository" 6
}

repo_owner() { printf '%s' "${GHT_SLUG%%/*}"; }
repo_name() { printf '%s' "${GHT_SLUG##*/}"; }

# gh_host — hostname for building web URLs. Read from origin's URL so
# GitHub Enterprise Server installs get their own host rather than a
# hardcoded github.com; github.com is the fallback when origin is absent or
# unparseable. Derived from git config, so it costs no network round trip.
gh_host() {
  local url host
  url=$(git remote get-url origin 2>/dev/null || true)
  case $url in
    git@*:*) host=${url#git@}; host=${host%%:*} ;;
    ssh://*|https://*|http://*|git://*)
      host=${url#*://}; host=${host#*@}; host=${host%%/*}; host=${host%%:*} ;;
    *) host="" ;;
  esac
  [ -n "$host" ] || host="github.com"
  printf '%s' "$host"
}

# cfg_write JQ_ASSIGNMENT — update config.json atomically, creating it first.
cfg_write() {
  mkdir -p "$(dirname "$GHT_CONFIG")"
  [ -f "$GHT_CONFIG" ] || printf '%s' '{}' >"$GHT_CONFIG"
  local tmp="$GHT_CONFIG.tmp.$$"
  jq "$1" "$GHT_CONFIG" >"$tmp" && mv "$tmp" "$GHT_CONFIG"
}
