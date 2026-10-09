#!/usr/bin/env bash
# Exports the released source tree for the upgrade validator's storage-layout baseline.
# usage: prepare-upgrade-reference.sh <release tag>
# Runs on the host (git is not in the tools image). The build itself happens in the tools container.
set -euo pipefail

tag="${1:?usage: prepare-upgrade-reference.sh <release tag>}"
dest=".upgrade-reference"

git rev-parse --verify --quiet "refs/tags/$tag" > /dev/null \
  || { echo "error: release tag '$tag' not found; run 'git fetch --tags'" >&2; exit 1; }

rm -rf "$dest"
mkdir -p "$dest/src"
git archive "$tag" | tar -x -C "$dest/src"
# git archive leaves submodules as empty directories. Export each dependency at the commit the release tag pinned, not
# the current checkout's, so a later dependency bump cannot hide a storage-layout change from the validator.
rm -rf "$dest/src/lib"
mkdir -p "$dest/src/lib"
git ls-tree "$tag" lib/ | while read -r mode _type commit path; do
  [ "$mode" = "160000" ] || continue
  mkdir -p "$dest/src/$path"
  git -C "$path" archive "$commit" | tar -x -C "$dest/src/$path" \
    || { echo "error: $path at $commit (pinned by $tag) is not available locally; run 'git submodule update --init $path', or 'git -C $path fetch' if it is already initialised" >&2; exit 1; }
done
echo "exported $tag to $dest/src"
