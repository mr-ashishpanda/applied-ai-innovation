#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json

# Happy path: creates the issue at stage:planned, inherits the parent's kind,
# links it as a sub-issue, seeds plan1:* on the parent from its current
# stage, and prints the bare number.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"kind:feature"},{"name":"stage:building"}]}'
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/77'
stub_expect_json 'issues/77 --jq' '{"id":9001}'
out=$(ght split 42 --plan docs/superpowers/plans/p2.md --title "Second plan")
assert_eq "77" "$out" "split prints the new sub-issue number"
calls=$(stub_calls)
assert_contains "$calls" "--label stage:planned" "sub-issue starts at planned"
assert_contains "$calls" "--label kind:feature" "kind inherited from the parent"
assert_contains "$calls" "sub_issues -F sub_issue_id=9001" "linked as a GitHub-native sub-issue"
assert_contains "$calls" "--add-label plan1:building" "seeds plan1 from the parent's current stage"
assert_eq "0" "$(stub_call_count 'project ')" "no board calls when no project is configured"

# --size applies the size label to the sub-issue too.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"kind:feature"},{"name":"stage:building"},{"name":"plan1:building"}]}'
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/78'
stub_expect_json 'issues/78 --jq' '{"id":9002}'
out=$(ght split 42 --plan docs/superpowers/plans/p3.md --title "Third plan" --size m)
assert_eq "78" "$out" "split with --size prints the number"
assert_contains "$(stub_calls)" "--label size:m" "size label applied to the sub-issue"
# plan1 was already seeded (present in the canned labels above) -- no second seed.
assert_eq "0" "$(stub_call_count '--add-label plan1:')" "plan1 not re-seeded on a later split"

# Idempotent: a repeat call for the SAME plan path returns the same number
# and creates nothing new.
stub_reset
out=$(ght split 42 --plan docs/superpowers/plans/p3.md --title "Third plan (again)" --size m)
assert_eq "78" "$out" "repeat split for the same plan returns the existing number"
assert_eq "0" "$(stub_call_count 'issue create')" "no duplicate issue created"

# A different plan path is a genuinely new split.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"kind:feature"},{"name":"stage:building"},{"name":"plan1:building"}]}'
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/79'
stub_expect_json 'issues/79 --jq' '{"id":9003}'
out=$(ght split 42 --plan docs/superpowers/plans/p4.md --title "Fourth plan")
assert_eq "79" "$out" "a new plan path creates a new sub-issue"

# A parent with no kind:* label refuses rather than guessing.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:building"}]}'
assert_exit 6 ght split 42 --plan docs/superpowers/plans/p5.md --title "No kind"
assert_eq "0" "$(stub_call_count 'issue create')" "no write when the parent's kind cannot be determined"

# A failed label read refuses the write (C1 discipline, same as stage/size).
stub_reset
stub_expect 'issue view 42' 1
assert_exit 6 ght split 42 --plan docs/superpowers/plans/p6.md --title "Failed read"
assert_eq "0" "$(stub_call_count 'issue create')" "no write on a failed parent read"

# Usage errors: missing --plan, missing --title, bad --size, non-numeric issue.
stub_reset
assert_exit 2 ght split 42 --title "No plan"
assert_exit 2 ght split 42 --plan docs/superpowers/plans/p.md
assert_exit 2 ght split 42 --plan docs/superpowers/plans/p.md --title T --size xl
assert_exit 2 ght split notanumber --plan docs/superpowers/plans/p.md --title T
assert_eq "0" "$(stub_call_count 'issue create')" "no write on a bad argument"

teardown_scratch
report
