#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/board.sh
. "$PLUGIN_DIR/scripts/lib/board.sh"

setup_scratch
printf '%s' '{"repo":"me/proj","project":3}' >.claude/gh-track/config.json
cfg_load
scratch_slug

# Missing project scope is detected and reported, not fatal.
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'read:project'"
assert_exit 1 board_has_scope

stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'project'"
assert_exit 0 board_has_scope

# board_ids resolves and caches project/field/option ids.
stub_reset
stub_expect_json 'auth status' "Token scopes: 'project'"
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"},{"id":"O_doing","name":"Doing"},{"id":"O_done","name":"Done"},{"id":"O_backlog","name":"Backlog"},{"id":"O_review","name":"Review"}]},{"id":"F_size","name":"Size","options":[{"id":"O_s","name":"S"},{"id":"O_m","name":"M"},{"id":"O_l","name":"L"}]}]}'
stub_expect_json 'project view' '{"id":"PVT_abc"}'
assert_exit 0 board_ids
assert_eq "PVT_abc" "$(state_get '.board.projectId')" "project id cached"
assert_eq "F_status" "$(state_get '.board.statusFieldId')" "status field id cached"
assert_eq "O_doing" "$(state_get '.board.statusOptions.Doing')" "status option cached"

# Cached ids mean no repeat lookups.
stub_reset
assert_exit 0 board_ids
assert_eq "0" "$(stub_call_count 'project field-list')" "ids read from cache"

# I1 regression. projectId is persisted BEFORE field-list runs, so gating the
# cache short-circuit on projectId alone meant one transient field-list
# failure cached a half-built entry that no later run ever retried: the board
# stayed degraded forever and the warning blamed the project's field
# configuration rather than a cache file the user cannot see.
rm -f .claude/gh-track/state.json
stub_reset
stub_expect_json 'auth status' "Token scopes: 'project'"
stub_expect 'project field-list' 1
stub_expect_json 'project view' '{"id":"PVT_x"}'
assert_exit 1 board_ids
assert_eq "PVT_x" "$(state_get '.board.projectId')" "partial cache is written"
assert_eq "" "$(state_get '.board.statusFieldId')" "no status field cached after the failure"

stub_reset
stub_expect_json 'auth status' "Token scopes: 'project'"
stub_expect_json 'project field-list' '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"},{"id":"O_doing","name":"Doing"},{"id":"O_done","name":"Done"},{"id":"O_backlog","name":"Backlog"},{"id":"O_review","name":"Review"}]},{"id":"F_size","name":"Size","options":[{"id":"O_s","name":"S"},{"id":"O_m","name":"M"},{"id":"O_l","name":"L"}]}]}'
stub_expect_json 'project view' '{"id":"PVT_x"}'
assert_exit 0 board_ids
assert_eq "1" "$(stub_call_count 'project field-list')" "a healthy later run retries field-list"
assert_eq "F_status" "$(state_get '.board.statusFieldId')" "the retry completes the cache"

# board_status_set adds the item if needed, then edits the field.
stub_reset
stub_expect_json 'project item-list' \
  '{"items":[{"id":"PVTI_42","content":{"number":42}}]}'
assert_exit 0 board_status_set 42 Doing
calls=$(stub_calls)
assert_contains "$calls" "item-edit" "edits the item field"
assert_contains "$calls" "PVTI_42" "targets the right item"
assert_contains "$calls" "O_doing" "uses the Doing option id"
assert_eq "0" "$(stub_call_count 'item-add')" "existing item not re-added"

# An issue not yet on the board is added first.
stub_reset
stub_expect_json 'project item-list' '{"items":[]}'
stub_expect_json 'project item-add' '{"id":"PVTI_new"}'
assert_exit 0 board_status_set 99 Todo
calls=$(stub_calls)
assert_contains "$calls" "item-add" "absent issue added to board"
assert_contains "$calls" "PVTI_new" "new item id used"

# An unknown status is rejected before any write.
stub_reset
assert_exit 1 board_status_set 42 Nonsense

# A failing gh call warns and returns 1 rather than dying.
stub_reset
stub_expect 'project item-list' 1
assert_exit 1 board_status_set 42 Doing

# item-list hitting the cap with no match means absence is unproven: warn
# and refuse to add a possibly-duplicate card.
stub_reset
capped_items=$(jq -n --argjson n "$BOARD_ITEM_LIMIT" \
  '{items: [range($n) | {id: ("PVTI_" + (. | tostring)), content: {number: (1000 + .)}}]}')
stub_expect_json 'project item-list' "$capped_items"
assert_exit 1 board_status_set 42 Doing
assert_eq "0" "$(stub_call_count 'item-add')" "capped list: no duplicate card created"

# item-list below the cap with no match still proves absence: add proceeds.
stub_reset
under_cap_items=$(jq -n \
  '{items: [range(3) | {id: ("PVTI_" + (. | tostring)), content: {number: (1000 + .)}}]}')
stub_expect_json 'project item-list' "$under_cap_items"
stub_expect_json 'project item-add' '{"id":"PVTI_below_cap"}'
assert_exit 0 board_status_set 42 Doing
assert_contains "$(stub_calls)" "item-add" "below cap: absent issue still added"

# --- new adds the issue to the board (A1) ----------------------------------
# `new` used to create the issue and stop there, so every issue was invisible
# on the kanban until its first `stage` transition -- and capture-only intake
# items are branchless and may never get one, so they never appeared at all.
stub_reset
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/77'
stub_expect_json 'project item-list' '{"items":[]}'
stub_expect_json 'project item-add' '{"id":"PVTI_77"}'
out=$("$GHTRACK" new --kind feature --title "Add a thing")
assert_eq "77" "$out" "new still prints only the issue number"
calls=$(stub_calls)
assert_contains "$calls" "item-add" "new adds the new issue to the board"
assert_contains "$calls" "/issues/77" "the card points at the issue just created"
assert_contains "$calls" "O_backlog" "the card lands in Backlog, matching stage:backlog"

# A board failure must NOT fail `new`: the issue already exists and its
# number is the command's entire contract. The board is a mirror.
stub_reset
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/78'
stub_expect 'project item-list' 1
set +e
out=$("$GHTRACK" new --kind bug --title "b" 2>/dev/null)
rc=$?
set -e
assert_eq "0" "$rc" "a board failure does not fail new"
assert_eq "78" "$out" "the issue number is still printed when the board fails"

# --size at intake writes the label and the board's Size field together.
stub_reset
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/79'
stub_expect_json 'project item-list' '{"items":[]}'
stub_expect_json 'project item-add' '{"id":"PVTI_79"}'
"$GHTRACK" new --kind chore --title c --size l >/dev/null
calls=$(stub_calls)
assert_contains "$calls" "--label size:l" "the size label is applied at creation"
assert_contains "$calls" "O_l" "the board Size field is written with it"

# --- size mirrors the board's Size field (A2) ------------------------------
stub_reset
stub_expect_json 'issue view 55' '{"labels":[{"name":"size:s"}]}'
stub_expect_json 'project item-list' '{"items":[{"id":"PVTI_55","content":{"number":55}}]}'
"$GHTRACK" size 55 m >/dev/null
calls=$(stub_calls)
assert_contains "$calls" "item-edit" "size edits the board field"
assert_contains "$calls" "F_size" "size targets the Size field, not Status"
assert_contains "$calls" "O_m" "size uses the M option id for size:m"

# ...and a board failure is a warning there too: the label is what counts.
stub_reset
stub_expect_json 'issue view 55' '{"labels":[]}'
stub_expect 'project item-list' 1
assert_exit 0 "$GHTRACK" size 55 l

# --- init ------------------------------------------------------------------
# T6: tear the first scratch repo down before building another, or each run
# leaks one and ORIG_PWD is clobbered to the first scratch path so teardown
# cd's somewhere unintended.
teardown_scratch
setup_scratch
# Re-point GHT_CONFIG/GHT_STATE at the NEW scratch repo; they still name the
# torn-down one otherwise, so every state assertion below would read nothing.
cfg_load

# init creates labels, ensures the board, caches its ids, and writes config.
# The `project view` response is what makes board_ensure actually SUCCEED:
# without it board_ids failed, init reported `board: skipped`, state.json was
# never written -- and the assertions below all passed anyway, because they
# only checked calls made BEFORE the failure. Field/option caching during
# init had zero coverage.
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'project'"
stub_expect_json 'repo view' '{"nameWithOwner":"me/proj"}'
stub_expect_json 'project list' '{"projects":[]}'
stub_expect_json 'project create' '{"number":9,"id":"PVT_new"}'
stub_expect_json 'project view' '{"id":"PVT_new"}'
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}'
out=$("$GHTRACK" init)
assert_contains "$(stub_calls)" "label create stage:backlog" "init creates labels"
assert_contains "$(stub_calls)" "project create" "init creates the board"
assert_eq "9" "$(jq -r .project .claude/gh-track/config.json)" "config records project"
assert_eq "me/proj" "$(jq -r .repo .claude/gh-track/config.json)" "config records repo"
assert_contains "$out" "board=project 9 ready" "init reports the board ready"
assert_contains "$out" "init=complete" "init reports completion"
assert_eq "PVT_new" "$(state_get '.board.projectId')" "init caches the project id"
assert_eq "F_status" "$(state_get '.board.statusFieldId')" "init caches the status field id"
assert_eq "O_todo" "$(state_get '.board.statusOptions.Todo')" "init caches the status options"

# init twice does not create a second project.
stub_reset
stub_expect_json 'auth status' "Token scopes: 'project'"
stub_expect_json 'repo view' '{"nameWithOwner":"me/proj"}'
stub_expect_json 'project view' '{"id":"PVT_new"}'
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}'
"$GHTRACK" init >/dev/null
assert_eq "0" "$(stub_call_count 'project create')" "init is idempotent"

# state.json is gitignored by init.
assert_contains "$(cat .gitignore)" ".claude/gh-track/state.json" "init gitignores state"

# C4 regression: a hand-edited .gitignore frequently has no trailing newline.
# Appending blind glued the entry onto the user's last rule -- breaking that
# rule AND leaving state.json unignored -- and because check-ignore then
# still failed, re-running appended a SECOND broken line instead of repairing.
teardown_scratch
setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
printf 'node_modules\n.env\nbuild' >.gitignore
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo'"
"$GHTRACK" init >/dev/null
assert_exit 0 git check-ignore -q .claude/gh-track/state.json
assert_eq "build" "$(sed -n 3p .gitignore)" "the user's last rule is left intact"
assert_eq ".claude/gh-track/state.json" "$(sed -n 4p .gitignore)" "the entry lands on its own line"
"$GHTRACK" init >/dev/null
assert_eq "1" "$(grep -c 'gh-track/state.json' .gitignore)" "re-running does not append a second entry"

# I4 regression: --force makes "already exists" a non-error; it does NOT make
# an auth or permission failure one. `init` used to print "labels: ensured"
# and exit 0 when every single label creation had failed.
teardown_scratch
setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
stub_reset
stub_expect 'label create' 1
stub_expect_json 'auth status' "Token scopes: 'repo'"
set +e
out=$("$GHTRACK" init 2>&1)
rc=$?
set -e
assert_eq "1" "$rc" "init fails when label creation fails"
assert_contains "$out" "labels=FAILED 16 of 16" "init reports how many labels failed"
assert_not_contains "$out" "labels=ensured" "init does not claim labels were ensured"
assert_contains "$out" "init=incomplete" "init summary surfaces the problem"

# A partial failure is reported as partial.
stub_reset
stub_expect 'label create size:l' 1
stub_expect_json 'auth status' "Token scopes: 'repo'"
set +e
out=$("$GHTRACK" init 2>&1)
rc=$?
set -e
assert_eq "1" "$rc" "one failed label still fails init"
assert_contains "$out" "labels=FAILED 1 of 16" "partial failure counted exactly"

# B1 regression: `project list` drives a CREATE, so a FAILED list must not
# read as "no project with this title". Piped straight into jq, an errored
# list produced the same empty answer as an empty account and fell through to
# `project create` -- a repository that already had a board got a SECOND one,
# reported as `init=complete`, exit 0.
teardown_scratch
setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'project'"
stub_expect 'project list' 1
stub_expect_json 'project create' '{"number":9,"id":"PVT_dup"}'
out=$("$GHTRACK" init 2>&1)
assert_eq "0" "$(stub_call_count 'project create')" "a failed project list creates no board"
assert_contains "$out" "board=skipped" "init reports the board as not set up"
assert_eq "" "$(jq -r '.project // empty' .claude/gh-track/config.json)" \
  "no project number recorded from a failed list"

# A list that "succeeds" with something unparseable is the same hazard.
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'project'"
stub_expect_json 'project list' '<html>504 Gateway Timeout</html>'
stub_expect_json 'project create' '{"number":9,"id":"PVT_dup"}'
out=$("$GHTRACK" init 2>&1)
assert_eq "0" "$(stub_call_count 'project create')" "an unparseable project list creates no board"
assert_contains "$out" "board=skipped" "unparseable list also reports the board as not set up"

# The healthy path still creates one: this must refuse failures, not everything.
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'project'"
stub_expect_json 'project list' '{"projects":[]}'
stub_expect_json 'project create' '{"number":12,"id":"PVT_ok"}'
stub_expect_json 'project view' '{"id":"PVT_ok"}'
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}'
out=$("$GHTRACK" init 2>&1)
assert_eq "1" "$(stub_call_count 'project create')" "an empty list still creates the board"
assert_eq "12" "$(jq -r .project .claude/gh-track/config.json)" "the new project is recorded"

# An EXISTING board with a matching title is linked, never duplicated.
teardown_scratch
setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'project'"
stub_expect_json 'project list' '{"projects":[{"number":5,"title":"proj"}]}'
stub_expect_json 'project view' '{"id":"PVT_existing"}'
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}'
"$GHTRACK" init >/dev/null
assert_eq "0" "$(stub_call_count 'project create')" "an existing board is linked, not duplicated"
assert_eq "5" "$(jq -r .project .claude/gh-track/config.json)" "config records the existing board"

teardown_scratch
report
