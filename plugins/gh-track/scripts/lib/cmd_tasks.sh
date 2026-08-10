#!/usr/bin/env bash
# tasks — sync an issue body's checklist from a plan file.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/body.sh
. "$GHT_LIB/body.sh"
# shellcheck source=SCRIPTDIR/tasks.sh
. "$GHT_LIB/tasks.sh"

cmd_tasks() {
  cfg_load
  slug_require
  local issue=${1:-}
  require_number "$issue" "tasks issue number"
  shift
  local plan=""
  while [ $# -gt 0 ]; do
    case $1 in
      --plan) plan=${2:-}; shift 2 ;;
      *) die "tasks: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$plan" ] || die "tasks requires --plan FILE" 2

  local tmp
  tmp=$(mktemp -d)
  # This trap fires in the caller's scope, after cmd_tasks has returned and
  # its `local tmp` has gone out of scope. The trap body must therefore be
  # DOUBLE-quoted so `$tmp` expands NOW, at registration time, baking the
  # literal path into the trap string. A single-quoted body (`'rm -rf
  # "$tmp"'` or `'rm -rf "${tmp:-}"'`) defers expansion to fire time, when
  # $tmp is unset -- with set -u that either errors or (guarded) silently
  # expands to "", making `rm -rf ""` a no-op that leaks this directory.
  # shellcheck disable=SC2064 # intentional: expand $tmp now, not at fire time (see comment above).
  trap "rm -rf '$tmp'" EXIT

  body_get "$issue" >"$tmp/body.md"
  section_get "$tmp/body.md" "Tasks" | grep '^- \[' >"$tmp/old.md" || : >"$tmp/old.md"
  tasks_extract "$plan" >"$tmp/new.md"
  tasks_merge "$tmp/old.md" "$tmp/new.md" >"$tmp/merged.md"
  tasks_render "$tmp/merged.md" >"$tmp/section.md"
  section_replace "$tmp/body.md" "Tasks" "$tmp/section.md" >"$tmp/out.md"
  body_put "$issue" "$tmp/out.md"

  printf 'checklist synced: #%s (%s)\n' "$issue" "$(head -1 "$tmp/section.md")"
}
