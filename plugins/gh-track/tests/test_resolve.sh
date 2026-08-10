#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/resolve.sh
. "$PLUGIN_DIR/scripts/lib/resolve.sh"

setup_scratch
cfg_load

# Branch name carries the issue number.
git checkout -q -b 42-gh-tracking
assert_eq "42" "$(resolve_issue)" "issue from branch name"

# Multi-digit and slugs with digits do not confuse the pattern.
git checkout -q -b 1234-fix-v2-parser
assert_eq "1234" "$(resolve_issue)" "multi-digit issue from branch"

# A non-conforming branch falls back to recorded state.
git checkout -q -b spike/no-number
assert_exit 3 resolve_issue

# The error message names the branch, so the failure is actionable.
# (Checked before any state is recorded for this worktree, since state
# is keyed by toplevel and would otherwise mask an unresolved branch.)
git checkout -q -b spike/other
# resolve_issue dies via `exit`, which terminates a shell outright --
# `||` cannot intercept it in the same shell. Run it in its own
# subshell first so only that subshell exits; the outer command
# substitution then evaluates `|| true` normally.
out=$( (resolve_issue) 2>&1 || true)
assert_contains "$out" "spike/other" "error names the branch"

git checkout -q spike/no-number
resolve_remember 99
assert_eq "99" "$(resolve_issue)" "issue from state fallback"

# A conforming branch beats the state entry (branch is authoritative).
git checkout -q -b 7-something
assert_eq "7" "$(resolve_issue)" "branch wins over state"

# A configured branchPattern is honoured.
printf '%s' '{"branchPattern":"^issue-([0-9]+)/"}' >.claude/gh-track/config.json
cfg_load
git checkout -q -b issue-55/slug
assert_eq "55" "$(resolve_issue)" "custom branch pattern"

# The subcommand prints just the number.
git checkout -q -b 42-again
printf '%s' '{}' >.claude/gh-track/config.json
assert_eq "issue=42" "$("$GHTRACK" resolve)" "resolve subcommand output"

# An unresolvable workspace must not print `issue=` and exit 0: resolve_issue
# dies with 3 inside a $(...), so the value has to be captured, not
# interpolated straight into printf.
# No branch number AND no recorded state (an earlier check above recorded 99
# for this worktree, and state is keyed by toplevel).
git checkout -q -b spike/unresolvable
rm -f .claude/gh-track/state.json
assert_exit 3 "$GHTRACK" resolve
out=$("$GHTRACK" resolve 2>&1 || true)
assert_not_contains "$out" "issue=" "no bare issue= line on an unresolvable branch"

teardown_scratch
report
