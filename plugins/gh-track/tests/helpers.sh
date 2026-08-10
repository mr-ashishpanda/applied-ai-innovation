#!/usr/bin/env bash
# Test helpers: assertions, scratch git repo, gh stub control.
# Every test file sources this and ends with `report`.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_DIR=$(cd "$TESTS_DIR/.." && pwd)
GHTRACK="$PLUGIN_DIR/scripts/ghtrack"
export GHTRACK PLUGIN_DIR TESTS_DIR

FAILURES=0
CHECKS=0

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

report() {
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

# stub_call_count PATTERN — how many recorded calls contain PATTERN.
stub_call_count() { grep -c -- "$1" "$GH_STUB_LOG" || true; }

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
}
