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
#
# -C "$GHT_ROOT" because PATH is repo-root-relative (link_root_relative
# guarantees it) while git resolves a pathspec against the CWD: without it,
# the same path that builds a correct URL would report no commit whenever
# the caller runs from a subdirectory.
link_sha() {
  git -C "$GHT_ROOT" log -1 --format=%h -- "$1" 2>/dev/null || true
}

# link_root_relative PATH — PATH as a repo-root-relative path, or non-zero.
#
# The URL these paths land in is a permanent record in an issue comment, so
# a path that is merely resolvable from the caller's cwd is not good enough:
# interpolated verbatim it produced confident 404s (`--path s.md` run from
# the spec directory), doubled slashes (absolute paths) and `/./` URLs.
# Resolve it to one physical location, then require it to live inside the
# repository. A repo-root-relative reading wins when both readings exist,
# since that is the form the URLs are built from.
link_root_relative() {
  local p=$1 dir base abs root
  if [ -f "$GHT_ROOT/$p" ]; then
    dir=$(dirname "$GHT_ROOT/$p")
  elif [ -f "$p" ]; then
    dir=$(dirname "$p")
  else
    warn "no such file: $p"
    return 1
  fi
  base=$(basename "$p")
  abs=$(cd "$dir" 2>/dev/null && pwd -P)/$base || return 1
  root=$(cd "$GHT_ROOT" && pwd -P)
  case $abs in
    "$root"/*) printf '%s' "${abs#"$root"/}" ;;
    *) warn "path is outside the repository: $p"; return 1 ;;
  esac
}

# link_url_encode PATH — encode the characters that break a blob URL. `#`
# would truncate the URL at a fragment and a space would end it entirely;
# `%` goes first so the encoding cannot double-encode itself.
link_url_encode() {
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g'
}

# link_blob_url REF PATH — one blob URL. Host comes from origin so GitHub
# Enterprise Server installs are not sent to github.com.
link_blob_url() {
  printf 'https://%s/%s/blob/%s/%s\n' "$(gh_host)" "$GHT_SLUG" "$1" "$(link_url_encode "$2")"
}

# link_urls PATH — line 1: branch-HEAD url, line 2: SHA-pinned url, line 3:
# the short SHA both were built from.
#
# Line 3 exists so callers that print the sha do not have to run `git log`
# a second time for the value this function already computed.
link_urls() {
  local path=$1 branch sha
  branch=$(git branch --show-current 2>/dev/null || true)
  sha=$(link_sha "$path")

  if [ -n "$branch" ] && [ -n "$sha" ]; then
    link_blob_url "$branch" "$path"
  else
    printf '\n'
  fi
  if [ -n "$sha" ]; then
    link_blob_url "$sha" "$path"
  else
    printf '\n'
  fi
  printf '%s\n' "$sha"
}

# link_default_url PATH — url on the default branch, for the Done rewrite.
link_default_url() {
  local base
  base=$(gh repo view --repo "$GHT_SLUG" --json defaultBranchRef \
    --jq .defaultBranchRef.name 2>/dev/null || true)
  [ -n "$base" ] || base=main
  link_blob_url "$base" "$1"
}
