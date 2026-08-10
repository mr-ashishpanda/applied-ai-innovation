#!/usr/bin/env bash
# Marked checkpoint comments.
#
# Singleton events have exactly one comment per issue: re-running the
# checkpoint edits it in place, so a revised spec does not leave a trail of
# near-identical comments. Repeatable events legitimately recur, so they are
# keyed by SHA — same SHA edits, new SHA posts.

COMMENT_EVENTS_SINGLETON="spec plan build-started done"
COMMENT_EVENTS_REPEATABLE="scope-change blocked repro root-cause"

comment_event_known() {
  case " $COMMENT_EVENTS_SINGLETON $COMMENT_EVENTS_REPEATABLE " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

comment_is_singleton() {
  case " $COMMENT_EVENTS_SINGLETON " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

comment_marker() { printf '<!-- gh-track:%s:%s -->' "$1" "$2"; }

# comment_find N EVENT SHA — numeric REST id of the comment to edit, if any.
comment_find() {
  local issue=$1 event=$2 sha=$3 prefix esc
  if comment_is_singleton "$event"; then
    prefix="<!-- gh-track:$event:"
  else
    prefix="$(comment_marker "$event" "$sha")"
  fi
  # $prefix is interpolated into a jq program string; escape backslashes and
  # double quotes first so an unusual SHA/event cannot break out of the jq
  # string literal (worst case otherwise: a jq syntax error, swallowed by
  # 2>/dev/null, silently degrading to "no match found").
  esc=$(printf '%s' "$prefix" | sed 's/\\/\\\\/g; s/"/\\"/g')
  gh api "repos/$(repo_slug)/issues/$issue/comments" --paginate \
    --jq "[.[] | select(.body | startswith(\"$esc\"))] | first | .id // empty" \
    2>/dev/null || true
}

# comment_upsert N EVENT SHA FILE — prints "created" or "updated".
comment_upsert() {
  local issue=$1 event=$2 sha=$3 file=$4
  comment_event_known "$event" || die "unknown checkpoint event: $event" 2
  [ -f "$file" ] || die "no such file: $file" 2

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/ghtrack-comment.XXXXXX")
  # Clean up on process exit rather than with an explicit rm right after the
  # gh call: an explicit rm would run whether or not gh succeeded, but under
  # `set -e` a failing gh call exits the process before that rm line is ever
  # reached, leaking $tmp. An EXIT trap fires on every exit path — success,
  # `die`, or a `set -e` bailout from a failed gh call — so both the post and
  # edit branches are covered without duplicating error handling.
  # $tmp is expanded now, at registration time: a single-quoted trap body
  # would expand it when the trap fires, after this function has returned
  # and its `local tmp` has gone out of scope, silently becoming `rm -f ""`.
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  { comment_marker "$event" "$sha"; printf '\n'; cat "$file"; } >"$tmp"

  local existing
  existing=$(comment_find "$issue" "$event" "$sha")

  if [ -n "$existing" ]; then
    gh api -X PATCH "repos/$(repo_slug)/issues/comments/$existing" \
      -F "body=@$tmp" >/dev/null
    printf 'updated'
  else
    gh issue comment "$issue" --repo "$(repo_slug)" --body-file "$tmp" >/dev/null
    printf 'created'
  fi
}
