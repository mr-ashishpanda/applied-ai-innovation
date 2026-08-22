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
| `feature` | triage → spec → planned → building → review → done | `superpowers:brainstorming` |
| `bug` | triage → debugging → building → review → done | `superpowers:systematic-debugging` |
| `chore` | triage → planned → building → review → done | `superpowers:writing-plans` |

Create it before any brainstorming or debugging:

```bash
ghtrack new --kind feature --title "Short imperative title"
```

The issue starts at `stage:backlog`. Then:

- **Starting work now?** Create the branch `<issue>-<slug>`, post the
  `pickup` checkpoint (`ghtrack stage N triage`) **before** brainstorming,
  triaging, or writing a plan — this is what moves the board from untouched
  Backlog to Todo the moment someone actually picks the item up, rather than
  only once the first artifact (spec, plan, or repro) is committed. Then
  advance the stage as the work reaches each further checkpoint.
- **Capturing for later?** Stop here. No branch, no spec, no brainstorming, no
  `pickup` checkpoint. A one-line requirement at `stage:backlog` is a
  complete, valid backlog item.

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

## Deferred findings become their own issue, immediately

A task-level or whole-branch review sometimes produces a finding that is
real and understood, but deliberately NOT fixed now — too large, wrong
scope, needs its own design pass. The moment that ruling is made, create a
tracked issue for it (`ghtrack new`) in the SAME turn — do not wait for the
closing checkpoint, and do not settle for writing it into the current
issue's `## Decisions` line as the only record. A closed issue's history is
not something anyone reads before starting unrelated future work, so a
finding that lives only there is functionally forgotten the moment the
issue closes.

If another already-tracked issue depends on the deferred finding — its own
author needs to know about it before they start — add an explicit
reference in *that issue's own body* too, not only a link back from the new
issue. One-directional linking ("the new issue mentions what spawned it")
is not enough; the dependent issue has to carry the pointer itself, since
that is the issue whoever picks it up will actually be reading.

This was learned the concrete way: a whole-branch review surfaced two real
architectural gaps, both recorded only in the closing issue's `## Decisions`
line and in code comments. Neither got a tracked issue until asked for
directly, and a downstream issue that genuinely depended on one of them had
no reference to it at all — its future author would have had no way to
find it short of searching.

## Issues under an existing epic use `ghtrack new --epic E`

If a new issue is a child of an existing "Epic N: ..." tracking issue,
create it with `ghtrack new --kind K --title T --epic E`, not plain
`ghtrack new`. The `--epic` flag numbers the title `N.<next>` (matching the
convention already visible on sibling children), writes an `**Epic:** #E`
header into the body, and links the new issue as `E`'s GitHub-native
sub-issue — one command instead of four manual steps that are each easy to
skip under time pressure.

This is not merely a formatting nicety: an epic's own "Children" list may be
hand-maintained prose with zero structural backing (verified in one repo —
an epic listing seven children as prose had ZERO native sub-issues linked),
which means nothing but memory enforces that a new child gets recorded
consistently. `--epic` fixes the structure at creation time instead of
requiring a later retrofit.
