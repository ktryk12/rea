# Proposed integration: Virkora → Foundry → REA

Status: **proposal only.** Nothing in this document is implemented, and no
production integration happens in this phase. It records how our REA fork could
later be qualified as an analysis capability, reusing contracts that already
exist in `virkora-foundry` and Virkora rather than inventing new layers.

## 1. Target shape

```
Virkora / BabyAI
  |  (authority path unchanged; Foundation owns policy and identity)
  v
Foundry
  |  software discovery, analysis, reuse qualification, transformation planning
  |  selects and qualifies a REA adapter
  v
REA adapter  (out-of-process, declared capability, no authority)
  v
isolated analysis  (rootless Podman: read-only input, no network, isolated output)
  v
evidence report  -> back to Foundry for reuse and qualification judgement
```

REA returns facts, source references, limitations, and uncertainties. Foundry
judges reuse and qualification. Virkora and Foundation keep their existing
responsibilities. REA never holds authorisation, deployment, credential, or Git
effect authority.

## 2. Why REA fits the existing contracts

This is the main finding of the integration review: the two systems already
speak compatible languages, so the adapter is thin.

### 2.1 Capability declaration

Foundry's `code-intelligence/deep-adapters/src/registry.rs` defines an
`AdapterDescriptor` whose comment states the governing principle:

> Every operation it may report on. The complete vocabulary, fixed in advance.
> This is what makes "0 call sites" different from "call sites were never
> extracted": an operation absent from this list is never claimed, and an
> operation present in it always has a state.

REA already produces exactly that, at runtime and machine-readably.
`rea capabilities --json` returns, per provider:

- `provider.id`, `provider.name`, `provider.version`
- `groups[].operations[]` — the fixed operation vocabulary
- `groups[].effects[]` — e.g. `launches_process`, `may_access_network`,
  `may_write_filesystem`, `may_show_ui`
- `groups[].available` plus `reason` and `availability_code`
  (e.g. `unsupported_host`)
- `shared_limitations[]` and per-group `limitations[]`

So a REA adapter descriptor can be **generated from REA's own declaration**
instead of being hand-maintained, and "unavailable" is distinguishable from
"observed nothing" on both sides. The `effects[]` vocabulary is what lets
Foundry gate an operation before running it.

### 2.2 Evidence

REA's `docs/mcp-contracts.md` defines a canonical Evidence record. A real record
captured from an isolated container run (`inspect-artifact` on a ZIP) contains:

```
evidence_id: ev_c7518dd5f3e585f23e4b8a8c9334852ec2a6be0811781d02a5bbeda33eab1595
subject:   { name, digest.sha256, local_path, format, architecture }
provider:  { id, name, version }
analysis_profile: null
predicate_type: rea.analysis
operation: inspect_artifact
parameters: { integrity_policy: fail }
raw_result: null
normalized_result: { inspection_id, subject.manifest_id, root_sha256, substeps[...] }
```

Each substep carries its own nested `evidence_id`, and inventories declare
`coverage.scope` and `coverage.status` (`complete` or `unknown`) plus explicit
`limitations[]`. Function dossiers declare per-facet availability
(`facet_availability`), and comparisons keep a dimension `unknown` rather than
guessing.

This maps directly onto Virkora's frozen boundary rule in
`docs/security/UNIVERSAL_SOFTWARE_ADAPTER_V1.md`:

> A PREPARED REQUEST IS WHAT THE CALLER ASKED FOR. IT IS NOT WHAT IS ALLOWED.
> A SOFTWARE RESULT IS EVIDENCE. IT IS NOT PERMISSION.

REA results are already evidence-shaped, content-addressed, and explicit about
what was not observed. They assert nothing about permission.

## 3. Reuse, not new layers

| Need | Reuse this | Do not build |
| --- | --- | --- |
| Operation vocabulary and selection | `code-intelligence/deep-adapters` `AdapterDescriptor` + frozen registry | A second adapter registry |
| Capability vocabulary | `contracts/foundry-capability` | A REA-specific capability model |
| Evidence and gating | `contracts/foundry-evidence` (incl. `gate.rs`) | A REA-specific evidence schema |
| Adapter qualification | `apps/software-adapter-conformance` | A bespoke REA qualification harness |
| External request/result boundary | `UNIVERSAL_SOFTWARE_ADAPTER_V1` | A direct REA→Virkora channel |
| Repository context and provenance | RepoGraph | Provenance storage inside REA |
| Implementation of changes | JCode | Any write-back capability in REA |

Note one structural difference to respect: Foundry's `deep-adapters` are
**in-process Rust** analysing source files. REA is an **out-of-process Node
CLI/MCP server** analysing binaries and applications. REA therefore belongs as
an out-of-process, qualified external adapter — not as a new `deep-adapters`
entry — and should be qualified through `apps/software-adapter-conformance`.

## 4. Transport choice

Two options exist; prefer the first.

1. **CLI, one-shot, per analysis (recommended).** Invoke
   `node scripts/rea.mjs <command> --json` inside the hardened container from
   `podman/rea-analyze.sh`. Stateless, trivially sandboxed, no long-lived
   process, and the process boundary is the trust boundary. Verified working:
   the container run above produced a complete Evidence record.
2. **MCP over stdio.** `node scripts/rea.mjs mcp` serves 207 tools on protocol
   `2025-06-18` with `serverInfo {"name":"rea","version":"6.5.0"}`. Useful for
   stateful, multi-step investigations (open a binary, then navigate it). Costs
   session state and a longer-lived process.

Whichever is used, REA must **not** be registered into any shared agent client
configuration. `rea setup` writes MCP registrations into third-party client
config files and is prohibited on this host. Foundry should spawn REA itself,
per analysis, with an explicit command line.

## 5. Boundary rules for the adapter

1. REA is a **requester and reporter**, never an authority. It may describe what
   it observed; it may never supply facts that decide whether something is
   allowed.
2. Every REA invocation is scoped to one explicitly approved analysis target.
   No scanning of arbitrary host paths, no production repositories mounted.
3. The adapter must pass through REA's `coverage`, `limitations`,
   `availability_code`, and `facet_availability` unchanged. Dropping them would
   turn "not observed" into "absent", which both contracts forbid.
4. Evidence is content-addressed. The adapter records `evidence_id` and
   `subject.digest.sha256` so a later claim can be traced to the exact bytes.
5. No REA write-back. REA has `comment`, `set_comment`, `set_address_name`, and
   similar mutating tools for its own analysis databases; the Foundry adapter
   must expose read/observe operations only in this phase.
6. All execution happens inside the Podman profile in `podman/README.md`.

## 6. Sequencing

Nothing below is started yet; each step is independently reviewable.

1. Generate a REA adapter descriptor from `rea capabilities --json` and check it
   into Foundry. Read-only, no execution.
2. Map a small, high-value operation set first — `inspect_artifact`,
   `inspect_managed_artifact`, `compare_artifacts` — all available without any
   bring-your-own engine.
3. Run those through `apps/software-adapter-conformance` with fixed local
   fixtures, inside the container.
4. Define the REA-Evidence → `foundry-evidence` projection, preserving coverage
   and limitations verbatim.
5. Only then consider engine-backed operations (Ghidra, IDA, Hopper), each of
   which needs its own install approval and licensing review.

## 7. Open questions for the owners

- Should the REA adapter live in `virkora-foundry` or in this fork? Keeping the
  descriptor in Foundry and the runtime here preserves the ownership split.
- Does `contracts/foundry-evidence` need a new predicate type for
  `rea.analysis`, or should REA Evidence be projected into an existing one?
- Which Foundry component owns the Podman invocation and the analysis-target
  approval record?
