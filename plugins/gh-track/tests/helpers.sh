#!/usr/bin/env bash
# Test helpers: assertions, scratch git repo, gh stub control.
# Every test file sources this and ends with `report`.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_DIR=$(cd "$TESTS_DIR/.." && pwd)
GHTRACK="$PLUGIN_DIR/scripts/ghtrack"
export GHTRACK PLUGIN_DIR TESTS_DIR

FAILURES=0
CHECKS=0

# Unmatched gh reads accumulate here for the WHOLE suite: stub_reset must not
# truncate it, or only the last segment's misses would ever be seen.
GH_STUB_UNMATCHED="${TMPDIR:-/tmp}/ghtrack-unmatched.$$"
export GH_STUB_UNMATCHED
: >"$GH_STUB_UNMATCHED"
# shellcheck disable=SC2064 # expand $GH_STUB_UNMATCHED now; it is stable for the suite.
trap "rm -f '$GH_STUB_UNMATCHED'" EXIT

fail() {
  FAILURES=$((FAILURES + 1))
  printf '  FAIL: %s\n' "$1" >&2
}

pass() { CHECKS=$((CHECKS + 1)); }

assert_eq() {
  CHECKS=$((CHECKS + 1))
  if [ "$1" != "$2" ]; then
    fail "${3:-assert_eq}: expected [$1], got [$2]"
  fi
}

assert_contains() {
  CHECKS=$((CHECKS + 1))
  case "$1" in
    *"$2"*) : ;;
    *) fail "${3:-assert_contains}: [$2] not found in [$1]" ;;
  esac
}

assert_not_contains() {
  CHECKS=$((CHECKS + 1))
  case "$1" in
    *"$2"*) fail "${3:-assert_not_contains}: [$2] unexpectedly found in [$1]" ;;
    *) : ;;
  esac
}

# assert_exit CODE CMD... — runs CMD, compares exit status.
#
# CMD runs in a SUBSHELL. Most library functions here signal failure with
# `die`, which calls `exit` — and `exit` inside a function terminates the
# whole shell, `||` notwithstanding. Without the subshell, the first
# assert_exit on a dying function would kill the test run silently.
assert_exit() {
  local want=$1
  shift
  CHECKS=$((CHECKS + 1))
  local got=0
  ( "$@" ) >/dev/null 2>&1 || got=$?
  if [ "$want" != "$got" ]; then
    fail "assert_exit: expected exit $want, got $got from: $*"
  fi
}

# require_scratch WHAT — non-zero unless the CWD is inside the scratch repo.
#
# Nearly every subcommand resolves its config from $PWD and can WRITE there:
# `init` creates .claude/gh-track/config.json and appends to .gitignore. A
# test that runs the CLI outside its scratch repo therefore mutates the
# repository the suite itself lives in. The two things that used to prevent
# that are accidents, not guards -- the gh stub hard-fails while GH_STUB_LOG
# is unset, and repo resolution fails without a canned `repo view` -- and
# BOTH evaporate the moment a test cans a `repo view` response, which is a
# single plausible mistake away. This is the structural version.
require_scratch() {
  local here scratch_p
  if [ -z "${SCRATCH:-}" ]; then
    printf 'ghtrack-tests: refusing to run [%s]: no scratch repo (missing setup_scratch)\n' \
      "$1" >&2
    return 1
  fi
  here=$(pwd -P)
  scratch_p=$(cd "$SCRATCH" 2>/dev/null && pwd -P) || scratch_p=$SCRATCH
  case $here in
    "$scratch_p"|"$scratch_p"/*) return 0 ;;
  esac
  printf 'ghtrack-tests: refusing to run [%s] from %s: outside the scratch repo %s\n' \
    "$1" "$here" "$scratch_p" >&2
  return 1
}

# ght ARGS... — the CLI, guarded. Use this instead of "$GHTRACK" everywhere a
# subcommand is exercised. Exit 99 (a code the CLI itself never returns) so a
# tripped guard can never be mistaken for a subcommand's own failure.
ght() {
  require_scratch "ghtrack $*" || return 99
  "$GHTRACK" "$@"
}

report() {
  # An unmatched READ against the gh stub means a canned response is missing
  # or misspelled, which silently reroutes the code under test onto its
  # degraded path while every assertion still passes. Fail loudly on it.
  if [ -s "${GH_STUB_UNMATCHED:-/nonexistent}" ]; then
    printf '  FAIL: gh stub had unmatched reads (missing canned responses):\n' >&2
    sed 's/^/    /' "$GH_STUB_UNMATCHED" >&2
    FAILURES=$((FAILURES + 1))
  fi
  if [ "$FAILURES" -gt 0 ]; then
    printf '  %d checks, %d FAILED\n' "$CHECKS" "$FAILURES" >&2
    exit 1
  fi
  printf '  %d checks passed\n' "$CHECKS"
  exit 0
}

# --- gh stub control -------------------------------------------------------

# Put the stub first on PATH for the whole test process.
STUB_BIN="$TESTS_DIR/stub"
PATH="$STUB_BIN:$PATH"
export PATH

stub_reset() {
  GH_STUB_LOG="${SCRATCH:-${TMPDIR:-/tmp}}/gh-calls.log"
  GH_STUB_RESPONSES="${SCRATCH:-${TMPDIR:-/tmp}}/gh-responses.tsv"
  : >"$GH_STUB_LOG"
  : >"$GH_STUB_RESPONSES"
  export GH_STUB_LOG GH_STUB_RESPONSES
}

# stub_expect PATTERN EXIT [STDOUT_FILE]
stub_expect() {
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$GH_STUB_RESPONSES"
}

# stub_expect_json PATTERN JSON — canned JSON stdout, exit 0.
stub_expect_json() {
  local f
  f="${SCRATCH:-${TMPDIR:-/tmp}}/stub-out.$RANDOM.json"
  printf '%s' "$2" >"$f"
  stub_expect "$1" 0 "$f"
}

stub_calls() { cat "$GH_STUB_LOG"; }

# stub_call_count PATTERN — how many recorded calls contain PATTERN as a
# LITERAL substring. -F matters: `gh` arguments are full of regex
# metacharacters (`.`, `[`, `*`), so a regex match would quietly count the
# wrong calls.
stub_call_count() { grep -c -F -- "$1" "$GH_STUB_LOG" || true; }

# scratch_slug — what a subcommand's `slug_require` does, for suites that
# source library functions directly instead of running `ghtrack`.
scratch_slug() { GHT_SLUG=$(repo_slug); export GHT_SLUG; }

# --- scratch repo ----------------------------------------------------------

setup_scratch() {
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/ghtrack-test.XXXXXX")
  export SCRATCH
  ORIG_PWD=$(pwd)
  # shellcheck disable=SC2164 # SCRATCH was just created by mktemp -d above; cd cannot fail here.
  cd "$SCRATCH"
  git init -q .
  git config user.email test@example.com
  git config user.name Test
  git commit -q --allow-empty -m "initial"
  mkdir -p .claude/gh-track
  stub_reset
}

teardown_scratch() {
  # shellcheck disable=SC2164 # ORIG_PWD defaults to / which always exists; failure here is not actionable.
  cd "${ORIG_PWD:-/}"
  [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
  unset SCRATCH
  # The stub inherits these through the environment, so leaving them set
  # after teardown means a `gh` call added below this line silently succeeds
  # against a deleted log instead of failing. Clearing them keeps "outside a
  # scratch repo" a loud state rather than a quiet one.
  unset GH_STUB_LOG GH_STUB_RESPONSES
}
