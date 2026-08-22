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
| `backlog` | Not picked up yet. The moment you start, post `pickup` (below) before anything else. |
| `triage` (feature/chore) | Picked up, no spec yet — `superpowers:brainstorming`, then post `spec` |
| `triage` (bug) | Picked up, not yet reproduced — `superpowers:systematic-debugging`, then post `repro` |
| `spec` | `superpowers:writing-plans` |
| `planned` | Execute — `superpowers:subagent-driven-development` or `superpowers:executing-plans` |
| `building` | Tick checklist items as tasks land |
| `review` | Post `done` once merged |
| `debugging` | Continue `superpowers:systematic-debugging`; post `root-cause` once found |

If `ghtrack resolve` fails, one of two things is true. If the message names a
**shared branch** (`main`, `v2`, or whatever the repo's `.sharedBranches`
config lists), that is expected — no single issue is tracked on a long-lived
integration branch, and this is not something to fix by recording one. Only on
an actual per-task branch that just doesn't follow `<issue>-<slug>`, ask the
user which issue this is and record it: `ghtrack resolve --set N` (undo with
`ghtrack resolve --clear`). Never run `--set` from a shared branch — it would
pin one issue to a path that gets reused for every future task, and the tool
refuses it for exactly that reason.

## Intake

**REQUIRED READ:** `references/intake.md` before creating any issue. It carries
the decision rule that keeps scope changes from becoming duplicate issues.

The rule in one line: a change to work already in flight is a `scope-change`
comment on the existing issue, never a new issue.

### Mid-build: does new work need its own plan?

When work surfaces mid-build, decide its size the same way `writing-plans`
already would:

- **Fits the current checklist** (a few items, no new design questions) —
  a `scope-change` checkpoint, checklist grown in place. Nothing new here.
- **Needs its own task breakdown, same spec** — write it as a new plan
  (`superpowers:writing-plans`, same issue). The very next plan checkpoint
  is now a *second* plan for this issue, which routes through `ghtrack
  split` below (see Checkpoints) automatically. No separate decision to
  make.
- **A different problem entirely** — a new, independent issue per
  `references/intake.md`.

## Checkpoints

**REQUIRED READ:** `references/issue-anatomy.md` for the body and comment
templates. Use them as written — they are short by design.

Six core events, each with a fixed shape, plus the `split` variant of `plan`
for a second-or-later plan on the same issue, and the lightweight `pickup`
event below that precedes all of them:

| Event | When | Also do |
|---|---|---|
| `pickup` | Work is picked up — brainstorming or triage begins, before any artifact exists | `ghtrack stage N triage` (no comment — starting work is not yet a decision) |
| `spec` | A design doc was written and committed | `ghtrack stage N spec`, add the spec link to the body |
| `plan` | A plan was written and committed | `ghtrack stage N planned`, `ghtrack tasks N --plan FILE`, `ghtrack size N s\|m\|l` |
| `plan` (2nd+ for this issue) | A second plan was written for the same spec | `ghtrack split ISSUE --plan FILE --title T`, then run the `plan` checkpoint steps below against the **new sub-issue number**, and post a `split` comment on the parent (see `references/issue-anatomy.md`) |
| `build-started` | Execution begins | `ghtrack stage N building` |
| `scope-change` | Agreed scope changed | Revise spec/plan, re-run `ghtrack tasks`, add a `## Decisions` line |
| `blocked` | You cannot proceed | Add the `blocked` label |
| `done` | Merged | `ghtrack stage N done`, rewrite body links to the default branch, `ghtrack close N` |

`pickup` reuses the `triage` stage for every kind, not only bugs: a feature
or chore that has been picked up but has no spec yet sits at `stage:triage`
exactly like a bug being investigated does — the label is shared, the next
action is not (see the stage table above and `references/intake.md`).
Without this event, an issue sits at `stage:backlog` — indistinguishable
from "nobody has looked at this" — for the entire brainstorming or triage
conversation, however long it runs, and only ever moves once the first
artifact (spec, plan, or repro) is committed.

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
3. **Update the body:** read it with `ghtrack body N`, edit the artifact
   links, `## Decisions` line, and header in place, then write the whole
   body back with `ghtrack body N --file FILE` — it's a full replace, not a
   patch. Use `ghtrack tasks` for the checklist rather than editing it by
   hand.
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

If the command exited **6**, the issue was **not** updated — a `gh` read that
shapes the write failed, so the write was refused rather than applied
partially. Treat this the same as any other failure (report, keep building,
retry later), but do not assume partial progress: nothing changed.

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
| "This finding is real but out of scope — I'll just note it in Decisions" | That note dies with the issue's history. Create a tracked issue for it now; see `references/intake.md`. |
| "This issue belongs under an epic, but plain `ghtrack new` is right there" | Use `ghtrack new --epic E` — it numbers, headers, and links the issue in one step instead of four easy-to-skip manual ones. |
