#!/bin/sh
# Offline tests for script/prepare-upgrade-reference.sh on a scratch repository: the upgrade baseline must hold each
# dependency at the commit the release tag pinned, not the one currently checked out.
# Run: sh test/release_tools/test_prepare_upgrade_reference.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A scratch repository must not pick up the developer's git configuration or signing setup.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@invalid

failures=0
checks=0
pass() { checks=$((checks + 1)); echo "ok   - $1"; }
bad() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }

# The dependency, with two commits whose file content tells them apart.
git init -q "$WORK/dep"
echo v1 > "$WORK/dep/file.txt"; git -C "$WORK/dep" add file.txt; git -C "$WORK/dep" commit -q -m c1
C1="$(git -C "$WORK/dep" rev-parse HEAD)"
echo v2 > "$WORK/dep/file.txt"; git -C "$WORK/dep" commit -q -am c2
C2="$(git -C "$WORK/dep" rev-parse HEAD)"
# A commit that exists only in another repository, so the dependency's checkout cannot have it.
git init -q "$WORK/other"
echo v3 > "$WORK/other/file.txt"; git -C "$WORK/other" add file.txt; git -C "$WORK/other" commit -q -m c3
C3="$(git -C "$WORK/other" rev-parse HEAD)"

# The project: its release tag pins the dependency at C1, then the dependency is bumped to C2.
git init -q "$WORK/project"
cd "$WORK/project" || exit 1
mkdir -p script src
cp "$ROOT/script/prepare-upgrade-reference.sh" script/
echo contract > src/A.sol
git -c protocol.file.allow=always submodule add -q "$WORK/dep" lib/dep
git -C lib/dep checkout -q "$C1"
git add -A; git commit -q -m release
git tag release-1
git -C lib/dep checkout -q "$C2"
git add lib/dep; git commit -q -m "bump dep"
# A second tag pinning a commit the dependency's checkout does not have.
git update-index --cacheinfo "160000,$C3,lib/dep"
git commit -q -m "pin missing"
git tag release-missing

run() { out="$(bash script/prepare-upgrade-reference.sh "$1" 2>&1)"; STATUS=$?; }

run release-1
[ "$STATUS" -eq 0 ] && pass "exports a tag whose dependency commit is available" || { bad "exports a tag whose dependency commit is available"; echo "$out"; }
[ "$(cat .upgrade-reference/src/lib/dep/file.txt 2>/dev/null)" = v1 ] \
  && pass "the dependency is exported at the commit the tag pinned, not the bumped one" \
  || bad "the dependency is exported at the commit the tag pinned, not the bumped one"
[ -f .upgrade-reference/src/src/A.sol ] && pass "the tag's own sources are exported" || bad "the tag's own sources are exported"
[ ! -L .upgrade-reference/src/lib ] && pass "lib is a copy, not a link to the current checkout" || bad "lib is a copy, not a link to the current checkout"

run release-missing
[ "$STATUS" -ne 0 ] && pass "a pinned dependency commit that is not available fails" || bad "a pinned dependency commit that is not available fails"
case "$out" in *"lib/dep at $C3"*"is not available locally"*) pass "the failure names the dependency and the commit" ;; *) bad "the failure names the dependency and the commit"; echo "$out" ;; esac
case "$out" in *"git submodule update --init lib/dep"*) pass "the failure says how to fetch it" ;; *) bad "the failure says how to fetch it" ;; esac

run release-unknown
[ "$STATUS" -ne 0 ] && pass "an unknown tag fails" || bad "an unknown tag fails"
case "$out" in *"release tag 'release-unknown' not found"*) pass "an unknown tag is named" ;; *) bad "an unknown tag is named"; echo "$out" ;; esac

echo "$checks checks, $failures failed"
[ "$failures" -eq 0 ]
