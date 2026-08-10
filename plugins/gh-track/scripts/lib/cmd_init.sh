#!/usr/bin/env bash
# init — make a repository ready for tracking. Idempotent: safe to re-run
# after a plugin upgrade.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=SCRIPTDIR/board.sh
. "$GHT_LIB/board.sh"

cmd_init() {
  cfg_load

  local slug
  slug=$(repo_slug)
  cfg_write ".repo = \"$slug\""
  printf 'repo: %s\n' "$slug"

  labels_ensure
  printf 'labels: ensured\n'

  # state.json is scratch; config.json is committed alongside it.
  if ! git -C "$GHT_ROOT" check-ignore -q .claude/gh-track/state.json 2>/dev/null; then
    printf '%s\n' ".claude/gh-track/state.json" >>"$GHT_ROOT/.gitignore"
    printf 'gitignore: added .claude/gh-track/state.json\n'
  fi

  if board_ensure; then
    printf 'board: project %s ready\n' "$(cfg .project)"
  else
    printf 'board: skipped - labels remain the source of truth\n'
  fi

  printf 'init complete\n'
}
