#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

# Usage on no arguments, exit 2 (usage error, distinct from failure).
out=$("$GHTRACK" 2>&1 || true)
assert_exit 2 "$GHTRACK"
assert_contains "$out" "usage: ghtrack" "usage banner on no args"

# Every subcommand the dispatcher accepts must be documented in the usage
# text. An undocumented subcommand is an unusable one: models read `ghtrack`
# with no arguments to discover what exists.
SUBCOMMANDS="doctor init new resolve show stage size body comment link tasks tick"
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
  assert_not_contains "$("$GHTRACK" "$sub" 2>&1 || true)" "unknown subcommand" \
    "$sub dispatches to a command"
done

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
  gh label create foo --force >/dev/null
assert_not_contains "$(cat "$probe")" "label create" \
  "an unmatched write whose stdout is discarded stays silent"

teardown_scratch

report
