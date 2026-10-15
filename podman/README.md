# Podman development, test, and analysis isolation

Docker is not used anywhere in this fork. There is no Docker Desktop
dependency, no Docker daemon requirement, and no Docker socket.

Upstream REA ships **no** container support at all: there is no Containerfile,
Dockerfile, or compose file in the repository, and no `docker`/`podman`
reference in `src/` or `scripts/`. So nothing had to be ported away from Docker.
Everything here is additive and optional.

There are two images, and the split matters:

| Image                         | Built from                  | Mutable?                                    | Purpose                           |
| ----------------------------- | --------------------------- | ------------------------------------------- | --------------------------------- |
| `localhost/rea-build:pinned`  | `Containerfile.rea-build`   | source bind-mounted, deps in a named volume | development, typecheck, test runs |
| `localhost/rea-runtime:<sha>` | `Containerfile.rea-runtime` | **no** — source and `dist/` are baked in    | performing analyses               |

Analyses run **only** on the runtime image. A build image plus a mutable named
volume cannot prove which REA bytes performed an analysis, because anything can
be written into the volume afterwards. The runtime image is immutable, so its
image ID plus its recorded source commit identify the exact analysis runtime.

## Is containerisation actually needed?

For **building and testing**: no, not strictly. REA builds, typechecks, and runs
natively on Windows from a pinned lockfile. The container is still worth having
for two concrete reasons:

1. **Reproducible, offline verification.** A pinned base plus the committed
   lockfile gives an identical toolchain on any host, and the test run needs no
   network at all. It is also how the Windows-only failures in
   `virkora/TEST_BASELINE.md` are shown to be host-conditioned.
2. **The Windows native addon build lane is Linux-only.** `native/windows/README.md`
   requires Linux with MinGW-w64 (`x86_64-w64-mingw32-g++`, `dlltool`, `tar`).
   `native/windows/build/` is gitignored, so a source checkout on Windows reports
   Windows native controls as unavailable and the related tests fail. A Podman
   container is the natural place to run that lane without installing MinGW on
   the host. Neither image includes MinGW yet; adding it is a separate, approved
   step.

For **analysis of untrusted binaries**: yes, this matters. REA's own
`SECURITY.md` is explicit:

> This is not a sandbox and does not protect against malicious processes already
> running as the same operating-system user. Opening an untrusted binary
> delegates parsing and analysis to the selected local provider with that user's
> permissions.

So isolation is ours to provide. `rea-analyze.sh` provides it.

## Pinning

Both Containerfiles pin the same base **by digest**:

```
docker.io/library/node@sha256:83f1c388c31fb2e51f7cbd4dea949b96260798c98f206e8e4696bc93bd964e3a
```

which is `node:24-alpine` providing Node v24.21.0, satisfying
`package.json#engines` (`^24.11.0`). Re-pin deliberately; never float the tag.

`git` is pinned to an exact Alpine package version with **no `||` fallback**. An
earlier revision had a fallback to an unpinned `git`, and it fired: the image
silently received git 2.54.0-r0 instead of the pinned 2.51.0-r0. A missing pin
must now fail the build loudly so it is updated deliberately.

Dependencies always come from the committed `package-lock.json`, never from the
image, so the lockfile stays the single source of truth.

## Build and test image

```sh
podman build -f podman/Containerfile.rea-build -t localhost/rea-build:pinned .
```

The host checkout's `node_modules` holds win32 binaries and cannot be reused in
the container, so this workflow keeps its own tree in a named volume:

```sh
podman volume create rea-build-work

# Install (the only step that needs the registry):
podman run --rm --security-opt=no-new-privileges --cap-drop=ALL \
  -v E:/repos/rea:/src:ro -v rea-build-work:/work \
  localhost/rea-build:pinned \
  'cd /work; tar -C /src -cf - --exclude=.git --exclude=node_modules --exclude=website --exclude=dist . | tar -xf -; npm ci --ignore-scripts'

# Verify with no network whatsoever:
podman run --rm --network=none --security-opt=no-new-privileges --cap-drop=ALL \
  -v rea-build-work:/work localhost/rea-build:pinned \
  'cd /work; npx tsc --noEmit && npx vitest run --project domain'
```

Keep `--ignore-scripts`. This volume is for development only; never use it to
perform an analysis.

## Analysis runtime image

Built with the source commit recorded as an image label:

```sh
SHA=$(git rev-parse HEAD)
DIRTY=$([ -z "$(git status --porcelain)" ] && echo clean || echo dirty)
podman build -f podman/Containerfile.rea-runtime \
  --build-arg REA_SOURCE_SHA="$SHA" --build-arg REA_SOURCE_DIRTY="$DIRTY" \
  -t localhost/rea-runtime:"$SHA" -t localhost/rea-runtime:current .
```

The image runs `npm ci --ignore-scripts` and `npm run compile` at build time, so
`dist/` is part of the image rather than something written later.

## Isolated analysis

```sh
./podman/rea-analyze.sh <input-file-or-dir> <output-dir> <operation> [args...]
```

Example:

```sh
./podman/rea-analyze.sh ./sample.zip ./out inspect-artifact /analysis/input
```

### Argument handling is a security boundary

The container is started with `--entrypoint /usr/local/bin/node`, and the script
path plus every caller argument are passed as **separate argv elements**. No
shell inside the container ever parses caller input.

An earlier revision built a command string and ran it through the image's
`sh -lc` entrypoint. That was a command-injection defect: an argument such as
`--version; id; echo INJECTED_COMMAND_RAN` executed `id` inside the container.
**Do not reintroduce `sh -lc`, and do not build a command string.**

`<operation>` must appear in `APPROVED_OPERATIONS` in the script. That allowlist
is the boundary between approved REA analysis and arbitrary CLI use: `setup`,
`uninstall`, `update` and `mcp` are deliberately absent, and an operation a
future REA version adds does not become callable until it is added deliberately.

### Enforced properties

| Requirement                                    | How                                                                     |
| ---------------------------------------------- | ----------------------------------------------------------------------- |
| No Docker Desktop / daemon                     | Podman only; nothing references Docker                                  |
| No Podman socket in analysis processes         | The socket is never mounted (verified absent in-container)              |
| No privileged containers                       | No `--privileged`; `--cap-drop=ALL`, `--security-opt=no-new-privileges` |
| Rootless                                       | Verified rootless with the `crun` runtime                               |
| Read-only analysis input                       | `-v "$INPUT":/analysis/input:ro` (writes fail `EROFS`)                  |
| Isolated output                                | `-v "$OUTPUT":/analysis/output:rw`, the only writable bind mount        |
| No host credentials or production repositories | Nothing else is mounted                                                 |
| Pinned bases and dependencies                  | Base pinned by digest; deps from the committed lockfile                 |
| No arbitrary command execution                 | Direct argv, no shell, explicit operation allowlist                     |
| Identifiable runtime                           | Immutable image; ID and source SHA recorded per run                     |
| No change to existing Podman workloads         | Only new images and a new volume are created                            |

Additionally: `--network=none` (DNS fails `EAI_AGAIN`), `--read-only` root
filesystem (writes fail `EROFS`), a capped `noexec,nosuid` tmpfs for `/tmp`,
`--memory=4g`, and `--pids-limit=512`.

### Run provenance

Each run writes `rea-run-provenance.json` into the output directory. It is
produced by `podman/rea-provenance.mjs` running in the **same image ID**, with
the input mounted read-only.

The wrapper itself builds no JSON and computes no digests, and it needs no node
on the host. Scalars reach the provenance script through environment variables
and the operation arguments reach it as real argv elements, so nothing is parsed
or encoded by a shell. This is deliberate: the first shell implementation had
two escaping defects, one of which silently wrote empty `path` values, which is
the worst possible failure for a provenance record — well-formed and
meaningless. A failed provenance write fails the run with exit 4.

Three properties worth stating precisely:

- **Identity is resolved once, by image ID.** A tag is a mutable pointer, so
  inspecting a tag and then starting a container from that same tag leaves a
  window in which the tag could move. The tag is resolved to an immutable image
  ID before anything runs, and every container is started from that ID. The
  record says `"started_from": "image_id"`.
- **The runtime is verified before it analyses anything.** The source commit
  baked into the image must agree with the label on the resolved image ID. A
  mismatch exits 3 and nothing is analysed. Verified with a deliberately
  tampered image: refused, output directory left empty.
- **Input digests cover names and structure, not only contents.** Hashing just
  the set of file digests gives two different trees the same value whenever
  their contents match but their layout does not. Directories are included, so
  a rename or an added empty directory changes the value.

Output paths are recorded relative to the output directory, so `a/report.json`
and `b/report.json` stay distinct instead of collapsing to one `report.json`.

For a single-file input the wrapper's digest can be compared with REA's own
`subject.digest.sha256`; in the verified run the two agreed.

### Windows shell note

Git Bash rewrites container paths and breaks the `-v` and `--entrypoint`
arguments (`invalid option type "\\Git\\analysis\\input;ro"`). Run the wrapper
from PowerShell or WSL, or disable the rewriting:

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
