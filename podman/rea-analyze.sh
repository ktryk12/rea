#!/bin/sh
# Run ONE approved REA analysis operation inside a hardened, rootless Podman
# container, and record what actually executed.
#
#   ./podman/rea-analyze.sh <input-file-or-dir> <output-dir> <operation> [args...]
#
# Argument handling (this is a security boundary, not a convenience):
#   The container is started with `--entrypoint /usr/local/bin/node` and the
#   script path plus every caller argument are passed as SEPARATE argv
#   elements. No shell inside the container ever parses caller input, so an
#   argument cannot introduce a second command. Do not reintroduce `sh -lc`
#   and do not build a command string.
#
#   <operation> must appear in APPROVED_OPERATIONS below. That allowlist is the
#   boundary between approved REA analysis and arbitrary CLI use: `setup`,
#   `uninstall`, `update` and `mcp` are deliberately absent, and an operation
#   REA gains in a future version does not become callable here until it is
#   added deliberately.
#
# Isolation properties, all enforced on the podman command lines below:
#   - rootless; no --privileged, no capabilities, no privilege escalation
#   - no network at all (--network=none)
#   - the analysis target is mounted READ-ONLY and never written to
#   - the only writable bind mount is the caller's output directory
#   - the container root filesystem is read-only; scratch is a capped tmpfs
#   - the Podman socket is NEVER mounted, so analysis code cannot reach the
#     container engine
#   - no host credentials, SSH keys, or production repositories are mounted
#
# Provenance: the runtime is an immutable image built by
# podman/Containerfile.rea-runtime, never a mutable volume. The tag is resolved
# to an image ID once and every container is started from that ID, so the
# recorded identity is the one that executed. The record itself is written by
# podman/rea-provenance.mjs running in that same image; this script builds no
# JSON and computes no digests, because hand-rolled shell escaping is where
# provenance records go wrong.
set -eu

# Read-only, evidence-producing operations that need no bring-your-own engine.
# Keep this list minimal and explicit. One operation per line.
APPROVED_OPERATIONS="
capabilities
providers
inspect-artifact
inspect-managed-artifact
inspect-binary-layout
inspect-keyed-archive
decode-interface-builder
inspect-wasm-artifact
compare-wasm-interfaces
inspect-evm-interface
inspect-sqlite-database
inspect-packet-capture
inspect-packet-fields
inspect-go-binary
"

usage() {
  echo "usage: rea-analyze.sh <input> <output-dir> <operation> [args...]" >&2
  echo "approved operations:" >&2
  for op in $APPROVED_OPERATIONS; do echo "  $op" >&2; done
  exit 2
}

[ "$#" -ge 3 ] || usage

IMAGE="${REA_IMAGE:-localhost/rea-runtime:current}"
INPUT="$1"
OUTPUT="$2"
OPERATION="$3"
shift 3

# Reject anything not explicitly approved, before starting a container.
approved=no
for op in $APPROVED_OPERATIONS; do
  if [ "$op" = "$OPERATION" ]; then
    approved=yes
    break
  fi
done
if [ "$approved" != yes ]; then
  echo "rea-analyze: operation not approved: $OPERATION" >&2
  usage
fi

[ -e "$INPUT" ] || { echo "rea-analyze: input not found: $INPUT" >&2; exit 2; }
mkdir -p "$OUTPUT"

# ---------------------------------------------------------------------------
# Resolve the runtime ONCE, by image ID
# ---------------------------------------------------------------------------
# A tag is a mutable pointer. Inspecting a tag and then starting a container
# from the same tag leaves a window in which the tag could be moved, so the
# recorded image ID would not be the image that ran.
image_id="$(podman image inspect --format '{{.Id}}' "$IMAGE")"
[ -n "$image_id" ] || { echo "rea-analyze: cannot resolve image: $IMAGE" >&2; exit 2; }
source_sha="$(podman image inspect --format '{{index .Labels "org.virkora.rea.source.sha"}}' "$image_id")"
source_tree="$(podman image inspect --format '{{index .Labels "org.virkora.rea.source.dirty"}}' "$image_id")"

BASE_DIGEST="sha256:83f1c388c31fb2e51f7cbd4dea949b96260798c98f206e8e4696bc93bd964e3a"

status=0
podman run --rm \
  --network=none \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=512m \
  --memory=4g \
  --pids-limit=512 \
  --entrypoint /usr/local/bin/node \
  -v "$INPUT":/analysis/input:ro \
  -v "$OUTPUT":/analysis/output:rw \
  -w /analysis/output \
  "$image_id" \
  /opt/rea/scripts/rea.mjs "$OPERATION" "$@" || status=$?

# ---------------------------------------------------------------------------
# Record provenance
# ---------------------------------------------------------------------------
# Written by node inside the same image ID, so the record is valid JSON by
# construction and the input digest covers names and tree structure, not just
# contents. Scalars arrive through the environment and the operation arguments
# arrive as real argv elements, so nothing is parsed or encoded by a shell.
#
# The provenance script also re-reads the source commit baked into the image
# and refuses to write a record if it disagrees with the image label.
podman run --rm \
  --network=none \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --entrypoint /usr/local/bin/node \
  -v "$INPUT":/analysis/input:ro \
  -v "$OUTPUT":/analysis/output:rw \
  -e REA_PROV_OPERATION="$OPERATION" \
  -e REA_PROV_EXIT="$status" \
  -e REA_PROV_IMAGE_REF="$IMAGE" \
  -e REA_PROV_IMAGE_ID="$image_id" \
  -e REA_PROV_SOURCE_SHA="$source_sha" \
  -e REA_PROV_SOURCE_TREE="$source_tree" \
  -e REA_PROV_BASE_DIGEST="$BASE_DIGEST" \
  "$image_id" \
  /opt/rea/podman/rea-provenance.mjs "$@" ||
  { echo "rea-analyze: provenance record failed" >&2; exit 4; }

exit $status
