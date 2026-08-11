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
| `new --kind K --title T [--size S] [--body-file F]` | Create an issue at `stage:backlog`, add it to the board; prints the number. |
| `resolve` | Print this branch's issue number. `--set N` records one manually. |
| `show N` | Issue state as compact `key=value` lines. |
| `stage N STAGE` | Swap the stage label, mirror board Status. |
| `size N s\|m\|l` | Swap the size label, mirror the board's Size field. Set at the plan checkpoint. |
| `body N --file F` | Replace the issue body. |
| `comment N --event E --file F` | Post or edit a marked checkpoint comment. |
| `link N --kind spec\|plan --path P` | Push the branch, print artifact URLs. |
| `tasks N --plan P` | Sync the body checklist from a plan's task headings. |
| `tick N --task K` | Mark checklist item K complete. |

## Design invariants

- **Labels are canonical; the board mirrors them.** A missing `project` scope
  or a Projects API failure costs the kanban view, not the truth.
  `scripts/lib/board.sh` contains no `die`: every function there warns and
  returns non-zero, so a board problem can never abort a label write.
- **Tracking failures never abort development.** Every failure is a non-zero
  exit with a one-line reason; callers degrade rather than stop.
- **Degrading means "report unknown", never "assume the empty answer".** A
  `gh` read whose result shapes a write must distinguish failure from
  emptiness, and a failed read refuses the write rather than issuing a
  partial one. An empty label list, an empty comment list and a failed
  lookup are three different things.
- **Branch names carry the issue number** (`<issue>-<slug>`), so any session
  resolves its context from `git branch --show-current`.
- **Every mutating subcommand is idempotent.** Re-running `tasks`, `tick`,
  `stage`, `size`, or `comment` with the same inputs edits in place rather than
  creating a duplicate — proved in `tests/test_idempotency.sh`, not just
  claimed.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (possibly degraded — check the `pushed=` / `board=` values) |
| 1 | General failure |
| 2 | Usage error: bad or missing argument, unknown stage/kind/event, non-numeric issue number, a `--path` outside the repository |
| 3 | The issue for this workspace could not be resolved |
| 4 | The plan file had no parseable task headings |
| 5 | The requested checklist item does not exist |
| 6 | A `gh` read that shapes a write failed, so the write was refused; nothing was changed |

### Output conventions

Three conventions, chosen by what the caller does with the output:

**Single-value accessors print a bare value, no key** — `resolve`, `new`,
`--version`. They exist to be captured directly:

```bash
issue=$(ghtrack resolve) || exit 0     # empty stdout and exit 3 if unresolvable
number=$(ghtrack new --kind feature --title "...")
```

This is deliberate, and it is the analogue of `git rev-parse`. Do not "make
them consistent" with the multi-field commands — a `key=value` line would
break every call site, including the plugin's hook scripts.

**Multi-field read commands print `key=value` lines** — `show`, `link`,
`doctor`, `init`. One per line, values unquoted and possibly empty. This is
the machine-readable surface; parse these.

**Mutating commands print a one-line human confirmation** — `stage`, `size`,
`body`, `comment`, `tasks`, `tick`. Do not parse the prose; read state back
with `show`.

### Known limitations

- Blob URLs take their host from `origin`'s URL (falling back to
  `github.com`), so GitHub Enterprise Server works, but a repository with no
  `origin` remote on a GHES install would get `github.com` links.
- Boards need a `Size` single-select field added by hand for `size` to mirror
  anything — nothing here creates one and `gh project create` does not. When
  it is missing, `size` still sets the label and says so. (`board_ids`
  re-reads the board's fields once when the cached Size id is absent, so a
  field added in the UI is picked up on the next `size` run without clearing
  any cache.)
- `link` emits `default_url=` (the default-branch URL that survives the work
  branch being deleted on merge), but nothing rewrites an issue body to use
  it yet — that is the Done checkpoint's job, and it belongs to the
  lifecycle skill in a later plan.

## Running the tests

```bash
bash tests/run
```

Tests are fully offline: a recording `gh` stub goes first on `PATH` and each
test runs inside a scratch git repository, so every test asserts the exact
`gh` invocations produced. `shellcheck` runs as part of the suite, over the
test files as well as the scripts.

The stub records any unmatched call whose *output* the code under test reads,
and the suite fails on it. Without that, a missing canned response is
indistinguishable from a legitimately empty API result — so it would silently
reroute a test onto its degraded path with every assertion still passing.

## Requirements

`bash` 3.2+, `git`, `jq`, `gh` 2.x authenticated. Board writes additionally
need the `project` OAuth scope: `gh auth refresh -s project`.

## Packaging

`plugins/gh-track/.claude-plugin/plugin.json` and the repository-root
`.claude-plugin/marketplace.json` make this plugin installable.
`hooks/hooks.json` registers two hooks: `artifact-changed.sh` on
`PostToolUse` (Write/Edit/NotebookEdit), which notices writes under
`docs/superpowers/**` and reminds the agent to checkpoint the tracking issue,
and `session-context.sh` on `SessionStart`, which resolves the current
branch's issue and surfaces its state at session start.
`skills/setting-up-github-tracking/SKILL.md` is the per-repository bootstrap
that runs `ghtrack doctor`/`init` and merges
`skills/tracking-work-in-github/references/claude-md-block.md` verbatim into
the project's `CLAUDE.md`. `skills/tracking-work-in-github/SKILL.md` is the
full intake-and-checkpoint lifecycle that the bootstrap's CLAUDE.md block and
both hooks point at: it documents the intake decision rule
(`references/intake.md`), the issue body and checkpoint comment templates
(`references/issue-anatomy.md`), the checkpoint procedure, and failure
handling. With both skills in place the plugin is functionally complete;
what remains is the end-to-end dogfood run (a later task in this plan).

The marketplace lists `gh-track` with `"source": "./plugins/gh-track"` — a
path relative to the marketplace manifest, since both live in this
repository. This was verified empirically with the `claude` CLI: `claude
plugin marketplace add ./` (run from the repo root; a bare `.` is rejected)
successfully added the marketplace from a **local path**, and `claude plugin
install gh-track@applied-ai-innovation` installed it with the correct
version and description; `claude plugin details gh-track` now reports a
component inventory of `Skills (2)` (`setting-up-github-tracking`,
`tracking-work-in-github`) and `Hooks (2)` (`PostToolUse`, `SessionStart`),
with zero agents and MCP/LSP servers. The relative form works because the
CLI resolves `source` against the marketplace's own location, not against
the process's working directory — no fallback to the `git-subdir` form was
needed. Adding the marketplace from the GitHub remote (`owner/repo`) would
only see pushed commits, so local-path verification is what proves a
manifest correct before a branch merges.
