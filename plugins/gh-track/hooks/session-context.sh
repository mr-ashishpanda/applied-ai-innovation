#!/usr/bin/env bash
# SessionStart hook: tell the session which issue it is working on, what
# stage that issue is in, and what comes next.
#
# This is the recovery mechanism. After compaction, or in a brand new
# session, this block is how the agent learns its position without reading
# a spec or plan. It is also the bug track's primary enforcement, since
# systematic-debugging writes no watched files for artifact-changed.sh to
# fire on.
#
# Design rules this script must never violate:
#   1. Always exit 0. A tracking hook that fails SessionStart is a defect.
#   2. Be silent unless there is something specific and actionable to say.
#   3. Watch only the permitted superpowers surface - user-facing skill
#      NAMES in the guidance text are fine; never reference internal SDD
#      paths or prompts.
set -uo pipefail
trap 'exit 0' ERR

payload=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

cwd=""
if [ -n "$payload" ]; then
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$cwd" ] || cwd=$(pwd)

cd "$cwd" 2>/dev/null || exit 0
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

# Locate ghtrack: prefer the plugin's own copy, fall back to PATH.
ghtrack=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "$CLAUDE_PLUGIN_ROOT/scripts/ghtrack" ]; then
  ghtrack="$CLAUDE_PLUGIN_ROOT/scripts/ghtrack"
elif command -v ghtrack >/dev/null 2>&1; then
  ghtrack=$(command -v ghtrack)
else
  exit 0
fi

issue=$("$ghtrack" resolve 2>/dev/null) || exit 0
[ -n "$issue" ] || exit 0

info=$("$ghtrack" show "$issue" 2>/dev/null) || exit 0
[ -n "$info" ] || exit 0

get() { printf '%s\n' "$info" | sed -n "s/^$1=//p" | head -1; }

title=$(get title)
stage=$(get stage)
kind=$(get kind)
tasks=$(get tasks)
state=$(get state)

case $stage in
  backlog)
    next="Not picked up yet. The moment you start brainstorming or triaging this, post the 'pickup' checkpoint (ghtrack stage $issue triage) so the board shows it as Todo instead of untouched Backlog - then start with superpowers:brainstorming (feature/chore) or superpowers:systematic-debugging (bug), and post 'spec' (or 'repro') once you have an artifact." ;;
  spec)
    next="A spec exists. Next is superpowers:writing-plans, then post the 'plan' checkpoint." ;;
  triage)
    case $kind in
      bug)
        next="This is a bug in triage. Use superpowers:systematic-debugging; post the 'repro' checkpoint once reproduced." ;;
      *)
        next="Picked up, not yet spec'd. Use superpowers:brainstorming; post the 'spec' checkpoint once the design doc is written and committed." ;;
    esac
    ;;
  debugging)
    next="Root cause hunt in progress. Post the 'root-cause' checkpoint when found, then move to stage building." ;;
  planned)
    next="A plan exists. Next is to execute it (superpowers:subagent-driven-development or superpowers:executing-plans), post 'build-started', and set stage building." ;;
  building)
    next="Implementation is in flight. Tick checklist items with 'ghtrack tick' as tasks complete; post 'blocked' if you stall." ;;
  review)
    next="Work is in review. Post the 'done' checkpoint once merged and set stage done." ;;
  done)
    next="This issue is complete. Confirm before starting new work on this branch." ;;
  *)
    next="Stage is unset. Set one with 'ghtrack stage $issue <stage>'." ;;
esac

msg="gh-track: this workspace tracks issue #$issue - \"$title\" (kind=$kind, stage=$stage, state=$state, tasks=$tasks).
$next
The issue is the single source of truth for this work. Do not copy spec or plan prose into it; post short checkpoint comments and keep the body's state current. Full guidance: the tracking-work-in-github skill."

jq -nc --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
exit 0
