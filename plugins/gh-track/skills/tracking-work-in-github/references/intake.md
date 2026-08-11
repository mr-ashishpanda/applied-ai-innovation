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
