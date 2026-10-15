#!/bin/sh
# Verify that an analysis runtime image was built from the Git commit it
# declares, by comparing file contents rather than trusting the declaration.
#
#   ./podman/rea-verify-source.sh [image-ref]
#
# Steps:
#   1. Resolve the image reference to an immutable image ID.
#   2. Read the commit the image declares (label and baked file must agree).
#   3. Reconstruct that commit's files with `git archive`, which applies
#      .gitattributes text conversion and so reproduces a checkout exactly.
#   4. Hash every source file inside the image.
#   5. Compare. Any missing, modified, or unexpected file fails the check.
#
# A label and a baked SHA only state a commit; they are not evidence that the
# image holds that commit's sources. This script is that evidence.
set -eu

IMAGE="${1:-${REA_IMAGE:-localhost/rea-runtime:current}}"

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# Scratch space is kept INSIDE the repository and every native tool is invoked
# from the repository root with RELATIVE paths only.
#
# This is deliberate. On Windows/Git Bash the script runs with
# MSYS2_ARG_CONV_EXCL='*' so podman receives its mount arguments unmangled,
# which also stops conversion for native tools: native git rejects a POSIX
# `-C /e/repos/rea`, and `cygpath -w` mis-maps it in a Git-for-Windows
# installation whose MSYS root is not the drive root. Relative paths sidestep
# all of it and behave identically on Linux.
work_rel=".rea-verify-work"
work="$repo_root/$work_rel"

# `cd` is a shell builtin, so it needs no path conversion.
in_repo() { (CDPATH= cd -- "$repo_root" && "$@"); }
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM

image_id="$(podman image inspect --format '{{.Id}}' "$IMAGE")"
[ -n "$image_id" ] || { echo "rea-verify-source: cannot resolve image: $IMAGE" >&2; exit 2; }

label_sha="$(podman image inspect --format '{{index .Labels "org.virkora.rea.source.sha"}}' "$image_id")"

# The commit baked into the image must agree with its label before either is
# used to select sources. Disagreement already means the image is not what it
# claims, so there is nothing meaningful left to compare against.
# keep-id for the same reason as in rea-analyze.sh: rootless podman otherwise
# maps the container user to a different host id, and a container write to a
# bind-mounted directory owned by the invoking user fails with EACCES. These
# runs only read, but the flag keeps both scripts behaving identically.
USERNS=""
if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
  USERNS="--userns=keep-id"
fi

baked_sha="$(podman run --rm $USERNS --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --entrypoint /usr/local/bin/node \
  "$image_id" -p \
  'require("node:fs").readFileSync("/opt/rea/.rea-source-sha","utf8").trim()' \
  2>/dev/null | tr -d '\r\n')"

if [ "$label_sha" != "$baked_sha" ]; then
  echo "rea-verify-source: declared commit is inconsistent" >&2
  echo "  label : $label_sha" >&2
  echo "  baked : $baked_sha" >&2
  exit 3
fi

declared="$label_sha"
echo "image      : $IMAGE"
echo "image id   : $image_id"
echo "declared   : $declared"

in_repo git cat-file -e "${declared}^{commit}" 2>/dev/null || {
  echo "rea-verify-source: declared commit is not in this repository: $declared" >&2
  exit 3
}

rm -rf "$work"
mkdir -p "$work/archive"
in_repo git archive --format=tar "$declared" | tar -x -C "$work/archive"

podman run --rm $USERNS --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --entrypoint /usr/local/bin/node \
  "$image_id" /opt/rea/podman/rea-verify-source.mjs --emit /opt/rea \
  > "$work/image-manifest.json"

in_repo node podman/rea-verify-source.mjs --compare \
  "$work_rel/archive" "$work_rel/image-manifest.json"
