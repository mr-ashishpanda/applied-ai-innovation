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

# Stage to Status mapping, every stage covered.
assert_eq "Backlog" "$(stage_to_status backlog)" "backlog -> Backlog"
assert_eq "Todo" "$(stage_to_status spec)" "spec -> Todo"
assert_eq "Todo" "$(stage_to_status triage)" "triage -> Todo"
assert_eq "Todo" "$(stage_to_status planned)" "planned -> Todo"
assert_eq "Doing" "$(stage_to_status building)" "building -> Doing"
assert_eq "Doing" "$(stage_to_status debugging)" "debugging -> Doing"
assert_eq "Review" "$(stage_to_status review)" "review -> Review"
assert_eq "Done" "$(stage_to_status done)" "done -> Done"
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

# issue_stage reads the current stage.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:building"},{"name":"size:m"}]}'
assert_eq "building" "$(issue_stage 42)" "reads current stage"

# new creates at stage:backlog with the kind label.
stub_reset
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/77'
out=$("$GHTRACK" new --kind feature --title "Add a thing")
assert_eq "77" "$out" "new prints the issue number"
calls=$(stub_calls)
assert_contains "$calls" "--label stage:backlog" "created at backlog"
assert_contains "$calls" "--label kind:feature" "kind label applied"

# An invalid kind is rejected before any write.
stub_reset
assert_exit 2 "$GHTRACK" new --kind nonsense --title x
assert_eq "0" "$(stub_call_count 'issue create')" "no write on bad kind"

# show prints compact key=value lines.
stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:building"},{"name":"kind:feature"},{"name":"size:m"}],"body":"## Tasks (from plan - 2/4)\n- [x] 1. a\n- [x] 2. b\n- [ ] 3. c\n- [ ] 4. d\n"}'
out=$("$GHTRACK" show 42)
assert_contains "$out" "stage=building" "show reports stage"
assert_contains "$out" "kind=feature" "show reports kind"
assert_contains "$out" "size=m" "show reports size"
assert_contains "$out" "tasks=2/4" "show reports checklist progress"

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
"$GHTRACK" show 42 >/dev/null
after=$(find "$tmp_root" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | sort)
assert_eq "$before" "$after" "show leaves no scratch tmpdir behind"

teardown_scratch
report
