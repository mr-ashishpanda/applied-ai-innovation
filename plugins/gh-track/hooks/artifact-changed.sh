#!/usr/bin/env bash
# PostToolUse hook: notice writes to superpowers artifacts and remind the
# agent to checkpoint the tracking issue.
#
# Design rules this script must never violate:
#   1. Always exit 0. A tracking hook that fails a user's Write is a defect.
#   2. Be silent unless there is something specific and actionable to say.
#   3. Watch PATHS, never superpowers internals - that is what makes this
#      immune to superpowers releases.
set -uo pipefail

# Any internal failure must still exit 0.
trap 'exit 0' ERR

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)
case $tool in
  Write|Edit|NotebookEdit) : ;;
  *) exit 0 ;;
esac

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[ -n "$file" ] || exit 0
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -n "$cwd" ] || cwd=$(pwd)

cd "$cwd" 2>/dev/null || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Canonicalize the written file's directory the same way git canonicalized
# root (macOS /tmp is a symlink to /private/tmp; comparing raw paths against
# git's resolved toplevel would falsely treat in-repo paths as outside it).
file_dir=$(dirname "$file")
file_base=$(basename "$file")
file_real_dir=$(cd "$file_dir" 2>/dev/null && pwd -P) || exit 0
file_real="$file_real_dir/$file_base"

# Relative path inside the repo; bail out if the write was outside it.
case $file_real in
  "$root"/*) rel=${file_real#"$root"/} ;;
  *) exit 0 ;;
esac

case $rel in
  docs/superpowers/*) : ;;
  *) exit 0 ;;
esac

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

# Debounce on (path, content hash) so iterative editing of the same
# unchanged artifact does not spam reminders. Only the single MOST RECENT
# notification is remembered (not a full per-path history): touching a
# different artifact in between, then returning to this one, nudges again
# even if this artifact's own content has not changed since last time -
# it is no longer the thing the agent was just told about.
hash=$(git hash-object "$file" 2>/dev/null || true)
[ -n "$hash" ] || exit 0
state="$root/.claude/gh-track/state.json"
if [ -f "$state" ]; then
  last_path=$(jq -r '.lastNudge.path // empty' "$state" 2>/dev/null || true)
  last_hash=$(jq -r '.lastNudge.hash // empty' "$state" 2>/dev/null || true)
  [ "$last_path" = "$rel" ] && [ "$last_hash" = "$hash" ] && exit 0
fi
mkdir -p "$(dirname "$state")"
[ -f "$state" ] || printf '%s' '{}' >"$state"
tmp="$state.tmp.$$"
if jq --arg p "$rel" --arg h "$hash" '.lastNudge = {path: $p, hash: $h}' \
    "$state" >"$tmp" 2>/dev/null; then
  mv "$tmp" "$state"
else
  rm -f "$tmp"
fi

case $rel in
  docs/superpowers/specs/*)
    msg="gh-track: spec artifact changed ($rel) for issue #$issue. Use the tracking-work-in-github skill to post the checkpoint: the 'spec' checkpoint if this issue has none yet, otherwise a 'scope-change' checkpoint explaining what changed and why. Then set the stage with: ghtrack stage $issue spec"
    ;;
  docs/superpowers/plans/*)
    msg="gh-track: plan artifact changed ($rel) for issue #$issue. Use the tracking-work-in-github skill to post the 'plan' checkpoint, then sync the checklist: ghtrack tasks $issue --plan $rel"
    ;;
  *)
    msg="gh-track: new superpowers artifact at $rel for issue #$issue. This is not a spec or plan path. Consider a one-line note on the issue if it records a decision; ignore it otherwise."
    ;;
esac

jq -nc --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
exit 0
