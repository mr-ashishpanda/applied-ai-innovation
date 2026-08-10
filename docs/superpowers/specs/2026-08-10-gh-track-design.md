# gh-track — GitHub issue & project tracking for superpowers workflows

**Date:** 2026-08-10
**Status:** Approved design

## Problem

Superpowers drives software development through a spec → plan → implement
pipeline whose artifacts are markdown files in the repo. That is excellent for
an agent and poor for a human: to learn what was decided, what is in flight, and
what is left, a person must read full spec and plan documents.

We want GitHub issues and a GitHub project board to be the human-facing single
source of truth for every requirement, bug, and task — without duplicating spec
and plan content into GitHub, and without coupling to superpowers internals that
change between releases.

## Goal

A Claude Code plugin, `gh-track`, that layers GitHub issue and project tracking
onto superpowers' existing development workflow. Every work item gets one issue
that carries its current state, links to its artifacts, and a short timeline of
the decisions that shaped it.

## Non-goals

- Re-implementing decomposition. Superpowers' brainstorming and writing-plans
  own that; gh-track only reflects their output.
- Orchestrating execution. `subagent-driven-development` owns that.
- Mirroring spec or plan prose into GitHub. Explicitly forbidden (see
  "Token economics").
- Multi-repo or team workflows. Single-repo, solo-builder scope.

## Core principles

1. **The issue is a control panel, not a copy.** It holds state, links, and
   decisions. Never spec or plan prose.
2. **Write from working memory, never re-read.** Checkpoints are written at the
   moment the agent already holds the content in context. Reading a spec file
   back in order to mirror it into GitHub is the waste this design exists to
   avoid.
3. **Comments are for decisions; the body is for state.** Task completions edit
   the body. Only the six checkpoint events produce comments.
4. **Labels are canonical; the board mirrors them.** Labels work with the `repo`
   scope and are greppable. A missing `project` scope or a Projects API failure
   costs the kanban view, not the truth.
5. **Depend only on superpowers' public surface.** Paths, user-facing skill
   names, and git state. Nothing else.

---

## Packaging

Authored in this repository at `plugins/gh-track/`, published through a root
`.claude-plugin/marketplace.json`. This keeps the repository multi-purpose while
making the plugin installable anywhere. Because the marketplace and the plugin
live in the same repository, the entry uses a repository-relative source
(`"source": "./plugins/gh-track"`); if relative sources prove unsupported, the
fallback is the `git-subdir` form the official marketplace uses, pointing at this
repository's URL with `"path": "plugins/gh-track"`. This is verified against a
real `/plugin marketplace add` during implementation.

```
.claude-plugin/marketplace.json          # marketplace manifest (repo root)
plugins/gh-track/
├── .claude-plugin/plugin.json
├── skills/
│   ├── tracking-work-in-github/
│   │   ├── SKILL.md                     # the lifecycle skill
│   │   └── references/
│   │       ├── issue-anatomy.md         # body + comment templates
│   │       ├── intake.md                # the four entry points
│   │       └── claude-md-block.md       # verbatim CLAUDE.md template
│   └── setting-up-github-tracking/
│       └── SKILL.md                     # per-project bootstrap
├── scripts/
│   └── ghtrack                          # all gh plumbing, one CLI
└── hooks/
    ├── hooks.json
    ├── artifact-changed.sh              # PostToolUse on docs/superpowers/**
    └── session-context.sh               # SessionStart issue context injection
```

Two-layer install:

- **Layer 1, once per machine.** `/plugin marketplace add
  mr-ashishpanda/applied-ai-innovation` then `/plugin install gh-track`. Ships
  skills, scripts, and hooks. Because a plugin carries its own
  `hooks/hooks.json`, the user's `settings.json` is never modified.
- **Layer 2, once per project.** The `setting-up-github-tracking` skill creates
  labels, creates or links the board, writes config, and merges the CLAUDE.md
  block. Inherently per-repository, so it cannot live in the plugin's install.

---

## State model

The issue is the state machine. No sidecar state to drift out of sync. Any fresh
session reconstructs full context from two reads:

```
git branch --show-current   →  "42-gh-tracking"  →  issue #42
gh issue view 42            →  label stage:planned  →  next action: execute plan
```

**Branch naming is the linchpin:** `<issue-number>-<slug>`. Superpowers'
`using-git-worktrees` does not prescribe a branch name — it uses whatever the
agent picks — so declaring this convention in CLAUDE.md makes superpowers
produce a correctly-named branch without knowing gh-track exists.

**Fallback:** if the current branch does not match `^[0-9]+-`, gh-track consults
a git-ignored `.claude/gh-track/state.json` mapping worktree path → issue
number. If neither resolves, it asks the user once and records the answer.

**Branch creation happens at pickup, not intake.** Backlog items are branchless.
The branch is created when work begins, which is when the worktree skill runs
anyway.

### Stages

Canonical stage is a label. Two tracks share the same terminal stages.

| Track | Stages |
|---|---|
| Feature / chore | `stage:backlog` → `stage:spec` → `stage:planned` → `stage:building` → `stage:review` → `stage:done` |
| Bug | `stage:backlog` → `stage:triage` → `stage:debugging` → `stage:building` → `stage:review` → `stage:done` |

### Labels

Created idempotently by the bootstrap skill via `gh label create --force`:

- `stage:backlog`, `stage:spec`, `stage:triage`, `stage:planned`,
  `stage:debugging`, `stage:building`, `stage:review`, `stage:done`
- `kind:feature`, `kind:bug`, `kind:chore`
- `size:s`, `size:m`, `size:l` — scope, never hours
- `parallel-safe`, `blocked`

Exactly one `stage:*` and one `kind:*` label per issue; setting a stage removes
the previous one.

### Project board

One board per repository, titled after the repository, auto-created if absent.
Fields:

- **Status** — single-select: `Backlog`, `Todo`, `Doing`, `Review`, `Done`
- **Size** — single-select: `S`, `M`, `L`

Stage → Status mapping:

| Stage | Status |
|---|---|
| `backlog` | Backlog |
| `spec`, `triage`, `planned` | Todo |
| `building`, `debugging` | Doing |
| `review` | Review |
| `done` | Done |

Board writes require the `project` OAuth scope. The bootstrap skill probes for
it and, if missing, instructs the user to run `gh auth refresh -s project` and
proceeds label-only until they do.

---

## Issue anatomy

### Body — rewritten in place, never appended to

```markdown
**Stage:** building · **Kind:** feature · **Size:** M · **Branch:** `42-gh-tracking`

## Goal
One paragraph: what this delivers and why it matters.

## Artifacts
- Spec: [2026-08-10-gh-track-design.md](https://github.com/o/r/blob/42-gh-tracking/docs/superpowers/specs/2026-08-10-gh-track-design.md)
- Plan: [2026-08-10-gh-track.md](https://github.com/o/r/blob/42-gh-tracking/docs/superpowers/plans/2026-08-10-gh-track.md)

## Tasks (from plan — 3/8)
- [x] 1. ghtrack CLI: issue read/write
- [x] 2. Body renderer
- [ ] 3. Checkpoint comments
- [ ] 4. Hook wiring

## Decisions
- Checklist not sub-issues — one board card per feature (spec)
- Labels canonical, board mirrors — survives a missing `project` scope (spec)
```

Body links point at **branch HEAD** so they always show the current artifact.
At the Done checkpoint they are rewritten to point at the default branch, because
the work branch is usually deleted on merge and its links would rot. The
SHA-pinned links in comments are unaffected by branch deletion and remain the
permanent record.

The `Decisions` list is append-only and one line each: the decision, then the
reason. It is a digest of the checkpoint comments, so the body alone answers
"why is it like this?"

**Size** is set at the plan checkpoint, not at intake, since task count and
critical path are what make the estimate meaningful. An issue captured at
`stage:backlog` carries no size until it is planned. The `size:*` label and the
board's Size field are written together.

### Comments — six events, each ≤12 lines

| Event | Content |
|---|---|
| Spec agreed | The 3–5 decisions that were genuinely contentious, plus the spec permalink |
| Plan ready | Task count, sizes, parallel-safe set, critical path, plus the plan permalink |
| Build started | Branch, first task, execution mode (subagent-driven or inline) |
| Scope change | What changed, **why**, what it invalidates, revised-artifact permalink |
| Blocked | The blocker verbatim, and what decision is needed to clear it |
| Done | PR link, tasks completed, test evidence, anything deferred |

On the bug track the first three are replaced by: **repro confirmed** (steps and
observed vs expected), **root cause found** (the mechanism, not the symptom),
and **fix approach**.

Comment links are **SHA-pinned permalinks**, so a comment always renders the
artifact as it stood when the decision was made:

```
https://github.com/o/r/blob/a1b2c3d/docs/superpowers/specs/2026-08-10-gh-track-design.md
```

Every comment carries an invisible idempotency marker as its first line:

```html
<!-- gh-track:<event>:<sha> -->
```

Re-running a checkpoint whose marker already exists **edits** that comment
rather than posting a duplicate.

### Publishing artifacts

Superpowers already commits spec and plan files. gh-track adds one step: `git
push` the current branch so GitHub can render the file, then construct the URL.
No new content is written. Because the whole lifecycle for a work item lives on
`<issue>-<slug>`, this push is always safe — it never targets a default branch.

If the push fails (no remote, no permission, detached HEAD), gh-track degrades
to plain repository paths in backticks and says so in the comment. It never
blocks development on a tracking failure.

---

## Intake

Four entry points, one decision rule.

```
new requirement / bug report / change to how something works
                        │
        ┌───────────────┴────────────────┐
        │ Does this change work already   │
        │ in flight (stage:spec through   │
        │ stage:building)?                │
        └───────────────┬────────────────┘
              yes       │        no
               │        └──────────────────► NEW ISSUE
               ▼                              kind:feature → brainstorming
     SCOPE CHANGE on that issue               kind:bug     → systematic-debugging
     • scope-change comment                   kind:chore   → straight to planning
       (what / why / what it invalidates)     or capture-only at stage:backlog
     • spec and plan revised in place
     • task checklist adjusted
     • NO new issue
```

**Capture-only intake.** A one-line requirement produces an issue at
`stage:backlog` with a goal and nothing else — no branch, no spec, no
brainstorming. That is the backlog. Picking it up is a later session that starts
by reading the issue.

**Bugs run the bug track.** A bug does not pass through brainstorming; it goes to
`superpowers:systematic-debugging`. Known limitation: systematic-debugging writes
no files under `docs/superpowers/`, so the path-watching hook cannot fire on the
bug track. Bug checkpoints are driven by the CLAUDE.md instruction and the
SessionStart context injection instead. This is accepted deliberately —
inventing an artifact directory superpowers does not have is exactly the
coupling that breaks on upgrade.

**Scope changes never fork silently.** When a change is large enough that it
should not block current work, gh-track offers to split it into a follow-up
issue cross-linked `Split from #42`. That is the user's explicit choice, never
automatic.

**Regressions against shipped work** are always new issues, cross-linked
`Regressed from #42`, so the original issue remains an accurate record of what
shipped.

---

## Enforcement

Three mechanisms, ordered from most to least deterministic.

**1. PostToolUse hook — `artifact-changed.sh`.** Matches `Write` and `Edit` on
paths under `docs/superpowers/**` (wildcard, not just `specs/` and `plans/`).
Classifies the path and emits a `system-reminder`:

| Path | Reminder |
|---|---|
| `specs/**` | Spec artifact changed for #N — post the spec checkpoint (or a scope-change checkpoint if a spec checkpoint already exists) |
| `plans/**` | Plan artifact changed for #N — post the plan checkpoint and sync the task checklist |
| anything else | New superpowers artifact at `<path>` — consider a one-line note on #N |

The wildcard is deliberate future-proofing: superpowers currently writes only
`specs/` and `plans/`, so if a future release adds `docs/superpowers/research/`,
gh-track notices instead of silently ignoring it. Unknown paths get the mildest
nudge so they cannot become noise.

The hook is debounced by content hash, recorded in
`.claude/gh-track/state.json`: a repeated write with unchanged content produces
no reminder. This keeps iterative editing from generating a stream of nudges.

**2. SessionStart hook — `session-context.sh`.** Resolves the current issue from
the branch and injects a compact context line — issue number, title, stage, next
expected action. This is what lets a fresh session, or a session after
compaction, know where it is without reading any artifact.

**3. The CLAUDE.md block.** Merged into the project's real CLAUDE.md between
`<!-- gh-track:begin -->` and `<!-- gh-track:end -->` markers. It states the
branch-naming convention, that superpowers owns the development workflow, and
that gh-track owns tracking. The verbatim template lives at
`references/claude-md-block.md` rather than as prose inside SKILL.md: a model
paraphrasing instructions produces a different CLAUDE.md in every project, and
the convention drifts. Markers make re-bootstrapping after a plugin upgrade
replace only gh-track's own block and never touch the user's content.

---

## The `ghtrack` CLI

All `gh` plumbing lives in one deterministic shell script, so it is testable
without a model and the skills stay short. Every subcommand is idempotent.

| Subcommand | Behaviour |
|---|---|
| `ghtrack doctor` | Verify `gh` present, authed, scopes, repo, config, board reachable. Report, never mutate. |
| `ghtrack init` | Create labels, create or link the board with its fields, write config. |
| `ghtrack new --kind K --title T [--size S] [--body-file F]` | Create an issue at `stage:backlog`, add it to the board, print the number. |
| `ghtrack resolve` | Print the issue number for the current branch or worktree, resolving via branch name then state file. |
| `ghtrack show N` | Print issue stage, kind, size, artifacts, and checklist progress as compact key=value lines. |
| `ghtrack stage N STAGE` | Swap the `stage:*` label and mirror Status onto the board. |
| `ghtrack body N --file F` | Replace the issue body from a rendered file. |
| `ghtrack comment N --event E --file F [--sha SHA]` | Post or edit a marked comment, resolving the marker for idempotency. |
| `ghtrack link N --kind spec\|plan --path P` | Push the branch, compute HEAD and pinned URLs, print both. |
| `ghtrack tasks N --plan P` | Extract `### Task N:` headings from the plan and sync the body checklist. |
| `ghtrack tick N --task K` | Mark checklist item K complete in the body. |

Failure policy: every subcommand exits non-zero with a single-line reason on
stderr. Tracking failures never abort development work — the skill reports the
failure and continues.

### Configuration — `.claude/gh-track/config.json`

Committed to the repository, so tracking behaviour travels with the project.

```json
{
  "repo": "owner/name",
  "project": 3,
  "specGlob": "docs/superpowers/specs/**/*.md",
  "planGlob": "docs/superpowers/plans/**/*.md",
  "taskHeadingPattern": "^### Task ([0-9]+):",
  "branchPattern": "^([0-9]+)-",
  "board": { "statusField": "Status", "sizeField": "Size" }
}
```

`.claude/gh-track/state.json` (git-ignored) holds only ephemeral data: worktree →
issue mappings and hook debounce hashes. Because config and state share a
directory, the bootstrap skill adds `.claude/gh-track/state.json` to `.gitignore`
and verifies with `git check-ignore` before writing it.

---

## Decoupling contract

gh-track may depend on exactly five things, all of them superpowers' public
surface:

1. Spec path glob — configurable
2. Plan path glob — configurable
3. Plan task heading pattern — configurable
4. User-facing skill names (`superpowers:brainstorming`, and so on)
5. Git state — branch, commits, SHAs

It must never read or depend on: internal prompt files
(`implementer-prompt.md`, `task-reviewer-prompt.md`, `re-review-prompt.md`), the
subagent-driven-development ledger format, anything under `.superpowers/sdd/`,
the review-loop structure, or `scripts/sdd-workspace`.

Items 1–3 live in config, so a superpowers rename is a one-line config edit
rather than a skill rewrite. `ghtrack doctor` performs a **compatibility probe**:
if the configured spec and plan directories do not exist while other
`docs/superpowers/` directories do, it reports a likely convention change
instead of failing silently months later.

---

## Token economics

The design's central claim is that tracking is nearly free. Per work item:

| Item | Cost | Why |
|---|---|---|
| 6 checkpoint comments | ~250 each ≈ 1.5k | Written from working memory; no artifact re-read |
| ~8 body rewrites | ~200 each ≈ 1.6k | The body is capped small by design |
| 4 session reads (`ghtrack show`) | ~300 each ≈ 1.2k | Replaces re-reading the spec to recover state |
| **Total** | **~4k** | Against a feature costing 200k+ to build |

This holds only because the issue never contains spec or plan prose. The moment
content is mirrored, cost scales with artifact size and the copy goes stale.
Links and decisions only.

---

## Error handling

| Failure | Behaviour |
|---|---|
| `gh` missing or unauthenticated | `doctor` reports it; skills degrade to no-op with one warning. Development continues. |
| Missing `project` scope | Labels only; board writes skipped with a warning naming the fix (`gh auth refresh -s project`). |
| Projects API error | Same as above — labels remain canonical. |
| Push fails | Comment uses plain backticked paths and states that links are unavailable. |
| Issue cannot be resolved | Ask the user once, record the answer in `state.json`. |
| Duplicate checkpoint | Marker lookup finds the existing comment and edits it. |
| Plan task headings unparseable | Report the pattern that failed and skip checklist sync; do not guess. |
| Issue closed but work continues | Warn, offer to reopen; never silently reopen. |

---

## Testing strategy

`ghtrack` is the tested surface, since it holds all logic that can be wrong.

- **Unit, no network.** Body rendering, checklist extraction from a fixture plan,
  marker parsing, stage→Status mapping, branch→issue resolution, permalink
  construction from a fixture git repo. `gh` is stubbed by a fake on `PATH` that
  records its arguments, so tests assert the exact `gh` invocations.
- **Idempotency.** Every mutating subcommand runs twice against the stub; the
  second run must produce no additional create calls.
- **Hooks.** Feed `artifact-changed.sh` synthetic PostToolUse payloads for a spec
  path, a plan path, an unknown `docs/superpowers/` path, and an unrelated path;
  assert the reminder text and that the unrelated path is silent. Assert the
  debounce suppresses an unchanged repeat.
- **Bootstrap.** Run `setting-up-github-tracking` against a scratch repository
  with the `gh` stub; assert labels, config, and CLAUDE.md merge. Run twice and
  assert the CLAUDE.md block is replaced, not duplicated, and that user content
  outside the markers is untouched.
- **Dogfood.** Use gh-track to track its own remaining implementation work. Any
  friction found there is a bug in the design.

## Build order

1. `ghtrack` CLI with unit tests and the `gh` stub — deterministic foundation.
2. `tracking-work-in-github` skill plus its reference files.
3. `setting-up-github-tracking` bootstrap skill and the CLAUDE.md template.
4. Hooks and `hooks.json`.
5. Marketplace manifest and plugin manifest.
6. README documentation, matching the existing `ssm-ssh-access` entry style.
7. Dogfood run.

## Success criteria

- From a clean machine: two commands install the plugin, one sentence bootstraps
  a project.
- A one-line requirement becomes a backlog issue without any spec work.
- A feature carried through brainstorming, planning, and execution in three
  separate sessions produces one issue whose comments tell the whole story, with
  no session needing to be told which issue it is on.
- A scope change mid-build produces a comment explaining why, and no new issue.
- No spec or plan prose appears anywhere in GitHub.
- Deleting the `gh-track` plugin leaves superpowers workflows fully functional.
