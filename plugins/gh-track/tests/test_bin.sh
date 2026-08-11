#!/usr/bin/env bash
# bin/ghtrack is the PATH shim: Claude Code prepends every installed
# plugin's bin/ to PATH unconditionally, while ${CLAUDE_PLUGIN_ROOT} is only
# set while a skill or hook is running. Without this file, every bare
# `ghtrack ...` call in the skills and CLAUDE.md block fails to resolve on a
# real install even though the tests (which invoke $GHTRACK directly) still
# pass. Nothing here exercises subcommand behavior -- that is scripts/ghtrack's
# job -- only that the shim exists, is executable, and dispatches correctly.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

BIN="$PLUGIN_DIR/bin/ghtrack"

if [ ! -f "$BIN" ]; then
  fail "bin/ghtrack is missing; ghtrack will not resolve on PATH after a real install"
else
  if [ ! -x "$BIN" ]; then
    fail "bin/ghtrack exists but is not executable"
  else
    pass "bin/ghtrack exists and is executable"
  fi

  # Must dispatch to the same script, not a stale copy: version drift
  # between the two would surface as a phantom version mismatch bug report.
  bin_version=$("$BIN" --version)
  lib_version=$("$GHTRACK" --version)
  assert_eq "$lib_version" "$bin_version" \
    "bin/ghtrack --version matches scripts/ghtrack --version"

  # Runs correctly when invoked via a PATH entry, from an unrelated cwd --
  # the exact way Claude Code's own PATH injection calls it.
  out=$(cd / && PATH="$PLUGIN_DIR/bin:$PATH" ghtrack --version)
  assert_eq "$lib_version" "$out" "ghtrack resolves and runs correctly via PATH"
fi

report
