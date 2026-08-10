# gh-track Plugin Implementation Plan (skills, hooks, packaging)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap the `ghtrack` CLI in a distributable Claude Code plugin — two skills, two hooks, a CLAUDE.md template, and marketplace packaging — so any project can adopt superpowers-plus-GitHub tracking with two install commands and one sentence.

**Architecture:** The plugin ships skills and hooks globally; a per-project bootstrap skill handles what is inherently repository-local. Hooks watch *file paths* under `docs/superpowers/**` and inject reminders — they never read superpowers internals, so superpowers releases cannot break them. All GitHub mutation is delegated to `ghtrack`; the skills contribute only judgment and prose.

**Tech Stack:** Claude Code plugin format (`.claude-plugin/plugin.json`, `hooks/hooks.json`), markdown skills, bash hook scripts, `jq`.

**Prerequisite:** `docs/superpowers/plans/2026-08-10-ghtrack-cli.md` must be complete. Every subcommand it defines is called verbatim here.

## Global Constraints

- **bash 3.2 compatible** for all hook scripts. No associative arrays, no `mapfile`, no `${var,,}`.
- **Shebang** `#!/usr/bin/env bash` then `set -euo pipefail`; `shellcheck` clean.
- **Hooks must never block or fail a tool call.** Every hook exits 0 unconditionally, even on internal error. A tracking hook that breaks a user's `Write` is a defect.
- **Hooks must be silent when irrelevant.** No output for paths outside `docs/superpowers/**`, or when no issue can be resolved, or when content is unchanged since the last nudge.
- **Plugin paths use `${CLAUDE_PLUGIN_ROOT}`,** never hardcoded absolute paths.
- **Skills never call `gh` directly.** Every mutation goes through `ghtrack`, so behaviour stays deterministic and testable.
- **The five permitted superpowers dependencies** (spec glob, plan glob, task heading pattern, user-facing skill names, git state) are the only coupling allowed. Never reference `implementer-prompt.md`, `task-reviewer-prompt.md`, `re-review-prompt.md`, `.superpowers/sdd/`, the ledger format, or `scripts/sdd-workspace`.
- **Marker format, exact:** `<!-- gh-track:begin -->` / `<!-- gh-track:end -->` for the CLAUDE.md block.
- **Checkpoint events, exact:** `spec`, `plan`, `build-started`, `done` (singleton); `scope-change`, `blocked`, `repro`, `root-cause` (repeatable).

---

## File Structure

```
.claude-plugin/marketplace.json           # repo root: makes the plugin installable
plugins/gh-track/
├── .claude-plugin/plugin.json            # plugin identity and version
├── hooks/
│   ├── hooks.json                        # PostToolUse + SessionStart registration
│   ├── artifact-changed.sh               # nudge on docs/superpowers/** writes
│   └── session-context.sh                # inject current issue state at session start
├── skills/
│   ├── tracking-work-in-github/
│   │   ├── SKILL.md                      # lifecycle: intake, checkpoints, routing
│   │   └── references/
│   │       ├── issue-anatomy.md          # body + comment templates, verbatim
│   │       ├── intake.md                  # the four entry points, decision rule
│   │       └── claude-md-block.md         # CLAUDE.md template, copied verbatim
│   └── setting-up-github-tracking/
│       └── SKILL.md                      # per-project bootstrap
└── tests/
    ├── test_hook_artifact.sh              # hook classification + debounce
    └── test_hook_session.sh               # session context injection
```

Boundary: `SKILL.md` files hold *routing and judgment*; `references/` hold *verbatim text* that must not be paraphrased (templates drift when a model regenerates them from prose). Hooks hold *detection*, never decisions.

---

### Task 1: Plugin and marketplace manifests

**Files:**
- Create: `plugins/gh-track/.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`

**Interfaces:**
- Consumes: nothing.
- Produces: an installable plugin named `gh-track`. Later tasks add skills and hooks into the directory this task establishes.

- [ ] **Step 1: Write the plugin manifest**

Create `plugins/gh-track/.claude-plugin/plugin.json`:

```json
{
  "name": "gh-track",
  "description": "GitHub issue and project tracking for superpowers development workflows. Every work item becomes one issue carrying its stage, artifact links, task checklist, and a timeline of decisions - without duplicating spec or plan prose into GitHub.",
  "version": "0.1.0",
  "author": {
    "name": "Ashish Panda"
  },
  "homepage": "https://github.com/mr-ashishpanda/applied-ai-innovation/tree/master/plugins/gh-track",
  "repository": "https://github.com/mr-ashishpanda/applied-ai-innovation",
  "license": "MIT",
  "keywords": ["github", "issues", "projects", "superpowers", "tracking", "workflow"]
}
```

- [ ] **Step 2: Write the marketplace manifest**

Create `.claude-plugin/marketplace.json` at the repository root:

```json
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "applied-ai-innovation",
  "description": "Applied AI tooling: Claude Code plugins and skills for practical development workflows",
  "owner": {
    "name": "Ashish Panda"
  },
  "plugins": [
    {
      "name": "gh-track",
      "description": "GitHub issue and project tracking for superpowers development workflows.",
      "author": { "name": "Ashish Panda" },
      "category": "workflow",
      "source": "./plugins/gh-track",
      "homepage": "https://github.com/mr-ashishpanda/applied-ai-innovation/tree/master/plugins/gh-track"
    }
  ]
}
```

- [ ] **Step 3: Verify the manifests are valid JSON**

Run:
```bash
jq empty .claude-plugin/marketplace.json && jq empty plugins/gh-track/.claude-plugin/plugin.json && echo "both valid"
```
Expected: `both valid`.

- [ ] **Step 4: Verify the marketplace actually resolves**

Commit and push first (a marketplace is fetched from the remote), then run in a Claude Code session:

```
/plugin marketplace add mr-ashishpanda/applied-ai-innovation
```

Expected: the marketplace is added and `gh-track` is listed.

**If the relative `"source": "./plugins/gh-track"` form is rejected**, replace that one field with the `git-subdir` form the official marketplace uses, and re-verify:

```json
"source": {
  "source": "git-subdir",
  "url": "https://github.com/mr-ashishpanda/applied-ai-innovation.git",
  "path": "plugins/gh-track",
  "ref": "master"
}
```

Record which form worked in `plugins/gh-track/README.md` under a short "Packaging" note, so a future maintainer does not have to rediscover it.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin plugins/gh-track/.claude-plugin
git commit -m "feat(gh-track): add plugin and marketplace manifests"
```

---

### Task 2: The artifact-changed hook

**Files:**
- Create: `plugins/gh-track/hooks/artifact-changed.sh`
- Create: `plugins/gh-track/hooks/hooks.json`
- Create: `plugins/gh-track/tests/test_hook_artifact.sh`

**Interfaces:**
- Consumes: `ghtrack resolve`, `ghtrack show` from plan 1.
- Produces: a PostToolUse hook that reads the hook JSON payload on stdin and prints a JSON object with `hookSpecificOutput.additionalContext` when a `docs/superpowers/**` path was written. Silent otherwise. Always exits 0.

Classification, matching the spec exactly:

| Path under `docs/superpowers/` | Reminder |
|---|---|
| `specs/**` | Spec artifact changed — post the `spec` checkpoint, or `scope-change` if a spec checkpoint already exists |
| `plans/**` | Plan artifact changed — post the `plan` checkpoint and run `ghtrack tasks` |
| anything else | New superpowers artifact — consider a one-line note |

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/test_hook_artifact.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

HOOK="$PLUGIN_DIR/hooks/artifact-changed.sh"

# payload TOOL PATH — synthesize a PostToolUse hook payload.
payload() {
  printf '{"tool_name":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' \
    "$1" "$SCRATCH" "$2"
}

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
git checkout -q -b 42-thing
mkdir -p docs/superpowers/specs docs/superpowers/plans docs/superpowers/research
printf '# s\n' >docs/superpowers/specs/s.md
printf '# p\n' >docs/superpowers/plans/p.md
printf '# r\n' >docs/superpowers/research/r.md

# A spec write produces a spec-checkpoint reminder naming the issue.
out=$(payload Write "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
assert_contains "$out" "additionalContext" "emits hook JSON"
assert_contains "$out" "#42" "names the resolved issue"
assert_contains "$out" "spec" "mentions the spec checkpoint"

# A plan write asks for the plan checkpoint AND checklist sync.
out=$(payload Edit "$SCRATCH/docs/superpowers/plans/p.md" | bash "$HOOK")
assert_contains "$out" "ghtrack tasks" "asks for checklist sync"

# An unknown docs/superpowers path gets the mildest nudge.
out=$(payload Write "$SCRATCH/docs/superpowers/research/r.md" | bash "$HOOK")
assert_contains "$out" "research/r.md" "names the unknown artifact"
assert_contains "$out" "one-line note" "mild nudge wording"

# Unrelated paths are silent.
printf 'x\n' >src.py
out=$(payload Write "$SCRATCH/src.py" | bash "$HOOK")
assert_eq "" "$out" "unrelated path silent"

# Non-write tools are silent.
out=$(payload Read "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
assert_eq "" "$out" "Read tool silent"

# Debounce: identical content twice produces one nudge.
out1=$(payload Write "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
out2=$(payload Write "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
assert_contains "$out1" "#42" "first write nudges"
assert_eq "" "$out2" "unchanged repeat is silent"

# Changed content nudges again.
printf '# s changed\n' >docs/superpowers/specs/s.md
out3=$(payload Write "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
assert_contains "$out3" "#42" "changed content nudges again"

# An unresolvable issue is silent, not an error.
git checkout -q -b spike/no-number
printf '# s2\n' >docs/superpowers/specs/s.md
out=$(payload Write "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
assert_eq "" "$out" "unresolvable issue is silent"

# Malformed payload exits 0 and stays silent - a hook must never break a tool.
out=$(printf 'not json' | bash "$HOOK")
assert_eq "" "$out" "malformed payload silent"
assert_exit 0 bash -c "printf 'not json' | bash '$HOOK'"

# A missing ghtrack on PATH must not break the hook either.
out=$(PATH=/usr/bin:/bin payload Write "$SCRATCH/docs/superpowers/specs/s.md" | \
  PATH=/usr/bin:/bin bash "$HOOK")
assert_exit 0 bash -c "PATH=/usr/bin:/bin printf '{}' | bash '$HOOK'"

teardown_scratch
report
```

Reuse the plan-1 harness by creating `plugins/gh-track/tests/helpers.sh` only if plan 1's copy is absent — it already exists, so this test sources it directly.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_hook_artifact.sh`
Expected: FAIL — `artifact-changed.sh: No such file or directory`.

- [ ] **Step 3: Write the hook**

Create `plugins/gh-track/hooks/artifact-changed.sh`:

```bash
#!/usr/bin/env bash
# PostToolUse hook: notice writes to superpowers artifacts and remind the
# agent to checkpoint the tracking issue.
#
# Design rules this script must never violate:
#   1. Always exit 0. A tracking hook that fails a user's Write is a defect.
#   2. Be silent unless there is something specific and actionable to say.
#   3. Watch PATHS, never superpowers internals - that is what makes this
#      immune to superpowers releases.
set -uo pipefail

# Any internal failure must still exit 0.
trap 'exit 0' ERR

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)
case $tool in
  Write|Edit|NotebookEdit) : ;;
  *) exit 0 ;;
esac

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[ -n "$file" ] || exit 0
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -n "$cwd" ] || cwd=$(pwd)

cd "$cwd" 2>/dev/null || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Relative path inside the repo; bail out if the write was outside it.
case $file in
  "$root"/*) rel=${file#"$root"/} ;;
  /*) exit 0 ;;
  *) rel=$file ;;
esac

case $rel in
  docs/superpowers/*) : ;;
  *) exit 0 ;;
esac

# Locate ghtrack: prefer the plugin's own copy, fall back to PATH.
ghtrack=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "$CLAUDE_PLUGIN_ROOT/scripts/ghtrack" ]; then
  ghtrack="$CLAUDE_PLUGIN_ROOT/scripts/ghtrack"
elif command -v ghtrack >/dev/null 2>&1; then
  ghtrack=$(command -v ghtrack)
else
  exit 0
fi

issue=$("$ghtrack" resolve 2>/dev/null) || exit 0
[ -n "$issue" ] || exit 0

# Debounce on content hash so iterative editing does not spam reminders.
hash=$(git hash-object "$file" 2>/dev/null || true)
[ -n "$hash" ] || exit 0
state="$root/.claude/gh-track/state.json"
key=$(printf '%s' "$rel" | tr -c 'a-zA-Z0-9' '_')
if [ -f "$state" ]; then
  seen=$(jq -r --arg k "$key" '.nudged[$k] // empty' "$state" 2>/dev/null || true)
  [ "$seen" = "$hash" ] && exit 0
fi
mkdir -p "$(dirname "$state")"
[ -f "$state" ] || printf '%s' '{}' >"$state"
tmp="$state.tmp.$$"
if jq --arg k "$key" --arg h "$hash" '.nudged[$k] = $h' "$state" >"$tmp" 2>/dev/null; then
  mv "$tmp" "$state"
else
  rm -f "$tmp"
fi

case $rel in
  docs/superpowers/specs/*)
    msg="gh-track: spec artifact changed ($rel) for issue #$issue. Use the tracking-work-in-github skill to post the checkpoint: the 'spec' checkpoint if this issue has none yet, otherwise a 'scope-change' checkpoint explaining what changed and why. Then set the stage with: ghtrack stage $issue spec"
    ;;
  docs/superpowers/plans/*)
    msg="gh-track: plan artifact changed ($rel) for issue #$issue. Use the tracking-work-in-github skill to post the 'plan' checkpoint, then sync the checklist: ghtrack tasks $issue --plan $rel"
    ;;
  *)
    msg="gh-track: new superpowers artifact at $rel for issue #$issue. This is not a spec or plan path. Consider a one-line note on the issue if it records a decision; ignore it otherwise."
    ;;
esac

jq -nc --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
exit 0
```

Make executable: `chmod +x plugins/gh-track/hooks/artifact-changed.sh`

- [ ] **Step 4: Register the hook**

Create `plugins/gh-track/hooks/hooks.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/artifact-changed.sh\"",
            "shell": "bash",
            "async": false
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/session-context.sh\"",
            "shell": "bash",
            "async": false
          }
        ]
      }
    ]
  }
}
```

`session-context.sh` is written in Task 3. Create it now as a two-line `exit 0`
stub so the registration is valid the moment `hooks.json` exists:

```bash
#!/usr/bin/env bash
exit 0
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — all plan-1 suites plus `test_hook_artifact.sh`, shellcheck clean.

- [ ] **Step 6: Verify the hook output contract against real Claude Code**

The `hookSpecificOutput.additionalContext` shape is what this hook emits; confirm
Claude Code surfaces it. In a session inside this repository, on a branch named
`<issue>-<slug>` for a real issue, write a throwaway file to
`docs/superpowers/specs/hook-probe.md` and confirm the reminder text appears.

**If `additionalContext` is not surfaced,** change the final `jq` line to print
the bare message to stdout instead (`printf '%s\n' "$msg"`), re-run the probe, and
note the working form in a comment at the top of the script. Delete
`docs/superpowers/specs/hook-probe.md` afterward.

- [ ] **Step 7: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): add artifact-changed hook with debounce"
```

---

### Task 3: The session-context hook

**Files:**
- Modify: `plugins/gh-track/hooks/session-context.sh` (replace the Task 2 stub)
- Create: `plugins/gh-track/tests/test_hook_session.sh`

**Interfaces:**
- Consumes: `ghtrack resolve`, `ghtrack show`.
- Produces: a SessionStart hook that injects one compact block naming the current issue, its stage, and the next expected action. Silent when no issue resolves. Always exits 0.

This is what lets a fresh session — or a session after compaction — know where it is without reading any artifact. It is also the bug track's primary enforcement, since `systematic-debugging` writes no watched files.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/test_hook_session.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_hook_session.sh`
Expected: FAIL — the stub hook emits nothing, so the first `assert_contains` fails.

- [ ] **Step 3: Write the hook**

Replace `plugins/gh-track/hooks/session-context.sh`:

```bash
#!/usr/bin/env bash
# SessionStart hook: tell the session which issue it is working on, what
# stage that issue is in, and what comes next.
#
# This is the recovery mechanism. After compaction, or in a brand new
# session, this block is how the agent learns its position without reading
# a spec or plan.
set -uo pipefail
trap 'exit 0' ERR

payload=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

cwd=""
if [ -n "$payload" ]; then
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$cwd" ] || cwd=$(pwd)

cd "$cwd" 2>/dev/null || exit 0
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

ghtrack=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "$CLAUDE_PLUGIN_ROOT/scripts/ghtrack" ]; then
  ghtrack="$CLAUDE_PLUGIN_ROOT/scripts/ghtrack"
elif command -v ghtrack >/dev/null 2>&1; then
  ghtrack=$(command -v ghtrack)
else
  exit 0
fi

issue=$("$ghtrack" resolve 2>/dev/null) || exit 0
[ -n "$issue" ] || exit 0

info=$("$ghtrack" show "$issue" 2>/dev/null) || exit 0
[ -n "$info" ] || exit 0

get() { printf '%s\n' "$info" | sed -n "s/^$1=//p" | head -1; }

title=$(get title)
stage=$(get stage)
kind=$(get kind)
tasks=$(get tasks)
state=$(get state)

case $stage in
  backlog)
    next="This work has no spec yet. Start with superpowers:brainstorming, then post the 'spec' checkpoint." ;;
  spec)
    next="A spec exists. Next is superpowers:writing-plans, then post the 'plan' checkpoint." ;;
  triage)
    next="This is a bug in triage. Use superpowers:systematic-debugging; post the 'repro' checkpoint once reproduced." ;;
  debugging)
    next="Root cause hunt in progress. Post the 'root-cause' checkpoint when found, then move to stage building." ;;
  planned)
    next="A plan exists. Next is to execute it (superpowers:subagent-driven-development or superpowers:executing-plans), post 'build-started', and set stage building." ;;
  building)
    next="Implementation is in flight. Tick checklist items with 'ghtrack tick' as tasks complete; post 'blocked' if you stall." ;;
  review)
    next="Work is in review. Post the 'done' checkpoint once merged and set stage done." ;;
  done)
    next="This issue is complete. Confirm before starting new work on this branch." ;;
  *)
    next="Stage is unset. Set one with 'ghtrack stage $issue <stage>'." ;;
esac

msg="gh-track: this workspace tracks issue #$issue - \"$title\" (kind=$kind, stage=$stage, state=$state, tasks=$tasks).
$next
The issue is the single source of truth for this work. Do not copy spec or plan prose into it; post short checkpoint comments and keep the body's state current. Full guidance: the tracking-work-in-github skill."

jq -nc --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — all suites green, shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): inject issue context at session start"
```

---

### Task 4: The CLAUDE.md template and bootstrap skill

**Files:**
- Create: `plugins/gh-track/skills/tracking-work-in-github/references/claude-md-block.md`
- Create: `plugins/gh-track/skills/setting-up-github-tracking/SKILL.md`

**Interfaces:**
- Consumes: `ghtrack doctor`, `ghtrack init`.
- Produces: a bootstrap skill invoked by "set up GitHub tracking in this repo". Idempotent: re-running after a plugin upgrade replaces only the marked CLAUDE.md block.

- [ ] **Step 1: Write the CLAUDE.md template**

Create `plugins/gh-track/skills/tracking-work-in-github/references/claude-md-block.md`. This file is copied **verbatim** into a project's CLAUDE.md — never paraphrased, or the convention drifts between projects.

```markdown
<!-- gh-track:begin -->
## Development workflow and tracking

**Superpowers owns how software gets built.** Brainstorm a spec, write a plan,
then implement it. Do not bypass those skills.

**gh-track owns how work is tracked.** Every requirement, bug, and task is one
GitHub issue. The issue is the single source of truth for a human reading this
project's history.

### Rules

1. **Branch names carry the issue number:** `<issue-number>-<slug>`, e.g.
   `42-github-tracking`. Every worktree and branch for tracked work follows this,
   because it is how any session resolves which issue it is on.
2. **Never copy spec or plan prose into GitHub.** The issue body holds state,
   artifact links, a task checklist, and one-line decisions. Full detail stays in
   `docs/superpowers/specs/` and `docs/superpowers/plans/`, which the issue links to.
3. **Write checkpoints from working memory.** Post a checkpoint at the moment you
   still hold the content in context. Never re-read a spec or plan in order to
   summarise it into GitHub.
4. **Comments are for decisions; the body is for state.** Task completions tick a
   checkbox. Only checkpoint events produce comments.
5. **New work starts with an issue.** Before brainstorming a new requirement,
   create its issue. A change to work already in flight is a scope-change comment
   on the existing issue, not a new issue.
6. **Tracking never blocks building.** If a `ghtrack` call fails, report it and
   keep working.

Use the `tracking-work-in-github` skill for the full lifecycle: intake, the six
checkpoint events, and the templates. All GitHub writes go through the `ghtrack`
CLI — never hand-rolled `gh` calls.
<!-- gh-track:end -->
```

- [ ] **Step 2: Write the bootstrap skill**

Create `plugins/gh-track/skills/setting-up-github-tracking/SKILL.md`:

```markdown
---
name: setting-up-github-tracking
description: Use when adopting gh-track in a repository for the first time, or re-running setup after a gh-track upgrade - creates labels, the project board, config, and the CLAUDE.md block. Triggers on "set up GitHub tracking", "initialise gh-track", "wire up issue tracking here".
---

# Setting Up GitHub Tracking

One-time (idempotent) per-repository setup for gh-track. Everything here is
repository-local, which is why it cannot ship inside the plugin install.

**Announce at start:** "I'm using the setting-up-github-tracking skill to wire up
issue tracking for this repository."

## Checklist

Create a todo per item and complete them in order.

1. **Diagnose.** Run `ghtrack doctor`. Read every line before acting — it tells
   you what is already in place and what is missing.
2. **Confirm the repository.** Show the user the `repo:` line from `doctor` and
   confirm it is the repository they want tracked. Never write to a repository
   the user has not confirmed.
3. **Handle a missing `project` scope.** If `doctor` reports
   `scope project: MISSING`, tell the user board writes will be skipped and that
   the fix is `gh auth refresh -s project`. Ask whether to proceed label-only or
   wait. Both are valid — labels are canonical.
4. **Initialise.** Run `ghtrack init`. It creates labels, finds or creates the
   board, writes `.claude/gh-track/config.json`, and gitignores
   `.claude/gh-track/state.json`.
5. **Merge the CLAUDE.md block.** See the procedure below.
6. **Verify.** Re-run `ghtrack doctor`. Report the before/after difference.
7. **Report.** List exactly what changed: labels created, board number, config
   path, whether CLAUDE.md was created or updated. Then state what the user can
   do next: "describe a new requirement and I'll open an issue for it."

## Merging the CLAUDE.md block

The template is at
`${CLAUDE_PLUGIN_ROOT}/skills/tracking-work-in-github/references/claude-md-block.md`.
Copy it **verbatim** — do not paraphrase, reformat, or trim it. Paraphrasing is
how the convention drifts between projects.

Three cases:

- **No `CLAUDE.md`:** create it containing exactly the template.
- **`CLAUDE.md` exists without `<!-- gh-track:begin -->`:** append the template,
  separated by a blank line. Do not reorganise the user's existing content.
- **`CLAUDE.md` exists with the markers:** replace everything between
  `<!-- gh-track:begin -->` and `<!-- gh-track:end -->` inclusive with the current
  template. Content outside the markers is untouchable.

Then confirm with `grep -c 'gh-track:begin' CLAUDE.md` — the answer must be `1`.
If it is `2` or more, you duplicated the block: remove the extras.

## Scope adaptation

If the user's superpowers artifacts do not live at `docs/superpowers/specs/` and
`docs/superpowers/plans/` — `doctor` reports `artifacts: MISMATCH` — ask where
they do live and set `specGlob` and `planGlob` in
`.claude/gh-track/config.json` accordingly. This is the designed adaptation
point for superpowers convention changes; do not edit skill files instead.

## Do not

- Do not create issues here. This skill only prepares the repository.
- Do not run `git push`, open PRs, or modify branches.
- Do not hand-roll `gh` calls. Everything goes through `ghtrack`.
- Do not proceed past step 2 without the user confirming the repository.
```

- [ ] **Step 3: Verify the skill loads and the template is byte-exact**

Run:
```bash
grep -c 'gh-track:begin' plugins/gh-track/skills/tracking-work-in-github/references/claude-md-block.md
grep -c 'gh-track:end' plugins/gh-track/skills/tracking-work-in-github/references/claude-md-block.md
head -3 plugins/gh-track/skills/setting-up-github-tracking/SKILL.md
```
Expected: `1`, `1`, and a valid YAML frontmatter opening with `name: setting-up-github-tracking`.

- [ ] **Step 4: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): add bootstrap skill and CLAUDE.md template"
```

---

### Task 5: The lifecycle skill

**Files:**
- Create: `plugins/gh-track/skills/tracking-work-in-github/SKILL.md`
- Create: `plugins/gh-track/skills/tracking-work-in-github/references/issue-anatomy.md`
- Create: `plugins/gh-track/skills/tracking-work-in-github/references/intake.md`

**Interfaces:**
- Consumes: every `ghtrack` subcommand; the two hooks' reminders.
- Produces: the skill the hooks name and the CLAUDE.md block points to. This is the last piece — after it, the plugin is functionally complete.

- [ ] **Step 1: Write the intake reference**

Create `plugins/gh-track/skills/tracking-work-in-github/references/intake.md`:

```markdown
# Intake: four entry points, one decision rule

## The rule

Ask one question first: **does this change work that is already in flight**
(an issue at `stage:spec` through `stage:building`)?

- **Yes** → it is a **scope change** on that issue. Post a `scope-change`
  checkpoint, revise the spec and plan in place, adjust the checklist. **Do not
  create a new issue.**
- **No** → **create a new issue.**

## Creating a new issue

Pick the kind, which decides the track:

| Kind | Track | First superpowers skill |
|---|---|---|
| `feature` | spec → planned → building → review → done | `superpowers:brainstorming` |
| `bug` | triage → debugging → building → review → done | `superpowers:systematic-debugging` |
| `chore` | planned → building → review → done | `superpowers:writing-plans` |

Create it before any brainstorming or debugging:

```bash
ghtrack new --kind feature --title "Short imperative title"
```

The issue starts at `stage:backlog`. Then:

- **Starting work now?** Create the branch `<issue>-<slug>`, then advance the
  stage as the work reaches each checkpoint.
- **Capturing for later?** Stop here. No branch, no spec, no brainstorming. A
  one-line requirement at `stage:backlog` is a complete, valid backlog item.

## Capture-only intake

When the user is dumping ideas rather than starting work, create the issue and
stop. Resist the urge to brainstorm. Confirm with one line: "Captured as #N."

## Scope changes that should not block

If a change is real but too large to absorb into current work, offer to split it:
a new issue cross-linked `Split from #N` in its body, left at `stage:backlog`.
**Offer — never split automatically.** The user decides whether current work
absorbs the change or defers it.

## Regressions

A bug found in already-shipped, closed work is always a **new** issue with
`kind:bug`, cross-linked `Regressed from #N`. Never reopen the original: it is
an accurate record of what shipped, and rewriting it destroys that.
```

- [ ] **Step 2: Write the issue-anatomy reference**

Create `plugins/gh-track/skills/tracking-work-in-github/references/issue-anatomy.md`:

````markdown
# Issue anatomy

## Body — a control panel, rewritten in place

Never append to the body; render it whole and replace it. Sections appear in
this order, and the `## Tasks` heading is ASCII-hyphenated exactly as shown
because `ghtrack` matches on it.

```markdown
**Stage:** building · **Kind:** feature · **Size:** M · **Branch:** `42-gh-tracking`

## Goal
One paragraph: what this delivers and why it matters. Written once at intake,
revised only if the goal itself changes.

## Artifacts
- Spec: [2026-08-10-topic-design.md](https://github.com/o/r/blob/42-gh-tracking/docs/superpowers/specs/2026-08-10-topic-design.md)
- Plan: [2026-08-10-topic.md](https://github.com/o/r/blob/42-gh-tracking/docs/superpowers/plans/2026-08-10-topic.md)

## Tasks (from plan - 3/8)
- [x] 1. First task title
- [ ] 2. Second task title

## Decisions
- Chose X over Y because Z (spec)
- Dropped W when it turned out to conflict with V (scope-change)
```

Body links use **branch HEAD** so they always show the current artifact. At the
`done` checkpoint, rewrite them to the default branch — the work branch is
usually deleted on merge and its links would rot. Get that URL from
`ghtrack link` output's `head_url`, or build the default-branch form at done time.

`## Decisions` is append-only, one line each: the decision, then the reason,
then the checkpoint it came from in parentheses. It is the digest of the comment
timeline, so the body alone answers "why is it like this?"

To update the body: fetch it, edit the section you own, write it back with
`ghtrack body N --file FILE`. For the checklist, use `ghtrack tasks` and
`ghtrack tick` instead — they handle the counter and preserve existing ticks.

## Comments — one per checkpoint event, ≤12 lines

Post with:

```bash
ghtrack comment N --event EVENT --file FILE --sha SHA
```

`spec`, `plan`, `build-started`, and `done` are **singleton** events: re-running
them edits the existing comment. `scope-change`, `blocked`, `repro`, and
`root-cause` are **repeatable**: a new SHA posts a new comment, the same SHA
edits.

### spec

```markdown
**Spec agreed.** [2026-08-10-topic-design.md](PINNED_URL)

Decisions that were genuinely contentious:
- **X over Y** — because Z.
- **Dropped W** — YAGNI for v1; revisit if V happens.

Approach in one line: <the architecture in a sentence>.
Next: implementation plan.
```

Include only decisions where a reasonable person would have chosen differently.
Restating the obvious is noise, and noise is what makes a human stop reading.

### plan

```markdown
**Plan ready.** [2026-08-10-topic.md](PINNED_URL)

8 tasks · size M · critical path 4 tasks
Parallel-safe: tasks 3, 4, 7
Checklist synced to the body.
Next: execution.
```

### build-started

```markdown
**Building.** Branch `42-gh-tracking` · subagent-driven execution.
First task: 1. <title>
```

### scope-change

The most important comment type. A human reading only these must understand
every deviation from what was originally agreed.

```markdown
**Scope change.** <what changed, one line>

**Why:** <the reason — this is the part that matters>
**Invalidates:** <which tasks, decisions, or spec sections are now wrong>
**Revised:** [spec](PINNED_URL) · [plan](PINNED_URL)
```

### blocked

```markdown
**Blocked.** <the blocker, verbatim — do not soften it>

**Need from you:** <the specific decision required>
**Meanwhile:** <what work continues, or "nothing — this blocks the branch">
```

### done

```markdown
**Done.** Merged via <PR url or commit>.

8/8 tasks · tests: <the actual command and its result>
Deferred: <anything parked, with why> (or "nothing")
```

### repro and root-cause (bug track)

```markdown
**Reproduced.** <steps, minimal>
Expected: <x> · Observed: <y>
```

```markdown
**Root cause.** <the mechanism, not the symptom>
Fix approach: <one line>
```

## Token discipline

Every template above is short by design. The rule that keeps tracking cheap:
**write the checkpoint while you still hold the content in context.** If you find
yourself opening a spec file to write a comment about it, stop — you have already
lost the saving this design exists to produce.
````

- [ ] **Step 3: Write the lifecycle skill**

Create `plugins/gh-track/skills/tracking-work-in-github/SKILL.md`:

```markdown
---
name: tracking-work-in-github
description: Use when starting new work, reaching a milestone in a superpowers workflow, or changing agreed scope - creates and updates the GitHub issue that tracks a requirement, bug, or task. Triggers on new requirements, bug reports, "create an issue for this", after a spec or plan is written, when a build starts or finishes, when scope changes, or when a gh-track hook reminder fires.
---

# Tracking Work in GitHub

Superpowers owns how software gets built. This skill owns how it gets tracked:
one GitHub issue per work item, carrying its stage, artifact links, task
checklist, and a timeline of the decisions that shaped it.

**Announce at start:** "I'm using the tracking-work-in-github skill to <post the
spec checkpoint / open an issue for this / record the scope change>."

## The two rules that matter most

1. **Never copy spec or plan prose into GitHub.** The issue holds state, links,
   and decisions. If you are about to paste a requirements list into an issue,
   stop.
2. **Write checkpoints from working memory.** Post the checkpoint while you still
   hold the content in context. Opening a spec file to summarise it into a
   comment defeats the entire design.

## Where am I?

Resolve position before doing anything:

```bash
ghtrack resolve          # issue number for this branch
ghtrack show <N>         # stage, kind, size, checklist progress, artifact links
```

The stage tells you what to do next:

| Stage | Next action |
|---|---|
| (no issue) | Read `references/intake.md`. Create the issue before brainstorming. |
| `backlog` | `superpowers:brainstorming` (feature) or `superpowers:systematic-debugging` (bug) |
| `spec` | `superpowers:writing-plans` |
| `planned` | Execute — `superpowers:subagent-driven-development` or `superpowers:executing-plans` |
| `building` | Tick checklist items as tasks land |
| `review` | Post `done` once merged |
| `triage` / `debugging` | Continue `superpowers:systematic-debugging` |

If `ghtrack resolve` fails, the branch does not follow `<issue>-<slug>`. Ask the
user which issue this is and record it: `ghtrack resolve --set N`.

## Intake

**REQUIRED READ:** `references/intake.md` before creating any issue. It carries
the decision rule that keeps scope changes from becoming duplicate issues.

The rule in one line: a change to work already in flight is a `scope-change`
comment on the existing issue, never a new issue.

## Checkpoints

**REQUIRED READ:** `references/issue-anatomy.md` for the body and comment
templates. Use them as written — they are short by design.

Six events, each with a fixed shape:

| Event | When | Also do |
|---|---|---|
| `spec` | A design doc was written and committed | `ghtrack stage N spec`, add the spec link to the body |
| `plan` | A plan was written and committed | `ghtrack stage N planned`, `ghtrack tasks N --plan FILE`, set `size:*` |
| `build-started` | Execution begins | `ghtrack stage N building` |
| `scope-change` | Agreed scope changed | Revise spec/plan, re-run `ghtrack tasks`, add a `## Decisions` line |
| `blocked` | You cannot proceed | Add the `blocked` label |
| `done` | Merged | `ghtrack stage N done`, rewrite body links to the default branch, close the issue |

On the bug track, `spec` and `plan` are replaced by `repro` and `root-cause`.

**Task completions do not get comments.** Tick the checkbox:
`ghtrack tick N --task K`. Comments are for decisions; the body is for state.

## The checkpoint procedure

Every checkpoint is the same four steps:

1. **Publish the artifact** (spec and plan checkpoints only):
   `ghtrack link N --kind spec --path docs/superpowers/specs/FILE.md`
   Read `pinned_url` and `sha` from its output. If `pushed=no`, use plain
   backticked paths in the comment and say links are unavailable — never block.
2. **Write the comment to a file**, using the matching template from
   `references/issue-anatomy.md`, then
   `ghtrack comment N --event EVENT --file FILE --sha SHA`.
3. **Update the body:** artifact links, `## Decisions` line, and stage in the
   header. Use `ghtrack tasks` for the checklist rather than editing it by hand.
4. **Advance the stage:** `ghtrack stage N <stage>`.

Do these in this order. The comment is the record; if step 3 or 4 fails, the
record still exists.

## When a hook reminder fires

The reminder names the issue and the artifact. Do exactly what it says, then
continue what you were doing. Do not restructure your work around it — it is a
prompt to checkpoint, not a change of task.

If the reminder asks for a `spec` checkpoint but one already exists, that means
the spec was revised: post a `scope-change` checkpoint instead, explaining what
changed and why.

## Failure handling

Tracking never blocks building. If a `ghtrack` call fails:

1. Report the failure in one line, including the command.
2. Continue the development work.
3. Retry the checkpoint at the next natural boundary.

Never abandon implementation work because tracking failed. Never silently
swallow the failure either — the user needs to know the issue is stale.

## Red flags

| Thought | Reality |
|---|---|
| "I'll paste the requirements into the issue" | Never. Link the spec. |
| "Let me re-read the spec to write the comment" | You already have it in context. If you truly don't, summarise from the plan's task list instead. |
| "This task completion deserves a comment" | Tick the checkbox. Comments are for decisions. |
| "The scope changed, so this is a new issue" | Only if it does not change in-flight work. Read `references/intake.md`. |
| "I'll create the issue after brainstorming" | The issue comes first. It is what the branch is named after. |
| "gh failed, I should stop" | Report and keep building. |
| "I'll write the CLAUDE.md rules from memory" | The bootstrap skill copies the template verbatim. |
| "I'll call gh directly, it's just one command" | Every write goes through `ghtrack`, so it stays idempotent. |
```

- [ ] **Step 4: Verify both skills have valid frontmatter and resolvable references**

Run:
```bash
for f in plugins/gh-track/skills/*/SKILL.md; do
  printf '%s: ' "$f"
  head -1 "$f" | grep -q '^---$' && sed -n '2p' "$f" | grep -q '^name: ' && echo "frontmatter ok" || echo "FRONTMATTER BROKEN"
done
ls plugins/gh-track/skills/tracking-work-in-github/references/
```
Expected: both report `frontmatter ok`; the references directory lists
`claude-md-block.md`, `intake.md`, `issue-anatomy.md`.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): add lifecycle skill with anatomy and intake references"
```

---

### Task 6: End-to-end dogfood

**Files:**
- Modify: `plugins/gh-track/README.md` (add Install and Packaging sections)
- Modify: `README.md` (repository root — install instructions)

**Interfaces:**
- Consumes: the whole plugin.
- Produces: proof the design works, plus the install documentation a new project needs.

This task is the real test. Everything before it was tested against a stub; this
runs against real GitHub.

- [ ] **Step 1: Install the plugin from the marketplace**

Push the branch, then in a Claude Code session:

```
/plugin marketplace add mr-ashishpanda/applied-ai-innovation
/plugin install gh-track
```

Expected: both skills appear in the available-skills list, and
`plugins/gh-track/hooks/hooks.json` is registered. Verify the hooks are live by
checking that a SessionStart in a `<issue>-<slug>` branch injects context.

- [ ] **Step 2: Bootstrap this repository**

Ask for setup: "set up GitHub tracking in this repo". The
`setting-up-github-tracking` skill should run and report labels created, board
status, config written, and CLAUDE.md updated.

Verify:
```bash
ghtrack doctor
jq . .claude/gh-track/config.json
grep -c 'gh-track:begin' CLAUDE.md
git check-ignore -q .claude/gh-track/state.json && echo "state ignored"
```
Expected: `doctor` reports `config:` present; config contains `repo` and either a
`project` number or none if the scope is missing; CLAUDE.md marker count is `1`;
`state ignored`.

- [ ] **Step 3: Run one work item end to end**

Use gh-track to track a small real change — adding a `--help` example to
`plugins/gh-track/README.md` is enough. Walk the full lifecycle:

1. Create the issue: `ghtrack new --kind chore --title "Document ghtrack --help output"`
2. Branch `<N>-document-help`
3. Write a plan to `docs/superpowers/plans/`, commit → confirm the hook fires
4. Post the `plan` checkpoint, sync the checklist
5. Implement, tick items with `ghtrack tick`
6. Post `done`, set `stage done`, close

Verify on github.com that the issue shows: one comment per checkpoint and no
duplicates, a checklist with correct ticks and counter, clickable artifact links,
exactly one `stage:*` label, and a board card in the right column (or a warning
that the scope is missing).

- [ ] **Step 4: Verify idempotency against real GitHub**

Re-run the plan checkpoint and `ghtrack init`:

```bash
ghtrack comment <N> --event plan --file /tmp/plan-checkpoint.md --sha <same-sha>
ghtrack init
```
Expected: the comment is **edited**, not duplicated (comment count unchanged on
the issue page); `init` reports no new project and no new labels.

- [ ] **Step 5: Verify the decoupling contract**

Run:
```bash
grep -rn "implementer-prompt\|task-reviewer-prompt\|re-review-prompt\|sdd-workspace\|\.superpowers/sdd" plugins/gh-track/ || echo "no forbidden coupling"
```
Expected: `no forbidden coupling`. Any hit is a violation of the design's central
constraint and must be removed.

- [ ] **Step 6: Document installation**

Add to `plugins/gh-track/README.md`, after the intro:

```markdown
## Install

Once per machine:

```
/plugin marketplace add mr-ashishpanda/applied-ai-innovation
/plugin install gh-track
```

Once per project — in the repository you want tracked, ask Claude:

> set up GitHub tracking in this repo

That runs the `setting-up-github-tracking` skill: it creates the labels and the
project board, writes `.claude/gh-track/config.json`, gitignores the state file,
and merges the tracking rules into your `CLAUDE.md` between
`<!-- gh-track:begin -->` markers. Re-running it after an upgrade replaces only
that block.

Board writes need one extra OAuth scope:

```bash
gh auth refresh -s project
```

Without it, tracking still works — labels remain canonical and you lose only the
kanban view.
```

Add to the repository root `README.md`, in the `Plugins` table row for gh-track,
a pointer to those install instructions.

- [ ] **Step 7: Commit**

```bash
git add plugins/gh-track/README.md README.md
git commit -m "docs(gh-track): document install and record dogfood results"
```

---

## Plan Self-Review

**Spec coverage.** Packaging and two-layer install (Task 1, 6). PostToolUse
wildcard hook with three-way classification and hash debounce (Task 2).
SessionStart context injection, including its role as the bug track's enforcement
(Task 3). CLAUDE.md template with markers, copied verbatim, and the merge
procedure's three cases (Task 4). Lifecycle skill with the six events, both
tracks, the four-step checkpoint procedure, and failure handling (Task 5). Intake
decision rule, capture-only, split-on-request, regression cross-linking (Task 5,
`intake.md`). Body and comment templates including the done-checkpoint link
rewrite (Task 5, `issue-anatomy.md`). Decoupling contract asserted as an
executable grep (Task 6). Success criteria from the spec are exercised by Task 6
steps 1–5.

**Placeholder scan.** No TBDs. The two genuinely unverifiable-until-runtime items
— the marketplace `source` form (Task 1 Step 4) and the hook output contract
(Task 2 Step 6) — each state a primary form, an exact fallback, and how to tell
which is correct. Those are decisions with contingencies, not deferred work.

**Name consistency.** Skill names `tracking-work-in-github` and
`setting-up-github-tracking` match between the hooks' reminder text, the CLAUDE.md
template, both SKILL.md frontmatter blocks, and the READMEs. Event names
(`spec`, `plan`, `build-started`, `done`, `scope-change`, `blocked`, `repro`,
`root-cause`) match `comment.sh`'s two event lists from plan 1. Stage names match
`GHT_STAGES`. `## Tasks (from plan - N/M)` is ASCII-hyphenated everywhere.
`ghtrack` invocations use the flags plan 1 defines.

**Cross-plan dependency.** Task 2's test file sources plan 1's
`tests/helpers.sh` and runs under plan 1's `tests/run`. Plan 1 must be complete
first; running this plan against a missing CLI fails at Task 2 Step 2.
