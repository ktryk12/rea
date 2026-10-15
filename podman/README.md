# Podman development, test, and analysis isolation

Docker is not used anywhere in this fork. There is no Docker Desktop
dependency, no Docker daemon requirement, and no Docker socket.

Upstream REA ships **no** container support at all: there is no Containerfile,
Dockerfile, or compose file in the repository, and no `docker`/`podman`
reference in `src/` or `scripts/`. So nothing had to be ported away from Docker.
Everything here is additive and optional.

## Is containerisation actually needed?

For **building and testing**: no, not strictly. REA builds, typechecks, and runs
natively on Windows from a pinned lockfile. The container is still worth having
for two concrete reasons:

1. **Reproducible, offline verification.** A pinned base plus the committed
   lockfile gives an identical toolchain on any host, and the test run needs no
   network at all.
2. **The Windows native addon build lane is Linux-only.** `native/windows/README.md`
   requires Linux with MinGW-w64 (`x86_64-w64-mingw32-g++`, `dlltool`, `tar`).
   `native/windows/build/` is gitignored, so a source checkout on Windows reports
   Windows native controls as unavailable and the related tests fail. A Podman
   container is the natural place to run that lane without installing MinGW on
   the host. This image does **not** yet include MinGW; adding it is a separate,
   approved step.

For **analysis of untrusted binaries**: yes, this matters. REA's own
`SECURITY.md` is explicit:

> This is not a sandbox and does not protect against malicious processes already
> running as the same operating-system user. Opening an untrusted binary
> delegates parsing and analysis to the selected local provider with that user's
> permissions.

So isolation is ours to provide. `rea-analyze.sh` provides it.

## Build and test container

`Containerfile.rea-build` pins its base **by digest**:

```
docker.io/library/node@sha256:83f1c388c31fb2e51f7cbd4dea949b96260798c98f206e8e4696bc93bd964e3a
```

which is `node:24-alpine` providing Node v24.21.0, satisfying
`package.json#engines` (`^24.11.0`). Re-pin deliberately; never float the tag.

Dependencies are not baked into the image. The source is copied in at run time
and `npm ci` installs from the committed lockfile, so the lockfile stays the
single source of truth.

### Build the image

```sh
podman build -f podman/Containerfile.rea-build -t localhost/rea-build:pinned .
```

### Populate a build volume, then verify offline

The host checkout's `node_modules` holds win32 binaries and cannot be reused in
the container, so the container keeps its own tree in a named volume:

```sh
podman volume create rea-build-work

# Install (needs the registry):
podman run --rm --security-opt=no-new-privileges --cap-drop=ALL \
  -v E:/repos/rea:/src:ro -v rea-build-work:/work \
  localhost/rea-build:pinned \
  'cd /work; tar -C /src -cf - --exclude=.git --exclude=node_modules --exclude=website --exclude=dist . | tar -xf -; npm ci --ignore-scripts'

# Verify with no network whatsoever:
podman run --rm --network=none --security-opt=no-new-privileges --cap-drop=ALL \
  -v rea-build-work:/work localhost/rea-build:pinned \
  'cd /work; npx tsc --noEmit && npx vitest run --project domain'

# Compile the runtime used by rea-analyze.sh:
podman run --rm --network=none --security-opt=no-new-privileges --cap-drop=ALL \
  -v rea-build-work:/work localhost/rea-build:pinned \
  'cd /work; npm run compile'
```

The install step is the only one that needs the network. Keep `--ignore-scripts`.

## Isolated analysis

```sh
./podman/rea-analyze.sh <input-file-or-dir> <output-dir> [rea args...]
```

Example:

```sh
./podman/rea-analyze.sh ./sample.zip ./out inspect-artifact /analysis/input
```

The input is mounted read-only at `/analysis/input`; the output directory is the
only writable bind mount. Enforced on the `podman run` command line:

| Requirement | How |
| --- | --- |
| No Docker Desktop / daemon | Podman only; nothing references Docker |
| No Podman socket in analysis processes | The socket is never mounted |
| No privileged containers | No `--privileged`; `--cap-drop=ALL`, `--security-opt=no-new-privileges` |
| Rootless | Verified rootless with the `crun` runtime |
| Read-only analysis input | `-v "$INPUT":/analysis/input:ro` |
| Isolated output | `-v "$OUTPUT":/analysis/output:rw`, the only writable mount |
| No host credentials or production repositories | Nothing else is mounted |
| Pinned bases and dependencies | Base pinned by digest; deps from the committed lockfile |
| No change to existing Podman workloads | Only a new image and a new volume are created |

Additionally: `--network=none`, `--read-only` root filesystem, a size-capped
`noexec,nosuid` tmpfs for `/tmp`, `--memory=4g`, and `--pids-limit=512`.

### Windows shell note

Git Bash rewrites container paths and breaks the `-v` arguments
(`invalid option type "\\Git\\analysis\\input;ro"`). Run the wrapper from
PowerShell or WSL, or disable the rewriting:

```sh
MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 sh podman/rea-analyze.sh ...
```

## Capability reality inside the container

The container provides only REA's **built-in** providers, which need no external
engine: the artifact graph provider, the managed/.NET static provider, and the
JavaScript/web analysis paths. Ghidra, IDA, Hopper, JADX, Apktool, binwalk,
unblob, and the debuggers are bring-your-own and are **not** installed here.
Adding any of them is a separate decision with its own licensing review.

`rea capabilities --json` reports per-provider availability and an
`availability_code` (for example `unsupported_host`), so a caller can always
tell "not available here" from "observed nothing".

## Do not disturb the existing environment

The host already runs a `podman-machine-default` WSL2 machine with unrelated
workloads. Nothing here resets, prunes, reconfigures, or stops any of them. Do
not run `podman system prune`, `podman machine reset`, or any bulk removal while
following this document.
