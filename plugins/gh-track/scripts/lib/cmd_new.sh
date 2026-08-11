#!/usr/bin/env bash
# new — create an issue at stage:backlog. Prints only the issue number so
# callers can capture it directly.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=SCRIPTDIR/board.sh
. "$GHT_LIB/board.sh"

cmd_new() {
  cfg_load
  slug_require
  local kind="" title="" bodyfile="" size=""
  while [ $# -gt 0 ]; do
    case $1 in
      --kind) kind=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --body-file) bodyfile=${2:-}; shift 2 ;;
      --size) size=${2:-}; shift 2 ;;
      *) die "new: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$kind" ] || die "new requires --kind feature|bug|chore" 2
  kind_valid "$kind" || die "new --kind must be one of: $GHT_KINDS" 2
  [ -n "$title" ] || die "new requires --title TITLE" 2

  local args="--label stage:backlog --label kind:$kind"
  if [ -n "$size" ]; then
    case " $GHT_SIZES " in
      *" $size "*) args="$args --label size:$size" ;;
      *) die "new --size must be one of: $GHT_SIZES" 2 ;;
    esac
  fi

  local url
  if [ -n "$bodyfile" ]; then
    [ -f "$bodyfile" ] || die "no such file: $bodyfile" 2
    # shellcheck disable=SC2086 # args is a deliberately word-split flag list
    url=$(gh issue create --repo "$GHT_SLUG" --title "$title" \
      --body-file "$bodyfile" $args)
  else
    # shellcheck disable=SC2086 # args is a deliberately word-split flag list
    url=$(gh issue create --repo "$GHT_SLUG" --title "$title" \
      --body "Captured by gh-track. No spec yet." $args)
  fi

  # The parse now shapes a WRITE -- it is what the board card is built from --
  # so it must distinguish "no url" from a number, exactly as every other read
  # that drives a write on this branch does. `gh issue create` exiting
  # non-zero is already fatal under set -e; this closes the exit-0-with-empty-
  # stdout path, which used to print a blank line and now would put a card
  # pointing at `/issues/` on the real board.
  local number=${url##*/}
  case $number in
    ''|*[!0-9]*) die "issue create returned no issue url; refusing to touch the board (got: [$url])" 1 ;;
  esac

  # Print the number BEFORE touching the board. The issue exists either way,
  # and the number is this command's entire contract with its caller; a board
  # that is unreachable, unconfigured or out of scope must cost the kanban
  # card and nothing else. Status is set to Backlog to match the
  # stage:backlog label the issue was just created with, so the card lands in
  # the right column rather than the board's default -- capture-only intake
  # items are branchless and may never see a `stage` transition to place them.
  printf '%s\n' "$number"

  if [ -n "$(cfg .project)" ] && type board_status_set >/dev/null 2>&1; then
    board_status_set "$number" Backlog || \
      warn "issue #$number created but not added to the board; labels are still correct"
    # The size:* label and the board's Size field are written together, here
    # as in `size`. Sizing at intake is unusual (it belongs to the plan
    # checkpoint) but --size exists, so it must not leave the two disagreeing.
    if [ -n "$size" ]; then
      board_size_set "$number" "$(size_to_field "$size")" || \
        warn "board Size not updated for #$number; labels are still correct"
    fi
  fi
}
