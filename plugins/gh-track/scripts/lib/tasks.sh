#!/usr/bin/env bash
# Plan task headings <-> issue body checklist. Pure text, no gh calls.

TASKS_HEADING_PREFIX="## Tasks (from plan - "

# tasks_extract PLAN_FILE — one `- [ ] N. Title` line per task heading.
tasks_extract() {
  local plan=$1 pattern
  pattern=$(cfg .taskHeadingPattern)
  [ -f "$plan" ] || die "no such plan file: $plan" 2

  local found=0
  while IFS= read -r line; do
    if [[ $line =~ $pattern ]]; then
      local num title
      num=${BASH_REMATCH[1]}
      # Title is everything after the colon that follows the number.
      title=${line#*"$num":}
      title=${title# }
      printf -- '- [ ] %s. %s\n' "$num" "$title"
      found=1
    fi
  done <"$plan"

  [ "$found" = 1 ] || die "no task headings matched pattern [$pattern] in $plan" 4
}

# tasks_merge OLD NEW — NEW's titles and ordering win; OLD's ticks survive.
tasks_merge() {
  local old=$1 new=$2

  # The classic `FNR == NR { ...; next }` two-file idiom breaks when OLD has
  # zero lines (true on every issue's FIRST tasks sync, since there is no
  # existing checklist yet): with nothing ever read from OLD, NR and FNR
  # track NEW's lines in lockstep from record 1, so FNR == NR is true for
  # EVERY line of NEW too -- the `next` meant for OLD's lines fires on all
  # of NEW's instead, and the whole checklist comes out empty (0/0), exit 0,
  # no error. This is not one awk's quirk; it's inherent to the idiom.
  # There is nothing to merge from an empty OLD, so skip the awk entirely.
  if [ ! -s "$old" ]; then
    cat "$new"
    return 0
  fi

  awk '
    FNR == NR {
      if ($0 ~ /^- \[x\] /) {
        line = $0
        sub(/^- \[x\] /, "", line)
        n = line
        sub(/\..*$/, "", n)
        ticked[n] = 1
      }
      next
    }
    {
      line = $0
      num = line
      sub(/^- \[[ x]\] /, "", num)
      sub(/\..*$/, "", num)
      if (num in ticked) sub(/^- \[ \] /, "- [x] ", $0)
      print
    }
  ' "$old" "$new"
}

# tasks_render LINES_FILE — full section with a recomputed counter.
tasks_render() {
  local lines=$1 done_count total
  done_count=$(grep -c '^- \[x\] ' "$lines" || true)
  total=$(grep -c '^- \[[ x]\] ' "$lines" || true)
  printf '%s%s/%s)\n' "$TASKS_HEADING_PREFIX" "${done_count:-0}" "${total:-0}"
  cat "$lines"
}

# tasks_tick LINES_FILE K — mark item K complete.
#
# K is interpolated into a grep pattern and a sed replacement, so it is
# validated here as well as at the subcommand boundary: this is the library
# entry point, and an unvalidated K rewrites every item on the checklist.
tasks_tick() {
  local lines=$1 k=$2
  require_number "$k" "tick --task"
  grep -q "^- \[[ x]\] $k\. " "$lines" || die "no checklist item numbered $k" 5
  sed "s/^- \[ \] $k\. /- [x] $k. /" "$lines"
}
