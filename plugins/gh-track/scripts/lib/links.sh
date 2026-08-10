#!/usr/bin/env bash
# Publishing artifacts: make the commit visible on GitHub, then build URLs.
#
# Nothing here writes content. Superpowers already commits spec and plan
# files; link_push only makes an existing commit visible so GitHub can
# render it.

# link_push — push the current branch. Returns 1 on failure; never dies,
# because a tracking push must not abort development work.
link_push() {
  local branch
  branch=$(git branch --show-current 2>/dev/null || true)
  if [ -z "$branch" ]; then
    warn "detached HEAD; cannot push for artifact links"
    return 1
  fi
  if ! git remote get-url origin >/dev/null 2>&1; then
    warn "no origin remote; artifact links unavailable"
    return 1
  fi
  if ! git push -u origin "$branch" >/dev/null 2>&1; then
    warn "git push failed; artifact links may not resolve yet"
    return 1
  fi
  return 0
}

# link_sha PATH — short SHA of the last commit touching PATH.
link_sha() {
  git log -1 --format=%h -- "$1" 2>/dev/null || true
}

# link_urls PATH — line 1: branch-HEAD url, line 2: SHA-pinned url.
link_urls() {
  local path=$1 slug branch sha
  slug=$(repo_slug)
  branch=$(git branch --show-current 2>/dev/null || true)
  sha=$(link_sha "$path")

  if [ -n "$branch" ] && [ -n "$sha" ]; then
    printf 'https://github.com/%s/blob/%s/%s\n' "$slug" "$branch" "$path"
  else
    printf '\n'
  fi
  if [ -n "$sha" ]; then
    printf 'https://github.com/%s/blob/%s/%s\n' "$slug" "$sha" "$path"
  else
    printf '\n'
  fi
}

# link_default_url PATH — url on the default branch, for the Done rewrite.
link_default_url() {
  local slug base
  slug=$(repo_slug)
  base=$(gh repo view --repo "$slug" --json defaultBranchRef \
    --jq .defaultBranchRef.name 2>/dev/null || true)
  [ -n "$base" ] || base=main
  printf 'https://github.com/%s/blob/%s/%s\n' "$slug" "$base" "$1"
}
