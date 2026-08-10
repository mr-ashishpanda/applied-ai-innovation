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

# init creates labels, ensures the board, and writes config.
setup_scratch
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'project'"
stub_expect_json 'repo view' '{"nameWithOwner":"me/proj"}'
stub_expect_json 'project list' '{"projects":[]}'
stub_expect_json 'project create' '{"number":9,"id":"PVT_new"}'
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}'
"$GHTRACK" init >/dev/null
assert_contains "$(stub_calls)" "label create stage:backlog" "init creates labels"
assert_contains "$(stub_calls)" "project create" "init creates the board"
assert_eq "9" "$(jq -r .project .claude/gh-track/config.json)" "config records project"
assert_eq "me/proj" "$(jq -r .repo .claude/gh-track/config.json)" "config records repo"

# init twice does not create a second project.
stub_reset
stub_expect_json 'auth status' "Token scopes: 'project'"
stub_expect_json 'repo view' '{"nameWithOwner":"me/proj"}'
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}'
"$GHTRACK" init >/dev/null
assert_eq "0" "$(stub_call_count 'project create')" "init is idempotent"

# state.json is gitignored by init.
assert_contains "$(cat .gitignore)" ".claude/gh-track/state.json" "init gitignores state"

teardown_scratch
report
