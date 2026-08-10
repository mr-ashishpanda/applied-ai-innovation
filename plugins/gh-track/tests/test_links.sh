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
scratch_slug

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

# I3 regression: every spelling of the same file must normalise to one
# repo-root-relative path, because that path is interpolated into a URL that
# becomes the permanent record in an issue comment. A cwd-relative reading
# used to yield a confident 404, an absolute path a doubled slash, and
# `./x` a `/./` URL -- all with a populated sha=, so the output looked fine.
git init -q --bare "$SCRATCH/origin.git"
git remote add origin "$SCRATCH/origin.git"
want="path=docs/superpowers/specs/s.md"
wanturl="head_url=https://github.com/me/proj/blob/42-thing/docs/superpowers/specs/s.md"

out=$(cd docs/superpowers/specs && "$GHTRACK" link 42 --kind spec --path s.md 2>/dev/null)
assert_contains "$out" "$want" "subdirectory-relative path normalised"
assert_contains "$out" "$wanturl" "subdirectory-relative path builds the right url"
assert_contains "$out" "sha=$sha" "sha still resolves for a normalised path"

out=$("$GHTRACK" link 42 --kind spec --path "$PWD/docs/superpowers/specs/s.md" 2>/dev/null)
assert_contains "$out" "$wanturl" "absolute path normalised"

out=$("$GHTRACK" link 42 --kind spec --path ./docs/superpowers/specs/s.md 2>/dev/null)
assert_contains "$out" "$wanturl" "dot-prefixed path normalised"

# A path outside the repository is a usage error, not a nonsense URL.
assert_exit 2 "$GHTRACK" link 42 --kind spec --path /etc/hosts

# Characters that would break the URL are encoded (ledger #21).
mkdir -p "d"
printf 'x\n' >"d/a b#c.md"
git add d && git commit -q -m "spacey"
out=$("$GHTRACK" link 42 --kind spec --path "d/a b#c.md" 2>/dev/null)
assert_contains "$out" "blob/42-thing/d/a%20b%23c.md" "space and hash url-encoded"

# M3: the host comes from origin, so GitHub Enterprise Server is not sent to
# github.com.
git remote set-url origin git@ghe.example.com:me/proj.git
assert_eq "ghe.example.com" "$(gh_host)" "host derived from an ssh remote"
git remote set-url origin https://ghe.example.com/me/proj.git
assert_eq "ghe.example.com" "$(gh_host)" "host derived from an https remote"
git remote remove origin
assert_eq "github.com" "$(gh_host)" "github.com when there is no remote"

# T3/M2: with no remote the push fails, and degradation must be visible in
# what the output SAYS -- not merely in `path=`, which is printed
# unconditionally and so asserted nothing about degradation at all.
out=$("$GHTRACK" link 42 --kind spec --path docs/superpowers/specs/s.md 2>/dev/null)
assert_contains "$out" "docs/superpowers/specs/s.md" "output names the path"
assert_contains "$out" "pushed=no" "degraded run reports the failed push"
assert_contains "$out" "head_url=" "degraded run emits the key"
assert_not_contains "$out" "head_url=https" "no confident url when nothing was pushed"
assert_not_contains "$out" "pinned_url=https" "no pinned url when nothing was pushed"

teardown_scratch
report
