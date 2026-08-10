#!/usr/bin/env bash
# body — replace an issue body wholesale from a rendered file.

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
  [ -n "$file" ] || die "body requires --file FILE" 2
  [ -f "$file" ] || die "no such file: $file" 2
  body_put "$issue" "$file"
  printf 'body updated: #%s\n' "$issue"
}
