#!/usr/bin/env bash
# link — push the branch and print artifact URLs for a spec or plan.
# Output is key=value lines so the calling skill can use them directly.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/links.sh
. "$GHT_LIB/links.sh"

cmd_link() {
  cfg_load
  local issue=${1:-}
  [ -n "$issue" ] || die "link requires an issue number" 2
  shift
  local kind="" path=""
  while [ $# -gt 0 ]; do
    case $1 in
      --kind) kind=${2:-}; shift 2 ;;
      --path) path=${2:-}; shift 2 ;;
      *) die "link: unexpected argument: $1" 2 ;;
    esac
  done
  case $kind in
    spec|plan) : ;;
    *) die "link --kind must be spec or plan" 2 ;;
  esac
  [ -n "$path" ] || die "link requires --path PATH" 2
  [ -f "$GHT_ROOT/$path" ] || [ -f "$path" ] || die "no such file: $path" 2

  local pushed=yes
  link_push || pushed=no

  local head_url pin_url
  head_url=$(link_urls "$path" | sed -n 1p)
  pin_url=$(link_urls "$path" | sed -n 2p)

  printf 'kind=%s\n' "$kind"
  printf 'path=%s\n' "$path"
  printf 'pushed=%s\n' "$pushed"
  printf 'sha=%s\n' "$(link_sha "$path")"
  printf 'head_url=%s\n' "$head_url"
  printf 'pinned_url=%s\n' "$pin_url"
}
