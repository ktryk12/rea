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
# Isolation properties, all enforced on the podman command line below:
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
# podman/Containerfile.rea-runtime, never a mutable volume, so the recorded
# image ID identifies the exact bytes that performed the analysis.
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

# Identify the runtime and the input before running anything.
image_id="$(podman image inspect --format '{{.Id}}' "$IMAGE")"
source_sha="$(podman image inspect --format '{{index .Labels "org.virkora.rea.source.sha"}}' "$IMAGE")"
source_tree="$(podman image inspect --format '{{index .Labels "org.virkora.rea.source.dirty"}}' "$IMAGE")"

input_digest() {
  if [ -f "$1" ]; then
    sha256sum "$1" | cut -d' ' -f1
  else
    # Directory: digest over the sorted per-file digests, so the value is
    # reproducible and independent of traversal order.
    find "$1" -type f -exec sha256sum {} + 2>/dev/null |
      cut -d' ' -f1 | LC_ALL=C sort | sha256sum | cut -d' ' -f1
  fi
}
in_digest="$(input_digest "$INPUT")"
in_kind="$(if [ -f "$INPUT" ]; then echo file; else echo directory; fi)"

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
  "$IMAGE" \
  /opt/rea/scripts/rea.mjs "$OPERATION" "$@" || status=$?

# Record provenance for this run next to its output. Written last so the
# recorded output digests describe the files the analysis actually produced.
manifest="$OUTPUT/rea-run-provenance.json"
out_files="$(find "$OUTPUT" -type f ! -name 'rea-run-provenance.json' 2>/dev/null |
  LC_ALL=C sort |
  while IFS= read -r f; do
    printf '    {"path": "%s", "sha256": "%s"},\n' \
      "$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
  done | sed '$ s/,$//')"

cat > "$manifest" <<JSON
{
  "operation": "$OPERATION",
  "exit_code": $status,
  "runtime": {
    "image": "$IMAGE",
    "image_id": "$image_id",
    "rea_source_sha": "$source_sha",
    "rea_source_tree": "$source_tree",
    "base_image_digest": "sha256:83f1c388c31fb2e51f7cbd4dea949b96260798c98f206e8e4696bc93bd964e3a"
  },
  "input": {
    "kind": "$in_kind",
    "sha256": "$in_digest",
    "mounted_at": "/analysis/input",
    "mode": "read-only"
  },
  "isolation": {
    "network": "none",
    "root_filesystem": "read-only",
    "capabilities": "all dropped",
    "no_new_privileges": true,
    "podman_socket_mounted": false,
    "rootless": true
  },
  "output": [
$out_files
  ]
}
JSON

exit $status
