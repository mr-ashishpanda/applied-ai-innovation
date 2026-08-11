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
usually deleted on merge and its links would rot. Get that URL directly from
`ghtrack link` output's `default_url` field — it is computed for exactly this
rewrite, so there is no need to build it by hand.

`## Decisions` is append-only, one line each: the decision, then the reason,
then the checkpoint it came from in parentheses. It is the digest of the comment
timeline, so the body alone answers "why is it like this?"

To update the body: read the current body with `ghtrack body N` (no `--file`),
edit the section you own, write the whole thing back with `ghtrack body N
--file FILE` — it is a full replace, not a patch. For the checklist, use
`ghtrack tasks` and `ghtrack tick` instead — they handle the counter and
preserve existing ticks.

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
