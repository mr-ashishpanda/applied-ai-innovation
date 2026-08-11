#!/usr/bin/env bash
# body — read the current issue body, or replace it wholesale from a
# rendered file. Read mode is the sanctioned way to see what a section this
# command doesn't own currently contains before rewriting the body, since
# body_put is a full replace, not a patch.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/body.sh
. "$GHT_LIB/body.sh"

cmd_body() {
  cfg_load
  slug_require
  local issue=${1:-}
  require_number "$issue" "body issue number"
  shift
  local file=""
  while [ $# -gt 0 ]; do
    case $1 in
      --file) file=${2:-}; shift 2 ;;
      *) die "body: unexpected argument: $1" 2 ;;
    esac
  done
  if [ -z "$file" ]; then
    body_get "$issue"
    return 0
  fi
  [ -f "$file" ] || die "no such file: $file" 2
  body_put "$issue" "$file"
  printf 'body updated: #%s\n' "$issue"
}
