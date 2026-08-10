#!/usr/bin/env bash
# link — push the branch and print artifact URLs for a spec or plan.
# Output is key=value lines so the calling skill can use them directly.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/links.sh
. "$GHT_LIB/links.sh"

cmd_link() {
  cfg_load
  slug_require
  local issue=${1:-}
  require_number "$issue" "link issue number"
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

  # Normalise before building anything: these URLs become the permanent
  # record in an issue comment, so a path that merely resolves from the
  # caller's cwd must not be turned into a confident 404.
  path=$(link_root_relative "$path") \
    || die "link --path must name a file inside the repository" 2

  local pushed=yes
  link_push || pushed=no

  # One call, two lines -- link_urls runs git and reads config, so calling
  # it twice doubled the subprocess work for identical output.
  local urls head_url pin_url
  urls=$(link_urls "$path")
  head_url=$(printf '%s\n' "$urls" | sed -n 1p)
  pin_url=$(printf '%s\n' "$urls" | sed -n 2p)

  # Without a successful push these URLs resolve to nothing on GitHub.
  # Degradation is a plain path, not a confident-looking dead link.
  if [ "$pushed" = no ]; then
    head_url=""
    pin_url=""
  fi

  printf 'kind=%s\n' "$kind"
  printf 'path=%s\n' "$path"
  printf 'pushed=%s\n' "$pushed"
  printf 'sha=%s\n' "$(link_sha "$path")"
  printf 'head_url=%s\n' "$head_url"
  printf 'pinned_url=%s\n' "$pin_url"
}
