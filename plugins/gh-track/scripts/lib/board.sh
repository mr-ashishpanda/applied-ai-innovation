#!/usr/bin/env bash
# Project board writes — a mirror of the label state, never the source of
# truth. Every function warns and returns non-zero on failure so a board
# problem degrades the kanban view and nothing else.

BOARD_STATUSES="Backlog Todo Doing Review Done"

# Cap on items fetched per `gh project item-list` call. Named once so the
# --limit argument and the truncation check below can never drift apart.
BOARD_ITEM_LIMIT=500

board_has_scope() {
  gh auth status 2>&1 | grep -q "'project'"
}

# board_ids [force] — resolve and cache project/field/option ids into
# state.json. A non-empty FORCE re-reads even when the cache looks complete.
#
# The short circuit requires every id needed to mirror STATUS, not just the
# project id. projectId is persisted before `field-list` runs, so gating on
# it alone meant one transient field-list failure cached a half-built entry
# that no later run ever retried: the board stayed degraded forever, and the
# warning blamed the project's field configuration rather than a cache file
# the user does not know exists.
#
# sizeFieldId is deliberately NOT part of that gate. Most boards genuinely
# have no Size field -- nothing here creates one, and `gh project create`
# does not -- so gating on it would re-run `field-list` on every single
# stage transition forever. Instead the one caller that needs it
# (board_size_set) asks for a forced re-read when it finds it missing, which
# costs one extra call at plan-checkpoint frequency rather than on every
# operation.
board_ids() {
  local force=${1:-}
  local cached_pid cached_fid cached_opts
  cached_pid=$(state_get '.board.projectId')
  cached_fid=$(state_get '.board.statusFieldId')
  cached_opts=$(state_get '.board.statusOptions')
  if [ -z "$force" ] && [ -n "$cached_pid" ] && [ -n "$cached_fid" ] \
     && [ -n "$cached_opts" ] && [ "$cached_opts" != "{}" ]; then
    return 0
  fi

  board_has_scope || {
    warn "missing 'project' scope; board writes skipped (fix: gh auth refresh -s project)"
    return 1
  }

  local proj owner
  proj=$(cfg .project)
  owner=$(cfg .projectOwner)
  [ -n "$owner" ] || owner=$(repo_owner)
  [ -n "$proj" ] || { warn "no project configured; run: ghtrack init"; return 1; }

  local pid
  pid=$(gh project view "$proj" --owner "$owner" --format json --jq .id 2>/dev/null || true)
  [ -n "$pid" ] || { warn "cannot read project $proj for owner $owner"; return 1; }
  state_set ".board.projectId = \"$pid\""

  local fields
  fields=$(gh project field-list "$proj" --owner "$owner" --format json 2>/dev/null || true)
  [ -n "$fields" ] || { warn "cannot list fields for project $proj"; return 1; }

  local statusname sizename sfid zfid
  statusname=$(cfg .board.statusField)
  sizename=$(cfg .board.sizeField)

  sfid=$(printf '%s' "$fields" | jq -r --arg n "$statusname" \
    '.fields[] | select(.name == $n) | .id // empty' 2>/dev/null)
  [ -n "$sfid" ] || { warn "project $proj has no '$statusname' field"; return 1; }
  state_set ".board.statusFieldId = \"$sfid\""

  zfid=$(printf '%s' "$fields" | jq -r --arg n "$sizename" \
    '.fields[] | select(.name == $n) | .id // empty' 2>/dev/null)
  [ -n "$zfid" ] && state_set ".board.sizeFieldId = \"$zfid\""

  local opts
  opts=$(printf '%s' "$fields" | jq -c --arg n "$statusname" \
    '[.fields[] | select(.name == $n) | .options[]? | {name, id}]' 2>/dev/null)
  state_set ".board.statusOptions = ($(printf '%s' "$opts" | jq 'map({(.name): .id}) | add // {}' 2>/dev/null))"

  local zopts
  zopts=$(printf '%s' "$fields" | jq -c --arg n "$sizename" \
    '[.fields[] | select(.name == $n) | .options[]? | {name, id}]' 2>/dev/null)
  state_set ".board.sizeOptions = ($(printf '%s' "$zopts" | jq 'map({(.name): .id}) | add // {}' 2>/dev/null))"

  return 0
}

# board_item_id N — project item id for issue N, adding it if absent.
#
# `gh project item-list` applies no state filter: it returns every item on
# the board, Done and closed included, so a long-lived board fills the
# --limit cap over time even if open-issue count stays modest. We do NOT
# filter the query (e.g. `is:open`) to dodge that: board_status_set runs on
# the *last* transition of an issue's life too (moving it to Done), so an
# open-only filter would make the lookup miss precisely the issues most
# likely to already be on the board, turning a rare truncation edge case
# into a guaranteed duplicate on every completion. Instead: if the issue
# isn't found AND the returned count is at the cap, the list may have been
# truncated before reaching it, so absence is unproven — warn and refuse to
# guess rather than risk creating a duplicate card.
board_item_id() {
  local issue=$1 proj owner items id count
  proj=$(cfg .project)
  owner=$(cfg .projectOwner)
  [ -n "$owner" ] || owner=$(repo_owner)

  items=$(gh project item-list "$proj" --owner "$owner" --format json \
    --limit "$BOARD_ITEM_LIMIT" 2>/dev/null) \
    || { warn "cannot list project items"; return 1; }

  id=$(printf '%s' "$items" | jq -r --argjson n "$issue" \
    '.items[] | select(.content.number == $n) | .id // empty' 2>/dev/null | head -1)
  if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi

  count=$(printf '%s' "$items" | jq -r '.items | length' 2>/dev/null || true)
  if [ -n "$count" ] && [ "$count" -ge "$BOARD_ITEM_LIMIT" ]; then
    warn "project item-list hit the $BOARD_ITEM_LIMIT-item cap; cannot confirm issue #$issue is absent from the board"
    return 1
  fi

  local url
  url="https://$(gh_host)/$GHT_SLUG/issues/$issue"
  id=$(gh project item-add "$proj" --owner "$owner" --url "$url" \
    --format json --jq .id 2>/dev/null || true)
  [ -n "$id" ] || { warn "cannot add issue #$issue to project $proj"; return 1; }
  printf '%s' "$id"
}

board_status_set() {
  local issue=$1 status=$2
  case " $BOARD_STATUSES " in
    *" $status "*) : ;;
    *) warn "unknown board status: $status"; return 1 ;;
  esac

  board_ids || return 1

  local pid fid oid item
  pid=$(state_get '.board.projectId')
  fid=$(state_get '.board.statusFieldId')
  oid=$(state_get ".board.statusOptions[\"$status\"]")
  [ -n "$oid" ] || { warn "project has no '$status' Status option"; return 1; }

  item=$(board_item_id "$issue") || return 1

  gh project item-edit --id "$item" --project-id "$pid" \
    --field-id "$fid" --single-select-option-id "$oid" >/dev/null 2>&1 \
    || { warn "board item-edit failed for #$issue"; return 1; }
  return 0
}

board_size_set() {
  local issue=$1 size=$2
  board_ids || return 1

  local pid fid oid item sizename
  fid=$(state_get '.board.sizeFieldId')

  # A missing Size field id is far more likely to be a stale cache than a
  # board without the field. Nothing in gh-track creates a Size field and a
  # freshly created project has only Status, so the field can ONLY appear
  # after a user adds it in the UI -- which is necessarily after init/stage
  # cached the Status ids. Without this one forced re-read the short circuit
  # was satisfied forever: the mirror never ran again, and the warning
  # blamed a board that by then had the field.
  if [ -z "$fid" ]; then
    board_ids force || return 1
    fid=$(state_get '.board.sizeFieldId')
  fi

  sizename=$(cfg .board.sizeField)
  [ -n "$fid" ] || {
    warn "project has no '$sizename' field; add it on the board to mirror sizes (the size label is set either way)"
    return 1
  }

  pid=$(state_get '.board.projectId')
  oid=$(state_get ".board.sizeOptions[\"$size\"]")
  [ -n "$oid" ] || { warn "project has no '$size' Size option"; return 1; }
  item=$(board_item_id "$issue") || return 1
  gh project item-edit --id "$item" --project-id "$pid" \
    --field-id "$fid" --single-select-option-id "$oid" >/dev/null 2>&1 \
    || { warn "board size edit failed for #$issue"; return 1; }
  return 0
}

# board_status_color STATUS — a fixed, purely cosmetic color per column.
board_status_color() {
  case $1 in
    Backlog) printf 'GRAY' ;;
    Todo) printf 'BLUE' ;;
    Doing) printf 'YELLOW' ;;
    Review) printf 'ORANGE' ;;
    Done) printf 'GREEN' ;;
    *) printf 'GRAY' ;;
  esac
}

# board_align_new_project_status PROJ OWNER — rewrite the Status field's
# options to exactly BOARD_STATUSES.
#
# `gh project create` only ever creates GitHub's own defaults (Todo, In
# Progress, Done), which don't match BOARD_STATUSES (Backlog, Todo, Doing,
# Review, Done) -- so board_status_set warns "no 'Backlog' Status option"
# on the very first ghtrack new against a fresh board, forever, since
# board_ids caches whatever options it finds on first read. This runs ONCE,
# only on a project THIS call just created (never against a pre-existing,
# possibly user-curated board -- the board is a mirror we own only at
# creation time), before board_ids caches anything.
board_align_new_project_status() {
  local proj=$1 owner=$2 statusname fields sfid
  statusname=$(cfg .board.statusField)

  fields=$(gh project field-list "$proj" --owner "$owner" --format json 2>/dev/null || true)
  [ -n "$fields" ] || { warn "cannot list fields for project $proj; Status options left at GitHub's defaults"; return 1; }

  sfid=$(printf '%s' "$fields" | jq -r --arg n "$statusname" \
    '.fields[] | select(.name == $n) | .id // empty' 2>/dev/null)
  [ -n "$sfid" ] || { warn "project $proj has no '$statusname' field; Status options left at GitHub's defaults"; return 1; }

  local opts s color first=1
  opts=""
  for s in $BOARD_STATUSES; do
    color=$(board_status_color "$s")
    if [ "$first" = 1 ]; then first=0; else opts="$opts, "; fi
    opts="$opts{name: \"$s\", color: $color, description: \"\"}"
  done

  gh api graphql -f query="
    mutation {
      updateProjectV2Field(input: {fieldId: \"$sfid\", singleSelectOptions: [$opts]}) {
        clientMutationId
      }
    }" >/dev/null 2>&1 \
    || { warn "cannot rewrite Status options for project $proj; left at GitHub's defaults"; return 1; }
  return 0
}

# board_ensure — find or create the repo's board, then cache its ids.
board_ensure() {
  board_has_scope || {
    warn "missing 'project' scope; skipping board setup (fix: gh auth refresh -s project)"
    return 1
  }

  local proj owner title
  proj=$(cfg .project)
  owner=$(repo_owner)
  title=$(repo_name)

  if [ -z "$proj" ]; then
    # The list drives a CREATE, so a failed list must not read as "no board
    # with this title": piped straight into jq, a `project list` that errored
    # produced the same empty answer as an empty account and fell through to
    # `project create`, giving a repo that already had a board a SECOND one
    # while reporting `init=complete`. Capture the listing, prove it parses,
    # and refuse the write otherwise. Warn and return 1 rather than aborting:
    # nothing in this file ever kills the process, so init simply reports the
    # board as not set up and labels remain the source of truth.
    local listing existing
    listing=$(gh project list --owner "$owner" --format json 2>/dev/null) \
      || { warn "cannot list projects for owner $owner; not creating a board that may already exist"; return 1; }
    printf '%s' "$listing" | jq -e '.projects' >/dev/null 2>&1 \
      || { warn "unreadable project list for owner $owner; not creating a board that may already exist"; return 1; }
    existing=$(printf '%s' "$listing" \
      | jq -r --arg t "$title" '.projects[] | select(.title == $t) | .number // empty' 2>/dev/null \
      | head -1)
    if [ -n "$existing" ]; then
      proj=$existing
    else
      proj=$(gh project create --owner "$owner" --title "$title" \
        --format json --jq .number 2>/dev/null || true)
      [ -n "$proj" ] || { warn "cannot create project '$title'"; return 1; }
      board_align_new_project_status "$proj" "$owner" || true
    fi
    cfg_write ".project = $proj"
  fi

  board_ids
}
