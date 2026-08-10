#!/usr/bin/env bash
# doctor — report environment readiness. Never mutates anything.
# Exits 0 when tracking can function at all (labels only counts as
# functioning); exits 1 only when gh is missing or unauthenticated.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"

cmd_doctor() {
  local problems=0

  if ! command -v gh >/dev/null 2>&1; then
    printf 'gh: NOT FOUND - install from https://cli.github.com\n'
    return 1
  fi
  printf 'gh: %s\n' "$(gh --version 2>/dev/null | head -1)"

  if ! gh auth status >/dev/null 2>&1; then
    printf 'auth: NOT AUTHENTICATED - run: gh auth login\n'
    return 1
  fi
  printf 'auth: ok\n'

  cfg_load
  printf 'repo: %s\n' "$(repo_slug)"

  if [ -f "$GHT_CONFIG" ]; then
    printf 'config: %s\n' "$GHT_CONFIG"
  else
    printf 'config: MISSING - run the setting-up-github-tracking skill\n'
    problems=$((problems + 1))
  fi

  # Project scope governs whether board writes can work at all.
  if gh auth status 2>&1 | grep -q "'project'"; then
    printf 'scope project: ok\n'
  else
    printf 'scope project: MISSING - board writes will be skipped; run: gh auth refresh -s project\n'
    problems=$((problems + 1))
  fi

  local proj
  proj=$(cfg .project)
  if [ -n "$proj" ]; then
    printf 'board: project %s\n' "$proj"
  else
    printf 'board: not configured - labels only\n'
  fi

  # Compatibility probe: configured artifact dirs vs what actually exists.
  local specdir plandir
  specdir=$(dirname "$(cfg .specGlob)")
  plandir=$(dirname "$(cfg .planGlob)")
  specdir=${specdir%/\*\*}
  plandir=${plandir%/\*\*}
  if [ -d "$GHT_ROOT/$specdir" ] || [ -d "$GHT_ROOT/$plandir" ]; then
    printf 'artifacts: ok (%s, %s)\n' "$specdir" "$plandir"
  elif [ -d "$GHT_ROOT/docs/superpowers" ]; then
    printf 'artifacts: MISMATCH - docs/superpowers exists but %s and %s do not.\n' "$specdir" "$plandir"
    printf 'artifacts: superpowers conventions may have changed; update globs in %s\n' "$GHT_CONFIG"
    problems=$((problems + 1))
  else
    printf 'artifacts: none yet (no docs/superpowers directory)\n'
  fi

  if [ "$problems" -gt 0 ]; then
    printf '\n%d item(s) need attention; tracking still functions in degraded mode.\n' "$problems"
  fi
  return 0
}
