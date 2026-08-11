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
