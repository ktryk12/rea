# REA fork ownership and independent maintenance

This document records how `ktryk12/rea` is owned, how it stays buildable without
upstream, and what it is allowed to do inside the Virkora system. It describes
only facts verified in this repository. Upstream REA remains the MIT-licensed
work of its original author; this fork adds no claim over it.

## 1. Provenance

| Fact | Value |
| --- | --- |
| Our fork | `https://github.com/ktryk12/rea` (real GitHub fork) |
| Upstream | `https://github.com/morluto/rea` (MIT, default branch `main`) |
| Fork point | `f8f3593a8c8c77a78f6ad192f2e4d3becf4bb409` |
| Local working copy | `E:\repos\rea` |
| Development branch | `feat/virkora-adaptation-v1` |
| History | 3261 commits, root commit `729d3e927cbcf17224e6b988eebcfae0d215c876` |

Full upstream history is present. The previously observed upstream commit
`ce89706145dd98fbaa8df8f062fdc80777136940` is an ancestor of our fork point.
Upstream is an active repository and has already advanced past our fork point;
that is expected and does not affect this fork.

### Remote policy

```
origin    https://github.com/ktryk12/rea.git      (fetch + push)
upstream  https://github.com/morluto/rea.git      (fetch only)
upstream  DISABLED_NO_PUSH_TO_UPSTREAM            (push URL, deliberately invalid)
```

The upstream push URL is set to an invalid literal so an accidental
`git push upstream` fails instead of contacting the original repository.
Upstream is a voluntary source of improvements, never an operational dependency.

Prohibited in this fork: force-push, history rewriting, repository reset, and
any push to `upstream`.

## 2. Licensing and attribution

REA-authored code is MIT (`LICENSE`, "Copyright (c) 2026 morluto"). The upstream
project maintains an unusually complete attribution set, which this fork keeps
unchanged:

- `LICENSE` - MIT, original copyright retained.
- `THIRD_PARTY_NOTICES.md` - distributed dependencies, derived code, and
  separately obtained engines.
- `licenses/` - preserved upstream texts plus `upstream-sources.json` with
  SHA-256 digests of each retained text.

Licensing facts that matter for our own redistribution:

- The analysis engines (Ghidra, IDA, Hopper, JADX, Apktool, binwalk, unblob,
  mitmproxy, GDB, LLDB, adb, ILSpy) are **bring-your-own**. They are not
  bundled, so their licenses - including GPL-2.0 (Unicorn) and GPL-3.0-or-later
  (GNU GDB) - do not attach to REA's distribution. They attach to whatever the
  operator installs locally.
- The one real redistribution obligation is the **prebuilt Windows native
  addon**, which statically links MinGW-w64 GCC runtime libraries under the GCC
  Runtime Library Exception 3.1. If we ever publish our own Windows binary, the
  MinGW-w64 notices, GPLv3 text, and exception text must ship with it, and the
  compiler actually used must be re-checked against `licenses/README.md`.
- `frida` is an optional dependency declared
  `LGPL-2.0 WITH WxWindows-exception-3.1`. It is omitted from our installs.
- Documented upstream notice gaps (`clean-git-ref@2.0.1`, `minimisted@2.0.1`,
  `frida@17.23.2`) are recorded by upstream as gaps. Do not restate them as
  complete attribution.

No license blocker was found for internal development and internal use.

## 3. Submodules

Five submodules pin third-party inspection sources. All are **uninitialized** in
this working copy and are not required to build, typecheck, compile, or run the
CLI/MCP server.

| Submodule | Pinned commit | License |
| --- | --- | --- |
| `third_party/binwalk` | `4fdab3d464d97b68e0af9088df3f9e2e1545b21c` | MIT |
| `third_party/ghidra-nativeaot` | `effeb734fc570c32650f88b159608979dc7b423e` | MIT |
| `third_party/jadx-headless-mcp` | `5844800a486d2248fa949b74c9896285f5b54de2` | Apache-2.0 |
| `third_party/unblob` | `1fcc7a0a584a70a96c31f5a276c20944d199a089` | MIT |
| `third_party/wakaru` | `8219bf5016a063d7fb215101a8c45d5959ec733f` | Apache-2.0 |

They point at third-party repositories, not at upstream REA, so upstream going
away does not affect them. Each is pinned to a commit, so availability is the
only risk; mirror them into our own namespace if long-term retention matters.

## 4. Dependency surface

Verified from `package-lock.json` (lockfileVersion 3):

- 723 locked package entries; **every** `resolved` URL points at
  `https://registry.npmjs.org`. No git, GitHub-tarball, or private-registry
  sources.
- Exactly 3 packages declare install scripts, none of them required:
  `frida@17.23.2` (optional), `fsevents@2.3.3` (optional, dev, macOS),
  `esbuild@0.25.12` (dev, under `vitepress`, docs site only).
- `npm audit` on the installed tree: **0 vulnerabilities**.
- Node engine requirement: `^22.19.0 || ^24.11.0 || >=26.0.0`.

Install command used in this fork, and the one to keep using:

```
HUSKY=0 npm ci --ignore-scripts
```

`--ignore-scripts` is kept permanently. `HUSKY=0` prevents the root `prepare`
script from installing git hooks (`core.hooksPath`) into the working copy.

Both root lifecycle scripts were read and are benign: `scripts/prepare.mjs` only
installs husky hooks locally, and `scripts/prepack.mjs` only runs local build
steps. Neither touches the network or agent configuration.

Optional platform packages must **not** be omitted: TypeScript 7 resolves a
platform binary (`@typescript/typescript-win32-x64`), and `--omit=optional` makes
`tsc` fail with "Unable to resolve @typescript/typescript-win32-x64".

## 5. What actually couples this fork to upstream

Measured, not assumed:

| Coupling | Reality | Needed to build or run? |
| --- | --- | --- |
| `rea.tools` website | Documentation links and a docs-fact check in `scripts/lib/docs-facts.mjs` | No |
| `morluto/rea` strings | `package.json` metadata, `server.json`, release-note and website scripts | No |
| `rea-agents` on npm | Only `rea update`, which resolves the latest version for a **globally installed** package | No - not used from a source checkout |
| `api.github.com` | `scripts/ci/artifacts.mjs`, upstream CI artifact handling | No |
| `install.sh` | Upstream pipe-to-shell installer that fetches Node and the npm package | No - never used here |
| JADX jar URL | `src/android/JadxRelease.ts` pins a third-party release jar | Only for Android analysis |
| Submodules | Third-party repos, pinned | No |
| Containers | **No coupling at all** - no Containerfile, Dockerfile, compose file, or docker/podman reference in `src/` or `scripts/` | No |

**Conclusion:** nothing in the build, typecheck, compile, CLI, or MCP path
requires upstream REA, `rea.tools`, or the published npm package. This fork is
already operationally independent from a pinned lockfile. If upstream were
archived tomorrow, this repository would continue to build and run.

Still external and genuinely required for *full* capability: the bring-your-own
analysis engines, and `registry.npmjs.org` for a cold `npm ci` (mitigate with a
vendored cache or an internal mirror if offline builds are needed).

## 6. Independent build and release process

### Build

```
HUSKY=0 npm ci --ignore-scripts     # pinned install, no lifecycle scripts
npx tsc --noEmit                    # typecheck
npm run compile                     # tsc -p tsconfig.build.json + bundle to dist/
node scripts/rea.mjs --version      # CLI smoke
node scripts/rea.mjs capabilities --json
```

Reproducible and containerised variants of these steps, plus the isolated
analysis profile, are in [podman/README.md](../podman/README.md). The measured
state of the test suites on both hosts is in
[TEST_BASELINE.md](TEST_BASELINE.md); read it before treating any test failure
in this fork as new.

`npm run compile` is the minimal path to a working `dist/`. The broader
`npm run build` and `npm run check:*` targets additionally drive turbo, knip,
oxlint, oxfmt, and artifact generators; they are useful but not required to
produce a runnable build.

### Release

Releases are **ours**, cut from our fork, and are not published to any public
registry:

1. Work on `feat/*` branches off our `main`.
2. Open a pull request into `ktryk12/rea`'s `main`. Never merge without
   reviewing tests, security impact, and the diff.
3. Tag with a fork-local prefix, for example `virkora-rea-<semver>`, so our tags
   never collide with upstream's `rea-agents-*` tags.
4. Publish a GitHub Release on `ktryk12/rea` with a packed tarball
   (`npm pack`), consumed internally by git ref or by that tarball.

**No automatic publishing to npm or any other registry.** `prepublishOnly` in
`package.json` runs `verify:windows-native:artifact`; never run `npm publish`
from this fork. If an internal distribution channel is ever needed, use a
private registry with a scoped name and treat it as a separate decision.

### Identity: deliberately unchanged

`package.json#name` (`rea-agents`), `package.json#mcpName`
(`io.github.morluto/rea`), `server.json#name`, and the MCP `serverInfo.name`
(`rea`) are **left exactly as upstream**. Renaming them would change the MCP
server identity that agent clients key their configuration on, break
`scripts/verify-mcp-registry-metadata.mjs`, and invalidate the published MCP
registry entry. Per the fork mandate, a namespace change requires a documented
compatibility analysis first; it is not a prerequisite for independent
development and is not done here.

### Fork-local documents

Fork-specific documentation lives in `virkora/`, not in `docs/`. `docs/` is
built by VitePress with no `ignoreDeadLinks`, so fork-local files there would
either break the docs build or have to be registered in the upstream sidebar.
Keeping them separate also avoids merge conflicts in `docs/` when upstream
changes are pulled in.

## 7. Boundaries this fork must respect

REA is a **specialised analysis capability**, nothing more. Inside the Virkora
system it must never take on:

- authorisation or policy decisions (Foundation owns these),
- deployment or credential management,
- Git effect authority,
- reuse and qualification judgement (Foundry owns this),
- repository context and provenance ownership (RepoGraph owns this),
- software implementation (JCode owns this).

REA returns facts, source references, limitations, and uncertainties. It does not
decide anything.

### Installation safety

`rea setup` is **not** to be run on this host. Verified by reading the code:
`src/application/SetupClientConfiguration.ts`, `SetupClients.ts`,
`SupportedClients.ts`, and `ClaudeDesktopConfigLocation.ts` write MCP server
registrations into third-party agent client configuration files. Running it
would modify the existing Claude/Codex/Cursor/Virkora MCP configuration, which is
out of scope for this fork.

Also prohibited without separate approval: `npx rea-agents setup`, global npm
installation, `install.sh` or any network-fetched installer, and installing
Ghidra, IDA, Hopper, or other external engines.

Starting the MCP server (`node scripts/rea.mjs mcp`) is safe and was verified not
to register anything: it serves stdio and exits when the pipe closes.
