#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

# Usage on no arguments, exit 2 (usage error, distinct from failure).
out=$("$GHTRACK" 2>&1 || true)
assert_exit 2 "$GHTRACK"
assert_contains "$out" "usage: ghtrack" "usage banner on no args"

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
teardown_scratch

report
