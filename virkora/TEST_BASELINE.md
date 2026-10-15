# Test baseline

A reproducible record of what the REA test suites actually do in this fork, so
that a future failure can be compared against a known state instead of being
guessed at. Read this before treating any failure here as new.

Measured at commit `fbcbdc973e1183ff8dcb993cd7ddd11694568a9e` on branch
`feat/virkora-adaptation-v1`.

Suite under test: `npm run test:fast` (`node scripts/ci/test-group.mjs source`),
8092 tests in 538 files.

## Headline

| Host                                       | Command                            | Exit | Failed  | Passed | Skipped |
| ------------------------------------------ | ---------------------------------- | ---- | ------- | ------ | ------- |
| Windows 11, Node v24.11.1, source checkout | `npm run test:fast`                | 1    | **214** | 7740   | 138     |
| Linux in Podman, Node v24.21.0             | same, `localhost/rea-build:pinned` | 1    | **39**  | 8045   | 8       |

The same code fails 214 tests on Windows and 39 in the container. **175 of the
Windows failures are host-conditioned, not defects in this fork.** That is the
single most useful fact in this document.

Neither figure is caused by this branch. For comparison, the broad suite failed
**215** tests at the unmodified fork point `f8f3593a8`; the one-test difference
is the fixture ordering fix in commit `ee224a7d1`.

## Windows: why 214

Dominant cause, confirmed by direct observation rather than inference:

```
PrivateRuntimeRootUnavailableError: REA Windows native controls are unavailable:
Missing packaged Windows native file native/windows/build/manifest.json (ENOENT).
```

`native/windows/build/` is gitignored and ships only in the published
`rea-agents` npm tarball, and its build lane requires Linux with MinGW-w64
(`native/windows/README.md`). A source checkout on Windows therefore has no
native addon, and every provider that needs the private runtime root fails.

Verified by running one file in isolation:
`npx vitest run --project adapters src/ida/IdaContainment.test.ts`
→ 33 of 40 tests fail, every one caused by the error above
(`code: 'private-runtime-root-authority-unavailable'`).

Largest failing files on Windows:

| File                                        | Failed   |
| ------------------------------------------- | -------- |
| `src/ida/IdaSessionClient.test.ts`          | 43       |
| `src/ida/IdaContainment.test.ts`            | 33       |
| `src/ida/IdaOperationFailures.test.ts`      | 31       |
| `src/wasm/WabtArtifactProvider.test.ts`     | 12       |
| `src/electron/ElectronFuseProvider.test.ts` | 11       |
| `src/hopper/HopperTargetLease.test.ts`      | 10       |
| `src/ghidra/GhidraSnapshotCache.test.ts`    | 7        |
| (22 further files)                          | 1–5 each |

The IDA clusters are a secondary effect of the same root cause: with no private
runtime root, every operation fails as a generic `ProviderAdapterError` instead
of the specific error class each test expects.

**Not verified:** how many of the 214 pass once the native addon is present.
Restoring it means either taking two files from the published upstream tarball
or building the MinGW lane, and neither is approved in this phase. Until then,
treat 214 as the Windows baseline and compare against it; do not claim the
suite passes on Windows.

## Linux in container: why 39

All 39 are attributable, and **none** indicate a defect in this fork. Every
remaining failure is a missing bring-your-own tool.

| Cause                                 | Failed | File(s)                                                                                                            |
| ------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------ |
| Apktool not installed (BYO)           | 20     | `src/apktool/ApktoolProvider.test.ts`, `src/apktool/ApktoolVersionProbe.lifecycle.test.ts`                         |
| WABT / `wasm2wat` not installed (BYO) | 12     | `src/wasm/WabtArtifactProvider.test.ts`                                                                            |
| Playwright browsers not installed     | 4      | `src/browser/PlaywrightElectronActiveProvider.test.ts`                                                             |
| Rizin not installed (BYO)             | 1      | `tests/composition/reverseEngineeringCancellation.test.ts` ("Rizin provider and descendant did not start in time") |
| **harness gap, now fixed**            | 1      | `src/process/ProcessOwnership.identity.test.ts`                                                                    |
| **harness gap, now fixed**            | 1      | `tests/conformance/readmeConsistency.test.ts`                                                                      |

### The two harness gaps were ours, and are closed

Both were defects in how the container was prepared, not in REA:

1. **Missing `procps`.** Alpine ships busybox `ps`; REA rejects it
   ("Linux process ownership inspection requires a procps-compatible ps on
   REA's PATH"). `procps-ng=4.0.6-r0` is now pinned in
   `podman/Containerfile.rea-build`. Re-verified in the rebuilt image:
   `src/process/ProcessOwnership.identity.test.ts` → **9/9 passed**.
   It is deliberately _not_ added to the analysis runtime image, to keep that
   image's toolset minimal.
2. **`website/` excluded from the container copy.** The copy command omitted
   `website/`, so a conformance test that reads it failed. Re-verified with the
   full tree copied: `tests/conformance/readmeConsistency.test.ts` →
   **5/5 passed**. It also passes on Windows, where the full tree is present.

So the expected Linux residual, with the fixed image and a complete copy, is
**37 failures, all missing-external-tool**. Anything beyond that list is new and
should be investigated.

## The 8 container skips

3 distinct tests, reported 3 times each by the shard reporter plus the project
split, all in one file:

- `src/contracts/sessionPathInputs.test.ts` — "Windows absolute path forms".

Correctly skipped on Linux because they assert Windows path semantics. They run
and pass on Windows, which is why Windows reports 138 skips and Linux 8.

## Platform-independent suites are green

These are the suites that carry real signal for fork maintenance, since they do
not depend on any external engine or host-specific artefact:

| Suite                                     | Host                        | Result                     |
| ----------------------------------------- | --------------------------- | -------------------------- |
| `vitest run --project domain`             | Windows                     | **3233 / 3233 passed**     |
| `vitest run --project domain`             | container, `--network=none` | **3230 passed, 3 skipped** |
| `tsc --noEmit`                            | both                        | exit 0                     |
| `npm run compile`                         | both                        | exit 0                     |
| `oxfmt --check`, `oxlint` (changed files) | Windows                     | exit 0                     |

## How to reproduce

```sh
# Windows baseline
npm run test:fast

# Container baseline (see podman/README.md for image and volume setup;
# copy the FULL tree, excluding only .git, node_modules and dist)
podman run --rm --cap-drop=ALL --security-opt=no-new-privileges \
  -v E:/repos/rea:/src:ro -v rea-build-work:/work localhost/rea-build:pinned \
  'cd /work; tar -C /src -cf - --exclude=.git --exclude=node_modules --exclude=dist . | tar -xf -; npm ci --ignore-scripts; npm run compile; npm run test:fast'
```

## Open work this baseline does not cover

- The 214 Windows failures are categorised by cause but not individually
  re-tested with the native addon present.
- No engine-backed path (Ghidra, IDA, Hopper, JADX, Apktool, WABT, Rizin) has
  been exercised against a real engine. Installing any of them needs separate
  approval and a licensing review.
- The broader `npm run check:*` targets (knip, jscpd, docs checks, metadata
  checks) have not been run in full.
