#!/usr/bin/env bash
# Issue body as text sections. The two pure-text functions
# (section_get, section_replace) never touch gh, which is what makes the
# body logic cheap to test.

# body_get N — the issue body, normalised to LF.
#
# GitHub's web form saves bodies with CRLF, and everything downstream
# (section_get, section_replace, the checklist greps) is line-anchored. Left
# in, the CR survives into the body written BACK to GitHub, so a single web
# edit leaves the issue with permanently mixed line endings and every
# exact-match heading comparison failing. This is the one point every body
# read passes through, so it is the one place worth normalising.
body_get() {
  gh issue view "$1" --repo "$GHT_SLUG" --json body --jq .body | tr -d '\r'
}

body_put() {
  gh issue edit "$1" --repo "$GHT_SLUG" --body-file "$2" >/dev/null
}

# The awk predicate every section function matches headings with.
#
# Matching must tolerate the `- N/M` counter that `tasks` writes into the
# Tasks heading, so it cannot be a plain string equality -- but it must NOT
# be an unanchored prefix either. `index($0, "## " h) == 1` also matches a
# sibling section a human plausibly adds ("## Tasks Notes",
# "## Tasks deferred"), which section_replace then DELETES and section_get
# returns as part of the union. So: the exact heading, or the heading
# followed by " (" -- which admits the counter and nothing else.
BODY_AWK_IS_HEADING='
  function is_heading(line, h) {
    return line == "## " h || index(line, "## " h " (") == 1
  }
'

# section_get BODY_FILE HEADING — content lines of `## HEADING…`, heading
# excluded. Empty output when the section is absent. Only the FIRST matching
# section is returned, so a duplicate heading cannot widen the result.
section_get() {
  awk -v h="$2" "$BODY_AWK_IS_HEADING"'
    !taken && is_heading($0, h) { inside = 1; taken = 1; next }
    /^## / { inside = 0 }
    inside { print }
  ' "$1"
}

# section_replace BODY_FILE HEADING CONTENT_FILE — new body on stdout.
# CONTENT_FILE must include its own `## Heading` line. An absent section is
# appended at the end so content is never silently dropped. Only the FIRST
# matching section is replaced.
section_replace() {
  local body=$1 heading=$2 content=$3

  if ! awk -v h="$heading" "$BODY_AWK_IS_HEADING"'
        is_heading($0, h) { found = 1 }
        END { exit !found }
      ' "$body"; then
    cat "$body"
    printf '\n'
    cat "$content"
    return 0
  fi

  awk -v h="$heading" -v cf="$content" "$BODY_AWK_IS_HEADING"'
    !replaced && is_heading($0, h) {
      while ((getline line < cf) > 0) print line
      close(cf)
      skipping = 1
      replaced = 1
      next
    }
    skipping && /^## / { skipping = 0 }
    !skipping { print }
  ' "$body"
}
