# REA_PR1_FINAL_PROVENANCE_REPORT

Scope: owner directive "REA PR #1 FINAL PROVENANCE GATE", sections A (source
binding), B (input integrity), C (minimal CI) and D (this report).

Merge remains on HOLD and requires a separate owner decision. Nothing was
published, deployed, released or pushed to upstream, and nothing in Virkora,
Foundation or Foundry was changed.

## 1. Commits

Branch `feat/virkora-adaptation-v1` in `ktryk12/rea`, on top of our own `main`
at `f8f3593a8c8c77a78f6ad192f2e4d3becf4bb409`.

| SHA                                        | Subject                                                                           |
| ------------------------------------------ | --------------------------------------------------------------------------------- |
| `ee224a7d10485977da524a6e8c91ba29537013ae` | test(apple): commit inventory graph digest over canonical node order              |
| `e64a1e3314189b77cfc1bf3e7e337222180bc1a6` | docs(virkora): record fork ownership, Podman isolation, and Foundry proposal      |
| `fbcbdc973e1183ff8dcb993cd7ddd11694568a9e` | fix(podman)!: pass analysis arguments as argv, never through a shell              |
| `a2c160708ec213aebe370254337e3e0a11953f08` | docs(virkora): establish a verifiable test baseline on both hosts                 |
| `74c13978212ac60c1e905c9e8dcdebebf2247fb9` | fix(podman): make run provenance unambiguous and tie it to the image that ran     |
| `3eb9086763129ea2fe9f3adda10025a354bd1e65` | fix(podman): verify the analysis runtime before it touches the input              |
| `0d66946def0d21e53f4aebda64cbe229f646cce9` | feat(podman): bind the runtime to its commit and snapshot the analysis input      |
| `cd77aec476c2aee6a6c46e49a187238b3073a3e7` | fix(podman): drain stdout before exiting, and use relative paths for native tools |
| `f8ed755b8600b41a1f7c28d580ca94e40868714a` | feat(podman): build the runtime image from a git commit, not the working tree     |
| `787bd7112cae184161090510820b303768e6429a` | feat(ci): add the verification gate as one runnable script                        |
| `5a385553b0b3750d00dff55b503857eea031d7fd` | fix(ci): give podman a relative build context in the gate                         |
| `fedf0eaf00ffbe095524e1994be59249e7cb5b5a` | ci: add a pinned, secretless gate workflow and format the fork documents          |
| `da8453a15233cb78c5b6f0c927dfed642b16cbd7` | ci: mark the gate scripts executable and stop duplicate gate runs                 |

Exactly one line of upstream source is modified across the whole branch
(`src/domain/apple/appleApplication.test.ts`); everything else is new files.

## 2. A - Source binding

**The requirement.** A declared Git commit must be verifiable against the
source files actually used to build the runtime image. A label and a baked-in
SHA are declarations by whoever built the image and are not evidence.

**What was built.**

- `podman/rea-verify-source.sh` + `podman/rea-verify-source.mjs` resolve the
  image to an immutable ID, require the label and the baked SHA to agree,
  reconstruct the declared commit with `git archive`, hash every source file
  inside the image, and compare file by file. Missing, modified and unexpected
  files each fail, and the report names them.
- `podman/rea-build-runtime.sh` builds the image **from the commit** rather than
  from the working directory, so the declared commit and the image contents
  agree by construction. A dirty tree is refused unless `REA_ALLOW_DIRTY=1`.
- `rea-analyze.sh` keeps a cheap label/baked agreement check before touching any
  input, and `REA_REQUIRE_SOURCE_BINDING=1` demands the full content check.
  Which of the two ran is recorded as `runtime.source_binding`, so a record
  never implies a check that did not happen.

**Why `git archive` and not raw blobs.** The repository sets `* text=auto
eol=lf` but `*.cmd text eol=crlf`. `git archive` applies that conversion and so
reproduces a checkout exactly; a raw blob comparison would report the three
tracked `.cmd` fixtures as mismatched on every honest build. Verified on
`tests/fixtures/captureGhidraLaunch.cmd`: archive and `cat-file --filters` both
give `10a2054d85b9`, the raw blob gives `12bc8f375b9a`.

**What the check found on first use.** An image that matched its declared commit
in all 3804 tracked files, and additionally carried four gitignored build
artefacts from the working tree:

```
build/fixtures/rea-ghidra-windows-x86.dll
build/fixtures/rea-ghidra-windows-x86.exe
build/fixtures/rea-ghidra-windows.dll
build/fixtures/rea-ghidra-windows.exe
```

That is the discrepancy the check exists to surface, and it is why the build now
exports the commit instead of using the working directory.

**Positive result.** After building from the commit:

```
declared : f8ed755b8600b41a1f7c28d580ca94e40868714a
verdict  : SOURCE_BINDING_VERIFIED
files    : 3805 expected, 3805 in image
exit     : 0
```

**Negative result (required by the directive).** An image built `FROM` the
verified runtime with two source files modified and the declared commit held
constant - label and baked SHA both unchanged:

```
declared : f8ed755b8600b41a1f7c28d580ca94e40868714a
verdict  : SOURCE_BINDING_FAILED
modified : podman/rea-digest.mjs, scripts/rea.mjs
missing  : 0   unexpected: 0
exit     : 1
```

The label-and-baked check accepted this image; only the content comparison
rejected it. That is precisely the gap the directive identified. Demonstrated
end to end:

| Run against the tampered image       | Result                                                                                 |
| ------------------------------------ | -------------------------------------------------------------------------------------- |
| without `REA_REQUIRE_SOURCE_BINDING` | analysis proceeds, exit 0, manifest records `source_binding: not-verified-in-this-run` |
| with `REA_REQUIRE_SOURCE_BINDING=1`  | refused, exit 7, output directory empty                                                |

## 3. B - Input integrity

**Special files.** Previously anything that was not a regular file or directory
was recorded as kind `other` and the run continued, putting un-attestable
entries into a provenance record. A symbolic link has no content of its own:
hashing its target is not the bytes that were analysed, and following it leaves
the declared input. FIFOs, sockets and device nodes have no stable content and
can block a read indefinitely.

`podman/rea-digest.mjs` now `lstat`s every entry, including the input root, and
refuses anything else with `UnhashableEntryError`, surfaced as exit 5. Verified:

| Input                                            | Result                          |
| ------------------------------------------------ | ------------------------------- |
| directory containing `escape.txt -> /etc/passwd` | refused, exit 5, named the link |
| directory containing a FIFO                      | refused, exit 5, named the FIFO |

**Snapshot.** The analysis and the provenance record are separate container
runs. Reading the caller's live path in both left a window in which the bytes
could change, so the manifest could attest something that was never analysed.

`podman/rea-snapshot.mjs` now copies the input once into a per-run volume,
digests the snapshot, and every later container mounts that volume read-only at
`/snapshot/input`. The provenance script re-digests it and refuses to write a
record if the value moved (exit 6). Verified:

| Check                                                | Result                               |
| ---------------------------------------------------- | ------------------------------------ |
| snapshot writable during analysis?                   | no - `EROFS`                         |
| provenance with a deliberately wrong expected digest | refused, exit 6, no manifest written |
| per-run volume removed afterwards                    | yes, via trap                        |

**Residual limitation, stated rather than papered over.** The caller's input can
still change while the snapshot copy is running. The manifest therefore attests
the snapshot - what the analysis actually read - and says so explicitly in
`input.attests`; it never claims the host path was stable.

**Directory digests.** The digest covers entry kind, path relative to the input
root, and content digest, with directories included. Three fixtures that the
previous contents-only digest could not distinguish:

| Fixture               | Old digest     | New digest         |
| --------------------- | -------------- | ------------------ |
| baseline              | `b3743906cb8e` | `a0636b6099ebc471` |
| one directory renamed | `b3743906cb8e` | `64c78dd532d231ee` |
| two filenames swapped | `b3743906cb8e` | `6707562921238668` |

**Output paths** are recorded relative to the output directory, so `a/report.json`
and `b/report.json` stay distinct instead of collapsing to one `report.json`.
The record is produced by `JSON.stringify`, not by shell string building.

## 4. C - CI

**Platform investigation, as the directive required.** At the start of this
work GitHub registered **no** workflows for this fork
(`GET /repos/ktryk12/rea/actions/workflows` returned `total_count: 0`) and
**zero** runs, after several pushes and an open pull request, despite 29
inherited upstream workflow files on disk. On that evidence Actions was not
executing anything.

**That changed when the gate workflow was pushed.** GitHub then registered four
workflows and began running them. This was a side effect of adding our workflow,
not an intended configuration change, and it also activated three inherited
upstream workflows:

| Workflow           | Trigger               | Note                                                     |
| ------------------ | --------------------- | -------------------------------------------------------- |
| `virkora-gate.yml` | ours                  | the gate                                                 |
| `ci.yml`           | `pull_request`        | upstream's full pipeline                                 |
| `pr-title.yml`     | `pull_request`        | fails: our PR title does not match upstream's convention |
| `pr-readiness.yml` | `pull_request_target` | upstream's, runs in elevated context                     |

**Merge-time risk to decide before merging.** `release.yml` is not registered
while nothing pushes to `main`, but it triggers on `push` to `main` and its
release job is gated on `github.event_name == 'push'`. Merging this PR pushes to
`main` and would start it. It falls back to `secrets.GITHUB_TOKEN` when
`RELEASE_PLEASE_TOKEN` is absent, so it could act on `ktryk12/rea`. This
conflicts with the directive's "no automatic release". It can be prevented
without touching upstream files:

```sh
gh api repos/ktryk12/rea/actions/workflows --jq '.workflows[] | "\(.id) \(.path)"'
gh api -X PUT repos/ktryk12/rea/actions/workflows/<id>/disable
```

This changes repository settings, so it is left as an owner decision rather than
done unilaterally. There is no exposure while merge is on HOLD.

**The gate.** `podman/ci-gate.sh` holds the checks; the workflow calls it and
nothing else, so CI cannot drift from local behaviour. The workflow references
no secrets, holds only `contents: read`, publishes nothing, is guarded by
`github.repository == 'ktryk12/rea'`, fetches full history (the gate needs
`git archive`), and pins both actions to commit SHAs:

- `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` (v7.0.1)
- `actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1` (v7.1.0)

Node comes from `.nvmrc`; the runner is pinned to `ubuntu-24.04`; the base
container image is pinned by digest and `git`/`procps-ng` to exact Alpine
versions.

**Runner requirement.** The gate needs rootless podman on the runner host. A
containerised agent would need the container socket passed in, which gives that
step control of the host's containers. The existing self-hosted Woodpecker
agent (`WOODPECKER_BACKEND=docker`, podman socket bound at
`/var/run/docker.sock`) could run the `static` and `provenance` stages; the
`negative` stage would need that socket, which is a deliberate trade-off rather
than a default. A self-hosted GitHub Actions runner on a host with rootless
podman runs the gate unmodified.

## 5. Test results

Local, at `da8453a15233cb78c5b6f0c927dfed642b16cbd7`, Windows 11 host with
rootless podman 5.8.3 and Node v24.11.1 (runtime container Node v24.21.0):
Run `38728943883`, head `b8a672ab4`, conclusion **success**.

| Stage        | Result on ubuntu-24.04, podman 4.9.3 rootless, crun                               |
| ------------ | --------------------------------------------------------------------------------- |
| `static`     | **success** - typecheck, compile, repository-wide format, lint, 3233 domain tests |
| `provenance` | **success** - all four checks, including both source-binding directions           |
| `negative`   | **success** - 13 of 13                                                            |

Earlier runs on the same branch failed the `negative` stage at 11 of 13 and,
before that, did not start at all. Each cause is below.

`static`: typecheck, compile, `oxfmt --check .` across all 3594 files, `oxlint`,
and the full `domain` project (193 files, 3233 tests).

`provenance`: image builds from the commit; source binding verified; source
binding rejects modified sources under a held-constant SHA; analysis refuses a
tampered runtime when the gate is required (exit 7).

`negative`: argument injection blocked; operation allowlist rejects an injected
operation and `setup`/`mcp`/`update`/`uninstall`; root filesystem `EROFS`; no
network (`EAI_AGAIN`); no podman or docker socket; no shell from the image;
symbolic links and special files refused; directory digests distinguish a rename
and swapped filenames; output manifest records relative paths.

Earlier measurements that remain valid are in `virkora/TEST_BASELINE.md`: the
broad `test:fast` suite fails 214 on Windows and 39 in the container at
`fbcbdc973`, with every failure attributed and none caused by this branch.

### CI result

The gate runs on GitHub. Results by stage, over successive commits:

| Stage        | Result on `ubuntu-24.04`, podman 4.9.3 rootless, crun                                                         |
| ------------ | ------------------------------------------------------------------------------------------------------------- |
| `static`     | **success** - typecheck, compile, repository-wide format, lint, 3233 domain tests                             |
| `provenance` | **success** - all four checks, including both source-binding directions                                       |
| `negative`   | 11 of 13; the two manifest-dependent checks blocked by a rootless id-mapping defect, fixed as described below |

Three defects were found only by running on a second platform, which is the
reason for having CI at all:

1. `Permission denied`, exit 126: the scripts were committed mode 100644.
2. `/bin/sh: syntax error: unterminated quoted string` while building the tamper
   fixture: the gate generated it with `echo "... printf '
   ' ..."`, and dash's
   echo expands backslash escapes while bash's does not.
3. `EACCES` writing the provenance record to the bind-mounted output directory.
   The container runs as the image user (`node`, uid 1000) while the output
   directory belongs to the invoking host user; rootless podman maps those to
   different ids. Plain `--userns=keep-id` did **not** fix it, because it maps
   the _invoking_ user's id and the process still runs as uid 1000.
   `--userns=keep-id:uid=1000,gid=1000` maps container uid 1000 to the caller
   and does. Host uids differ widely - 1001 on the runner, a Windows-derived
   197608 locally - and `--user "$(id -u)"` is rejected on the latter
   ("doesn't map UID 197608"), so naming the container-side ids is the only
   portable form.

## 6. Defects found in our own work during this round

Recorded because they bear on how much the gate can be trusted.

1. **Truncated manifest reported as success.** `rea-verify-source.mjs` called
   `process.exit(0)` straight after writing a large manifest to stdout. Pipe
   writes are asynchronous, so the output was cut to exactly 65536 bytes while
   the command still reported exit 0. Confirmed not a podman limit: a 200 KiB
   single write through the same path arrives complete.
2. **Gate measured stale state.** A run that never reached the provenance step
   left the previous manifest in place, and the digest tests read it: three
   different directory fixtures all reported the digest of an earlier file
   input (`aaf9ff488e0767da`). It would equally have allowed a false pass. The
   manifest is now deleted before each run and a missing one reported as
   `NO_MANIFEST`.
3. **Gate helper variables were global.** POSIX sh has no function scope, so
   `expect_status` assigning `out` clobbered the caller's output directory and
   later tests used an error message as a path. Helper locals are prefixed.
4. **Integrity check ran too late.** The image check happened after the
   analysis, so a non-conforming runtime had already read the input before its
   record was refused. It now runs first.
5. **Inherited base entrypoint.** The runtime image inherited
   `docker-entrypoint.sh`, so `podman run <image> sh -c` reached a shell, which
   an earlier comment denied. `ENTRYPOINT` is now explicitly node.
6. **Repository-wide formatting was never checked.** Earlier rounds reported
   `oxfmt --check` clean for changed source files only; across the repository,
   as upstream's own `format:check` does, four markdown files failed. The gate's
   static stage now runs the repository-wide check.
7. **Executable bits were not in the index.** The first real CI run failed with
   `Permission denied`, exit 126, because the scripts were committed 100644.

## 7. CI run

Actions executes the gate; see section 5 for stage results and section 4 for
how Actions came to be enabled and what else it activated. The PR carries the
live status for the current head commit.

## 8. Changed files

```
.containerignore
.github/workflows/virkora-gate.yml
.gitignore
podman/Containerfile.rea-build
podman/Containerfile.rea-runtime
podman/README.md
podman/ci-gate.sh
podman/rea-analyze.sh
podman/rea-build-runtime.sh
podman/rea-digest.mjs
podman/rea-provenance.mjs
podman/rea-snapshot.mjs
podman/rea-verify-source.mjs
podman/rea-verify-source.sh
src/domain/apple/appleApplication.test.ts      (1 line)
virkora/FORK_OWNERSHIP.md
virkora/FOUNDRY_INTEGRATION.md
virkora/REA_PR1_FINAL_PROVENANCE_REPORT.md
virkora/TEST_BASELINE.md
```

## 9. Remaining risks

1. **Merging starts upstream CI, including `release.yml`.** Decide whether to
   disable the inherited workflows on the fork first. Highest-priority item.
2. **The host input can change during the snapshot copy.** The manifest attests
   the snapshot, not the host path. Closing this fully would require taking the
   input from an already-immutable source, such as a content-addressed store.
3. **Source binding is opt-in per analysis.** `rea-analyze.sh` always performs
   the cheap check; the content check runs only with
   `REA_REQUIRE_SOURCE_BINDING=1` because it needs the Git repository. Any
   caller that wants a provenance guarantee must set it, and the manifest says
   which check ran.
4. **The `git archive` comparison trusts the local repository.** It proves the
   image matches a commit as this clone records it. It does not prove that
   commit is what upstream published; commit signing would be a separate step.
5. **214 Windows failures in the broad suite remain uncategorised per test.**
   Attributed in bulk to the missing Windows native addon, whose build lane
   needs Linux and MinGW-w64. Not individually re-tested with the addon present.
6. **No engine-backed path has run against a real engine.** Ghidra, IDA, Hopper,
   JADX, Apktool, WABT and Rizin are all bring-your-own and uninstalled.
7. **No production integration exists.** The chain approved artefact → REA
   analysis in Podman → verified evidence → Foundry qualification has not been
   built; `virkora/FOUNDRY_INTEGRATION.md` section 4 describes the harness it
   needs.
8. **Container socket on a CI agent.** If the gate's negative stage is ever run
   on the existing Woodpecker agent, that step controls the host's containers.
