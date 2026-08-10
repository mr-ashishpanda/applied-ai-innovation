#!/usr/bin/env bash
# Project board writes — a mirror of the label state, never the source of
# truth. Every function warns and returns non-zero on failure so a board
# problem degrades the kanban view and nothing else.

BOARD_STATUSES="Backlog Todo Doing Review Done"

board_has_scope() {
  gh auth status 2>&1 | grep -q "'project'"
}

# board_ids — resolve and cache project/field/option ids into state.json.
board_ids() {
  local cached
  cached=$(state_get '.board.projectId')
  if [ -n "$cached" ]; then return 0; fi

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
    '.fields[] | select(.name == $n) | .id // empty')
  [ -n "$sfid" ] || { warn "project $proj has no '$statusname' field"; return 1; }
  state_set ".board.statusFieldId = \"$sfid\""

  zfid=$(printf '%s' "$fields" | jq -r --arg n "$sizename" \
    '.fields[] | select(.name == $n) | .id // empty')
  [ -n "$zfid" ] && state_set ".board.sizeFieldId = \"$zfid\""

  local opts
  opts=$(printf '%s' "$fields" | jq -c --arg n "$statusname" \
    '[.fields[] | select(.name == $n) | .options[]? | {name, id}]')
  state_set ".board.statusOptions = ($(printf '%s' "$opts" | jq 'map({(.name): .id}) | add // {}'))"

  local zopts
  zopts=$(printf '%s' "$fields" | jq -c --arg n "$sizename" \
    '[.fields[] | select(.name == $n) | .options[]? | {name, id}]')
  state_set ".board.sizeOptions = ($(printf '%s' "$zopts" | jq 'map({(.name): .id}) | add // {}'))"

  return 0
}

# board_item_id N — project item id for issue N, adding it if absent.
board_item_id() {
  local issue=$1 proj owner items id
  proj=$(cfg .project)
  owner=$(cfg .projectOwner)
  [ -n "$owner" ] || owner=$(repo_owner)

  items=$(gh project item-list "$proj" --owner "$owner" --format json --limit 500 2>/dev/null) \
    || { warn "cannot list project items"; return 1; }

  id=$(printf '%s' "$items" | jq -r --argjson n "$issue" \
    '.items[] | select(.content.number == $n) | .id // empty' | head -1)
  if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi

  local url
  url="https://github.com/$(repo_slug)/issues/$issue"
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
  local pid fid oid item
  pid=$(state_get '.board.projectId')
  fid=$(state_get '.board.sizeFieldId')
  [ -n "$fid" ] || { warn "project has no Size field; skipping"; return 1; }
  oid=$(state_get ".board.sizeOptions[\"$size\"]")
  [ -n "$oid" ] || { warn "project has no '$size' Size option"; return 1; }
  item=$(board_item_id "$issue") || return 1
  gh project item-edit --id "$item" --project-id "$pid" \
    --field-id "$fid" --single-select-option-id "$oid" >/dev/null 2>&1 \
    || { warn "board size edit failed for #$issue"; return 1; }
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
    local existing
    existing=$(gh project list --owner "$owner" --format json 2>/dev/null \
      | jq -r --arg t "$title" '.projects[] | select(.title == $t) | .number // empty' \
      | head -1)
    if [ -n "$existing" ]; then
      proj=$existing
    else
      proj=$(gh project create --owner "$owner" --title "$title" \
        --format json --jq .number 2>/dev/null || true)
      [ -n "$proj" ] || { warn "cannot create project '$title'"; return 1; }
    fi
    cfg_write ".project = $proj"
  fi

  board_ids
}
