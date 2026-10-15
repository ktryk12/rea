# Proposed integration: Virkora → Foundry → REA

Status: **proposal only.** Nothing here is implemented, and no production
integration happens in this phase. It records how our REA fork could later be
qualified as an analysis capability.

An earlier revision of this document claimed that REA's capability and Evidence
formats map directly onto existing Foundry contracts. **That claim was wrong**
and is corrected in section 3. The contracts were read, and they are narrower
and more deliberate than the claim assumed. Integration is still worth doing,
but it needs a new, explicitly approved projection layer — not a drop-in reuse.

## 1. Target shape

```
Virkora / BabyAI
  |  (authority path unchanged; Foundation owns policy and identity)
  v
Foundry
  |  software discovery, analysis, reuse qualification, transformation planning
  |  selects a versioned, approved REA operation surface
  v
REA adapter  (out-of-process, no authority)
  v
isolated analysis  (rootless Podman: read-only input, no network, isolated output)
  v
evidence report  -> back to Foundry for reuse and qualification judgement
```

## 2. Three different questions that must not be merged

This separation is the architectural point, and collapsing it is the main risk
of integrating an analysis tool at all.

| Question                                                      | Who answers it       | Where it lives                                                |
| ------------------------------------------------------------- | -------------------- | ------------------------------------------------------------- |
| What can the analysis tool _perform_?                         | REA                  | `rea capabilities --json` — operations, effects, availability |
| What behaviour must a software solution _exhibit_ to qualify? | Foundry              | `contracts/foundry-capability` — `CapabilityContract`         |
| What is _authorised_?                                         | Foundation / Virkora | the existing authority path                                   |

REA describing its own operations is **not** a capability contract, and it is
**not** permission. A REA operation becoming available must never, by itself,
widen what Foundry may ask for or what Virkora may authorise.

## 3. What the existing contracts actually are

Read from `virkora-foundry`. Each row corrects a reuse assumption.

| Component                           | What the code actually supports                                                                                                                                                                                                                                                                                                                        | Consequence for REA                                                                                                                                                                                                                                         |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `code-intelligence/deep-adapters`   | A **frozen static registry** of **in-process Rust** adapters. `AdapterDescriptor.run` is `fn(&str, &FileContext<'_>) -> AdapterOutput`, and `ADAPTERS` is a `static` table analysing source files.                                                                                                                                                     | REA is an out-of-process Node process analysing binaries. It **cannot** be an entry here. Only the _principle_ transfers (see 3.1).                                                                                                                         |
| `contracts/foundry-capability`      | F3.4.1 `CapabilityContract`: "what observable behaviour must hold, not how an implementation is expected to represent that behaviour." Its own doc comment lists what it **may not** describe, including "expected record kinds, evidence types" and "implementation vocabulary". Claims are adjudicated individually (`SUPPORTED` / `INDETERMINATE`). | REA's operation names and `effects` vocabulary are exactly the implementation vocabulary this contract forbids. Pouring them in would be a category error and would turn the contract into "an elaborate matcher", which its doc comment exists to prevent. |
| `contracts/foundry-evidence`        | `RunRecord` + `EvidenceSink`. Deliberately **weak**: `metrics` is a string-keyed map and `outcome` is a string, specifically so the storage layer never learns a producer's semantics (Charter §7.5).                                                                                                                                                  | REA's rich Evidence record is **not** automatically compatible. It stays producer-side; only a thin projection (identity, operation, outcome, digests, counts) goes into a `RunRecord`.                                                                     |
| `apps/software-adapter-conformance` | States plainly: "**This is conformance, not integration.**" It proves Rust-produced bytes are accepted by Virkora's canonical Python `SoftwareRequestV1.from_json`. A four-field envelope, no transport, no trusted ingress, and it may never carry a grant, signature, policy result or requester identity.                                           | It does **not** execute REA analyses and cannot qualify one today. It is the right place to prove a REA _request_ is well-formed; running the analysis is separate, new work.                                                                               |

### 3.1 What does genuinely transfer

One principle, not a type. `deep-adapters/src/registry.rs` states it:

> Every operation it may report on. The complete vocabulary, fixed in advance.
> This is what makes "0 call sites" different from "call sites were never
> extracted": an operation absent from this list is never claimed, and an
> operation present in it always has a state.

REA independently satisfies the same discipline at runtime: `capabilities --json`
reports `available`, a `reason`, and an `availability_code` (e.g.
`unsupported_host`), and inventories carry `coverage.status` (`complete` /
`unknown`), `limitations[]` and per-facet `facet_availability`. Comparisons keep
a dimension `unknown` rather than guessing.

So the two systems share a _stance_ on absence. They do not share a schema.

## 4. What must therefore be built

A **versioned, approved REA operation surface** owned by Foundry:

1. A checked-in surface document, e.g. `rea-surface-v1`, listing the REA
   operations Foundry may invoke, each with its REA operation name, argument
   shape, declared effects, and the approval that admitted it.
2. `rea capabilities --json` is **discovery input only**. It is used to detect
   what a given REA build offers, and to detect drift against the approved
   surface. A new REA version that adds or renames operations produces a
   _diff to review_, never an automatic grant. The same applies in reverse: an
   operation disappearing must be reported, not silently skipped.
3. A projection from a REA Evidence record into `foundry-evidence::RunRecord`
   that keeps the rich record addressable rather than flattened: record
   `evidence_id`, `subject.digest.sha256`, the runtime provenance (image ID and
   REA source SHA, see section 5), and the coverage/limitation state. The full
   REA record is retained as an artefact referenced by digest.
4. Capability contracts stay behaviour-only. REA evidence is **input to
   adjudicating** a `CapabilityContract` claim; it is never the contract.
5. A separate harness that actually runs a REA analysis in the container. The
   existing conformance app is not that harness and should not be stretched
   into one.

The matching allowlist already exists on the REA side:
`podman/rea-analyze.sh` refuses any operation outside `APPROVED_OPERATIONS`, so
a REA version bump cannot widen what the wrapper will execute either.

## 5. Provenance: which bytes performed the analysis

The analysis runtime is the immutable image from
`podman/Containerfile.rea-runtime`, built with a pinned base digest and carrying
the REA source commit as an image label. A mutable named volume is deliberately
**not** used for analysis, because anything could be written into it afterwards
and the runtime would no longer be identifiable.

Every run writes `rea-run-provenance.json` beside its output recording the
operation and exit code, the runtime image ID, the REA source SHA and whether
that source tree was clean, the pinned base image digest, the input digest and
mount mode, the enforced isolation properties, and a digest per output file.

The wrapper computes the input digest independently of REA, and in the verified
run it matched REA's own `subject.digest.sha256`
(`99c83172f61184f456a682f1fc24a13ba01eeed706da012bbe8bbc6a33499cb4`), so the
two agree on which bytes were analysed.

## 6. Transport choice

1. **CLI, one-shot, per analysis (recommended).** `podman/rea-analyze.sh` runs a
   single approved operation with no shell, no network, and a read-only input.
   Stateless; the process boundary is the trust boundary. Verified working.
2. **MCP over stdio.** `node scripts/rea.mjs mcp` serves 207 tools on protocol
   `2025-06-18`. Useful for stateful multi-step investigation, at the cost of
   session state and a longer-lived process. Not used in this phase; `mcp` is
   deliberately absent from the wrapper's allowlist.

REA must **not** be registered into any shared agent client configuration.
`rea setup` writes MCP registrations into third-party client config files and is
prohibited on this host. Foundry spawns REA itself, per analysis, with an
explicit argument vector.

## 7. Boundary rules for the adapter

1. REA is a **reporter**. It may describe what it observed; it may never supply
   facts that decide whether something is allowed.
2. Every invocation is scoped to one explicitly approved analysis target. No
   scanning of arbitrary host paths; no production repositories mounted.
3. The projection must pass through `coverage`, `limitations`,
   `availability_code` and `facet_availability` unchanged. Dropping them turns
   "not observed" into "absent", which both systems forbid.
4. Evidence is content-addressed, and a claim must be traceable to the exact
   input bytes and the exact runtime that produced it.
5. No REA write-back. REA has mutating tools (`comment`, `set_address_name`, …)
   for its own analysis databases; the Foundry surface exposes read/observe
   operations only in this phase.
6. All execution happens inside the Podman profile in `podman/README.md`.

## 8. Sequencing

Each step is independently reviewable; none has started.

1. Draft `rea-surface-v1` from `rea capabilities --json`, by hand, as a
   reviewed document. Read-only, no execution.
2. Start with operations available without any bring-your-own engine:
   `inspect-artifact`, `inspect-managed-artifact`, `inspect-binary-layout`.
3. Define the REA-Evidence → `RunRecord` projection, preserving coverage and
   limitations and keeping the full record addressable by digest.
4. Build the analysis harness (new) and drive it with fixed local fixtures in
   the container, with positive **and** negative tests.
5. Only then adjudicate a real `CapabilityContract` claim using REA evidence as
   input.
6. Engine-backed operations (Ghidra, IDA, Hopper) come last, each needing its
   own install approval and licensing review.

## 9. Open questions for the owners

- Should `rea-surface-v1` live in `virkora-foundry` or in this fork? Keeping the
  surface in Foundry and the runtime here preserves the ownership split.
- Does the REA-Evidence artefact belong in `evidence/run-store` alongside its
  `RunRecord`, or in separate content-addressed storage?
- Which Foundry component owns the Podman invocation and the record of which
  analysis target was approved?
