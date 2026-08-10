#!/usr/bin/env bash
# init — make a repository ready for tracking. Idempotent: safe to re-run
# after a plugin upgrade.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=SCRIPTDIR/board.sh
. "$GHT_LIB/board.sh"

# init_gitignore — make sure state.json is ignored, without corrupting the
# file. `>>` on a .gitignore whose last line has no terminating newline
# glues the new entry onto it, which both breaks the user's last ignore rule
# and leaves state.json unignored -- and because check-ignore then still
# fails, re-running appended a SECOND broken line instead of repairing.
init_gitignore() {
  local gi="$GHT_ROOT/.gitignore"
  if git -C "$GHT_ROOT" check-ignore -q .claude/gh-track/state.json 2>/dev/null; then
    return 0
  fi
  if [ -s "$gi" ] && [ "$(tail -c1 "$gi" | wc -l | tr -d '[:space:]')" = "0" ]; then
    printf '\n' >>"$gi"
  fi
  printf '%s\n' ".claude/gh-track/state.json" >>"$gi"
  printf 'gitignore=added .claude/gh-track/state.json\n'
}

cmd_init() {
  cfg_load
  slug_require
  local problems=0

  cfg_write ".repo = \"$GHT_SLUG\""
  printf 'repo=%s\n' "$GHT_SLUG"

  # --force absorbs "already exists"; it does not absorb an auth or
  # permission failure, so a partial failure must be reported rather than
  # dressed up as "ensured". A token without issue-write permission used to
  # get a clean bill of health here and fail on every later stage/new.
  if labels_ensure; then
    printf 'labels=ensured (%d)\n' "$GHT_LABELS_TOTAL"
  else
    printf 'labels=FAILED %d of %d - check token permissions (needs repo issue write)\n' \
      "$GHT_LABELS_FAILED" "$GHT_LABELS_TOTAL"
    problems=$((problems + 1))
  fi

  # state.json is scratch; config.json is committed alongside it.
  init_gitignore

  if board_ensure; then
    printf 'board=project %s ready\n' "$(cfg .project)"
  else
    printf 'board=skipped - labels remain the source of truth\n'
  fi

  if [ "$problems" -gt 0 ]; then
    printf 'init=incomplete (%d problem(s))\n' "$problems"
    return 1
  fi
  printf 'init=complete\n'
}
