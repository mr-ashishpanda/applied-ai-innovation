#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

# Every mutating subcommand runs twice; the second run must add no CREATE
# calls. This is the executable form of the plan's idempotency constraint.

setup_scratch
printf '%s' '{"repo":"me/proj","project":3}' >.claude/gh-track/config.json
git checkout -q -b 42-thing
mkdir -p docs/superpowers/plans
cp "$TESTS_DIR/fixtures/plan-sample.md" docs/superpowers/plans/p.md
git add docs && git commit -q -m "plan"

# body_get runs `gh issue view N --json body --jq .body`; the stub emulates
# --jq for real, so the canned payload must be an object whose .body is the
# markdown string (matching the shape every other suite uses), not the bare
# string itself -- jq .body on a bare string errors and yields empty output.
# shellcheck disable=SC2016 # the literal backticks around `code` are the fixture: a code-spanned task title must survive the round trip.
body='{"body":"## Goal\nG\n\n## Tasks (from plan - 0/4)\n- [ ] 1. First thing\n- [ ] 2. Second thing\n- [ ] 3. Third thing with `code` in the title\n- [ ] 4. Fourth thing\n"}'

# tasks: two runs, two edits, no creates.
#
# "no issue create" cannot fail here by construction -- only labels_ensure
# ever calls `issue create`/`label create` -- so the real assertion is that
# the SECOND run's payload is byte-identical to the first's. That is what
# idempotence means for a body rewrite, and it can genuinely fail (a counter
# recomputed differently, a heading re-inserted, ticks lost).
stub_reset
stub_expect_json 'issue view 42' "$body"
"$GHTRACK" tasks 42 --plan docs/superpowers/plans/p.md >/dev/null
cp "${GH_STUB_LOG}.body" tasks-first.md
"$GHTRACK" tasks 42 --plan docs/superpowers/plans/p.md >/dev/null
cp "${GH_STUB_LOG}.body" tasks-second.md
assert_eq "0" "$(stub_call_count 'issue create')" "tasks creates nothing"
assert_eq "2" "$(stub_call_count 'issue edit 42')" "tasks edits once per run"
assert_eq "$(cat tasks-first.md)" "$(cat tasks-second.md)" "second tasks run sends a byte-identical body"

# comment: second run with the same event+sha edits instead of posting.
stub_reset
printf 'checkpoint text\n' >c.md
stub_expect_json 'issues/42/comments' '[]'
"$GHTRACK" comment 42 --event spec --sha abc1234 --file c.md >/dev/null
first_posts=$(stub_call_count 'issue comment 42')
stub_reset
stub_expect_json 'issues/42/comments' \
  '[{"id":11,"body":"<!-- gh-track:spec:abc1234 -->\ncheckpoint text"}]'
"$GHTRACK" comment 42 --event spec --sha abc1234 --file c.md >/dev/null
assert_eq "1" "$first_posts" "first comment posted once"
assert_eq "0" "$(stub_call_count 'issue comment 42')" "second run posted nothing"
assert_contains "$(stub_calls)" "issues/comments/11" "second run edited instead"

# stage: setting the same stage twice adds no labels beyond the first.
#
# "no label create" is likewise inert (only labels_ensure creates labels), so
# assert what the second `issue edit` actually CARRIES: still the add, and no
# spurious removal of the very label being set.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:planned"}]}'
stub_expect_json 'auth status' "Token scopes: 'repo', 'project'"
stub_expect_json 'project view' '{"id":"PVT_i"}'
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}'
stub_expect_json 'project item-list' '{"items":[{"id":"PVTI_42","content":{"number":42}}]}'
"$GHTRACK" stage 42 planned >/dev/null
"$GHTRACK" stage 42 planned >/dev/null
assert_eq "0" "$(stub_call_count 'label create')" "stage does not create labels"
assert_eq "2" "$(stub_call_count 'issue edit 42')" "one edit per stage run"
second_edit=$(grep -F 'issue edit 42' "$GH_STUB_LOG" | sed -n 2p)
assert_contains "$second_edit" "--add-label stage:planned" "second run still adds the stage label"
assert_not_contains "$second_edit" "--remove-label stage:planned" "second run does not remove the label it is setting"
assert_not_contains "$second_edit" "--remove-label" "nothing to remove when the stage is unchanged"

# tick: ticking the same task twice yields identical bodies.
#
# `ghtrack tick` writes --body-file to a mktemp scratch dir that its own
# EXIT trap deletes the instant the `ghtrack` process exits -- which, since
# it runs as a subprocess here (not sourced in-process, as test_comment.sh
# and test_tasks.sh do), happens before control ever returns to this test.
# The stub snapshots each --body-file's content to $GH_STUB_LOG.body at
# call time, while the file still exists, so we read that instead of the
# (by-then-deleted) path.
stub_reset
stub_expect_json 'issue view 42' "$body"
"$GHTRACK" tick 42 --task 1 >/dev/null
cp "${GH_STUB_LOG}.body" first-body.md
stub_reset
# shellcheck disable=SC2016 # as above: the literal backticks are the fixture.
stub_expect_json 'issue view 42' \
  '{"body":"## Tasks (from plan - 1/4)\n- [x] 1. First thing\n- [ ] 2. Second thing\n- [ ] 3. Third thing with `code` in the title\n- [ ] 4. Fourth thing\n"}'
"$GHTRACK" tick 42 --task 1 >/dev/null
assert_contains "$(cat "${GH_STUB_LOG}.body")" "- [x] 1. First thing" "tick stays ticked"
assert_contains "$(cat "${GH_STUB_LOG}.body")" "(from plan - 1/4)" "counter stable on re-tick"

teardown_scratch
report
