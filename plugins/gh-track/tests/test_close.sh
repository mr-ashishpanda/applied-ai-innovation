#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json

# Closing an OPEN issue at stage:done: closes with the default reason, no
# warning about stage mismatch.
stub_reset
stub_expect_json 'issue view 42 --repo me/proj --json state' '{"state":"OPEN"}'
stub_expect_json 'issue view 42 --repo me/proj --json labels' \
  '{"labels":[{"name":"stage:done"},{"name":"kind:feature"}]}'
stub_expect 'issue close 42' 0
out=$(ght close 42 2>&1)
assert_contains "$out" "closed: #42 (completed)" "reports the close and default reason"
assert_not_contains "$out" "not stage:done" "no stage warning when already at stage:done"
calls=$(stub_calls)
assert_contains "$calls" "issue close 42 --repo me/proj --reason completed" "closes with the default reason"

# Already-closed issue: no-op, no `issue close` call made.
stub_reset
stub_expect_json 'issue view 42 --repo me/proj --json state' '{"state":"CLOSED"}'
out=$(ght close 42 2>&1)
assert_contains "$out" "already closed: #42" "reports already-closed rather than re-closing"
calls=$(stub_calls)
assert_not_contains "$calls" "issue close" "does not call issue close on an already-closed issue"

# --reason "not planned" passes through, and closing off-stage with this
# reason draws no stage warning (closing a backlog item as not-planned is a
# legitimate, expected use, not a mistake to flag).
stub_reset
stub_expect_json 'issue view 42 --repo me/proj --json state' '{"state":"OPEN"}'
stub_expect_json 'issue view 42 --repo me/proj --json labels' \
  '{"labels":[{"name":"stage:backlog"}]}'
stub_expect 'issue close 42' 0
out=$(ght close 42 --reason "not planned" 2>&1)
assert_contains "$out" "closed: #42 (not planned)" "reports the not-planned reason"
assert_not_contains "$out" "not stage:done" "no stage warning for a not-planned close"
calls=$(stub_calls)
assert_contains "$calls" 'issue close 42 --repo me/proj --reason not planned' "passes the reason through"

# Closing as "completed" while NOT at stage:done: still closes, but warns.
stub_reset
stub_expect_json 'issue view 42 --repo me/proj --json state' '{"state":"OPEN"}'
stub_expect_json 'issue view 42 --repo me/proj --json labels' \
  '{"labels":[{"name":"stage:building"},{"name":"kind:feature"}]}'
stub_expect 'issue close 42' 0
out=$(ght close 42 2>&1)
assert_contains "$out" "not stage:done" "warns when closing as completed off stage:done"
assert_contains "$out" "closed: #42 (completed)" "still closes despite the warning"

# Validation: unknown --reason, missing/non-numeric issue number.
assert_exit 2 ght close 42 --reason "duplicate"
assert_exit 2 ght close notanumber
assert_exit 2 ght close

teardown_scratch
report
