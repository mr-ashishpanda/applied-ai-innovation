#!/usr/bin/env bash
# tick — mark one checklist item complete in an issue body.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/body.sh
. "$GHT_LIB/body.sh"
# shellcheck source=SCRIPTDIR/tasks.sh
. "$GHT_LIB/tasks.sh"

cmd_tick() {
  cfg_load
  slug_require
  local issue=${1:-}
  require_number "$issue" "tick issue number"
  shift
  local task=""
  while [ $# -gt 0 ]; do
    case $1 in
      --task) task=${2:-}; shift 2 ;;
      *) die "tick: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$task" ] || die "tick requires --task K" 2
  require_number "$task" "tick --task"

  local tmp
  tmp=$(mktemp -d)
  # This trap fires in the caller's scope, after cmd_tick has returned and
  # its `local tmp` has gone out of scope. The trap body must therefore be
  # DOUBLE-quoted so `$tmp` expands NOW, at registration time, baking the
  # literal path into the trap string. A single-quoted body (`'rm -rf
  # "$tmp"'` or `'rm -rf "${tmp:-}"'`) defers expansion to fire time, when
  # $tmp is unset -- with set -u that either errors or (guarded) silently
  # expands to "", making `rm -rf ""` a no-op that leaks this directory.
  # shellcheck disable=SC2064 # intentional: expand $tmp now, not at fire time (see comment above).
  trap "rm -rf '$tmp'" EXIT

  body_get "$issue" >"$tmp/body.md"
  section_get "$tmp/body.md" "Tasks" | grep '^- \[' >"$tmp/lines.md" \
    || die "issue #$issue has no task checklist; run: ghtrack tasks $issue --plan FILE" 5
  tasks_tick "$tmp/lines.md" "$task" >"$tmp/ticked.md"
  tasks_render "$tmp/ticked.md" >"$tmp/section.md"
  section_replace "$tmp/body.md" "Tasks" "$tmp/section.md" >"$tmp/out.md"
  body_put "$issue" "$tmp/out.md"

  printf 'ticked: #%s task %s (%s)\n' "$issue" "$task" "$(head -1 "$tmp/section.md")"
}
