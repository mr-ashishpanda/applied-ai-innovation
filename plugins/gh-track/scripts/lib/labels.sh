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

labels_ensure() {
  local slug s
  slug=$(repo_slug)
  for s in $GHT_STAGES; do
    gh label create "stage:$s" --force --color BFD4F2 \
      --description "gh-track lifecycle stage" --repo "$slug" >/dev/null 2>&1 || true
  done
  for s in $GHT_KINDS; do
    gh label create "kind:$s" --force --color D4C5F9 \
      --description "gh-track work kind" --repo "$slug" >/dev/null 2>&1 || true
  done
  for s in $GHT_SIZES; do
    gh label create "size:$s" --force --color FEF2C0 \
      --description "gh-track scope estimate" --repo "$slug" >/dev/null 2>&1 || true
  done
  gh label create "parallel-safe" --force --color C2E0C6 \
    --description "gh-track: safe to run alongside siblings" --repo "$slug" >/dev/null 2>&1 || true
  gh label create "blocked" --force --color E11D21 \
    --description "gh-track: blocked, needs a decision" --repo "$slug" >/dev/null 2>&1 || true
}

# issue_labels N — one label name per line.
issue_labels() {
  gh issue view "$1" --repo "$(repo_slug)" --json labels \
    --jq '.labels[].name' 2>/dev/null || true
}

issue_stage() {
  issue_labels "$1" | sed -n 's/^stage://p' | head -1
}

# stage_set N STAGE — swap the stage label in one edit, then mirror the
# board if board support is loaded.
stage_set() {
  local issue=$1 want=$2
  stage_valid "$want" || die "unknown stage: $want" 2

  local args="" s current
  current=$(issue_labels "$issue")
  for s in $GHT_STAGES; do
    if [ "$s" != "$want" ] && printf '%s\n' "$current" | grep -qx "stage:$s"; then
      args="$args --remove-label stage:$s"
    fi
  done

  # shellcheck disable=SC2086 # args is a deliberately word-split flag list
  gh issue edit "$issue" --repo "$(repo_slug)" \
    --add-label "stage:$want" $args >/dev/null

  if command -v board_status_set >/dev/null 2>&1 \
     || type board_status_set >/dev/null 2>&1; then
    board_status_set "$issue" "$(stage_to_status "$want")" || \
      warn "board Status not updated; labels are still correct"
  fi
}
