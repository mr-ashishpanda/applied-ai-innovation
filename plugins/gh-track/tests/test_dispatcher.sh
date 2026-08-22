#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

# These four run the CLI directly rather than through the guarded `ght`
# wrapper: they exercise the dispatcher's own error and version paths, which
# return before any cmd_*.sh is sourced, so they read no config and write
# nothing. They are the only $GHTRACK invocations in the suite that are not
# inside a scratch repo.

# Usage on no arguments, exit 2 (usage error, distinct from failure).
out=$("$GHTRACK" 2>&1 || true)
assert_exit 2 "$GHTRACK"
assert_contains "$out" "usage: ghtrack" "usage banner on no args"

# Every subcommand the dispatcher accepts must be documented in the usage
# text. An undocumented subcommand is an unusable one: models read `ghtrack`
# with no arguments to discover what exists.
SUBCOMMANDS="doctor init new resolve show stage size body comment link tasks tick split close"
for sub in $SUBCOMMANDS; do
  assert_contains "$out" "  $sub" "usage lists $sub"
done

# Unknown subcommand names the offender and exits 2.
out=$("$GHTRACK" frobnicate 2>&1 || true)
assert_exit 2 "$GHTRACK" frobnicate
assert_contains "$out" "unknown subcommand: frobnicate" "unknown subcommand message"

# --version prints a bare semver and exits 0.
out=$("$GHTRACK" --version)
assert_exit 0 "$GHTRACK" --version
if ! printf '%s' "$out" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  fail "--version should print bare semver, got: $out"
fi

# GHTRACK_VERSION and plugin.json's "version" are two independent sources of
# truth for the same number; nothing enforces they move together except this
# check catching drift the moment either one changes.
manifest_version=$(jq -r '.version' "$PLUGIN_DIR/.claude-plugin/plugin.json")
assert_eq "$manifest_version" "$out" \
  "plugin.json version matches ghtrack --version"

# The stub records calls and is what `gh` resolves to inside tests.
setup_scratch
stub_reset
gh issue list --label foo >/dev/null
assert_contains "$(stub_calls)" "issue list --label foo" "stub records gh calls"

# ...and every documented subcommand must actually reach a command function.
# Run inside the scratch repo: these invocations resolve config and, for
# `init`, would write to whatever repository the test happens to sit in.
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
for sub in $SUBCOMMANDS; do
  stub_reset
  stub_expect 'auth status' 1
  stub_expect_json '--version' 'gh version 2.40.0 (2024-01-01)'
  assert_not_contains "$(ght "$sub" 2>&1 || true)" "unknown subcommand" \
    "$sub dispatches to a command"
done

# The harness guard itself. Every subcommand resolves config from $PWD and
# `init` WRITES there, so running the CLI outside the scratch repo mutates
# the repository the suite lives in -- reachable with one plausible mistake
# (a canned `repo view` response plus a `cd` out, or any line added after
# teardown_scratch). The guard must fail loudly instead.
stub_reset
# `init` is the dangerous one: it writes config.json and appends .gitignore.
# Run it from OUTSIDE the scratch repo, in a subshell so the cd cannot leak.
# shellcheck disable=SC2329 # invoked indirectly, by assert_exit on the next line.
guard_probe() { cd / && ght init; }
assert_exit 99 guard_probe
guard_out=$( (cd / && ght init) 2>&1 || true)
assert_contains "$guard_out" "refusing to run" "the guard says why it refused"
assert_contains "$guard_out" "outside the scratch repo" "the guard names the hazard"
assert_eq "" "$(stub_calls)" "a refused run makes no gh calls at all"

# ...and it refuses just as hard when setup_scratch never ran, which is the
# state every line after teardown_scratch is in.
old_scratch=$SCRATCH
unset SCRATCH
assert_exit 99 ght init
assert_contains "$(ght init 2>&1 || true)" "no scratch repo" \
  "the guard also refuses when setup_scratch never ran"
SCRATCH=$old_scratch
export SCRATCH

# B2: the stub classifies a call by what the caller does with its stdout, not
# by which flags it carries. 'gh issue create' has no --json/--jq/--format, so
# it read as a WRITE and an unmatched call stayed silent -- yet cmd_new parses
# its stdout for the issue number, so a misspelled canned response yielded an
# empty number, exit 0, and no UNMATCHED line to explain it.
#
# The probe writes to its own file: the suite-wide one is what `report` fails
# on, and these misses are deliberate.
stub_reset
probe="$SCRATCH/unmatched-probe"
: >"$probe"
GH_STUB_UNMATCHED="$probe" GH_STUB_RESPONSES=/dev/null \
  gh issue create --repo me/proj --title x >/dev/null
assert_contains "$(cat "$probe")" "issue create" \
  "an unmatched issue create is recorded: its stdout is parsed"
GH_STUB_UNMATCHED="$probe" GH_STUB_RESPONSES=/dev/null \
  gh --version >/dev/null
assert_contains "$(cat "$probe")" "--version" \
  "an unmatched gh --version is recorded: cmd_doctor prints what it reads back"
GH_STUB_UNMATCHED="$probe" GH_STUB_RESPONSES=/dev/null \
  gh label create foo --force >/dev/null
assert_not_contains "$(cat "$probe")" "label create" \
  "an unmatched write whose stdout is discarded stays silent"

teardown_scratch

report
