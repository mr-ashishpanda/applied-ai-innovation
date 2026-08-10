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
# Not in a subshell: FAILURES incremented inside one would be lost and a
# real failure would read as a pass.
ln -sf "$SCRATCH/fakegit" "$SCRATCH/git"
old_path=$PATH
PATH="$SCRATCH:$PATH"
assert_exit 1 link_push
PATH=$old_path
rm -f "$SCRATCH/git"

# The subcommand degrades to a plain path when there is no remote.
out=$("$GHTRACK" link 42 --kind spec --path docs/superpowers/specs/s.md 2>&1 || true)
assert_contains "$out" "docs/superpowers/specs/s.md" "output names the path"

teardown_scratch
report
