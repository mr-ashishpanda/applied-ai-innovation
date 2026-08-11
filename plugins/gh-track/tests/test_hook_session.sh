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
