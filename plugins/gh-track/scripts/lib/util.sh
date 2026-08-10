#!/usr/bin/env bash
# Generic helpers. Knows nothing about GitHub or issues.

die() { printf 'ghtrack: %s\n' "$1" >&2; exit "${2:-1}"; }
warn() { printf 'ghtrack: %s\n' "$1" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# json_get FILE JQ_FILTER DEFAULT — read a value, falling back when the file
# is absent or the filter yields null/empty.
json_get() {
  local file=$1 filter=$2 default=${3:-}
  if [ ! -f "$file" ]; then printf '%s' "$default"; return 0; fi
  local v
  v=$(jq -r "$filter // empty" "$file" 2>/dev/null || true)
  if [ -z "$v" ]; then printf '%s' "$default"; else printf '%s' "$v"; fi
}
