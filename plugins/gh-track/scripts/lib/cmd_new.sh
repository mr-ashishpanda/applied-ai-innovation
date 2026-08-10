#!/usr/bin/env bash
# new — create an issue at stage:backlog. Prints only the issue number so
# callers can capture it directly.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"

cmd_new() {
  cfg_load
  slug_require
  local kind="" title="" bodyfile="" size=""
  while [ $# -gt 0 ]; do
    case $1 in
      --kind) kind=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --body-file) bodyfile=${2:-}; shift 2 ;;
      --size) size=${2:-}; shift 2 ;;
      *) die "new: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$kind" ] || die "new requires --kind feature|bug|chore" 2
  kind_valid "$kind" || die "new --kind must be one of: $GHT_KINDS" 2
  [ -n "$title" ] || die "new requires --title TITLE" 2

  local args="--label stage:backlog --label kind:$kind"
  if [ -n "$size" ]; then
    case " $GHT_SIZES " in
      *" $size "*) args="$args --label size:$size" ;;
      *) die "new --size must be one of: $GHT_SIZES" 2 ;;
    esac
  fi

  local url
  if [ -n "$bodyfile" ]; then
    [ -f "$bodyfile" ] || die "no such file: $bodyfile" 2
    # shellcheck disable=SC2086 # args is a deliberately word-split flag list
    url=$(gh issue create --repo "$GHT_SLUG" --title "$title" \
      --body-file "$bodyfile" $args)
  else
    # shellcheck disable=SC2086 # args is a deliberately word-split flag list
    url=$(gh issue create --repo "$GHT_SLUG" --title "$title" \
      --body "Captured by gh-track. No spec yet." $args)
  fi

  printf '%s\n' "${url##*/}"
}
