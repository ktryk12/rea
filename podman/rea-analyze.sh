#!/bin/sh
# Run one REA analysis inside a hardened, rootless Podman container.
#
#   ./podman/rea-analyze.sh <input-file-or-dir> <output-dir> [rea args...]
#
# Isolation properties, all enforced on the command line below:
#   - rootless (no sudo, no privileged, no --privileged escape)
#   - no network at all (--network=none)
#   - all Linux capabilities dropped, no privilege escalation
#   - the analysis target is mounted READ-ONLY and never written to
#   - the only writable path is the caller's output directory
#   - the container filesystem itself is read-only; scratch is a size-capped tmpfs
#   - the Podman socket is NEVER mounted, so analysis code cannot reach the
#     container engine
#   - no host credentials, SSH keys, or repositories are mounted
#
# This wrapper is deliberately plain. It adds no framework and no daemon.
set -eu

IMAGE="${REA_IMAGE:-localhost/rea-build:pinned}"
INPUT="${1:?usage: rea-analyze.sh <input> <output-dir> [rea args...]}"
OUTPUT="${2:?usage: rea-analyze.sh <input> <output-dir> [rea args...]}"
shift 2

[ -e "$INPUT" ] || { echo "rea-analyze: input not found: $INPUT" >&2; exit 2; }
mkdir -p "$OUTPUT"

# A Linux-built REA tree is required. It lives in a Podman named volume built
# by podman/README.md, NOT in the host checkout: the host node_modules holds
# win32 binaries that cannot run in the container.
REA_VOLUME="${REA_VOLUME:-rea-build-work}"

exec podman run --rm \
  --network=none \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=512m \
  --memory=4g \
  --pids-limit=512 \
  -v "$REA_VOLUME":/opt/rea:ro \
  -v "$INPUT":/analysis/input:ro \
  -v "$OUTPUT":/analysis/output:rw \
  -w /analysis/output \
  "$IMAGE" \
  "node /opt/rea/scripts/rea.mjs $(printf '%s ' "$@")"
