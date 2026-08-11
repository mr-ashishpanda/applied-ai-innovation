#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

HOOK="$PLUGIN_DIR/hooks/artifact-changed.sh"

# payload TOOL PATH — synthesize a PostToolUse hook payload.
payload() {
  printf '{"tool_name":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' \
    "$1" "$SCRATCH" "$2"
}

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
git checkout -q -b 42-thing
mkdir -p docs/superpowers/specs docs/superpowers/plans docs/superpowers/research
printf '# s\n' >docs/superpowers/specs/s.md
printf '# p\n' >docs/superpowers/plans/p.md
printf '# r\n' >docs/superpowers/research/r.md

# A spec write produces a spec-checkpoint reminder naming the issue.
out=$(payload Write "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
assert_contains "$out" "additionalContext" "emits hook JSON"
assert_contains "$out" "#42" "names the resolved issue"
assert_contains "$out" "spec" "mentions the spec checkpoint"

# A plan write asks for the plan checkpoint AND checklist sync.
out=$(payload Edit "$SCRATCH/docs/superpowers/plans/p.md" | bash "$HOOK")
assert_contains "$out" "ghtrack tasks" "asks for checklist sync"

# An unknown docs/superpowers path gets the mildest nudge.
out=$(payload Write "$SCRATCH/docs/superpowers/research/r.md" | bash "$HOOK")
assert_contains "$out" "research/r.md" "names the unknown artifact"
assert_contains "$out" "one-line note" "mild nudge wording"

# Unrelated paths are silent.
printf 'x\n' >src.py
out=$(payload Write "$SCRATCH/src.py" | bash "$HOOK")
assert_eq "" "$out" "unrelated path silent"

# Non-write tools are silent.
out=$(payload Read "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
assert_eq "" "$out" "Read tool silent"

# Debounce: identical content twice produces one nudge.
out1=$(payload Write "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
out2=$(payload Write "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
assert_contains "$out1" "#42" "first write nudges"
assert_eq "" "$out2" "unchanged repeat is silent"

# Changed content nudges again.
printf '# s changed\n' >docs/superpowers/specs/s.md
out3=$(payload Write "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
assert_contains "$out3" "#42" "changed content nudges again"

# An unresolvable issue is silent, not an error.
git checkout -q -b spike/no-number
printf '# s2\n' >docs/superpowers/specs/s.md
out=$(payload Write "$SCRATCH/docs/superpowers/specs/s.md" | bash "$HOOK")
assert_eq "" "$out" "unresolvable issue is silent"

# Malformed payload exits 0 and stays silent - a hook must never break a tool.
out=$(printf 'not json' | bash "$HOOK")
assert_eq "" "$out" "malformed payload silent"
assert_exit 0 bash -c "printf 'not json' | bash '$HOOK'"

# A missing ghtrack on PATH must not break the hook either.
out=$(PATH=/usr/bin:/bin payload Write "$SCRATCH/docs/superpowers/specs/s.md" | \
  PATH=/usr/bin:/bin bash "$HOOK")
assert_exit 0 bash -c "PATH=/usr/bin:/bin printf '{}' | bash '$HOOK'"

teardown_scratch
report
