#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/body.sh
. "$PLUGIN_DIR/scripts/lib/body.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
cfg_load
cp "$TESTS_DIR/fixtures/body-sample.md" body.md

# section_get returns content without the heading.
got=$(section_get body.md "Goal")
assert_eq "Ship the thing." "$got" "section_get Goal"

# Tasks section is found despite the counter in the heading.
got=$(section_get body.md "Tasks")
assert_contains "$got" "- [x] 1. First" "section_get Tasks keeps ticks"
assert_not_contains "$got" "## Decisions" "section_get stops at next heading"

# section_replace swaps content and preserves everything else.
printf '## Tasks (from plan - 2/2)\n- [x] 1. First\n- [x] 2. Second\n' >new.md
section_replace body.md "Tasks" new.md >out.md
out=$(cat out.md)
assert_contains "$out" "- [x] 2. Second" "replacement content present"
assert_contains "$out" "Chose A over B" "later section survives"
assert_contains "$out" "Ship the thing." "earlier section survives"
assert_not_contains "$out" "- [ ] 2. Second" "old content gone"
assert_eq "1" "$(grep -c '^## Tasks' out.md)" "exactly one Tasks heading"

# A missing section is appended rather than dropped silently.
printf '## Risks\n- none\n' >risks.md
section_replace body.md "Risks" risks.md >out2.md
assert_contains "$(cat out2.md)" "## Risks" "absent section appended"
assert_eq "1" "$(grep -c '^## Risks' out2.md)" "appended once"

# The final section can be replaced (EOF boundary).
printf '## Decisions\n- New decision (spec)\n' >dec.md
section_replace body.md "Decisions" dec.md >out3.md
assert_contains "$(cat out3.md)" "New decision" "last section replaced"
assert_not_contains "$(cat out3.md)" "Chose A over B" "old last section gone"

# body_put sends the file through gh issue edit. Assertions are checked
# independently (not as one contiguous substring) so a future reordering
# of flags can't break this test on a purely cosmetic basis — but a
# missing --repo still must fail it.
stub_reset
body_put 42 out.md
calls=$(stub_calls)
assert_contains "$calls" "issue edit 42" "body_put calls gh issue edit"
assert_contains "$calls" "--body-file" "body_put passes --body-file"
assert_contains "$calls" "--repo me/proj" "body_put passes --repo"

# body_get reads through gh issue view. Same independent-assertion
# treatment, and it also confirms --repo is passed.
stub_reset
stub_expect_json 'issue view 42' '{"body":"hello body"}'
got_body=$(body_get 42)
assert_eq "hello body" "$got_body" "body_get returns body"
assert_contains "$(stub_calls)" "--repo me/proj" "body_get passes --repo"

teardown_scratch
report
