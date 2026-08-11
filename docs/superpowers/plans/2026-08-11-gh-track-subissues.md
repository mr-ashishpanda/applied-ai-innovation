# gh-track sub-issues Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ghtrack split` (a GitHub-native sub-issue per plan 2+) and teach `ghtrack stage` to roll a parent's displayed stage up from its sub-issues, per the approved spec addendum at `docs/superpowers/specs/2026-08-11-gh-track-subissues-design.md`.

**Architecture:** Two additions to the existing `ghtrack` CLI: a `split` subcommand that creates and links a sub-issue (reusing `cmd_new`'s issue-create/board-add pattern), and an extension to `stage` that recomputes a parent's rolled-up stage whenever a sub-issue's own stage changes (or the parent's does). A new durable `plan1:*` label family records a split parent's own progress independently of its rolled-up `stage:*` label, since the two can diverge and only one of them is recoverable from the rolled-up value alone.

**Tech Stack:** bash 3.2+, `gh` CLI (REST via `gh api`), `jq`. Same recording-stub test harness already in `plugins/gh-track/tests/`.

## Global Constraints

- bash 3.2+, `git`, `jq`, `gh` 2.x authenticated (existing project floor).
- Every mutating subcommand must be idempotent (existing project invariant; proved by tests, not just claimed).
- `board.sh` and anything it calls must never call `die` — warn and return non-zero instead, so a board problem never blocks a label write.
- Any `gh` read that shapes a write must distinguish "read failed" from "read succeeded with an empty answer," and must refuse the write (exit 6) on a failed read rather than assume emptiness.
- Relationship state that gh-track needs to recover correctly in a **fresh clone or worktree** (no local `state.json`) must live in a GitHub-durable place (a label, an issue field) — never rely on `state.json` alone for anything whose staleness would silently corrupt a canonical value. `state.json` remains fine for genuinely disposable/local bookkeeping (debounce hashes, one-shot idempotency caches whose worst failure mode is a harmless duplicate, not silent wrong state).
- All new code must pass `shellcheck` (run by `tests/run`) and the full existing suite (`bash tests/run`), not just the new tests.
- Every new subcommand or library function follows the existing file's established conventions exactly (see per-task file references below) rather than introducing a new style.

---

### Task 1: `plan1:*` label — a split parent's own stage, durably

**Why this exists:** Once a parent has a sub-issue, its `stage:*` label is going to be **rolled up** (Task 4) — the *displayed* stage may sit below what plan 1 (which still lives directly on the parent) has actually reached, because a sub-issue is lagging. Recovering plan 1's *true* stage later (e.g. when the lagging sub-issue finally catches up) requires remembering it separately from the rolled-up label. `state.json` is git-ignored and cannot be trusted for this — a fresh clone or a fresh subagent worktree must reconstruct it. A label is exactly as durable as `stage:*` itself, so this reuses that same mechanism.

**Files:**
- Modify: `plugins/gh-track/scripts/lib/labels.sh`
- Test: `plugins/gh-track/tests/test_labels.sh`

**Interfaces:**
- Produces: `issue_plan1_stage(N)` → prints the current `plan1:*` value for issue N, or empty. `plan1_set(N, STAGE)` → swaps the `plan1:*` label, same refuse-on-failed-read discipline as `stage_set`. Both consumed by `subissues.sh` (Task 2) and `cmd_split.sh` (Task 3).

- [ ] **Step 1: Write the failing tests**

Add to `plugins/gh-track/tests/test_labels.sh`, right after the existing `issue_stage` test (after line 136, before the `new creates at stage:backlog` block):

```bash
# --- plan1:* (sub-issues addendum) --------------------------------------
# plan1:* mirrors stage:* exactly, but is never mirrored to the board and
# never touched by ordinary stage_set -- it is gh-track's own durable memory
# of a split parent's own progress, independent of its rolled-up display.
stub_reset
stub_expect_json 'issue view 2' '{"labels":[{"name":"plan1:building"}]}'
assert_eq "building" "$(issue_plan1_stage 2)" "reads current plan1 stage"

stub_reset
stub_expect_json 'issue view 2' '{"labels":[{"name":"plan1:building"},{"name":"stage:building"}]}'
plan1_set 2 review
calls=$(stub_calls)
assert_contains "$calls" "--add-label plan1:review" "adds the new plan1 stage"
assert_contains "$calls" "--remove-label plan1:building" "removes the old plan1 stage"
assert_not_contains "$calls" "--remove-label stage:building" "leaves the real stage:* label alone"
assert_eq "1" "$(stub_call_count 'issue edit 2')" "single edit call"

# Setting the plan1 stage it already has is a no-op edit, not an error.
stub_reset
stub_expect_json 'issue view 2' '{"labels":[{"name":"plan1:review"}]}'
assert_exit 0 plan1_set 2 review

# C1 discipline, same as stage_set/size_set: a failed label read must refuse
# the write rather than turn the SWAP into an ADD.
stub_reset
stub_expect 'issue view 2' 1
assert_exit 6 plan1_set 2 review
assert_eq "0" "$(stub_call_count 'issue edit')" "no partial edit on a failed read"

# labels_ensure creates a plan1:* label for every stage, same as stage:*.
stub_reset
labels_ensure
assert_contains "$(stub_calls)" "label create plan1:building --force" "creates plan1 label"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd plugins/gh-track && bash tests/test_labels.sh
```

Expected: FAIL — `issue_plan1_stage: command not found` (or similar) for the first new assertion.

- [ ] **Step 3: Implement `plan1:*` in `labels.sh`**

In `labels_ensure`, add a second loop right after the existing `stage:*` loop (which is `for s in $GHT_STAGES; do label_create "stage:$s" ... ; done`):

```bash
  for s in $GHT_STAGES; do
    label_create "plan1:$s" A9D1F5 "gh-track: a split parent's own stage, independent of its rolled-up display"
  done
```

After the existing `issue_stage()` function, add:

```bash
# issue_plan1_stage N — a split parent's own recorded stage, or empty if this
# issue has never been split (see subissues.sh's rollup_apply).
issue_plan1_stage() {
  issue_labels "$1" | sed -n 's/^plan1://p' | head -1
}

# plan1_set N STAGE — swap the plan1:* label. Same swap-and-refuse discipline
# as stage_set, but this label is never mirrored to the board: it is
# gh-track's own bookkeeping, never a user-facing status.
plan1_set() {
  local issue=$1 want=$2
  stage_valid "$want" || die "unknown stage: $want" 2

  local args="" s current
  current=$(issue_labels "$issue") \
    || die "cannot read current labels for issue #$issue; refusing to change plan1 stage (no write performed)" 6
  for s in $GHT_STAGES; do
    if [ "$s" != "$want" ] && printf '%s\n' "$current" | grep -qx "plan1:$s"; then
      args="$args --remove-label plan1:$s"
    fi
  done

  # shellcheck disable=SC2086 # args is a deliberately word-split flag list
  gh issue edit "$issue" --repo "$GHT_SLUG" \
    --add-label "plan1:$want" $args >/dev/null
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/test_labels.sh
```

Expected: all checks pass, including the new ones.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-track/scripts/lib/labels.sh plugins/gh-track/tests/test_labels.sh
git commit -m "feat(gh-track): add plan1:* label for split parents"
```

---

### Task 2: `subissues.sh` — parent/child reads, link, rollup

**Files:**
- Create: `plugins/gh-track/scripts/lib/subissues.sh`
- Test: `plugins/gh-track/tests/test_subissues.sh` (new file)

**Interfaces:**
- Consumes: `issue_stage(N)`, `issue_plan1_stage(N)`, `stage_set(N, STAGE)` from `labels.sh` (Task 1); `$GHT_SLUG` from `config.sh`; `warn`/`die` from `util.sh`.
- Produces: `issue_parent_number(N)`, `issue_sub_issue_numbers(N)`, `sub_issue_link(PARENT, CHILD)`, `rollup_stage_rank(STAGE)`, `rollup_stage_from_rank(RANK)`, `rollup_apply(PARENT, CHILDREN)` — all consumed by `cmd_split.sh` (Task 3) and `cmd_stage.sh` (Task 4).

- [ ] **Step 1: Write the failing tests**

Create `plugins/gh-track/tests/test_subissues.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/labels.sh
. "$PLUGIN_DIR/scripts/lib/labels.sh"
# shellcheck source=../scripts/lib/board.sh
. "$PLUGIN_DIR/scripts/lib/board.sh"
# shellcheck source=../scripts/lib/subissues.sh
. "$PLUGIN_DIR/scripts/lib/subissues.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
cfg_load
scratch_slug

# --- issue_parent_number ----------------------------------------------------
# A real 404 from GitHub (verified live against the actual sub_issues API):
# gh api exits non-zero and does NOT apply --jq, so the caller only ever
# needs to check for emptiness, never distinguish "no parent" from "read
# failed" -- both mean "nothing to roll up to right now".
stub_reset
stub_expect 'issues/5/parent' 1
assert_eq "" "$(issue_parent_number 5 2>/dev/null || true)" "no parent -> empty"

stub_reset
stub_expect_json 'issues/5/parent' '{"number":2}'
assert_eq "2" "$(issue_parent_number 5)" "parent number read"

# --- issue_sub_issue_numbers -------------------------------------------------
stub_reset
stub_expect_json 'issues/2/sub_issues' '[]'
assert_eq "" "$(issue_sub_issue_numbers 2)" "no children -> empty"

stub_reset
stub_expect_json 'issues/2/sub_issues' '[{"number":5},{"number":6}]'
assert_eq "$(printf '5\n6')" "$(issue_sub_issue_numbers 2)" "lists both children"

# --- sub_issue_link -----------------------------------------------------------
stub_reset
stub_expect_json 'issues/5 --jq' '{"id":9001}'
sub_issue_link 2 5
assert_contains "$(stub_calls)" "sub_issues -F sub_issue_id=9001" "posts the child's numeric id"

stub_reset
stub_expect 'issues/5 --jq' 1
assert_exit 1 sub_issue_link 2 5
assert_eq "0" "$(stub_call_count 'sub_issues')" "no link attempted when the id lookup fails"

# --- rollup_stage_rank / rollup_stage_from_rank ------------------------------
assert_eq "0" "$(rollup_stage_rank planned)" "planned -> 0"
assert_eq "1" "$(rollup_stage_rank building)" "building -> 1"
assert_eq "2" "$(rollup_stage_rank review)" "review -> 2"
assert_eq "3" "$(rollup_stage_rank done)" "done -> 3"
assert_eq "0" "$(rollup_stage_rank "")" "empty (failed read) -> 0, the conservative direction"
assert_eq "building" "$(rollup_stage_from_rank 0)" "rank 0 floors to building"
assert_eq "building" "$(rollup_stage_from_rank 1)" "rank 1 -> building"
assert_eq "review" "$(rollup_stage_from_rank 2)" "rank 2 -> review"
assert_eq "done" "$(rollup_stage_from_rank 3)" "rank 3 -> done"

# --- rollup_apply -------------------------------------------------------------
# The slower child (building) wins over plan 1's more advanced review.
stub_reset
stub_expect_json 'issue view 2' '{"labels":[{"name":"plan1:review"}]}'
stub_expect_json 'issue view 5' '{"labels":[{"name":"stage:building"}]}'
stub_expect_json 'issue view 6' '{"labels":[{"name":"stage:done"}]}'
rollup_apply 2 "5 6"
assert_contains "$(stub_calls)" "--add-label stage:building" "rollup floors at the slowest child"

# All children done AND plan 1 done -> parent reaches done.
stub_reset
stub_expect_json 'issue view 2' '{"labels":[{"name":"plan1:done"}]}'
stub_expect_json 'issue view 5' '{"labels":[{"name":"stage:done"}]}'
rollup_apply 2 "5"
assert_contains "$(stub_calls)" "--add-label stage:done" "all done -> parent done"

# Plan 1 lagging behind an already-done child still floors at building, not
# planned -- the floor exists specifically for this case.
stub_reset
stub_expect_json 'issue view 2' '{"labels":[]}'
stub_expect_json 'issue view 5' '{"labels":[{"name":"stage:done"}]}'
rollup_apply 2 "5"
assert_contains "$(stub_calls)" "--add-label stage:building" "no recorded plan1 stage floors at building, never planned"

teardown_scratch
report
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd plugins/gh-track && bash tests/test_subissues.sh
```

Expected: FAIL — no such file `subissues.sh` to source.

- [ ] **Step 3: Implement `subissues.sh`**

Create `plugins/gh-track/scripts/lib/subissues.sh`:

```bash
#!/usr/bin/env bash
# Sub-issues: GitHub-native parent/child links for a spec's second-and-later
# plan, plus the parent stage rollup that reads them.
#
# issue_parent_number and issue_sub_issue_numbers read GitHub directly rather
# than caching the relationship in state.json: state.json is git-ignored, and
# a fresh clone or a fresh subagent worktree must still compute a correct
# rollup without it. GitHub's own sub_issues/parent endpoints are the durable
# source gh-track already trusts everywhere else for canonical state.

# issue_parent_number N — the parent's issue number, or empty. Verified live
# against the real API: a 404 (no parent) makes `gh api` exit non-zero
# WITHOUT applying --jq, so a failed read and a genuine "no parent" are
# indistinguishable from here -- which is fine, because both mean the same
# thing to every caller: there is nothing to roll up to right now.
issue_parent_number() {
  gh api "repos/$GHT_SLUG/issues/$1/parent" --jq '.number' 2>/dev/null
}

# issue_sub_issue_numbers N — one child issue number per line, or empty when
# N has no sub-issues (a real, successful empty list -- verified live).
issue_sub_issue_numbers() {
  gh api "repos/$GHT_SLUG/issues/$1/sub_issues" --jq '.[].number' 2>/dev/null
}

# sub_issue_link PARENT CHILD — link CHILD as a GitHub-native sub-issue of
# PARENT. Never dies: CHILD already exists as a real issue by the time this
# runs (cmd_split creates it first), so a failed link degrades to "no
# progress-bar rollup in GitHub's own UI", never to a failed issue creation.
# The REST endpoint wants CHILD's numeric database id, not its GraphQL node
# id -- `gh issue view --json id` returns the latter, so the id must come
# from `gh api .../issues/N` instead (verified live against the real API).
sub_issue_link() {
  local parent=$1 child=$2 cid
  cid=$(gh api "repos/$GHT_SLUG/issues/$child" --jq '.id' 2>/dev/null) || true
  [ -n "$cid" ] || { warn "cannot resolve #$child's id; not linked as a sub-issue of #$parent"; return 1; }
  gh api -X POST "repos/$GHT_SLUG/issues/$parent/sub_issues" \
    -F sub_issue_id="$cid" >/dev/null 2>&1 \
    || { warn "cannot link #$child as a sub-issue of #$parent"; return 1; }
  return 0
}

# Rank for comparing stages in the rollup's min(). Restricted to the stages a
# split sub-issue or its parent can actually be in post-split
# (planned/building/review/done): a split only happens once plan 1's spec is
# already agreed, so backlog/spec/triage/debugging cannot recur here. Any
# other input -- including empty, which is what a failed issue_stage read
# yields -- maps to rank 0, the conservative direction: it can only ever pull
# the rollup DOWN, never wrongly advance the parent past a stage nothing has
# proven it reached.
rollup_stage_rank() {
  case $1 in
    planned) printf 0 ;;
    building) printf 1 ;;
    review) printf 2 ;;
    done) printf 3 ;;
    *) printf 0 ;;
  esac
}

# rollup_stage_from_rank RANK — the stage a rank maps back to. Rank 0 maps to
# building, never planned: the floor below always wins before this is ever
# called with an unfloored 0, so 0 as an OUTPUT never actually occurs, but the
# safe default here still matches the floor rather than under-reporting.
rollup_stage_from_rank() {
  case $1 in
    0|1) printf building ;;
    2) printf review ;;
    3) printf done ;;
    *) printf building ;;
  esac
}

# rollup_apply PARENT CHILDREN — recompute PARENT's stage as
# min(plan 1's own stage, every child's stage), floored at building, and
# write it with the ordinary stage_set (label + board, unchanged). CHILDREN
# is a space-separated list of issue numbers, already resolved by the caller.
rollup_apply() {
  local parent=$1 children=$2 plan1 c min_rank cur_rank floor_rank target

  plan1=$(issue_plan1_stage "$parent")
  [ -n "$plan1" ] || plan1=$(issue_stage "$parent")
  min_rank=$(rollup_stage_rank "$plan1")

  for c in $children; do
    cur_rank=$(rollup_stage_rank "$(issue_stage "$c")")
    [ "$cur_rank" -lt "$min_rank" ] && min_rank=$cur_rank
  done

  floor_rank=$(rollup_stage_rank building)
  [ "$min_rank" -lt "$floor_rank" ] && min_rank=$floor_rank

  target=$(rollup_stage_from_rank "$min_rank")
  stage_set "$parent" "$target"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/test_subissues.sh
```

Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-track/scripts/lib/subissues.sh plugins/gh-track/tests/test_subissues.sh
git commit -m "feat(gh-track): add subissues.sh — parent/child reads, link, rollup"
```

---

### Task 3: `ghtrack split` subcommand

**Files:**
- Create: `plugins/gh-track/scripts/lib/cmd_split.sh`
- Modify: `plugins/gh-track/scripts/ghtrack` (usage text, dispatcher case)
- Modify: `plugins/gh-track/tests/test_dispatcher.sh` (`SUBCOMMANDS` list)
- Test: `plugins/gh-track/tests/test_split.sh` (new file)

**Interfaces:**
- Consumes: `cfg_load`, `slug_require`, `cfg`, `state_get`, `state_set` (config.sh); `issue_labels`, `size_valid`, `size_to_field`, `issue_plan1_stage`, `plan1_set` (labels.sh); `board_status_set`, `board_size_set` (board.sh); `sub_issue_link` (subissues.sh, Task 2).
- Produces: `cmd_split()`, dispatched as `ghtrack split N --plan P --title T [--size S]`, printing the new (or, if already split, existing) sub-issue's bare number on success — same output convention as `new`/`resolve`.

- [ ] **Step 1: Write the failing tests**

Create `plugins/gh-track/tests/test_split.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json

# Happy path: creates the issue at stage:planned, inherits the parent's kind,
# links it as a sub-issue, seeds plan1:* on the parent from its current
# stage, and prints the bare number.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"kind:feature"},{"name":"stage:building"}]}'
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/77'
stub_expect_json 'issues/77 --jq' '{"id":9001}'
out=$(ght split 42 --plan docs/superpowers/plans/p2.md --title "Second plan")
assert_eq "77" "$out" "split prints the new sub-issue number"
calls=$(stub_calls)
assert_contains "$calls" "--label stage:planned" "sub-issue starts at planned"
assert_contains "$calls" "--label kind:feature" "kind inherited from the parent"
assert_contains "$calls" "sub_issues -F sub_issue_id=9001" "linked as a GitHub-native sub-issue"
assert_contains "$calls" "--add-label plan1:building" "seeds plan1 from the parent's current stage"
assert_eq "0" "$(stub_call_count 'project ')" "no board calls when no project is configured"

# --size applies the size label to the sub-issue too.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"kind:feature"},{"name":"stage:building"},{"name":"plan1:building"}]}'
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/78'
stub_expect_json 'issues/78 --jq' '{"id":9002}'
out=$(ght split 42 --plan docs/superpowers/plans/p3.md --title "Third plan" --size m)
assert_eq "78" "$out" "split with --size prints the number"
assert_contains "$(stub_calls)" "--label size:m" "size label applied to the sub-issue"
# plan1 was already seeded (present in the canned labels above) -- no second seed.
assert_eq "0" "$(stub_call_count '--add-label plan1:')" "plan1 not re-seeded on a later split"

# Idempotent: a repeat call for the SAME plan path returns the same number
# and creates nothing new.
stub_reset
out=$(ght split 42 --plan docs/superpowers/plans/p3.md --title "Third plan (again)" --size m)
assert_eq "78" "$out" "repeat split for the same plan returns the existing number"
assert_eq "0" "$(stub_call_count 'issue create')" "no duplicate issue created"

# A different plan path is a genuinely new split.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"kind:feature"},{"name":"stage:building"},{"name":"plan1:building"}]}'
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/79'
stub_expect_json 'issues/79 --jq' '{"id":9003}'
out=$(ght split 42 --plan docs/superpowers/plans/p4.md --title "Fourth plan")
assert_eq "79" "$out" "a new plan path creates a new sub-issue"

# A parent with no kind:* label refuses rather than guessing.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:building"}]}'
assert_exit 6 ght split 42 --plan docs/superpowers/plans/p5.md --title "No kind"
assert_eq "0" "$(stub_call_count 'issue create')" "no write when the parent's kind cannot be determined"

# A failed label read refuses the write (C1 discipline, same as stage/size).
stub_reset
stub_expect 'issue view 42' 1
assert_exit 6 ght split 42 --plan docs/superpowers/plans/p6.md --title "Failed read"
assert_eq "0" "$(stub_call_count 'issue create')" "no write on a failed parent read"

# Usage errors: missing --plan, missing --title, bad --size, non-numeric issue.
stub_reset
assert_exit 2 ght split 42 --title "No plan"
assert_exit 2 ght split 42 --plan docs/superpowers/plans/p.md
assert_exit 2 ght split 42 --plan docs/superpowers/plans/p.md --title T --size xl
assert_exit 2 ght split notanumber --plan docs/superpowers/plans/p.md --title T
assert_eq "0" "$(stub_call_count 'issue create')" "no write on a bad argument"

teardown_scratch
report
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd plugins/gh-track && bash tests/test_split.sh
```

Expected: FAIL — `unknown subcommand: split`.

- [ ] **Step 3: Implement `cmd_split.sh`**

Create `plugins/gh-track/scripts/lib/cmd_split.sh`:

```bash
#!/usr/bin/env bash
# split — create a GitHub-native sub-issue under a parent for a spec's
# second-and-later plan. Kind inherits from the parent; stage starts at
# planned (the spec is already agreed -- that is what makes a split
# possible in the first place).

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=SCRIPTDIR/board.sh
. "$GHT_LIB/board.sh"
# shellcheck source=SCRIPTDIR/subissues.sh
. "$GHT_LIB/subissues.sh"

cmd_split() {
  cfg_load
  slug_require
  local issue=${1:-}
  require_number "$issue" "split issue number"
  shift
  local plan="" title="" size=""
  while [ $# -gt 0 ]; do
    case $1 in
      --plan) plan=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --size) size=${2:-}; shift 2 ;;
      *) die "split: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$plan" ] || die "split requires --plan PATH" 2
  [ -n "$title" ] || die "split requires --title TITLE" 2
  if [ -n "$size" ]; then
    size_valid "$size" || die "split --size must be one of: $GHT_SIZES" 2
  fi

  # Idempotency cache. This is a deliberately weaker guarantee than
  # rollup_apply's inputs (Task 2): state.json is local and git-ignored, so
  # losing it degrades to "a repeat split re-creates a duplicate sub-issue"
  # -- human-visible, one issue to close by hand -- never to a silently
  # corrupted rollup. The asymmetry is intentional: unlike a stage, a plan
  # path -> sub-issue mapping has no GitHub-durable equivalent to fall back
  # to at split time, because the new issue's body (which will eventually
  # carry the plan link) is written by the calling skill AFTER split
  # returns, not before.
  local existing
  existing=$(state_get ".splits[\"$plan\"]")
  if [ -n "$existing" ]; then
    printf '%s\n' "$existing"
    return 0
  fi

  local parent_labels kind
  parent_labels=$(issue_labels "$issue") \
    || die "cannot read labels for #$issue; refusing to create a sub-issue with an unknown kind" 6
  kind=$(printf '%s\n' "$parent_labels" | sed -n 's/^kind://p' | head -1)
  [ -n "$kind" ] || die "issue #$issue has no kind:* label; cannot create a sub-issue" 6

  local args="--label stage:planned --label kind:$kind"
  [ -n "$size" ] && args="$args --label size:$size"

  local url number
  # shellcheck disable=SC2086 # args is a deliberately word-split flag list
  url=$(gh issue create --repo "$GHT_SLUG" --title "$title" \
    --body "Captured by gh-track: sub-issue of #$issue. No spec yet -- plan is linked separately." \
    $args)
  number=${url##*/}
  case $number in
    ''|*[!0-9]*) die "issue create returned no issue url; refusing to link or board it (got: [$url])" 1 ;;
  esac

  # Print the number before touching the link or the board, same reasoning
  # as cmd_new: the issue exists either way, and a degraded link or board
  # write must cost only itself, never the caller's ability to capture the
  # number that was just created.
  printf '%s\n' "$number"

  sub_issue_link "$issue" "$number" \
    || warn "issue #$number created but not linked as a sub-issue of #$issue on GitHub"

  if [ -n "$(cfg .project)" ] && type board_status_set >/dev/null 2>&1; then
    board_status_set "$number" Todo \
      || warn "issue #$number created but not added to the board; labels are still correct"
    if [ -n "$size" ]; then
      board_size_set "$number" "$(size_to_field "$size")" \
        || warn "board Size not updated for #$number; labels are still correct"
    fi
  fi

  # Seed plan1:* from the parent's CURRENT stage, but only on the parent's
  # FIRST split -- a later split (plan 3, 4...) must never clobber a value
  # that direct `ghtrack stage <parent>` calls may have already advanced.
  if [ -z "$(printf '%s\n' "$parent_labels" | sed -n 's/^plan1://p' | head -1)" ]; then
    local parent_stage
    parent_stage=$(printf '%s\n' "$parent_labels" | sed -n 's/^stage://p' | head -1)
    [ -n "$parent_stage" ] && plan1_set "$issue" "$parent_stage"
  fi

  state_set ".splits[\"$plan\"] = $number"
}
```

- [ ] **Step 4: Wire `split` into the dispatcher and usage text**

In `plugins/gh-track/scripts/ghtrack`, add a line to the `usage()` heredoc right after the `link` line:

```
  split N --plan P --title T [--size S]  create a sub-issue for a spec's 2nd+ plan
```

And add `split` to the dispatcher's subcommand case (the line currently reading `doctor|init|new|resolve|show|stage|size|body|comment|link|tasks|tick)`), making it:

```
    doctor|init|new|resolve|show|stage|size|body|comment|link|tasks|tick|split)
```

- [ ] **Step 5: Add `split` to the dispatcher test's subcommand list**

In `plugins/gh-track/tests/test_dispatcher.sh`, change:

```bash
SUBCOMMANDS="doctor init new resolve show stage size body comment link tasks tick"
```

to:

```bash
SUBCOMMANDS="doctor init new resolve show stage size body comment link tasks tick split"
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bash tests/test_split.sh
bash tests/test_dispatcher.sh
```

Expected: all checks pass in both files.

- [ ] **Step 7: Commit**

```bash
git add plugins/gh-track/scripts/lib/cmd_split.sh plugins/gh-track/scripts/ghtrack \
  plugins/gh-track/tests/test_split.sh plugins/gh-track/tests/test_dispatcher.sh
git commit -m "feat(gh-track): add ghtrack split for a spec's 2nd+ plan"
```

---

### Task 4: Parent stage rollup in `ghtrack stage`

**Files:**
- Modify: `plugins/gh-track/scripts/lib/cmd_stage.sh`
- Test: `plugins/gh-track/tests/test_subissues.sh` (append)

**Interfaces:**
- Consumes: `issue_sub_issue_numbers`, `issue_parent_number`, `rollup_apply` (subissues.sh, Task 2); `plan1_set` (labels.sh, Task 1).
- Produces: `cmd_stage()` now recomputes the parent's rolled-up stage whenever the issue it is called on is itself a split parent, or is a sub-issue of one. Single-plan issues (no parent, no children) behave exactly as before — zero new GitHub calls for that case, since both lookups return empty immediately and nothing further runs.

- [ ] **Step 1: Write the failing tests**

Append to `plugins/gh-track/tests/test_subissues.sh`, before `teardown_scratch`:

```bash
# --- cmd_stage rollup routing (CLI level) ------------------------------------
# Setting a CHILD's stage recomputes and writes the PARENT's rolled-up stage.
stub_reset
stub_expect_json 'issue view 5' '{"labels":[{"name":"stage:done"}]}'
stub_expect_json 'issues/5/sub_issues' '[]'
stub_expect_json 'issues/5/parent' '{"number":2}'
stub_expect_json 'issues/2/sub_issues' '[{"number":5}]'
stub_expect_json 'issue view 2' '{"labels":[{"name":"plan1:done"}]}'
out=$(ght stage 5 done)
assert_eq "stage set: #5 -> done" "$out" "stage still reports the issue it was called on"
assert_contains "$(stub_calls)" "--add-label stage:done" "parent rolled up to done"
assert_eq "1" "$(stub_call_count 'issue edit 2')" "exactly one rollup edit on the parent"

# Setting the PARENT's own stage directly updates plan1:* and still floors
# at building when a child lags behind.
stub_reset
stub_expect_json 'issue view 2' '{"labels":[{"name":"stage:building"},{"name":"plan1:building"}]}'
stub_expect_json 'issues/2/sub_issues' '[{"number":5}]'
stub_expect 'issues/2/parent' 1
stub_expect_json 'issue view 5' '{"labels":[{"name":"stage:building"}]}'
ght stage 2 review >/dev/null
calls=$(stub_calls)
assert_contains "$calls" "--add-label plan1:review" "direct stage call updates plan1 first"
assert_contains "$calls" "--add-label stage:building" "still floored at building while the child lags"

# A single-plan issue (no parent, no children) is completely unchanged: both
# relationship lookups come back empty and nothing further runs.
stub_reset
stub_expect_json 'issue view 9' '{"labels":[{"name":"stage:planned"}]}'
stub_expect_json 'issues/9/sub_issues' '[]'
stub_expect 'issues/9/parent' 1
ght stage 9 building >/dev/null
assert_eq "1" "$(stub_call_count 'issue edit 9')" "exactly one edit -- no rollup machinery engaged"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd plugins/gh-track && bash tests/test_subissues.sh
```

Expected: FAIL — the parent's label is never rolled up (only `issue edit 5` happens, no `issue edit 2`).

- [ ] **Step 3: Extend `cmd_stage.sh`**

Replace the full contents of `plugins/gh-track/scripts/lib/cmd_stage.sh` with:

```bash
#!/usr/bin/env bash
# stage — swap the stage label and mirror the board Status. If this issue is
# a split parent or a sub-issue of one, also recompute the parent's rolled-up
# stage: min(plan 1's own stage, every sub-issue's stage), floored at
# building. See subissues.sh for the rollup itself.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=SCRIPTDIR/board.sh
. "$GHT_LIB/board.sh"
# shellcheck source=SCRIPTDIR/subissues.sh
. "$GHT_LIB/subissues.sh"

cmd_stage() {
  cfg_load
  slug_require
  local issue=${1:-} want=${2:-}
  require_number "$issue" "stage issue number"
  [ -n "$want" ] || die "stage requires a stage name (one of: $GHT_STAGES)" 2
  stage_set "$issue" "$want"

  # I am a split parent: this direct call is plan 1's own stage advancing.
  # Record it durably, then let the rollup decide what the LABEL should
  # actually show once every sub-issue is accounted for.
  local children
  children=$(issue_sub_issue_numbers "$issue") || children=""
  if [ -n "$children" ]; then
    plan1_set "$issue" "$want"
    rollup_apply "$issue" "$children" \
      || warn "stage rollup not recomputed for #$issue"
  fi

  # I am a sub-issue: my own stage just changed, so my parent's rollup may
  # need to move too.
  local parent
  parent=$(issue_parent_number "$issue") || parent=""
  if [ -n "$parent" ]; then
    local siblings
    siblings=$(issue_sub_issue_numbers "$parent") || siblings=""
    rollup_apply "$parent" "$siblings" \
      || warn "parent #$parent's rolled-up stage not updated"
  fi

  printf 'stage set: #%s -> %s\n' "$issue" "$want"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/test_subissues.sh
bash tests/test_labels.sh
bash tests/test_idempotency.sh
```

Expected: all checks pass. (The last two confirm this change has not disturbed ordinary, non-split stage transitions.)

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-track/scripts/lib/cmd_stage.sh plugins/gh-track/tests/test_subissues.sh
git commit -m "feat(gh-track): roll a split parent's stage up from its sub-issues"
```

---

### Task 5: `split` checkpoint comment event

**Why:** The tracking-work-in-github skill (Task 6) needs to post a short, idempotent note on the parent when a split happens (`Split into sub-issue #N — Plan 2: <title>`). This reuses the existing marked-comment machinery exactly as every other checkpoint does, with the new sub-issue's number standing in for the `--sha` slot — `comment_marker` only ever treats it as an opaque idempotency key, never actually validates it looks like a SHA.

**Files:**
- Modify: `plugins/gh-track/scripts/lib/comment.sh`
- Test: `plugins/gh-track/tests/test_comment.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `split` becomes a valid `--event` value for `ghtrack comment`, in `COMMENT_EVENTS_REPEATABLE` (a later plan's split, or the same plan re-split after a failure, must not collide).

- [ ] **Step 1: Write the failing test**

Add to `plugins/gh-track/tests/test_comment.sh`, right after the existing `comment_is_singleton`/`comment_event_known` assertions (after line 22):

```bash
assert_exit 0 comment_event_known split
assert_exit 1 comment_is_singleton split
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd plugins/gh-track && bash tests/test_comment.sh
```

Expected: FAIL on `assert_exit 0 comment_event_known split`.

- [ ] **Step 3: Add `split` to the repeatable events**

In `plugins/gh-track/scripts/lib/comment.sh`, change:

```bash
COMMENT_EVENTS_REPEATABLE="scope-change blocked repro root-cause"
```

to:

```bash
COMMENT_EVENTS_REPEATABLE="scope-change blocked repro root-cause split"
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_comment.sh
```

Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-track/scripts/lib/comment.sh plugins/gh-track/tests/test_comment.sh
git commit -m "feat(gh-track): add split as a repeatable checkpoint event"
```

---

### Task 6: Skill and reference documentation

**Deliberate scope note:** the spec addendum's testing section sketched a
hook-level test ("feed `artifact-changed.sh` two plan writes ... assert the
second produces a split prompt"). This plan does **not** modify
`hooks/artifact-changed.sh`. The hook has no network access today — it
resolves the issue purely from `git branch`, never calls `gh` — and teaching
it to count existing plan artifacts would mean adding a live API read inside
a `PostToolUse` hook that fires on every `docs/superpowers/**` write, which
is a real latency/fragility cost the hook's own design rules (`hooks/artifact-changed.sh`'s header: "Always exit 0", "Watch PATHS, never
superpowers internals") were written to avoid. The hook's existing generic
"plan artifact changed" message is reused unchanged; the SKILL (Task 6, this
task) is what decides — by checking the issue body it already has to read
for the checkpoint anyway — whether this is the first plan (unchanged path)
or the second-and-later (`split` path). This reaches the same outcome the
spec asked for without adding a network call to the hook.

**Files:**
- Modify: `plugins/gh-track/skills/tracking-work-in-github/SKILL.md`
- Modify: `plugins/gh-track/skills/tracking-work-in-github/references/issue-anatomy.md`
- Modify: `plugins/gh-track/README.md`

No tests — this task is documentation only. Verify by reading the rendered result and confirming no code example in it is stale (every command shown must be one this plan actually implemented).

- [ ] **Step 1: Add the split trigger and the three-way mid-build routing rule to `SKILL.md`**

In `plugins/gh-track/skills/tracking-work-in-github/SKILL.md`, in the `## Checkpoints` table, add a row right after the `plan` row:

```markdown
| `plan` (2nd+ for this issue) | A second plan was written for the same spec | `ghtrack split ISSUE --plan FILE --title T`, then run the `plan` checkpoint steps below against the **new sub-issue number**, and post a `split` comment on the parent (see `references/issue-anatomy.md`) |
```

Right after the existing `## Checkpoints` table (before `On the bug track...`), add:

```markdown
### When a plan checkpoint fires for the SECOND time on one issue

The first plan for an issue is handled by the `plan` row above, unchanged.
A second (or later) distinct plan artifact for the same issue means the spec
decomposed into more than one plan — run `ghtrack split ISSUE --plan FILE
--title T` first. It prints a new sub-issue number; run the rest of the plan
checkpoint (`link`, `tasks`, the `plan` comment, `stage ... planned`) against
**that number**, not the parent. Then post one `split` comment on the parent:

```bash
ghtrack comment PARENT --event split --sha SUBISSUE_NUMBER --file FILE
```

using the template in `references/issue-anatomy.md`. This is the same
marked-comment mechanism as every other checkpoint — `SUBISSUE_NUMBER`
just fills the idempotency-key slot that a SHA fills everywhere else, so
re-running the same split's checkpoint edits the same comment rather than
duplicating it.

The parent's own stage is never touched directly here — `ghtrack stage`
already recomputes it from the sub-issue automatically (see the CLI's
`split`/`stage` behavior) the next time either issue's stage changes.
```

Right after the `intake.md` reference pointer (in the `## Intake` section), add a short paragraph — this is the "minimum changes" mid-build routing rule the design settled on:

```markdown
### Mid-build: does new work need its own plan?

When work surfaces mid-build, decide its size the same way `writing-plans`
already would:

- **Fits the current checklist** (a few items, no new design questions) —
  a `scope-change` checkpoint, checklist grown in place. Nothing new here.
- **Needs its own task breakdown, same spec** — write it as a new plan
  (`superpowers:writing-plans`, same issue). The very next plan checkpoint
  is now a *second* plan for this issue, which routes through `ghtrack
  split` above automatically. No separate decision to make.
- **A different problem entirely** — a new, independent issue per
  `references/intake.md`.
```

- [ ] **Step 2: Add the `split` comment template to `issue-anatomy.md`**

In `plugins/gh-track/skills/tracking-work-in-github/references/issue-anatomy.md`, add a new subsection right after `### scope-change` and before `### blocked`:

```markdown
### split

Posted on the **parent**, once per sub-issue created.

```markdown
**Split into sub-issue #77.** Plan 2: <title, one line>

Same spec, second plan — tracked separately from here on.
```

Also append one line to the parent's `## Decisions`, the first time this
happens for that parent (never again after):

```markdown
- Decomposed into sub-issues — plan 1 stays on the parent, plan 2+ tracked as sub-issues (spec)
```
```

- [ ] **Step 3: Update `README.md`**

In the `## The ghtrack CLI` table in `plugins/gh-track/README.md`, add a row right after the `link` row:

```markdown
| `split N --plan P --title T [--size S]` | Create a GitHub-native sub-issue under `N` for a spec's 2nd+ plan; prints the number. |
```

In the `### Output conventions` section, add `split` to the bare-value list:

```markdown
**Single-value accessors print a bare value, no key** — `resolve`, `new`, `split`, `--version`.
```

In `### Known limitations`, append:

```markdown
- `split`'s plan-path → sub-issue-number idempotency is cached in `state.json`,
  which is local and git-ignored. Losing it (a fresh clone, a fresh worktree)
  degrades to "a repeat `split` for the same plan creates a second sub-issue"
  — human-visible and fixable by closing the duplicate — never to a
  corrupted rollup: the rollup itself (`stage`'s parent recomputation) reads
  GitHub's own `parent`/`sub_issues` endpoints and the durable `plan1:*`
  label, not `state.json`, so it is always correct from a fresh clone.
```

- [ ] **Step 4: Commit**

```bash
git add plugins/gh-track/skills/tracking-work-in-github/SKILL.md \
  plugins/gh-track/skills/tracking-work-in-github/references/issue-anatomy.md \
  plugins/gh-track/README.md
git commit -m "docs(gh-track): document split, its checkpoint, and mid-build routing"
```

---

### Task 7: Dogfood — verify live, then bootstrap this repo's labels

This project's own history (see the spec addendum's motivation) found real bugs during live end-to-end runs that no offline stub test caught. Run one here before calling this done.

**Files:** none (verification only, against the real `mr-ashishpanda/applied-ai-innovation` repo, using throwaway issues that get closed at the end — same discipline as this project's prior live e2e runs).

- [ ] **Step 1: Run the full offline suite once, from a clean tree**

```bash
cd plugins/gh-track && bash tests/run
```

Expected: every suite passes, including `shellcheck`.

- [ ] **Step 2: Re-run `ghtrack init` on this repo to create the new `plan1:*` labels**

```bash
cd /Users/ashish/Documents/Personal/Projects/applied-ai-innovation
./plugins/gh-track/scripts/ghtrack init
```

Expected: reports labels created/already-present; `plan1:backlog` through `plan1:done` now exist alongside `stage:*`.

- [ ] **Step 3: Live-verify split + rollup end to end, using throwaway issues**

Create one throwaway parent and two throwaway children directly against the real repo, exercise `split` and `stage` for real, confirm the rollup lands where expected via `gh issue view --json labels`, then close every throwaway issue. This mirrors exactly how the sub_issues REST contract was verified live during this plan's own design (POST/GET/DELETE `sub_issues`, GET `parent`) — repeat that verification here through the actual `ghtrack` CLI rather than raw `gh api` calls, to prove the CLI wraps that contract correctly.

Concretely:
1. Create a throwaway parent issue with `ghtrack new --kind chore --title "[gh-track test] split rollup probe — safe to close"`, then `ghtrack stage <parent> building`.
2. `ghtrack split <parent> --plan docs/superpowers/plans/2026-08-10-ghtrack-cli.md --title "[gh-track test] probe child A"` (reusing a real existing plan path already in this repo is fine for this probe — nothing writes to it).
3. `ghtrack split <parent> --plan docs/superpowers/plans/2026-08-10-gh-track-plugin.md --title "[gh-track test] probe child B"`.
4. Confirm via `gh issue view <parent> --json labels` that `plan1:building` was seeded exactly once (not twice).
5. `ghtrack stage <childA> building`, `ghtrack stage <childB> building` — confirm the parent's `stage:*` label is `building` (already was).
6. `ghtrack stage <childA> done` — confirm the parent stays at `building` (childB still building) via `gh issue view`.
7. `ghtrack stage <childB> done` — confirm the parent rolls to `done`.
8. `ghtrack stage <parent> review` (simulating plan 1 itself finishing later than both children) — confirm the parent's `plan1:*` becomes `review` but the displayed `stage:*` stays `done` (both children already done, so min is `done`, unaffected by plan1 dropping below it — expected: rollup uses the CURRENT plan1 input each time, so `min(review, done, done) = review`; confirm which of these two outcomes actually occurs and treat a mismatch as a real bug to fix, not a spec ambiguity to paper over — the spec's intent is that the rollup always reflects the true minimum across plan 1 and every child right now).
9. Close all three throwaway issues (`gh issue close`) and report their numbers so the user can delete them later if desired, per this project's established "user deletes, agent never does" convention for throwaway artifacts.

- [ ] **Step 4: Fix anything the live run finds**

If step 3 surfaces a real defect, fix it in the relevant task's file, add a regression test to the matching test file from Tasks 1–5, and re-run that suite before continuing. Do not consider this task done while a live-verified defect remains unfixed.

- [ ] **Step 5: Commit any fixes**

```bash
git add -A plugins/gh-track
git commit -m "fix(gh-track): <describe the specific live-e2e finding and fix>"
```

(Skip this step if step 3 found nothing to fix.)
