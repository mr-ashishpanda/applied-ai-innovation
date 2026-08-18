#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json

# Happy path: --epic derives the "<epic-num>.<next>" title from the epic's
# own title text and the highest existing child found anywhere in the repo,
# writes the Epic header into the body, and links the new issue as a
# GitHub-native sub-issue of the epic.
stub_reset
stub_expect_json 'issue view 11 --repo me/proj --json title' '{"title":"Epic 3: Conversation runtime"}'
stub_expect_json 'issue list --repo me/proj' \
  '[{"title":"3.9 contracts: the versioned type package"},{"title":"3.15 repair-pattern standard library"},{"title":"not-numbered issue"},{"title":"13.2 unrelated epic, must not match epicnum 3"}]'
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/92'
stub_expect_json 'issues/92 --jq' '{"id":7001}'
out=$(ght new --kind feature --title "flow-sdk: cross-call dominance" --epic 11)
assert_eq "92" "$out" "new --epic prints the new issue number"
calls=$(stub_calls)
assert_contains "$calls" "--title 3.16 flow-sdk: cross-call dominance" "title numbered one past the highest existing 3.* child"
assert_contains "$calls" "sub_issues -F sub_issue_id=7001" "linked as a GitHub-native sub-issue of the epic"
# This block passes no --body-file, so the epic header travels through the
# INLINE --body argument, which lands directly in the call log (the .body
# snapshot mechanism only captures --body-file's content, not this path).
assert_contains "$calls" "Epic:** #11" "body carries the Epic header"
assert_contains "$calls" "Kind:** feature" "body's Kind matches the real --kind, not a hardcoded value"

# No existing "3.*" child at all: numbering starts at 1.
stub_reset
stub_expect_json 'issue view 20 --repo me/proj --json title' '{"title":"Epic 9: Something else"}'
stub_expect_json 'issue list --repo me/proj' '[{"title":"unrelated"}]'
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/93'
stub_expect_json 'issues/93 --jq' '{"id":7002}'
out=$(ght new --kind bug --title "first child" --epic 20)
assert_eq "93" "$out" "new --epic prints the number"
assert_contains "$(stub_calls)" "--title 9.1 first child" "numbering starts at 1 with no existing children"

# --body-file's content is preserved, with the Epic header prepended.
stub_reset
printf 'Custom body content.\n' >custom-body.md
stub_expect_json 'issue view 11 --repo me/proj --json title' '{"title":"Epic 3: Conversation runtime"}'
stub_expect_json 'issue list --repo me/proj' '[{"title":"3.16 flow-sdk: cross-call dominance"}]'
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/94'
stub_expect_json 'issues/94 --jq' '{"id":7003}'
out=$(ght new --kind feature --title "second child" --epic 11 --body-file custom-body.md)
assert_eq "94" "$out" "new --epic --body-file prints the number"
body=$(cat "$GH_STUB_LOG.body")
assert_contains "$body" "**Epic:** #11" "body-file's content still gets the Epic header"
assert_contains "$body" "Custom body content." "body-file's own content is preserved, not replaced"

# An epic whose title doesn't match "Epic N: ..." is a usage error, and
# nothing is created.
stub_reset
stub_expect_json 'issue view 30 --repo me/proj --json title' '{"title":"Not an epic at all"}'
assert_exit 2 ght new --kind feature --title "orphan" --epic 30
assert_eq "0" "$(stub_call_count 'issue create')" "no issue created when the epic title is malformed"

# An epic issue that cannot be read (deleted, wrong number, no access)
# refuses rather than guessing.
stub_reset
stub_expect 'issue view 999' 1
assert_exit 6 ght new --kind feature --title "orphan" --epic 999
assert_eq "0" "$(stub_call_count 'issue create')" "no issue created when the epic cannot be read"

# Plain `new` (no --epic) is unaffected: no epic lookup, no numbering, no
# sub-issue link, exactly the pre-existing behaviour.
stub_reset
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/95'
out=$(ght new --kind feature --title "ordinary issue, no epic")
assert_eq "95" "$out" "plain new still works"
calls=$(stub_calls)
assert_contains "$calls" "--title ordinary issue, no epic" "title is untouched without --epic"
assert_eq "0" "$(stub_call_count 'issue view')" "no epic lookup without --epic"
assert_eq "0" "$(stub_call_count 'sub_issues')" "no sub-issue link without --epic"
# Plain `new` passes its body inline (`--body "..."`, not `--body-file`), so
# the call log itself -- not the .body snapshot, which only captures
# --body-file and would otherwise still hold the PREVIOUS block's content --
# is the only place to check for an absent Epic header.
assert_not_contains "$calls" "**Epic:**" "no Epic header without --epic"

teardown_scratch
report
