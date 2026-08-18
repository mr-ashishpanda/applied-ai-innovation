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
2. **Confirm the repository.** Show the user the `repo=` line from `doctor` and
   confirm it is the repository they want tracked. Never write to a repository
   the user has not confirmed.
3. **Handle a missing `project` scope.** If `doctor` reports
   `scope_project=MISSING - ...`, tell the user board writes will be skipped and
   that the fix is `gh auth refresh -s project`. Ask whether to proceed
   label-only or wait. Both are valid — labels are canonical.
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
`docs/superpowers/plans/` — `doctor` reports `artifacts=MISMATCH - ...` — ask where
they do live and set `specGlob` and `planGlob` in
`.claude/gh-track/config.json` accordingly. This is the designed adaptation
point for superpowers convention changes; do not edit skill files instead.

If the repo has more than one long-lived integration branch (e.g. `main` is
frozen and a `v2` branch is where active work actually lands), ask and set
`sharedBranches` in `.claude/gh-track/config.json` — an array including every
such branch, e.g. `["main", "v2"]`. `resolve` never uses its recorded-state
fallback on a shared branch, and `resolve --set` refuses to record one there,
precisely because a shared branch's checked-out content changes constantly as
unrelated work merges into it — a path-keyed pin recorded there once would
misattribute every future session that starts on it before a dedicated
per-task worktree exists. Defaults to `["main", "master"]` when unset.

## Do not

- Do not create issues here. This skill only prepares the repository.
- Do not run `git push`, open PRs, or modify branches.
- Do not hand-roll `gh` calls. Everything goes through `ghtrack`.
- Do not proceed past step 2 without the user confirming the repository.
