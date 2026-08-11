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
scratch_slug
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

# C3 regression: a sibling section sharing the heading prefix -- exactly what
# a human adds to a "control panel" issue -- must survive, and the checklist
# heading must not be duplicated. Unanchored prefix matching silently DELETED
# `## Tasks Notes` and inserted the replacement heading twice, while
# section_get returned the union of both sections.
cat >sib.md <<'SIB'
## Goal
G

## Tasks (from plan - 1/2)
- [x] 1. First
- [ ] 2. Second

## Tasks Notes
Task 2 is blocked on the vendor.

## Decisions
- Chose A over B
SIB
got=$(section_get sib.md "Tasks")
assert_contains "$got" "- [ ] 2. Second" "section_get still finds the counter heading"
assert_not_contains "$got" "vendor" "section_get does not absorb the sibling section"
printf '## Tasks (from plan - 2/2)\n- [x] 1. First\n- [x] 2. Second\n' >sibnew.md
section_replace sib.md "Tasks" sibnew.md >sibout.md
sibout=$(cat sibout.md)
assert_contains "$sibout" "## Tasks Notes" "sibling heading survives replacement"
assert_contains "$sibout" "vendor" "sibling content survives replacement"
assert_contains "$sibout" "- [x] 2. Second" "replacement still applied"
assert_eq "1" "$(grep -c '^## Tasks (from plan' sibout.md)" "checklist heading not duplicated"
assert_eq "1" "$(grep -c '^## Tasks Notes' sibout.md)" "sibling heading not duplicated"

# The same, with the sibling BEFORE the checklist -- this is what requires the
# heading match to be anchored rather than merely first-wins: an unanchored
# prefix treats `## Tasks Notes` as the Tasks section itself, so section_get
# returns the prose and section_replace overwrites the human's notes with the
# checklist while the real checklist section is left untouched below.
cat >sib2.md <<'SIB2'
## Tasks Notes
Task 2 is blocked on the vendor.

## Tasks (from plan - 1/2)
- [x] 1. First
- [ ] 2. Second

## Decisions
- Chose A over B
SIB2
got=$(section_get sib2.md "Tasks")
assert_contains "$got" "- [ ] 2. Second" "leading sibling does not shadow the checklist"
assert_not_contains "$got" "vendor" "leading sibling content not returned as Tasks"
section_replace sib2.md "Tasks" sibnew.md >sib2out.md
sib2out=$(cat sib2out.md)
assert_contains "$sib2out" "vendor" "leading sibling content survives replacement"
assert_contains "$sib2out" "- [x] 2. Second" "checklist replaced, not the sibling"
assert_eq "1" "$(grep -c '^## Tasks (from plan' sib2out.md)" "one checklist heading with a leading sibling"
assert_eq "1" "$(grep -c '^## Tasks Notes' sib2out.md)" "leading sibling heading kept once"

# An exact heading with no counter still matches.
printf '## Tasks\n- [ ] 1. a\n\n## After\nx\n' >exact.md
assert_eq "- [ ] 1. a" "$(section_get exact.md "Tasks" | head -1)" "exact heading matches"

# A duplicated heading resolves to the FIRST section, not their union.
printf '## Tasks\nfirst\n\n## Tasks\nsecond\n' >dup.md
got=$(section_get dup.md "Tasks")
assert_contains "$got" "first" "first duplicate section returned"
assert_not_contains "$got" "second" "second duplicate section not merged in"

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

# cmd_body dispatch: no --file reads the current body verbatim.
stub_reset
stub_expect_json 'issue view 42' '{"body":"hello from github"}'
got_cli=$(ght body 42)
assert_eq "hello from github" "$got_cli" "ghtrack body N with no --file prints the current body"

# cmd_body dispatch: --file still replaces wholesale.
stub_reset
printf 'new body\n' >replace.md
msg=$(ght body 42 --file replace.md)
assert_contains "$msg" "body updated: #42" "ghtrack body N --file confirms the update"
assert_contains "$(stub_calls)" "issue edit 42" "ghtrack body N --file calls gh issue edit"

teardown_scratch
report
