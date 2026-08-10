#!/usr/bin/env bash
# Issue body as text sections. The two pure-text functions
# (section_get, section_replace) never touch gh, which is what makes the
# body logic cheap to test.

body_get() {
  gh issue view "$1" --json body --jq .body --repo "$(repo_slug)"
}

body_put() {
  gh issue edit "$1" --body-file "$2" --repo "$(repo_slug)" >/dev/null
}

# section_get BODY_FILE HEADING — content lines of `## HEADING…`, heading
# excluded. Empty output when the section is absent.
section_get() {
  awk -v h="$2" '
    index($0, "## " h) == 1 { inside = 1; next }
    /^## / { inside = 0 }
    inside { print }
  ' "$1"
}

# section_replace BODY_FILE HEADING CONTENT_FILE — new body on stdout.
# CONTENT_FILE must include its own `## Heading` line. An absent section is
# appended at the end so content is never silently dropped.
section_replace() {
  local body=$1 heading=$2 content=$3

  if ! awk -v h="$heading" 'index($0, "## " h) == 1 { found = 1 } END { exit !found }' "$body"; then
    cat "$body"
    printf '\n'
    cat "$content"
    return 0
  fi

  awk -v h="$heading" -v cf="$content" '
    index($0, "## " h) == 1 {
      while ((getline line < cf) > 0) print line
      close(cf)
      skipping = 1
      next
    }
    skipping && /^## / { skipping = 0 }
    !skipping { print }
  ' "$body"
}
