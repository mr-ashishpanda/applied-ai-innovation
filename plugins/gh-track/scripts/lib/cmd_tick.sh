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
  local issue=${1:-}
  [ -n "$issue" ] || die "tick requires an issue number" 2
  shift
  local task=""
  while [ $# -gt 0 ]; do
    case $1 in
      --task) task=${2:-}; shift 2 ;;
      *) die "tick: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$task" ] || die "tick requires --task K" 2

  local tmp
  tmp=$(mktemp -d)
  # ${tmp:-} guards against "unbound variable": this trap is registered
  # inside the function but fires in the caller's scope, where the
  # function-local $tmp no longer exists once cmd_tick has returned.
  trap 'rm -rf "${tmp:-}"' EXIT

  body_get "$issue" >"$tmp/body.md"
  section_get "$tmp/body.md" "Tasks" | grep '^- \[' >"$tmp/lines.md" \
    || die "issue #$issue has no task checklist; run: ghtrack tasks $issue --plan FILE" 5
  tasks_tick "$tmp/lines.md" "$task" >"$tmp/ticked.md"
  tasks_render "$tmp/ticked.md" >"$tmp/section.md"
  section_replace "$tmp/body.md" "Tasks" "$tmp/section.md" >"$tmp/out.md"
  body_put "$issue" "$tmp/out.md"

  printf 'ticked: #%s task %s (%s)\n' "$issue" "$task" "$(head -1 "$tmp/section.md")"
}
