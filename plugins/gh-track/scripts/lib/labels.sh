#!/usr/bin/env bash
# Labels are the canonical stage store: they work with the `repo` scope
# alone, so tracking survives a missing `project` scope with only the
# kanban view lost.

GHT_STAGES="backlog spec triage planned debugging building review done"
GHT_KINDS="feature bug chore"
GHT_SIZES="s m l"

stage_valid() {
  case " $GHT_STAGES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

kind_valid() {
  case " $GHT_KINDS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

size_valid() {
  case " $GHT_SIZES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

stage_to_status() {
  case $1 in
    backlog) printf 'Backlog' ;;
    spec|triage|planned) printf 'Todo' ;;
    building|debugging) printf 'Doing' ;;
    review) printf 'Review' ;;
    done) printf 'Done' ;;
    *) die "unknown stage: $1" 2 ;;
  esac
}

# size_to_field SIZE — the board's Size option name for a size:* label.
#
# A literal table rather than an upcasing trick: bash 3.2 has no
# case-converting parameter expansion, and the board's option names are the
# project's to choose, not a mechanical transform of the label.
size_to_field() {
  case $1 in
    s) printf 'S' ;;
    m) printf 'M' ;;
    l) printf 'L' ;;
    *) die "unknown size: $1" 2 ;;
  esac
}

# Set by labels_ensure so callers can report how bad a partial failure was.
GHT_LABELS_TOTAL=0
GHT_LABELS_FAILED=0

# label_create NAME COLOR DESCRIPTION — one label, counting the outcome.
#
# --force makes "already exists" a non-error, which is the whole point of
# re-runnable setup. It does NOT make an auth or permission failure a
# non-error, so failures are counted rather than discarded: a token without
# issue-write permission used to earn a clean bill of health here.
label_create() {
  GHT_LABELS_TOTAL=$((GHT_LABELS_TOTAL + 1))
  gh label create "$1" --force --color "$2" --description "$3" \
    --repo "$GHT_SLUG" >/dev/null 2>&1 \
    || GHT_LABELS_FAILED=$((GHT_LABELS_FAILED + 1))
}

# labels_ensure — create every label gh-track relies on. Returns non-zero if
# any creation failed, with the counts in GHT_LABELS_TOTAL/GHT_LABELS_FAILED.
labels_ensure() {
  local s
  GHT_LABELS_TOTAL=0
  GHT_LABELS_FAILED=0
  for s in $GHT_STAGES; do
    label_create "stage:$s" BFD4F2 "gh-track lifecycle stage"
  done
  for s in $GHT_KINDS; do
    label_create "kind:$s" D4C5F9 "gh-track work kind"
  done
  for s in $GHT_SIZES; do
    label_create "size:$s" FEF2C0 "gh-track scope estimate"
  done
  label_create "parallel-safe" C2E0C6 "gh-track: safe to run alongside siblings"
  label_create "blocked" E11D21 "gh-track: blocked, needs a decision"
  [ "$GHT_LABELS_FAILED" -eq 0 ]
}

# issue_labels N — one label name per line; non-zero if the READ failed.
#
# "The read failed" and "the issue has no labels" must not be the same
# answer: this result drives stage_set's --remove-label list, and an empty
# list silently turns a label SWAP into a label ADD, leaving two stage:*
# labels on the issue. gh exits non-zero on a failed read, so propagate it.
issue_labels() {
  gh issue view "$1" --repo "$GHT_SLUG" --json labels \
    --jq '.labels[].name' 2>/dev/null \
    || { warn "cannot read labels for issue #$1"; return 1; }
}

issue_stage() {
  issue_labels "$1" | sed -n 's/^stage://p' | head -1
}

# stage_set N STAGE — swap the stage label in one edit, then mirror the
# board if board support is loaded.
stage_set() {
  local issue=$1 want=$2
  stage_valid "$want" || die "unknown stage: $want" 2

  # Refuse the write when the read that shapes it failed. A partial edit
  # here corrupts the canonical store the whole labels-over-board design
  # rests on, and it would do so while printing success.
  local args="" s current
  current=$(issue_labels "$issue") \
    || die "cannot read current labels for issue #$issue; refusing to change stage (no write performed)" 6
  for s in $GHT_STAGES; do
    if [ "$s" != "$want" ] && printf '%s\n' "$current" | grep -qx "stage:$s"; then
      args="$args --remove-label stage:$s"
    fi
  done

  # shellcheck disable=SC2086 # args is a deliberately word-split flag list
  gh issue edit "$issue" --repo "$GHT_SLUG" \
    --add-label "stage:$want" $args >/dev/null

  # Mirror the board only when one is configured. Running label-only is a
  # chosen configuration, not a failure, so it must not warn twice on every
  # single stage transition forever.
  if [ -n "$(cfg .project)" ] && type board_status_set >/dev/null 2>&1; then
    board_status_set "$issue" "$(stage_to_status "$want")" || \
      warn "board Status not updated; labels are still correct"
  fi
}

# size_set N SIZE — swap the size label in one edit, then mirror the board.
#
# Size is set at the plan checkpoint, not at intake, so this has to work on
# an issue that already exists and may already carry a different size. Same
# discipline as stage_set: one edit, only size:* touched, and a read failure
# refuses the write rather than turning the SWAP into an ADD.
size_set() {
  local issue=$1 want=$2
  size_valid "$want" || die "unknown size: $want (one of: $GHT_SIZES)" 2

  local args="" s current
  current=$(issue_labels "$issue") \
    || die "cannot read current labels for issue #$issue; refusing to change size (no write performed)" 6
  for s in $GHT_SIZES; do
    if [ "$s" != "$want" ] && printf '%s\n' "$current" | grep -qx "size:$s"; then
      args="$args --remove-label size:$s"
    fi
  done

  # shellcheck disable=SC2086 # args is a deliberately word-split flag list
  gh issue edit "$issue" --repo "$GHT_SLUG" \
    --add-label "size:$want" $args >/dev/null

  # The size:* label and the board's Size field are written together, and
  # the label is the one that counts: a board failure is a warning.
  if [ -n "$(cfg .project)" ] && type board_size_set >/dev/null 2>&1; then
    board_size_set "$issue" "$(size_to_field "$want")" || \
      warn "board Size not updated; labels are still correct"
  fi
}
