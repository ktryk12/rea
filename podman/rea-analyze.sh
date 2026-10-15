#!/bin/sh
# Run ONE approved REA analysis operation inside a hardened, rootless Podman
# container, against an immutable snapshot of the input, and record what
# actually executed.
#
#   ./podman/rea-analyze.sh <input-file-or-dir> <output-dir> <operation> [args...]
#
# The input is available inside the container at /snapshot/input.
#
# Argument handling (this is a security boundary, not a convenience):
#   Every container is started with `--entrypoint /usr/local/bin/node`, and the
#   script path plus every caller argument are passed as SEPARATE argv
#   elements. No shell inside a container ever parses caller input, so an
#   argument cannot introduce a second command. Do not reintroduce `sh -lc`
#   and do not build a command string.
#
#   <operation> must appear in APPROVED_OPERATIONS below. That allowlist is the
#   boundary between approved REA analysis and arbitrary CLI use: `setup`,
#   `uninstall`, `update` and `mcp` are deliberately absent, and an operation
#   REA gains in a future version does not become callable here until it is
#   added deliberately.
#
# Isolation, all enforced on the podman command lines below:
#   - rootless; no --privileged, no capabilities, no privilege escalation
#   - no network at all (--network=none)
#   - the analysis reads a read-only snapshot, never the caller's live input
#   - the only writable bind mount is the caller's output directory
#   - the container root filesystem is read-only; scratch is a capped tmpfs
#   - the Podman socket is NEVER mounted
#   - no host credentials, SSH keys, or production repositories are mounted
#
# Why a snapshot: the analysis and the provenance record are separate container
# runs. Reading the caller's live path in both would let the bytes change in
# between, so the record could attest something that was never analysed. The
# snapshot is written once into a per-run volume and mounted read-only
# afterwards, and its digest is taken before the analysis and re-checked when
# the record is written.
#
# Identity: the image reference is resolved to an immutable image ID once, and
# every container is started from that ID. Before anything is analysed, the
# commit baked into the image must agree with the image label. Content-level
# proof that the image holds that commit's sources is a separate, stronger
# check - see podman/rea-verify-source.sh - and whether it was run for this
# invocation is recorded in the manifest.
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
  echo "the input is mounted at /snapshot/input" >&2
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

snapshot_volume=""
cleanup() {
  if [ -n "$snapshot_volume" ]; then
    podman volume rm "$snapshot_volume" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

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

# Map the calling user into the container when podman is rootless.
#
# Without this, the container process is the image user (uid 1000) while the
# bind-mounted output directory belongs to the invoking host user. Rootless
# podman maps those to different ids, so writing the provenance record failed
# with EACCES on a host whose uid is not 1000 - which is exactly what happened
# on CI, while a local run on a different host silently worked. Image files are
# world-readable, so reading /opt/rea is unaffected.
#
# The uid/gid parameters matter. Plain keep-id maps the INVOKING user's id into
# the container, but the image still runs as its own USER (node, uid 1000),
# which that mapping does not cover - so the write still failed. Naming the
# container-side ids maps uid 1000 to the caller instead, which is what makes a
# bind-mounted output directory writable while the host user still owns the
# files afterwards. Host uids vary widely (1001 on a CI runner, a
# Windows-derived 197608 here), so nothing may assume a particular value.
#
# keep-id is only valid for rootless podman; under a root podman the ids
# already line up and passing it would be an error.
USERNS=""
if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
  USERNS="--userns=keep-id:uid=1000,gid=1000"
fi

# Verify the runtime BEFORE it analyses anything. The source commit baked into
# the image must agree with the label on the image ID we resolved; otherwise
# this is not an image built by Containerfile.rea-runtime as claimed, and its
# provenance would be a fiction. Checking afterwards would still refuse the
# record, but only once an unverified runtime had already touched the input.
baked_sha="$(podman run --rm $USERNS --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --entrypoint /usr/local/bin/node \
  "$image_id" -p \
  'require("node:fs").readFileSync("/opt/rea/.rea-source-sha","utf8").trim()' \
  2>/dev/null | tr -d '\r\n')"
if [ "$baked_sha" != "$source_sha" ]; then
  echo "rea-analyze: runtime provenance mismatch, refusing to analyse" >&2
  echo "  image            : $IMAGE ($image_id)" >&2
  echo "  label source sha : $source_sha" >&2
  echo "  baked source sha : $baked_sha" >&2
  exit 3
fi

# Full content-level source binding is an explicit, separate step because it
# needs the Git repository. Set REA_REQUIRE_SOURCE_BINDING=1 to demand it here.
source_binding="not-verified-in-this-run"
if [ "${REA_REQUIRE_SOURCE_BINDING:-0}" = "1" ]; then
  if "$(dirname -- "$0")/rea-verify-source.sh" "$image_id" >/dev/null; then
    source_binding="verified-against-git-$source_sha"
  else
    echo "rea-analyze: source binding verification failed, refusing to analyse" >&2
    exit 7
  fi
fi

# ---------------------------------------------------------------------------
# Immutable input snapshot
# ---------------------------------------------------------------------------
# Written once, read-only everywhere afterwards. Symbolic links and other
# special files are refused rather than copied: a symlink has no content of its
# own to attest, and following it would leave the declared input.
snapshot_volume="$(podman volume create)"

input_sha256="$(podman run --rm $USERNS \
  --network=none \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --entrypoint /usr/local/bin/node \
  -v "$INPUT":/src:ro \
  -v "$snapshot_volume":/snapshot:rw \
  "$image_id" \
  /opt/rea/podman/rea-snapshot.mjs | tr -d '\r\n')"

if [ -z "$input_sha256" ]; then
  echo "rea-analyze: input snapshot failed; nothing was analysed" >&2
  exit 5
fi

status=0
podman run --rm $USERNS \
  --network=none \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=512m \
  --memory=4g \
  --pids-limit=512 \
  --entrypoint /usr/local/bin/node \
  -v "$snapshot_volume":/snapshot:ro \
  -v "$OUTPUT":/analysis/output:rw \
  -w /analysis/output \
  "$image_id" \
  /opt/rea/scripts/rea.mjs "$OPERATION" "$@" || status=$?

# ---------------------------------------------------------------------------
# Record provenance
# ---------------------------------------------------------------------------
# Written by node inside the same image ID, over the same read-only snapshot.
# Scalars arrive through the environment and the operation arguments arrive as
# real argv elements, so nothing is parsed or encoded by a shell. The script
# re-checks the snapshot digest and the image provenance, and refuses to write
# a record it cannot vouch for.
podman run --rm $USERNS \
  --network=none \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --entrypoint /usr/local/bin/node \
  -v "$snapshot_volume":/snapshot:ro \
  -v "$OUTPUT":/analysis/output:rw \
  -e REA_PROV_OPERATION="$OPERATION" \
  -e REA_PROV_EXIT="$status" \
  -e REA_PROV_IMAGE_REF="$IMAGE" \
  -e REA_PROV_IMAGE_ID="$image_id" \
  -e REA_PROV_SOURCE_SHA="$source_sha" \
  -e REA_PROV_SOURCE_TREE="$source_tree" \
  -e REA_PROV_BASE_DIGEST="$BASE_DIGEST" \
  -e REA_PROV_SOURCE_BINDING="$source_binding" \
  -e REA_PROV_INPUT_SHA256="$input_sha256" \
  -e REA_PROV_INPUT_HOST_PATH="$INPUT" \
  "$image_id" \
  /opt/rea/podman/rea-provenance.mjs "$@" ||
  { echo "rea-analyze: provenance record failed" >&2; exit 4; }

exit $status
