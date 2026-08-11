# gh-track — sub-issues for multi-plan specs

**Date:** 2026-08-11
**Status:** Approved design
**Addendum to:** [2026-08-10-gh-track-design.md](2026-08-10-gh-track-design.md)

## Problem

The original design chose one issue per work item, with the plan's tasks as a
single checklist in that issue's body — deliberately rejecting sub-issues per
plan task to keep one board card per feature. That decision holds for the
common case: one spec, one plan. It breaks down when a spec decomposes into
multiple plans (this project's own CLI + plugin plans are the precedent): the
checklist either has to interleave two plans' tasks under one counter, or the
second plan's progress is invisible until someone reads the body closely.

This addendum revisits that decision **only** for the multi-plan case. The
single-plan case is unchanged.

## Decision

When a spec has more than one plan, plan 2 onward gets its own **GitHub-native
sub-issue** under the parent. Plan 1 keeps living on the parent issue exactly
as today — no retrofit, no migration. This is asymmetric on purpose: the
parent issue is both "the feature" and, incidentally, "plan 1's tracker,"
which costs nothing extra and avoids migrating already-ticked task state.

## Trigger — plan count, not phase

The `artifact-changed` hook already fires on every write under
`docs/superpowers/plans/**` and prompts the plan-ready checkpoint for the
issue resolved from the current branch. That checkpoint step now inspects the
parent issue's `Artifacts` section:

- **First** distinct plan link for this issue → unchanged: comment + `ghtrack
  tasks` write to the parent, exactly as the original design.
- **Second or later** distinct plan link → switch to the sub-issue path below.

This is deliberately plan-count-based, not "are we mid-build" based. A spec
known upfront to need two plans, and major work discovered mid-build that
turns out to need its own plan, are **the same trigger**: both produce a
second plan artifact under the same issue, and the hook cannot tell — nor
needs to — which story produced it.

## Creating the sub-issue

A new CLI subcommand:

```
ghtrack split N --plan P --title T [--size S]
```

- Creates a new issue: `kind` inherited from the parent, `stage:planned`, size
  if given.
- Links it as a GitHub-native sub-issue of `N` via the REST `sub_issues` API,
  so GitHub's own UI shows the parent's rollup progress bar in addition to
  what gh-track tracks itself.
- Adds it to the board with its own card.
- Prints the new issue number.
- **Idempotent:** the plan path → sub-issue number mapping is recorded in
  `state.json`; a repeat call for the same plan path returns the existing
  number instead of creating a duplicate.

The plan-ready checkpoint then runs its normal steps (`link`, `tasks`,
comment) against this **new sub-issue number**. It also posts a short comment
on the **parent**:

```
Split into sub-issue #N — Plan 2: <title>
```

## Parent rollup

`ghtrack stage` gains a step: after setting a sub-issue's stage, it looks up
the sub-issue's parent via the native GitHub parent-issue link and recomputes
the parent's own stage as:

```
min(plan 1's own stage on the parent, stage of every sub-issue)
floored at stage:building
```

The floor exists because plan 1 already put the parent at `stage:building` or
later by the time any sub-issue exists. The parent reaches `stage:done` only
when plan 1 **and** every sub-issue are done. This updates the parent's
`stage:*` label and board Status in the same call — the same idempotent,
label-canonical mechanism the original design already uses everywhere else.

## Decisions line

The first time a split happens, gh-track appends one line to the parent's
`Decisions` section:

```
- Decomposed into sub-issues — plan 1 stays on the parent, plan 2+ tracked as sub-issues (spec)
```

## Mid-build major work — the decision rule

This was the open question going in: when new work surfaces mid-build, how do
we route it? The answer turns out to require no new plumbing, only a
sharpened decision rule in the `tracking-work-in-github` skill's existing
scope-change section:

| Size of the new work | Route | Mechanism |
|---|---|---|
| Small — a few checklist items, no new design questions | Retrofit into the current plan's checklist in place | The **original** scope-change mechanism: scope-change comment, plan revised in place, tasks resynced. Unchanged, already built. |
| Major, but serves the same spec — needs its own task breakdown | Write it as a new plan under the same spec (`superpowers:writing-plans`), same issue | The sub-issue split above. No new trigger: the second plan artifact fires the same hook. |
| Serves a different problem entirely | New, independent issue | The **original** intake decision tree's `NEW ISSUE` path, cross-linked `Split from #N`. Unchanged, already built. |

The judgment call — "does this need its own task breakdown, or does it fit in
the current checklist" — is exactly the same judgment `writing-plans` already
makes when deciding whether new scope needs a new plan document versus an
amendment to the existing one. gh-track adds no separate heuristic; it just
reacts to whichever way that call comes out.

## What's unchanged

- Single-plan specs: identical to the original design, no sub-issues ever
  created.
- The board: still label-canonical, still degrades gracefully without the
  `project` scope.
- Checkpoint comments, body anatomy, decoupling contract, token economics: all
  apply identically to a sub-issue as to any other issue — a sub-issue is a
  normal issue that happens to have a parent.

## Testing strategy (addition)

- **Split idempotency.** `ghtrack split` run twice for the same plan path
  creates exactly one issue and one sub-issue link.
- **Rollup matrix.** Unit-test `ghtrack stage`'s parent recomputation against
  a table of (plan-1 stage, sub-issue stages) → expected parent stage,
  including the `stage:building` floor and the all-done case.
- **First-vs-second-plan routing.** Feed `artifact-changed.sh` two plan writes
  for the same issue; assert the first produces a normal checkpoint prompt on
  the parent and the second produces a split prompt instead.
- **Dogfood:** if this project itself ever needs a third plan for an existing
  spec, use gh-track to track it and treat any friction as a bug in this
  design.

## Success criteria (addition)

- A spec with two plans produces one parent issue and one sub-issue, each with
  its own board card, and the parent's board card reflects the slower of the
  two.
- Major work discovered mid-build, once written as its own plan, is tracked as
  a sub-issue without any manual `ghtrack` invocation beyond what the plan
  checkpoint already does.
- A single-plan spec behaves identically to before this addendum.
