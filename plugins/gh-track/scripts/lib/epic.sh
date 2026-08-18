#!/usr/bin/env bash
# Epic-child numbering: "<epic-number>.<next>" titles, matching the
# convention already in use for issues like "3.9 contracts: ...",
# "3.10 flow-sdk: ...". The epic ISSUE's own number (e.g. #11) is unrelated
# to the short numeric prefix its children carry (3) -- that number lives
# only in the epic's own title text ("Epic 3: Conversation runtime"), since
# no `epic:N` label or other structured field exists anywhere in this
# system. Title text is therefore the one source of truth both functions
# below read, and it is what stays authoritative even for an epic whose
# existing children were never linked as GitHub-native sub-issues.

# epic_short_number EPIC — the short numeric prefix EPIC's title declares,
# or die if EPIC's title doesn't match "Epic N: ...".
epic_short_number() {
  local epic=$1 title num
  title=$(gh issue view "$epic" --repo "$GHT_SLUG" --json title --jq .title 2>/dev/null) \
    || die "cannot read issue #$epic; --epic requires an existing epic issue" 6
  case $title in
    'Epic '[0-9]*': '*)
      num=${title#Epic }
      num=${num%%:*}
      ;;
    *) die "issue #$epic's title ('$title') doesn't look like an epic ('Epic N: ...')" 2 ;;
  esac
  printf '%s' "$num"
}

# epic_next_child_number EPICNUM — one past the highest "<EPICNUM>.<N>"
# title found anywhere in the repo (open or closed).
#
# Scans TITLE TEXT rather than native sub-issue links: an epic's existing
# children may predate this tool creating sub-issue links at all (verified
# live -- issue #11 had zero native sub-issues despite seven documented
# prose children), so counting only linked sub-issues would silently
# under-number against them. Title text is what this numbering scheme has
# always used as its source of truth, so it stays authoritative here too,
# independent of how completely any given epic's children are linked.
epic_next_child_number() {
  local epicnum=$1 max=0 n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case $n in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$n" -gt "$max" ] && max=$n
  done < <(gh issue list --repo "$GHT_SLUG" --state all --limit 500 \
    --json title --jq '.[].title' 2>/dev/null \
    | sed -n "s/^${epicnum}\.\([0-9][0-9]*\)[[:space:]].*/\1/p")
  printf '%s' "$((max + 1))"
}
