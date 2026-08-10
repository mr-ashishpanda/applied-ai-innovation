# gh-track

GitHub issue and project tracking for [superpowers](https://github.com/obra/superpowers)
development workflows.

Superpowers drives development through spec → plan → implement, with artifacts
as markdown files in the repository. gh-track adds a human-facing layer: every
work item gets one GitHub issue carrying its current state, links to its
artifacts, and a short timeline of the decisions that shaped it.

**It never copies spec or plan prose into GitHub.** The issue is a control
panel — state, links, decisions. Checkpoint comments are written from what the
agent already holds in context, so tracking costs roughly 4k tokens per feature
and no artifact is ever re-read for tracking's sake.

## The `ghtrack` CLI

Every GitHub mutation lives in `scripts/ghtrack`, so it is deterministic,
idempotent, and testable without a model.

| Subcommand | Purpose |
|---|---|
| `doctor` | Check gh, auth, scopes, config, board, artifact conventions. Never mutates. |
| `init` | Create labels and the board, write config, gitignore state. Idempotent. |
| `new --kind K --title T` | Create an issue at `stage:backlog`; prints the number. |
| `resolve` | Print this branch's issue number. `--set N` records one manually. |
| `show N` | Issue state as compact `key=value` lines. |
| `stage N STAGE` | Swap the stage label, mirror board Status. |
| `body N --file F` | Replace the issue body. |
| `comment N --event E --file F` | Post or edit a marked checkpoint comment. |
| `link N --kind spec\|plan --path P` | Push the branch, print artifact URLs. |
| `tasks N --plan P` | Sync the body checklist from a plan's task headings. |
| `tick N --task K` | Mark checklist item K complete. |

## Design invariants

- **Labels are canonical; the board mirrors them.** A missing `project` scope
  or a Projects API failure costs the kanban view, not the truth.
- **Tracking failures never abort development.** Every failure is a non-zero
  exit with a one-line reason; callers degrade rather than stop.
- **Branch names carry the issue number** (`<issue>-<slug>`), so any session
  resolves its context from `git branch --show-current`.
- **Every mutating subcommand is idempotent.** Re-running `tasks`, `tick`,
  `stage`, or `comment` with the same inputs edits in place rather than
  creating a duplicate — proved in `tests/test_idempotency.sh`, not just
  claimed.

## Running the tests

```bash
bash tests/run
```

Tests are fully offline: a recording `gh` stub goes first on `PATH` and each
test runs inside a scratch git repository, so every test asserts the exact
`gh` invocations produced. `shellcheck` runs as part of the suite.

## Requirements

`bash` 3.2+, `git`, `jq`, `gh` 2.x authenticated. Board writes additionally
need the `project` OAuth scope: `gh auth refresh -s project`.

## Packaging

This is the CLI only. The plugin manifest, marketplace manifest, hooks
(`hooks.json`), skills, and the CLAUDE.md template that wire `ghtrack` into a
Claude Code plugin are not yet written — they belong to a second plan. There
is nothing here to install today; `scripts/ghtrack` is a standalone,
independently testable bash tool that a future plugin layer will call.
