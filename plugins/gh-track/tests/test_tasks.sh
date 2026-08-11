#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/body.sh
. "$PLUGIN_DIR/scripts/lib/body.sh"
# shellcheck source=../scripts/lib/tasks.sh
. "$PLUGIN_DIR/scripts/lib/tasks.sh"

setup_scratch
# Write a real config before cfg_load: repo_slug would otherwise die inside
# a $(...) substitution where set -e does not propagate, silently yielding
# an empty string and producing inert stderr noise (see Task 4 convention).
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
cfg_load

# Extraction finds every task heading and nothing else.
tasks_extract "$TESTS_DIR/fixtures/plan-sample.md" >lines.md
assert_eq "4" "$(wc -l <lines.md | tr -d ' ')" "four tasks extracted"
assert_contains "$(cat lines.md)" "- [ ] 1. First thing" "task 1 line"
assert_contains "$(cat lines.md)" "- [ ] 3. Third thing with \`code\` in the title" "code in title survives"
assert_not_contains "$(cat lines.md)" "99." "inline decoy not matched"

# Unparseable plan exits 4 and says which pattern failed.
printf '# no tasks here\n' >empty-plan.md
# tasks_extract dies via `exit`, which terminates a shell outright -- `||`
# cannot intercept it in the same shell. Run it in its own subshell first
# (matches the pattern in test_resolve.sh) so only that subshell exits;
# the outer command substitution then evaluates `|| true` normally.
out=$( (tasks_extract empty-plan.md) 2>&1 || true)
assert_exit 4 tasks_extract empty-plan.md
assert_contains "$out" "### Task" "error names the pattern"

# Merge preserves ticks by task number, not by position.
printf -- '- [x] 1. First thing\n- [x] 2. Second thing\n' >old.md
tasks_merge old.md lines.md >merged.md
assert_contains "$(cat merged.md)" "- [x] 1. First thing" "tick 1 preserved"
assert_contains "$(cat merged.md)" "- [x] 2. Second thing" "tick 2 preserved"
assert_contains "$(cat merged.md)" "- [ ] 4. Fourth thing" "new task unticked"

# A retitled task keeps its tick and takes the new title.
printf -- '- [x] 1. Old title\n' >old2.md
tasks_merge old2.md lines.md >merged2.md
assert_contains "$(cat merged2.md)" "- [x] 1. First thing" "retitled task keeps tick"

# Render computes the counter from the lines.
tasks_render merged.md >section.md
assert_contains "$(head -1 section.md)" "## Tasks (from plan - 2/4)" "counter 2/4"

# Ticking updates one item and nothing else.
tasks_tick merged.md 4 >ticked.md
assert_contains "$(cat ticked.md)" "- [x] 4. Fourth thing" "task 4 ticked"
assert_contains "$(cat ticked.md)" "- [ ] 3. Third thing" "task 3 untouched"

# Ticking an absent task exits 5 rather than silently doing nothing.
assert_exit 5 tasks_tick merged.md 77

# Ticking twice is idempotent.
tasks_tick ticked.md 4 >ticked2.md
assert_eq "$(cat ticked.md)" "$(cat ticked2.md)" "tick is idempotent"

# I2 regression: --task is interpolated into a grep pattern and a sed
# replacement, and callers are models. `--task '.*'` used to tick every item
# AND replace every item number with the literal `.*`, exit 0, counter
# lying. Validate at both the library and the subcommand boundary.
assert_exit 2 tasks_tick merged.md '.*'
assert_exit 2 tasks_tick merged.md ''
assert_exit 2 tasks_tick merged.md '1x'

stub_reset
stub_expect_json 'issue view 42' '{"body":"## Tasks (from plan - 0/3)\n- [ ] 1. One\n- [ ] 2. Two\n- [ ] 3. Three\n"}'
assert_exit 2 ght tick 42 --task '.*'
assert_eq "0" "$(stub_call_count 'issue edit')" "no body written for a non-numeric --task"

# End to end: tasks subcommand reads the body, writes back one edit.
stub_reset
stub_expect_json 'issue view 42' '{"body":"## Goal\nG\n\n## Tasks (from plan - 1/2)\n- [x] 1. First thing\n- [ ] 2. old\n"}'
ght tasks 42 --plan "$TESTS_DIR/fixtures/plan-sample.md" >/dev/null
assert_eq "1" "$(stub_call_count 'issue edit 42')" "exactly one body edit"

# A body saved by GitHub's web form arrives with CRLF. body_get is the single
# point every body read passes through, so the CR is stripped there: left in,
# it survives into the body written BACK, leaving the issue with permanently
# mixed line endings and defeating every exact-match heading comparison.
stub_reset
stub_expect_json 'issue view 42' \
  '{"body":"## Goal\r\nG\r\n\r\n## Tasks (from plan - 0/2)\r\n- [ ] 1. First thing\r\n- [ ] 2. old\r\n"}'
ght tick 42 --task 1 >/dev/null
sent=$(cat "${GH_STUB_LOG}.body")
assert_contains "$sent" "- [x] 1. First thing" "CRLF body still ticks the right item"
assert_eq "0" "$(tr -cd '\r' <"${GH_STUB_LOG}.body" | wc -c | tr -d '[:space:]')" "no CR written back to GitHub"

# Cleanup: neither subcommand leaks its scratch tmpdir (each holds a full
# copy of the issue body, so a leaked one is not just disk waste but an
# information-hygiene problem). Snapshot mktemp -d's own droppings
# (`tmp.XXXXXXXXXX` under $TMPDIR) before and after each invocation and
# require the sets to be identical -- a trap that fires but no-ops (e.g. a
# single-quoted body that expands $tmp to "" at fire time) would otherwise
# pass every functional assertion above while still leaking a directory per
# call.
tmp_root="${TMPDIR:-/tmp}"
before=$(find "$tmp_root" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | sort)

stub_reset
stub_expect_json 'issue view 42' '{"body":"## Goal\nG\n\n## Tasks (from plan - 1/2)\n- [x] 1. First thing\n- [ ] 2. old\n"}'
ght tasks 42 --plan "$TESTS_DIR/fixtures/plan-sample.md" >/dev/null
after=$(find "$tmp_root" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | sort)
assert_eq "$before" "$after" "tasks leaves no scratch tmpdir behind"

before=$(find "$tmp_root" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | sort)
stub_reset
stub_expect_json 'issue view 42' '{"body":"## Goal\nG\n\n## Tasks (from plan - 1/2)\n- [x] 1. First thing\n- [ ] 2. old\n"}'
ght tick 42 --task 2 >/dev/null
after=$(find "$tmp_root" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | sort)
assert_eq "$before" "$after" "tick leaves no scratch tmpdir behind"

teardown_scratch
report
