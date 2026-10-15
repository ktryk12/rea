#!/bin/sh
# Build the analysis runtime image FROM A GIT COMMIT, not from the working tree.
#
#   ./podman/rea-build-runtime.sh [commit-ish]     (default: HEAD)
#
# Why not build from the working directory: a build context taken from the
# working tree carries whatever happens to be on disk, including untracked and
# gitignored files. That was not hypothetical - the first content-level source
# check found four gitignored build artefacts (build/fixtures/rea-ghidra-*)
# inside an otherwise exact image, which means the image held files that were
# not in the commit it declared.
#
# Exporting the commit with `git archive` makes the context exactly the files
# that commit records, with .gitattributes text conversion applied, so the
# declared commit and the image contents agree by construction.
# podman/rea-verify-source.sh then confirms that independently.
#
# A dirty working tree is refused by default, because an image labelled with a
# commit must not contain uncommitted work. REA_ALLOW_DIRTY=1 overrides it and
# the resulting image is labelled `dirty`, which rea-analyze.sh records.
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# `cd` is a shell builtin, so it needs no MSYS path conversion; see
# rea-verify-source.sh for why relative paths are used throughout.
in_repo() { (CDPATH= cd -- "$repo_root" && "$@"); }

commitish="${1:-HEAD}"
sha="$(in_repo git rev-parse "${commitish}^{commit}")"

tree_state=clean
if [ -n "$(in_repo git status --porcelain)" ]; then
  if [ "${REA_ALLOW_DIRTY:-0}" != "1" ]; then
    echo "rea-build-runtime: working tree is dirty; refusing to build an image" >&2
    echo "  commit the changes, or set REA_ALLOW_DIRTY=1 to build anyway" >&2
    exit 2
  fi
  tree_state=dirty
fi

context_rel=".rea-build-context"
context="$repo_root/$context_rel"
cleanup() { rm -rf "$context"; }
trap cleanup EXIT INT TERM

rm -rf "$context"
mkdir -p "$context"
in_repo git archive --format=tar "$sha" | tar -x -C "$context"

echo "building runtime image"
echo "  commit : $sha"
echo "  tree   : $tree_state"

in_repo podman build \
  -f "$context_rel/podman/Containerfile.rea-runtime" \
  --build-arg REA_SOURCE_SHA="$sha" \
  --build-arg REA_SOURCE_DIRTY="$tree_state" \
  -t "localhost/rea-runtime:$sha" \
  -t localhost/rea-runtime:current \
  "$context_rel"

echo "built localhost/rea-runtime:$sha"
echo "verify it with: ./podman/rea-verify-source.sh localhost/rea-runtime:$sha"
