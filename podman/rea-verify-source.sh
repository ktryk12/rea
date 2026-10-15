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
work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM

image_id="$(podman image inspect --format '{{.Id}}' "$IMAGE")"
[ -n "$image_id" ] || { echo "rea-verify-source: cannot resolve image: $IMAGE" >&2; exit 2; }

label_sha="$(podman image inspect --format '{{index .Labels "org.virkora.rea.source.sha"}}' "$image_id")"

# The commit baked into the image must agree with its label before either is
# used to select sources. Disagreement already means the image is not what it
# claims, so there is nothing meaningful left to compare against.
baked_sha="$(podman run --rm --network=none --read-only --cap-drop=ALL \
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

git -C "$repo_root" cat-file -e "${declared}^{commit}" 2>/dev/null || {
  echo "rea-verify-source: declared commit is not in this repository: $declared" >&2
  exit 3
}

mkdir -p "$work/archive"
git -C "$repo_root" archive --format=tar "$declared" | tar -x -C "$work/archive"

podman run --rm --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --entrypoint /usr/local/bin/node \
  "$image_id" /opt/rea/podman/rea-verify-source.mjs --emit /opt/rea \
  > "$work/image-manifest.json"

node "$repo_root/podman/rea-verify-source.mjs" --compare \
  "$work/archive" "$work/image-manifest.json"
