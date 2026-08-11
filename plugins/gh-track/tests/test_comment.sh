#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/comment.sh
. "$PLUGIN_DIR/scripts/lib/comment.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
cfg_load
scratch_slug

assert_eq "<!-- gh-track:spec:abc1234 -->" "$(comment_marker spec abc1234)" "marker format"

# Event classification.
assert_exit 0 comment_is_singleton spec
assert_exit 0 comment_is_singleton "done"
assert_exit 1 comment_is_singleton scope-change
assert_exit 1 comment_is_singleton blocked

assert_exit 0 comment_event_known split
assert_exit 1 comment_is_singleton split

printf 'Spec agreed. Decisions: ...\n' >c.md

# No existing comment -> create.
stub_reset
stub_expect_json 'issues/42/comments' '[]'
out=$(comment_upsert 42 spec abc1234 c.md)
assert_eq "created" "$out" "first post creates"
assert_contains "$(stub_calls)" "issue comment 42" "used gh issue comment"

# Existing singleton with a DIFFERENT sha -> update, not a second comment.
stub_reset
stub_expect_json 'issues/42/comments' \
  '[{"id":555,"body":"<!-- gh-track:spec:oldsha1 -->\nold text"}]'
out=$(comment_upsert 42 spec newsha2 c.md)
assert_eq "updated" "$out" "singleton edits despite new sha"
assert_contains "$(stub_calls)" "issues/comments/555" "PATCHed the existing comment"
assert_eq "0" "$(stub_call_count 'issue comment 42')" "did not post a duplicate"

# Repeatable event with a different sha -> new comment.
stub_reset
stub_expect_json 'issues/42/comments' \
  '[{"id":777,"body":"<!-- gh-track:scope-change:sha0000 -->\nfirst change"}]'
out=$(comment_upsert 42 scope-change sha1111 c.md)
assert_eq "created" "$out" "repeatable event posts again"

# Repeatable event with the SAME sha -> update (idempotent re-run).
stub_reset
stub_expect_json 'issues/42/comments' \
  '[{"id":777,"body":"<!-- gh-track:scope-change:sha1111 -->\nfirst change"}]'
out=$(comment_upsert 42 scope-change sha1111 c.md)
assert_eq "updated" "$out" "same sha is idempotent"

# The marker is prepended to the body sent to GitHub.
stub_reset
stub_expect_json 'issues/42/comments' '[]'
comment_upsert 42 "done" deadbee c.md >/dev/null
sent=$(grep -o '\-\-body-file [^ ]*' "$GH_STUB_LOG" | head -1 | awk '{print $2}')
assert_contains "$(head -1 "$sent")" "<!-- gh-track:done:deadbee -->" "marker is first line"
assert_contains "$(cat "$sent")" "Spec agreed" "author text preserved"

# Unknown event is rejected rather than silently accepted.
assert_exit 2 comment_upsert 42 nonsense abc c.md

# C2 regression. A FAILED lookup is not "no comment exists": treating it as
# such posts a duplicate checkpoint on an issue that already has one and
# reports "created". Empty output still means not-found; failure is a
# non-zero return, and it must stop the post.
stub_reset
stub_expect 'issues/42/comments' 1
assert_exit 1 comment_find 42 spec abc1234 "failed lookup returns non-zero"
assert_exit 6 comment_upsert 42 spec abc1234 c.md
assert_eq "0" "$(stub_call_count 'issue comment 42')" "no comment posted on a failed lookup"
assert_eq "0" "$(stub_call_count '-X PATCH')" "no comment edited on a failed lookup"

# An empty comment list is still a legitimate "not found" and must post.
stub_reset
stub_expect_json 'issues/42/comments' '[]'
out=$(comment_upsert 42 spec abc1234 c.md)
assert_eq "created" "$out" "an empty list still means not found"

# A marker containing jq/regex metacharacters cannot perturb the filter now
# that it travels via jq --arg rather than the program text.
stub_reset
stub_expect_json 'issues/42/comments' \
  '[{"id":901,"body":"<!-- gh-track:scope-change:a\"b\\c -->\nx"}]'
out=$(comment_upsert 42 scope-change 'a"b\c' c.md)
assert_eq "updated" "$out" "quotes and backslashes in a sha still match"

# --paginate yields one array per page; a match on a later page must be found.
stub_reset
stub_expect_json 'issues/42/comments' \
  '[{"id":1,"body":"unrelated"}]
[{"id":222,"body":"<!-- gh-track:plan:zzz -->\nplan text"}]'
out=$(comment_upsert 42 plan zzz c.md)
assert_eq "updated" "$out" "match found on a later page"
assert_contains "$(stub_calls)" "issues/comments/222" "edited the match from page 2"

teardown_scratch
report
