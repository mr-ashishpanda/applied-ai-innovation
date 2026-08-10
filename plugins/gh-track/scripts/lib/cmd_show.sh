#!/usr/bin/env bash
# show — compact key=value view of an issue's tracking state. Designed to
# be read by a model in one glance, which is why it is not JSON.

# shellcheck source=SCRIPTDIR/config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=SCRIPTDIR/body.sh
. "$GHT_LIB/body.sh"
# shellcheck source=SCRIPTDIR/labels.sh
. "$GHT_LIB/labels.sh"

cmd_show() {
  cfg_load
  slug_require
  local issue=${1:-}
  require_number "$issue" "show issue number"

  local tmp
  tmp=$(mktemp -d)
  # This trap fires in the caller's scope, after cmd_show has returned and
  # its `local tmp` has gone out of scope. The trap body must therefore be
  # DOUBLE-quoted so `$tmp` expands NOW, at registration time, baking the
  # literal path into the trap string. A single-quoted body defers
  # expansion to fire time, when $tmp is unset -- with set -u that either
  # errors or (guarded) silently expands to "", making `rm -rf ""` a no-op
  # that leaks this directory (and the issue-body content inside it).
  # shellcheck disable=SC2064 # intentional: expand $tmp now, not at fire time (see comment above).
  trap "rm -rf '$tmp'" EXIT

  gh issue view "$issue" --repo "$GHT_SLUG" \
    --json number,title,state,labels,body >"$tmp/issue.json" \
    || die "cannot read issue #$issue"

  printf 'issue=%s\n' "$(jq -r .number "$tmp/issue.json")"
  printf 'title=%s\n' "$(jq -r .title "$tmp/issue.json")"
  printf 'state=%s\n' "$(jq -r .state "$tmp/issue.json")"

  local labels
  labels=$(jq -r '.labels[].name' "$tmp/issue.json")
  printf 'stage=%s\n' "$(printf '%s\n' "$labels" | sed -n 's/^stage://p' | head -1)"
  printf 'kind=%s\n' "$(printf '%s\n' "$labels" | sed -n 's/^kind://p' | head -1)"
  printf 'size=%s\n' "$(printf '%s\n' "$labels" | sed -n 's/^size://p' | head -1)"

  # Strip CR: GitHub's web form saves bodies with \r\n, and the whole premise
  # is that a human edits this issue. Every line-anchored pattern below (and
  # in body.sh) would otherwise fail to match on a web-edited body, silently
  # reporting no artifacts and no checklist.
  jq -r .body "$tmp/issue.json" | tr -d '\r' >"$tmp/body.md"
  local lines done_count total
  lines=$(section_get "$tmp/body.md" "Tasks" | grep -c '^- \[[ x]\] ' || true)
  if [ "${lines:-0}" -gt 0 ]; then
    done_count=$(section_get "$tmp/body.md" "Tasks" | grep -c '^- \[x\] ' || true)
    total=$lines
    printf 'tasks=%s/%s\n' "${done_count:-0}" "$total"
  else
    printf 'tasks=none\n'
  fi

  # Capture the markdown link target, not "everything up to the last `)` on
  # the line": `- Spec: [s.md](url) (pinned)` used to yield `pinned`. Anchor
  # on the last `](` and take only up to the first `)` after it.
  local spec plan
  spec=$(section_get "$tmp/body.md" "Artifacts" | sed -n 's/^- Spec: .*](\([^)]*\)).*$/\1/p' | head -1)
  plan=$(section_get "$tmp/body.md" "Artifacts" | sed -n 's/^- Plan: .*](\([^)]*\)).*$/\1/p' | head -1)
  printf 'spec=%s\n' "$spec"
  printf 'plan=%s\n' "$plan"
}
