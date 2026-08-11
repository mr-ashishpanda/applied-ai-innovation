#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/labels.sh
. "$PLUGIN_DIR/scripts/lib/labels.sh"
# shellcheck source=../scripts/lib/board.sh
. "$PLUGIN_DIR/scripts/lib/board.sh"
# shellcheck source=../scripts/lib/subissues.sh
. "$PLUGIN_DIR/scripts/lib/subissues.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
cfg_load
scratch_slug

# --- issue_parent_number ----------------------------------------------------
# A real 404 from GitHub (verified live against the actual sub_issues API):
# gh api exits non-zero and does NOT apply --jq, so the caller only ever
# needs to check for emptiness, never distinguish "no parent" from "read
# failed" -- both mean "nothing to roll up to right now".
stub_reset
stub_expect 'issues/5/parent' 1
assert_eq "" "$(issue_parent_number 5 2>/dev/null || true)" "no parent -> empty"

stub_reset
stub_expect_json 'issues/5/parent' '{"number":2}'
assert_eq "2" "$(issue_parent_number 5)" "parent number read"

# --- issue_sub_issue_numbers -------------------------------------------------
stub_reset
stub_expect_json 'issues/2/sub_issues' '[]'
assert_eq "" "$(issue_sub_issue_numbers 2)" "no children -> empty"

stub_reset
stub_expect_json 'issues/2/sub_issues' '[{"number":5},{"number":6}]'
assert_eq "$(printf '5\n6')" "$(issue_sub_issue_numbers 2)" "lists both children"

# --- sub_issue_link -----------------------------------------------------------
stub_reset
stub_expect_json 'issues/5 --jq' '{"id":9001}'
sub_issue_link 2 5
assert_contains "$(stub_calls)" "sub_issues -F sub_issue_id=9001" "posts the child's numeric id"

stub_reset
stub_expect 'issues/5 --jq' 1
assert_exit 1 sub_issue_link 2 5
assert_eq "0" "$(stub_call_count 'sub_issues')" "no link attempted when the id lookup fails"

# --- rollup_stage_rank / rollup_stage_from_rank ------------------------------
assert_eq "0" "$(rollup_stage_rank planned)" "planned -> 0"
assert_eq "1" "$(rollup_stage_rank building)" "building -> 1"
assert_eq "2" "$(rollup_stage_rank review)" "review -> 2"
assert_eq "3" "$(rollup_stage_rank "done")" "done -> 3"
assert_eq "0" "$(rollup_stage_rank "")" "empty (failed read) -> 0, the conservative direction"
assert_eq "building" "$(rollup_stage_from_rank 0)" "rank 0 floors to building"
assert_eq "building" "$(rollup_stage_from_rank 1)" "rank 1 -> building"
assert_eq "review" "$(rollup_stage_from_rank 2)" "rank 2 -> review"
assert_eq "done" "$(rollup_stage_from_rank 3)" "rank 3 -> done"

# --- rollup_apply -------------------------------------------------------------
# The slower child (building) wins over plan 1's more advanced review.
stub_reset
stub_expect_json 'issue view 2' '{"labels":[{"name":"plan1:review"}]}'
stub_expect_json 'issue view 5' '{"labels":[{"name":"stage:building"}]}'
stub_expect_json 'issue view 6' '{"labels":[{"name":"stage:done"}]}'
rollup_apply 2 "5 6"
assert_contains "$(stub_calls)" "--add-label stage:building" "rollup floors at the slowest child"

# All children done AND plan 1 done -> parent reaches done.
stub_reset
stub_expect_json 'issue view 2' '{"labels":[{"name":"plan1:done"}]}'
stub_expect_json 'issue view 5' '{"labels":[{"name":"stage:done"}]}'
rollup_apply 2 "5"
assert_contains "$(stub_calls)" "--add-label stage:done" "all done -> parent done"

# Plan 1 lagging behind an already-done child still floors at building, not
# planned -- the floor exists specifically for this case.
stub_reset
stub_expect_json 'issue view 2' '{"labels":[]}'
stub_expect_json 'issue view 5' '{"labels":[{"name":"stage:done"}]}'
rollup_apply 2 "5"
assert_contains "$(stub_calls)" "--add-label stage:building" "no recorded plan1 stage floors at building, never planned"

# --- rollup_apply: guard against unreadable parent labels --------------------
# If the parent's labels cannot be read, rollup_apply must return 1 and never
# call stage_set (which would die). This is the "best-effort" contract.
stub_reset
stub_expect 'issue view 2' 1
assert_exit 1 rollup_apply 2 "5"
assert_eq "0" "$(stub_call_count 'issue edit')" "no write attempted when parent labels unreadable"

teardown_scratch
report
