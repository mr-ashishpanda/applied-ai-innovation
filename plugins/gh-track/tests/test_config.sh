#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"

setup_scratch

# Defaults apply when no config file exists.
cfg_load
# Compare resolved paths: on macOS, $TMPDIR (thus $SCRATCH) lives under a
# symlink (/var -> /private/var) that `git rev-parse --show-toplevel`
# resolves away, so a literal string compare would fail on that platform
# alone. Intent (GHT_ROOT is the repo toplevel) is unaffected.
assert_eq "$(realpath "$SCRATCH")" "$GHT_ROOT" "GHT_ROOT is repo toplevel"
assert_eq "^### Task ([0-9]+):" "$(cfg .taskHeadingPattern)" "default task pattern"
assert_eq "^([0-9]+)-" "$(cfg .branchPattern)" "default branch pattern"
assert_eq "Status" "$(cfg .board.statusField)" "default status field"
assert_eq "" "$(cfg .project)" "project empty by default"

# Config file values win over defaults.
cat >.claude/gh-track/config.json <<'JSON'
{"repo":"me/proj","project":7,"taskHeadingPattern":"^## T([0-9]+):"}
JSON
cfg_load
assert_eq "me/proj" "$(cfg .repo)" "repo from config"
assert_eq "7" "$(cfg .project)" "project from config"
assert_eq "^## T([0-9]+):" "$(cfg .taskHeadingPattern)" "overridden task pattern"
assert_eq "docs/superpowers/plans/**/*.md" "$(cfg .planGlob)" "unset key still defaults"

# repo_slug prefers config and never calls gh when config has it.
stub_reset
assert_eq "me/proj" "$(repo_slug)" "repo_slug from config"
scratch_slug
assert_eq "me" "$(repo_owner)" "repo_owner splits slug"
assert_eq "proj" "$(repo_name)" "repo_name splits slug"
assert_eq "0" "$(stub_call_count 'repo view')" "no gh call when config has repo"

# With no repo in config, repo_slug falls back to gh.
printf '%s' '{}' >.claude/gh-track/config.json
cfg_load
stub_reset
stub_expect_json 'repo view' '{"nameWithOwner":"fallback/repo"}'
assert_eq "fallback/repo" "$(repo_slug)" "repo_slug falls back to gh"

# State round-trips and is created on demand.
state_set '.worktrees["/tmp/wt"] = 42'
assert_eq "42" "$(state_get '.worktrees["/tmp/wt"]')" "state round-trip"
assert_eq "zz" "$(state_get '.nope' zz)" "state default"

# doctor reports missing config as a warning, not a failure, and exits 0
# when gh is present and authed. The previous step left a stray (empty)
# config.json on disk; remove it so config is genuinely absent here.
rm -f .claude/gh-track/config.json
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo'"
stub_expect_json 'repo view' '{"nameWithOwner":"fallback/repo"}'
out=$("$GHTRACK" doctor 2>&1 || true)
assert_contains "$out" "repo=fallback/repo" "doctor reports repo line"
assert_contains "$out" "config=MISSING" "doctor flags absent config"
assert_contains "$out" "scope_project=MISSING" "doctor flags absent project scope"

# C5 regression. repo_slug must never `die`: every call site is a $(...)
# substitution, where exit kills only the subshell and the enclosing command
# then runs with an empty --repo while the subcommand reports success.
stub_reset
stub_expect 'repo view' 1
printf '%s' '{}' >.claude/gh-track/config.json
cfg_load
assert_exit 1 repo_slug "unresolvable repo returns 1 rather than dying"

# ...and the diagnostic whose job is to catch that must actually flag it.
stub_reset
stub_expect 'repo view' 1
stub_expect_json 'auth status' "Token scopes: 'repo'"
out=$("$GHTRACK" doctor 2>&1 || true)
assert_contains "$out" "repo=UNKNOWN" "doctor flags an unresolvable repo"
assert_not_contains "$out" "problems=0" "doctor counts it as a problem"

# ...and a mutating subcommand must refuse the write rather than exit 0.
stub_reset
stub_expect 'repo view' 1
stub_expect_json 'auth status' "Token scopes: 'repo'"
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:spec"}]}'
assert_exit 6 "$GHTRACK" stage 42 building
assert_eq "0" "$(stub_call_count 'issue edit')" "no edit when the repo is unknown"

# M5 regression: a non-numeric issue number is a usage error, not a write.
stub_reset
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
assert_exit 2 "$GHTRACK" stage 'x; rm -rf /' building
assert_exit 2 "$GHTRACK" show 'x'
assert_exit 2 "$GHTRACK" tick 'x' --task 1
assert_eq "0" "$(stub_call_count 'issue edit')" "no write on a bad issue number"

teardown_scratch
report
