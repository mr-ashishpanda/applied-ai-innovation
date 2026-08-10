# ghtrack CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `ghtrack` CLI — every GitHub mutation the gh-track plugin performs, as one deterministic, idempotent, model-free shell tool with a full offline test suite.

**Architecture:** A thin dispatcher (`scripts/ghtrack`) sources focused libraries from `scripts/lib/` and dispatches to one function per subcommand. All GitHub access goes through `gh`, never `curl`, so authentication is inherited. Tests run fully offline by putting a recording `gh` stub first on `PATH` and operating inside a scratch git repository, so every test asserts the exact `gh` invocations produced.

**Tech Stack:** POSIX-ish bash (3.2 compatible), `jq` for JSON, `gh` CLI for GitHub, `shellcheck` for linting, a hand-rolled dependency-free bash test runner.

## Global Constraints

- **bash 3.2 compatible.** The only bash on the target machine is GNU bash 3.2.57 (macOS system bash). Forbidden: associative arrays (`declare -A`), `mapfile`/`readarray`, `${var,,}`/`${var^^}`, `&>>`, `+=` on arrays is allowed but avoid it where a loop is clearer. Use `BASH_REMATCH` (available in 3.2).
- **Shebang:** every script starts `#!/usr/bin/env bash` followed by `set -euo pipefail`.
- **`shellcheck` clean.** Zero warnings at default severity. Suppressions require an inline justification comment.
- **Every mutating subcommand is idempotent.** Running it twice must produce no second create call.
- **Tracking failures never abort development.** Every subcommand exits non-zero with a single-line reason on stderr; no subcommand ever exits zero on failure.
- **`gh` only for GitHub.** No `curl`, no hardcoded API hostnames.
- **No network in tests.** Any test that would reach the network is a broken test.
- **Config path:** `.claude/gh-track/config.json` (committed). **State path:** `.claude/gh-track/state.json` (git-ignored).
- **Marker format, exact:** `<!-- gh-track:<event>:<sha> -->` as the first line of a comment body.
- **Stage labels, exact:** `stage:backlog`, `stage:spec`, `stage:triage`, `stage:planned`, `stage:debugging`, `stage:building`, `stage:review`, `stage:done`.
- **Board Status options, exact:** `Backlog`, `Todo`, `Doing`, `Review`, `Done`.
- **Tasks heading in issue bodies, exact ASCII:** `## Tasks (from plan - N/M)`. ASCII hyphen, not an em dash, so `awk` and `sed` behave identically across platforms.

---

## File Structure

```
plugins/gh-track/
├── scripts/
│   ├── ghtrack                 # dispatcher: arg parsing, subcommand routing, usage
│   └── lib/
│       ├── util.sh             # die/warn, dependency checks, JSON read helpers
│       ├── config.sh           # config + state load/write, repo & owner resolution
│       ├── resolve.sh          # branch/worktree -> issue number
│       ├── body.sh             # fetch/replace issue body, section replacement
│       ├── tasks.sh            # plan task extraction, checklist merge, tick, counter
│       ├── comment.sh          # marked comment upsert (post vs edit)
│       ├── links.sh            # branch push, HEAD + SHA-pinned blob URLs
│       ├── labels.sh           # label ensure, stage swap
│       └── board.sh            # project field/option id lookup, Status + Size writes
└── tests/
    ├── run                     # test runner: executes tests/test_*.sh, reports
    ├── helpers.sh              # assertions, scratch repo, gh stub control
    ├── stub/gh                 # recording gh stub, canned responses
    ├── fixtures/
    │   ├── plan-sample.md      # plan with 4 `### Task N:` headings
    │   └── body-sample.md      # issue body with all sections populated
    └── test_*.sh               # one file per library
```

Responsibility boundaries: `util.sh` knows nothing about GitHub. `config.sh` knows nothing about issues. `body.sh`/`tasks.sh` are pure text transforms — they never call `gh` — which is what makes them cheap to test. Only `labels.sh`, `board.sh`, `comment.sh`, `links.sh` and the dispatcher touch `gh`.

---

### Task 1: Test harness, gh stub, and dispatcher skeleton

**Files:**
- Create: `plugins/gh-track/scripts/ghtrack`
- Create: `plugins/gh-track/scripts/lib/util.sh`
- Create: `plugins/gh-track/tests/run`
- Create: `plugins/gh-track/tests/helpers.sh`
- Create: `plugins/gh-track/tests/stub/gh`
- Create: `plugins/gh-track/tests/test_dispatcher.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `die MSG` (prints `ghtrack: MSG` to stderr, exits 1), `warn MSG` (stderr, returns 0), `need_cmd NAME` (die if not on PATH), `GHT_LIB` (absolute path to `scripts/lib`). Test helpers: `assert_eq EXPECTED ACTUAL LABEL`, `assert_contains HAYSTACK NEEDLE LABEL`, `assert_exit CODE CMD...`, `setup_scratch` (creates and cds into a scratch git repo, sets `SCRATCH`), `teardown_scratch`, `stub_reset`, `stub_expect PATTERN EXIT [STDOUT_FILE]`, `stub_calls` (prints the recorded call log), `GHTRACK` (absolute path to the `ghtrack` under test).

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/test_dispatcher.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

# Usage on no arguments, exit 2 (usage error, distinct from failure).
out=$("$GHTRACK" 2>&1 || true)
assert_exit 2 "$GHTRACK"
assert_contains "$out" "usage: ghtrack" "usage banner on no args"

# Unknown subcommand names the offender and exits 2.
out=$("$GHTRACK" frobnicate 2>&1 || true)
assert_exit 2 "$GHTRACK" frobnicate
assert_contains "$out" "unknown subcommand: frobnicate" "unknown subcommand message"

# --version prints a bare semver and exits 0.
out=$("$GHTRACK" --version)
assert_exit 0 "$GHTRACK" --version
if ! printf '%s' "$out" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  fail "--version should print bare semver, got: $out"
fi

# The stub records calls and is what `gh` resolves to inside tests.
setup_scratch
stub_reset
gh issue list --label foo >/dev/null
assert_contains "$(stub_calls)" "issue list --label foo" "stub records gh calls"
teardown_scratch

report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_dispatcher.sh`
Expected: FAIL — `helpers.sh: No such file or directory`.

- [ ] **Step 3: Write the gh stub**

Create `plugins/gh-track/tests/stub/gh`:

```bash
#!/usr/bin/env bash
# Recording gh stub. Logs every invocation and replays canned responses.
#
# Contract:
#   $GH_STUB_LOG        - file; one line per call, the joined arguments
#   $GH_STUB_RESPONSES  - file; TAB-separated: PATTERN <TAB> EXIT <TAB> [STDOUT_FILE]
#
# The first response whose PATTERN occurs as a substring of the joined
# arguments wins. With no match: exit 0, empty stdout. This keeps tests
# declarative — a test states only the calls it cares about.
set -uo pipefail

args="$*"
printf '%s\n' "$args" >>"${GH_STUB_LOG:?GH_STUB_LOG unset}"

if [ -n "${GH_STUB_RESPONSES:-}" ] && [ -f "$GH_STUB_RESPONSES" ]; then
  while IFS="$(printf '\t')" read -r pattern code outfile; do
    [ -n "${pattern:-}" ] || continue
    case "$args" in
      *"$pattern"*)
        if [ -n "${outfile:-}" ] && [ -f "$outfile" ]; then
          cat "$outfile"
        fi
        exit "${code:-0}"
        ;;
    esac
  done <"$GH_STUB_RESPONSES"
fi

exit 0
```

Make it executable: `chmod +x plugins/gh-track/tests/stub/gh`

- [ ] **Step 4: Write the test helpers**

Create `plugins/gh-track/tests/helpers.sh`:

```bash
#!/usr/bin/env bash
# Test helpers: assertions, scratch git repo, gh stub control.
# Every test file sources this and ends with `report`.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_DIR=$(cd "$TESTS_DIR/.." && pwd)
GHTRACK="$PLUGIN_DIR/scripts/ghtrack"
export GHTRACK PLUGIN_DIR TESTS_DIR

FAILURES=0
CHECKS=0

fail() {
  FAILURES=$((FAILURES + 1))
  printf '  FAIL: %s\n' "$1" >&2
}

pass() { CHECKS=$((CHECKS + 1)); }

assert_eq() {
  CHECKS=$((CHECKS + 1))
  if [ "$1" != "$2" ]; then
    fail "${3:-assert_eq}: expected [$1], got [$2]"
  fi
}

assert_contains() {
  CHECKS=$((CHECKS + 1))
  case "$1" in
    *"$2"*) : ;;
    *) fail "${3:-assert_contains}: [$2] not found in [$1]" ;;
  esac
}

assert_not_contains() {
  CHECKS=$((CHECKS + 1))
  case "$1" in
    *"$2"*) fail "${3:-assert_not_contains}: [$2] unexpectedly found in [$1]" ;;
    *) : ;;
  esac
}

# assert_exit CODE CMD... — runs CMD, compares exit status.
assert_exit() {
  local want=$1
  shift
  CHECKS=$((CHECKS + 1))
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [ "$want" != "$got" ]; then
    fail "assert_exit: expected exit $want, got $got from: $*"
  fi
}

report() {
  if [ "$FAILURES" -gt 0 ]; then
    printf '  %d checks, %d FAILED\n' "$CHECKS" "$FAILURES" >&2
    exit 1
  fi
  printf '  %d checks passed\n' "$CHECKS"
  exit 0
}

# --- gh stub control -------------------------------------------------------

# Put the stub first on PATH for the whole test process.
STUB_BIN="$TESTS_DIR/stub"
PATH="$STUB_BIN:$PATH"
export PATH

stub_reset() {
  GH_STUB_LOG="${SCRATCH:-${TMPDIR:-/tmp}}/gh-calls.log"
  GH_STUB_RESPONSES="${SCRATCH:-${TMPDIR:-/tmp}}/gh-responses.tsv"
  : >"$GH_STUB_LOG"
  : >"$GH_STUB_RESPONSES"
  export GH_STUB_LOG GH_STUB_RESPONSES
}

# stub_expect PATTERN EXIT [STDOUT_FILE]
stub_expect() {
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$GH_STUB_RESPONSES"
}

# stub_expect_json PATTERN JSON — canned JSON stdout, exit 0.
stub_expect_json() {
  local f
  f="${SCRATCH:-${TMPDIR:-/tmp}}/stub-out.$RANDOM.json"
  printf '%s' "$2" >"$f"
  stub_expect "$1" 0 "$f"
}

stub_calls() { cat "$GH_STUB_LOG"; }

# stub_call_count PATTERN — how many recorded calls contain PATTERN.
stub_call_count() { grep -c -- "$1" "$GH_STUB_LOG" || true; }

# --- scratch repo ----------------------------------------------------------

setup_scratch() {
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/ghtrack-test.XXXXXX")
  export SCRATCH
  ORIG_PWD=$(pwd)
  cd "$SCRATCH"
  git init -q .
  git config user.email test@example.com
  git config user.name Test
  git commit -q --allow-empty -m "initial"
  mkdir -p .claude/gh-track
  stub_reset
}

teardown_scratch() {
  cd "${ORIG_PWD:-/}"
  [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
  unset SCRATCH
}
```

- [ ] **Step 5: Write util.sh and the dispatcher**

Create `plugins/gh-track/scripts/lib/util.sh`:

```bash
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
```

Create `plugins/gh-track/scripts/ghtrack`:

```bash
#!/usr/bin/env bash
# ghtrack — GitHub issue and project tracking plumbing for gh-track.
# All GitHub mutations the plugin performs live here, so they are
# deterministic, idempotent, and testable without a model.
set -euo pipefail

GHTRACK_VERSION="0.1.0"

GHT_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GHT_LIB="$GHT_SCRIPTS/lib"
export GHT_LIB

# shellcheck source=lib/util.sh
. "$GHT_LIB/util.sh"

usage() {
  cat <<'EOF'
usage: ghtrack <subcommand> [options]

  doctor                              check environment, auth, scopes, config
  init                                create labels, board, and config
  new --kind K --title T [...]        create an issue at stage:backlog
  resolve                             print the issue number for this branch
  show N                              print issue state as key=value lines
  stage N STAGE                       swap stage label, mirror board Status
  body N --file F                     replace the issue body
  comment N --event E --file F        post or edit a marked comment
  link N --kind spec|plan --path P     push branch, print artifact URLs
  tasks N --plan P                    sync body checklist from a plan
  tick N --task K                     mark checklist item K complete

  --version                           print version
EOF
}

main() {
  if [ $# -eq 0 ]; then usage >&2; exit 2; fi

  case $1 in
    --version) printf '%s\n' "$GHTRACK_VERSION"; return 0 ;;
    -h|--help|help) usage; return 0 ;;
  esac

  local sub=$1
  shift

  case $sub in
    doctor|init|new|resolve|show|stage|body|comment|link|tasks|tick)
      # shellcheck source=/dev/null
      . "$GHT_LIB/cmd_$sub.sh"
      "cmd_$sub" "$@"
      ;;
    *)
      printf 'ghtrack: unknown subcommand: %s\n' "$sub" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
```

Create a placeholder-free stub for the one subcommand this task can exercise — `plugins/gh-track/scripts/lib/cmd_resolve.sh` is written in Task 3, so Task 1 registers no subcommand implementations and the dispatcher test only covers usage, unknown subcommands, and `--version`.

Make executable: `chmod +x plugins/gh-track/scripts/ghtrack plugins/gh-track/tests/run`

- [ ] **Step 6: Write the test runner**

Create `plugins/gh-track/tests/run`:

```bash
#!/usr/bin/env bash
# Run every tests/test_*.sh as its own process; report aggregate result.
# Also runs shellcheck over all scripts, since lint failures are test
# failures under this plan's Global Constraints.
set -uo pipefail

cd "$(cd "$(dirname "$0")" && pwd)"

failed=0
total=0

for t in test_*.sh; do
  [ -f "$t" ] || continue
  total=$((total + 1))
  printf '%s\n' "$t"
  if ! bash "$t"; then
    failed=$((failed + 1))
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  printf 'shellcheck\n'
  if ! shellcheck -x ../scripts/ghtrack ../scripts/lib/*.sh stub/gh helpers.sh run; then
    failed=$((failed + 1))
  fi
else
  printf 'shellcheck: not installed, skipped\n'
fi

if [ "$failed" -gt 0 ]; then
  printf '\n%d of %d suites FAILED\n' "$failed" "$total" >&2
  exit 1
fi
printf '\nall %d suites passed\n' "$total"
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — `test_dispatcher.sh` reports checks passed; shellcheck clean.

- [ ] **Step 8: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): add ghtrack dispatcher, gh stub, and test harness"
```

---

### Task 2: Config, state, and `ghtrack doctor`

**Files:**
- Create: `plugins/gh-track/scripts/lib/config.sh`
- Create: `plugins/gh-track/scripts/lib/cmd_doctor.sh`
- Create: `plugins/gh-track/tests/test_config.sh`

**Interfaces:**
- Consumes: `die`, `warn`, `need_cmd`, `json_get` from `util.sh`.
- Produces: `cfg_load` (sets `GHT_ROOT` to the repo toplevel, `GHT_CONFIG`, `GHT_STATE`; dies outside a git repo), `cfg KEY DEFAULT` (reads a dotted key from config, e.g. `cfg .project ""`), `state_get JQ_FILTER DEFAULT`, `state_set JQ_ASSIGNMENT` (atomically updates state.json, creating `{}` first), `repo_slug` (echoes `owner/name` from config, falling back to `gh repo view`), `repo_owner` (echoes the owner half). Defaults: `specGlob=docs/superpowers/specs/**/*.md`, `planGlob=docs/superpowers/plans/**/*.md`, `taskHeadingPattern=^### Task ([0-9]+):`, `branchPattern=^([0-9]+)-`, `board.statusField=Status`, `board.sizeField=Size`.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/test_config.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"

setup_scratch

# Defaults apply when no config file exists.
cfg_load
assert_eq "$SCRATCH" "$GHT_ROOT" "GHT_ROOT is repo toplevel"
assert_eq "^### Task ([0-9]+):" "$(cfg .taskHeadingPattern)" "default task pattern"
assert_eq "^([0-9]+)-" "$(cfg .branchPattern)" "default branch pattern"
assert_eq "Status" "$(cfg .board.statusField)" "default status field"
assert_eq "" "$(cfg .project)" "project empty by default"

# Config file values win over defaults.
cat >.claude/gh-track/config.json <<'JSON'
{"repo":"me/proj","project":7,"taskHeadingPattern":"^## T([0-9]+):"}
JSON
cfg_load
assert_eq "me/proj" "$(cfg .repo)" "repo from config"
assert_eq "7" "$(cfg .project)" "project from config"
assert_eq "^## T([0-9]+):" "$(cfg .taskHeadingPattern)" "overridden task pattern"
assert_eq "docs/superpowers/plans/**/*.md" "$(cfg .planGlob)" "unset key still defaults"

# repo_slug prefers config and never calls gh when config has it.
stub_reset
assert_eq "me/proj" "$(repo_slug)" "repo_slug from config"
assert_eq "me" "$(repo_owner)" "repo_owner splits slug"
assert_eq "0" "$(stub_call_count 'repo view')" "no gh call when config has repo"

# With no repo in config, repo_slug falls back to gh.
printf '%s' '{}' >.claude/gh-track/config.json
cfg_load
stub_reset
stub_expect_json 'repo view' '{"nameWithOwner":"fallback/repo"}'
assert_eq "fallback/repo" "$(repo_slug)" "repo_slug falls back to gh"

# State round-trips and is created on demand.
state_set '.worktrees["/tmp/wt"] = 42'
assert_eq "42" "$(state_get '.worktrees["/tmp/wt"]')" "state round-trip"
assert_eq "zz" "$(state_get '.nope' zz)" "state default"

# doctor reports missing config as a warning, not a failure, and exits 0
# when gh is present and authed.
stub_reset
stub_expect_json 'auth status' '{}'
out=$("$GHTRACK" doctor 2>&1 || true)
assert_contains "$out" "repo:" "doctor reports repo line"

teardown_scratch
report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_config.sh`
Expected: FAIL — `config.sh: No such file or directory`.

- [ ] **Step 3: Write config.sh**

Create `plugins/gh-track/scripts/lib/config.sh`:

```bash
#!/usr/bin/env bash
# Config and state. Knows nothing about issues — only where settings live.

cfg_load() {
  need_cmd git
  need_cmd jq
  GHT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside a git repository"
  GHT_CONFIG="$GHT_ROOT/.claude/gh-track/config.json"
  GHT_STATE="$GHT_ROOT/.claude/gh-track/state.json"
  export GHT_ROOT GHT_CONFIG GHT_STATE
}

# cfg KEY [DEFAULT] — dotted jq key. Built-in defaults apply when the key is
# absent and no explicit default is given.
cfg() {
  local key=$1 default=${2:-}
  if [ -z "$default" ]; then
    case $key in
      .specGlob) default="docs/superpowers/specs/**/*.md" ;;
      .planGlob) default="docs/superpowers/plans/**/*.md" ;;
      .taskHeadingPattern) default="^### Task ([0-9]+):" ;;
      .branchPattern) default="^([0-9]+)-" ;;
      .board.statusField) default="Status" ;;
      .board.sizeField) default="Size" ;;
    esac
  fi
  json_get "$GHT_CONFIG" "$key" "$default"
}

state_get() { json_get "$GHT_STATE" "$1" "${2:-}"; }

# state_set JQ_ASSIGNMENT — e.g. state_set '.worktrees["/p"] = 42'
state_set() {
  mkdir -p "$(dirname "$GHT_STATE")"
  [ -f "$GHT_STATE" ] || printf '%s' '{}' >"$GHT_STATE"
  local tmp="$GHT_STATE.tmp.$$"
  jq "$1" "$GHT_STATE" >"$tmp" && mv "$tmp" "$GHT_STATE"
}

repo_slug() {
  local slug
  slug=$(cfg .repo)
  if [ -n "$slug" ]; then printf '%s' "$slug"; return 0; fi
  slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  [ -n "$slug" ] || die "cannot determine repo; set .repo in $GHT_CONFIG"
  printf '%s' "$slug"
}

repo_owner() { repo_slug | cut -d/ -f1; }
repo_name() { repo_slug | cut -d/ -f2; }
```

- [ ] **Step 4: Write cmd_doctor.sh**

Create `plugins/gh-track/scripts/lib/cmd_doctor.sh`:

```bash
#!/usr/bin/env bash
# doctor — report environment readiness. Never mutates anything.
# Exits 0 when tracking can function at all (labels only counts as
# functioning); exits 1 only when gh is missing or unauthenticated.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"

cmd_doctor() {
  local problems=0

  if ! command -v gh >/dev/null 2>&1; then
    printf 'gh: NOT FOUND - install from https://cli.github.com\n'
    return 1
  fi
  printf 'gh: %s\n' "$(gh --version 2>/dev/null | head -1)"

  if ! gh auth status >/dev/null 2>&1; then
    printf 'auth: NOT AUTHENTICATED - run: gh auth login\n'
    return 1
  fi
  printf 'auth: ok\n'

  cfg_load
  printf 'repo: %s\n' "$(repo_slug)"

  if [ -f "$GHT_CONFIG" ]; then
    printf 'config: %s\n' "$GHT_CONFIG"
  else
    printf 'config: MISSING - run the setting-up-github-tracking skill\n'
    problems=$((problems + 1))
  fi

  # Project scope governs whether board writes can work at all.
  if gh auth status 2>&1 | grep -q "'project'"; then
    printf 'scope project: ok\n'
  else
    printf 'scope project: MISSING - board writes will be skipped; run: gh auth refresh -s project\n'
    problems=$((problems + 1))
  fi

  local proj
  proj=$(cfg .project)
  if [ -n "$proj" ]; then
    printf 'board: project %s\n' "$proj"
  else
    printf 'board: not configured - labels only\n'
  fi

  # Compatibility probe: configured artifact dirs vs what actually exists.
  local specdir plandir
  specdir=$(dirname "$(cfg .specGlob)")
  plandir=$(dirname "$(cfg .planGlob)")
  specdir=${specdir%/\*\*}
  plandir=${plandir%/\*\*}
  if [ -d "$GHT_ROOT/$specdir" ] || [ -d "$GHT_ROOT/$plandir" ]; then
    printf 'artifacts: ok (%s, %s)\n' "$specdir" "$plandir"
  elif [ -d "$GHT_ROOT/docs/superpowers" ]; then
    printf 'artifacts: MISMATCH - docs/superpowers exists but %s and %s do not.\n' "$specdir" "$plandir"
    printf 'artifacts: superpowers conventions may have changed; update globs in %s\n' "$GHT_CONFIG"
    problems=$((problems + 1))
  else
    printf 'artifacts: none yet (no docs/superpowers directory)\n'
  fi

  if [ "$problems" -gt 0 ]; then
    printf '\n%d item(s) need attention; tracking still functions in degraded mode.\n' "$problems"
  fi
  return 0
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — both suites green, shellcheck clean.

- [ ] **Step 6: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): add config/state loading and ghtrack doctor"
```

---

### Task 3: Issue resolution — `ghtrack resolve`

**Files:**
- Create: `plugins/gh-track/scripts/lib/resolve.sh`
- Create: `plugins/gh-track/scripts/lib/cmd_resolve.sh`
- Create: `plugins/gh-track/tests/test_resolve.sh`

**Interfaces:**
- Consumes: `cfg_load`, `cfg`, `state_get`, `state_set`, `die`.
- Produces: `resolve_issue` — echoes the issue number for the current worktree. Resolution order: branch name matched against `cfg .branchPattern` (capture group 1), then `state.json` `.worktrees[<toplevel>]`. Exits **3** (a distinct code meaning "unresolvable", not a general failure) with `cannot resolve issue for branch <b>` when neither works. Also `resolve_remember N` — records `.worktrees[<toplevel>] = N`.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/test_resolve.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/resolve.sh
. "$PLUGIN_DIR/scripts/lib/resolve.sh"

setup_scratch
cfg_load

# Branch name carries the issue number.
git checkout -q -b 42-gh-tracking
assert_eq "42" "$(resolve_issue)" "issue from branch name"

# Multi-digit and slugs with digits do not confuse the pattern.
git checkout -q -b 1234-fix-v2-parser
assert_eq "1234" "$(resolve_issue)" "multi-digit issue from branch"

# A non-conforming branch falls back to recorded state.
git checkout -q -b spike/no-number
assert_exit 3 resolve_issue
resolve_remember 99
assert_eq "99" "$(resolve_issue)" "issue from state fallback"

# A conforming branch beats the state entry (branch is authoritative).
git checkout -q -b 7-something
assert_eq "7" "$(resolve_issue)" "branch wins over state"

# The error message names the branch, so the failure is actionable.
git checkout -q -b spike/other
out=$(resolve_issue 2>&1 || true)
assert_contains "$out" "spike/other" "error names the branch"

# A configured branchPattern is honoured.
printf '%s' '{"branchPattern":"^issue-([0-9]+)/"}' >.claude/gh-track/config.json
cfg_load
git checkout -q -b issue-55/slug
assert_eq "55" "$(resolve_issue)" "custom branch pattern"

# The subcommand prints just the number.
git checkout -q -b 42-again
printf '%s' '{}' >.claude/gh-track/config.json
assert_eq "42" "$("$GHTRACK" resolve)" "resolve subcommand output"

teardown_scratch
report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_resolve.sh`
Expected: FAIL — `resolve.sh: No such file or directory`.

- [ ] **Step 3: Write resolve.sh and cmd_resolve.sh**

Create `plugins/gh-track/scripts/lib/resolve.sh`:

```bash
#!/usr/bin/env bash
# Map the current workspace to an issue number.
# Branch name is authoritative; recorded state is the fallback for
# branches that do not follow the convention (e.g. externally created
# worktrees).

resolve_issue() {
  local branch pattern
  branch=$(git branch --show-current 2>/dev/null || true)
  pattern=$(cfg .branchPattern)

  if [ -n "$branch" ] && [[ $branch =~ $pattern ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  local top recorded
  top=$(git rev-parse --show-toplevel)
  recorded=$(state_get ".worktrees[\"$top\"]")
  if [ -n "$recorded" ]; then
    printf '%s' "$recorded"
    return 0
  fi

  die "cannot resolve issue for branch ${branch:-<detached>}; run: ghtrack resolve --set N" 3
}

resolve_remember() {
  local n=$1 top
  top=$(git rev-parse --show-toplevel)
  state_set ".worktrees[\"$top\"] = $n"
}
```

Create `plugins/gh-track/scripts/lib/cmd_resolve.sh`:

```bash
#!/usr/bin/env bash
# resolve — print the issue number for this workspace, or record one.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=resolve.sh
. "$GHT_LIB/resolve.sh"

cmd_resolve() {
  cfg_load
  if [ "${1:-}" = "--set" ]; then
    [ -n "${2:-}" ] || die "resolve --set requires an issue number" 2
    resolve_remember "$2"
    printf '%s\n' "$2"
    return 0
  fi
  resolve_issue
  printf '\n'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — three suites green.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): resolve issue number from branch or state"
```

---

### Task 4: Body section engine — `ghtrack body`

**Files:**
- Create: `plugins/gh-track/scripts/lib/body.sh`
- Create: `plugins/gh-track/scripts/lib/cmd_body.sh`
- Create: `plugins/gh-track/tests/fixtures/body-sample.md`
- Create: `plugins/gh-track/tests/test_body.sh`

**Interfaces:**
- Consumes: `cfg_load`, `repo_slug`, `die`.
- Produces: `body_get N` (prints the issue body to stdout via `gh issue view N --json body --jq .body`), `body_put N FILE` (`gh issue edit N --body-file FILE`), `section_replace BODY_FILE HEADING CONTENT_FILE` (prints a new body to stdout with the `## HEADING…` section's content replaced; appends the section at the end if absent; the section runs from its heading line to the next line starting `## ` or EOF), `section_get BODY_FILE HEADING` (prints just that section's content lines, excluding the heading).

Section boundaries are matched on the heading's leading text, so `## Tasks (from plan - 3/8)` is found by `section_replace f "Tasks"`. That keeps the counter free to change without breaking the match.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/fixtures/body-sample.md`:

```markdown
**Stage:** building · **Kind:** feature · **Size:** M · **Branch:** `42-x`

## Goal
Ship the thing.

## Artifacts
- Spec: [spec](https://example.com/spec)

## Tasks (from plan - 1/2)
- [x] 1. First
- [ ] 2. Second

## Decisions
- Chose A over B because C (spec)
```

Create `plugins/gh-track/tests/test_body.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/body.sh
. "$PLUGIN_DIR/scripts/lib/body.sh"

setup_scratch
cfg_load
cp "$TESTS_DIR/fixtures/body-sample.md" body.md

# section_get returns content without the heading.
got=$(section_get body.md "Goal")
assert_eq "Ship the thing." "$got" "section_get Goal"

# Tasks section is found despite the counter in the heading.
got=$(section_get body.md "Tasks")
assert_contains "$got" "- [x] 1. First" "section_get Tasks keeps ticks"
assert_not_contains "$got" "## Decisions" "section_get stops at next heading"

# section_replace swaps content and preserves everything else.
printf '## Tasks (from plan - 2/2)\n- [x] 1. First\n- [x] 2. Second\n' >new.md
section_replace body.md "Tasks" new.md >out.md
out=$(cat out.md)
assert_contains "$out" "- [x] 2. Second" "replacement content present"
assert_contains "$out" "Chose A over B" "later section survives"
assert_contains "$out" "Ship the thing." "earlier section survives"
assert_not_contains "$out" "- [ ] 2. Second" "old content gone"
assert_eq "1" "$(grep -c '^## Tasks' out.md)" "exactly one Tasks heading"

# A missing section is appended rather than dropped silently.
printf '## Risks\n- none\n' >risks.md
section_replace body.md "Risks" risks.md >out2.md
assert_contains "$(cat out2.md)" "## Risks" "absent section appended"
assert_eq "1" "$(grep -c '^## Risks' out2.md)" "appended once"

# The final section can be replaced (EOF boundary).
printf '## Decisions\n- New decision (spec)\n' >dec.md
section_replace body.md "Decisions" dec.md >out3.md
assert_contains "$(cat out3.md)" "New decision" "last section replaced"
assert_not_contains "$(cat out3.md)" "Chose A over B" "old last section gone"

# body_put sends the file through gh issue edit.
stub_reset
body_put 42 out.md
assert_contains "$(stub_calls)" "issue edit 42 --body-file" "body_put calls gh issue edit"

# body_get reads through gh issue view.
stub_reset
stub_expect_json 'issue view 42' '"hello body"'
assert_eq "hello body" "$(body_get 42)" "body_get returns body"

teardown_scratch
report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_body.sh`
Expected: FAIL — `body.sh: No such file or directory`.

- [ ] **Step 3: Write body.sh**

Create `plugins/gh-track/scripts/lib/body.sh`:

```bash
#!/usr/bin/env bash
# Issue body as text sections. The two pure-text functions
# (section_get, section_replace) never touch gh, which is what makes the
# body logic cheap to test.

body_get() {
  gh issue view "$1" --repo "$(repo_slug)" --json body --jq .body
}

body_put() {
  gh issue edit "$1" --repo "$(repo_slug)" --body-file "$2" >/dev/null
}

# section_get BODY_FILE HEADING — content lines of `## HEADING…`, heading
# excluded. Empty output when the section is absent.
section_get() {
  awk -v h="$2" '
    index($0, "## " h) == 1 { inside = 1; next }
    /^## / { inside = 0 }
    inside { print }
  ' "$1"
}

# section_replace BODY_FILE HEADING CONTENT_FILE — new body on stdout.
# CONTENT_FILE must include its own `## Heading` line. An absent section is
# appended at the end so content is never silently dropped.
section_replace() {
  local body=$1 heading=$2 content=$3

  if ! awk -v h="$heading" 'index($0, "## " h) == 1 { found = 1 } END { exit !found }' "$body"; then
    cat "$body"
    printf '\n'
    cat "$content"
    return 0
  fi

  awk -v h="$heading" -v cf="$content" '
    index($0, "## " h) == 1 {
      while ((getline line < cf) > 0) print line
      close(cf)
      skipping = 1
      next
    }
    skipping && /^## / { skipping = 0 }
    !skipping { print }
  ' "$body"
}
```

- [ ] **Step 4: Write cmd_body.sh**

Create `plugins/gh-track/scripts/lib/cmd_body.sh`:

```bash
#!/usr/bin/env bash
# body — replace an issue body wholesale from a rendered file.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=body.sh
. "$GHT_LIB/body.sh"

cmd_body() {
  cfg_load
  local issue=${1:-}
  [ -n "$issue" ] || die "body requires an issue number" 2
  shift
  local file=""
  while [ $# -gt 0 ]; do
    case $1 in
      --file) file=${2:-}; shift 2 ;;
      *) die "body: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$file" ] || die "body requires --file FILE" 2
  [ -f "$file" ] || die "no such file: $file" 2
  body_put "$issue" "$file"
  printf 'body updated: #%s\n' "$issue"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — four suites green.

- [ ] **Step 6: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): add issue body section engine"
```

---

### Task 5: Checklist sync — `ghtrack tasks` and `ghtrack tick`

**Files:**
- Create: `plugins/gh-track/scripts/lib/tasks.sh`
- Create: `plugins/gh-track/scripts/lib/cmd_tasks.sh`
- Create: `plugins/gh-track/scripts/lib/cmd_tick.sh`
- Create: `plugins/gh-track/tests/fixtures/plan-sample.md`
- Create: `plugins/gh-track/tests/test_tasks.sh`

**Interfaces:**
- Consumes: `cfg_load`, `cfg`, `section_get`, `section_replace`, `body_get`, `body_put`, `die`, `warn`.
- Produces: `tasks_extract PLAN_FILE` (prints `- [ ] N. Title` per matching heading, using `cfg .taskHeadingPattern`; exits 4 when no headings match), `tasks_merge OLD_LINES_FILE NEW_LINES_FILE` (prints merged lines, preserving `[x]` for task numbers already ticked), `tasks_render LINES_FILE` (prints the full section including the `## Tasks (from plan - N/M)` heading with a recomputed counter), `tasks_tick LINES_FILE K` (prints lines with item K marked `[x]`; exits 5 if K is absent).

Preserving existing ticks is the load-bearing behaviour: a plan revised mid-build must not reset completed work to unchecked.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/fixtures/plan-sample.md`:

```markdown
# Sample Plan

### Task 1: First thing

Some prose. Not a heading: ### Task 99: decoy inside a paragraph is fine
because matching is anchored to the line start.

### Task 2: Second thing

### Task 3: Third thing with `code` in the title

### Task 4: Fourth thing
```

Create `plugins/gh-track/tests/test_tasks.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/body.sh
. "$PLUGIN_DIR/scripts/lib/body.sh"
# shellcheck source=../scripts/lib/tasks.sh
. "$PLUGIN_DIR/scripts/lib/tasks.sh"

setup_scratch
cfg_load

# Extraction finds every task heading and nothing else.
tasks_extract "$TESTS_DIR/fixtures/plan-sample.md" >lines.md
assert_eq "4" "$(wc -l <lines.md | tr -d ' ')" "four tasks extracted"
assert_contains "$(cat lines.md)" "- [ ] 1. First thing" "task 1 line"
assert_contains "$(cat lines.md)" "- [ ] 3. Third thing with \`code\` in the title" "code in title survives"
assert_not_contains "$(cat lines.md)" "99." "inline decoy not matched"

# Unparseable plan exits 4 and says which pattern failed.
printf '# no tasks here\n' >empty-plan.md
out=$(tasks_extract empty-plan.md 2>&1 || true)
assert_exit 4 tasks_extract empty-plan.md
assert_contains "$out" "### Task" "error names the pattern"

# Merge preserves ticks by task number, not by position.
printf -- '- [x] 1. First thing\n- [x] 2. Second thing\n' >old.md
tasks_merge old.md lines.md >merged.md
assert_contains "$(cat merged.md)" "- [x] 1. First thing" "tick 1 preserved"
assert_contains "$(cat merged.md)" "- [x] 2. Second thing" "tick 2 preserved"
assert_contains "$(cat merged.md)" "- [ ] 4. Fourth thing" "new task unticked"

# A retitled task keeps its tick and takes the new title.
printf -- '- [x] 1. Old title\n' >old2.md
tasks_merge old2.md lines.md >merged2.md
assert_contains "$(cat merged2.md)" "- [x] 1. First thing" "retitled task keeps tick"

# Render computes the counter from the lines.
tasks_render merged.md >section.md
assert_contains "$(head -1 section.md)" "## Tasks (from plan - 2/4)" "counter 2/4"

# Ticking updates one item and nothing else.
tasks_tick merged.md 4 >ticked.md
assert_contains "$(cat ticked.md)" "- [x] 4. Fourth thing" "task 4 ticked"
assert_contains "$(cat ticked.md)" "- [ ] 3. Third thing" "task 3 untouched"

# Ticking an absent task exits 5 rather than silently doing nothing.
assert_exit 5 tasks_tick merged.md 77

# Ticking twice is idempotent.
tasks_tick ticked.md 4 >ticked2.md
assert_eq "$(cat ticked.md)" "$(cat ticked2.md)" "tick is idempotent"

# End to end: tasks subcommand reads the body, writes back one edit.
stub_reset
stub_expect_json 'issue view 42' '"## Goal\nG\n\n## Tasks (from plan - 1/2)\n- [x] 1. First thing\n- [ ] 2. old\n"'
"$GHTRACK" tasks 42 --plan "$TESTS_DIR/fixtures/plan-sample.md" >/dev/null
assert_eq "1" "$(stub_call_count 'issue edit 42')" "exactly one body edit"

teardown_scratch
report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_tasks.sh`
Expected: FAIL — `tasks.sh: No such file or directory`.

- [ ] **Step 3: Write tasks.sh**

Create `plugins/gh-track/scripts/lib/tasks.sh`:

```bash
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
tasks_tick() {
  local lines=$1 k=$2
  grep -q "^- \[[ x]\] $k\. " "$lines" || die "no checklist item numbered $k" 5
  sed "s/^- \[ \] $k\. /- [x] $k. /" "$lines"
}
```

- [ ] **Step 4: Write cmd_tasks.sh and cmd_tick.sh**

Create `plugins/gh-track/scripts/lib/cmd_tasks.sh`:

```bash
#!/usr/bin/env bash
# tasks — sync an issue body's checklist from a plan file.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=body.sh
. "$GHT_LIB/body.sh"
# shellcheck source=tasks.sh
. "$GHT_LIB/tasks.sh"

cmd_tasks() {
  cfg_load
  local issue=${1:-}
  [ -n "$issue" ] || die "tasks requires an issue number" 2
  shift
  local plan=""
  while [ $# -gt 0 ]; do
    case $1 in
      --plan) plan=${2:-}; shift 2 ;;
      *) die "tasks: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$plan" ] || die "tasks requires --plan FILE" 2

  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  body_get "$issue" >"$tmp/body.md"
  section_get "$tmp/body.md" "Tasks" | grep '^- \[' >"$tmp/old.md" || : >"$tmp/old.md"
  tasks_extract "$plan" >"$tmp/new.md"
  tasks_merge "$tmp/old.md" "$tmp/new.md" >"$tmp/merged.md"
  tasks_render "$tmp/merged.md" >"$tmp/section.md"
  section_replace "$tmp/body.md" "Tasks" "$tmp/section.md" >"$tmp/out.md"
  body_put "$issue" "$tmp/out.md"

  printf 'checklist synced: #%s (%s)\n' "$issue" "$(head -1 "$tmp/section.md")"
}
```

Create `plugins/gh-track/scripts/lib/cmd_tick.sh`:

```bash
#!/usr/bin/env bash
# tick — mark one checklist item complete in an issue body.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=body.sh
. "$GHT_LIB/body.sh"
# shellcheck source=tasks.sh
. "$GHT_LIB/tasks.sh"

cmd_tick() {
  cfg_load
  local issue=${1:-}
  [ -n "$issue" ] || die "tick requires an issue number" 2
  shift
  local task=""
  while [ $# -gt 0 ]; do
    case $1 in
      --task) task=${2:-}; shift 2 ;;
      *) die "tick: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$task" ] || die "tick requires --task K" 2

  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  body_get "$issue" >"$tmp/body.md"
  section_get "$tmp/body.md" "Tasks" | grep '^- \[' >"$tmp/lines.md" \
    || die "issue #$issue has no task checklist; run: ghtrack tasks $issue --plan FILE" 5
  tasks_tick "$tmp/lines.md" "$task" >"$tmp/ticked.md"
  tasks_render "$tmp/ticked.md" >"$tmp/section.md"
  section_replace "$tmp/body.md" "Tasks" "$tmp/section.md" >"$tmp/out.md"
  body_put "$issue" "$tmp/out.md"

  printf 'ticked: #%s task %s (%s)\n' "$issue" "$task" "$(head -1 "$tmp/section.md")"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — five suites green.

- [ ] **Step 6: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): sync issue checklist from plan tasks"
```

---

### Task 6: Marked comments — `ghtrack comment`

**Files:**
- Create: `plugins/gh-track/scripts/lib/comment.sh`
- Create: `plugins/gh-track/scripts/lib/cmd_comment.sh`
- Create: `plugins/gh-track/tests/test_comment.sh`

**Interfaces:**
- Consumes: `cfg_load`, `repo_slug`, `die`.
- Produces: `comment_is_singleton EVENT` (returns 0 for `spec`, `plan`, `build-started`, `done`; 1 for `scope-change`, `blocked`, `repro`, `root-cause`), `comment_marker EVENT SHA` (prints `<!-- gh-track:EVENT:SHA -->`), `comment_find N EVENT SHA` (prints the numeric REST comment id of a matching existing comment, empty if none; singleton events match on the `<!-- gh-track:EVENT:` prefix ignoring SHA, repeatable events match the full marker), `comment_upsert N EVENT SHA FILE` (posts a new comment or PATCHes the matching one; prints `created` or `updated`).

Singleton vs repeatable is the crux: re-running the spec checkpoint must edit the one spec comment, while a second scope change must post a second comment rather than overwrite the first.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/test_comment.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/comment.sh
. "$PLUGIN_DIR/scripts/lib/comment.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
cfg_load

assert_eq "<!-- gh-track:spec:abc1234 -->" "$(comment_marker spec abc1234)" "marker format"

# Event classification.
assert_exit 0 comment_is_singleton spec
assert_exit 0 comment_is_singleton done
assert_exit 1 comment_is_singleton scope-change
assert_exit 1 comment_is_singleton blocked

printf 'Spec agreed. Decisions: ...\n' >c.md

# No existing comment -> create.
stub_reset
stub_expect_json 'issues/42/comments' '[]'
out=$(comment_upsert 42 spec abc1234 c.md)
assert_eq "created" "$out" "first post creates"
assert_contains "$(stub_calls)" "issue comment 42" "used gh issue comment"

# Existing singleton with a DIFFERENT sha -> update, not a second comment.
stub_reset
stub_expect_json 'issues/42/comments' \
  '[{"id":555,"body":"<!-- gh-track:spec:oldsha1 -->\nold text"}]'
out=$(comment_upsert 42 spec newsha2 c.md)
assert_eq "updated" "$out" "singleton edits despite new sha"
assert_contains "$(stub_calls)" "issues/comments/555" "PATCHed the existing comment"
assert_eq "0" "$(stub_call_count 'issue comment 42')" "did not post a duplicate"

# Repeatable event with a different sha -> new comment.
stub_reset
stub_expect_json 'issues/42/comments' \
  '[{"id":777,"body":"<!-- gh-track:scope-change:sha0000 -->\nfirst change"}]'
out=$(comment_upsert 42 scope-change sha1111 c.md)
assert_eq "created" "$out" "repeatable event posts again"

# Repeatable event with the SAME sha -> update (idempotent re-run).
stub_reset
stub_expect_json 'issues/42/comments' \
  '[{"id":777,"body":"<!-- gh-track:scope-change:sha1111 -->\nfirst change"}]'
out=$(comment_upsert 42 scope-change sha1111 c.md)
assert_eq "updated" "$out" "same sha is idempotent"

# The marker is prepended to the body sent to GitHub.
stub_reset
stub_expect_json 'issues/42/comments' '[]'
comment_upsert 42 done deadbee c.md >/dev/null
sent=$(grep -o '\-\-body-file [^ ]*' "$GH_STUB_LOG" | head -1 | awk '{print $2}')
assert_contains "$(head -1 "$sent")" "<!-- gh-track:done:deadbee -->" "marker is first line"
assert_contains "$(cat "$sent")" "Spec agreed" "author text preserved"

# Unknown event is rejected rather than silently accepted.
assert_exit 2 comment_upsert 42 nonsense abc c.md

teardown_scratch
report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_comment.sh`
Expected: FAIL — `comment.sh: No such file or directory`.

- [ ] **Step 3: Write comment.sh**

Create `plugins/gh-track/scripts/lib/comment.sh`:

```bash
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
  local issue=$1 event=$2 sha=$3 prefix
  if comment_is_singleton "$event"; then
    prefix="<!-- gh-track:$event:"
  else
    prefix="$(comment_marker "$event" "$sha")"
  fi
  gh api "repos/$(repo_slug)/issues/$issue/comments" --paginate \
    --jq "[.[] | select(.body | startswith(\"$prefix\"))] | first | .id // empty" \
    2>/dev/null || true
}

# comment_upsert N EVENT SHA FILE — prints "created" or "updated".
comment_upsert() {
  local issue=$1 event=$2 sha=$3 file=$4
  comment_event_known "$event" || die "unknown checkpoint event: $event" 2
  [ -f "$file" ] || die "no such file: $file" 2

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/ghtrack-comment.XXXXXX")
  { comment_marker "$event" "$sha"; printf '\n'; cat "$file"; } >"$tmp"

  local existing
  existing=$(comment_find "$issue" "$event" "$sha")

  if [ -n "$existing" ]; then
    gh api -X PATCH "repos/$(repo_slug)/issues/comments/$existing" \
      -F "body=@$tmp" >/dev/null
    rm -f "$tmp"
    printf 'updated'
  else
    gh issue comment "$issue" --repo "$(repo_slug)" --body-file "$tmp" >/dev/null
    rm -f "$tmp"
    printf 'created'
  fi
}
```

- [ ] **Step 4: Write cmd_comment.sh**

Create `plugins/gh-track/scripts/lib/cmd_comment.sh`:

```bash
#!/usr/bin/env bash
# comment — post or edit a marked checkpoint comment.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=comment.sh
. "$GHT_LIB/comment.sh"

cmd_comment() {
  cfg_load
  local issue=${1:-}
  [ -n "$issue" ] || die "comment requires an issue number" 2
  shift
  local event="" file="" sha=""
  while [ $# -gt 0 ]; do
    case $1 in
      --event) event=${2:-}; shift 2 ;;
      --file) file=${2:-}; shift 2 ;;
      --sha) sha=${2:-}; shift 2 ;;
      *) die "comment: unexpected argument: $1" 2 ;;
    esac
  done
  [ -n "$event" ] || die "comment requires --event EVENT" 2
  [ -n "$file" ] || die "comment requires --file FILE" 2
  [ -n "$sha" ] || sha=$(git rev-parse --short HEAD)

  local result
  result=$(comment_upsert "$issue" "$event" "$sha" "$file")
  printf 'comment %s: #%s %s@%s\n' "$result" "$issue" "$event" "$sha"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — six suites green.

- [ ] **Step 6: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): add idempotent marked checkpoint comments"
```

---

### Task 7: Artifact links — `ghtrack link`

**Files:**
- Create: `plugins/gh-track/scripts/lib/links.sh`
- Create: `plugins/gh-track/scripts/lib/cmd_link.sh`
- Create: `plugins/gh-track/tests/test_links.sh`

**Interfaces:**
- Consumes: `cfg_load`, `repo_slug`, `die`, `warn`.
- Produces: `link_push` (pushes the current branch with `-u`; returns 0 on success, 1 on any failure without dying, so a push failure degrades rather than aborts), `link_sha PATH` (prints the short SHA of the most recent commit touching PATH, or the empty string if the path is untracked), `link_urls PATH` (prints two lines: the branch-HEAD blob URL then the SHA-pinned blob URL; prints two empty lines when the path is untracked), `link_default_url PATH` (prints the default-branch blob URL, for the Done checkpoint's body rewrite).

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/test_links.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/links.sh
. "$PLUGIN_DIR/scripts/lib/links.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
cfg_load

git checkout -q -b 42-thing
mkdir -p docs/superpowers/specs
printf '# spec\n' >docs/superpowers/specs/s.md
git add docs && git commit -q -m "add spec"
sha=$(git rev-parse --short HEAD)

# link_sha reports the commit that last touched the path.
assert_eq "$sha" "$(link_sha docs/superpowers/specs/s.md)" "link_sha finds commit"

# link_urls emits HEAD url then pinned url.
link_urls docs/superpowers/specs/s.md >urls.txt
head_url=$(sed -n 1p urls.txt)
pin_url=$(sed -n 2p urls.txt)
assert_eq "https://github.com/me/proj/blob/42-thing/docs/superpowers/specs/s.md" "$head_url" "HEAD url"
assert_eq "https://github.com/me/proj/blob/$sha/docs/superpowers/specs/s.md" "$pin_url" "pinned url"

# An untracked path yields empty urls rather than a bogus link.
printf 'x\n' >untracked.md
assert_eq "" "$(link_sha untracked.md)" "untracked has no sha"
link_urls untracked.md >u2.txt
assert_eq "" "$(sed -n 2p u2.txt)" "untracked pinned url empty"

# link_push shells out to git push and reports failure without dying.
cat >"$SCRATCH/fakegit" <<'EOS'
#!/usr/bin/env bash
if [ "$1" = "push" ]; then echo "push rejected" >&2; exit 1; fi
exec /usr/bin/git "$@"
EOS
chmod +x "$SCRATCH/fakegit"
(
  PATH="$SCRATCH:$PATH"
  ln -sf "$SCRATCH/fakegit" "$SCRATCH/git"
  assert_exit 1 link_push
)

# The subcommand degrades to a plain path when there is no remote.
out=$("$GHTRACK" link 42 --kind spec --path docs/superpowers/specs/s.md 2>&1 || true)
assert_contains "$out" "docs/superpowers/specs/s.md" "output names the path"

teardown_scratch
report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_links.sh`
Expected: FAIL — `links.sh: No such file or directory`.

- [ ] **Step 3: Write links.sh**

Create `plugins/gh-track/scripts/lib/links.sh`:

```bash
#!/usr/bin/env bash
# Publishing artifacts: make the commit visible on GitHub, then build URLs.
#
# Nothing here writes content. Superpowers already commits spec and plan
# files; link_push only makes an existing commit visible so GitHub can
# render it.

# link_push — push the current branch. Returns 1 on failure; never dies,
# because a tracking push must not abort development work.
link_push() {
  local branch
  branch=$(git branch --show-current 2>/dev/null || true)
  if [ -z "$branch" ]; then
    warn "detached HEAD; cannot push for artifact links"
    return 1
  fi
  if ! git remote get-url origin >/dev/null 2>&1; then
    warn "no origin remote; artifact links unavailable"
    return 1
  fi
  if ! git push -u origin "$branch" >/dev/null 2>&1; then
    warn "git push failed; artifact links may not resolve yet"
    return 1
  fi
  return 0
}

# link_sha PATH — short SHA of the last commit touching PATH.
link_sha() {
  git log -1 --format=%h -- "$1" 2>/dev/null || true
}

# link_urls PATH — line 1: branch-HEAD url, line 2: SHA-pinned url.
link_urls() {
  local path=$1 slug branch sha
  slug=$(repo_slug)
  branch=$(git branch --show-current 2>/dev/null || true)
  sha=$(link_sha "$path")

  if [ -n "$branch" ] && [ -n "$sha" ]; then
    printf 'https://github.com/%s/blob/%s/%s\n' "$slug" "$branch" "$path"
  else
    printf '\n'
  fi
  if [ -n "$sha" ]; then
    printf 'https://github.com/%s/blob/%s/%s\n' "$slug" "$sha" "$path"
  else
    printf '\n'
  fi
}

# link_default_url PATH — url on the default branch, for the Done rewrite.
link_default_url() {
  local slug base
  slug=$(repo_slug)
  base=$(gh repo view --repo "$slug" --json defaultBranchRef \
    --jq .defaultBranchRef.name 2>/dev/null || true)
  [ -n "$base" ] || base=main
  printf 'https://github.com/%s/blob/%s/%s\n' "$slug" "$base" "$1"
}
```

- [ ] **Step 4: Write cmd_link.sh**

Create `plugins/gh-track/scripts/lib/cmd_link.sh`:

```bash
#!/usr/bin/env bash
# link — push the branch and print artifact URLs for a spec or plan.
# Output is key=value lines so the calling skill can use them directly.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=links.sh
. "$GHT_LIB/links.sh"

cmd_link() {
  cfg_load
  local issue=${1:-}
  [ -n "$issue" ] || die "link requires an issue number" 2
  shift
  local kind="" path=""
  while [ $# -gt 0 ]; do
    case $1 in
      --kind) kind=${2:-}; shift 2 ;;
      --path) path=${2:-}; shift 2 ;;
      *) die "link: unexpected argument: $1" 2 ;;
    esac
  done
  case $kind in
    spec|plan) : ;;
    *) die "link --kind must be spec or plan" 2 ;;
  esac
  [ -n "$path" ] || die "link requires --path PATH" 2
  [ -f "$GHT_ROOT/$path" ] || [ -f "$path" ] || die "no such file: $path" 2

  local pushed=yes
  link_push || pushed=no

  local head_url pin_url
  head_url=$(link_urls "$path" | sed -n 1p)
  pin_url=$(link_urls "$path" | sed -n 2p)

  printf 'kind=%s\n' "$kind"
  printf 'path=%s\n' "$path"
  printf 'pushed=%s\n' "$pushed"
  printf 'sha=%s\n' "$(link_sha "$path")"
  printf 'head_url=%s\n' "$head_url"
  printf 'pinned_url=%s\n' "$pin_url"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — seven suites green.

- [ ] **Step 6: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): add artifact push and permalink construction"
```

---

### Task 8: Labels, stage, and issue creation — `ghtrack new`, `show`, `stage`

**Files:**
- Create: `plugins/gh-track/scripts/lib/labels.sh`
- Create: `plugins/gh-track/scripts/lib/cmd_new.sh`
- Create: `plugins/gh-track/scripts/lib/cmd_show.sh`
- Create: `plugins/gh-track/scripts/lib/cmd_stage.sh`
- Create: `plugins/gh-track/tests/test_labels.sh`

**Interfaces:**
- Consumes: `cfg_load`, `cfg`, `repo_slug`, `body_get`, `section_get`, `die`, `warn`, `board_status_set` (from Task 9 — called only if the function exists, so this task works standalone).
- Produces: `GHT_STAGES` (space-separated stage names), `GHT_KINDS`, `labels_ensure` (creates every gh-track label with `gh label create --force`), `stage_valid STAGE`, `stage_to_status STAGE` (prints `Backlog`/`Todo`/`Doing`/`Review`/`Done`), `stage_set N STAGE` (removes any other `stage:*` label and adds the new one in a single `gh issue edit`), `issue_stage N` (prints the current stage name or empty).

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/test_labels.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/body.sh
. "$PLUGIN_DIR/scripts/lib/body.sh"
# shellcheck source=../scripts/lib/labels.sh
. "$PLUGIN_DIR/scripts/lib/labels.sh"

setup_scratch
printf '%s' '{"repo":"me/proj"}' >.claude/gh-track/config.json
cfg_load

# Stage to Status mapping, every stage covered.
assert_eq "Backlog" "$(stage_to_status backlog)" "backlog -> Backlog"
assert_eq "Todo" "$(stage_to_status spec)" "spec -> Todo"
assert_eq "Todo" "$(stage_to_status triage)" "triage -> Todo"
assert_eq "Todo" "$(stage_to_status planned)" "planned -> Todo"
assert_eq "Doing" "$(stage_to_status building)" "building -> Doing"
assert_eq "Doing" "$(stage_to_status debugging)" "debugging -> Doing"
assert_eq "Review" "$(stage_to_status review)" "review -> Review"
assert_eq "Done" "$(stage_to_status done)" "done -> Done"
assert_exit 1 stage_valid nonsense

# labels_ensure uses --force so re-running cannot fail on existing labels.
stub_reset
labels_ensure
calls=$(stub_calls)
assert_contains "$calls" "label create stage:building --force" "creates stage label with --force"
assert_contains "$calls" "label create kind:bug --force" "creates kind label"
assert_contains "$calls" "label create size:m --force" "creates size label"
assert_contains "$calls" "label create parallel-safe --force" "creates parallel-safe"
assert_contains "$calls" "label create blocked --force" "creates blocked"

# labels_ensure twice produces the same calls (idempotent by --force).
before=$(stub_call_count 'label create')
stub_reset
labels_ensure
assert_eq "$before" "$(stub_call_count 'label create')" "second run identical"

# stage_set swaps in one edit: every other stage removed, new one added.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:spec"},{"name":"kind:feature"}]}'
stage_set 42 planned
calls=$(stub_calls)
assert_contains "$calls" "--add-label stage:planned" "adds new stage"
assert_contains "$calls" "--remove-label stage:spec" "removes old stage"
assert_not_contains "$calls" "--remove-label kind:feature" "leaves non-stage labels"
assert_eq "1" "$(stub_call_count 'issue edit 42')" "single edit call"

# Setting the stage it already has is a no-op edit, not an error.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:planned"}]}'
assert_exit 0 stage_set 42 planned

# issue_stage reads the current stage.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:building"},{"name":"size:m"}]}'
assert_eq "building" "$(issue_stage 42)" "reads current stage"

# new creates at stage:backlog with the kind label.
stub_reset
stub_expect_json 'issue create' 'https://github.com/me/proj/issues/77'
out=$("$GHTRACK" new --kind feature --title "Add a thing")
assert_eq "77" "$out" "new prints the issue number"
calls=$(stub_calls)
assert_contains "$calls" "--label stage:backlog" "created at backlog"
assert_contains "$calls" "--label kind:feature" "kind label applied"

# An invalid kind is rejected before any write.
stub_reset
assert_exit 2 "$GHTRACK" new --kind nonsense --title x
assert_eq "0" "$(stub_call_count 'issue create')" "no write on bad kind"

# show prints compact key=value lines.
stub_reset
stub_expect_json 'issue view 42' \
  '{"number":42,"title":"T","state":"OPEN","labels":[{"name":"stage:building"},{"name":"kind:feature"},{"name":"size:m"}],"body":"## Tasks (from plan - 2/4)\n- [x] 1. a\n- [x] 2. b\n- [ ] 3. c\n- [ ] 4. d\n"}'
out=$("$GHTRACK" show 42)
assert_contains "$out" "stage=building" "show reports stage"
assert_contains "$out" "kind=feature" "show reports kind"
assert_contains "$out" "size=m" "show reports size"
assert_contains "$out" "tasks=2/4" "show reports checklist progress"

teardown_scratch
report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_labels.sh`
Expected: FAIL — `labels.sh: No such file or directory`.

- [ ] **Step 3: Write labels.sh**

Create `plugins/gh-track/scripts/lib/labels.sh`:

```bash
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
```

- [ ] **Step 4: Write cmd_new.sh, cmd_show.sh, cmd_stage.sh**

Create `plugins/gh-track/scripts/lib/cmd_new.sh`:

```bash
#!/usr/bin/env bash
# new — create an issue at stage:backlog. Prints only the issue number so
# callers can capture it directly.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=labels.sh
. "$GHT_LIB/labels.sh"

cmd_new() {
  cfg_load
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
    url=$(gh issue create --repo "$(repo_slug)" --title "$title" \
      --body-file "$bodyfile" $args)
  else
    # shellcheck disable=SC2086 # args is a deliberately word-split flag list
    url=$(gh issue create --repo "$(repo_slug)" --title "$title" \
      --body "Captured by gh-track. No spec yet." $args)
  fi

  printf '%s\n' "${url##*/}"
}
```

Create `plugins/gh-track/scripts/lib/cmd_show.sh`:

```bash
#!/usr/bin/env bash
# show — compact key=value view of an issue's tracking state. Designed to
# be read by a model in one glance, which is why it is not JSON.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=body.sh
. "$GHT_LIB/body.sh"
# shellcheck source=labels.sh
. "$GHT_LIB/labels.sh"

cmd_show() {
  cfg_load
  local issue=${1:-}
  [ -n "$issue" ] || die "show requires an issue number" 2

  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  gh issue view "$issue" --repo "$(repo_slug)" \
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

  jq -r .body "$tmp/issue.json" >"$tmp/body.md"
  local lines done_count total
  lines=$(section_get "$tmp/body.md" "Tasks" | grep -c '^- \[[ x]\] ' || true)
  if [ "${lines:-0}" -gt 0 ]; then
    done_count=$(section_get "$tmp/body.md" "Tasks" | grep -c '^- \[x\] ' || true)
    total=$lines
    printf 'tasks=%s/%s\n' "${done_count:-0}" "$total"
  else
    printf 'tasks=none\n'
  fi

  local spec plan
  spec=$(section_get "$tmp/body.md" "Artifacts" | sed -n 's/^- Spec: .*(\(.*\))$/\1/p' | head -1)
  plan=$(section_get "$tmp/body.md" "Artifacts" | sed -n 's/^- Plan: .*(\(.*\))$/\1/p' | head -1)
  printf 'spec=%s\n' "$spec"
  printf 'plan=%s\n' "$plan"
}
```

Create `plugins/gh-track/scripts/lib/cmd_stage.sh`:

```bash
#!/usr/bin/env bash
# stage — swap the stage label and mirror the board Status.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=board.sh
. "$GHT_LIB/board.sh"

cmd_stage() {
  cfg_load
  local issue=${1:-} want=${2:-}
  [ -n "$issue" ] || die "stage requires an issue number" 2
  [ -n "$want" ] || die "stage requires a stage name (one of: $GHT_STAGES)" 2
  stage_set "$issue" "$want"
  printf 'stage set: #%s -> %s\n' "$issue" "$want"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Note: `cmd_stage.sh` sources `board.sh`, created in Task 9. Create a minimal `plugins/gh-track/scripts/lib/board.sh` now containing only the guard so this task is independently green; Task 9 replaces its body:

```bash
#!/usr/bin/env bash
# Project board writes. Replaced with the full implementation in Task 9.
board_status_set() { return 1; }
```

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — eight suites green.

- [ ] **Step 6: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): add labels, stage transitions, issue create and show"
```

---

### Task 9: Project board mirror and `ghtrack init`

**Files:**
- Modify: `plugins/gh-track/scripts/lib/board.sh` (replace the Task 8 stub)
- Create: `plugins/gh-track/scripts/lib/cmd_init.sh`
- Create: `plugins/gh-track/tests/test_board.sh`

**Interfaces:**
- Consumes: `cfg_load`, `cfg`, `state_set`, `state_get`, `repo_slug`, `repo_owner`, `repo_name`, `labels_ensure`, `die`, `warn`.
- Produces: `board_has_scope` (returns 0 when `gh auth status` reports the `project` scope), `board_ids` (resolves and caches project id, Status field id, Size field id, and each Status option id into `state.json` under `.board`; returns 1 when the board is unreachable), `board_item_id N` (project item id for issue N, adding the issue to the board if absent), `board_status_set N STATUS` (sets the Status single-select; returns 1 and warns on any failure), `board_size_set N SIZE`, `board_ensure` (creates the project titled after the repo if `cfg .project` is empty, then ensures Status and Size options exist).

Board failures must never propagate: every function returns non-zero and warns, and `stage_set` already treats that as "labels are still correct".

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/test_board.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=../scripts/lib/util.sh
. "$PLUGIN_DIR/scripts/lib/util.sh"
# shellcheck source=../scripts/lib/config.sh
. "$PLUGIN_DIR/scripts/lib/config.sh"
# shellcheck source=../scripts/lib/board.sh
. "$PLUGIN_DIR/scripts/lib/board.sh"

setup_scratch
printf '%s' '{"repo":"me/proj","project":3}' >.claude/gh-track/config.json
cfg_load

# Missing project scope is detected and reported, not fatal.
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'read:project'"
assert_exit 1 board_has_scope

stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'project'"
assert_exit 0 board_has_scope

# board_ids resolves and caches project/field/option ids.
stub_reset
stub_expect_json 'auth status' "Token scopes: 'project'"
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"},{"id":"O_doing","name":"Doing"},{"id":"O_done","name":"Done"},{"id":"O_backlog","name":"Backlog"},{"id":"O_review","name":"Review"}]},{"id":"F_size","name":"Size","options":[{"id":"O_s","name":"S"},{"id":"O_m","name":"M"},{"id":"O_l","name":"L"}]}]}'
stub_expect_json 'project view' '{"id":"PVT_abc"}'
assert_exit 0 board_ids
assert_eq "PVT_abc" "$(state_get '.board.projectId')" "project id cached"
assert_eq "F_status" "$(state_get '.board.statusFieldId')" "status field id cached"
assert_eq "O_doing" "$(state_get '.board.statusOptions.Doing')" "status option cached"

# Cached ids mean no repeat lookups.
stub_reset
assert_exit 0 board_ids
assert_eq "0" "$(stub_call_count 'project field-list')" "ids read from cache"

# board_status_set adds the item if needed, then edits the field.
stub_reset
stub_expect_json 'project item-list' \
  '{"items":[{"id":"PVTI_42","content":{"number":42}}]}'
assert_exit 0 board_status_set 42 Doing
calls=$(stub_calls)
assert_contains "$calls" "item-edit" "edits the item field"
assert_contains "$calls" "PVTI_42" "targets the right item"
assert_contains "$calls" "O_doing" "uses the Doing option id"
assert_eq "0" "$(stub_call_count 'item-add')" "existing item not re-added"

# An issue not yet on the board is added first.
stub_reset
stub_expect_json 'project item-list' '{"items":[]}'
stub_expect_json 'project item-add' '{"id":"PVTI_new"}'
assert_exit 0 board_status_set 99 Todo
calls=$(stub_calls)
assert_contains "$calls" "item-add" "absent issue added to board"
assert_contains "$calls" "PVTI_new" "new item id used"

# An unknown status is rejected before any write.
stub_reset
assert_exit 1 board_status_set 42 Nonsense

# A failing gh call warns and returns 1 rather than dying.
stub_reset
stub_expect 'project item-list' 1
assert_exit 1 board_status_set 42 Doing

# init creates labels, ensures the board, and writes config.
setup_scratch
stub_reset
stub_expect_json 'auth status' "Token scopes: 'repo', 'project'"
stub_expect_json 'repo view' '{"nameWithOwner":"me/proj"}'
stub_expect_json 'project list' '{"projects":[]}'
stub_expect_json 'project create' '{"number":9,"id":"PVT_new"}'
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}'
"$GHTRACK" init >/dev/null
assert_contains "$(stub_calls)" "label create stage:backlog" "init creates labels"
assert_contains "$(stub_calls)" "project create" "init creates the board"
assert_eq "9" "$(jq -r .project .claude/gh-track/config.json)" "config records project"
assert_eq "me/proj" "$(jq -r .repo .claude/gh-track/config.json)" "config records repo"

# init twice does not create a second project.
stub_reset
stub_expect_json 'auth status' "Token scopes: 'project'"
stub_expect_json 'repo view' '{"nameWithOwner":"me/proj"}'
stub_expect_json 'project field-list' \
  '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}'
"$GHTRACK" init >/dev/null
assert_eq "0" "$(stub_call_count 'project create')" "init is idempotent"

# state.json is gitignored by init.
assert_contains "$(cat .gitignore)" ".claude/gh-track/state.json" "init gitignores state"

teardown_scratch
report
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-track/tests/test_board.sh`
Expected: FAIL — `board_has_scope: command not found` (the Task 8 stub defines only `board_status_set`).

- [ ] **Step 3: Write board.sh**

Replace `plugins/gh-track/scripts/lib/board.sh` entirely:

```bash
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
```

- [ ] **Step 4: Write cmd_init.sh and add cfg_write to config.sh**

Append to `plugins/gh-track/scripts/lib/config.sh`:

```bash
# cfg_write JQ_ASSIGNMENT — update config.json atomically, creating it first.
cfg_write() {
  mkdir -p "$(dirname "$GHT_CONFIG")"
  [ -f "$GHT_CONFIG" ] || printf '%s' '{}' >"$GHT_CONFIG"
  local tmp="$GHT_CONFIG.tmp.$$"
  jq "$1" "$GHT_CONFIG" >"$tmp" && mv "$tmp" "$GHT_CONFIG"
}
```

Create `plugins/gh-track/scripts/lib/cmd_init.sh`:

```bash
#!/usr/bin/env bash
# init — make a repository ready for tracking. Idempotent: safe to re-run
# after a plugin upgrade.

# shellcheck source=config.sh
. "$GHT_LIB/config.sh"
# shellcheck source=labels.sh
. "$GHT_LIB/labels.sh"
# shellcheck source=board.sh
. "$GHT_LIB/board.sh"

cmd_init() {
  cfg_load

  local slug
  slug=$(repo_slug)
  cfg_write ".repo = \"$slug\""
  printf 'repo: %s\n' "$slug"

  labels_ensure
  printf 'labels: ensured\n'

  # state.json is scratch; config.json is committed alongside it.
  if ! git -C "$GHT_ROOT" check-ignore -q .claude/gh-track/state.json 2>/dev/null; then
    printf '%s\n' ".claude/gh-track/state.json" >>"$GHT_ROOT/.gitignore"
    printf 'gitignore: added .claude/gh-track/state.json\n'
  fi

  if board_ensure; then
    printf 'board: project %s ready\n' "$(cfg .project)"
  else
    printf 'board: skipped - labels remain the source of truth\n'
  fi

  printf 'init complete\n'
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — nine suites green, shellcheck clean.

- [ ] **Step 6: Verify against real GitHub, read-only**

Run: `plugins/gh-track/scripts/ghtrack doctor`
Expected: reports `gh`, `auth: ok`, `repo: mr-ashishpanda/applied-ai-innovation`, `config: MISSING`, `scope project: MISSING`, and `artifacts: ok (docs/superpowers/specs, docs/superpowers/plans)`. The two MISSING lines are correct for a repo that has not been initialised and a token without the `project` scope — they prove the degraded-mode reporting works against real `gh`.

- [ ] **Step 7: Commit**

```bash
git add plugins/gh-track
git commit -m "feat(gh-track): add project board mirror and ghtrack init"
```

---

### Task 10: Idempotency sweep and README

**Files:**
- Create: `plugins/gh-track/tests/test_idempotency.sh`
- Create: `plugins/gh-track/README.md`
- Modify: `README.md` (repository root — add a Plugins section entry)

**Interfaces:**
- Consumes: every subcommand built above.
- Produces: no new functions. This task proves the Global Constraint "every mutating subcommand is idempotent" as an executable test rather than a claim.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-track/tests/test_idempotency.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

# Every mutating subcommand runs twice; the second run must add no CREATE
# calls. This is the executable form of the plan's idempotency constraint.

setup_scratch
printf '%s' '{"repo":"me/proj","project":3}' >.claude/gh-track/config.json
git checkout -q -b 42-thing
mkdir -p docs/superpowers/plans
cp "$TESTS_DIR/fixtures/plan-sample.md" docs/superpowers/plans/p.md
git add docs && git commit -q -m "plan"

body='"## Goal\nG\n\n## Tasks (from plan - 0/4)\n- [ ] 1. First thing\n- [ ] 2. Second thing\n- [ ] 3. Third thing with `code` in the title\n- [ ] 4. Fourth thing\n"'

# tasks: two runs, two edits, no creates.
stub_reset
stub_expect_json 'issue view 42' "$body"
"$GHTRACK" tasks 42 --plan docs/superpowers/plans/p.md >/dev/null
"$GHTRACK" tasks 42 --plan docs/superpowers/plans/p.md >/dev/null
assert_eq "0" "$(stub_call_count 'issue create')" "tasks creates nothing"

# comment: second run with the same event+sha edits instead of posting.
stub_reset
printf 'checkpoint text\n' >c.md
stub_expect_json 'issues/42/comments' '[]'
"$GHTRACK" comment 42 --event spec --sha abc1234 --file c.md >/dev/null
first_posts=$(stub_call_count 'issue comment 42')
stub_reset
stub_expect_json 'issues/42/comments' \
  '[{"id":11,"body":"<!-- gh-track:spec:abc1234 -->\ncheckpoint text"}]'
"$GHTRACK" comment 42 --event spec --sha abc1234 --file c.md >/dev/null
assert_eq "1" "$first_posts" "first comment posted once"
assert_eq "0" "$(stub_call_count 'issue comment 42')" "second run posted nothing"
assert_contains "$(stub_calls)" "issues/comments/11" "second run edited instead"

# stage: setting the same stage twice adds no labels beyond the first.
stub_reset
stub_expect_json 'issue view 42' '{"labels":[{"name":"stage:planned"}]}'
"$GHTRACK" stage 42 planned >/dev/null
"$GHTRACK" stage 42 planned >/dev/null
assert_eq "0" "$(stub_call_count 'label create')" "stage does not create labels"

# tick: ticking the same task twice yields identical bodies.
stub_reset
stub_expect_json 'issue view 42' "$body"
"$GHTRACK" tick 42 --task 1 >/dev/null
f1=$(grep -o '\-\-body-file [^ ]*' "$GH_STUB_LOG" | head -1 | awk '{print $2}')
cp "$f1" first-body.md
stub_reset
stub_expect_json 'issue view 42' '"## Tasks (from plan - 1/4)\n- [x] 1. First thing\n- [ ] 2. Second thing\n- [ ] 3. Third thing with `code` in the title\n- [ ] 4. Fourth thing\n"'
"$GHTRACK" tick 42 --task 1 >/dev/null
f2=$(grep -o '\-\-body-file [^ ]*' "$GH_STUB_LOG" | head -1 | awk '{print $2}')
assert_contains "$(cat "$f2")" "- [x] 1. First thing" "tick stays ticked"
assert_contains "$(cat "$f2")" "(from plan - 1/4)" "counter stable on re-tick"

teardown_scratch
report
```

- [ ] **Step 2: Run test to verify it fails or reveals real bugs**

Run: `bash plugins/gh-track/tests/test_idempotency.sh`
Expected: initially FAIL. Any failure here is a genuine idempotency bug in an earlier task — fix the library, not the test. Do not weaken an assertion to make it pass.

- [ ] **Step 3: Write the plugin README**

Create `plugins/gh-track/README.md`:

```markdown
# gh-track

GitHub issue and project tracking for [superpowers](https://github.com/obra/superpowers)
development workflows.

Superpowers drives development through spec → plan → implement, with artifacts
as markdown files in the repository. gh-track adds a human-facing layer: every
work item gets one GitHub issue carrying its current state, links to its
artifacts, and a short timeline of the decisions that shaped it.

**It never copies spec or plan prose into GitHub.** The issue is a control
panel — state, links, decisions. Checkpoint comments are written from what the
agent already holds in context, so tracking costs roughly 4k tokens per feature
and no artifact is ever re-read for tracking's sake.

## The `ghtrack` CLI

Every GitHub mutation lives in `scripts/ghtrack`, so it is deterministic,
idempotent, and testable without a model.

| Subcommand | Purpose |
|---|---|
| `doctor` | Check gh, auth, scopes, config, board, artifact conventions. Never mutates. |
| `init` | Create labels and the board, write config, gitignore state. Idempotent. |
| `new --kind K --title T` | Create an issue at `stage:backlog`; prints the number. |
| `resolve` | Print this branch's issue number. `--set N` records one manually. |
| `show N` | Issue state as compact `key=value` lines. |
| `stage N STAGE` | Swap the stage label, mirror board Status. |
| `body N --file F` | Replace the issue body. |
| `comment N --event E --file F` | Post or edit a marked checkpoint comment. |
| `link N --kind spec\|plan --path P` | Push the branch, print artifact URLs. |
| `tasks N --plan P` | Sync the body checklist from a plan's task headings. |
| `tick N --task K` | Mark checklist item K complete. |

## Design invariants

- **Labels are canonical; the board mirrors them.** A missing `project` scope
  or a Projects API failure costs the kanban view, not the truth.
- **Tracking failures never abort development.** Every failure is a non-zero
  exit with a one-line reason; callers degrade rather than stop.
- **Branch names carry the issue number** (`<issue>-<slug>`), so any session
  resolves its context from `git branch --show-current`.

## Running the tests

```bash
bash tests/run
```

Tests are fully offline: a recording `gh` stub goes first on `PATH` and each
test runs inside a scratch git repository, so every test asserts the exact
`gh` invocations produced. `shellcheck` runs as part of the suite.

## Requirements

`bash` 3.2+, `git`, `jq`, `gh` 2.x authenticated. Board writes additionally
need the `project` OAuth scope: `gh auth refresh -s project`.
```

- [ ] **Step 4: Add a Plugins section to the repository README**

Modify the root `README.md`. After the existing `### Skills` table, add:

```markdown
### Plugins

| Plugin | Description |
|--------|-------------|
| [`plugins/gh-track`](./plugins/gh-track/README.md) | GitHub issue and project tracking for superpowers development workflows. Every work item becomes one issue carrying its stage, artifact links, task checklist, and a timeline of decisions — without duplicating spec or plan prose into GitHub. |
```

Also update the `Repository Structure` block to include:

```
├── plugins/
│   └── gh-track/      # GitHub issue + project tracking for superpowers workflows
```

- [ ] **Step 5: Run the full suite and shellcheck**

Run: `bash plugins/gh-track/tests/run`
Expected: PASS — ten suites green, shellcheck clean.

- [ ] **Step 6: Commit**

```bash
git add plugins/gh-track README.md
git commit -m "test(gh-track): prove subcommand idempotency; document the CLI"
```

---

## Plan Self-Review

**Spec coverage.** Every `ghtrack` subcommand in the spec's CLI table has a task:
`doctor` (2), `init` (9), `new`/`show`/`stage` (8), `resolve` (3), `body` (4),
`comment` (6), `link` (7), `tasks`/`tick` (5). Config schema (2), state file and
gitignore (2, 9), stage→Status mapping (8), board fallback on missing scope (9),
marker idempotency (6, 10), permalink construction (7), compatibility probe (2),
error-handling table (spread across the task that owns each failure).

**Deliberately out of scope for this plan**, and carried by plan 2: the two
skills, both hooks, `hooks.json`, the CLAUDE.md template, the plugin manifest,
the marketplace manifest, and the Done-checkpoint body rewrite to
default-branch URLs (`link_default_url` is built here in Task 7; its *caller* is
the lifecycle skill).

**Type and name consistency.** `stage_set`, `board_status_set`, `comment_upsert`,
`tasks_extract`/`tasks_merge`/`tasks_render`/`tasks_tick`, `section_get`/
`section_replace`, `link_urls`/`link_sha`/`link_push`/`link_default_url`,
`cfg`/`cfg_write`/`state_get`/`state_set`, `repo_slug`/`repo_owner`/`repo_name`
are each defined once and referenced with the same signature everywhere. The
`## Tasks (from plan - N/M)` heading is ASCII-hyphenated in every occurrence.
Exit codes are consistent: 2 usage, 3 unresolvable issue, 4 unparseable plan,
5 missing checklist item.

**Ordering note.** Task 8 sources `board.sh`, which Task 9 owns. Task 8 therefore
creates a two-line stub returning 1, and Task 9 replaces the file wholesale.
This keeps each task independently green without a forward dependency.
