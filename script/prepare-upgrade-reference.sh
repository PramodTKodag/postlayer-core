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
# git archive leaves submodules as empty directories; the dependencies are pinned by foundry.lock and are
# the same as the current checkout's, so link them in.
rm -rf "$dest/src/lib"
ln -s ../../lib "$dest/src/lib"
echo "exported $tag to $dest/src"
