// Write the run-provenance record for one isolated REA analysis.
//
// This runs INSIDE the pinned analysis runtime, started from an image ID, with
// the immutable input snapshot mounted read-only and the output directory
// mounted read-write. It is invoked by podman/rea-analyze.sh after the
// analysis.
//
// Why node and not shell: the record is JSON, and hand-rolled shell escaping is
// where provenance records go wrong. An earlier shell implementation silently
// wrote empty `path` values because its escaper aborted inside a command
// substitution. Here JSON.stringify is correct by construction, every scalar
// arrives through an environment variable and the operation arguments arrive as
// real argv elements, so nothing is parsed by a shell, and a failure is an exit
// code rather than a quietly malformed record.
//
// Three checks are enforced before a record is written:
//   - the commit baked into the image agrees with the image label;
//   - the snapshot digest still equals the digest taken when the snapshot was
//     created, so the record attests the bytes the analysis actually read;
//   - every entry is a regular file or directory, enforced by rea-digest.mjs.

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { describeInput, UnhashableEntryError, walk } from "./rea-digest.mjs";

const INPUT = process.env.REA_PROV_INPUT ?? "/snapshot/input";
const OUTPUT = "/analysis/output";
const MANIFEST = "rea-run-provenance.json";

const required = (name) => {
  const value = process.env[name];
  if (value === undefined)
    throw new Error(`rea-provenance: missing environment variable ${name}`);
  return value;
};

const fail = (message, code) => {
  process.stderr.write(`rea-provenance: ${message}\n`);
  process.exit(code);
};

let input;
let outputEntries;
try {
  input = describeInput(INPUT);
  outputEntries = walk(OUTPUT)
    .filter((entry) => entry.path !== MANIFEST)
    .map(({ kind, path, sha256 }) =>
      sha256 === undefined ? { kind, path } : { kind, path, sha256 },
    );
} catch (cause) {
  if (cause instanceof UnhashableEntryError) fail(cause.message, 5);
  throw cause;
}

const bakedSha = readFileSync("/opt/rea/.rea-source-sha", "utf8").trim();
const labelSha = required("REA_PROV_SOURCE_SHA");
if (bakedSha !== labelSha)
  fail(`image label ${labelSha} does not match baked source ${bakedSha}`, 3);

// The snapshot was digested when it was created, before the analysis ran. It is
// mounted read-only everywhere afterwards, so a change here would mean the
// snapshot was altered out of band and the record must not be written.
const expectedInputDigest = required("REA_PROV_INPUT_SHA256");
if (input.sha256 !== expectedInputDigest)
  fail(
    `input snapshot changed after analysis; expected ${expectedInputDigest}, found ${input.sha256}`,
    6,
  );

const record = {
  operation: required("REA_PROV_OPERATION"),
  // Real argv elements, forwarded by the wrapper; never a hand-built string.
  arguments: process.argv.slice(2),
  exit_code: Number.parseInt(required("REA_PROV_EXIT"), 10),
  runtime: {
    image_ref_requested: required("REA_PROV_IMAGE_REF"),
    image_id: required("REA_PROV_IMAGE_ID"),
    started_from: "image_id",
    rea_source_sha: labelSha,
    rea_source_sha_baked_in_image: bakedSha,
    rea_source_tree: required("REA_PROV_SOURCE_TREE"),
    base_image_digest: required("REA_PROV_BASE_DIGEST"),
    node_version: process.version,
    source_binding: required("REA_PROV_SOURCE_BINDING"),
  },
  input: {
    ...input,
    snapshot: {
      mounted_at: INPUT,
      mode: "read-only",
      immutable: true,
      digest_taken_before_analysis: expectedInputDigest,
      rechecked_after_analysis: true,
    },
    host_path: required("REA_PROV_INPUT_HOST_PATH"),
    attests:
      "the snapshot that the analysis read, not the caller's live host path",
    special_entries: "refused; only regular files and directories are hashed",
  },
  isolation: {
    network: "none",
    root_filesystem: "read-only",
    capabilities: "all dropped",
    no_new_privileges: true,
    podman_socket_mounted: false,
    rootless: true,
  },
  output: outputEntries,
};

writeFileSync(join(OUTPUT, MANIFEST), `${JSON.stringify(record, null, 2)}\n`);
