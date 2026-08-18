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
# A BARE number, by design: hook scripts do `issue=$(ghtrack resolve)`.
assert_eq "42" "$(ght resolve)" "resolve subcommand output"
assert_eq "77" "$(ght resolve --set 77)" "resolve --set echoes a bare number"
assert_eq "42" "$(ght resolve)" "branch still wins after --set"

# An unresolvable workspace must not print `issue=` and exit 0: resolve_issue
# dies with 3 inside a $(...), so the value has to be captured, not
# interpolated straight into printf.
# No branch number AND no recorded state (an earlier check above recorded 99
# for this worktree, and state is keyed by toplevel).
git checkout -q -b spike/unresolvable
rm -f .claude/gh-track/state.json
assert_exit 3 ght resolve
# Nothing on STDOUT when it fails -- a caller doing `n=$(ghtrack resolve)` must
# get an empty string, not a stray line it would treat as an issue number.
out=$(ght resolve 2>/dev/null || true)
assert_eq "" "$out" "unresolvable branch prints nothing on stdout"
err=$(ght resolve 2>&1 >/dev/null || true)
assert_contains "$err" "cannot resolve issue" "the reason goes to stderr"

# --- shared branches: never use the recorded-state fallback ---------------

# A configured shared branch refuses resolve_remember/--set outright, rather
# than silently recording a pin that would misattribute every future
# session on that branch.
printf '%s' '{"sharedBranches":["integration"]}' >.claude/gh-track/config.json
cfg_load
git checkout -q -b integration
assert_exit 2 resolve_remember 4242
out=$( (resolve_remember 4242) 2>&1 || true)
assert_contains "$out" "shared branch" "resolve_remember names the reason"
assert_exit 2 ght resolve --set 4242

# resolve_issue on a shared branch dies with 3, WITHOUT consulting any
# recorded state -- even one that predates the branch being marked shared.
# (State is keyed by TOPLEVEL PATH, not branch, so recording it on one
# branch and reading it from another in the same scratch repo is exactly
# the scenario being proven here, not an accident of the test.)
git checkout -q -b spike/pre-existing-record
resolve_remember 55
git checkout -q integration
assert_exit 3 resolve_issue
out=$( (resolve_issue) 2>&1 || true)
assert_contains "$out" "shared branch" "resolve_issue on a shared branch never falls through to state"

# An ad-hoc branch that is NOT configured as shared still uses the fallback
# recorded above (55, from the same path) -- shared-branch handling must not
# have disabled the fallback mechanism generally, only for shared branches.
git checkout -q -b spike/still-fine
assert_eq "55" "$(resolve_issue)" "a non-shared branch still uses the pre-existing fallback"
resolve_remember 66
assert_eq "66" "$(resolve_issue)" "and can still overwrite it"

# Default sharedBranches (["main","master"]) applies when the key is unset.
# -B (not -b): setup_scratch's `git init` may itself have named the
# scratch repo's initial branch "main" depending on the host's
# init.defaultBranch, so the branch can already exist here.
printf '%s' '{}' >.claude/gh-track/config.json
cfg_load
git checkout -q -B main
assert_exit 3 resolve_issue
out=$( (resolve_issue) 2>&1 || true)
assert_contains "$out" "shared branch" "main is shared by default"
git checkout -q -B master
assert_exit 3 resolve_issue

# --- --clear: the symmetric undo for --set ---------------------------------

printf '%s' '{}' >.claude/gh-track/config.json
cfg_load
git checkout -q -b spike/to-clear
resolve_remember 321
assert_eq "321" "$(resolve_issue)" "recorded before clearing"
ght resolve --clear
assert_exit 3 resolve_issue
out=$( (resolve_issue) 2>&1 || true)
assert_contains "$out" "cannot resolve issue" "cleared workspace is unresolvable again"

teardown_scratch
report
