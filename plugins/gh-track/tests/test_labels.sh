#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/body.sh
. "$PLUGIN_DIR/scripts/lib/body.sh"
# shellcheck source=../scripts/lib/labels.sh
. "$PLUGIN_DIR/scripts/lib/labels.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
cfg_load
scratch_slug

# Stage to Status mapping, every stage covered.
assert_eq "Backlog" "$(stage_to_status backlog)" "backlog -> Backlog"
assert_eq "Todo" "$(stage_to_status spec)" "spec -> Todo"
assert_eq "Todo" "$(stage_to_status triage)" "triage -> Todo"
assert_eq "Todo" "$(stage_to_status planned)" "planned -> Todo"
assert_eq "Doing" "$(stage_to_status building)" "building -> Doing"
assert_eq "Doing" "$(stage_to_status debugging)" "debugging -> Doing"
assert_eq "Review" "$(stage_to_status review)" "review -> Review"
assert_eq "Done" "$(stage_to_status "done")" "done -> Done"
assert_exit 1 stage_valid nonsense

# labels_ensure uses --force so re-running cannot fail on existing labels.
stub_reset
labels_ensure
calls=$(stub_calls)
assert_contains "$calls" "label create stage:building --force" "creates stage label with --force"
assert_contains "$calls" "label create kind:bug --force" "creates kind label"
assert_contains "$calls" "label create size:m --force" "creates size label"
assert_contains "$calls" "label create parallel-safe --force" "creates parallel-safe"
assert_contains "$calls" "label create blocked --force" "creates blocked"

# labels_ensure twice produces the same calls (idempotent by --force).
before=$(stub_call_count 'label create')
stub_reset
labels_ensure
assert_eq "$before" "$(stub_call_count 'label create')" "second run identical"

# stage_set swaps in one edit: every other stage removed, new one added.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:spec"},{"name":"kind:feature"}]}'
stage_set 42 planned
calls=$(stub_calls)
assert_contains "$calls" "--add-label stage:planned" "adds new stage"
assert_contains "$calls" "--remove-label stage:spec" "removes old stage"
assert_not_contains "$calls" "--remove-label kind:feature" "leaves non-stage labels"
assert_eq "1" "$(stub_call_count 'issue edit 42')" "single edit call"

# Setting the stage it already has is a no-op edit, not an error.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:planned"}]}'
assert_exit 0 stage_set 42 planned

# C1 regression. The read that shapes the --remove-label list must be able
# to say "I failed" -- an empty answer turns the label SWAP into an ADD and
# leaves the issue carrying TWO stage:* labels, while `stage` prints success
# and exits 0. That corrupts the canonical store the whole design rests on.
stub_reset
stub_expect 'issue view 42' 1
assert_exit 1 issue_labels 42 "failed label read returns non-zero"
assert_exit 6 stage_set 42 review
assert_eq "0" "$(stub_call_count 'issue edit')" "no partial edit on a failed read"

# An issue with genuinely no labels is still a successful read, and the add
# must proceed (no --remove-label flags to compute).
stub_reset
stub_expect_json 'issue view 42' '{"labels":[]}'
assert_exit 0 stage_set 42 review
assert_contains "$(stub_calls)" "--add-label stage:review" "unlabelled issue still gets its stage"
assert_not_contains "$(stub_calls)" "--remove-label" "nothing to remove from an unlabelled issue"

# --- size (A2) -------------------------------------------------------------
# Size is set at the plan checkpoint, not at intake, so it has to work on an
# issue that already exists and may already carry a different size.
assert_exit 0 size_valid s
assert_exit 0 size_valid l
assert_exit 1 size_valid xl
assert_eq "S" "$(size_to_field s)" "s -> S board option"
assert_eq "M" "$(size_to_field m)" "m -> M board option"
assert_eq "L" "$(size_to_field l)" "l -> L board option"

# size_set swaps in ONE edit: other size:* labels removed, stage/kind untouched.
stub_reset
stub_expect_json 'issue view 42' \
  '{"labels":[{"name":"size:s"},{"name":"stage:planned"},{"name":"kind:feature"}]}'
size_set 42 l
calls=$(stub_calls)
assert_contains "$calls" "--add-label size:l" "adds the new size"
assert_contains "$calls" "--remove-label size:s" "removes the old size"
assert_not_contains "$calls" "--remove-label stage:planned" "leaves the stage label alone"
assert_not_contains "$calls" "--remove-label kind:feature" "leaves the kind label alone"
assert_eq "1" "$(stub_call_count 'issue edit 42')" "single edit call"

# Setting the size an issue already has is a successful no-op.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"size:m"}]}'
assert_exit 0 size_set 42 m
assert_not_contains "$(stub_calls)" "--remove-label" "nothing to remove when the size is unchanged"

# C1 discipline: the read that shapes the --remove-label list must be able to
# say "I failed". An empty answer would turn the SWAP into an ADD and leave
# the issue carrying TWO size:* labels while the command printed success.
stub_reset
stub_expect 'issue view 42' 1
assert_exit 6 size_set 42 m
assert_eq "0" "$(stub_call_count 'issue edit')" "no partial edit on a failed read"

# An issue with genuinely no labels is still a successful read.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[]}'
assert_exit 0 size_set 42 s
assert_contains "$(stub_calls)" "--add-label size:s" "unlabelled issue still gets its size"

# The subcommand: valid run, bad size, non-numeric issue number.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"size:s"}]}'
out=$(ght size 42 m)
assert_eq "size set: #42 -> m" "$out" "size prints a one-line confirmation"
assert_contains "$(stub_calls)" "--add-label size:m" "size subcommand edits the label"

stub_reset
assert_exit 2 ght size 42 xl
assert_exit 2 ght size 42
assert_exit 2 ght size notanumber m
assert_eq "0" "$(stub_call_count 'issue edit')" "no write on a bad size argument"

# issue_stage reads the current stage.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:building"},{"name":"size:m"}]}'
assert_eq "building" "$(issue_stage 42)" "reads current stage"

# new creates at stage:backlog with the kind label.
stub_reset
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/77'
out=$(ght new --kind feature --title "Add a thing")
assert_eq "77" "$out" "new prints the issue number"
calls=$(stub_calls)
assert_contains "$calls" "--label stage:backlog" "created at backlog"
assert_contains "$calls" "--label kind:feature" "kind label applied"
# A1: with no project configured, running label-only is a chosen setup, not a
# failure -- `new` must not reach for a board that was never set up.
assert_eq "0" "$(stub_call_count 'project ')" "no board calls when no project is configured"

# An invalid kind is rejected before any write.
stub_reset
assert_exit 2 ght new --kind nonsense --title x
assert_eq "0" "$(stub_call_count 'issue create')" "no write on bad kind"

# show prints compact key=value lines.
stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:building"},{"name":"kind:feature"},{"name":"size:m"}],"body":"## Tasks (from plan - 2/4)\n- [x] 1. a\n- [x] 2. b\n- [ ] 3. c\n- [ ] 4. d\n"}'
out=$(ght show 42)
assert_contains "$out" "stage=building" "show reports stage"
assert_contains "$out" "kind=feature" "show reports kind"
assert_contains "$out" "size=m" "show reports size"
assert_contains "$out" "tasks=2/4" "show reports checklist progress"

# I5 regression: a body saved by GitHub's web form has CRLF line endings.
# Every line-anchored pattern in show must still match, and the artifact
# links must not be captured greedily to the last `)` on the line.
crlf_body='## Artifacts\r\n- Spec: [docs/s.md](https://github.com/me/proj/blob/x/docs/s.md) (pinned)\r\n- Plan: [docs/p.md](https://github.com/me/proj/blob/x/docs/p.md)\r\n\r\n## Tasks (from plan - 1/2)\r\n- [x] 1. a\r\n- [ ] 2. b\r\n'
stub_reset
stub_expect_json 'issue view 42' \
  "{\"number\":42,\"title\":\"T\",\"state\":\"OPEN\",\"labels\":[{\"name\":\"stage:spec\"}],\"body\":\"$crlf_body\"}"
out=$(ght show 42)
assert_contains "$out" "spec=https://github.com/me/proj/blob/x/docs/s.md" "CRLF body still yields the spec link"
assert_contains "$out" "plan=https://github.com/me/proj/blob/x/docs/p.md" "CRLF body still yields the plan link"
assert_contains "$out" "tasks=1/2" "CRLF body still yields the checklist counter"

# Cleanup: show does not leak its scratch tmpdir. show's trap must expand
# $tmp at registration time (double-quoted), not at fire time (single-
# quoted) -- by fire time the function has returned and `local tmp` is out
# of scope, so a single-quoted trap becomes `rm -rf ""` and leaks a
# directory holding the full issue body. Snapshot mktemp -d's own
# droppings (`tmp.XXXXXXXXXX` under $TMPDIR) before and after and require
# the sets to be identical.
tmp_root="${TMPDIR:-/tmp}"
before=$(find "$tmp_root" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | sort)
stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:building"}],"body":"## Tasks (from plan - 0/1)\n- [ ] 1. a\n"}'
ght show 42 >/dev/null
after=$(find "$tmp_root" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | sort)
assert_eq "$before" "$after" "show leaves no scratch tmpdir behind"

teardown_scratch
report
