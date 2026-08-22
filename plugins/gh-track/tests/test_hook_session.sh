#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

HOOK="$PLUGIN_DIR/hooks/session-context.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
git checkout -q -b 42-thing

# With a resolvable issue, inject stage and next action.
stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"Add tracking","state":"OPEN","labels":[{"name":"stage:planned"},{"name":"kind:feature"}],"body":"## Tasks (from plan - 2/4)\n- [x] 1. a\n- [x] 2. b\n- [ ] 3. c\n- [ ] 4. d\n"}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_contains "$out" "#42" "names the issue"
assert_contains "$out" "Add tracking" "names the title"
assert_contains "$out" "stage=planned" "reports the stage"
assert_contains "$out" "2/4" "reports checklist progress"
assert_contains "$out" "execute" "suggests the next action for stage planned"

# Each stage suggests a different next action.
stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:backlog"}],"body":""}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_contains "$out" "brainstorming" "backlog suggests brainstorming"
assert_contains "$out" "'pickup' checkpoint" "backlog names the pickup checkpoint"

stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:spec"}],"body":""}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_contains "$out" "writing-plans" "spec suggests writing-plans"

stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:triage"},{"name":"kind:bug"}],"body":""}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_contains "$out" "systematic-debugging" "bug triage suggests debugging skill"
assert_contains "$out" "repro" "triage suggests the repro checkpoint"

# A feature or chore picked up but not yet spec'd sits at the SAME
# stage:triage label as a bug, but must get brainstorming guidance, not
# "this is a bug" — the two tracks share the label, not the message.
stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:triage"},{"name":"kind:feature"}],"body":""}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_contains "$out" "brainstorming" "feature triage suggests brainstorming"
assert_not_contains "$out" "systematic-debugging" "feature triage's message is distinct from a bug's"
assert_not_contains "$out" "This is a bug" "feature triage does not call the issue a bug"

stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:triage"},{"name":"kind:chore"}],"body":""}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_contains "$out" "brainstorming" "chore triage also gets the non-bug message"
assert_not_contains "$out" "systematic-debugging" "chore triage's message is distinct from a bug's"

stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:debugging"},{"name":"kind:bug"}],"body":""}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_contains "$out" "root-cause" "debugging suggests posting the root-cause checkpoint"
assert_contains "$out" "stage building" "debugging suggests moving to stage building"
assert_not_contains "$out" "systematic-debugging" "debugging's message is distinct from triage's"

stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:building"},{"name":"kind:feature"}],"body":""}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_contains "$out" "ghtrack tick" "building suggests ticking checklist items"
assert_contains "$out" "'blocked'" "building suggests posting blocked if stalled"
assert_not_contains "$out" "root-cause" "building's message is distinct from debugging's"

stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:review"},{"name":"kind:feature"}],"body":""}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_contains "$out" "'done' checkpoint once merged" "review suggests posting done once merged"
assert_not_contains "$out" "ghtrack tick" "review's message is distinct from building's"

stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:done"},{"name":"kind:feature"}],"body":""}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_contains "$out" "Confirm before starting new work" "done suggests confirming before new work"
assert_not_contains "$out" "once merged" "done's message is distinct from review's"

# An issue with NO stage:* label at all must not fall through to silence -
# that would be indistinguishable from "no issue resolved" and would strand
# exactly the session this hook exists to orient.
stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"kind:feature"}],"body":""}'
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_exit 0 test -n "$out"
assert_contains "$out" "ghtrack stage" "unknown stage names the remedy"

# No resolvable issue - silent.
git checkout -q -b spike/none
out=$(printf '{"cwd":"%s","source":"startup"}' "$SCRATCH" | bash "$HOOK")
assert_eq "" "$out" "silent without an issue"

# Outside a git repo - silent, exit 0.
out=$(printf '{"cwd":"/tmp","source":"startup"}' | bash "$HOOK")
assert_eq "" "$out" "silent outside a repo"
assert_exit 0 bash -c "printf '{\"cwd\":\"/tmp\"}' | bash '$HOOK'"

# Malformed payload - silent, exit 0.
assert_exit 0 bash -c "printf 'garbage' | bash '$HOOK'"

teardown_scratch
report
