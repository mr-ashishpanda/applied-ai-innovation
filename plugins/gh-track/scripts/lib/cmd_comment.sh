#!/usr/bin/env bash
# comment — post or edit a marked checkpoint comment.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/comment.sh
. "$GHT_LIB/comment.sh"

cmd_comment() {
  cfg_load
  local issue=${1:-}
  [ -n "$issue" ] || die "comment requires an issue number" 2
  shift
  local event="" file="" sha=""
  while [ $# -gt 0 ]; do
    case $1 in
      --event) event=${2:-}; shift 2 ;;
      --file) file=${2:-}; shift 2 ;;
      --sha) sha=${2:-}; shift 2 ;;
      *) die "comment: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$event" ] || die "comment requires --event EVENT" 2
  [ -n "$file" ] || die "comment requires --file FILE" 2
  [ -n "$sha" ] || sha=$(git rev-parse --short HEAD)

  local result
  result=$(comment_upsert "$issue" "$event" "$sha" "$file")
  printf 'comment %s: #%s %s@%s\n' "$result" "$issue" "$event" "$sha"
}
